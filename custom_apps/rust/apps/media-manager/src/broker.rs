use crate::config::{AppConfig, Identity};
use serde::{Deserialize, Serialize};
use std::{
    ffi::CString,
    fmt, fs,
    fs::File,
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
    time::UNIX_EPOCH,
};

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveAction {
    pub source_root_id: String,
    pub source_relative_path: String,
    pub destination_root_id: String,
    pub destination_relative_path: String,
    pub expected: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallSubtitleAction {
    pub staging_filename: String,
    pub destination_root_id: String,
    pub destination_relative_path: String,
    pub expected: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallMetadataSidecarAction {
    pub staging_filename: String,
    pub destination_root_id: String,
    pub destination_relative_path: String,
    pub expected: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplaceArtworkAction {
    pub staging_filename: String,
    pub root_id: String,
    pub source_relative_path: String,
    pub archived_relative_path: String,
    pub replacement_relative_path: String,
    pub expected_source: String,
    pub expected_replacement: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum BrokerAction {
    Move(MoveAction),
    InstallSubtitle(InstallSubtitleAction),
    InstallMetadataSidecar(InstallMetadataSidecarAction),
    ReplaceArtwork(ReplaceArtworkAction),
}

impl From<MoveAction> for BrokerAction {
    fn from(action: MoveAction) -> Self {
        Self::Move(action)
    }
}

impl From<InstallSubtitleAction> for BrokerAction {
    fn from(action: InstallSubtitleAction) -> Self {
        Self::InstallSubtitle(action)
    }
}

impl From<InstallMetadataSidecarAction> for BrokerAction {
    fn from(action: InstallMetadataSidecarAction) -> Self {
        Self::InstallMetadataSidecar(action)
    }
}

impl From<ReplaceArtworkAction> for BrokerAction {
    fn from(action: ReplaceArtworkAction) -> Self {
        Self::ReplaceArtwork(action)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BrokerError(String);

impl BrokerError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for BrokerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for BrokerError {}

pub fn file_fingerprint(path: &Path) -> Result<String, BrokerError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| BrokerError::new(format!("inspect source: {error}")))?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(BrokerError::new(
            "source must be a regular non-symlink file",
        ));
    }
    let modified_ns = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    Ok(format!("{}:{modified_ns}", metadata.len()))
}

#[cfg(target_os = "linux")]
pub fn open_regular_file_beneath(root: &Path, relative_path: &str) -> Result<File, BrokerError> {
    let (parents, leaf) = safe_parent_and_leaf(relative_path)?;
    let root_fd = open_root(root)?;
    let parent_fd = open_directory_chain(root_fd.as_raw_fd(), &parents, false)?;
    let file_fd = open_regular_at(parent_fd.as_raw_fd(), leaf)?;
    Ok(File::from(file_fd))
}

#[cfg(target_os = "linux")]
pub fn open_directory_beneath(root: &Path, relative_path: &str) -> Result<File, BrokerError> {
    let (mut components, leaf) = safe_parent_and_leaf(relative_path)?;
    components.push(leaf);
    let root_fd = open_root(root)?;
    let directory_fd = open_directory_chain(root_fd.as_raw_fd(), &components, false)?;
    Ok(File::from(directory_fd))
}

#[cfg(not(target_os = "linux"))]
pub fn open_regular_file_beneath(_root: &Path, _relative_path: &str) -> Result<File, BrokerError> {
    Err(BrokerError::new(
        "contained media reads require Linux openat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn open_directory_beneath(_root: &Path, _relative_path: &str) -> Result<File, BrokerError> {
    Err(BrokerError::new(
        "contained media directory reads require Linux openat2",
    ))
}

#[cfg(target_os = "linux")]
pub fn apply_broker_action(
    config: &AppConfig,
    username: &str,
    action: &BrokerAction,
) -> Result<(), BrokerError> {
    match action {
        BrokerAction::Move(action) => apply_move(config, username, action),
        BrokerAction::InstallSubtitle(action) => apply_install_subtitle(config, username, action),
        BrokerAction::InstallMetadataSidecar(action) => {
            apply_install_metadata_sidecar(config, username, action)
        }
        BrokerAction::ReplaceArtwork(action) => apply_replace_artwork(config, username, action),
    }
}

#[cfg(target_os = "linux")]
pub fn recover_broker_action(
    config: &AppConfig,
    username: &str,
    action: &BrokerAction,
) -> Result<bool, BrokerError> {
    match action {
        BrokerAction::Move(action) => move_destination_matches(config, username, action),
        BrokerAction::InstallSubtitle(action) => {
            recover_installed_subtitle(config, username, action)
        }
        BrokerAction::InstallMetadataSidecar(action) => {
            recover_installed_metadata_sidecar(config, username, action)
        }
        BrokerAction::ReplaceArtwork(action) => recover_replaced_artwork(config, username, action),
    }
}

#[cfg(target_os = "linux")]
pub fn discard_staged_broker_action(
    config: &AppConfig,
    action: &BrokerAction,
) -> Result<(), BrokerError> {
    match action {
        BrokerAction::Move(_) => Ok(()),
        BrokerAction::InstallSubtitle(action) => {
            discard_staged_file(config, &action.staging_filename, &action.expected)
        }
        BrokerAction::InstallMetadataSidecar(action) => {
            discard_staged_file(config, &action.staging_filename, &action.expected)
        }
        BrokerAction::ReplaceArtwork(action) => discard_staged_file(
            config,
            &action.staging_filename,
            &action.expected_replacement,
        ),
    }
}

#[cfg(not(target_os = "linux"))]
pub fn apply_broker_action(
    _config: &AppConfig,
    _username: &str,
    _action: &BrokerAction,
) -> Result<(), BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn recover_broker_action(
    _config: &AppConfig,
    _username: &str,
    _action: &BrokerAction,
) -> Result<bool, BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn discard_staged_broker_action(
    _config: &AppConfig,
    _action: &BrokerAction,
) -> Result<(), BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(target_os = "linux")]
pub fn apply_move(
    config: &AppConfig,
    username: &str,
    action: &MoveAction,
) -> Result<(), BrokerError> {
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let source_root = config
        .resolve_visible_root(&identity, &action.source_root_id)
        .ok_or_else(|| BrokerError::new("source root ID is not registered"))?;
    let destination_root = config
        .resolve_visible_root(&identity, &action.destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    let (source_parent, source_leaf) = safe_parent_and_leaf(&action.source_relative_path)?;
    let (destination_parent, destination_leaf) =
        safe_parent_and_leaf(&action.destination_relative_path)?;
    if action.source_root_id == action.destination_root_id
        && action.source_relative_path == action.destination_relative_path
    {
        return Err(BrokerError::new("source and destination are identical"));
    }

    let source_root_fd = open_root(Path::new(&source_root.resolved_path))?;
    let destination_root_fd = open_root(Path::new(&destination_root.resolved_path))?;
    let source_parent_fd = open_directory_chain(source_root_fd.as_raw_fd(), &source_parent, false)?;
    let destination_parent_fd =
        open_directory_chain(destination_root_fd.as_raw_fd(), &destination_parent, true)?;
    let actual_fingerprint = fingerprint_at(source_parent_fd.as_raw_fd(), source_leaf)?;
    if actual_fingerprint != action.expected {
        return Err(BrokerError::new(
            "source fingerprint changed after the mutation preview",
        ));
    }

    let source_name = c_string(source_leaf)?;
    let destination_name = c_string(destination_leaf)?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_parent_fd.as_raw_fd(),
            source_name.as_ptr(),
            destination_parent_fd.as_raw_fd(),
            destination_name.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        return Err(BrokerError::new(match error.raw_os_error() {
            Some(libc::EEXIST) => "destination already exists; no file was overwritten".to_string(),
            Some(libc::EXDEV) => {
                "source and destination are on different filesystems; cross-library copy is not enabled"
                    .to_string()
            }
            _ => format!("atomic no-replace move failed: {error}"),
        }));
    }
    sync_directory(source_parent_fd.as_raw_fd())?;
    if source_parent_fd.as_raw_fd() != destination_parent_fd.as_raw_fd() {
        sync_directory(destination_parent_fd.as_raw_fd())?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn move_destination_matches(
    config: &AppConfig,
    username: &str,
    action: &MoveAction,
) -> Result<bool, BrokerError> {
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let destination_root = config
        .resolve_visible_root(&identity, &action.destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    let (destination_parent, destination_leaf) =
        safe_parent_and_leaf(&action.destination_relative_path)?;
    let root_fd = open_root(Path::new(&destination_root.resolved_path))?;
    let parent_fd = match open_directory_chain(root_fd.as_raw_fd(), &destination_parent, false) {
        Ok(parent) => parent,
        Err(_) => return Ok(false),
    };
    match fingerprint_at(parent_fd.as_raw_fd(), destination_leaf) {
        Ok(fingerprint) => Ok(fingerprint == action.expected),
        Err(_) => Ok(false),
    }
}

#[cfg(target_os = "linux")]
pub fn apply_install_subtitle(
    config: &AppConfig,
    username: &str,
    action: &InstallSubtitleAction,
) -> Result<(), BrokerError> {
    validate_subtitle_action(config, username, action)?;
    apply_staged_no_replace(
        config,
        username,
        &action.staging_filename,
        &action.destination_root_id,
        &action.destination_relative_path,
        &action.expected,
    )
}

#[cfg(target_os = "linux")]
pub fn install_subtitle_destination_matches(
    config: &AppConfig,
    username: &str,
    action: &InstallSubtitleAction,
) -> Result<bool, BrokerError> {
    validate_subtitle_action(config, username, action)?;
    staged_destination_matches(
        config,
        username,
        &action.destination_root_id,
        &action.destination_relative_path,
        &action.expected,
    )
}

#[cfg(target_os = "linux")]
fn recover_installed_subtitle(
    config: &AppConfig,
    username: &str,
    action: &InstallSubtitleAction,
) -> Result<bool, BrokerError> {
    recover_staged_no_replace(
        config,
        username,
        &action.staging_filename,
        &action.destination_root_id,
        &action.destination_relative_path,
        &action.expected,
    )
}

#[cfg(target_os = "linux")]
fn validate_subtitle_action(
    config: &AppConfig,
    username: &str,
    action: &InstallSubtitleAction,
) -> Result<(), BrokerError> {
    if !safe_component(&action.staging_filename) {
        return Err(BrokerError::new("staging filename is not a safe component"));
    }
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let destination_root = config
        .resolve_visible_root(&identity, &action.destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    if destination_root.category != "videos" {
        return Err(BrokerError::new(
            "subtitle sidecars may only be installed in a video root",
        ));
    }
    let (_, destination_leaf) = safe_parent_and_leaf(&action.destination_relative_path)?;
    let valid_extension = [".srt", ".vtt", ".ass"]
        .iter()
        .any(|extension| destination_leaf.to_ascii_lowercase().ends_with(extension));
    if !valid_extension {
        return Err(BrokerError::new(
            "subtitle destination must use .srt, .vtt, or .ass",
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn apply_install_metadata_sidecar(
    config: &AppConfig,
    username: &str,
    action: &InstallMetadataSidecarAction,
) -> Result<(), BrokerError> {
    validate_metadata_sidecar_action(config, username, action)?;
    apply_staged_no_replace(
        config,
        username,
        &action.staging_filename,
        &action.destination_root_id,
        &action.destination_relative_path,
        &action.expected,
    )
}

#[cfg(target_os = "linux")]
fn recover_installed_metadata_sidecar(
    config: &AppConfig,
    username: &str,
    action: &InstallMetadataSidecarAction,
) -> Result<bool, BrokerError> {
    validate_metadata_sidecar_action(config, username, action)?;
    recover_staged_no_replace(
        config,
        username,
        &action.staging_filename,
        &action.destination_root_id,
        &action.destination_relative_path,
        &action.expected,
    )
}

#[cfg(target_os = "linux")]
fn validate_metadata_sidecar_action(
    config: &AppConfig,
    username: &str,
    action: &InstallMetadataSidecarAction,
) -> Result<(), BrokerError> {
    if !safe_component(&action.staging_filename) {
        return Err(BrokerError::new("staging filename is not a safe component"));
    }
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let destination_root = config
        .resolve_visible_root(&identity, &action.destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    if !["videos", "music", "audiobooks", "books"].contains(&destination_root.category.as_str()) {
        return Err(BrokerError::new(
            "metadata sidecars may only be installed in a media root",
        ));
    }
    let (_, destination_leaf) = safe_parent_and_leaf(&action.destination_relative_path)?;
    if ![".nfo", ".opf"]
        .iter()
        .any(|extension| destination_leaf.to_ascii_lowercase().ends_with(extension))
    {
        return Err(BrokerError::new(
            "metadata destination must use .nfo or .opf",
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn apply_replace_artwork(
    config: &AppConfig,
    username: &str,
    action: &ReplaceArtworkAction,
) -> Result<(), BrokerError> {
    validate_replace_artwork_action(config, username, action)?;
    if recover_replaced_artwork(config, username, action)? {
        return Ok(());
    }
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let root = config
        .resolve_visible_root(&identity, &action.root_id)
        .ok_or_else(|| BrokerError::new("artwork root ID is not registered"))?;
    let (source_parent, source_leaf) = safe_parent_and_leaf(&action.source_relative_path)?;
    let (archive_parent, archive_leaf) = safe_parent_and_leaf(&action.archived_relative_path)?;
    let (replacement_parent, replacement_leaf) =
        safe_parent_and_leaf(&action.replacement_relative_path)?;
    let root_fd = open_root(Path::new(&root.resolved_path))?;
    let source_parent_fd = open_directory_chain(root_fd.as_raw_fd(), &source_parent, false)?;
    let archive_parent_fd = open_directory_chain(root_fd.as_raw_fd(), &archive_parent, true)?;
    let replacement_parent_fd =
        open_directory_chain(root_fd.as_raw_fd(), &replacement_parent, false)?;
    let source = fingerprint_optional_at(source_parent_fd.as_raw_fd(), source_leaf)?;
    let archived = fingerprint_optional_at(archive_parent_fd.as_raw_fd(), archive_leaf)?;
    let replacement = fingerprint_optional_at(replacement_parent_fd.as_raw_fd(), replacement_leaf)?;
    let replacement_is_source = action.source_relative_path == action.replacement_relative_path;
    let initial = source.as_deref() == Some(action.expected_source.as_str())
        && archived.is_none()
        && (replacement_is_source || replacement.is_none());
    let archived_only = source.is_none()
        && archived.as_deref() == Some(action.expected_source.as_str())
        && replacement.is_none();
    if !initial && !archived_only {
        if source.is_none()
            && archived.as_deref() == Some(action.expected_source.as_str())
            && replacement.is_some()
        {
            let rollback = rename_noreplace(
                archive_parent_fd.as_raw_fd(),
                archive_leaf,
                source_parent_fd.as_raw_fd(),
                source_leaf,
                "restore archived artwork after replacement conflict",
            );
            if rollback.is_ok() {
                sync_directory(archive_parent_fd.as_raw_fd())?;
                sync_directory(source_parent_fd.as_raw_fd())?;
            }
        }
        return Err(BrokerError::new(
            "artwork replacement inputs changed after the mutation preview",
        ));
    }

    let (staging_root_fd, temporary_name) = prepare_staged_copy(
        config,
        &action.staging_filename,
        &action.expected_replacement,
        replacement_parent_fd.as_raw_fd(),
    )?;
    if initial {
        if let Err(error) = rename_noreplace(
            source_parent_fd.as_raw_fd(),
            source_leaf,
            archive_parent_fd.as_raw_fd(),
            archive_leaf,
            "archive current artwork",
        ) {
            unlink_at_if_present(replacement_parent_fd.as_raw_fd(), &temporary_name);
            return Err(error);
        }
        sync_directory(source_parent_fd.as_raw_fd())?;
        sync_directory(archive_parent_fd.as_raw_fd())?;
    }
    if let Err(install_error) = rename_noreplace(
        replacement_parent_fd.as_raw_fd(),
        &temporary_name,
        replacement_parent_fd.as_raw_fd(),
        replacement_leaf,
        "install replacement artwork",
    ) {
        unlink_at_if_present(replacement_parent_fd.as_raw_fd(), &temporary_name);
        let rollback = rename_noreplace(
            archive_parent_fd.as_raw_fd(),
            archive_leaf,
            source_parent_fd.as_raw_fd(),
            source_leaf,
            "restore archived artwork after install failure",
        );
        if let Err(rollback_error) = rollback {
            return Err(BrokerError::new(format!(
                "{install_error}; the original remains preserved at the archive path because rollback failed: {rollback_error}"
            )));
        }
        sync_directory(archive_parent_fd.as_raw_fd())?;
        sync_directory(source_parent_fd.as_raw_fd())?;
        return Err(install_error);
    }
    sync_directory(replacement_parent_fd.as_raw_fd())?;
    unlink_regular_at(staging_root_fd.as_raw_fd(), &action.staging_filename)?;
    sync_directory(staging_root_fd.as_raw_fd())
}

#[cfg(target_os = "linux")]
fn recover_replaced_artwork(
    config: &AppConfig,
    username: &str,
    action: &ReplaceArtworkAction,
) -> Result<bool, BrokerError> {
    validate_replace_artwork_action(config, username, action)?;
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let root = config
        .resolve_visible_root(&identity, &action.root_id)
        .ok_or_else(|| BrokerError::new("artwork root ID is not registered"))?;
    let (archive_parent, archive_leaf) = safe_parent_and_leaf(&action.archived_relative_path)?;
    let (replacement_parent, replacement_leaf) =
        safe_parent_and_leaf(&action.replacement_relative_path)?;
    let root_fd = open_root(Path::new(&root.resolved_path))?;
    let archive_parent_fd = match open_directory_chain(root_fd.as_raw_fd(), &archive_parent, false)
    {
        Ok(parent) => parent,
        Err(_) => return Ok(false),
    };
    let replacement_parent_fd =
        open_directory_chain(root_fd.as_raw_fd(), &replacement_parent, false)?;
    if fingerprint_optional_at(archive_parent_fd.as_raw_fd(), archive_leaf)?.as_deref()
        != Some(action.expected_source.as_str())
        || fingerprint_optional_at(replacement_parent_fd.as_raw_fd(), replacement_leaf)?.as_deref()
            != Some(action.expected_replacement.as_str())
    {
        return Ok(false);
    }
    let staging_root_fd = open_root(&config.state_dir.join("provider-staging"))?;
    match fingerprint_optional_at(staging_root_fd.as_raw_fd(), &action.staging_filename)? {
        Some(fingerprint) if fingerprint == action.expected_replacement => {
            unlink_regular_at(staging_root_fd.as_raw_fd(), &action.staging_filename)?;
            sync_directory(staging_root_fd.as_raw_fd())?;
        }
        Some(_) => {
            return Err(BrokerError::new(
                "completed artwork replacement has a changed staged recovery file",
            ))
        }
        None => {}
    }
    Ok(true)
}

#[cfg(target_os = "linux")]
fn validate_replace_artwork_action(
    config: &AppConfig,
    username: &str,
    action: &ReplaceArtworkAction,
) -> Result<(), BrokerError> {
    if !safe_component(&action.staging_filename) {
        return Err(BrokerError::new("staging filename is not a safe component"));
    }
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let root = config
        .resolve_visible_root(&identity, &action.root_id)
        .ok_or_else(|| BrokerError::new("artwork root ID is not registered"))?;
    if !["videos", "music", "audiobooks", "books"].contains(&root.category.as_str()) {
        return Err(BrokerError::new(
            "artwork may only be installed in a media root",
        ));
    }
    let (source_parent, source_leaf) = safe_parent_and_leaf(&action.source_relative_path)?;
    let (archive_parent, _) = safe_parent_and_leaf(&action.archived_relative_path)?;
    let (replacement_parent, replacement_leaf) =
        safe_parent_and_leaf(&action.replacement_relative_path)?;
    let mut expected_archive_parent = source_parent.clone();
    expected_archive_parent.push("superseded");
    if archive_parent != expected_archive_parent || replacement_parent != source_parent {
        return Err(BrokerError::new(
            "artwork replacement paths must remain beside the source and in its superseded child",
        ));
    }
    if action.source_relative_path == action.archived_relative_path
        || action.archived_relative_path == action.replacement_relative_path
    {
        return Err(BrokerError::new(
            "artwork replacement paths must be distinct",
        ));
    }
    if source_leaf.rsplit_once('.').is_none() {
        return Err(BrokerError::new(
            "artwork source must have a file extension",
        ));
    }
    let valid_extension = [".jpg", ".jpeg", ".png", ".gif", ".webp"]
        .iter()
        .any(|extension| replacement_leaf.to_ascii_lowercase().ends_with(extension));
    if !valid_extension {
        return Err(BrokerError::new(
            "artwork destination must use .jpg, .jpeg, .png, .gif, or .webp",
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn apply_staged_no_replace(
    config: &AppConfig,
    username: &str,
    staging_filename: &str,
    destination_root_id: &str,
    destination_relative_path: &str,
    expected: &str,
) -> Result<(), BrokerError> {
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let destination_root = config
        .resolve_visible_root(&identity, destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    let (destination_parent, destination_leaf) = safe_parent_and_leaf(destination_relative_path)?;
    let staging_root_fd = open_root(&config.state_dir.join("provider-staging"))?;
    let source_fd = open_regular_at(staging_root_fd.as_raw_fd(), staging_filename)?;
    let source_stat = file_stat(source_fd.as_raw_fd())?;
    if fingerprint_from_stat(&source_stat) != expected {
        return Err(BrokerError::new(
            "staged file changed after the mutation preview",
        ));
    }
    let destination_root_fd = open_root(Path::new(&destination_root.resolved_path))?;
    let destination_parent_fd =
        open_directory_chain(destination_root_fd.as_raw_fd(), &destination_parent, true)?;
    let (temporary_name, temporary_fd) = create_temporary_file(destination_parent_fd.as_raw_fd())?;
    let mut source = File::from(source_fd);
    let mut temporary = File::from(temporary_fd);
    let install_result = (|| -> Result<(), BrokerError> {
        io::copy(&mut source, &mut temporary)
            .map_err(|error| BrokerError::new(format!("copy staged file: {error}")))?;
        let times = [
            libc::timespec {
                tv_sec: source_stat.st_atime,
                tv_nsec: source_stat.st_atime_nsec,
            },
            libc::timespec {
                tv_sec: source_stat.st_mtime,
                tv_nsec: source_stat.st_mtime_nsec,
            },
        ];
        if unsafe { libc::futimens(temporary.as_raw_fd(), times.as_ptr()) } != 0 {
            return Err(BrokerError::new(format!(
                "preserve staged file timestamp: {}",
                std::io::Error::last_os_error()
            )));
        }
        temporary
            .sync_all()
            .map_err(|error| BrokerError::new(format!("sync staged file copy: {error}")))?;
        drop(temporary);

        let temporary_name = c_string(&temporary_name)?;
        let destination_name = c_string(destination_leaf)?;
        let renamed = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                destination_parent_fd.as_raw_fd(),
                temporary_name.as_ptr(),
                destination_parent_fd.as_raw_fd(),
                destination_name.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if renamed != 0 {
            let error = std::io::Error::last_os_error();
            return Err(BrokerError::new(match error.raw_os_error() {
                Some(libc::EEXIST) => {
                    "destination sidecar already exists; no file was overwritten".to_string()
                }
                _ => format!("atomic no-replace sidecar install failed: {error}"),
            }));
        }
        sync_directory(destination_parent_fd.as_raw_fd())?;
        unlink_regular_at(staging_root_fd.as_raw_fd(), staging_filename)?;
        sync_directory(staging_root_fd.as_raw_fd())?;
        Ok(())
    })();
    if install_result.is_err() {
        unlink_at_if_present(destination_parent_fd.as_raw_fd(), &temporary_name);
    }
    install_result
}

#[cfg(target_os = "linux")]
fn staged_destination_matches(
    config: &AppConfig,
    username: &str,
    destination_root_id: &str,
    destination_relative_path: &str,
    expected: &str,
) -> Result<bool, BrokerError> {
    let identity = Identity::try_new(username, ["users"])
        .map_err(|_| BrokerError::new("plan owner is not a safe identity component"))?;
    let destination_root = config
        .resolve_visible_root(&identity, destination_root_id)
        .ok_or_else(|| BrokerError::new("destination root ID is not registered"))?;
    let (destination_parent, destination_leaf) = safe_parent_and_leaf(destination_relative_path)?;
    let root_fd = open_root(Path::new(&destination_root.resolved_path))?;
    let parent_fd = match open_directory_chain(root_fd.as_raw_fd(), &destination_parent, false) {
        Ok(parent) => parent,
        Err(_) => return Ok(false),
    };
    match fingerprint_at(parent_fd.as_raw_fd(), destination_leaf) {
        Ok(fingerprint) => Ok(fingerprint == expected),
        Err(_) => Ok(false),
    }
}

#[cfg(target_os = "linux")]
fn recover_staged_no_replace(
    config: &AppConfig,
    username: &str,
    staging_filename: &str,
    destination_root_id: &str,
    destination_relative_path: &str,
    expected: &str,
) -> Result<bool, BrokerError> {
    if !staged_destination_matches(
        config,
        username,
        destination_root_id,
        destination_relative_path,
        expected,
    )? {
        return Ok(false);
    }
    let staging_root_fd = open_root(&config.state_dir.join("provider-staging"))?;
    match fingerprint_at(staging_root_fd.as_raw_fd(), staging_filename) {
        Ok(fingerprint) if fingerprint == expected => {
            unlink_regular_at(staging_root_fd.as_raw_fd(), staging_filename)?;
            sync_directory(staging_root_fd.as_raw_fd())?;
        }
        Ok(_) => {
            return Err(BrokerError::new(
                "installed sidecar matches but its staged recovery file changed",
            ))
        }
        Err(_) => {}
    }
    Ok(true)
}

#[cfg(target_os = "linux")]
fn discard_staged_file(
    config: &AppConfig,
    staging_filename: &str,
    expected: &str,
) -> Result<(), BrokerError> {
    if !safe_component(staging_filename) {
        return Err(BrokerError::new("staging filename is not a safe component"));
    }
    let staging_root_fd = open_root(&config.state_dir.join("provider-staging"))?;
    let leaf = c_string(staging_filename)?;
    let fd = unsafe {
        libc::openat(
            staging_root_fd.as_raw_fd(),
            leaf.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    let file = match owned_fd(fd) {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(libc::ENOENT) => return Ok(()),
        Err(error) => {
            return Err(BrokerError::new(format!(
                "open expired staged file: {error}"
            )))
        }
    };
    let stat = file_stat(file.as_raw_fd())?;
    if fingerprint_from_stat(&stat) != expected {
        return Err(BrokerError::new(
            "expired staged file changed after the mutation preview",
        ));
    }
    if unsafe { libc::unlinkat(staging_root_fd.as_raw_fd(), leaf.as_ptr(), 0) } != 0 {
        return Err(BrokerError::new(format!(
            "remove expired staged file: {}",
            std::io::Error::last_os_error()
        )));
    }
    sync_directory(staging_root_fd.as_raw_fd())
}

#[cfg(not(target_os = "linux"))]
pub fn apply_move(
    _config: &AppConfig,
    _username: &str,
    _action: &MoveAction,
) -> Result<(), BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn move_destination_matches(
    _config: &AppConfig,
    _username: &str,
    _action: &MoveAction,
) -> Result<bool, BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn apply_install_subtitle(
    _config: &AppConfig,
    _username: &str,
    _action: &InstallSubtitleAction,
) -> Result<(), BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(not(target_os = "linux"))]
pub fn install_subtitle_destination_matches(
    _config: &AppConfig,
    _username: &str,
    _action: &InstallSubtitleAction,
) -> Result<bool, BrokerError> {
    Err(BrokerError::new(
        "the mutation broker requires Linux openat2 and renameat2",
    ))
}

#[cfg(target_os = "linux")]
fn safe_parent_and_leaf(path: &str) -> Result<(Vec<&str>, &str), BrokerError> {
    if path.is_empty() || path.len() > 4096 || path.starts_with('/') || path.contains('\0') {
        return Err(BrokerError::new(
            "operation path is not a safe relative path",
        ));
    }
    let components = path.split('/').collect::<Vec<_>>();
    if components
        .iter()
        .any(|component| !safe_component(component))
    {
        return Err(BrokerError::new(
            "operation path contains an unsafe component",
        ));
    }
    let (leaf, parents) = components
        .split_last()
        .ok_or_else(|| BrokerError::new("operation path has no leaf component"))?;
    Ok((parents.to_vec(), leaf))
}

#[cfg(target_os = "linux")]
fn safe_component(component: &str) -> bool {
    !component.is_empty()
        && component != "."
        && component != ".."
        && component.len() <= 255
        && !component.contains(['/', '\\', '\0'])
}

#[cfg(target_os = "linux")]
fn c_string(value: &str) -> Result<CString, BrokerError> {
    CString::new(value.as_bytes()).map_err(|_| BrokerError::new("path component contains NUL"))
}

#[cfg(target_os = "linux")]
fn open_root(path: &Path) -> Result<OwnedFd, BrokerError> {
    use std::os::unix::ffi::OsStrExt;

    let path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| BrokerError::new("configured root contains NUL"))?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    owned_fd(fd).map_err(|error| BrokerError::new(format!("open registered root: {error}")))
}

#[cfg(target_os = "linux")]
fn open_directory_chain(
    root_fd: RawFd,
    components: &[&str],
    create: bool,
) -> Result<OwnedFd, BrokerError> {
    let duplicated = unsafe { libc::fcntl(root_fd, libc::F_DUPFD_CLOEXEC, 3) };
    let mut current = owned_fd(duplicated)
        .map_err(|error| BrokerError::new(format!("duplicate root descriptor: {error}")))?;
    for component in components {
        let component = c_string(component)?;
        match openat2_directory(current.as_raw_fd(), &component) {
            Ok(next) => current = next,
            Err(error) if create && error.raw_os_error() == Some(libc::ENOENT) => {
                let created =
                    unsafe { libc::mkdirat(current.as_raw_fd(), component.as_ptr(), 0o770) };
                if created != 0
                    && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
                {
                    return Err(BrokerError::new(format!(
                        "create destination directory: {}",
                        std::io::Error::last_os_error()
                    )));
                }
                current = openat2_directory(current.as_raw_fd(), &component).map_err(|error| {
                    BrokerError::new(format!("open created destination directory: {error}"))
                })?;
            }
            Err(error) => {
                return Err(BrokerError::new(format!(
                    "open contained directory component: {error}"
                )))
            }
        }
    }
    Ok(current)
}

#[cfg(target_os = "linux")]
fn openat2_directory(parent_fd: RawFd, component: &CString) -> std::io::Result<OwnedFd> {
    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }
    const RESOLVE_NO_XDEV: u64 = 0x01;
    const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
    const RESOLVE_NO_SYMLINKS: u64 = 0x04;
    const RESOLVE_BENEATH: u64 = 0x08;
    let how = OpenHow {
        flags: (libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC) as u64,
        mode: 0,
        resolve: RESOLVE_NO_XDEV | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS | RESOLVE_BENEATH,
    };
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            parent_fd,
            component.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        ) as libc::c_int
    };
    owned_fd(fd)
}

#[cfg(target_os = "linux")]
fn fingerprint_at(parent_fd: RawFd, leaf: &str) -> Result<String, BrokerError> {
    let leaf = c_string(leaf)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let result = unsafe {
        libc::fstatat(
            parent_fd,
            leaf.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result != 0 {
        return Err(BrokerError::new(format!(
            "inspect source leaf: {}",
            std::io::Error::last_os_error()
        )));
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(BrokerError::new(
            "source must be a regular non-symlink file",
        ));
    }
    Ok(fingerprint_from_stat(&stat))
}

#[cfg(target_os = "linux")]
fn fingerprint_optional_at(parent_fd: RawFd, leaf: &str) -> Result<Option<String>, BrokerError> {
    let leaf = c_string(leaf)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let result = unsafe {
        libc::fstatat(
            parent_fd,
            leaf.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) {
            return Ok(None);
        }
        return Err(BrokerError::new(format!("inspect artwork leaf: {error}")));
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(BrokerError::new(
            "artwork path must be a regular non-symlink file",
        ));
    }
    Ok(Some(fingerprint_from_stat(&stat)))
}

#[cfg(target_os = "linux")]
fn prepare_staged_copy(
    config: &AppConfig,
    staging_filename: &str,
    expected: &str,
    destination_parent_fd: RawFd,
) -> Result<(OwnedFd, String), BrokerError> {
    let staging_root_fd = open_root(&config.state_dir.join("provider-staging"))?;
    let source_fd = open_regular_at(staging_root_fd.as_raw_fd(), staging_filename)?;
    let source_stat = file_stat(source_fd.as_raw_fd())?;
    if fingerprint_from_stat(&source_stat) != expected {
        return Err(BrokerError::new(
            "staged artwork changed after the mutation preview",
        ));
    }
    let (temporary_name, temporary_fd) = create_temporary_file(destination_parent_fd)?;
    let mut source = File::from(source_fd);
    let mut temporary = File::from(temporary_fd);
    let copy_result = (|| -> Result<(), BrokerError> {
        io::copy(&mut source, &mut temporary)
            .map_err(|error| BrokerError::new(format!("copy staged artwork: {error}")))?;
        let times = [
            libc::timespec {
                tv_sec: source_stat.st_atime,
                tv_nsec: source_stat.st_atime_nsec,
            },
            libc::timespec {
                tv_sec: source_stat.st_mtime,
                tv_nsec: source_stat.st_mtime_nsec,
            },
        ];
        if unsafe { libc::futimens(temporary.as_raw_fd(), times.as_ptr()) } != 0 {
            return Err(BrokerError::new(format!(
                "preserve staged artwork timestamp: {}",
                std::io::Error::last_os_error()
            )));
        }
        temporary
            .sync_all()
            .map_err(|error| BrokerError::new(format!("sync staged artwork copy: {error}")))
    })();
    if let Err(error) = copy_result {
        drop(temporary);
        unlink_at_if_present(destination_parent_fd, &temporary_name);
        return Err(error);
    }
    drop(temporary);
    Ok((staging_root_fd, temporary_name))
}

#[cfg(target_os = "linux")]
fn rename_noreplace(
    source_parent_fd: RawFd,
    source_leaf: &str,
    destination_parent_fd: RawFd,
    destination_leaf: &str,
    operation: &str,
) -> Result<(), BrokerError> {
    let source_name = c_string(source_leaf)?;
    let destination_name = c_string(destination_leaf)?;
    let renamed = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_parent_fd,
            source_name.as_ptr(),
            destination_parent_fd,
            destination_name.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if renamed == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    Err(BrokerError::new(match error.raw_os_error() {
        Some(libc::EEXIST) => {
            format!("{operation}: destination already exists; no file was overwritten")
        }
        _ => format!("{operation}: {error}"),
    }))
}

#[cfg(target_os = "linux")]
fn fingerprint_from_stat(stat: &libc::stat) -> String {
    let modified_ns =
        (stat.st_mtime as i128 * 1_000_000_000i128 + stat.st_mtime_nsec as i128).max(0) as u128;
    format!("{}:{modified_ns}", stat.st_size)
}

#[cfg(target_os = "linux")]
fn file_stat(fd: RawFd) -> Result<libc::stat, BrokerError> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(BrokerError::new(format!(
            "inspect opened file: {}",
            std::io::Error::last_os_error()
        )));
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(BrokerError::new("opened file is not a regular file"));
    }
    Ok(stat)
}

#[cfg(target_os = "linux")]
fn open_regular_at(parent_fd: RawFd, leaf: &str) -> Result<OwnedFd, BrokerError> {
    let leaf = c_string(leaf)?;
    let fd = unsafe {
        libc::openat(
            parent_fd,
            leaf.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    let fd = owned_fd(fd)
        .map_err(|error| BrokerError::new(format!("open contained regular file: {error}")))?;
    file_stat(fd.as_raw_fd())?;
    Ok(fd)
}

#[cfg(target_os = "linux")]
fn create_temporary_file(parent_fd: RawFd) -> Result<(String, OwnedFd), BrokerError> {
    for _ in 0..16 {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let name = format!(".media-manager-{}-{sequence}.partial", std::process::id());
        let c_name = c_string(&name)?;
        let fd = unsafe {
            libc::openat(
                parent_fd,
                c_name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o660,
            )
        };
        match owned_fd(fd) {
            Ok(fd) => return Ok((name, fd)),
            Err(error) if error.raw_os_error() == Some(libc::EEXIST) => continue,
            Err(error) => {
                return Err(BrokerError::new(format!(
                    "create temporary subtitle: {error}"
                )))
            }
        }
    }
    Err(BrokerError::new(
        "could not allocate a unique temporary subtitle name",
    ))
}

#[cfg(target_os = "linux")]
fn unlink_regular_at(parent_fd: RawFd, leaf: &str) -> Result<(), BrokerError> {
    file_stat(open_regular_at(parent_fd, leaf)?.as_raw_fd())?;
    let leaf = c_string(leaf)?;
    if unsafe { libc::unlinkat(parent_fd, leaf.as_ptr(), 0) } != 0 {
        return Err(BrokerError::new(format!(
            "remove staged subtitle: {}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn unlink_at_if_present(parent_fd: RawFd, leaf: &str) {
    if let Ok(leaf) = c_string(leaf) {
        unsafe {
            libc::unlinkat(parent_fd, leaf.as_ptr(), 0);
        }
    }
}

#[cfg(target_os = "linux")]
fn sync_directory(fd: RawFd) -> Result<(), BrokerError> {
    let result = unsafe { libc::fsync(fd) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        // O_PATH descriptors cannot be fsynced on all supported kernels. The
        // rename itself is still atomic; the queue journal provides recovery.
        if !matches!(error.raw_os_error(), Some(libc::EBADF | libc::EINVAL)) {
            return Err(BrokerError::new(format!(
                "sync destination directory: {error}"
            )));
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn owned_fd(fd: libc::c_int) -> std::io::Result<OwnedFd> {
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}
