//! Targeted catalog updates announced by producers such as the YouTube
//! downloader. A producer atomically renames a small `<name>.json` hint into a
//! drop directory listing the absolute paths it just wrote; draining the
//! directory indexes only those paths instead of walking whole libraries.
//!
//! Hints are advisory. Every path is re-validated against the configured
//! library roots and the filesystem, and anything rejected here is still found
//! by the periodic full reconcile.

use crate::{
    catalog::CatalogHandle,
    config::AppConfig,
    scanner::{index_root_paths, ScanResult, ScanRoot},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

const MAX_HINT_BYTES: u64 = 256 * 1024;
const MAX_PATHS_PER_RUN: usize = 10_000;
/// Producers write `.<name>.tmp` and rename it into place; anything left that
/// long belongs to a producer that died mid-write.
const STALE_PARTIAL_HINT_AGE: Duration = Duration::from_secs(60 * 60);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HintFile {
    schema_version: u32,
    paths: Vec<PathBuf>,
}

#[derive(Debug)]
pub struct RootIndexOutcome {
    pub root_id: String,
    pub owner_username: Option<String>,
    pub result: Result<ScanResult, String>,
}

#[derive(Debug, Default)]
pub struct HintRun {
    pub hints_read: usize,
    pub hints_invalid: usize,
    pub paths_unmatched: usize,
    pub roots: Vec<RootIndexOutcome>,
}

/// Consumes every complete hint in `hint_dir` and indexes the announced paths.
/// Hint files are removed before indexing so a failing catalog write cannot
/// make the triggering path unit spin; the periodic scan is the fallback.
pub fn drain_hint_directory(
    config: &AppConfig,
    catalog: &CatalogHandle,
    hint_dir: &Path,
) -> Result<HintRun, String> {
    let mut run = HintRun::default();
    let mut paths = Vec::new();
    let entries = fs::read_dir(hint_dir)
        .map_err(|error| format!("read hint directory {}: {error}", hint_dir.display()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            let _ = fs::remove_file(&path);
            continue;
        };
        if name.starts_with('.') {
            remove_if_stale(&path);
            continue;
        }
        let parsed = read_hint(&path);
        let _ = fs::remove_file(&path);
        match parsed {
            Some(hint) => {
                run.hints_read += 1;
                let room = MAX_PATHS_PER_RUN.saturating_sub(paths.len());
                paths.extend(
                    hint.paths
                        .into_iter()
                        .filter(|path| path.is_absolute())
                        .take(room),
                );
            }
            None => run.hints_invalid += 1,
        }
    }

    let mut by_root: BTreeMap<(String, Option<String>), (ScanRoot, Vec<PathBuf>)> = BTreeMap::new();
    for path in paths {
        let Some(spec) = config.scan_spec_for_path(&path) else {
            run.paths_unmatched += 1;
            continue;
        };
        by_root
            .entry((spec.id.clone(), spec.owner_username.clone()))
            .or_insert_with(|| {
                (
                    ScanRoot {
                        id: spec.id,
                        owner_username: spec.owner_username,
                        path: spec.path,
                        category: spec.category,
                    },
                    Vec::new(),
                )
            })
            .1
            .push(path);
    }
    for (root, root_paths) in by_root.into_values() {
        let result = index_root_paths(catalog, &root, &root_paths);
        run.roots.push(RootIndexOutcome {
            root_id: root.id,
            owner_username: root.owner_username,
            result,
        });
    }
    Ok(run)
}

fn read_hint(path: &Path) -> Option<HintFile> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_HINT_BYTES {
        return None;
    }
    let mut contents = String::new();
    fs::File::open(path)
        .ok()?
        .take(MAX_HINT_BYTES)
        .read_to_string(&mut contents)
        .ok()?;
    let hint: HintFile = serde_json::from_str(&contents).ok()?;
    (hint.schema_version == 1).then_some(hint)
}

fn remove_if_stale(path: &Path) {
    let stale = fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .is_some_and(|age| age > STALE_PARTIAL_HINT_AGE);
    if stale {
        let _ = fs::remove_file(path);
    }
}
