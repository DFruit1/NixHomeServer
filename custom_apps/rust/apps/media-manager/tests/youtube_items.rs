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

/// Preview a change and apply it through the broker. Returns what the
/// preview reported: its summary and its notes.
async fn change(
    library: &Library,
    root_id: &str,
    item: &str,
    change: Change,
    destination: Option<&str>,
) -> (Value, Vec<String>) {
    try_change(library, root_id, item, change, destination)
        .await
        .unwrap_or_else(|error| panic!("{error}"))
}

async fn try_change(
    library: &Library,
    root_id: &str,
    item: &str,
    change: Change,
    destination: Option<&str>,
) -> Result<(Value, Vec<String>), String> {
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
    .map_err(|error| format!("prepare {change:?}: {error}"))?;
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
    Ok((prepared.summary.clone(), prepared.warnings.clone()))
}

fn sha256(path: &Path) -> String {
    let output = Command::new("sha256sum")
        .arg(path)
        .output()
        .expect("sha256sum");
    assert!(output.status.success(), "sha256sum {}", path.display());
    String::from_utf8(output.stdout).unwrap()[..64].to_string()
}

/// Rewrite a file's container with a new title tag; its streams are copied.
fn retag(path: &Path) {
    let extension = path.extension().unwrap().to_str().unwrap();
    let temporary = path.with_extension(format!("retag.{extension}"));
    ffmpeg(&[
        "-i",
        path.to_str().unwrap(),
        "-map",
        "0",
        "-c",
        "copy",
        "-metadata",
        "title=Changed later",
        temporary.to_str().unwrap(),
    ]);
    fs::rename(&temporary, path).unwrap();
}

fn manifest(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[tokio::test]
async fn a_download_splits_joins_recovers_and_moves_without_losing_a_byte() {
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
    let original_sha256 = sha256(&music.join("Some Artist/Live Set.flac"));

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
    // The original is on record, and its container is kept in the restore file.
    assert_eq!(split["original"]["name"], json!("Live Set.flac"));
    assert_eq!(split["original"]["sha256"], json!(original_sha256));
    let restore = folder.join(".youtube-downloader/abcdefghijk.restore");
    assert_eq!(
        split["original"]["restore"]["sha256"],
        json!(sha256(&restore))
    );
    let chapter_bytes = split["files"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|file| file["role"] == json!("chapter"))
        .map(|file| file["streams"][0]["bytes"].as_u64().unwrap())
        .sum::<u64>();
    assert_eq!(
        json!(chapter_bytes),
        split["original"]["streams"][0]["bytes"]
    );

    // A chapter re-tagged in the meantime still holds the same audio.
    retag(&folder.join("02 - It's Main.flac"));

    // Join: the original file comes back byte for byte.
    let (summary, notes) = change(
        &library,
        "shared-music",
        "Some Artist/Live Set/02 - It's Main.flac",
        Change::Join,
        None,
    )
    .await;
    let joined = folder.join("Live Set.flac");
    assert_eq!(summary["exact"], json!(true));
    assert!(
        notes.iter().any(|note| note.contains("byte for byte")),
        "{notes:?}"
    );
    assert_eq!(sha256(&joined), original_sha256);
    assert_eq!(decoded(&joined, "0:a"), original);
    assert!(!restore.exists());
    assert!(music
        .join("_Tombstone/Some Artist/Live Set/.youtube-downloader/abcdefghijk.restore")
        .is_file());
    let rejoined = manifest(&folder.join(".youtube-downloader/abcdefghijk.json"));
    assert_eq!(
        rejoined["state"],
        json!({ "split": false, "coverEmbedded": false })
    );
    assert!(rejoined.get("original").is_none());
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

/// Every container Media Manager catalogues comes back as the identical
/// file: AAC in M4A and MP4 (whose encoder-delay trim a chapter loses),
/// H.264 in MP4 and Matroska, MP3 and Opus.
#[tokio::test]
async fn every_container_joins_back_to_the_identical_file() {
    let Some(library) = library() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    let audio = ["-f", "lavfi", "-i", "sine=f=440:d=6"];
    let video = [
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
    ];
    let tags = [
        "-metadata",
        "title=Original Title",
        "-metadata",
        "comment=kept exactly",
    ];
    for (root, root_id, title, extension, codec) in [
        (
            "_Music",
            "shared-music",
            "Song",
            ".m4a",
            &["-c:a", "aac", "-b:a", "128k"][..],
        ),
        (
            "_Music",
            "shared-music",
            "Tune",
            ".mp3",
            &["-c:a", "libmp3lame", "-q:a", "4"][..],
        ),
        (
            "_Music",
            "shared-music",
            "Voice",
            ".opus",
            &["-c:a", "libopus", "-b:a", "96k"][..],
        ),
        ("_Videos", "shared-videos", "Clip", ".mp4", &[][..]),
        ("_Videos", "shared-videos", "Film", ".mkv", &[][..]),
    ] {
        let source_args = if root == "_Videos" {
            [&video[..], &tags[..]].concat()
        } else {
            [&audio[..], &tags[..], codec].concat()
        };
        // Each in a folder of its own, so the chapters stay beside it.
        download(&library, root, title, title, extension, &source_args);
        let base = library.shared.join(root).join(title);
        let source = base.join(format!("{title}{extension}"));
        let original_sha256 = sha256(&source);
        change(
            &library,
            root_id,
            &format!("{title}/{title}{extension}"),
            Change::Split,
            None,
        )
        .await;
        assert!(!source.exists(), "{title} was split");
        let (summary, _) = change(
            &library,
            root_id,
            &format!("{title}/01 - Intro{extension}"),
            Change::Join,
            None,
        )
        .await;
        assert_eq!(summary["exact"], json!(true), "{title}");
        assert_eq!(sha256(&source), original_sha256, "{title}");
    }
}

/// A split item that is moved takes its restore file along, and still joins
/// back to the identical file.
#[tokio::test]
async fn a_moved_split_still_joins_back_exactly() {
    let Some(library) = library() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    download(
        &library,
        "_Music",
        "Mix",
        "Mix",
        ".flac",
        &["-f", "lavfi", "-i", "sine=f=440:d=6", "-c:a", "flac"],
    );
    let music = library.shared.join("_Music");
    let original_sha256 = sha256(&music.join("Mix/Mix.flac"));
    change(
        &library,
        "shared-music",
        "Mix/Mix.flac",
        Change::Split,
        None,
    )
    .await;
    change(
        &library,
        "shared-music",
        "Mix/01 - Intro.flac",
        Change::Move {
            layout: Layout::Collection,
            collection: Some("Road Trip".into()),
            destination_root_id: Some("shared-audiobooks".into()),
        },
        Some("shared-audiobooks"),
    )
    .await;
    let moved = library.shared.join("_Audiobooks/Road Trip/Mix");
    assert!(moved
        .join(".youtube-downloader/abcdefghijk.restore")
        .is_file());
    let (summary, _) = change(
        &library,
        "shared-audiobooks",
        "Road Trip/Mix/03 - Outro.flac",
        Change::Join,
        None,
    )
    .await;
    assert_eq!(summary["exact"], json!(true));
    assert_eq!(sha256(&moved.join("Mix.flac")), original_sha256);
}

/// Without its restore file a split still joins, into a new container with
/// the identical audio and video, and says so. A chapter whose audio was
/// replaced is refused outright.
#[tokio::test]
async fn a_join_without_the_restore_file_keeps_the_streams_and_says_so() {
    let Some(library) = library() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    download(
        &library,
        "_Videos",
        "Clip",
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
    let folder = library.shared.join("_Videos/Clip");
    let source = folder.join("Clip.mp4");
    let (audio, video, original_sha256) = (
        decoded(&source, "0:a"),
        decoded(&source, "0:V"),
        sha256(&source),
    );
    change(
        &library,
        "shared-videos",
        "Clip/Clip.mp4",
        Change::Split,
        None,
    )
    .await;

    // A chapter with other audio in it is not the split's chapter any more.
    let chapter = folder.join("02 - It's Main.mp4");
    let kept = folder.join("kept.bin");
    fs::rename(&chapter, &kept).unwrap();
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "testsrc2=s=160x120:r=25:d=2",
        "-f",
        "lavfi",
        "-i",
        "sine=f=880:d=2",
        "-c:v",
        "libx264",
        "-c:a",
        "aac",
        chapter.to_str().unwrap(),
    ]);
    let refused = try_change(
        &library,
        "shared-videos",
        "Clip/01 - Intro.mp4",
        Change::Join,
        None,
    )
    .await
    .unwrap_err();
    assert!(
        refused.contains("02 - It's Main.mp4 no longer holds"),
        "{refused}"
    );
    fs::rename(&kept, &chapter).unwrap();

    fs::remove_file(folder.join(".youtube-downloader/abcdefghijk.restore")).unwrap();
    let (summary, notes) = change(
        &library,
        "shared-videos",
        "Clip/01 - Intro.mp4",
        Change::Join,
        None,
    )
    .await;
    assert_eq!(summary["exact"], json!(false));
    assert!(
        notes
            .iter()
            .any(|note| note.contains("restore file is missing")),
        "{notes:?}"
    );
    assert_eq!(decoded(&source, "0:a"), audio);
    assert_eq!(decoded(&source, "0:V"), video);
    assert_ne!(sha256(&source), original_sha256);
    // The rebuilt container carries the chapter markers from the manifest.
    let chapters = Command::new("ffprobe")
        .args(["-v", "error", "-show_chapters", "-of", "json"])
        .arg(&source)
        .output()
        .unwrap();
    let chapters: Value = serde_json::from_slice(&chapters.stdout).unwrap();
    assert_eq!(chapters["chapters"].as_array().unwrap().len(), 3);
    assert_eq!(chapters["chapters"][1]["tags"]["title"], json!("It's Main"));
}
