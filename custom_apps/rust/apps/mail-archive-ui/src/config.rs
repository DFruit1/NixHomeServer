use super::*;

#[derive(Clone, Debug)]
pub(super) struct AppConfig {
    pub(super) address: Arc<str>,
    pub(super) port: u16,
    pub(super) data_dir: Arc<str>,
    pub(super) store_root: Arc<str>,
    pub(super) account_state_root: Arc<str>,
    pub(super) runtime_dir: Arc<str>,
    pub(super) lock_dir: Arc<str>,
    pub(super) paperless_consume_root: Option<Arc<str>>,
    pub(super) paperless_handoff_staging_root: Option<Arc<str>>,
    pub(super) paperless_database_path: Option<Arc<str>>,
    pub(super) visible_mirror_read_group: Option<Arc<str>>,
    pub(super) default_tags: Arc<[String]>,
    pub(super) frontend_dist_dir: Arc<str>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FrontendMode {
    Production,
    Vite,
}

pub(super) fn load_config() -> AppConfig {
    let address =
        env::var("MAIL_ARCHIVE_UI_ADDRESS").unwrap_or_else(|_| DEFAULT_ADDRESS.to_string());
    let port = env::var("MAIL_ARCHIVE_UI_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);
    let data_dir =
        env::var("MAIL_ARCHIVE_UI_DATA_DIR").unwrap_or_else(|_| DEFAULT_DATA_DIR.to_string());
    let store_root =
        env::var("MAIL_ARCHIVE_UI_STORE_ROOT").unwrap_or_else(|_| DEFAULT_STORE_ROOT.to_string());
    let account_state_root = env::var("MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT")
        .unwrap_or_else(|_| format!("{data_dir}/accounts"));
    let runtime_dir =
        env::var("MAIL_ARCHIVE_UI_RUNTIME_DIR").unwrap_or_else(|_| DEFAULT_RUNTIME_DIR.to_string());
    let lock_dir =
        env::var("MAIL_ARCHIVE_UI_LOCK_DIR").unwrap_or_else(|_| DEFAULT_LOCK_DIR.to_string());
    let paperless_consume_root = env::var("MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let paperless_handoff_staging_root = env::var("MAIL_ARCHIVE_UI_PAPERLESS_HANDOFF_STAGING_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let paperless_database_path = env::var("MAIL_ARCHIVE_UI_PAPERLESS_DATABASE_PATH")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let visible_mirror_read_group = env::var("MAIL_ARCHIVE_UI_VISIBLE_MIRROR_READ_GROUP")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let default_tags = env::var("MAIL_ARCHIVE_UI_DEFAULT_TAGS")
        .ok()
        .map(|value| {
            value
                .split(';')
                .map(str::trim)
                .filter(|tag| !tag.is_empty())
                .map(ToString::to_string)
                .collect::<Vec<_>>()
        })
        .filter(|tags| !tags.is_empty())
        .unwrap_or_else(|| vec!["new".to_string()]);
    let frontend_dist_dir = env::var("MAIL_ARCHIVE_UI_FRONTEND_DIST_DIR")
        .unwrap_or_else(|_| DEFAULT_FRONTEND_DIST_DIR.to_string());

    AppConfig {
        address: Arc::<str>::from(address),
        port,
        data_dir: Arc::<str>::from(data_dir),
        store_root: Arc::<str>::from(store_root),
        account_state_root: Arc::<str>::from(account_state_root),
        runtime_dir: Arc::<str>::from(runtime_dir),
        lock_dir: Arc::<str>::from(lock_dir),
        paperless_consume_root,
        paperless_handoff_staging_root,
        paperless_database_path,
        visible_mirror_read_group,
        default_tags: Arc::from(default_tags),
        frontend_dist_dir: Arc::<str>::from(frontend_dist_dir),
    }
}

pub(super) fn ensure_app_layout(config: &AppConfig) -> Result<(), String> {
    for directory in [
        config.data_dir.as_ref(),
        config.account_state_root.as_ref(),
        config.runtime_dir.as_ref(),
        config.lock_dir.as_ref(),
    ] {
        fs::create_dir_all(directory)
            .map_err(|error| format!("failed to create {directory}: {error}"))?;
    }

    Ok(())
}

pub(super) fn install_filesystem_sandbox(config: &AppConfig) {
    #[cfg(target_os = "linux")]
    match restrict_filesystem(config) {
        Ok(status) => log_landlock_status(status),
        Err(error) => eprintln!("mail-archive-ui Landlock sandbox disabled: {error}"),
    }
}

#[cfg(not(target_os = "linux"))]
pub(super) fn install_filesystem_sandbox(_config: &AppConfig) {}

#[cfg(target_os = "linux")]
pub(super) fn restrict_filesystem(config: &AppConfig) -> Result<RestrictionStatus, String> {
    let abi = ABI::V6;
    let read_access = AccessFs::from_read(abi) | AccessFs::Execute;
    let write_access = AccessFs::from_all(abi);
    let (read_only_roots, read_write_roots) = landlock_roots(config);

    Ruleset::default()
        .handle_access(AccessFs::from_all(abi))
        .map_err(|error| format!("failed to configure Landlock access set: {error}"))?
        .create()
        .map_err(|error| format!("failed to create Landlock ruleset: {error}"))?
        .add_rules(path_beneath_rules(
            read_only_roots.iter().map(PathBuf::as_path),
            read_access,
        ))
        .map_err(|error| format!("failed to add read-only Landlock rules: {error}"))?
        .add_rules(path_beneath_rules(
            read_write_roots.iter().map(PathBuf::as_path),
            write_access,
        ))
        .map_err(|error| format!("failed to add read-write Landlock rules: {error}"))?
        .restrict_self()
        .map_err(|error| format!("failed to apply Landlock sandbox: {error}"))
}

#[cfg(target_os = "linux")]
pub(super) fn log_landlock_status(status: RestrictionStatus) {
    let label = match status.ruleset {
        RulesetStatus::FullyEnforced => "fully enforced",
        RulesetStatus::PartiallyEnforced => "partially enforced",
        RulesetStatus::NotEnforced => "not enforced",
    };
    eprintln!("mail-archive-ui Landlock sandbox: {label}");
}

pub(super) fn landlock_roots(config: &AppConfig) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let read_only_roots = dedupe_paths([
        Some(PathBuf::from("/nix/store")),
        Some(PathBuf::from("/etc")),
        Some(PathBuf::from("/run/current-system")),
        Some(PathBuf::from("/run/systemd/resolve")),
        Some(PathBuf::from("/dev/null")),
        Some(PathBuf::from("/dev/random")),
        Some(PathBuf::from("/dev/urandom")),
        config.paperless_database_path.as_deref().map(PathBuf::from),
    ]);
    let read_write_roots = dedupe_paths([
        Some(PathBuf::from(config.data_dir.as_ref())),
        Some(PathBuf::from(config.store_root.as_ref())),
        Some(PathBuf::from(config.account_state_root.as_ref())),
        Some(PathBuf::from(config.runtime_dir.as_ref())),
        Some(PathBuf::from(config.lock_dir.as_ref())),
        config.paperless_consume_root.as_deref().map(PathBuf::from),
        config
            .paperless_handoff_staging_root
            .as_deref()
            .map(PathBuf::from),
    ]);

    (read_only_roots, read_write_roots)
}

pub(super) fn dedupe_paths<const N: usize>(paths: [Option<PathBuf>; N]) -> Vec<PathBuf> {
    let mut deduped = Vec::new();
    for path in paths.into_iter().flatten() {
        if deduped.iter().any(|existing| existing == &path) {
            continue;
        }
        deduped.push(path);
    }
    deduped
}
