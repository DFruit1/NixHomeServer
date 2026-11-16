//! YouTube downloads that can be rearranged after the fact.
//!
//! The YouTube Downloader leaves a manifest beside every download, in a hidden
//! `.youtube-downloader/<video id>.json` (see the downloader's
//! `item-manifest.ts`). It records the chapters whether or not the media was
//! split, the original thumbnail, the names any folder layout is built from,
//! and for a split, the packets of the file it was cut from. That is enough to
//! undo or redo each download option here without downloading again:
//!
//! - split a single file into chapter files by copying coded packets (never
//!   re-encoding), keeping a restore file (`crate::youtube_restore`) with the
//!   original's container, and join chapter files back into the original byte
//!   for byte, checked against its recorded SHA-256;
//! - embed or remove the cover picture, again copying the coded streams;
//! - move the item between "by channel", its own folder or a named
//!   collection, and between libraries on the same storage.
//!
//! Every change is one confirmable plan: the preview does the ffmpeg work into
//! private staging, and the broker installs the result. Replaced files go to the
//! library's `_Tombstone` folder rather than being deleted, and the manifest is
//! rewritten to match, with the change appended to its `history`.
use crate::{
    broker::{
        open_directory_beneath, open_regular_file_beneath, opened_file_fingerprint, BrokerAction,
        InstallYoutubeItemFileAction, MoveAction,
    },
    config::{AppConfig, VisibleRoot, TOMBSTONE_FOLDER, YOUTUBE_ITEM_METADATA_FOLDER},
    media::{LibraryCategory, MediaKind},
    youtube_restore::{self, StreamData},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::Read,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub const MANIFEST_SCHEMA: &str = "youtube-downloader.item";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_MANIFESTS_PER_FOLDER: usize = 5000;
const MAX_FOLDER_ENTRIES: usize = 20_000;
/// Every chapter file is an inherited descriptor while joining, so the count
/// stays well inside the default 1024 open-file limit.
pub const MAX_CHAPTERS: usize = 300;
/// Intake subfolder holding staged files until the broker installs them.
pub const STAGING_DIRECTORY: &str = "youtube-items";
/// One ffmpeg pass reads or writes a whole file once.
const FFMPEG_TIMEOUT: Duration = Duration::from_secs(3 * 3600);

// ---------------------------------------------------------------------------
// The manifest
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub channel: Option<String>,
    #[serde(default)]
    pub uploader: Option<String>,
    #[serde(default)]
    pub release_date: Option<String>,
    #[serde(default)]
    pub upload_date: Option<String>,
    #[serde(default)]
    pub duration_seconds: Option<f64>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Naming {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub channel: String,
    #[serde(default)]
    pub date: Option<String>,
    #[serde(default)]
    pub year: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Chapter {
    pub index: u32,
    pub title: String,
    pub start_time: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_time: Option<f64>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ItemState {
    pub split: bool,
    pub cover_embedded: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OriginalStream {
    #[serde(rename = "type")]
    pub kind: String,
    pub codec: String,
    pub time_base: String,
    pub start_pts: i64,
    /// Length and SHA-256 of the stream's raw data (its packets end to end).
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub sha256: String,
}

/// The restore file kept as `<manifest stem>.restore` in the metadata folder.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RestoreRef {
    pub bytes: u64,
    pub sha256: String,
}

/// The single file a split was cut from.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Original {
    /// Its file name, restored on a join.
    #[serde(default)]
    pub name: String,
    /// With the dot, e.g. `.flac`.
    pub extension: String,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub sha256: String,
    /// Whether it carried the thumbnail as embedded cover art.
    #[serde(default)]
    pub cover_embedded: bool,
    pub method: String,
    pub streams: Vec<OriginalStream>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore: Option<RestoreRef>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ManifestFile {
    pub path: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<f64>,
    /// A chapter file's share of each of the original's streams.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub streams: Option<Vec<StreamData>>,
}

impl ManifestFile {
    fn is_media(&self) -> bool {
        self.role == "media" || self.role == "chapter"
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema: String,
    pub schema_version: u32,
    #[serde(default)]
    pub source: Source,
    #[serde(default)]
    pub naming: Naming,
    #[serde(default)]
    pub chapters: Vec<Chapter>,
    #[serde(default)]
    pub state: ItemState,
    #[serde(default)]
    pub original: Option<Original>,
    #[serde(default)]
    pub files: Vec<ManifestFile>,
    #[serde(default)]
    pub has_thumbnail: bool,
    #[serde(default)]
    pub download: Value,
    #[serde(default)]
    pub history: Vec<Value>,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let manifest = serde_json::from_slice::<Self>(bytes).ok()?;
        (manifest.schema == MANIFEST_SCHEMA && manifest.schema_version == 1).then_some(manifest)
    }

    /// Media files in chapter order.
    pub fn media_files(&self) -> Vec<&ManifestFile> {
        let mut media = self
            .files
            .iter()
            .filter(|file| file.is_media())
            .collect::<Vec<_>>();
        media.sort_by_key(|file| file.chapter.unwrap_or(0));
        media
    }

    pub fn media_type(&self) -> &str {
        self.download["options"]["mediaType"]
            .as_str()
            .unwrap_or("audio")
    }

    fn title(&self) -> String {
        if self.naming.title.trim().is_empty() {
            sanitize_segment(&self.source.title, "Unknown Title")
        } else {
            self.naming.title.clone()
        }
    }

    fn channel(&self) -> String {
        if self.naming.channel.trim().is_empty() {
            let channel = self
                .source
                .channel
                .as_deref()
                .or(self.source.uploader.as_deref())
                .unwrap_or("");
            sanitize_segment(channel, "Unknown Channel")
        } else {
            self.naming.channel.clone()
        }
    }
}

/// A manifest found beside a library item.
#[derive(Clone, Debug)]
pub struct Located {
    pub root: VisibleRoot,
    /// The item folder relative to the root, `""` for the root itself.
    pub folder: String,
    /// The manifest's file stem in the metadata folder.
    pub stem: String,
    pub manifest: Manifest,
    pub raw: Value,
}

impl Located {
    fn root_path(&self) -> &Path {
        Path::new(&self.root.resolved_path)
    }

    fn in_folder(&self, path: &str) -> String {
        join(&self.folder, path)
    }

    fn manifest_path(&self) -> String {
        self.in_folder(&format!(
            "{YOUTUBE_ITEM_METADATA_FOLDER}/{}.json",
            self.stem
        ))
    }

    fn thumbnail_path(&self) -> String {
        self.in_folder(&format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{}.jpg", self.stem))
    }

    fn restore_path(&self) -> String {
        self.in_folder(&format!(
            "{YOUTUBE_ITEM_METADATA_FOLDER}/{}.restore",
            self.stem
        ))
    }

    /// Whether a join can rebuild the original file byte for byte.
    pub fn exact_restore(&self) -> bool {
        self.manifest
            .original
            .as_ref()
            .is_some_and(|original| original.restore.is_some() && !original.sha256.is_empty())
            && exists_beneath(self.root_path(), &self.restore_path())
    }

    fn extension(&self) -> String {
        self.manifest
            .media_files()
            .first()
            .and_then(|file| extension_of(&file.path))
            .map(|extension| format!(".{extension}"))
            .unwrap_or_default()
    }
}

fn join(parent: &str, child: &str) -> String {
    match (parent.is_empty(), child.is_empty()) {
        (true, _) => child.to_string(),
        (_, true) => parent.to_string(),
        _ => format!("{parent}/{child}"),
    }
}

fn parent_and_leaf(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}

fn extension_of(path: &str) -> Option<String> {
    let leaf = parent_and_leaf(path).1;
    leaf.rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
}

/// Names of the regular entries of a folder beneath `root`, read through a
/// contained descriptor.
fn folder_names(root: &Path, folder: &str) -> Result<Vec<String>, String> {
    let directory = if folder.is_empty() {
        File::open(root).map_err(|error| format!("open library root: {error}"))?
    } else {
        open_directory_beneath(root, folder).map_err(|error| error.to_string())?
    };
    let mut names = Vec::new();
    for (index, entry) in fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|error| format!("list folder: {error}"))?
        .enumerate()
    {
        if index >= MAX_FOLDER_ENTRIES {
            return Err("The folder holds too many files to inspect safely.".into());
        }
        if let Ok(name) = entry
            .map_err(|error| error.to_string())?
            .file_name()
            .into_string()
        {
            names.push(name);
        }
    }
    names.sort();
    Ok(names)
}

fn read_beneath(root: &Path, path: &str, limit: u64) -> Result<Vec<u8>, String> {
    let file = open_regular_file_beneath(root, path).map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("read {path}: {error}"))?;
    if bytes.len() as u64 > limit {
        return Err(format!("{path} is too large"));
    }
    Ok(bytes)
}

fn exists_beneath(root: &Path, path: &str) -> bool {
    fs::symlink_metadata(root.join(path)).is_ok()
}

fn fingerprint_beneath(root: &Path, path: &str) -> Result<String, String> {
    let file = open_regular_file_beneath(root, path)
        .map_err(|_| format!("{path} could not be opened. Rescan the library and try again."))?;
    opened_file_fingerprint(&file).map_err(|error| error.to_string())
}

/// The manifest whose media includes `item_relative_path`, if the item came
/// from the YouTube Downloader.
pub fn locate(root: &VisibleRoot, item_relative_path: &str) -> Result<Option<Located>, String> {
    let root_path = Path::new(&root.resolved_path);
    let (folder, leaf) = parent_and_leaf(item_relative_path);
    let metadata_folder = join(folder, YOUTUBE_ITEM_METADATA_FOLDER);
    let Ok(names) = folder_names(root_path, &metadata_folder) else {
        return Ok(None);
    };
    for name in names
        .iter()
        .filter(|name| name.ends_with(".json") && !name.starts_with('.'))
        .take(MAX_MANIFESTS_PER_FOLDER)
    {
        let Ok(bytes) = read_beneath(root_path, &join(&metadata_folder, name), MAX_MANIFEST_BYTES)
        else {
            continue;
        };
        let Some(manifest) = Manifest::parse(&bytes) else {
            continue;
        };
        if manifest
            .files
            .iter()
            .any(|file| file.is_media() && file.path == leaf)
        {
            let raw = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
            return Ok(Some(Located {
                root: root.clone(),
                folder: folder.to_string(),
                stem: name.trim_end_matches(".json").to_string(),
                manifest,
                raw,
            }));
        }
    }
    Ok(None)
}

// ---------------------------------------------------------------------------
// Names and layouts
// ---------------------------------------------------------------------------

/// The downloader's `sanitizeSegment`: a safe single path component.
pub fn sanitize_segment(value: &str, fallback: &str) -> String {
    let replaced = value
        .chars()
        .map(|character| {
            if matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            ) || character.is_control()
            {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    let collapsed = replaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed =
        collapsed.trim_matches(|character: char| character == '.' || character.is_whitespace());
    let cleaned = trimmed.chars().take(120).collect::<String>();
    let cleaned = cleaned
        .trim_end_matches(|character: char| character == '.' || character.is_whitespace())
        .to_string();
    if cleaned.is_empty() {
        return fallback.to_string();
    }
    let stem = cleaned
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let reserved = matches!(stem.as_str(), "con" | "prn" | "aux" | "nul")
        || ((stem.starts_with("com") || stem.starts_with("lpt"))
            && stem.len() == 4
            && stem.as_bytes()[3].is_ascii_digit()
            && stem.as_bytes()[3] != b'0');
    if reserved {
        format!("{cleaned}_")
    } else {
        cleaned
    }
}

/// The downloader's chapter file name: `NN - <title>.<ext>`.
pub fn chapter_file_name(chapter: &Chapter, total: usize, extension: &str) -> String {
    let width = total.to_string().len().max(2);
    format!(
        "{:0width$} - {}{extension}",
        chapter.index,
        sanitize_segment(&chapter.title, "Chapter"),
    )
}

/// Where a layout files an item, relative to the library root.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Layout {
    /// In the channel's folder; a split gets its own folder inside it.
    Channel,
    /// In its own folder named after the video.
    OwnFolder,
    /// In a named collection folder; a split gets its own folder inside it.
    Collection,
}

pub fn destination_folder(
    manifest: &Manifest,
    layout: &Layout,
    collection: Option<&str>,
    split: bool,
) -> Result<String, String> {
    let title = manifest.title();
    let parent = match layout {
        Layout::Channel => manifest.channel(),
        Layout::OwnFolder => return Ok(title),
        Layout::Collection => {
            let name = collection.map(str::trim).unwrap_or_default();
            if name.is_empty() {
                return Err("Name the collection to move this into.".into());
            }
            sanitize_segment(name, "Collection")
        }
    };
    Ok(if split { join(&parent, &title) } else { parent })
}

/// How the item's current folder relates to its names, for display.
pub fn describe_layout(located: &Located) -> Value {
    let title = located.manifest.title();
    let channel = located.manifest.channel();
    let components = located
        .folder
        .split('/')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    let last = components.last().copied().unwrap_or_default();
    let parent = components
        .len()
        .checked_sub(2)
        .and_then(|index| components.get(index))
        .copied()
        .unwrap_or_default();
    let dated = located
        .manifest
        .naming
        .date
        .as_deref()
        .is_some_and(|date| last == format!("{date} - {title}"));
    let (layout, collection) = if components.is_empty() {
        ("library-root", None)
    } else if last == channel || (last == title && parent == channel) {
        ("channel", None)
    } else if (last == title || dated)
        && components.len() <= 2
        && (parent.is_empty() || parent.len() == 4)
    {
        ("own-folder", None)
    } else if last == title && !parent.is_empty() {
        ("collection", Some(parent))
    } else {
        ("collection", Some(last))
    };
    json!({ "layout": layout, "collection": collection })
}

// ---------------------------------------------------------------------------
// ffmpeg
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
}

impl Tools {
    pub fn from_config(config: &AppConfig) -> Option<Self> {
        let ffprobe = config.ffprobe_path.clone()?;
        Some(Self {
            ffmpeg: ffprobe.with_file_name("ffmpeg"),
            ffprobe,
        })
    }
}

/// Library files handed to ffmpeg as inherited descriptors, so it reads
/// exactly the files opened with containment checks and never a path.
struct Inherited<'a> {
    files: Vec<&'a File>,
    base: i32,
}

impl<'a> Inherited<'a> {
    fn new(files: Vec<&'a File>) -> Self {
        // Above every source descriptor, so installing one never closes another.
        let base = files
            .iter()
            .map(|file| file.as_raw_fd())
            .max()
            .unwrap_or(2)
            .max(2)
            + 1;
        Self { files, base }
    }

    fn path(&self, index: usize) -> String {
        format!("/proc/self/fd/{}", self.base + index as i32)
    }
}

async fn run(program: &Path, args: &[String], inherited: &Inherited<'_>) -> Result<String, String> {
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let sources = inherited
        .files
        .iter()
        .map(|file| file.as_raw_fd())
        .collect::<Vec<_>>();
    let base = inherited.base;
    // SAFETY: only async-signal-safe dup2 calls run between fork and exec.
    unsafe {
        command.pre_exec(move || {
            for (index, source) in sources.iter().enumerate() {
                if libc::dup2(*source, base + index as i32) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|error| format!("start {}: {error}", program.display()))?;
    let output = tokio::time::timeout(FFMPEG_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "ffmpeg took too long and was stopped.".to_string())?
        .map_err(|error| format!("wait for ffmpeg: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim();
        return Err(if detail.is_empty() {
            format!("ffmpeg exited with {}", output.status)
        } else {
            detail.chars().take(600).collect()
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

/// `-map 0:V? -map 0:a`: video that is not a cover picture, then audio.
fn programme_maps(input: usize) -> Vec<String> {
    vec![
        "-map".into(),
        format!("{input}:V?"),
        "-map".into(),
        format!("{input}:a"),
    ]
}

pub fn parse_stream_hashes(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(|line| {
            let (_, hash) = line.trim().rsplit_once(",MD5=")?;
            (hash.len() == 32 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()))
                .then(|| hash.to_ascii_lowercase())
        })
        .collect()
}

#[derive(Clone, Debug)]
struct ProbedStream {
    index: usize,
    kind: String,
    codec: String,
    time_base: String,
}

/// Programme streams (non-cover video first, then audio) of input `path`.
async fn programme_streams(
    tools: &Tools,
    path: &str,
    inherited: &Inherited<'_>,
) -> Result<Vec<ProbedStream>, String> {
    let output = run(
        &tools.ffprobe,
        &strings(&[
            "-v",
            "error",
            "-show_entries",
            "stream=index,codec_type,codec_name,time_base:stream_disposition=attached_pic",
            "-of",
            "json",
            path,
        ]),
        inherited,
    )
    .await?;
    let value: Value = serde_json::from_str(&output).map_err(|error| error.to_string())?;
    let mut streams = value["streams"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|stream| {
            let kind = stream["codec_type"].as_str()?;
            let cover = stream["disposition"]["attached_pic"].as_i64() == Some(1);
            ((kind == "video" && !cover) || kind == "audio").then(|| ProbedStream {
                index: stream["index"].as_u64().unwrap_or(0) as usize,
                kind: kind.to_string(),
                codec: stream["codec_name"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string(),
                time_base: stream["time_base"].as_str().unwrap_or("1/1000").to_string(),
            })
        })
        .collect::<Vec<_>>();
    streams.sort_by_key(|stream| (stream.kind == "audio", stream.index));
    if !streams.iter().any(|stream| stream.kind == "audio") {
        return Err("The file has no audio stream.".into());
    }
    Ok(streams)
}

/// Earliest presentation timestamp per stream index among the first packets.
async fn earliest_pts(
    tools: &Tools,
    path: &str,
    inherited: &Inherited<'_>,
) -> Result<BTreeMap<usize, i64>, String> {
    let output = run(
        &tools.ffprobe,
        &strings(&[
            "-v",
            "error",
            "-read_intervals",
            "%+#256",
            "-show_entries",
            "packet=stream_index,pts",
            "-of",
            "json",
            path,
        ]),
        inherited,
    )
    .await?;
    let value: Value = serde_json::from_str(&output).map_err(|error| error.to_string())?;
    let mut earliest = BTreeMap::new();
    for packet in value["packets"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let (Some(index), Some(pts)) = (packet["stream_index"].as_u64(), packet["pts"].as_i64())
        else {
            continue;
        };
        earliest
            .entry(index as usize)
            .and_modify(|current: &mut i64| *current = (*current).min(pts))
            .or_insert(pts);
    }
    Ok(earliest)
}

async fn stream_hashes(
    tools: &Tools,
    input_args: Vec<String>,
    maps: Vec<String>,
    inherited: &Inherited<'_>,
) -> Result<Vec<String>, String> {
    let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error"]);
    args.extend(input_args);
    args.extend(maps);
    args.extend(strings(&[
        "-c",
        "copy",
        "-f",
        "streamhash",
        "-hash",
        "md5",
        "-",
    ]));
    Ok(parse_stream_hashes(
        &run(&tools.ffmpeg, &args, inherited).await?,
    ))
}

/// Run file work that takes as long as the media is large off the async threads.
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|_| "A background step stopped unexpectedly.".to_string())?
}

/// Each programme stream's raw data (its packets end to end, no container).
struct Gathered {
    /// One file per stream, in programme order.
    paths: Vec<PathBuf>,
    totals: Vec<StreamData>,
    /// The share of each input file, per stream.
    per_file: Vec<Vec<StreamData>>,
}

impl Gathered {
    fn open(&self) -> Result<Vec<File>, String> {
        self.paths
            .iter()
            .map(|path| File::open(path).map_err(|error| format!("reopen stream data: {error}")))
            .collect()
    }

    fn discard(&self) {
        for path in &self.paths {
            let _ = fs::remove_file(path);
        }
    }
}

/// Read the streams named by `specifiers` from `files` in order, appending
/// each stream's raw data into one work file. This is what a restore file's
/// map refers to, and it is the same whatever container the packets are in.
async fn gather_stream_data(
    tools: &Tools,
    staging: &Staging,
    files: &[&File],
    specifiers: &[String],
    label: &str,
) -> Result<Gathered, String> {
    let paths = (0..specifiers.len())
        .map(|stream| staging.work_path(&format!("{label}.{stream}.bin")))
        .collect::<Vec<_>>();
    for path in &paths {
        File::create(path).map_err(|error| format!("prepare stream data: {error}"))?;
    }
    let mut per_file = Vec::new();
    for file in files {
        let inherited = Inherited::new(vec![*file]);
        let pieces = (0..specifiers.len())
            .map(|stream| staging.work_path(&format!("{label}.piece.{stream}.bin")))
            .collect::<Vec<_>>();
        let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error", "-y", "-i"]);
        args.push(inherited.path(0));
        for (specifier, piece) in specifiers.iter().zip(&pieces) {
            args.extend(["-map".into(), format!("0:{specifier}")]);
            args.extend(strings(&["-c", "copy", "-f", "data"]));
            args.push(piece.display().to_string());
        }
        run(&tools.ffmpeg, &args, &inherited).await?;
        let targets = paths.clone();
        per_file.push(
            blocking(move || {
                pieces
                    .iter()
                    .zip(&targets)
                    .map(|(piece, target)| {
                        let mut source = File::open(piece)
                            .map_err(|error| format!("read stream data: {error}"))?;
                        let mut out = fs::OpenOptions::new()
                            .append(true)
                            .open(target)
                            .map_err(|error| format!("collect stream data: {error}"))?;
                        let data = youtube_restore::append_hashed(&mut source, &mut out)?;
                        let _ = fs::remove_file(piece);
                        Ok(data)
                    })
                    .collect::<Result<Vec<_>, String>>()
            })
            .await?,
        );
    }
    let hashed = paths.clone();
    let totals = blocking(move || {
        hashed
            .iter()
            .map(|path| {
                File::open(path)
                    .map_err(|error| format!("read stream data: {error}"))
                    .and_then(|file| youtube_restore::hash_file(&file))
            })
            .collect::<Result<Vec<_>, String>>()
    })
    .await?;
    Ok(Gathered {
        paths,
        totals,
        per_file,
    })
}

fn seconds(pts: i64, time_base: &str) -> f64 {
    let (numerator, denominator) = time_base
        .split_once('/')
        .and_then(|(n, d)| Some((n.parse::<f64>().ok()?, d.parse::<f64>().ok()?)))
        .unwrap_or((1.0, 1000.0));
    pts as f64 * numerator / denominator
}

/// A line of an ffmpeg concat list.
pub fn concat_line(path: &str) -> String {
    format!("file '{}'", path.replace('\'', "'\\''"))
}

/// The cover arguments for one output, or `None` when its container cannot
/// carry a cover. `video_streams` is the number of programme video streams
/// mapped before the cover input `cover_input`.
pub fn cover_args(
    extension: &str,
    cover_input: usize,
    cover_path: &str,
    video_streams: usize,
) -> Option<Vec<String>> {
    match extension.trim_start_matches('.') {
        "flac" | "m4a" | "mp3" | "mp4" | "m4v" | "mov" => Some(vec![
            "-map".into(),
            format!("{cover_input}:v:0"),
            format!("-c:v:{video_streams}"),
            "copy".into(),
            format!("-disposition:v:{video_streams}"),
            "attached_pic".into(),
        ]),
        "mkv" | "mka" => Some(vec![
            "-attach".into(),
            cover_path.into(),
            "-metadata:s:t:0".into(),
            "mimetype=image/jpeg".into(),
            "-metadata:s:t:0".into(),
            "filename=cover.jpg".into(),
        ]),
        _ => None,
    }
}

pub fn cover_supported(extension: &str) -> bool {
    cover_args(extension, 1, "cover.jpg", 0).is_some()
}

/// FFMETADATA for a joined file: its tags and its chapter markers.
pub fn ffmetadata(manifest: &Manifest) -> String {
    let escape = |value: &str| {
        value
            .chars()
            .flat_map(|character| match character {
                '=' | ';' | '#' | '\\' | '\n' => vec!['\\', character],
                other => vec![other],
            })
            .collect::<String>()
    };
    let mut text = String::from(";FFMETADATA1\n");
    text.push_str(&format!("title={}\n", escape(&manifest.source.title)));
    if let Some(artist) = manifest
        .source
        .channel
        .as_deref()
        .or(manifest.source.uploader.as_deref())
    {
        text.push_str(&format!("artist={}\n", escape(artist)));
    }
    if let Some(date) = &manifest.naming.date {
        text.push_str(&format!("date={}\n", escape(date)));
    }
    if !manifest.source.url.is_empty() {
        text.push_str(&format!("purl={}\n", escape(&manifest.source.url)));
    }
    for (position, chapter) in manifest.chapters.iter().enumerate() {
        let end = chapter
            .end_time
            .or_else(|| {
                manifest
                    .chapters
                    .get(position + 1)
                    .map(|next| next.start_time)
            })
            .or(manifest.source.duration_seconds);
        let Some(end) = end.filter(|end| *end > chapter.start_time) else {
            continue;
        };
        text.push_str(&format!(
            "[CHAPTER]\nTIMEBASE=1/1000\nSTART={}\nEND={}\ntitle={}\n",
            (chapter.start_time * 1000.0).round() as i64,
            (end * 1000.0).round() as i64,
            escape(&chapter.title)
        ));
    }
    text
}

// ---------------------------------------------------------------------------
// Staging
// ---------------------------------------------------------------------------

pub fn staging_root(config: &AppConfig) -> PathBuf {
    crate::conversion_jobs::staging_root(config).join(STAGING_DIRECTORY)
}

/// Staged files and a private work folder, removed unless the plan takes
/// custody of the staged files.
pub struct Staging {
    root: PathBuf,
    work: PathBuf,
    prefix: String,
    staged: Vec<PathBuf>,
    counter: usize,
}

impl Staging {
    pub fn new(config: &AppConfig, request_id: &str) -> Result<Self, String> {
        let root = staging_root(config);
        fs::create_dir_all(&root).map_err(|error| format!("prepare staging: {error}"))?;
        let prefix = request_id
            .chars()
            .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
            .take(64)
            .collect::<String>();
        sweep_abandoned_work(&root);
        let work = root.join(format!(".work-{prefix}"));
        let _ = fs::remove_dir_all(&work);
        fs::create_dir(&work).map_err(|error| format!("prepare staging: {error}"))?;
        Ok(Self {
            root,
            work,
            prefix,
            staged: Vec::new(),
            counter: 0,
        })
    }

    fn work_path(&self, name: &str) -> PathBuf {
        self.work.join(name)
    }

    /// A fresh staged file name and path with `extension` (with the dot).
    fn next(&mut self, extension: &str) -> (String, PathBuf) {
        self.counter += 1;
        let name = format!("{}-{:03}{}", self.prefix, self.counter, extension);
        let path = self.root.join(&name);
        self.staged.push(path.clone());
        (name, path)
    }

    fn write(&mut self, extension: &str, bytes: &[u8]) -> Result<(String, String), String> {
        let (name, path) = self.next(extension);
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o660)
            .open(&path)
            .map_err(|error| format!("stage file: {error}"))?;
        std::io::Write::write_all(&mut file, bytes)
            .map_err(|error| format!("stage file: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("stage file: {error}"))?;
        Ok((name, staged_fingerprint(&path)?))
    }

    /// The plan journal now owns the staged files.
    pub fn persist(&mut self) {
        self.staged.clear();
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.work);
        for path in &self.staged {
            let _ = fs::remove_file(path);
        }
    }
}

/// Work folders a preview leaves only when the service stopped mid-way; no
/// preview runs for a day. Staged files themselves belong to plans, whose
/// expiry discards them.
fn sweep_abandoned_work(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let stale = entry
            .metadata()
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age > Duration::from_secs(24 * 3600));
        if stale && entry.file_name().to_string_lossy().starts_with(".work-") {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

fn staged_fingerprint(path: &Path) -> Result<String, String> {
    crate::broker::file_fingerprint(path).map_err(|error| format!("inspect staged file: {error}"))
}

// ---------------------------------------------------------------------------
// Plans
// ---------------------------------------------------------------------------

/// The requested change, as sent in a plan's `operation`.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "change", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Change {
    Split,
    Join,
    EmbedCover,
    RemoveCover,
    #[serde(rename_all = "camelCase")]
    Move {
        layout: Layout,
        #[serde(default)]
        collection: Option<String>,
        #[serde(default)]
        destination_root_id: Option<String>,
    },
}

impl Change {
    fn name(&self) -> &'static str {
        match self {
            Change::Split => "split",
            Change::Join => "join",
            Change::EmbedCover => "embed-cover",
            Change::RemoveCover => "remove-cover",
            Change::Move { .. } => "move",
        }
    }
}

/// A prepared change: broker actions plus what the preview shows.
pub struct Prepared {
    pub actions: Vec<BrokerAction>,
    pub warnings: Vec<String>,
    pub summary: Value,
    pub staging: Staging,
}

/// Which changes the item's current state allows, with the reason when not.
pub fn available_changes(located: &Located, tools_available: bool) -> Value {
    let manifest = &located.manifest;
    let extension = located.extension();
    let media = manifest.media_files();
    let unavailable = |reason: &str| json!({ "available": false, "reason": reason });
    let ok = json!({ "available": true });
    let needs_tools = |value: Value| {
        if tools_available {
            value
        } else {
            unavailable("ffmpeg is not available on this server.")
        }
    };
    let split = if manifest.state.split {
        unavailable("It is already split into chapters.")
    } else if manifest.chapters.len() < 2 {
        unavailable("It has fewer than two chapters.")
    } else if manifest.chapters.len() > MAX_CHAPTERS {
        unavailable("It has too many chapters to split here.")
    } else if media.len() != 1 {
        unavailable("It is not a single media file.")
    } else {
        needs_tools(ok.clone())
    };
    let join = if !manifest.state.split {
        unavailable("It is already one file.")
    } else if manifest.original.is_none() {
        unavailable("Its manifest does not record the original these chapters were cut from.")
    } else if media.len() > MAX_CHAPTERS {
        unavailable("It has too many chapter files to join here.")
    } else {
        needs_tools(ok.clone())
    };
    let embed = if manifest.state.cover_embedded {
        unavailable("The cover is already embedded.")
    } else if !manifest.has_thumbnail {
        unavailable("The original thumbnail was not kept.")
    } else if !cover_supported(&extension) {
        unavailable("This file type cannot carry a cover picture.")
    } else {
        needs_tools(ok.clone())
    };
    let remove = if manifest.state.cover_embedded {
        needs_tools(ok.clone())
    } else {
        unavailable("No cover is embedded.")
    };
    json!({
        "split": split,
        "join": join,
        "embedCover": embed,
        "removeCover": remove,
        "move": ok,
    })
}

/// The item's files that exist, as (manifest entry, path relative to root, fingerprint).
fn present_files(located: &Located) -> Result<Vec<(ManifestFile, String, String)>, String> {
    let mut present = Vec::new();
    for file in &located.manifest.files {
        let path = located.in_folder(&file.path);
        if !exists_beneath(located.root_path(), &path) {
            if file.is_media() {
                return Err(format!(
                    "{} is missing, so the item cannot be changed. Rescan the library.",
                    file.path
                ));
            }
            continue;
        }
        let fingerprint = fingerprint_beneath(located.root_path(), &path)?;
        present.push((file.clone(), path, fingerprint));
    }
    Ok(present)
}

/// A free path in the root's tombstone folder for `path`.
fn tombstone_destination(root: &Path, path: &str, taken: &mut BTreeSet<String>) -> String {
    let base = join(TOMBSTONE_FOLDER, path);
    let (parent, leaf) = parent_and_leaf(&base);
    let (stem, extension) = match leaf.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => (stem.to_string(), format!(".{extension}")),
        _ => (leaf.to_string(), String::new()),
    };
    for attempt in 0..1000 {
        let candidate = if attempt == 0 {
            base.clone()
        } else {
            join(parent, &format!("{stem} ({attempt}){extension}"))
        };
        if !exists_beneath(root, &candidate) && taken.insert(candidate.clone()) {
            return candidate;
        }
    }
    join(
        parent,
        &format!("{stem} ({}){extension}", homelab_common::random_hex(6)),
    )
}

struct PlanBuilder<'a> {
    located: &'a Located,
    actions: Vec<BrokerAction>,
    taken: BTreeSet<String>,
    removed: Vec<String>,
    added: Vec<String>,
    moved: Vec<String>,
    /// For a join: whether the original file is rebuilt byte for byte.
    exact: Option<bool>,
    /// Things the preview should say about how the change is made.
    notes: Vec<String>,
}

impl<'a> PlanBuilder<'a> {
    fn new(located: &'a Located) -> Self {
        Self {
            located,
            actions: Vec::new(),
            taken: BTreeSet::new(),
            removed: Vec::new(),
            added: Vec::new(),
            moved: Vec::new(),
            exact: None,
            notes: Vec::new(),
        }
    }

    fn root_id(&self) -> String {
        self.located.root.id.clone()
    }

    /// Reserve `path` in `root_id` as a destination; it must be free.
    fn claim(&mut self, root: &Path, path: &str) -> Result<(), String> {
        if exists_beneath(root, path) || !self.taken.insert(path.to_string()) {
            return Err(format!(
                "{path} already exists, so nothing was changed. Move or rename it first."
            ));
        }
        Ok(())
    }

    fn tombstone(&mut self, path: &str, fingerprint: &str) {
        let destination = tombstone_destination(self.located.root_path(), path, &mut self.taken);
        self.actions.push(BrokerAction::Move(MoveAction {
            source_root_id: self.root_id(),
            source_relative_path: path.to_string(),
            destination_root_id: self.root_id(),
            destination_relative_path: destination,
            expected: fingerprint.to_string(),
        }));
        self.removed.push(path.to_string());
    }

    fn install(&mut self, root_id: &str, staged: (String, String), destination: &str) {
        self.actions.push(BrokerAction::InstallYoutubeItemFile(
            InstallYoutubeItemFileAction {
                staging_filename: staged.0,
                destination_root_id: root_id.to_string(),
                destination_relative_path: destination.to_string(),
                expected: staged.1,
            },
        ));
        self.added.push(destination.to_string());
    }

    fn relocate(&mut self, root_id: &str, from: &str, to: &str, fingerprint: &str) {
        self.actions.push(BrokerAction::Move(MoveAction {
            source_root_id: self.root_id(),
            source_relative_path: from.to_string(),
            destination_root_id: root_id.to_string(),
            destination_relative_path: to.to_string(),
            expected: fingerprint.to_string(),
        }));
        self.moved.push(to.to_string());
    }
}

/// The manifest rewritten for a change: new state, files and history entry.
fn rewritten_manifest(
    located: &Located,
    change: &Change,
    username: &str,
    state: &ItemState,
    original: Option<&Original>,
    files: &[ManifestFile],
) -> Result<Vec<u8>, String> {
    let mut raw = located.raw.clone();
    raw["state"] = serde_json::to_value(state).map_err(|error| error.to_string())?;
    match original {
        Some(original) => {
            raw["original"] = serde_json::to_value(original).map_err(|error| error.to_string())?
        }
        None => {
            if let Some(object) = raw.as_object_mut() {
                object.remove("original");
            }
        }
    }
    raw["files"] = serde_json::to_value(files).map_err(|error| error.to_string())?;
    let mut entry = json!({
        "at": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "by": username,
        "change": change.name(),
    });
    if let Change::Move {
        layout,
        collection,
        destination_root_id,
    } = change
    {
        entry["from"] = json!({ "rootId": located.root.id, "folder": located.folder });
        entry["layout"] = json!(layout);
        if let Some(collection) = collection {
            entry["collection"] = json!(collection);
        }
        if let Some(root) = destination_root_id {
            entry["rootId"] = json!(root);
        }
    }
    match raw["history"].as_array_mut() {
        Some(history) => history.push(entry),
        None => raw["history"] = json!([entry]),
    }
    let mut bytes = serde_json::to_vec_pretty(&raw).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    Ok(bytes)
}

/// Swap the manifest: the old one to the tombstone, the new one installed.
fn replace_manifest(
    builder: &mut PlanBuilder<'_>,
    staging: &mut Staging,
    root_id: &str,
    destination_folder: &str,
    stem: &str,
    bytes: &[u8],
) -> Result<(), String> {
    let old = builder.located.manifest_path();
    let fingerprint = fingerprint_beneath(builder.located.root_path(), &old)?;
    builder.tombstone(&old, &fingerprint);
    let staged = staging.write(".json", bytes)?;
    let destination = join(
        destination_folder,
        &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{stem}.json"),
    );
    builder.install(root_id, staged, &destination);
    Ok(())
}

fn summary(builder: &PlanBuilder<'_>, change: &Change, folder: &str, root: &VisibleRoot) -> Value {
    let visible = |paths: &[String]| {
        paths
            .iter()
            .filter(|path| !path.contains(&format!("{YOUTUBE_ITEM_METADATA_FOLDER}/")))
            .cloned()
            .collect::<Vec<_>>()
    };
    json!({
        "change": change.name(),
        "rootId": root.id,
        "rootLabel": root.label,
        "folder": folder,
        "removed": visible(&builder.removed),
        "added": visible(&builder.added),
        "moved": visible(&builder.moved),
        "exact": builder.exact,
    })
}

/// The item's media file, opened and checked against its fingerprint.
fn open_media(located: &Located, path: &str, fingerprint: &str) -> Result<File, String> {
    let file = open_regular_file_beneath(located.root_path(), path)
        .map_err(|_| format!("{path} could not be opened. Rescan the library and try again."))?;
    if opened_file_fingerprint(&file).ok().as_deref() != Some(fingerprint) {
        return Err(format!(
            "{path} changed while it was being prepared. Try again."
        ));
    }
    Ok(file)
}

fn thumbnail_file(located: &Located) -> Option<File> {
    if !located.manifest.has_thumbnail {
        return None;
    }
    open_regular_file_beneath(located.root_path(), &located.thumbnail_path()).ok()
}

pub async fn prepare(
    config: &AppConfig,
    tools: Option<&Tools>,
    located: &Located,
    change: &Change,
    username: &str,
    destination_root: Option<&VisibleRoot>,
    request_id: &str,
) -> Result<Prepared, String> {
    let mut staging = Staging::new(config, request_id)?;
    let changes = available_changes(located, tools.is_some());
    let key = match change {
        Change::Split => "split",
        Change::Join => "join",
        Change::EmbedCover => "embedCover",
        Change::RemoveCover => "removeCover",
        Change::Move { .. } => "move",
    };
    if changes[key]["available"] != json!(true) {
        return Err(changes[key]["reason"]
            .as_str()
            .unwrap_or("This change is not available.")
            .to_string());
    }
    let present = present_files(located)?;
    let mut builder = PlanBuilder::new(located);
    let mut warnings = Vec::new();
    let folder = match change {
        Change::Split => {
            let tools = tools.ok_or("ffmpeg is not available on this server.")?;
            split(
                &mut builder,
                &mut staging,
                tools,
                &present,
                username,
                change,
            )
            .await?
        }
        Change::Join => {
            let tools = tools.ok_or("ffmpeg is not available on this server.")?;
            join_chapters(
                &mut builder,
                &mut staging,
                tools,
                &present,
                username,
                change,
            )
            .await?
        }
        Change::EmbedCover | Change::RemoveCover => {
            let tools = tools.ok_or("ffmpeg is not available on this server.")?;
            recover(
                &mut builder,
                &mut staging,
                tools,
                &present,
                username,
                change,
            )
            .await?
        }
        Change::Move {
            layout, collection, ..
        } => {
            let root = destination_root.unwrap_or(&located.root);
            move_item(
                &mut builder,
                &mut staging,
                &present,
                username,
                change,
                root,
                layout,
                collection.as_deref(),
                &mut warnings,
            )?
        }
    };
    let root = destination_root.unwrap_or(&located.root);
    let summary = summary(&builder, change, &folder, root);
    warnings.append(&mut builder.notes);
    warnings
        .push("Replaced files are moved to the library's _Tombstone folder, not deleted.".into());
    Ok(Prepared {
        actions: builder.actions,
        warnings,
        summary,
        staging,
    })
}

/// Whether `folder` holds media besides this item's own files.
fn shares_folder(located: &Located) -> Result<bool, String> {
    let own = located
        .manifest
        .files
        .iter()
        .map(|file| file.path.as_str())
        .collect::<BTreeSet<_>>();
    let category = located.root.category;
    Ok(folder_names(located.root_path(), &located.folder)?
        .iter()
        .filter(|name| !own.contains(name.as_str()))
        .any(|name| {
            extension_of(name).is_some_and(|extension| {
                category
                    .media_kinds()
                    .iter()
                    .any(|kind| kind.extensions().contains(&extension.as_str()))
                    && !MediaKind::Artwork
                        .extensions()
                        .contains(&extension.as_str())
                    && !MediaKind::Subtitle
                        .extensions()
                        .contains(&extension.as_str())
            })
        }))
}

async fn split(
    builder: &mut PlanBuilder<'_>,
    staging: &mut Staging,
    tools: &Tools,
    present: &[(ManifestFile, String, String)],
    username: &str,
    change: &Change,
) -> Result<String, String> {
    let located = builder.located;
    let manifest = &located.manifest;
    let (media, media_path, media_fingerprint) = present
        .iter()
        .find(|(file, _, _)| file.is_media())
        .ok_or("The media file is missing.")?;
    let extension = extension_of(&media.path)
        .map(|extension| format!(".{extension}"))
        .unwrap_or_default();
    // Chapter files only make sense together: in a folder shared with other
    // downloads they get a folder of their own, named after the video.
    let destination = if shares_folder(located)? {
        join(&located.folder, &manifest.title())
    } else {
        located.folder.clone()
    };
    let moving = destination != located.folder;
    if moving && exists_beneath(located.root_path(), &destination) {
        return Err(format!(
            "{destination} already exists, so the chapters have nowhere to go. Move or rename it first."
        ));
    }

    let source = open_media(located, media_path, media_fingerprint)?;
    let inherited = Inherited::new(vec![&source]);
    let input = inherited.path(0);
    let streams = programme_streams(tools, &input, &inherited).await?;
    let starts = earliest_pts(tools, &input, &inherited).await?;
    // The original itself, and the raw data of each of its streams.
    let hashed = source
        .try_clone()
        .map_err(|error| format!("read original: {error}"))?;
    let original_data = blocking(move || youtube_restore::hash_file(&hashed)).await?;
    let stream_indexes = streams
        .iter()
        .map(|stream| stream.index)
        .collect::<Vec<_>>();
    let source_data = gather_stream_data(
        tools,
        staging,
        &[&source],
        &stream_indexes
            .iter()
            .map(|index| index.to_string())
            .collect::<Vec<_>>(),
        "source",
    )
    .await?;
    let mut original = Original {
        name: parent_and_leaf(&media.path).1.to_string(),
        extension: extension.clone(),
        bytes: original_data.bytes,
        sha256: original_data.sha256.clone(),
        cover_embedded: manifest.state.cover_embedded,
        method: "stream-copy".into(),
        streams: streams
            .iter()
            .zip(&source_data.totals)
            .map(|(stream, data)| {
                Ok(OriginalStream {
                    kind: stream.kind.clone(),
                    codec: stream.codec.clone(),
                    time_base: stream.time_base.clone(),
                    start_pts: *starts
                        .get(&stream.index)
                        .ok_or("A stream has no timestamped packets.")?,
                    bytes: data.bytes,
                    sha256: data.sha256.clone(),
                })
            })
            .collect::<Result<Vec<_>, &str>>()?,
        restore: None,
    };

    // Cut at the chapter starts, copying packets.
    let chapters = &manifest.chapters;
    let mut previous = 0.0;
    let mut times = Vec::new();
    for chapter in chapters.iter().skip(1) {
        if !chapter.start_time.is_finite() || chapter.start_time <= previous {
            return Err(format!(
                "Chapter {} does not start after the chapter before it.",
                chapter.index
            ));
        }
        previous = chapter.start_time;
        times.push(format!("{:.6}", chapter.start_time));
    }
    let list = staging.work_path("segments.csv");
    let pattern = staging.work_path(&format!("%05d{extension}"));
    let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error", "-y", "-i"]);
    args.push(input.clone());
    args.extend(programme_maps(0));
    args.extend(strings(&["-c", "copy", "-f", "segment", "-segment_times"]));
    args.push(times.join(","));
    args.extend(strings(&["-reset_timestamps", "1", "-segment_list"]));
    args.push(list.display().to_string());
    args.extend(strings(&["-segment_list_type", "csv"]));
    args.push(pattern.display().to_string());
    run(&tools.ffmpeg, &args, &inherited).await?;
    let segments = parse_segment_list(
        &fs::read_to_string(&list).map_err(|error| format!("read the split: {error}"))?,
    )?;
    if segments.len() != chapters.len() {
        return Err(format!(
            "The split made {} files for {} chapters, so nothing was changed.",
            segments.len(),
            chapters.len()
        ));
    }

    // Tag each chapter and re-add the cover, copying the streams.
    let thumbnail = thumbnail_file(located);
    let cover = (manifest.state.cover_embedded && cover_supported(&extension))
        .then_some(thumbnail.as_ref())
        .flatten();
    let cover_inherited = Inherited::new(cover.into_iter().collect());
    let video_streams = streams
        .iter()
        .filter(|stream| stream.kind == "video")
        .count();
    let mut finished = Vec::new();
    for (position, (name, start, end)) in segments.iter().enumerate() {
        let chapter = &chapters[position];
        let (staged_name, staged_path) = staging.next(&extension);
        let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error", "-y", "-i"]);
        args.push(staging.work_path(name).display().to_string());
        let cover_path = cover.map(|_| cover_inherited.path(0));
        if let Some(cover_path) = &cover_path {
            args.extend([
                "-f".into(),
                "image2".into(),
                "-i".into(),
                cover_path.clone(),
            ]);
        }
        args.extend(strings(&["-map", "0", "-c", "copy"]));
        if let Some(cover_path) = &cover_path {
            args.extend(cover_args(&extension, 1, cover_path, video_streams).unwrap_or_default());
        }
        args.extend(strings(&[
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-metadata",
        ]));
        args.push(format!("title={}", chapter.title));
        args.push("-metadata".into());
        args.push(format!("track={}/{}", chapter.index, chapters.len()));
        args.push(staged_path.display().to_string());
        run(&tools.ffmpeg, &args, &cover_inherited).await?;
        finished.push((staged_name, staged_path, chapter.clone(), *start, *end));
    }

    // The finished chapters, read in order, must hold each stream's raw data
    // exactly. They keep the programme streams first, so those are addressed
    // by position (a cover comes after them).
    let opened = finished
        .iter()
        .map(|(_, path, ..)| File::open(path).map_err(|error| format!("reopen chapter: {error}")))
        .collect::<Result<Vec<_>, _>>()?;
    let chapter_data = gather_stream_data(
        tools,
        staging,
        &opened.iter().collect::<Vec<_>>(),
        &(0..streams.len())
            .map(|position| position.to_string())
            .collect::<Vec<_>>(),
        "chapters",
    )
    .await?;
    drop(opened);
    if chapter_data.totals != source_data.totals {
        return Err(
            "The chapter files did not add up to the original's audio and video data exactly, so nothing was changed."
                .into(),
        );
    }

    // Save what the chapters do not hold (the original's container), and
    // prove that it and the chapters' stream data rebuild the original byte
    // for byte before the original is let go.
    let packet_list = run(
        &tools.ffprobe,
        &[
            "-v".into(),
            "error".into(),
            "-show_entries".into(),
            "packet=stream_index,pos,size".into(),
            "-of".into(),
            "csv=p=0:nk=0".into(),
            input.clone(),
        ],
        &inherited,
    )
    .await?;
    let packets = youtube_restore::parse_packet_list(&packet_list, &stream_indexes);
    drop(packet_list);
    let (restore_name, restore_path) = staging.next(".restore");
    {
        let original_file = source
            .try_clone()
            .map_err(|error| format!("read original: {error}"))?;
        let dumps = source_data
            .open()?
            .into_iter()
            .zip(source_data.totals.clone())
            .collect::<Vec<_>>();
        let chapter_dumps = chapter_data.open()?;
        let sha256 = original_data.sha256.clone();
        let output = restore_path.clone();
        let expected = original_data.clone();
        let restore_data = blocking(move || {
            youtube_restore::build(&original_file, &sha256, &dumps, &packets, &output)?;
            let restore = File::open(&output).map_err(|error| format!("reopen restore file: {error}"))?;
            if youtube_restore::rebuilt_hash(&restore, &chapter_dumps)? != expected {
                return Err(
                    "The restore file would not rebuild the original exactly, so nothing was changed."
                        .to_string(),
                );
            }
            youtube_restore::hash_file(&restore)
        })
        .await?;
        original.restore = Some(RestoreRef {
            bytes: restore_data.bytes,
            sha256: restore_data.sha256,
        });
    }
    source_data.discard();
    chapter_data.discard();

    // Plan: chapters in, sidecars along, original and old manifest out.
    let root_id = builder.root_id();
    let root_path = located.root_path().to_path_buf();
    let total = chapters.len();
    let mut files = Vec::new();
    for (position, (staged_name, staged_path, chapter, start, end)) in finished.iter().enumerate() {
        let name = chapter_file_name(chapter, total, &extension);
        let path = join(&destination, &name);
        builder.claim(&root_path, &path)?;
        builder.install(
            &root_id,
            (staged_name.clone(), staged_fingerprint(staged_path)?),
            &path,
        );
        files.push(ManifestFile {
            path: name,
            role: "chapter".into(),
            chapter: Some(chapter.index),
            start: Some(*start),
            end: Some(*end),
            streams: chapter_data.per_file.get(position).cloned(),
        });
    }
    let restore_destination = join(
        &destination,
        &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{}.restore", located.stem),
    );
    builder.claim(&root_path, &restore_destination)?;
    builder.install(
        &root_id,
        (restore_name, staged_fingerprint(&restore_path)?),
        &restore_destination,
    );
    for (file, path, fingerprint) in present {
        if file.is_media() {
            continue;
        }
        if moving {
            let target = join(&destination, &file.path);
            builder.claim(&root_path, &target)?;
            builder.relocate(&root_id, path, &target, fingerprint);
        }
        files.push(file.clone());
    }
    if moving {
        move_companions(builder, &root_id, &destination, &located.stem)?;
    }
    builder.tombstone(media_path, media_fingerprint);
    let state = ItemState {
        split: true,
        cover_embedded: cover.is_some(),
    };
    let bytes = rewritten_manifest(located, change, username, &state, Some(&original), &files)?;
    replace_manifest(
        builder,
        staging,
        &root_id,
        &destination,
        &located.stem,
        &bytes,
    )?;
    Ok(destination)
}

/// Take the item's files in the metadata folder (its archived thumbnail and,
/// for a split, its restore file) along to `destination` under `stem`.
fn move_companions(
    builder: &mut PlanBuilder<'_>,
    root_id: &str,
    destination: &str,
    stem: &str,
) -> Result<(), String> {
    let located = builder.located;
    for (current, extension) in [
        (located.thumbnail_path(), "jpg"),
        (located.restore_path(), "restore"),
    ] {
        if !exists_beneath(located.root_path(), &current) {
            continue;
        }
        let fingerprint = fingerprint_beneath(located.root_path(), &current)?;
        let target = join(
            destination,
            &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{stem}.{extension}"),
        );
        builder.relocate(root_id, &current, &target, &fingerprint);
    }
    Ok(())
}

fn concat_input(list: &str, offset: Option<f64>) -> Vec<String> {
    let mut args = strings(&["-auto_convert", "0"]);
    if let Some(offset) = offset {
        args.push("-itsoffset".into());
        args.push(format!("{offset:.6}"));
    }
    args.extend(strings(&["-f", "concat", "-safe", "0", "-i"]));
    args.push(list.into());
    args
}

pub fn parse_segment_list(csv: &str) -> Result<Vec<(String, f64, f64)>, String> {
    csv.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let mut fields = line.rsplitn(3, ',');
            let end = fields.next().and_then(|value| value.parse().ok());
            let start = fields.next().and_then(|value| value.parse().ok());
            let name = fields
                .next()
                .map(|value| value.trim_matches('"').to_string());
            match (name, start, end) {
                (Some(name), Some(start), Some(end)) if !name.contains('/') => {
                    Ok((name, start, end))
                }
                _ => Err(format!("The split list could not be read: {line}")),
            }
        })
        .collect()
}

async fn join_chapters(
    builder: &mut PlanBuilder<'_>,
    staging: &mut Staging,
    tools: &Tools,
    present: &[(ManifestFile, String, String)],
    username: &str,
    change: &Change,
) -> Result<String, String> {
    let located = builder.located;
    let manifest = &located.manifest;
    let original = manifest
        .original
        .as_ref()
        .ok_or("The original these chapters were cut from is not recorded.")?;
    let mut chapters = present
        .iter()
        .filter(|(file, _, _)| file.is_media())
        .collect::<Vec<_>>();
    chapters.sort_by_key(|(file, _, _)| file.chapter.unwrap_or(0));
    if chapters.len() != manifest.media_files().len() {
        return Err("A chapter file is missing, so the chapters cannot be joined.".into());
    }
    let opened = chapters
        .iter()
        .map(|(_, path, fingerprint)| open_media(located, path, fingerprint))
        .collect::<Result<Vec<_>, _>>()?;

    // Every chapter must still hold its share of each stream, and together
    // they must hold the original's streams exactly. Only the coded data
    // counts: a chapter that was re-tagged or given another cover is fine.
    let positions = (0..original.streams.len())
        .map(|position| position.to_string())
        .collect::<Vec<_>>();
    let chapter_data = gather_stream_data(
        tools,
        staging,
        &opened.iter().collect::<Vec<_>>(),
        &positions,
        "chapters",
    )
    .await?;
    for ((file, _, _), found) in chapters.iter().zip(&chapter_data.per_file) {
        if file
            .streams
            .as_ref()
            .is_some_and(|recorded| recorded != found)
        {
            return Err(format!(
                "{} no longer holds the audio and video it was split with, so the chapters were not joined.",
                file.path
            ));
        }
    }
    let recorded = original
        .streams
        .iter()
        .map(|stream| StreamData {
            bytes: stream.bytes,
            sha256: stream.sha256.clone(),
        })
        .collect::<Vec<_>>();
    let hashes_recorded = recorded.iter().all(|stream| !stream.sha256.is_empty());
    if hashes_recorded && chapter_data.totals != recorded {
        return Err(
            "The chapter files no longer add up to the original's audio and video data, so they were not joined."
                .into(),
        );
    }

    // With the restore file, the original is rebuilt byte for byte.
    let exact = match rebuild_exactly(staging, located, original, &chapter_data).await {
        Ok(rebuilt) => rebuilt,
        Err(reason) => {
            builder.notes.push(format!(
                "{reason} The chapters are joined into a new file instead: its audio and video data are identical to the original's, but its tags, cover and the timing between chapters are rebuilt and can differ slightly."
            ));
            None
        }
    };
    let (staged_name, staged_path, name, cover_embedded) = match exact {
        Some((staged_name, staged_path)) => {
            builder.exact = Some(true);
            builder.notes.push(
                "The original file is rebuilt byte for byte and matched its recorded SHA-256."
                    .into(),
            );
            let name = if original.name.is_empty() || original.name.contains('/') {
                format!("{}{}", manifest.title(), original.extension)
            } else {
                original.name.clone()
            };
            (staged_name, staged_path, name, original.cover_embedded)
        }
        None => {
            builder.exact = Some(false);
            let (staged_name, staged_path, cover_embedded) =
                join_streams(staging, tools, located, original, &opened).await?;
            // The new file must hold exactly the chapters' stream data.
            let output =
                File::open(&staged_path).map_err(|error| format!("reopen joined file: {error}"))?;
            let joined =
                gather_stream_data(tools, staging, &[&output], &positions, "joined").await?;
            joined.discard();
            if joined.totals != chapter_data.totals {
                return Err(
                    "The joined file does not hold the chapters' audio and video data exactly, so nothing was changed."
                        .into(),
                );
            }
            (
                staged_name,
                staged_path,
                format!("{}{}", manifest.title(), original.extension),
                cover_embedded,
            )
        }
    };
    chapter_data.discard();
    drop(opened);

    let root_id = builder.root_id();
    let root_path = located.root_path().to_path_buf();
    let path = join(&located.folder, &name);
    builder.claim(&root_path, &path)?;
    builder.install(
        &root_id,
        (staged_name, staged_fingerprint(&staged_path)?),
        &path,
    );
    let mut files = vec![ManifestFile {
        path: name,
        role: "media".into(),
        chapter: None,
        start: None,
        end: None,
        streams: None,
    }];
    for (file, path, fingerprint) in present {
        if file.is_media() {
            builder.tombstone(path, fingerprint);
        } else {
            files.push(file.clone());
        }
    }
    // The chapters are gone, so their restore file has nothing left to restore.
    if exists_beneath(&root_path, &located.restore_path()) {
        let fingerprint = fingerprint_beneath(&root_path, &located.restore_path())?;
        builder.tombstone(&located.restore_path(), &fingerprint);
    }
    let state = ItemState {
        split: false,
        cover_embedded,
    };
    let bytes = rewritten_manifest(located, change, username, &state, None, &files)?;
    let folder = located.folder.clone();
    replace_manifest(builder, staging, &root_id, &folder, &located.stem, &bytes)?;
    Ok(folder)
}

/// Rebuild the original from its restore file and the chapters' stream data
/// into a staged file, accepted only with the original's size and SHA-256.
/// `Ok(None)` is never returned; an `Err` says why an exact rebuild is not
/// possible, and the caller falls back to joining the streams.
async fn rebuild_exactly(
    staging: &mut Staging,
    located: &Located,
    original: &Original,
    chapter_data: &Gathered,
) -> Result<Option<(String, PathBuf)>, String> {
    let reference = original
        .restore
        .clone()
        .filter(|_| !original.sha256.is_empty())
        .ok_or("This split has no restore file recorded.")?;
    let restore = open_regular_file_beneath(located.root_path(), &located.restore_path())
        .map_err(|_| "The restore file is missing.".to_string())?;
    let (staged_name, staged_path) = staging.next(&original.extension);
    let dumps = chapter_data.open()?;
    let output = staged_path.clone();
    let expected = StreamData {
        bytes: original.bytes,
        sha256: original.sha256.clone(),
    };
    let outcome = blocking(move || {
        let found = youtube_restore::hash_file(&restore)?;
        if found.sha256 != reference.sha256 || found.bytes != reference.bytes {
            return Err("The restore file has changed since the split.".to_string());
        }
        let file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o660)
            .open(&output)
            .map_err(|error| format!("stage rebuilt file: {error}"))?;
        let mut hashing = youtube_restore::Hashing::new(std::io::BufWriter::new(file));
        youtube_restore::rebuild(&restore, &dumps, &mut hashing)?;
        let (rebuilt, writer) = hashing.finish().map_err(|error| error.to_string())?;
        writer
            .into_inner()
            .map_err(|error| error.to_string())?
            .sync_all()
            .map_err(|error| error.to_string())?;
        if rebuilt != expected {
            return Err("The rebuilt file did not match the original's SHA-256.".to_string());
        }
        Ok(())
    })
    .await;
    match outcome {
        Ok(()) => Ok(Some((staged_name, staged_path))),
        Err(reason) => {
            let _ = fs::remove_file(&staged_path);
            Err(reason)
        }
    }
}

/// Join the chapters' streams into a new container: the audio and video data
/// are the original's, but the container is rebuilt. Used only when the
/// restore file is unavailable. Returns the staged file and whether it carries
/// the cover.
async fn join_streams(
    staging: &mut Staging,
    tools: &Tools,
    located: &Located,
    original: &Original,
    opened: &[File],
) -> Result<(String, PathBuf, bool), String> {
    let manifest = &located.manifest;
    let thumbnail = thumbnail_file(located);
    let cover = (manifest.state.cover_embedded && cover_supported(&original.extension))
        .then_some(thumbnail.as_ref())
        .flatten();
    // Chapter files first, then the cover, all as inherited descriptors.
    let mut sources = opened.iter().collect::<Vec<_>>();
    sources.extend(cover);
    let inherited = Inherited::new(sources);
    let first = inherited.path(0);

    // Each stream restarts where it started in the original, which restores
    // trims such as AAC's encoder delay that the first chapter lost.
    let first_streams = programme_streams(tools, &first, &inherited).await?;
    let first_starts = earliest_pts(tools, &first, &inherited).await?;
    if first_streams.len() != original.streams.len() {
        return Err("The chapter files do not have the original's streams.".into());
    }
    let concat = staging.work_path("chapters.txt");
    fs::write(
        &concat,
        (0..opened.len())
            .map(|index| concat_line(&inherited.path(index)))
            .collect::<Vec<_>>()
            .join("\n")
            + "\n",
    )
    .map_err(|error| format!("prepare join: {error}"))?;
    let metadata = staging.work_path("metadata.txt");
    fs::write(&metadata, ffmetadata(manifest)).map_err(|error| format!("prepare join: {error}"))?;

    let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error", "-y"]);
    let mut maps = Vec::new();
    for (position, (stream, recorded)) in first_streams.iter().zip(&original.streams).enumerate() {
        let chapter_start = first_starts
            .get(&stream.index)
            .ok_or("A chapter stream has no timestamped packets.")?;
        let offset = seconds(recorded.start_pts, &recorded.time_base)
            - seconds(*chapter_start, &stream.time_base);
        args.extend(concat_input(&concat.display().to_string(), Some(offset)));
        maps.extend(["-map".to_string(), format!("{position}:{position}")]);
    }
    let metadata_input = first_streams.len();
    args.extend([
        "-f".into(),
        "ffmetadata".into(),
        "-i".into(),
        metadata.display().to_string(),
    ]);
    let cover_path = cover.map(|_| inherited.path(opened.len()));
    if let Some(cover_path) = &cover_path {
        args.extend([
            "-f".into(),
            "image2".into(),
            "-i".into(),
            cover_path.clone(),
        ]);
    }
    args.extend(maps);
    args.extend(strings(&["-c", "copy"]));
    if let Some(cover_path) = &cover_path {
        let video_streams = first_streams
            .iter()
            .filter(|stream| stream.kind == "video")
            .count();
        args.extend(
            cover_args(
                &original.extension,
                metadata_input + 1,
                cover_path,
                video_streams,
            )
            .unwrap_or_default(),
        );
    }
    args.extend([
        "-map_metadata".into(),
        metadata_input.to_string(),
        "-map_chapters".into(),
        metadata_input.to_string(),
    ]);
    let (staged_name, staged_path) = staging.next(&original.extension);
    args.push(staged_path.display().to_string());
    run(&tools.ffmpeg, &args, &inherited).await?;
    drop(inherited);

    Ok((staged_name, staged_path, cover.is_some()))
}

/// Embed or remove the cover in every media file, copying the streams.
async fn recover(
    builder: &mut PlanBuilder<'_>,
    staging: &mut Staging,
    tools: &Tools,
    present: &[(ManifestFile, String, String)],
    username: &str,
    change: &Change,
) -> Result<String, String> {
    let located = builder.located;
    let embed = *change == Change::EmbedCover;
    let thumbnail = if embed {
        Some(thumbnail_file(located).ok_or("The original thumbnail is missing.")?)
    } else {
        None
    };
    let root_id = builder.root_id();
    let mut replacements = Vec::new();
    for (file, path, fingerprint) in present.iter().filter(|(file, _, _)| file.is_media()) {
        let extension = extension_of(&file.path)
            .map(|extension| format!(".{extension}"))
            .unwrap_or_default();
        let source = open_media(located, path, fingerprint)?;
        let mut sources = vec![&source];
        if let Some(thumbnail) = &thumbnail {
            sources.push(thumbnail);
        }
        let inherited = Inherited::new(sources);
        let input = inherited.path(0);
        let streams = programme_streams(tools, &input, &inherited).await?;
        let before = stream_hashes(
            tools,
            vec!["-i".into(), input.clone()],
            programme_maps(0),
            &inherited,
        )
        .await?;
        let (staged_name, staged_path) = staging.next(&extension);
        let mut args = strings(&["-nostdin", "-hide_banner", "-v", "error", "-y", "-i"]);
        args.push(input.clone());
        if thumbnail.is_some() {
            args.extend(["-f".into(), "image2".into(), "-i".into(), inherited.path(1)]);
        }
        args.extend(programme_maps(0));
        args.extend(strings(&["-map", "0:s?", "-c", "copy"]));
        if thumbnail.is_some() {
            let video_streams = streams
                .iter()
                .filter(|stream| stream.kind == "video")
                .count();
            args.extend(
                cover_args(&extension, 1, &inherited.path(1), video_streams)
                    .ok_or("This file type cannot carry a cover picture.")?,
            );
        }
        args.extend(strings(&["-map_metadata", "0", "-map_chapters", "0"]));
        args.push(staged_path.display().to_string());
        run(&tools.ffmpeg, &args, &inherited).await?;
        let output = File::open(&staged_path).map_err(|error| format!("reopen file: {error}"))?;
        let output_inherited = Inherited::new(vec![&output]);
        let after = stream_hashes(
            tools,
            vec!["-i".into(), output_inherited.path(0)],
            programme_maps(0),
            &output_inherited,
        )
        .await?;
        if after != before {
            return Err(format!(
                "{} would not keep its audio and video exactly, so nothing was changed.",
                file.path
            ));
        }
        replacements.push((path.clone(), fingerprint.clone(), staged_name, staged_path));
    }
    for (path, fingerprint, staged_name, staged_path) in replacements {
        builder.tombstone(&path, &fingerprint);
        builder.install(
            &root_id,
            (staged_name, staged_fingerprint(&staged_path)?),
            &path,
        );
    }
    let state = ItemState {
        split: located.manifest.state.split,
        cover_embedded: embed,
    };
    let files = located
        .manifest
        .files
        .iter()
        .filter(|file| {
            present
                .iter()
                .any(|(present, _, _)| present.path == file.path)
        })
        .cloned()
        .collect::<Vec<_>>();
    let bytes = rewritten_manifest(
        located,
        change,
        username,
        &state,
        located.manifest.original.as_ref(),
        &files,
    )?;
    let folder = located.folder.clone();
    replace_manifest(builder, staging, &root_id, &folder, &located.stem, &bytes)?;
    Ok(folder)
}

#[allow(clippy::too_many_arguments)]
fn move_item(
    builder: &mut PlanBuilder<'_>,
    staging: &mut Staging,
    present: &[(ManifestFile, String, String)],
    username: &str,
    change: &Change,
    destination_root: &VisibleRoot,
    layout: &Layout,
    collection: Option<&str>,
    warnings: &mut Vec<String>,
) -> Result<String, String> {
    let located = builder.located;
    let manifest = &located.manifest;
    let split = manifest.state.split;
    let destination = destination_folder(manifest, layout, collection, split)?;
    let same_root = destination_root.id == located.root.id;
    if same_root && destination == located.folder {
        return Err("It is already filed there.".into());
    }
    if !compatible_roots(&located.root, destination_root) {
        return Err(
            "That library is on different storage, so the item cannot be moved there.".into(),
        );
    }
    // A folder of its own keeps the video's poster and NFO; a folder shared
    // with other downloads must not, or it would read as this one video.
    let dedicated = split || *layout == Layout::OwnFolder;
    let destination_path = Path::new(&destination_root.resolved_path);
    let root_id = destination_root.id.clone();
    let mut files = Vec::new();
    for (file, path, fingerprint) in present {
        let keep = dedicated || !matches!(file.role.as_str(), "video-nfo" | "video-poster");
        if !keep {
            builder.tombstone(path, fingerprint);
            continue;
        }
        let target = join(&destination, &file.path);
        builder.claim(destination_path, &target)?;
        builder.relocate(&root_id, path, &target, fingerprint);
        files.push(file.clone());
    }
    // Another manifest of the same video may already be there.
    let mut stem = located.stem.clone();
    for attempt in 1..1000 {
        let manifest_path = join(
            &destination,
            &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{stem}.json"),
        );
        let thumbnail_path = join(
            &destination,
            &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{stem}.jpg"),
        );
        let restore_path = join(
            &destination,
            &format!("{YOUTUBE_ITEM_METADATA_FOLDER}/{stem}.restore"),
        );
        if !exists_beneath(destination_path, &manifest_path)
            && !exists_beneath(destination_path, &thumbnail_path)
            && !exists_beneath(destination_path, &restore_path)
        {
            break;
        }
        stem = format!("{} ({attempt})", located.stem);
    }
    move_companions(builder, &root_id, &destination, &stem)?;
    if !same_root {
        warnings.push(format!(
            "The item moves to {}; players that index that library will pick it up after their next scan.",
            destination_root.label
        ));
    }
    let bytes = rewritten_manifest(
        located,
        change,
        username,
        &manifest.state,
        manifest.original.as_ref(),
        &files,
    )?;
    replace_manifest(builder, staging, &root_id, &destination, &stem, &bytes)?;
    Ok(destination)
}

/// Libraries an item can move between: the same kind of media, on the same
/// storage (a move is a rename, never a copy).
pub fn compatible_roots(from: &VisibleRoot, to: &VisibleRoot) -> bool {
    let audio = |category: LibraryCategory| {
        matches!(
            category,
            LibraryCategory::Music | LibraryCategory::Audiobooks
        )
    };
    let kind_matches = from.category == to.category || (audio(from.category) && audio(to.category));
    if !kind_matches || !to.available {
        return false;
    }
    use std::os::unix::fs::MetadataExt;
    match (
        fs::metadata(&from.resolved_path),
        fs::metadata(&to.resolved_path),
    ) {
        (Ok(from), Ok(to)) => from.dev() == to.dev(),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(split: bool) -> Manifest {
        Manifest::parse(
            json!({
                "schema": MANIFEST_SCHEMA,
                "schemaVersion": 1,
                "source": { "url": "https://www.youtube.com/watch?v=abcdefghijk", "title": "Live: Set / One", "channel": "Some Artist", "durationSeconds": 300 },
                "naming": { "title": "Live Set One", "channel": "Some Artist", "date": "2025-01-02", "year": "2025" },
                "chapters": [
                    { "index": 1, "title": "Intro", "startTime": 0, "endTime": 60 },
                    { "index": 2, "title": "Main = Part; #2", "startTime": 60 }
                ],
                "state": { "split": split, "coverEmbedded": true },
                "files": [{ "path": "Live Set One.flac", "role": "media" }],
                "hasThumbnail": true
            })
            .to_string()
            .as_bytes(),
        )
        .unwrap()
    }

    #[test]
    fn rejects_other_documents() {
        assert!(Manifest::parse(br#"{"schema":"something-else","schemaVersion":1}"#).is_none());
        assert!(
            Manifest::parse(br#"{"schema":"youtube-downloader.item","schemaVersion":2}"#).is_none()
        );
    }

    #[test]
    fn names_match_the_downloader() {
        assert_eq!(sanitize_segment("A / Useful: Talk?", "x"), "A Useful Talk");
        assert_eq!(sanitize_segment("  ..  ", "fallback"), "fallback");
        assert_eq!(sanitize_segment("CON", "x"), "CON_");
        let chapter = Chapter {
            index: 3,
            title: "It's / Main".into(),
            start_time: 0.0,
            end_time: None,
        };
        assert_eq!(
            chapter_file_name(&chapter, 12, ".flac"),
            "03 - It's Main.flac"
        );
        assert_eq!(
            chapter_file_name(&chapter, 120, ".mkv"),
            "003 - It's Main.mkv"
        );
    }

    #[test]
    fn layouts_put_splits_in_a_folder_of_their_own() {
        let single = manifest(false);
        assert_eq!(
            destination_folder(&single, &Layout::Channel, None, false).unwrap(),
            "Some Artist"
        );
        assert_eq!(
            destination_folder(&single, &Layout::Channel, None, true).unwrap(),
            "Some Artist/Live Set One"
        );
        assert_eq!(
            destination_folder(&single, &Layout::OwnFolder, None, true).unwrap(),
            "Live Set One"
        );
        assert_eq!(
            destination_folder(&single, &Layout::Collection, Some(" Road / Trip "), false).unwrap(),
            "Road Trip"
        );
        assert!(destination_folder(&single, &Layout::Collection, Some("  "), false).is_err());
    }

    #[test]
    fn changes_follow_the_state() {
        let root = VisibleRoot {
            id: "music".into(),
            label: "Music".into(),
            category: LibraryCategory::Music,
            scope: crate::config::RootScope::Shared,
            resolved_path: "/nonexistent".into(),
            available: true,
        };
        let located = Located {
            root,
            folder: "Some Artist".into(),
            stem: "abcdefghijk".into(),
            manifest: manifest(false),
            raw: Value::Null,
        };
        let changes = available_changes(&located, true);
        assert_eq!(changes["split"]["available"], json!(true));
        assert_eq!(changes["join"]["available"], json!(false));
        assert_eq!(changes["embedCover"]["available"], json!(false));
        assert_eq!(changes["removeCover"]["available"], json!(true));
        assert_eq!(
            available_changes(&located, false)["split"]["available"],
            json!(false)
        );
        assert_eq!(describe_layout(&located)["layout"], json!("channel"));
    }

    #[test]
    fn ffmetadata_escapes_tags_and_lists_every_chapter() {
        let text = ffmetadata(&manifest(true));
        assert!(text.starts_with(";FFMETADATA1\ntitle=Live: Set / One\nartist=Some Artist\n"));
        assert!(text.contains("START=0\nEND=60000\ntitle=Intro\n"));
        assert!(text.contains("START=60000\nEND=300000\ntitle=Main \\= Part\\; \\#2\n"));
    }

    #[test]
    fn reads_ffmpeg_output() {
        assert_eq!(
            parse_segment_list("00000.flac,0.000000,2.368000\n00001.flac,2.368000,4.608000\n")
                .unwrap(),
            vec![
                ("00000.flac".to_string(), 0.0, 2.368),
                ("00001.flac".to_string(), 2.368, 4.608)
            ]
        );
        assert_eq!(
            parse_stream_hashes("0,v,MD5=0123456789ABCDEF0123456789abcdef\nnoise\n1,a,MD5=fedcba9876543210fedcba9876543210\n"),
            vec!["0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"]
        );
        assert_eq!(concat_line("/a/It's.flac"), "file '/a/It'\\''s.flac'");
        assert!((seconds(-1024, "1/48000") + 0.021333).abs() < 1e-6);
    }

    #[test]
    fn covers_go_where_the_container_allows() {
        assert!(cover_supported(".flac") && cover_supported(".mkv") && cover_supported(".mp4"));
        assert!(!cover_supported(".opus") && !cover_supported(".webm") && !cover_supported(".wav"));
        assert_eq!(
            cover_args(".m4a", 1, "/proc/self/fd/9", 0).unwrap(),
            strings(&[
                "-map",
                "1:v:0",
                "-c:v:0",
                "copy",
                "-disposition:v:0",
                "attached_pic"
            ])
        );
    }
}
