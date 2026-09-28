use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};
use tauri_plugin_dialog::DialogExt;

use crate::models::*;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<MobileFiles<R>> {
    Ok(MobileFiles(app.clone()))
}

pub struct MobileFiles<R: Runtime>(AppHandle<R>);

impl<R: Runtime> MobileFiles<R> {
    pub fn acquire_sync_lock(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn release_sync_lock(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn release_local_folder(&self, _folder_uri: String) -> crate::Result<()> {
        Ok(())
    }

    pub fn create_temp_file(&self) -> crate::Result<String> {
        Ok(std::env::temp_dir()
            .join(format!("filesync-{}.stage", uuid::Uuid::new_v4()))
            .to_string_lossy()
            .into_owned())
    }

    pub fn pick_local_folder(&self) -> crate::Result<Option<PickedFolder>> {
        let Some(path) = self.0.dialog().file().blocking_pick_folder() else {
            return Ok(None);
        };
        let path = path
            .into_path()
            .map_err(|error| crate::Error::Operation(error.to_string()))?;
        let display_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Selected folder")
            .to_owned();
        Ok(Some(PickedFolder {
            uri: path.to_string_lossy().into_owned(),
            display_name,
        }))
    }

    pub fn ensure_all_files_access(&self) -> crate::Result<bool> {
        Ok(true)
    }

    pub fn request_all_files_access(&self) -> crate::Result<bool> {
        Ok(true)
    }

    pub fn create_local_folder(&self, subpath: String) -> crate::Result<PickedFolder> {
        let root = std::env::temp_dir().join("filesync-auto");
        let path = root.join(&subpath);
        fs::create_dir_all(&path)?;
        let display_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Selected folder")
            .to_owned();
        Ok(PickedFolder {
            uri: path.to_string_lossy().into_owned(),
            display_name,
        })
    }

    pub fn store_session(&self, session: String) -> crate::Result<()> {
        self.store_secret("oidc-session".into(), session)
    }

    pub fn store_secret(&self, slot: String, secret: String) -> crate::Result<()> {
        let entry = keyring::Entry::new("org.nixhomeserver.filesync", &slot)
            .map_err(|error| crate::Error::Operation(error.to_string()))?;
        entry
            .set_password(&secret)
            .map_err(|error| crate::Error::Operation(error.to_string()))?;
        Ok(())
    }

    pub fn load_session(&self) -> crate::Result<Option<String>> {
        self.load_secret("oidc-session".into())
    }

    pub fn load_secret(&self, slot: String) -> crate::Result<Option<String>> {
        let entry = keyring::Entry::new("org.nixhomeserver.filesync", &slot)
            .map_err(|error| crate::Error::Operation(error.to_string()))?;
        match entry.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(crate::Error::Operation(error.to_string())),
        }
    }

    pub fn clear_session(&self) -> crate::Result<()> {
        self.clear_secret("oidc-session".into())
    }

    pub fn clear_secret(&self, slot: String) -> crate::Result<()> {
        let entry = keyring::Entry::new("org.nixhomeserver.filesync", &slot)
            .map_err(|error| crate::Error::Operation(error.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(crate::Error::Operation(error.to_string())),
        }
    }

    pub fn schedule_background_sync(&self, _enabled: bool) -> crate::Result<()> {
        Ok(())
    }

    pub fn update_background_syncs(
        &self,
        _pairs_json: String,
        _enabled: bool,
    ) -> crate::Result<()> {
        Ok(())
    }

    pub fn run_sync_pair(&self, _pair_json: String) -> crate::Result<serde_json::Value> {
        Err(crate::Error::Operation(
            "Native background sync is only available on Android.".into(),
        ))
    }

    pub fn background_sync_status(&self) -> crate::Result<Option<String>> {
        Ok(None)
    }

    pub fn sync_progress(&self) -> crate::Result<Option<String>> {
        Ok(None)
    }

    pub fn ensure_notifications(&self) -> crate::Result<bool> {
        Ok(true)
    }

    pub fn list_local_files(&self, folder_uri: String) -> crate::Result<Vec<LocalEntry>> {
        fn walk(root: &Path, dir: &Path, entries: &mut Vec<LocalEntry>) -> std::io::Result<()> {
            for item in fs::read_dir(dir)? {
                let item = item?;
                let path = item.path();
                let metadata = fs::symlink_metadata(&path)?;
                if metadata.file_type().is_symlink() {
                    continue;
                }
                let relative = path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .replace('\\', "/");
                let modified_unix_ms = metadata
                    .modified()
                    .ok()
                    .and_then(|v| v.duration_since(UNIX_EPOCH).ok())
                    .map(|v| v.as_millis() as u64)
                    .unwrap_or_default();
                let sha256 = if metadata.is_file() {
                    let mut file = fs::File::open(&path)?;
                    let mut hasher = Sha256::new();
                    let mut buffer = [0_u8; 64 * 1024];
                    loop {
                        let count = file.read(&mut buffer)?;
                        if count == 0 {
                            break;
                        }
                        hasher.update(&buffer[..count]);
                    }
                    format!("{:x}", hasher.finalize())
                } else {
                    String::new()
                };
                entries.push(LocalEntry {
                    path: relative,
                    kind: if metadata.is_dir() {
                        "directory"
                    } else if metadata.is_file() {
                        "file"
                    } else {
                        "other"
                    }
                    .into(),
                    size: metadata.len(),
                    modified_unix_ms,
                    sha256,
                });
                if metadata.is_dir() {
                    walk(root, &path, entries)?;
                }
            }
            Ok(())
        }
        let root = PathBuf::from(folder_uri).canonicalize()?;
        let mut entries = Vec::new();
        walk(&root, &root, &mut entries)?;
        Ok(entries)
    }

    pub fn stage_local_file(
        &self,
        folder_uri: String,
        relative_path: String,
    ) -> crate::Result<String> {
        let root = PathBuf::from(folder_uri).canonicalize()?;
        let relative = safe_relative(&relative_path)?;
        let path = root.join(relative);
        let mut current = root.clone();
        for component in Path::new(&relative_path).components() {
            current.push(component);
            if fs::symlink_metadata(&current)?.file_type().is_symlink() {
                return Err(crate::Error::Operation(
                    "Symbolic links are not synced".into(),
                ));
            }
        }
        if !path.starts_with(&root) || !path.is_file() {
            return Err(crate::Error::Operation("Invalid local file path".into()));
        }
        Ok(path.to_string_lossy().into_owned())
    }

    pub fn install_local_file(
        &self,
        folder_uri: String,
        relative_path: String,
        staged_path: String,
    ) -> crate::Result<()> {
        let root = PathBuf::from(folder_uri).canonicalize()?;
        let relative = safe_relative(&relative_path)?;
        let target = root.join(relative);
        if !target.starts_with(&root) {
            return Err(crate::Error::Operation("Invalid local file path".into()));
        }
        let parent = target
            .parent()
            .ok_or_else(|| crate::Error::Operation("Invalid local file path".into()))?;
        let relative_parent = parent
            .strip_prefix(&root)
            .map_err(|_| crate::Error::Operation("Invalid local file path".into()))?;
        let mut current = root.clone();
        for component in relative_parent.components() {
            current.push(component);
            match fs::symlink_metadata(&current) {
                Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                    return Err(crate::Error::Operation(
                        "A local destination path is not a regular folder".into(),
                    ))
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    fs::create_dir(&current)?
                }
                Err(error) => return Err(error.into()),
            }
        }
        let temp = parent.join(format!(".filesync-{}.tmp", uuid::Uuid::new_v4()));
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        let copy_result = (|| -> crate::Result<()> {
            let mut input = fs::File::open(staged_path)?;
            io::copy(&mut input, &mut output)?;
            output.flush()?;
            output.sync_all()?;
            Ok(())
        })();
        if let Err(error) = copy_result {
            drop(output);
            let _ = fs::remove_file(&temp);
            return Err(error);
        }
        drop(output);
        if let Err(error) = fs::rename(&temp, target) {
            let _ = fs::remove_file(&temp);
            return Err(error.into());
        }
        Ok(())
    }
}

fn safe_relative(value: &str) -> crate::Result<PathBuf> {
    let path = Path::new(value);
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        return Err(crate::Error::Operation("Invalid local file path".into()));
    }
    Ok(path.to_path_buf())
}
