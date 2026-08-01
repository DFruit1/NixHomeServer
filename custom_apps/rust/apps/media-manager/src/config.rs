use serde::{Deserialize, Serialize};
use std::{env, net::IpAddr, path::PathBuf};

pub const DEFAULT_EDITOR_GROUP: &str = "media-manager-editors";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MutationMode {
    ReadOnly,
    Enabled,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RootScope {
    Shared,
    Personal,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VisibleRoot {
    pub id: String,
    pub label: String,
    pub category: String,
    pub scope: RootScope,
    #[serde(skip_serializing)]
    pub resolved_path: String,
    pub available: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IntegrationCapability {
    pub id: String,
    pub label: String,
    pub available: bool,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub address: IpAddr,
    pub port: u16,
    pub state_dir: PathBuf,
    pub shared_root: PathBuf,
    pub users_root: PathBuf,
    pub editor_group: String,
    pub mutation_mode: MutationMode,
    pub mkvmaker_progress_file: PathBuf,
    pub open_subtitles_credentials_file: Option<PathBuf>,
    pub frontend_dir: Option<PathBuf>,
    pub integrations: Vec<IntegrationCapability>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub username: String,
    pub groups: Vec<String>,
}

impl Identity {
    pub fn try_new<I, S>(username: &str, groups: I) -> Result<Self, String>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        if !valid_identity_component(username) {
            return Err("forwarded username is not a safe identity component".to_string());
        }
        let mut groups = groups
            .into_iter()
            .map(|group| group.as_ref().trim().to_string())
            .filter(|group| !group.is_empty())
            .collect::<Vec<_>>();
        groups.sort();
        groups.dedup();
        Ok(Self {
            username: username.to_string(),
            groups,
        })
    }

    pub fn new<I, S>(username: &str, groups: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        Self::try_new(username, groups).expect("valid test identity")
    }

    pub fn can_edit(&self, editor_group: &str) -> bool {
        self.groups.iter().any(|group| group == editor_group)
    }
}

impl AppConfig {
    pub fn from_env() -> Result<Self, String> {
        let address = env_string("MEDIA_MANAGER_ADDRESS", "127.0.0.1")
            .parse::<IpAddr>()
            .map_err(|error| format!("invalid MEDIA_MANAGER_ADDRESS: {error}"))?;
        if !address.is_loopback() {
            return Err("MEDIA_MANAGER_ADDRESS must be loopback".to_string());
        }
        let port = env_string("MEDIA_MANAGER_PORT", "8087")
            .parse::<u16>()
            .map_err(|error| format!("invalid MEDIA_MANAGER_PORT: {error}"))?;
        let mutation_mode = match env_string("MEDIA_MANAGER_MUTATION_MODE", "read-only").as_str() {
            "read-only" => MutationMode::ReadOnly,
            "enabled" => MutationMode::Enabled,
            value => return Err(format!("invalid MEDIA_MANAGER_MUTATION_MODE: {value}")),
        };
        let integrations_json = env_string("MEDIA_MANAGER_INTEGRATIONS_JSON", "[]");
        let integrations =
            serde_json::from_str::<Vec<IntegrationCapability>>(&integrations_json)
                .map_err(|error| format!("invalid MEDIA_MANAGER_INTEGRATIONS_JSON: {error}"))?;
        validate_integrations(&integrations)?;

        Ok(Self {
            address,
            port,
            state_dir: PathBuf::from(env_string(
                "MEDIA_MANAGER_STATE_DIR",
                "/var/lib/media-manager",
            )),
            shared_root: PathBuf::from(env_string("MEDIA_MANAGER_SHARED_ROOT", "/mnt/data/shared")),
            users_root: PathBuf::from(env_string("MEDIA_MANAGER_USERS_ROOT", "/mnt/data/users")),
            editor_group: env_string("MEDIA_MANAGER_EDITOR_GROUP", DEFAULT_EDITOR_GROUP),
            mutation_mode,
            mkvmaker_progress_file: PathBuf::from(env_string(
                "MEDIA_MANAGER_MKVMAKER_PROGRESS_FILE",
                "/run/mkvmaker/progress.json",
            )),
            open_subtitles_credentials_file: env::var_os(
                "MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE",
            )
            .map(PathBuf::from),
            frontend_dir: env::var_os("MEDIA_MANAGER_FRONTEND_DIR").map(PathBuf::from),
            integrations,
        })
    }

    pub fn for_test(shared_root: &str, users_root: &str) -> Self {
        Self {
            address: "127.0.0.1".parse().expect("loopback address"),
            port: 8087,
            state_dir: PathBuf::from("."),
            shared_root: PathBuf::from(shared_root),
            users_root: PathBuf::from(users_root),
            editor_group: DEFAULT_EDITOR_GROUP.to_string(),
            mutation_mode: MutationMode::ReadOnly,
            mkvmaker_progress_file: PathBuf::from("progress.json"),
            open_subtitles_credentials_file: None,
            frontend_dir: None,
            integrations: Vec::new(),
        }
    }

    pub fn database_path(&self) -> PathBuf {
        self.state_dir.join("control.sqlite3")
    }

    pub fn visible_roots(&self, identity: &Identity) -> Vec<VisibleRoot> {
        let personal_base = self.users_root.join(&identity.username);
        let definitions = [
            (
                "shared-videos",
                "Shared videos",
                "videos",
                RootScope::Shared,
                self.shared_root.join("_Videos"),
            ),
            (
                "shared-music",
                "Shared music",
                "music",
                RootScope::Shared,
                self.shared_root.join("_Music"),
            ),
            (
                "shared-audiobooks",
                "Shared audiobooks",
                "audiobooks",
                RootScope::Shared,
                self.shared_root.join("_Audiobooks"),
            ),
            (
                "shared-books",
                "Shared books",
                "books",
                RootScope::Shared,
                self.shared_root.join("_Books"),
            ),
            (
                "shared-dvd-inbox",
                "DVD ISO inbox",
                "iso",
                RootScope::Shared,
                self.shared_root.join("_ISO/_DVDs"),
            ),
            (
                "personal-videos",
                "My videos",
                "videos",
                RootScope::Personal,
                personal_base.join("_Videos"),
            ),
            (
                "personal-music",
                "My music",
                "music",
                RootScope::Personal,
                personal_base.join("_Music"),
            ),
            (
                "personal-audiobooks",
                "My audiobooks",
                "audiobooks",
                RootScope::Personal,
                personal_base.join("_Audiobooks"),
            ),
            (
                "personal-books",
                "My books",
                "books",
                RootScope::Personal,
                personal_base.join("_Books"),
            ),
        ];

        definitions
            .into_iter()
            .map(|(id, label, category, scope, path)| VisibleRoot {
                id: id.to_string(),
                label: label.to_string(),
                category: category.to_string(),
                scope,
                available: path.is_dir(),
                resolved_path: path.to_string_lossy().into_owned(),
            })
            .collect()
    }

    pub fn resolve_visible_root(&self, identity: &Identity, root_id: &str) -> Option<VisibleRoot> {
        if !valid_root_id(root_id) {
            return None;
        }
        self.visible_roots(identity)
            .into_iter()
            .find(|root| root.id == root_id)
    }
}

fn env_string(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_string())
}

fn valid_identity_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn valid_root_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn validate_integrations(integrations: &[IntegrationCapability]) -> Result<(), String> {
    let mut ids = std::collections::BTreeSet::new();
    for integration in integrations {
        if !valid_root_id(&integration.id) {
            return Err(format!("invalid integration ID: {}", integration.id));
        }
        if !ids.insert(integration.id.as_str()) {
            return Err(format!("duplicate integration ID: {}", integration.id));
        }
    }
    Ok(())
}
