use crate::{
    catalog::{Catalog, CatalogHandle, ScannedItem},
    config::TOMBSTONE_FOLDER,
    media::{classify, LibraryCategory},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::UNIX_EPOCH,
};

const MAX_SCAN_ENTRIES: usize = 1_000_000;
const MAX_SKIPPED_PATH_REPORT: usize = 64;
static ROOT_SCAN_LOCKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

#[derive(Clone, Debug)]
pub struct ScanRoot {
    pub id: String,
    pub owner_username: Option<String>,
    pub path: PathBuf,
    pub category: LibraryCategory,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub files_seen: usize,
    pub items_indexed: usize,
    pub items_changed: usize,
    pub items_removed: usize,
    pub entries_skipped: usize,
    pub skipped_paths: Vec<String>,
}

pub fn scan_root_if_needed(
    catalog_handle: &CatalogHandle,
    root: &ScanRoot,
) -> Result<Option<ScanResult>, String> {
    with_root_scan_lock(root, || {
        let mut catalog = catalog_handle
            .open()
            .map_err(|error| format!("open catalog: {error}"))?;
        if catalog
            .root_has_been_scanned(&root.id, root.owner_username.as_deref())
            .map_err(|error| format!("read catalog scan state: {error}"))?
        {
            return Ok(None);
        }
        let result = scan_root(&mut catalog, root)?;
        catalog
            .record_scan_outcome(
                &root.id,
                root.owner_username.as_deref(),
                scan_found_change(&result),
                unix_timestamp(),
            )
            .map_err(|error| format!("record scan outcome: {error}"))?;
        Ok(Some(result))
    })
}

/// Scans a single root only when its adaptive schedule says it is due, then
/// records the outcome. Used by the periodic scanner so idle roots back off.
pub fn scan_root_if_due(
    catalog_handle: &CatalogHandle,
    root: &ScanRoot,
    now: i64,
) -> Result<Option<ScanResult>, String> {
    with_root_scan_lock(root, || {
        let mut catalog = catalog_handle
            .open()
            .map_err(|error| format!("open catalog: {error}"))?;
        if !catalog
            .scan_is_due(&root.id, root.owner_username.as_deref(), now)
            .map_err(|error| format!("read scan schedule: {error}"))?
        {
            return Ok(None);
        }
        let result = scan_root(&mut catalog, root)?;
        catalog
            .record_scan_outcome(
                &root.id,
                root.owner_username.as_deref(),
                scan_found_change(&result),
                now,
            )
            .map_err(|error| format!("record scan outcome: {error}"))?;
        Ok(Some(result))
    })
}

/// Runs a scan immediately (manual refresh or explicit editor rescan) and
/// resets the root's adaptive backoff when it finds a change.
pub fn scan_root_now(
    catalog_handle: &CatalogHandle,
    root: &ScanRoot,
    now: i64,
) -> Result<ScanResult, String> {
    with_root_scan_lock(root, || {
        let mut catalog = catalog_handle
            .open()
            .map_err(|error| format!("open catalog: {error}"))?;
        let result = scan_root(&mut catalog, root)?;
        catalog
            .record_scan_outcome(
                &root.id,
                root.owner_username.as_deref(),
                scan_found_change(&result),
                now,
            )
            .map_err(|error| format!("record scan outcome: {error}"))?;
        Ok(result)
    })
}

fn scan_found_change(result: &ScanResult) -> bool {
    result.items_changed > 0 || result.items_removed > 0
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

pub fn rescan_root(catalog_handle: &CatalogHandle, root: &ScanRoot) -> Result<ScanResult, String> {
    with_root_scan_lock(root, || {
        let mut catalog = catalog_handle
            .open()
            .map_err(|error| format!("open catalog: {error}"))?;
        scan_root(&mut catalog, root)
    })
}

fn with_root_scan_lock<T>(
    root: &ScanRoot,
    operation: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    let key = format!(
        "{}\0{}",
        root.id,
        root.owner_username.as_deref().unwrap_or_default()
    );
    let root_lock = {
        let locks = ROOT_SCAN_LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
        let mut locks = locks
            .lock()
            .map_err(|_| "root scan lock registry is poisoned".to_string())?;
        locks
            .entry(key)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    };
    let _guard = root_lock
        .lock()
        .map_err(|_| "root scan lock is poisoned".to_string())?;
    operation()
}

pub fn scan_root(catalog: &mut Catalog, root: &ScanRoot) -> Result<ScanResult, String> {
    if !root.path.is_dir() {
        let outcome = catalog
            .reconcile_root(&root.id, root.owner_username.as_deref(), &[])
            .map_err(|error| format!("clear unavailable root catalog: {error}"))?;
        return Ok(ScanResult {
            items_removed: outcome.removed,
            ..ScanResult::default()
        });
    }

    let mut result = ScanResult::default();
    let mut scanned = Vec::new();
    let mut pending = vec![root.path.clone()];
    let mut entries_seen = 0usize;

    while let Some(directory) = pending.pop() {
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) => {
                if directory == root.path {
                    return Err(format!("read {}: {error}", directory.display()));
                }
                record_skip(&mut result, &directory);
                continue;
            }
        };
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    record_skip(&mut result, &directory);
                    continue;
                }
            };
            entries_seen += 1;
            if entries_seen > MAX_SCAN_ENTRIES {
                return Err(format!(
                    "root {} exceeded the {MAX_SCAN_ENTRIES} entry scan limit",
                    root.id
                ));
            }
            let path = entry.path();
            let metadata = match fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(_) => {
                    record_skip(&mut result, &path);
                    continue;
                }
            };
            let file_type = metadata.file_type();
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                if path.file_name().and_then(|value| value.to_str()) == Some(TOMBSTONE_FOLDER) {
                    continue;
                }
                pending.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            result.files_seen += 1;
            let extension = path
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_ascii_lowercase();
            let media_kind = match classify(root.category, &extension) {
                Some(media_kind) => media_kind,
                None => continue,
            };
            let relative = match path.strip_prefix(&root.path) {
                Ok(relative) => relative,
                Err(_) => {
                    record_skip(&mut result, &path);
                    continue;
                }
            };
            let relative_path = match normalized_relative_path(relative) {
                Ok(relative_path) => relative_path,
                Err(_) => {
                    record_skip(&mut result, &path);
                    continue;
                }
            };
            let modified_ns = metadata
                .modified()
                .ok()
                .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
                .unwrap_or(0);
            let fingerprint = format!("{}:{modified_ns}", metadata.len());
            let id = stable_item_id(&root.id, root.owner_username.as_deref(), &relative_path);
            scanned.push(ScannedItem {
                id,
                relative_path,
                media_kind,
                size_bytes: metadata.len().min(i64::MAX as u64) as i64,
                modified_ns,
                fingerprint,
            });
        }
    }

    result.items_indexed = scanned.len();
    let outcome = catalog
        .reconcile_root(&root.id, root.owner_username.as_deref(), &scanned)
        .map_err(|error| format!("reconcile catalog: {error}"))?;
    result.items_changed = outcome.changed;
    result.items_removed = outcome.removed;
    Ok(result)
}

fn record_skip(result: &mut ScanResult, path: &Path) {
    result.entries_skipped += 1;
    if result.skipped_paths.len() < MAX_SKIPPED_PATH_REPORT {
        result
            .skipped_paths
            .push(path.to_string_lossy().into_owned());
    }
}

fn stable_item_id(root_id: &str, owner: Option<&str>, relative_path: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(root_id.as_bytes());
    hasher.update([0]);
    hasher.update(owner.unwrap_or_default().as_bytes());
    hasher.update([0]);
    hasher.update(relative_path.as_bytes());
    let digest = hasher.finalize();
    let short = digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("item-{short}")
}

fn normalized_relative_path(path: &Path) -> Result<String, String> {
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            std::path::Component::Normal(value) => {
                let value = value
                    .to_str()
                    .ok_or_else(|| "media path is not valid UTF-8".to_string())?;
                if value == "." || value == ".." || value.contains('\0') {
                    return Err("media path contains an unsafe component".to_string());
                }
                components.push(value);
            }
            _ => return Err("media path is not a normalized relative path".to_string()),
        }
    }
    Ok(components.join("/"))
}
