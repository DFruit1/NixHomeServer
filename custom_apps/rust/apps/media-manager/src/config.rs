use serde::{Deserialize, Serialize};
use std::{env, net::IpAddr, path::PathBuf};

pub const DEFAULT_EDITOR_GROUP: &str = "media-manager-editors";

pub const TOMBSTONE_FOLDER: &str = "_Tombstone";

const MEDIA_CATEGORIES: [(&str, &str, &str, &str); 5] = [
    ("videos", "_Videos", "Shared videos", "My videos"),
    ("music", "_Music", "Shared music", "My music"),
    (
        "audiobooks",
        "_Audiobooks",
        "Shared audiobooks",
        "My audiobooks",
    ),
    ("podcasts", "_Podcasts", "Shared podcasts", "My podcasts"),
    ("books", "_Books", "Shared books", "My books"),
];

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

#[derive(Clone, Debug)]
pub struct RootScanSpec {
    pub id: String,
    pub category: String,
    pub scope: RootScope,
    pub path: PathBuf,
    pub owner_username: Option<String>,
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
    pub jellyfin_metadata_cache_file: Option<PathBuf>,
    pub audiobookshelf_metadata_cache_file: Option<PathBuf>,
    pub kavita_metadata_cache_file: Option<PathBuf>,
    pub jellyfin_base_url: Option<String>,
    pub jellyfin_public_url: Option<String>,
    pub audiobookshelf_public_url: Option<String>,
    pub kavita_public_url: Option<String>,
    pub jellyfin_api_key_file: Option<PathBuf>,
    pub acoustid_api_key_file: Option<PathBuf>,
    pub fpcalc_path: Option<PathBuf>,
    pub ffprobe_path: Option<PathBuf>,
    pub musicbrainz_api_base: Option<String>,
    pub acoustid_api_base: Option<String>,
    pub musicbrainz_request_gap_ms: u64,
    pub frontend_dir: Option<PathBuf>,
    pub files_base_url: Option<String>,
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
            jellyfin_metadata_cache_file: env::var_os("MEDIA_MANAGER_JELLYFIN_METADATA_CACHE_FILE")
                .map(PathBuf::from),
            audiobookshelf_metadata_cache_file: env::var_os(
                "MEDIA_MANAGER_AUDIOBOOKSHELF_METADATA_CACHE_FILE",
            )
            .map(PathBuf::from),
            kavita_metadata_cache_file: env::var_os("MEDIA_MANAGER_KAVITA_METADATA_CACHE_FILE")
                .map(PathBuf::from),
            jellyfin_base_url: optional_env("MEDIA_MANAGER_JELLYFIN_BASE_URL"),
            jellyfin_public_url: optional_env("MEDIA_MANAGER_JELLYFIN_PUBLIC_URL"),
            audiobookshelf_public_url: optional_env("MEDIA_MANAGER_AUDIOBOOKSHELF_PUBLIC_URL"),
            kavita_public_url: optional_env("MEDIA_MANAGER_KAVITA_PUBLIC_URL"),
            jellyfin_api_key_file: env::var_os("MEDIA_MANAGER_JELLYFIN_API_KEY_FILE")
                .map(PathBuf::from),
            acoustid_api_key_file: env::var_os("MEDIA_MANAGER_ACOUSTID_API_KEY_FILE")
                .map(PathBuf::from),
            fpcalc_path: env::var_os("MEDIA_MANAGER_FPCALC_PATH").map(PathBuf::from),
            ffprobe_path: env::var_os("MEDIA_MANAGER_FFPROBE").map(PathBuf::from),
            musicbrainz_api_base: optional_env("MEDIA_MANAGER_MUSICBRAINZ_API_BASE"),
            acoustid_api_base: optional_env("MEDIA_MANAGER_ACOUSTID_API_BASE"),
            musicbrainz_request_gap_ms: env_string(
                "MEDIA_MANAGER_MUSICBRAINZ_RATE_LIMIT_MS",
                "1000",
            )
            .parse::<u64>()
            .map_err(|error| format!("invalid MEDIA_MANAGER_MUSICBRAINZ_RATE_LIMIT_MS: {error}"))?,
            frontend_dir: env::var_os("MEDIA_MANAGER_FRONTEND_DIR").map(PathBuf::from),
            files_base_url: optional_env("MEDIA_MANAGER_FILESTASH_BASE_URL"),
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
            jellyfin_metadata_cache_file: None,
            audiobookshelf_metadata_cache_file: None,
            kavita_metadata_cache_file: None,
            jellyfin_base_url: None,
            jellyfin_public_url: None,
            audiobookshelf_public_url: None,
            kavita_public_url: None,
            jellyfin_api_key_file: None,
            acoustid_api_key_file: None,
            fpcalc_path: None,
            ffprobe_path: None,
            musicbrainz_api_base: None,
            acoustid_api_base: None,
            musicbrainz_request_gap_ms: 0,
            frontend_dir: None,
            files_base_url: None,
            integrations: Vec::new(),
        }
    }

    pub fn database_path(&self) -> PathBuf {
        self.state_dir.join("control.sqlite3")
    }

    pub fn dvd_inbox_path(&self) -> PathBuf {
        self.shared_root.join("_ISO").join("_DVDs")
    }

    pub fn visible_roots(&self, identity: &Identity) -> Vec<VisibleRoot> {
        let personal_base = self.users_root.join(&identity.username);
        let mut roots = Vec::with_capacity(10);
        for (category, folder, shared_label, _) in MEDIA_CATEGORIES {
            let shared_path = self.shared_root.join(folder);
            roots.push(VisibleRoot {
                id: format!("shared-{category}"),
                label: shared_label.to_string(),
                category: category.to_string(),
                scope: RootScope::Shared,
                available: shared_path.is_dir(),
                resolved_path: shared_path.to_string_lossy().into_owned(),
            });
        }
        for (category, folder, _, personal_label) in MEDIA_CATEGORIES {
            let personal_path = personal_base.join(folder);
            roots.push(VisibleRoot {
                id: format!("personal-{category}"),
                label: personal_label.to_string(),
                category: category.to_string(),
                scope: RootScope::Personal,
                available: personal_path.is_dir(),
                resolved_path: personal_path.to_string_lossy().into_owned(),
            });
        }
        roots
    }

    pub fn shared_scan_specs(&self) -> Vec<RootScanSpec> {
        MEDIA_CATEGORIES
            .iter()
            .map(|(category, folder, _, _)| RootScanSpec {
                id: format!("shared-{category}"),
                category: (*category).to_string(),
                scope: RootScope::Shared,
                path: self.shared_root.join(*folder),
                owner_username: None,
            })
            .collect()
    }

    pub fn personal_scan_specs(&self, username: &str) -> Vec<RootScanSpec> {
        let base = self.users_root.join(username);
        MEDIA_CATEGORIES
            .iter()
            .map(|(category, folder, _, _)| RootScanSpec {
                id: format!("personal-{category}"),
                category: (*category).to_string(),
                scope: RootScope::Personal,
                path: base.join(*folder),
                owner_username: Some(username.to_string()),
            })
            .collect()
    }

    pub fn all_scan_specs(&self) -> Vec<RootScanSpec> {
        let mut specs = self.shared_scan_specs();
        if let Ok(entries) = std::fs::read_dir(&self.users_root) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                let Some(username) = path.file_name().and_then(|name| name.to_str()) else {
                    continue;
                };
                if is_valid_username(username) {
                    specs.extend(self.personal_scan_specs(username));
                }
            }
        }
        specs
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

fn optional_env(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

pub fn is_valid_username(value: &str) -> bool {
    valid_identity_component(value)
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
