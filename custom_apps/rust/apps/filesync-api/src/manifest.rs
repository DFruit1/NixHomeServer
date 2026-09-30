//! Server-side folder manifests.
//!
//! A manifest is the recursive listing of one server folder: every file's
//! relative path, size and mtime, plus a SHA-256 once one has been needed.
//!
//! Before this existed the phone walked the tree itself, one HTTP request per
//! directory with `hashes=true`, so the server re-read and re-hashed an entire
//! library on every estimate refresh — and the app refreshes estimates on
//! sign-in and after every enable, remove, sync and address change. The walk
//! lives here instead, so it happens once per change rather than once per
//! refresh, and folder sizes can be reported without reading a single byte of
//! file content.
//!
//! Hash reuse keys on `(size, mtime)`: a file whose size and modification time
//! are unchanged keeps its previous hash. That is the same trade every
//! incremental sync tool makes to avoid re-reading unchanged data, and it is
//! what turns a steady-state estimate into one walk and zero reads.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::{self, Read},
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// Bounds on a single walk. A personal media folder is finite, but a runaway
/// tree must not be able to pin a core or hold a request open indefinitely.
/// When a bound trips the result is flagged `truncated`, and the UI says "at
/// least" rather than presenting a partial sum as a total.
const MAX_DEPTH: usize = 32;
const MAX_ENTRIES: usize = 500_000;
const MAX_WALK: Duration = Duration::from_secs(20);

/// How long a manifest may be reused before it is re-walked. The walk itself
/// is cheap once hashes are cached, so this only bounds how stale a size can
/// get; it is not a performance crutch.
const MANIFEST_TTL: Duration = Duration::from_secs(300);

#[derive(Clone, Debug)]
pub struct ManifestEntry {
    pub path: String,
    pub size: u64,
    pub mtime_unix_ms: u128,
    /// `None` until something needed to compare this file's content.
    pub hash: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Manifest {
    pub entries: Vec<ManifestEntry>,
    pub total_bytes: u64,
    pub files: usize,
    pub directories: usize,
    pub truncated: bool,
    /// Files read and hashed to build this manifest.
    pub hashed: usize,
    /// Hashes carried over from the previous manifest.
    pub reused: usize,
}

impl Manifest {
    fn get(&self, path: &str) -> Option<(u64, u128)> {
        self.find(path)
            .map(|entry| (entry.size, entry.mtime_unix_ms))
    }

    fn find(&self, path: &str) -> Option<&ManifestEntry> {
        self.entries
            .binary_search_by(|entry| entry.path.as_str().cmp(path))
            .ok()
            .map(|index| &self.entries[index])
    }

    fn find_mut(&mut self, path: &str) -> Option<&mut ManifestEntry> {
        self.entries
            .binary_search_by(|entry| entry.path.as_str().cmp(path))
            .ok()
            .map(|index| &mut self.entries[index])
    }
}

pub type ManifestKey = (String, String, String);

#[derive(Clone, Debug)]
pub struct CachedManifest {
    pub manifest: Manifest,
    pub scanned_at: SystemTime,
}

impl CachedManifest {
    pub fn is_fresh(&self) -> bool {
        SystemTime::now()
            .duration_since(self.scanned_at)
            .map(|age| age < MANIFEST_TTL)
            .unwrap_or(false)
    }
}

/// One library folder's size, for the app's list of premade folders.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySize {
    pub bytes: u64,
    pub files: usize,
    pub directories: usize,
    pub truncated: bool,
}

fn mtime_millis(time: Option<SystemTime>) -> u128 {
    time.and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_millis())
        .unwrap_or_default()
}

/// Recursively list a directory without reading any file contents.
///
/// Symlinks are skipped, matching the single-level `list_directory`, so a link
/// out of the folder cannot pull foreign data into a manifest or a size total.
pub fn scan(root: &Path) -> io::Result<Manifest> {
    let mut manifest = Manifest::default();
    let mut stack: Vec<(PathBuf, String, usize)> = vec![(root.to_path_buf(), String::new(), 0)];
    let started = Instant::now();

    'outer: while let Some((directory, prefix, depth)) = stack.pop() {
        if depth > MAX_DEPTH {
            manifest.truncated = true;
            continue;
        }
        if started.elapsed() > MAX_WALK || manifest.entries.len() >= MAX_ENTRIES {
            manifest.truncated = true;
            break 'outer;
        }
        for item in std::fs::read_dir(&directory)? {
            if started.elapsed() > MAX_WALK || manifest.entries.len() >= MAX_ENTRIES {
                manifest.truncated = true;
                break 'outer;
            }
            let item = item?;
            let file_type = item.file_type()?;
            if file_type.is_symlink() {
                continue;
            }
            let name = item.file_name().to_string_lossy().into_owned();
            let path = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            if file_type.is_dir() {
                manifest.directories += 1;
                stack.push((item.path(), path, depth + 1));
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            let metadata = item.metadata()?;
            let size = metadata.len();
            manifest.total_bytes = manifest.total_bytes.saturating_add(size);
            manifest.files += 1;
            manifest.entries.push(ManifestEntry {
                path,
                size,
                mtime_unix_ms: mtime_millis(metadata.modified().ok()),
                hash: None,
            });
        }
    }

    manifest
        .entries
        .sort_by(|left, right| left.path.cmp(&right.path));
    Ok(manifest)
}

/// Carry hashes from the previous manifest onto a fresh scan.
pub fn reuse_hashes(manifest: &mut Manifest, previous: Option<&Manifest>) {
    let Some(previous) = previous else {
        return;
    };
    let index: HashMap<&str, &ManifestEntry> = previous
        .entries
        .iter()
        .map(|entry| (entry.path.as_str(), entry))
        .collect();
    for entry in &mut manifest.entries {
        let Some(cached) = index.get(entry.path.as_str()) else {
            continue;
        };
        if cached.size != entry.size || cached.mtime_unix_ms != entry.mtime_unix_ms {
            continue;
        }
        if let Some(hash) = &cached.hash {
            entry.hash = Some(hash.clone());
            manifest.reused += 1;
        }
    }
}

/// Hash one file and remember the result for the next estimate.
fn hash_entry(manifest: &mut Manifest, root: &Path, path: &str) -> io::Result<Option<String>> {
    if let Some(existing) = manifest.find(path).and_then(|entry| entry.hash.clone()) {
        return Ok(Some(existing));
    }
    let mut file = match std::fs::File::open(root.join(path)) {
        Ok(file) => file,
        // A file that vanished between the walk and the read cannot be
        // compared. Reporting it as unchanged would silently drop it from the
        // estimate, so treat it as unreadable and let the caller queue it.
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 128 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => hasher.update(&buffer[..count]),
            Err(error) => return Err(error),
        }
    }
    let hash = format!("{:x}", hasher.finalize());
    if let Some(entry) = manifest.find_mut(path) {
        entry.hash = Some(hash.clone());
        manifest.hashed += 1;
    }
    Ok(Some(hash))
}

/// What the caller sent about one file on the device.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalFile {
    pub path: String,
    pub size: u64,
    pub mtime_unix_ms: u128,
    /// Sent on the second pass for the few files whose metadata disagreed.
    /// Leaving it out is what keeps the common request small.
    pub hash: Option<String>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffResult {
    pub pending_bytes: u64,
    pub pending_count: usize,
    pub skipped: usize,
    /// Files that look different by metadata and still need a content
    /// comparison. Non-empty only when something actually changed.
    pub needs_hash: Vec<String>,
    /// Files that could not be read for comparison.
    pub unreadable: Vec<String>,
}

/// Decide what a sync would move, hashing only what it must.
///
/// `(path, size, mtime)` agreement is treated as identity, so a library that
/// is already in sync costs zero reads on the server. Only files whose metadata
/// disagrees are hashed, and only once the client has supplied the local hash
/// to compare against — which is why the caller may need a second pass.
///
/// `pending_bytes` counts the side the files are moving *from*, matching what
/// the engine will actually transfer.
pub fn diff(
    manifest: &mut Manifest,
    root: &Path,
    local: &[LocalFile],
    direction: &str,
) -> io::Result<DiffResult> {
    let mut result = DiffResult::default();

    if direction == "phone-to-server" {
        for local_file in local {
            let Some((remote_size, remote_mtime)) = manifest.get(&local_file.path) else {
                result.pending_bytes = result.pending_bytes.saturating_add(local_file.size);
                result.pending_count += 1;
                continue;
            };
            match compare(
                manifest,
                root,
                &local_file.path,
                remote_size,
                remote_mtime,
                local_file,
                &mut result,
            )? {
                Outcome::Same => result.skipped += 1,
                // An upload moves the device's copy, so the device's size is
                // what the estimate has to add.
                Outcome::Different => {
                    result.pending_bytes = result.pending_bytes.saturating_add(local_file.size);
                    result.pending_count += 1;
                }
                Outcome::Unreadable => result.unreadable.push(local_file.path.clone()),
                Outcome::NeedHash => {}
            }
        }
        return Ok(result);
    }

    // A download is driven by what the server holds, so iterate the manifest.
    // Paths are collected first because comparing mutates the manifest.
    let paths: Vec<String> = manifest
        .entries
        .iter()
        .map(|entry| entry.path.clone())
        .collect();
    for path in paths {
        let Some((remote_size, remote_mtime)) = manifest.get(&path) else {
            continue;
        };
        let Some(local_file) = local.iter().find(|file| file.path == path) else {
            result.pending_bytes = result.pending_bytes.saturating_add(remote_size);
            result.pending_count += 1;
            continue;
        };
        match compare(
            manifest,
            root,
            &path,
            remote_size,
            remote_mtime,
            local_file,
            &mut result,
        )? {
            Outcome::Same => result.skipped += 1,
            Outcome::Different => {
                result.pending_bytes = result.pending_bytes.saturating_add(remote_size);
                result.pending_count += 1;
            }
            Outcome::Unreadable => result.unreadable.push(path.clone()),
            Outcome::NeedHash => {}
        }
    }
    Ok(result)
}

enum Outcome {
    Same,
    Different,
    NeedHash,
    Unreadable,
}

#[allow(clippy::too_many_arguments)]
fn compare(
    manifest: &mut Manifest,
    root: &Path,
    remote_path: &str,
    remote_size: u64,
    remote_mtime: u128,
    local: &LocalFile,
    result: &mut DiffResult,
) -> io::Result<Outcome> {
    if remote_size == local.size && remote_mtime == local.mtime_unix_ms {
        return Ok(Outcome::Same);
    }
    let Some(local_hash) = &local.hash else {
        result.needs_hash.push(local.path.clone());
        return Ok(Outcome::NeedHash);
    };
    match hash_entry(manifest, root, remote_path)? {
        Some(remote_hash) if &remote_hash == local_hash => Ok(Outcome::Same),
        Some(_) => Ok(Outcome::Different),
        None => Ok(Outcome::Unreadable),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local(path: &str, size: u64, mtime: u128) -> LocalFile {
        LocalFile {
            path: path.to_owned(),
            size,
            mtime_unix_ms: mtime,
            hash: None,
        }
    }

    fn manifest_of(entries: Vec<(&str, u64, u128, Option<&str>)>) -> Manifest {
        let mut manifest = Manifest::default();
        for (path, size, mtime, hash) in entries {
            manifest.total_bytes += size;
            manifest.files += 1;
            manifest.entries.push(ManifestEntry {
                path: path.to_owned(),
                size,
                mtime_unix_ms: mtime,
                hash: hash.map(str::to_owned),
            });
        }
        manifest.entries.sort_by(|a, b| a.path.cmp(&b.path));
        manifest
    }

    fn no_root() -> PathBuf {
        PathBuf::from("/nonexistent-filesync-test-root")
    }

    #[test]
    fn an_already_synced_library_needs_no_hashing() {
        let mut manifest = manifest_of(vec![("a.flac", 100, 5, Some("aaa"))]);
        let result = diff(
            &mut manifest,
            &no_root(),
            &[local("a.flac", 100, 5)],
            "server-to-phone",
        )
        .unwrap();
        assert_eq!(result.skipped, 1);
        assert_eq!(result.pending_count, 0);
        assert!(result.needs_hash.is_empty());
    }

    #[test]
    fn a_changed_file_waits_for_the_local_hash_then_counts_as_pending() {
        let mut manifest = manifest_of(vec![("a.flac", 100, 5, Some("aaa"))]);
        let waiting = diff(
            &mut manifest,
            &no_root(),
            &[local("a.flac", 120, 9)],
            "server-to-phone",
        )
        .unwrap();
        assert_eq!(waiting.needs_hash, vec!["a.flac".to_owned()]);
        assert_eq!(
            waiting.pending_count, 0,
            "must not count before it is decided"
        );

        // The client hashes the file and asks again; the remote hash is already
        // cached, so this needs no filesystem access.
        let mut device = local("a.flac", 120, 9);
        device.hash = Some("bbb".to_owned());
        let decided = diff(&mut manifest, &no_root(), &[device], "server-to-phone").unwrap();
        assert!(decided.needs_hash.is_empty());
        assert_eq!(
            decided.pending_bytes, 100,
            "downloads count the server copy"
        );
        assert_eq!(decided.pending_count, 1);
    }

    #[test]
    fn equal_content_after_a_touch_is_not_re_transferred() {
        let mut manifest = manifest_of(vec![("a.flac", 100, 5, Some("same"))]);
        let mut device = local("a.flac", 100, 9);
        device.hash = Some("same".to_owned());
        let result = diff(&mut manifest, &no_root(), &[device], "server-to-phone").unwrap();
        assert_eq!(result.skipped, 1);
        assert_eq!(result.pending_count, 0);
    }

    #[test]
    fn a_new_server_file_counts_towards_the_download() {
        let mut manifest = manifest_of(vec![("b.flac", 900, 5, Some("bbb"))]);
        let result = diff(&mut manifest, &no_root(), &[], "server-to-phone").unwrap();
        assert_eq!(result.pending_bytes, 900);
        assert_eq!(result.pending_count, 1);
    }

    #[test]
    fn an_upload_counts_the_device_copy_not_the_stale_server_one() {
        let mut manifest = manifest_of(vec![("c.flac", 10, 1, Some("old"))]);
        let result = diff(
            &mut manifest,
            &no_root(),
            &[local("c.flac", 700, 2)],
            "phone-to-server",
        )
        .unwrap();
        assert_eq!(result.needs_hash, vec!["c.flac".to_owned()]);

        let mut device = local("c.flac", 700, 2);
        device.hash = Some("new".to_owned());
        let decided = diff(&mut manifest, &no_root(), &[device], "phone-to-server").unwrap();
        assert_eq!(decided.pending_bytes, 700, "uploads count the device copy");
        assert_eq!(decided.pending_count, 1);
    }

    #[test]
    fn a_file_only_on_the_device_is_an_upload() {
        let manifest = Manifest::default();
        let mut manifest = manifest;
        let result = diff(
            &mut manifest,
            &no_root(),
            &[local("d.flac", 42, 1)],
            "phone-to-server",
        )
        .unwrap();
        assert_eq!(result.pending_bytes, 42);
        assert_eq!(result.pending_count, 1);
    }

    #[test]
    fn hashes_are_reused_only_when_size_and_mtime_both_match() {
        let previous = manifest_of(vec![("a.flac", 100, 5, Some("aaa"))]);

        let mut unchanged = manifest_of(vec![("a.flac", 100, 5, None)]);
        reuse_hashes(&mut unchanged, Some(&previous));
        assert_eq!(unchanged.entries[0].hash.as_deref(), Some("aaa"));
        assert_eq!(unchanged.reused, 1);

        let mut resized = manifest_of(vec![("a.flac", 101, 5, None)]);
        reuse_hashes(&mut resized, Some(&previous));
        assert!(resized.entries[0].hash.is_none());

        let mut touched = manifest_of(vec![("a.flac", 100, 6, None)]);
        reuse_hashes(&mut touched, Some(&previous));
        assert!(touched.entries[0].hash.is_none());
    }

    #[test]
    fn a_cached_hash_survives_a_rescan_unchanged() {
        let mut scanned = manifest_of(vec![("a.flac", 100, 5, None)]);
        reuse_hashes(
            &mut scanned,
            Some(&manifest_of(vec![("a.flac", 100, 5, Some("aaa"))])),
        );
        let again = scan_of(&[("a.flac", 100, 5)]);
        reuse_hashes(&mut scanned, Some(&again));
        assert_eq!(scanned.entries[0].hash.as_deref(), Some("aaa"));
    }

    fn scan_of(entries: &[(&str, u64, u128)]) -> Manifest {
        manifest_of(
            entries
                .iter()
                .map(|(path, size, mtime)| (*path, *size, *mtime, None))
                .collect(),
        )
    }

    #[test]
    fn a_missing_remote_file_is_reported_rather_than_silently_skipped() {
        // The walk saw the file but it cannot be read for comparison, so it
        // must not be counted as unchanged.
        let mut manifest = manifest_of(vec![("gone.flac", 100, 5, None)]);
        let mut device = local("gone.flac", 100, 9);
        device.hash = Some("aaa".to_owned());
        let result = diff(&mut manifest, &no_root(), &[device], "server-to-phone").unwrap();
        assert_eq!(result.unreadable, vec!["gone.flac".to_owned()]);
    }

    /// Build a throwaway tree, hand it to `scan`, and clean up afterwards.
    fn with_tree(files: &[(&str, &[u8])], run: impl FnOnce(&Path)) {
        let root = std::env::temp_dir().join(format!(
            "filesync-manifest-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        for (path, contents) in files {
            let target = root.join(path);
            std::fs::create_dir_all(target.parent().expect("a test path has a parent"))
                .expect("create test directory");
            std::fs::write(&target, contents).expect("write test file");
        }
        run(&root);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_scan_totals_nested_files_and_ignores_symlinks() {
        with_tree(
            &[
                ("top.flac", &[1_u8; 30]),
                ("album/one.flac", &[2_u8; 20]),
                ("album/deep/two.flac", &[3_u8; 50]),
            ],
            |root| {
                #[cfg(unix)]
                std::os::unix::fs::symlink("/etc", root.join("escape")).expect("symlink");

                let manifest = scan(root).expect("scan a real tree");
                assert_eq!(manifest.files, 3);
                assert_eq!(manifest.total_bytes, 100);
                assert_eq!(manifest.directories, 2);
                assert!(!manifest.truncated);
                assert!(
                    manifest.entries.iter().all(|entry| entry.hash.is_none()),
                    "a size-only scan must not read file contents"
                );
                let paths: Vec<&str> = manifest.entries.iter().map(|e| e.path.as_str()).collect();
                assert_eq!(paths, ["album/deep/two.flac", "album/one.flac", "top.flac"]);

                // The same tree hashed on demand, then matched against a device
                // that already has it: no reads needed on the second pass.
                let mut manifest = manifest;
                let device: Vec<LocalFile> = manifest
                    .entries
                    .iter()
                    .map(|entry| local(&entry.path, entry.size, entry.mtime_unix_ms))
                    .collect();
                let result = diff(&mut manifest, root, &device, "server-to-phone").unwrap();
                assert_eq!(result.skipped, 3);
                assert_eq!(result.pending_count, 0);
                assert!(result.needs_hash.is_empty());
                assert_eq!(manifest.hashed, 0);
            },
        );
    }

    #[test]
    fn a_changed_file_is_hashed_once_and_then_cached() {
        with_tree(&[("a.flac", &[7_u8; 12])], |root| {
            let mut manifest = scan(root).expect("scan a real tree");
            // Same size, different mtime: metadata disagrees, so content decides.
            let device = vec![local("a.flac", 12, 999)];
            let first = diff(&mut manifest, root, &device, "server-to-phone").unwrap();
            assert_eq!(first.needs_hash, vec!["a.flac".to_owned()]);
            assert_eq!(manifest.hashed, 0, "no local hash to compare against yet");

            let mut device = local("a.flac", 12, 999);
            device.hash = Some(hash_of(&root.join("a.flac")));
            let second = diff(&mut manifest, root, &[device], "server-to-phone").unwrap();
            assert_eq!(second.skipped, 1, "identical content after a touch");
            assert_eq!(manifest.hashed, 1, "read once and remembered");

            let device = vec![local("a.flac", 12, 999)];
            let third = diff(&mut manifest, root, &device, "server-to-phone").unwrap();
            assert_eq!(
                manifest.hashed, 1,
                "the cached hash settles it without a read"
            );
            assert_eq!(third.needs_hash, vec!["a.flac".to_owned()]);
        });
    }

    fn hash_of(path: &Path) -> String {
        let bytes = std::fs::read(path).expect("read test file");
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        format!("{:x}", hasher.finalize())
    }
}
