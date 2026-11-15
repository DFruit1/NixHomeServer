#![cfg(target_os = "linux")]
//! Rearranging a YouTube download replaces library media, so these run the
//! real thing: ffmpeg prepares each change, the broker applies it to a
//! temporary library, and the media must decode exactly as before.

use media_manager::{
    broker::{apply_broker_action, BrokerAction},
    config::{AppConfig, Identity},
    youtube_item::{self, Change, Layout, Tools},
};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn tool(name: &str) -> Option<PathBuf> {
    let output = Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .ok()?;
    let path = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn ffmpeg(args: &[&str]) {
    let status = Command::new("ffmpeg")
        .args(["-nostdin", "-v", "error", "-y"])
        .args(args)
        .status()
        .expect("run ffmpeg");
    assert!(status.success(), "ffmpeg {args:?}");
}

fn decoded(file: &Path, stream: &str) -> String {
    let output = Command::new("ffmpeg")
        .args(["-nostdin", "-v", "error", "-i"])
        .arg(file)
        .args(["-map", stream, "-f", "hash", "-hash", "md5", "-"])
        .output()
        .expect("hash");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn has_cover(file: &Path) -> bool {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type:stream_disposition=attached_pic",
            "-of",
            "json",
        ])
        .arg(file)
        .output()
        .expect("probe");
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    value["streams"].as_array().unwrap().iter().any(|stream| {
        stream["disposition"]["attached_pic"] == json!(1)
            || stream["codec_type"] == json!("attachment")
    })
}

struct Library {
    _temp: tempfile::TempDir,
    config: AppConfig,
    shared: PathBuf,
}

fn library() -> Option<Library> {
    let ffprobe = tool("ffprobe")?;
    tool("ffmpeg")?;
    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    for folder in ["_Music", "_Audiobooks", "_Videos"] {
        fs::create_dir_all(shared.join(folder)).unwrap();
    }
    let mut config = AppConfig::for_test(
        shared.to_str().unwrap(),
        temp.path().join("users").to_str().unwrap(),
    );
    config.conversion_staging_dir = Some(temp.path().join("intake"));
    config.ffprobe_path = Some(ffprobe);
    Some(Library {
        _temp: temp,
        config,
        shared,
    })
}

/// A single-file download as the YouTube Downloader files it.
fn download(
    library: &Library,
    root: &str,
    folder: &str,
    title: &str,
    extension: &str,
    source: &[&str],
) {
    let folder_path = library.shared.join(root).join(folder);
    let metadata = folder_path.join(".youtube-downloader");
    fs::create_dir_all(&metadata).unwrap();
    let media = folder_path.join(format!("{title}{extension}"));
    let mut args = source.to_vec();
    args.push(media.to_str().unwrap());
    ffmpeg(&args);
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "color=red:s=64x64",
        "-frames:v",
        "1",
        metadata.join("abcdefghijk.jpg").to_str().unwrap(),
    ]);
    fs::write(folder_path.join(format!("{title}.info.json")), "{}").unwrap();
    let manifest = json!({
        "schema": youtube_item::MANIFEST_SCHEMA,
        "schemaVersion": 1,
        "source": { "url": "https://www.youtube.com/watch?v=abcdefghijk", "id": "abcdefghijk", "title": title, "channel": "Some Artist", "durationSeconds": 6 },
        "download": { "options": { "mediaType": if root == "_Videos" { "video" } else { "audio" } } },
        "naming": { "title": title, "channel": "Some Artist" },
        "chapters": [
            { "index": 1, "title": "Intro", "startTime": 0, "endTime": 2.35 },
            { "index": 2, "title": "It's Main", "startTime": 2.35, "endTime": 4.6 },
            { "index": 3, "title": "Outro", "startTime": 4.6, "endTime": 6 }
        ],
        "state": { "split": false, "coverEmbedded": false },
        "files": [
            { "path": format!("{title}{extension}"), "role": "media" },
            { "path": format!("{title}.info.json"), "role": "info-json" }
        ],
        "hasThumbnail": true
    });
    fs::write(
        metadata.join("abcdefghijk.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
}

async fn change(
    library: &Library,
    root_id: &str,
    item: &str,
    change: Change,
    destination: Option<&str>,
) {
    let identity = Identity::try_new("editor", ["users"]).unwrap();
    let root = library
        .config
        .resolve_visible_root(&identity, root_id)
        .unwrap();
    let located = youtube_item::locate(&root, item)
        .unwrap()
        .unwrap_or_else(|| panic!("no manifest beside {item}"));
    let destination_root =
        destination.map(|id| library.config.resolve_visible_root(&identity, id).unwrap());
    let tools = Tools::from_config(&library.config);
    let mut prepared = youtube_item::prepare(
        &library.config,
        tools.as_ref(),
        &located,
        &change,
        "editor",
        destination_root.as_ref(),
        &format!("test-{}", homelab_common::random_hex(6)),
    )
    .await
    .unwrap_or_else(|error| panic!("prepare {change:?}: {error}"));
    prepared.staging.persist();
    for action in &prepared.actions {
        apply_broker_action(&library.config, "editor", action)
            .unwrap_or_else(|error| panic!("apply {action:?}: {error}"));
    }
    // Every staged file was installed, so the staging folder is empty again.
    let staged = fs::read_dir(youtube_item::staging_root(&library.config))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .count();
    assert_eq!(staged, 0);
    assert!(prepared
        .actions
        .iter()
        .all(|action| !matches!(action, BrokerAction::ConvertVideo(_))));
}

fn manifest(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[tokio::test]
async fn a_download_splits_joins_recovers_and_moves_without_losing_a_sample() {
    let Some(library) = library() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    let music = library.shared.join("_Music");
    download(
        &library,
        "_Music",
        "Some Artist",
        "Live Set",
        ".flac",
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=f=440:d=6",
            "-f",
            "lavfi",
            "-i",
            "anoisesrc=d=6:a=0.05",
            "-filter_complex",
            "amix=inputs=2",
            "-ac",
            "2",
            "-ar",
            "48000",
            "-c:a",
            "flac",
        ],
    );
    // Another download in the same channel folder.
    fs::write(music.join("Some Artist/Other.flac"), b"other").unwrap();
    let original = decoded(&music.join("Some Artist/Live Set.flac"), "0:a");

    // Split: chapters get their own folder because the channel folder is shared.
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set.flac",
        Change::Split,
        None,
    )
    .await;
    let folder = music.join("Some Artist/Live Set");
    for name in [
        "01 - Intro.flac",
        "02 - It's Main.flac",
        "03 - Outro.flac",
        "Live Set.info.json",
    ] {
        assert!(folder.join(name).is_file(), "{name}");
    }
    assert!(folder.join(".youtube-downloader/abcdefghijk.jpg").is_file());
    assert!(music.join("_Tombstone/Some Artist/Live Set.flac").is_file());
    assert!(music
        .join("_Tombstone/Some Artist/.youtube-downloader/abcdefghijk.json")
        .is_file());
    assert_eq!(
        fs::read(music.join("Some Artist/Other.flac")).unwrap(),
        b"other"
    );
    let split = manifest(&folder.join(".youtube-downloader/abcdefghijk.json"));
    assert_eq!(
        split["state"],
        json!({ "split": true, "coverEmbedded": false })
    );
    assert_eq!(split["original"]["method"], json!("stream-copy"));
    assert_eq!(split["history"][0]["change"], json!("split"));

    // Join: the original samples come back exactly.
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set/02 - It's Main.flac",
        Change::Join,
        None,
    )
    .await;
    let joined = folder.join("Live Set.flac");
    assert_eq!(decoded(&joined, "0:a"), original);
    assert!(music
        .join("_Tombstone/Some Artist/Live Set/01 - Intro.flac")
        .is_file());

    // Cover in and out, streams untouched.
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set/Live Set.flac",
        Change::EmbedCover,
        None,
    )
    .await;
    assert!(has_cover(&joined));
    assert_eq!(decoded(&joined, "0:a"), original);
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set/Live Set.flac",
        Change::RemoveCover,
        None,
    )
    .await;
    assert!(!has_cover(&joined));
    assert_eq!(decoded(&joined, "0:a"), original);

    // Back into the channel folder, then into a collection in another library.
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set/Live Set.flac",
        Change::Move {
            layout: Layout::Channel,
            collection: None,
            destination_root_id: None,
        },
        None,
    )
    .await;
    assert!(music.join("Some Artist/Live Set.flac").is_file());
    assert!(music.join("Some Artist/Live Set.info.json").is_file());
    assert!(music
        .join("Some Artist/.youtube-downloader/abcdefghijk.json")
        .is_file());
    change(
        &library,
        "shared-music",
        "Some Artist/Live Set.flac",
        Change::Move {
            layout: Layout::Collection,
            collection: Some("Road Trip".into()),
            destination_root_id: Some("shared-audiobooks".into()),
        },
        Some("shared-audiobooks"),
    )
    .await;
    let moved = library.shared.join("_Audiobooks/Road Trip");
    assert_eq!(decoded(&moved.join("Live Set.flac"), "0:a"), original);
    let history = manifest(&moved.join(".youtube-downloader/abcdefghijk.json"))["history"].clone();
    let changes = history
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["change"].clone())
        .collect::<Vec<_>>();
    assert_eq!(
        changes,
        vec![
            json!("split"),
            json!("join"),
            json!("embed-cover"),
            json!("remove-cover"),
            json!("move"),
            json!("move")
        ]
    );
    assert!(!music.join("Some Artist/Live Set.flac").exists());
}

/// AAC in MP4 trims its encoder delay with an edit list that a split loses;
/// the join restores it, so the decode matches sample for sample.
#[tokio::test]
async fn aac_and_video_join_back_to_the_identical_decode() {
    let Some(library) = library() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    download(
        &library,
        "_Music",
        "Some Artist",
        "Song",
        ".m4a",
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=f=440:d=6",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
        ],
    );
    download(
        &library,
        "_Videos",
        "Some Artist",
        "Clip",
        ".mp4",
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc2=s=160x120:r=25:d=6",
            "-f",
            "lavfi",
            "-i",
            "sine=f=440:d=6",
            "-c:v",
            "libx264",
            "-g",
            "25",
            "-c:a",
            "aac",
        ],
    );
    for (root, root_id, title, extension) in [
        ("_Music", "shared-music", "Song", ".m4a"),
        ("_Videos", "shared-videos", "Clip", ".mp4"),
    ] {
        let base = library.shared.join(root).join("Some Artist");
        let source = base.join(format!("{title}{extension}"));
        let audio = decoded(&source, "0:a");
        let video = (root == "_Videos").then(|| decoded(&source, "0:V"));
        change(
            &library,
            root_id,
            &format!("Some Artist/{title}{extension}"),
            Change::Split,
            None,
        )
        .await;
        change(
            &library,
            root_id,
            &format!("Some Artist/01 - Intro{extension}"),
            Change::Join,
            None,
        )
        .await;
        let joined = base.join(format!("{title}{extension}"));
        assert_eq!(decoded(&joined, "0:a"), audio, "{title} audio");
        if let Some(video) = video {
            assert_eq!(decoded(&joined, "0:V"), video, "{title} video");
        }
        // The joined file carries the chapter markers again.
        let chapters = Command::new("ffprobe")
            .args(["-v", "error", "-show_chapters", "-of", "json"])
            .arg(&joined)
            .output()
            .unwrap();
        let chapters: Value = serde_json::from_slice(&chapters.stdout).unwrap();
        assert_eq!(
            chapters["chapters"].as_array().unwrap().len(),
            3,
            "{title} chapters"
        );
        assert_eq!(chapters["chapters"][1]["tags"]["title"], json!("It's Main"));
    }
}
