use crate::{
    audio_sequence::{rewrite_audio_order, sequence_filename, AUDIO_EXTENSIONS},
    broker::{
        file_fingerprint, open_directory_beneath, open_regular_file_beneath,
        opened_file_fingerprint, BrokerAction, InstallMetadataSidecarAction, MoveAction,
        ReplaceArtworkAction,
    },
    catalog::CatalogItem,
    config::{AppConfig, Identity, RootScope},
    media::LibraryCategory,
};
use serde::Serialize;
use serde_json::json;
use std::{
    collections::BTreeSet,
    fs,
    io::Write,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceTrack {
    pub source_relative_path: String,
    pub destination_relative_path: String,
    pub track_number: usize,
    pub track_total: usize,
    pub disc_number: usize,
    pub disc_total: usize,
}

pub struct PreparedSequence {
    pub actions: Vec<BrokerAction>,
    pub tracks: Vec<SequenceTrack>,
    staged: Vec<PathBuf>,
}
impl PreparedSequence {
    /// Transfer staging custody to the durable plan journal only after insertion.
    pub fn persist(&mut self) {
        self.staged.clear();
    }
}
impl Drop for PreparedSequence {
    fn drop(&mut self) {
        for path in &self.staged {
            let _ = fs::remove_file(path);
        }
    }
}
fn join(parent: &str, leaf: &str) -> String {
    format!("{parent}/{leaf}")
}
fn extension(name: &str) -> String {
    name.rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default()
}
fn fingerprint(root: &Path, path: &str) -> Result<String, String> {
    let file = open_regular_file_beneath(root, path).map_err(|e| e.to_string())?;
    opened_file_fingerprint(&file).map_err(|e| e.to_string())
}

/// Validate the entire folder before staging any rewrite. Every audio sibling must
/// participate, including formats that cannot safely be tagged (which block the plan).
pub fn prepare_sequence(
    config: &AppConfig,
    identity: &Identity,
    items: &[CatalogItem],
    id: &str,
) -> Result<PreparedSequence, String> {
    if id.is_empty()
        || id.len() > 100
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("Invalid sequence staging identifier".into());
    }
    if items.is_empty() || items.len() > 500 {
        return Err("Select between 1 and 500 tracks".into());
    }
    let first = &items[0];
    let (parent, _) = first
        .relative_path
        .rsplit_once('/')
        .ok_or("Tracks must be inside an album folder")?;
    let root = config
        .resolve_visible_root(identity, &first.root_id)
        .ok_or("Track root is not visible")?;
    if !matches!(
        root.category,
        LibraryCategory::Music | LibraryCategory::Audiobooks
    ) {
        return Err("Track sequencing is available for music and audiobooks".into());
    }
    let root_path = Path::new(&root.resolved_path);
    let directory = open_directory_beneath(root_path, parent).map_err(|e| e.to_string())?;
    let mut names = BTreeSet::new();
    let mut playlists = BTreeSet::from([
        "playlist.m3u".to_string(),
        "playlist.m3u8".to_string(),
        "playlist.pls".to_string(),
        "playlist.xspf".to_string(),
    ]);
    for (index, entry) in fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|e| e.to_string())?
        .enumerate()
    {
        if index >= 10_000 {
            return Err("Album folder exceeds the safe inspection limit".into());
        }
        let name = entry
            .map_err(|e| e.to_string())?
            .file_name()
            .into_string()
            .map_err(|_| "Non-UTF-8 album filename")?;
        let ext = extension(&name);
        if AUDIO_EXTENSIONS.contains(&ext.as_str()) {
            names.insert(join(parent, &name));
        } else if crate::track_order::UNRECOGNISED_AUDIO_EXTENSIONS.contains(&ext.as_str()) {
            return Err(format!(
                "{name} cannot be tagged safely. No track order changes were prepared."
            ));
        } else if matches!(ext.as_str(), "m3u" | "m3u8" | "pls" | "xspf") {
            playlists.insert(name);
        }
    }
    let selected: BTreeSet<_> = items
        .iter()
        .map(|item| item.relative_path.clone())
        .collect();
    if selected.len() != items.len() || selected != names {
        return Err("The sequence must contain every audio file in exactly one folder, once. Rescan and reload the album.".into());
    }
    let mut bytes = 0u64;
    let mut destinations = BTreeSet::new();
    let mut tracks = Vec::new();
    for (index, item) in items.iter().enumerate() {
        if item.root_id != first.root_id
            || (root.scope == RootScope::Personal
                && item.owner_username.as_deref() != Some(&identity.username))
        {
            return Err("A track is outside the visible album".into());
        }
        let source =
            open_regular_file_beneath(root_path, &item.relative_path).map_err(|e| e.to_string())?;
        let size = source.metadata().map_err(|e| e.to_string())?.len();
        if size > 512 * 1024 * 1024 {
            return Err("A track exceeds the 512 MiB safe edit limit".into());
        }
        bytes = bytes.saturating_add(size);
        if bytes > 2 * 1024 * 1024 * 1024 {
            return Err("This album exceeds the 2 GiB safe staging limit".into());
        }
        if opened_file_fingerprint(&source).map_err(|e| e.to_string())? != item.fingerprint {
            return Err("An audio file changed. Rescan and reload the album.".into());
        }
        let name = item
            .relative_path
            .rsplit('/')
            .next()
            .ok_or("Invalid track path")?;
        let destination = join(parent, &sequence_filename(name, index + 1, items.len())?);
        if !destinations.insert(destination.clone()) {
            return Err("Two tracks would have the same filename".into());
        }
        if fs::symlink_metadata(root_path.join(&destination)).is_ok()
            && !selected.contains(&destination)
        {
            return Err(format!("Destination is occupied: {destination}"));
        }
        tracks.push(SequenceTrack {
            source_relative_path: item.relative_path.clone(),
            destination_relative_path: destination,
            track_number: index + 1,
            track_total: items.len(),
            disc_number: 1,
            disc_total: 1,
        });
    }
    let staging = config.state_dir.join("provider-staging");
    fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    let mut prepared = PreparedSequence {
        actions: Vec::new(),
        tracks,
        staged: Vec::new(),
    };
    for (index, item) in items.iter().enumerate() {
        let ext = extension(&item.relative_path);
        let staging_filename = format!("sequence-{id}-{index}.{ext}");
        let path = staging.join(&staging_filename);
        let output = fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .mode(0o660)
            .open(&path)
            .map_err(|e| e.to_string())?;
        prepared.staged.push(path.clone());
        let source =
            open_regular_file_beneath(root_path, &item.relative_path).map_err(|e| e.to_string())?;
        rewrite_audio_order(source, output, &ext, (index + 1) as u32, items.len() as u32)
            .map_err(|e| format!("{}: {e}", item.relative_path))?;
        if fingerprint(root_path, &item.relative_path)? != item.fingerprint {
            return Err("An audio file changed during preparation".into());
        }
        let expected_replacement = file_fingerprint(&path).map_err(|e| e.to_string())?;
        prepared.actions.push(BrokerAction::ReplaceEmbeddedMetadata(
            ReplaceArtworkAction {
                staging_filename,
                root_id: first.root_id.clone(),
                source_relative_path: item.relative_path.clone(),
                archived_relative_path: join(
                    parent,
                    &format!("superseded/sequence-{id}-original-{index}.{ext}.backup"),
                ),
                replacement_relative_path: item.relative_path.clone(),
                expected_source: item.fingerprint.clone(),
                expected_replacement,
            },
        ));
    }
    // All tagged copies are moved aside before any final name is installed. This
    // handles cycles and identical chapter titles without overwriting a sibling.
    let mut final_moves = Vec::new();
    for (index, track) in prepared.tracks.iter().enumerate() {
        if track.source_relative_path == track.destination_relative_path {
            continue;
        }
        let BrokerAction::ReplaceEmbeddedMetadata(replacement) = &prepared.actions[index] else {
            unreachable!()
        };
        let temporary = join(
            parent,
            &format!(
                "superseded/sequence-{id}/ordered-{index}.{}.pending",
                extension(&track.source_relative_path)
            ),
        );
        prepared.actions.push(BrokerAction::Move(MoveAction {
            source_root_id: first.root_id.clone(),
            source_relative_path: track.source_relative_path.clone(),
            destination_root_id: first.root_id.clone(),
            destination_relative_path: temporary.clone(),
            expected: replacement.expected_replacement.clone(),
        }));
        final_moves.push(BrokerAction::Move(MoveAction {
            source_root_id: first.root_id.clone(),
            source_relative_path: temporary,
            destination_root_id: first.root_id.clone(),
            destination_relative_path: track.destination_relative_path.clone(),
            expected: match &prepared.actions[index] {
                BrokerAction::ReplaceEmbeddedMetadata(a) => a.expected_replacement.clone(),
                _ => unreachable!(),
            },
        }));
    }
    prepared.actions.extend(final_moves);
    // Existing file-specific metadata overrides must follow the renamed audio.
    let mut companion_moves = Vec::new();
    for (index, track) in prepared.tracks.iter().enumerate() {
        if track.source_relative_path == track.destination_relative_path {
            continue;
        }
        for ext in ["nfo", "opf"] {
            let source = format!("{}.{}", track.source_relative_path, ext);
            if fs::symlink_metadata(root_path.join(&source)).is_err() {
                continue;
            }
            let expected = fingerprint(root_path, &source)?;
            let temporary = join(
                parent,
                &format!("superseded/sequence-{id}/companion-{index}.{ext}"),
            );
            let destination = format!("{}.{}", track.destination_relative_path, ext);
            let original_companions: BTreeSet<_> = prepared
                .tracks
                .iter()
                .map(|t| format!("{}.{}", t.source_relative_path, ext))
                .collect();
            if fs::symlink_metadata(root_path.join(&destination)).is_ok()
                && !original_companions.contains(&destination)
            {
                return Err(format!("Metadata destination is occupied: {destination}"));
            }
            prepared.actions.push(BrokerAction::Move(MoveAction {
                source_root_id: first.root_id.clone(),
                source_relative_path: source,
                destination_root_id: first.root_id.clone(),
                destination_relative_path: temporary.clone(),
                expected: expected.clone(),
            }));
            companion_moves.push(BrokerAction::Move(MoveAction {
                source_root_id: first.root_id.clone(),
                source_relative_path: temporary,
                destination_root_id: first.root_id.clone(),
                destination_relative_path: destination,
                expected,
            }));
        }
    }
    prepared.actions.extend(companion_moves);
    let filenames: Vec<_> = prepared
        .tracks
        .iter()
        .map(|t| {
            t.destination_relative_path
                .rsplit('/')
                .next()
                .unwrap()
                .to_string()
        })
        .collect();
    let m3u = format!("#EXTM3U\n{}\n", filenames.join("\n"));
    let mut pls = String::from("[playlist]\n");
    let mut xspf = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\"><trackList>\n");
    for (index, name) in filenames.iter().enumerate() {
        pls.push_str(&format!("File{}={}\n", index + 1, name));
        let encoded: String = name
            .as_bytes()
            .iter()
            .map(|b| {
                if b.is_ascii_alphanumeric() || b"-._~".contains(b) {
                    (*b as char).to_string()
                } else {
                    format!("%{b:02X}")
                }
            })
            .collect();
        xspf.push_str(&format!("<track><location>{encoded}</location></track>\n"));
    }
    pls.push_str(&format!("NumberOfEntries={}\nVersion=2\n", filenames.len()));
    xspf.push_str("</trackList></playlist>\n");
    let manifest = serde_json::to_string_pretty(
        &json!({"schemaVersion":1,"authoritative":true,"tracks":prepared.tracks}),
    )
    .map_err(|e| e.to_string())?;
    playlists.insert("track-order.json".into());
    for (index, name) in playlists.iter().enumerate() {
        let content = match extension(name).as_str() {
            "json" => &manifest,
            "pls" => &pls,
            "xspf" => &xspf,
            _ => &m3u,
        };
        let destination = join(parent, name);
        let filename = format!("sequence-{id}-sidecar-{index}.{}", extension(name));
        let path = staging.join(&filename);
        let mut output = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o660)
            .open(&path)
            .map_err(|e| e.to_string())?;
        prepared.staged.push(path.clone());
        output
            .write_all(content.as_bytes())
            .and_then(|_| output.sync_all())
            .map_err(|e| e.to_string())?;
        let expected = file_fingerprint(&path).map_err(|e| e.to_string())?;
        if fs::symlink_metadata(root_path.join(&destination)).is_ok() {
            prepared
                .actions
                .push(BrokerAction::ReplaceMetadataSidecar(ReplaceArtworkAction {
                    staging_filename: filename,
                    root_id: first.root_id.clone(),
                    source_relative_path: destination.clone(),
                    archived_relative_path: join(
                        parent,
                        &format!(
                            "superseded/sequence-{id}-sidecar-{index}.{}.backup",
                            name.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("json")
                        ),
                    ),
                    replacement_relative_path: destination.clone(),
                    expected_source: fingerprint(root_path, &destination)?,
                    expected_replacement: expected,
                }));
        } else {
            prepared.actions.push(BrokerAction::InstallMetadataSidecar(
                InstallMetadataSidecarAction {
                    staging_filename: filename,
                    destination_root_id: first.root_id.clone(),
                    destination_relative_path: destination,
                    expected,
                },
            ));
        }
    }
    Ok(prepared)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        broker::{apply_broker_action, recover_broker_action},
        media::MediaKind,
    };
    use lofty::{config::ParseOptions, file::TaggedFileExt, probe::Probe, tag::Accessor};

    fn fixture() -> (tempfile::TempDir, AppConfig, Vec<CatalogItem>) {
        let temp = tempfile::tempdir().unwrap();
        let mut config = AppConfig::for_test(
            temp.path().join("shared").to_str().unwrap(),
            temp.path().join("users").to_str().unwrap(),
        );
        config.state_dir = temp.path().join("state");
        let folder = config.shared_root.join("_Music/Album");
        fs::create_dir_all(&folder).unwrap();
        let mut items = Vec::new();
        for (index, name) in ["01 - Same.flac", "02 - Same.flac"].iter().enumerate() {
            let mut bytes = b"fLaC\x80\0\0\x22".to_vec();
            bytes.extend([0u8; 34]);
            bytes.extend(format!("encoded-audio-{index}").as_bytes());
            fs::write(folder.join(name), bytes).unwrap();
            items.push(CatalogItem {
                id: format!("item-{index}"),
                root_id: "shared-music".into(),
                owner_username: None,
                relative_path: format!("Album/{name}"),
                media_kind: MediaKind::Music,
                size_bytes: 0,
                modified_ns: 0,
                fingerprint: file_fingerprint(&folder.join(name)).unwrap(),
            });
        }
        (temp, config, items)
    }
    // A folder rename cycle and recoverable mid-plan interruption must not lose
    // either original or duplicate audio on the next library scan.
    #[test]
    fn sequence_plan_swaps_files_preserves_originals_and_writes_sidecars() {
        let (_temp, config, mut items) = fixture();
        let folder = config.shared_root.join("_Music/Album");
        let original0 = fs::read(folder.join("01 - Same.flac")).unwrap();
        let original1 = fs::read(folder.join("02 - Same.flac")).unwrap();
        fs::write(
            folder.join("custom.m3u"),
            "02 - Same.flac\n01 - Same.flac\n",
        )
        .unwrap();
        fs::write(folder.join("01 - Same.flac.nfo"), "Keep file metadata").unwrap();
        items.reverse();
        let identity = Identity::try_new("editor", ["users"]).unwrap();
        let mut plan = prepare_sequence(&config, &identity, &items, "test").unwrap();
        assert_eq!(fs::read(folder.join("01 - Same.flac")).unwrap(), original0);
        assert_eq!(fs::read(folder.join("02 - Same.flac")).unwrap(), original1);
        // Persist custody as the API does after inserting the journal.
        plan.persist();
        for action in &plan.actions {
            apply_broker_action(&config, "editor", action).unwrap();
            assert!(recover_broker_action(&config, "editor", action).unwrap());
        }
        for (index, name) in ["01 - Same.flac", "02 - Same.flac"].iter().enumerate() {
            let tagged = Probe::open(folder.join(name))
                .unwrap()
                .options(ParseOptions::new().read_properties(false))
                .read()
                .unwrap();
            let tag = tagged.primary_tag().unwrap();
            assert_eq!(tag.track(), Some(index as u32 + 1));
            assert_eq!(tag.track_total(), Some(2));
            assert_eq!(tag.disk(), Some(1));
            assert_eq!(tag.disk_total(), Some(1));
            assert!(fs::read(folder.join(name))
                .unwrap()
                .ends_with(format!("encoded-audio-{}", 1 - index).as_bytes()));
        }
        assert_eq!(
            fs::read(folder.join("superseded/sequence-test-original-0.flac.backup")).unwrap(),
            original1
        );
        assert_eq!(
            fs::read(folder.join("superseded/sequence-test-original-1.flac.backup")).unwrap(),
            original0
        );
        assert_eq!(
            fs::read_to_string(folder.join("02 - Same.flac.nfo")).unwrap(),
            "Keep file metadata"
        );
        assert_eq!(
            fs::read_to_string(folder.join("custom.m3u")).unwrap(),
            "#EXTM3U\n01 - Same.flac\n02 - Same.flac\n"
        );
        for name in [
            "playlist.m3u",
            "playlist.m3u8",
            "playlist.pls",
            "playlist.xspf",
            "track-order.json",
        ] {
            assert!(folder.join(name).is_file());
        }
        let (report, _) = crate::track_order::inspect_folder_track_order(
            &config.shared_root.join("_Music"),
            "Album",
            LibraryCategory::Music,
        );
        assert!(report.unwrap().problems.is_empty());
        let xspf = fs::read_to_string(folder.join("playlist.xspf")).unwrap();
        assert!(roxmltree::Document::parse(&xspf).is_ok());
        let manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(folder.join("track-order.json")).unwrap()).unwrap();
        assert_eq!(manifest["tracks"][0]["trackNumber"], 1);
        assert_eq!(manifest["tracks"][1]["trackTotal"], 2);
    }
    #[test]
    fn sequence_plan_rejects_partial_folders_and_cleans_failed_staging() {
        let (_temp, config, items) = fixture();
        let identity = Identity::try_new("editor", ["users"]).unwrap();
        assert!(prepare_sequence(&config, &identity, &items[..1], "partial").is_err());
        fs::write(
            config.shared_root.join("_Music/Album/bad.wma"),
            b"unsupported",
        )
        .unwrap();
        assert!(prepare_sequence(&config, &identity, &items, "unsupported").is_err());
        fs::remove_file(config.shared_root.join("_Music/Album/bad.wma")).unwrap();
        let mut changed = items.clone();
        changed[0].fingerprint = "stale".into();
        assert!(prepare_sequence(&config, &identity, &changed, "stale").is_err());
        // Failure on a later track must leave earlier prepared copies uncommitted
        // and reclaim staging, while retaining both original files.
        fs::write(
            config.shared_root.join("_Music/Album/02 - Same.flac"),
            b"bad",
        )
        .unwrap();
        let mut corrupt = items;
        corrupt[1].fingerprint =
            file_fingerprint(&config.shared_root.join("_Music/Album/02 - Same.flac")).unwrap();
        assert!(prepare_sequence(&config, &identity, &corrupt, "corrupt").is_err());
        assert_eq!(
            fs::read_dir(config.state_dir.join("provider-staging"))
                .unwrap()
                .count(),
            0
        );
        assert!(config
            .shared_root
            .join("_Music/Album/01 - Same.flac")
            .is_file());
    }
}
