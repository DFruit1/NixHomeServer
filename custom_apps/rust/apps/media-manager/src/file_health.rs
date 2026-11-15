//! File-level health checks: whether a media file is what its name says and
//! whether it is whole.
//!
//! Metadata health compares what sources say about an item; these checks look
//! at the file itself. They are structural and bounded: a few kilobytes from
//! each end, the container's own size fields, and the audio stream header.
//! Nothing here decodes the media, so damage in the middle of an otherwise
//! complete file is not detected. A full decode of a library takes hours and
//! does not belong in an on-demand scan.
//!
//! The video checks take the cached FFprobe result, and the relationship
//! checks (an extra as long as its feature, subtitles outrunning the video,
//! an embedded title naming something else) take values the handler already
//! holds, so every function below stays pure or reads one file.

use crate::{
    broker::open_regular_file_beneath,
    catalog::CatalogItem,
    media::MediaKind,
    metadata::{health_issue, MetadataHealthIssue},
    video_probe::VideoProbe,
};
use lofty::{
    config::ParseOptions,
    file::{AudioFile, FileType},
    probe::Probe,
};
use std::{
    collections::BTreeSet,
    fs::File,
    io::{BufReader, Read, Seek, SeekFrom},
    path::Path,
};
use zip::ZipArchive;

/// Leading bytes read to recognise a container.
const SNIFF_BYTES: usize = 4096;
/// Trailing bytes searched for a PDF end-of-file marker.
const PDF_TAIL_BYTES: u64 = 4096;
/// Top-level MPEG-4 boxes walked before giving up on a file.
const MAX_ISO_BOXES: usize = 4096;
/// Audio padding tolerated before the first frame. Lofty's default of 1 KiB
/// rejects playable files that carry a larger gap after their ID3 tag.
const MAX_AUDIO_JUNK_BYTES: usize = 64 * 1024;
/// Subtitle sidecars larger than this are not inspected.
pub const MAX_SUBTITLE_BYTES: u64 = 10 * 1024 * 1024;

/// What a file's leading bytes say it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Container {
    Matroska,
    IsoMedia,
    Avi,
    Wave,
    Flac,
    Ogg,
    MpegAudio,
    /// An ID3v2 tag whose audio starts beyond the sniffed bytes.
    Id3Tagged,
    Aac,
    Pdf,
    Zip,
    Rar,
    SevenZip,
    WindowsMedia,
    /// HTML, XML or other markup: a download that saved an error page.
    Markup,
}

impl Container {
    fn label(self) -> &'static str {
        match self {
            Container::Matroska => "Matroska video (MKV or WebM)",
            Container::IsoMedia => "MPEG-4 media (MP4 or M4A)",
            Container::Avi => "AVI video",
            Container::Wave => "WAV audio",
            Container::Flac => "FLAC audio",
            Container::Ogg => "Ogg audio",
            Container::MpegAudio | Container::Id3Tagged => "MP3 audio",
            Container::Aac => "raw AAC audio",
            Container::Pdf => "a PDF document",
            Container::Zip => "a ZIP archive",
            Container::Rar => "a RAR archive",
            Container::SevenZip => "a 7-Zip archive",
            Container::WindowsMedia => "Windows Media",
            Container::Markup => "a web page or text document",
        }
    }
}

fn sniff(bytes: &[u8]) -> Option<Container> {
    if bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        return Some(Container::Matroska);
    }
    if bytes.len() >= 12 {
        let brand = &bytes[4..8];
        if [b"ftyp", b"moov", b"mdat", b"wide", b"free", b"skip"]
            .iter()
            .any(|kind| brand == *kind)
        {
            return Some(Container::IsoMedia);
        }
        if bytes.starts_with(b"RIFF") {
            return match &bytes[8..12] {
                b"AVI " => Some(Container::Avi),
                b"WAVE" => Some(Container::Wave),
                _ => None,
            };
        }
    }
    if bytes.starts_with(b"fLaC") {
        return Some(Container::Flac);
    }
    if bytes.starts_with(b"OggS") {
        return Some(Container::Ogg);
    }
    if bytes.starts_with(b"PK\x03\x04") || bytes.starts_with(b"PK\x05\x06") {
        return Some(Container::Zip);
    }
    if bytes.starts_with(b"Rar!\x1a\x07") {
        return Some(Container::Rar);
    }
    if bytes.starts_with(&[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
        return Some(Container::SevenZip);
    }
    if bytes.starts_with(&[0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
        return Some(Container::WindowsMedia);
    }
    let head = &bytes[..bytes.len().min(1024)];
    if head.windows(5).any(|window| window == b"%PDF-") {
        return Some(Container::Pdf);
    }
    if bytes.starts_with(b"ID3") && bytes.len() >= 10 {
        // The tag length is four 7-bit bytes; the audio follows it.
        let length = bytes[6..10].iter().fold(0usize, |length, byte| {
            (length << 7) | usize::from(byte & 0x7F)
        });
        return match bytes.get(10 + length..) {
            Some(audio) if audio.starts_with(b"fLaC") => Some(Container::Flac),
            Some(audio) if audio.len() >= 2 => audio_frame(audio).or(Some(Container::Id3Tagged)),
            _ => Some(Container::Id3Tagged),
        };
    }
    if let Some(container) = audio_frame(bytes) {
        return Some(container);
    }
    let text = bytes
        .strip_prefix(&[0xEF, 0xBB, 0xBF])
        .unwrap_or(bytes)
        .trim_ascii_start();
    let opening = text[..text.len().min(16)].to_ascii_lowercase();
    if [&b"<!doctype"[..], b"<html", b"<?xml", b"<head", b"<body"]
        .iter()
        .any(|marker| opening.starts_with(marker))
    {
        return Some(Container::Markup);
    }
    None
}

/// An MPEG audio or ADTS AAC frame header at the start of `bytes`.
fn audio_frame(bytes: &[u8]) -> Option<Container> {
    let [first, second, third, ..] = bytes else {
        return None;
    };
    if *first != 0xFF || second & 0xE0 != 0xE0 {
        return None;
    }
    let layer = (second >> 1) & 0x03;
    if layer == 0 {
        // ADTS reuses the sync word with the layer bits cleared.
        return (second & 0xF0 == 0xF0).then_some(Container::Aac);
    }
    let version = (second >> 3) & 0x03;
    let bitrate = third >> 4;
    let sample_rate = (third >> 2) & 0x03;
    (version != 1 && bitrate != 0x0F && sample_rate != 0x03).then_some(Container::MpegAudio)
}

/// The containers an extension may legitimately hold. Empty for extensions
/// this module has no opinion about.
fn expected_containers(extension: &str) -> &'static [Container] {
    match extension {
        "mkv" => &[Container::Matroska],
        "mp4" | "m4v" | "m4a" | "m4b" => &[Container::IsoMedia],
        "avi" => &[Container::Avi],
        "flac" => &[Container::Flac],
        "ogg" | "opus" => &[Container::Ogg],
        "mp3" => &[Container::MpegAudio, Container::Id3Tagged],
        "pdf" => &[Container::Pdf],
        "epub" | "cbz" => &[Container::Zip],
        _ => &[],
    }
}

fn extension_of(relative_path: &str) -> String {
    relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default()
}

fn file_name_of(relative_path: &str) -> &str {
    relative_path.rsplit('/').next().unwrap_or(relative_path)
}

fn issue(code: &str, severity: &str, title: &str, message: String) -> MetadataHealthIssue {
    health_issue(code, severity, None, title, &message, Vec::new())
}

/// Messages stay free of per-file figures: the health view states one
/// message for every file of an album that shares an issue.
fn truncated(extension: &str) -> MetadataHealthIssue {
    issue(
        "file-truncated",
        "error",
        "File is incomplete",
        format!(
            "The {} container declares more data than the file holds, so a copy or download stopped early. Playback ends or fails at the missing part. Replace the file from its source.",
            extension.to_ascii_uppercase(),
        ),
    )
}

/// Inspect one catalogued file: empty, mislabelled, truncated or unreadable.
/// Returns at most one issue, the most fundamental one, because the later
/// checks cannot be trusted once an earlier one fails.
pub fn inspect_file(root: &Path, item: &CatalogItem) -> Vec<MetadataHealthIssue> {
    let extension = extension_of(&item.relative_path);
    // CBR archives have their own check, which also offers the fix.
    if extension == "cbr" {
        return Vec::new();
    }
    let Ok(mut file) = open_regular_file_beneath(root, &item.relative_path) else {
        return Vec::new();
    };
    let Ok(length) = file.metadata().map(|metadata| metadata.len()) else {
        return Vec::new();
    };
    if length == 0 {
        return vec![issue(
            "file-empty",
            "error",
            "File is empty",
            "The file holds no data, so nothing can play or open it. Replace it from its source."
                .to_string(),
        )];
    }
    let mut head = Vec::with_capacity(SNIFF_BYTES);
    if file
        .by_ref()
        .take(SNIFF_BYTES as u64)
        .read_to_end(&mut head)
        .is_err()
    {
        return Vec::new();
    }
    let expected = expected_containers(&extension);
    let found = sniff(&head);
    if let Some(found) = found
        && !expected.is_empty()
        && !expected.contains(&found)
    {
        let named = extension.to_ascii_uppercase();
        return vec![if found == Container::Markup {
            issue(
                "file-not-media",
                "error",
                "File is a web page, not media",
                format!(
                    "This {named} file holds {} instead of media, which usually means a failed or blocked download was saved under the media's name. Download it again from its source.",
                    found.label(),
                ),
            )
        } else {
            issue(
                "file-format-mismatch",
                "warning",
                "File content does not match its extension",
                format!(
                    "The file is named .{extension} but holds {}. Apps that trust the extension can refuse it or read its tags wrongly. Rename it with the matching extension, or convert it.",
                    found.label(),
                ),
            )
        }];
    }
    let structural = match found {
        Some(Container::Matroska) => {
            matroska_missing_bytes(&head, length).map(|_| truncated(&extension))
        }
        Some(Container::IsoMedia) => iso_media_issue(&mut file, length, &extension),
        Some(Container::Avi) => riff_missing_bytes(&head, length).map(|_| truncated(&extension)),
        Some(Container::Pdf) => pdf_issue(&mut file, length),
        Some(Container::Zip) => zip_issue(&mut file, &extension),
        _ => None,
    };
    if let Some(structural) = structural {
        return vec![structural];
    }
    if matches!(
        item.media_kind,
        MediaKind::Music | MediaKind::Audiobook | MediaKind::Podcast
    ) && let Some(audio) = audio_issue(file, &item.relative_path, &extension)
    {
        return vec![audio];
    }
    Vec::new()
}

/// Read an EBML variable-length size. `None` for a malformed or unknown size
/// (all value bits set), which live captures and interrupted muxes carry.
fn ebml_size(bytes: &[u8]) -> Option<(u64, usize)> {
    let first = *bytes.first()?;
    let width = first.leading_zeros() as usize + 1;
    if width > 8 || bytes.len() < width {
        return None;
    }
    let mut value = u64::from(first) & ((1u64 << (8 - width)) - 1);
    for byte in &bytes[1..width] {
        value = (value << 8) | u64::from(*byte);
    }
    let unknown = (1u64 << (7 * width)) - 1;
    (value != unknown).then_some((value, width))
}

/// Bytes the Matroska segment declares beyond the end of the file.
fn matroska_missing_bytes(head: &[u8], length: u64) -> Option<u64> {
    let (header_size, width) = ebml_size(head.get(4..)?)?;
    let segment = 4usize
        .checked_add(width)?
        .checked_add(usize::try_from(header_size).ok()?)?;
    let rest = head.get(segment..)?;
    if !rest.starts_with(&[0x18, 0x53, 0x80, 0x67]) {
        return None;
    }
    let (segment_size, width) = ebml_size(rest.get(4..)?)?;
    let end = (segment as u64)
        .checked_add(4 + width as u64)?
        .checked_add(segment_size)?;
    end.checked_sub(length).filter(|missing| *missing > 0)
}

/// Bytes the first RIFF chunk declares beyond the end of the file. Larger
/// OpenDML files append further chunks, so a longer file is not a fault.
fn riff_missing_bytes(head: &[u8], length: u64) -> Option<u64> {
    let size = u32::from_le_bytes(head.get(4..8)?.try_into().ok()?);
    (u64::from(size) + 8)
        .checked_sub(length)
        .filter(|missing| *missing > 0)
}

/// Walk the top-level MPEG-4 boxes: each must fit in the file, and one of
/// them must be the `moov` index that players need before they can start.
fn iso_media_issue(file: &mut File, length: u64, extension: &str) -> Option<MetadataHealthIssue> {
    let mut offset = 0u64;
    let mut has_index = false;
    // Whether every byte was accounted for. Only then does a missing index
    // mean the file has none, rather than this walk having lost its place.
    let mut walked_whole_file = false;
    for _ in 0..MAX_ISO_BOXES {
        if length - offset < 8 {
            // The end, or a few stray bytes some muxers pad the file with.
            walked_whole_file = true;
            break;
        }
        let mut header = [0u8; 16];
        file.seek(SeekFrom::Start(offset)).ok()?;
        file.read_exact(&mut header[..8]).ok()?;
        let kind = [header[4], header[5], header[6], header[7]];
        if !kind
            .iter()
            .all(|byte| byte.is_ascii_graphic() || *byte == b' ')
        {
            // Not a box header: trailing data this walk cannot interpret.
            break;
        }
        let size = match u32::from_be_bytes([header[0], header[1], header[2], header[3]]) {
            0 => length - offset,
            1 => {
                file.read_exact(&mut header[8..16]).ok()?;
                u64::from_be_bytes(header[8..16].try_into().ok()?)
            }
            size => u64::from(size),
        };
        if size < 8 {
            break;
        }
        has_index |= &kind == b"moov";
        let end = offset.checked_add(size)?;
        if end > length {
            return Some(truncated(extension));
        }
        offset = end;
    }
    (walked_whole_file && !has_index).then(|| {
        issue(
            "file-index-missing",
            "error",
            "File has no playback index",
            format!(
                "This {} has no index of its audio and video (the moov box), which is written last, so the recording or download never finished. Players cannot open it. Replace the file from its source.",
                extension.to_ascii_uppercase(),
            ),
        )
    })
}

fn pdf_issue(file: &mut File, length: u64) -> Option<MetadataHealthIssue> {
    let start = length.saturating_sub(PDF_TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::with_capacity(PDF_TAIL_BYTES as usize);
    file.take(PDF_TAIL_BYTES).read_to_end(&mut tail).ok()?;
    (!tail.windows(5).any(|window| window == b"%%EOF")).then(|| {
        issue(
            "pdf-end-missing",
            "warning",
            "PDF has no end marker",
            "The PDF does not finish with its end-of-file marker, so it was probably cut short. Readers may refuse it or lose the last pages. Replace the file from its source."
                .to_string(),
        )
    })
}

fn zip_issue(file: &mut File, extension: &str) -> Option<MetadataHealthIssue> {
    file.seek(SeekFrom::Start(0)).ok()?;
    let named = extension.to_ascii_uppercase();
    let Ok(mut archive) = ZipArchive::new(&mut *file) else {
        return Some(issue(
            "archive-unreadable",
            "error",
            "Archive cannot be opened",
            format!(
                "This {named} is a ZIP archive whose file list, stored at the end, is missing or damaged, so the download was probably cut short. Readers cannot open it. Replace the file from its source.",
            ),
        ));
    };
    if extension == "epub" {
        return archive.by_name("META-INF/container.xml").is_err().then(|| {
            issue(
                "epub-invalid",
                "error",
                "Not a valid EPUB",
                "The archive has no META-INF/container.xml, which every EPUB needs to locate its book. Readers cannot open it. Replace the file from its source."
                    .to_string(),
            )
        });
    }
    let pages = (0..archive.len())
        .filter_map(|index| archive.name_for_index(index))
        .filter(|name| {
            MediaKind::Artwork
                .extensions()
                .contains(&extension_of(name).as_str())
        })
        .count();
    (pages == 0).then(|| {
        issue(
            "comic-no-pages",
            "warning",
            "Comic has no pages",
            "The archive holds no page images, so readers show an empty comic. Replace the file from its source."
                .to_string(),
        )
    })
}

/// Parse the audio stream header. A file that cannot be parsed, has no
/// length, or is shorter than its own header declares will not play through.
fn audio_issue(
    mut file: File,
    relative_path: &str,
    extension: &str,
) -> Option<MetadataHealthIssue> {
    let file_type = FileType::from_path(relative_path)?;
    // The sniff and the container walk left the cursor mid-file.
    file.rewind().ok()?;
    let named = extension.to_ascii_uppercase();
    let tagged = match Probe::with_file_type(BufReader::new(file), file_type)
        .options(
            ParseOptions::new()
                .read_tags(false)
                .read_cover_art(false)
                .max_junk_bytes(MAX_AUDIO_JUNK_BYTES),
        )
        .read()
    {
        Ok(tagged) => tagged,
        Err(_) => {
            return Some(issue(
                "audio-unreadable",
                "warning",
                "Audio cannot be read",
                format!(
                    "The {named} audio stream could not be parsed, so the file may be damaged or incomplete. Play it to check, then replace it from its source.",
                ),
            ));
        }
    };
    let properties = tagged.properties();
    if properties.duration().is_zero() {
        return Some(issue(
            "audio-empty",
            "warning",
            "Audio has no playable length",
            format!(
                "No playable audio was found in this {named} file. It may be damaged or incomplete. Play it to check, then replace it from its source.",
            ),
        ));
    }
    // An MP3's Xing header records the size of the audio it was written
    // with. A file much smaller than that lost its tail.
    if file_type == FileType::Mpeg
        && let (Some(overall), Some(audio)) =
            (properties.overall_bitrate(), properties.audio_bitrate())
        && audio > 0
        && u64::from(overall) * 100 < u64::from(audio) * 90
    {
        return Some(issue(
            "audio-shorter-than-header",
            "warning",
            "Audio is shorter than its header declares",
            "The MP3 header describes more audio than the file holds, so it was cut short or trimmed without rewriting the header. Players show the wrong length and stop early. Replace the file from its source."
                .to_string(),
        ));
    }
    None
}

/// Issues the cached FFprobe result shows. `failed` means FFprobe ran on
/// this exact file and could not read it.
pub fn video_probe_issues(probe: Option<&VideoProbe>, failed: bool) -> Vec<MetadataHealthIssue> {
    let Some(probe) = probe else {
        return if failed {
            vec![issue(
                "video-unreadable",
                "error",
                "Video cannot be read",
                "FFprobe could not read this file's streams, so it is damaged, incomplete or not a video. Play it to check, then replace it from its source."
                    .to_string(),
            )]
        } else {
            Vec::new()
        };
    };
    let mut issues = Vec::new();
    if probe.codec.is_none() {
        issues.push(issue(
            "video-track-missing",
            "warning",
            "No video track",
            "This file holds no video stream, so it plays as sound only or not at all. Replace it from its source, or move it to an audio library."
                .to_string(),
        ));
    } else if probe.audio_codecs.is_empty() {
        issues.push(issue(
            "audio-track-missing",
            "info",
            "No audio track",
            "This video has no audio stream. If it should have sound, the rip or download dropped it; replace it from its source."
                .to_string(),
        ));
    }
    if probe.duration_seconds.is_none() {
        issues.push(issue(
            "duration-missing",
            "warning",
            "Running time is not recorded",
            "The container does not say how long the video is, which usually means it was not finished being written. Seeking, resume and progress can fail. Remuxing or replacing the file fixes it."
                .to_string(),
        ));
    }
    issues
}

/// Folder names Jellyfin treats as holding a title's extras.
const EXTRAS_FOLDERS: &[&str] = &[
    "extras",
    "extra",
    "behind the scenes",
    "deleted scenes",
    "featurettes",
    "interviews",
    "scenes",
    "shorts",
    "trailers",
    "clips",
    "other",
    "samples",
];

/// The folder holding the main video when `relative_path` is one of its
/// extras: `Movie/extras/clip.mkv` gives `Movie`.
pub fn feature_folder_of_extra(relative_path: &str) -> Option<&str> {
    let (folder, _) = relative_path.rsplit_once('/')?;
    let (feature_folder, extras) = folder.rsplit_once('/')?;
    EXTRAS_FOLDERS
        .contains(&extras.to_ascii_lowercase().as_str())
        .then_some(feature_folder)
}

/// "1 h 26 min", for running times in messages.
fn running_time(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as u64;
    match (minutes / 60, minutes % 60) {
        (0, minutes) => format!("{minutes} min"),
        (hours, 0) => format!("{hours} h"),
        (hours, minutes) => format!("{hours} h {minutes} min"),
    }
}

/// "1:26:21", for positions within a video.
fn clock(seconds: f64) -> String {
    let seconds = seconds.max(0.0).round() as u64;
    format!(
        "{}:{:02}:{:02}",
        seconds / 3600,
        seconds % 3600 / 60,
        seconds % 60
    )
}

/// An extra about as long as the main video is rarely an extra: it is the
/// second part of a two-part title, or the feature itself, filed where
/// players hide it.
pub fn long_extra_issue(
    extra_seconds: f64,
    feature_name: &str,
    feature_seconds: f64,
) -> Option<MetadataHealthIssue> {
    (extra_seconds >= 20.0 * 60.0 && extra_seconds >= feature_seconds * 0.6).then(|| {
        issue(
            "extra-as-long-as-feature",
            "warning",
            "Extra is as long as the main video",
            format!(
                "This extra runs {}, beside a main video of {} ({feature_name}). It is probably another part of the title, or the feature itself, filed as an extra, so players leave it out of the title's running time and metadata. Play it to check, then rename it as a part or merge the two.",
                running_time(extra_seconds),
                running_time(feature_seconds),
            ),
        )
    })
}

/// The file's running time against the runtime its sidecar lists for the
/// title. A large gap means a different cut, one part of several, or a
/// different title under this name.
pub fn runtime_issue(file_seconds: f64, listed_minutes: f64) -> Option<MetadataHealthIssue> {
    if !listed_minutes.is_finite() || listed_minutes < 5.0 {
        return None;
    }
    let difference = (file_seconds / 60.0 - listed_minutes).abs();
    (difference > f64::max(10.0, listed_minutes * 0.15)).then(|| {
        issue(
            "runtime-mismatch",
            "warning",
            "Running time differs from the listed runtime",
            format!(
                "The file runs {} but its metadata lists {}. It may be a different cut, one part of a multi-part title, or a different title altogether. Check the match before trusting the rest of its metadata.",
                running_time(file_seconds),
                running_time(listed_minutes * 60.0),
            ),
        )
    })
}

/// One subtitle sidecar measured against its video.
pub struct SubtitleTimeline {
    pub file_name: String,
    /// End of the last cue, or why the file has no usable cues.
    pub last_cue_seconds: Result<f64, String>,
}

/// Read a subtitle sidecar's final cue time. `None` when the file is not a
/// text subtitle this module can parse or is too large to inspect.
pub fn subtitle_timeline(root: &Path, relative_path: &str) -> Option<SubtitleTimeline> {
    let extension = extension_of(relative_path);
    if !matches!(extension.as_str(), "srt" | "vtt" | "ass" | "ssa") {
        return None;
    }
    let file = open_regular_file_beneath(root, relative_path).ok()?;
    if file.metadata().ok()?.len() > MAX_SUBTITLE_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_SUBTITLE_BYTES).read_to_end(&mut bytes).ok()?;
    // Timings are ASCII; legacy encodings only garble the cue text.
    let text = String::from_utf8_lossy(&bytes);
    let last_cue_seconds =
        crate::subtitle_format::parse_subtitle(&extension, &text).and_then(|cues| {
            cues.iter()
                .map(|cue| cue.end_ms)
                .max()
                .map(|end| end as f64 / 1000.0)
                .ok_or_else(|| "it has no cues".to_string())
        });
    Some(SubtitleTimeline {
        file_name: file_name_of(relative_path).to_string(),
        last_cue_seconds,
    })
}

/// Subtitles timed for a different cut or a different title cannot stay in
/// sync. Compare each sidecar's last cue with the video's running time and
/// report the worst case per kind, naming how many others share it.
pub fn subtitle_issues(
    timelines: &[SubtitleTimeline],
    video_seconds: Option<f64>,
) -> Vec<MetadataHealthIssue> {
    let others = |count: usize| match count {
        0 | 1 => String::new(),
        2 => " One other subtitle file has the same problem.".to_string(),
        count => format!(" {} other subtitle files have the same problem.", count - 1),
    };
    let mut issues = Vec::new();
    let unreadable = timelines
        .iter()
        .filter_map(|timeline| {
            timeline
                .last_cue_seconds
                .as_ref()
                .err()
                .map(|reason| (timeline, reason))
        })
        .collect::<Vec<_>>();
    if let Some((timeline, reason)) = unreadable.first() {
        let reason = reason
            .chars()
            .filter(|character| !character.is_control())
            .take(120)
            .collect::<String>();
        issues.push(issue(
            "subtitle-unreadable",
            "warning",
            "Subtitle file cannot be read",
            format!(
                "{} has no usable subtitle cues ({reason}), so players ignore it. Replace it.{}",
                timeline.file_name,
                others(unreadable.len()),
            ),
        ));
    }
    let Some(video_seconds) = video_seconds else {
        return issues;
    };
    let timed = timelines
        .iter()
        .filter_map(|timeline| {
            timeline
                .last_cue_seconds
                .as_ref()
                .ok()
                .map(|end| (timeline, *end))
        })
        .collect::<Vec<_>>();
    let mut outrunning = timed
        .iter()
        .filter(|(_, end)| *end > video_seconds + f64::max(90.0, video_seconds * 0.03))
        .collect::<Vec<_>>();
    outrunning.sort_by(|left, right| right.1.total_cmp(&left.1));
    if let Some((timeline, end)) = outrunning.first() {
        issues.push(issue(
            "subtitle-outruns-video",
            "warning",
            "Subtitles run past the end of the video",
            format!(
                "{} has cues up to {}, but the video ends at {}. It was timed for a longer cut or a different title, so it cannot stay in sync. Replace it with subtitles made for this file.{}",
                timeline.file_name,
                clock(*end),
                clock(video_seconds),
                others(outrunning.len()),
            ),
        ));
    }
    // Forced tracks only cover foreign-language passages by design.
    let mut early = timed
        .iter()
        .filter(|(timeline, end)| {
            video_seconds >= 600.0
                && *end < video_seconds * 0.5
                && !timeline.file_name.to_ascii_lowercase().contains(".forced.")
        })
        .collect::<Vec<_>>();
    early.sort_by(|left, right| left.1.total_cmp(&right.1));
    if let Some((timeline, end)) = early.first() {
        issues.push(issue(
            "subtitle-ends-early",
            "info",
            "Subtitles stop partway through",
            format!(
                "{}'s last cue is at {} of {}. It may be incomplete, or timed for a different title.{}",
                timeline.file_name,
                clock(*end),
                clock(video_seconds),
                others(early.len()),
            ),
        ));
    }
    issues
}

/// Words that carry a title's identity: lowercase, at least three
/// characters, and neither filler nor rip and release jargon.
fn identity_words(text: &str) -> BTreeSet<String> {
    const FILLER: &[&str] = &[
        "the",
        "and",
        "for",
        "with",
        "from",
        "that",
        "this",
        "but",
        "its",
        "title",
        "chapter",
        "track",
        "disc",
        "disk",
        "video",
        "movie",
        "film",
        "part",
        "episode",
        "season",
        "bluray",
        "brrip",
        "bdrip",
        "dvdrip",
        "webrip",
        "hdtv",
        "web",
        "x264",
        "x265",
        "h264",
        "h265",
        "hevc",
        "avc",
        "aac",
        "ac3",
        "dts",
        "remux",
        "remaster",
        "remastered",
        "uhd",
        "hdr",
        "sdr",
        "1080p",
        "720p",
        "480p",
        "2160p",
        "mkv",
        "mp4",
        "avi",
    ];
    text.split(|character: char| !character.is_alphanumeric())
        .map(str::to_lowercase)
        .filter(|word| {
            word.chars().count() >= 3
                && !word.chars().all(|character| character.is_ascii_digit())
                && !FILLER.contains(&word.as_str())
        })
        .collect()
}

/// The container's own title against everything the library calls the item.
/// Embedded titles are often release names, so only a title sharing no
/// identifying word with any of `library_names` is reported: that one names
/// something else. Callers skip titles shared by sibling files, which name a
/// collection; on the library this was written against, every such case was a
/// video split by chapter (64 of 340 files) and none was a misfiled video.
pub fn embedded_title_issue(embedded: &str, library_names: &[&str]) -> Option<MetadataHealthIssue> {
    let embedded_words = identity_words(embedded);
    if embedded_words.len() < 2 {
        return None;
    }
    let library_words = library_names
        .iter()
        .flat_map(|name| identity_words(name))
        .collect::<BTreeSet<_>>();
    if library_words.is_empty() || !embedded_words.is_disjoint(&library_words) {
        return None;
    }
    let shown = embedded.chars().take(120).collect::<String>();
    Some(issue(
        "embedded-title-differs",
        "info",
        "Embedded title names something else",
        format!(
            "The file's own title tag reads \u{201c}{shown}\u{201d}, which shares nothing with the name it has in the library. Players that prefer embedded titles show that instead, and it can mean the file is not what its name says. Play it to check, then correct or clear the tag.",
        ),
    ))
}

/// An ISBN whose check digit does not match its other digits was mistyped
/// somewhere, and provider lookups by ISBN then find the wrong book or none.
/// Values that are not shaped like an ISBN are left alone: sources also file
/// other identifiers under this field.
pub fn isbn_check_digit_is_wrong(value: &str) -> bool {
    let characters = value
        .chars()
        .filter(|character| !matches!(character, '-' | ' '))
        .collect::<Vec<_>>();
    let digit = |character: char| character.to_digit(10);
    match characters.len() {
        10 => {
            let Some(body) = characters[..9]
                .iter()
                .map(|character| digit(*character))
                .collect::<Option<Vec<_>>>()
            else {
                return false;
            };
            let check = match characters[9] {
                'X' | 'x' => 10,
                character => match digit(character) {
                    Some(check) => check,
                    None => return false,
                },
            };
            let sum = body
                .iter()
                .enumerate()
                .map(|(index, digit)| digit * (10 - index as u32))
                .sum::<u32>()
                + check;
            sum % 11 != 0
        }
        13 => {
            let Some(digits) = characters
                .iter()
                .map(|character| digit(*character))
                .collect::<Option<Vec<_>>>()
            else {
                return false;
            };
            let sum = digits
                .iter()
                .enumerate()
                .map(|(index, digit)| digit * if index % 2 == 0 { 1 } else { 3 })
                .sum::<u32>();
            sum % 10 != 0
        }
        _ => false,
    }
}
