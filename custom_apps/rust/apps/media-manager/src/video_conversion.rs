//! Converting library videos that browsers and many devices cannot play into a
//! format chosen per conversion (owner decisions, 2026-11-15).
//!
//! A queued job is encoded by the low-priority `media-manager-video-convert`
//! worker into the data-pool intake, verified, and then handed to the
//! filesystem broker as one confirmed plan. The broker copies the original into
//! the converting user's `_Originals` folder before the conversion replaces it
//! in the library; nothing is deleted until that copy is verified.
use crate::{
    config::{AppConfig, Identity},
    transcription::fs::Dir,
    video_probe::VideoProbe,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Folder in each user root that keeps the originals of converted videos.
/// `_Archives` is already taken by the Files app's browsable archive views.
pub const ORIGINALS_DIRECTORY: &str = "_Originals";
/// Intake subfolder holding finished encodes until the broker installs them.
pub const STAGING_DIRECTORY: &str = "video-conversions";
const JOBS_DIRECTORY: &str = "video-conversions";
/// Default conversion jobs keep the original in `_Originals`; editor jobs
/// write a new file and never touch the original.
pub const MODE_REPLACE: &str = "replace";
pub const MODE_COPY: &str = "copy";
/// The worker's systemd path unit watches this directory for new work.
pub const WAKE_DIRECTORY: &str = "video-conversion-requests";
const MAX_JOB_BYTES: u64 = 64 * 1024;
/// Free space a conversion must leave on the data pool, which it shares with
/// backups, photos and documents (review R8-1, 2026-11-15). Overridable with
/// `MEDIA_MANAGER_FREE_SPACE_RESERVE_BYTES`.
pub const DEFAULT_FREE_SPACE_RESERVE: u64 = 20 * 1024 * 1024 * 1024;
/// Finished jobs shown in history; older ones are pruned.
const HISTORY_LIMIT: usize = 30;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    CompatibleMp4,
    CompatibleMkv,
    EfficientHevc,
    ModernAv1,
    AudioMp3,
}

impl Format {
    pub const ALL: [Format; 5] = [
        Format::CompatibleMp4,
        Format::CompatibleMkv,
        Format::EfficientHevc,
        Format::ModernAv1,
        Format::AudioMp3,
    ];

    pub const fn id(self) -> &'static str {
        match self {
            Format::CompatibleMp4 => "compatible-mp4",
            Format::CompatibleMkv => "compatible-mkv",
            Format::EfficientHevc => "efficient-hevc",
            Format::ModernAv1 => "modern-av1",
            Format::AudioMp3 => "audio-mp3",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|format| format.id() == value)
    }

    pub const fn extension(self) -> &'static str {
        match self {
            Format::CompatibleMp4 => "mp4",
            Format::AudioMp3 => "mp3",
            _ => "mkv",
        }
    }

    const fn muxer(self) -> &'static str {
        match self {
            Format::CompatibleMp4 => "mp4",
            Format::AudioMp3 => "mp3",
            _ => "matroska",
        }
    }

    const fn video_codec(self) -> &'static str {
        match self {
            Format::CompatibleMp4 | Format::CompatibleMkv => "h264",
            Format::EfficientHevc => "hevc",
            Format::ModernAv1 => "av1",
            Format::AudioMp3 => "",
        }
    }
}

// ---------------------------------------------------------------------------
// Browser compatibility (shared by Library health and the Conversions list)
// ---------------------------------------------------------------------------

/// Audio codecs browsers decode inside a video element. Keep in step with
/// `frontend/src/video-audio.ts`: AC-3, DTS, TrueHD and WMA are dropped
/// silently rather than raising an error.
const BROWSER_AUDIO_CODECS: &[&str] = &[
    "aac",
    "mp3",
    "mp2",
    "opus",
    "vorbis",
    "flac",
    "pcm_s16le",
    "pcm_s16be",
    "pcm_s24le",
    "pcm_s32le",
    "pcm_f32le",
    "pcm_u8",
    "pcm_mulaw",
    "pcm_alaw",
];

/// Video codecs at least one mainstream browser plays. HEVC and MKV are not
/// flagged: they play in some browsers, and HEVC is itself a target format.
const BROWSER_VIDEO_CODECS: &[&str] = &["h264", "hevc", "vp8", "vp9", "av1"];

fn codec_label(codec: &str) -> String {
    match codec {
        "mpeg4" => "MPEG-4 Part 2 (XviD/DivX)".into(),
        "msmpeg4v1" | "msmpeg4v2" | "msmpeg4v3" => "Microsoft MPEG-4 (DivX 3)".into(),
        "wmv1" | "wmv2" | "wmv3" => "Windows Media".into(),
        "vc1" => "VC-1".into(),
        "mpeg1video" => "MPEG-1".into(),
        "mpeg2video" => "MPEG-2".into(),
        "ac3" => "Dolby Digital (AC-3)".into(),
        "eac3" => "Dolby Digital Plus (E-AC-3)".into(),
        "truehd" => "Dolby TrueHD".into(),
        "dts" => "DTS".into(),
        "wmav1" | "wmav2" | "wmapro" => "Windows Media Audio".into(),
        other => other.to_ascii_uppercase(),
    }
}

/// Why browsers cannot play this video as it is, or an empty list when they
/// can (or when there is no probe yet to tell).
pub fn browser_issues(relative_path: &str, probe: &VideoProbe) -> Vec<String> {
    let mut reasons = Vec::new();
    let extension = relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    if extension == "avi" {
        reasons.push("AVI files do not play in web browsers.".to_string());
    }
    if let Some(codec) = probe.codec.as_deref().map(str::to_ascii_lowercase)
        && !BROWSER_VIDEO_CODECS.contains(&codec.as_str())
    {
        reasons.push(format!(
            "Its {} video does not play in web browsers.",
            codec_label(&codec)
        ));
    }
    let audio = probe
        .audio_codecs
        .iter()
        .map(|codec| codec.trim().to_ascii_lowercase())
        .collect::<Vec<_>>();
    if !audio.is_empty()
        && !audio
            .iter()
            .any(|codec| BROWSER_AUDIO_CODECS.contains(&codec.as_str()))
    {
        let mut labels = audio
            .iter()
            .map(|codec| codec_label(codec))
            .collect::<Vec<_>>();
        labels.dedup();
        reasons.push(format!(
            "Its {} audio is silent in web browsers.",
            labels.join(" and ")
        ));
    }
    reasons
}

// ---------------------------------------------------------------------------
// Encoding plan
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SourceStream {
    pub index: usize,
    pub kind: String,
    pub codec: String,
    pub pix_fmt: Option<String>,
    pub field_order: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub channels: Option<u32>,
    pub attached_pic: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SourceProbe {
    pub duration_seconds: Option<f64>,
    pub streams: Vec<SourceStream>,
}

impl SourceProbe {
    /// Parses `ffprobe -show_streams -show_format -print_format json`.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let value: Value =
            serde_json::from_slice(bytes).map_err(|error| format!("read probe: {error}"))?;
        let duration_seconds = value["format"]["duration"]
            .as_str()
            .and_then(|duration| duration.parse::<f64>().ok())
            .filter(|duration| duration.is_finite() && *duration > 0.0);
        let streams = value["streams"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
            .filter_map(|stream| {
                Some(SourceStream {
                    index: usize::try_from(stream["index"].as_u64()?).ok()?,
                    kind: stream["codec_type"].as_str()?.to_string(),
                    codec: stream["codec_name"]
                        .as_str()
                        .unwrap_or_default()
                        .to_ascii_lowercase(),
                    pix_fmt: stream["pix_fmt"].as_str().map(str::to_string),
                    field_order: stream["field_order"].as_str().map(str::to_string),
                    width: stream["width"].as_i64(),
                    height: stream["height"].as_i64(),
                    channels: stream["channels"]
                        .as_u64()
                        .and_then(|c| u32::try_from(c).ok()),
                    attached_pic: stream["disposition"]["attached_pic"].as_i64() == Some(1),
                })
            })
            .collect();
        Ok(Self {
            duration_seconds,
            streams,
        })
    }

    fn video(&self) -> Option<&SourceStream> {
        self.streams
            .iter()
            .find(|stream| stream.kind == "video" && !stream.attached_pic)
    }

    fn of_kind<'a>(&'a self, kind: &'a str) -> impl Iterator<Item = &'a SourceStream> + 'a {
        self.streams
            .iter()
            .filter(move |stream| stream.kind == kind)
    }
}

/// Subtitle codecs stored as text, which MP4 can carry as `mov_text`.
const TEXT_SUBTITLE_CODECS: &[&str] =
    &["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"];

#[derive(Clone, Debug, PartialEq)]
pub struct EncodePlan {
    /// Output options, placed between the input and the output path.
    pub args: Vec<String>,
    pub muxer: &'static str,
    /// Picture-based subtitle tracks MP4 cannot hold; the original keeps them.
    pub dropped_subtitles: usize,
    pub audio_streams: usize,
    pub subtitle_streams: usize,
}

fn audio_bitrate(format: Format, channels: Option<u32>) -> u32 {
    let channels = channels.unwrap_or(2).max(1);
    match format {
        Format::ModernAv1 => (channels * 48).clamp(96, 320),
        _ => (channels * 64).clamp(128, 384),
    }
}

/// Decide, stream by stream, what to copy and what to encode. Streams that are
/// already in the target codec are copied untouched, so a DVD rip whose only
/// problem is AC-3 audio needs just an audio encode.
pub fn plan(
    format: Format,
    source_extension: &str,
    probe: &SourceProbe,
) -> Result<EncodePlan, String> {
    plan_for_edit(format, source_extension, probe, false)
}

/// An edit must decode the kept range, so a trimmed copy re-encodes video and
/// audio instead of stream-copying around the cut. Untrimmed copies keep the
/// stream-copy optimisation when the source already fits the target format.
pub fn plan_for_edit(
    format: Format,
    source_extension: &str,
    probe: &SourceProbe,
    trimmed: bool,
) -> Result<EncodePlan, String> {
    if format == Format::AudioMp3 {
        let audio = probe
            .of_kind("audio")
            .next()
            .ok_or("This video has no audio track.")?;
        return Ok(EncodePlan {
            args: [
                "-map",
                &format!("0:{}", audio.index),
                "-vn",
                "-sn",
                "-dn",
                "-c:a",
                "libmp3lame",
                "-q:a",
                "2",
                "-ac",
                "2",
                "-map_metadata",
                "-1",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            muxer: "mp3",
            dropped_subtitles: 0,
            audio_streams: 1,
            subtitle_streams: 0,
        });
    }
    let video = probe
        .video()
        .ok_or("This file has no video stream to convert.")?;
    let mut args: Vec<String> = Vec::new();
    let mut push = |values: &[&str]| args.extend(values.iter().map(|value| value.to_string()));

    // Video: exactly the first real picture stream (cover art is dropped).
    push(&["-map", &format!("0:{}", video.index)]);
    let eight_bit = matches!(video.pix_fmt.as_deref(), Some("yuv420p" | "yuvj420p"));
    let copy_video = !trimmed
        && video.codec == format.video_codec()
        && (format.video_codec() != "h264" || eight_bit);
    if copy_video {
        push(&["-c:v", "copy"]);
        if format == Format::CompatibleMp4 && video.codec == "hevc" {
            push(&["-tag:v", "hvc1"]);
        }
    } else {
        let mut filters = Vec::new();
        if matches!(
            video.field_order.as_deref(),
            Some("tt" | "bb" | "tb" | "bt")
        ) {
            filters.push("bwdif=mode=send_frame".to_string());
        }
        if video.width.is_some_and(|w| w % 2 != 0) || video.height.is_some_and(|h| h % 2 != 0) {
            filters.push("scale=trunc(iw/2)*2:trunc(ih/2)*2".to_string());
        }
        if !filters.is_empty() {
            push(&["-filter:v", &filters.join(",")]);
        }
        match format {
            Format::CompatibleMp4 | Format::CompatibleMkv => push(&[
                "-c:v",
                "libx264",
                "-preset",
                "medium",
                "-crf",
                "20",
                "-profile:v",
                "high",
                "-pix_fmt",
                "yuv420p",
            ]),
            Format::EfficientHevc => push(&[
                "-c:v",
                "libx265",
                "-preset",
                "medium",
                "-crf",
                "22",
                "-pix_fmt",
                "yuv420p10le",
                "-x265-params",
                "log-level=error",
            ]),
            Format::AudioMp3 => unreachable!(),
            Format::ModernAv1 => push(&[
                "-c:v",
                "libsvtav1",
                "-preset",
                "6",
                "-crf",
                "30",
                "-pix_fmt",
                "yuv420p10le",
            ]),
        }
    }

    // Audio: every track, in order, so commentary and other languages survive.
    let copyable_audio: &[&str] = if trimmed {
        &[]
    } else {
        match format {
            Format::ModernAv1 => &["opus", "aac"],
            _ => &["aac", "mp3"],
        }
    };
    let mut audio_streams = 0;
    for stream in probe.of_kind("audio") {
        let output = audio_streams;
        audio_streams += 1;
        push(&["-map", &format!("0:{}", stream.index)]);
        if copyable_audio.contains(&stream.codec.as_str()) {
            push(&[&format!("-c:a:{output}"), "copy"]);
            continue;
        }
        let encoder = if format == Format::ModernAv1 {
            "libopus"
        } else {
            "aac"
        };
        push(&[
            &format!("-c:a:{output}"),
            encoder,
            &format!("-b:a:{output}"),
            &format!("{}k", audio_bitrate(format, stream.channels)),
            // Encoders reject some side-channel layouts (5.1(side) on DVDs).
            &format!("-filter:a:{output}"),
            "aformat=channel_layouts=7.1|5.1|stereo|mono",
        ]);
        if encoder == "libopus" {
            push(&[&format!("-mapping_family:a:{output}"), "1"]);
        }
    }

    // Subtitles: MKV keeps every track; MP4 holds text tracks only.
    let mut subtitle_streams = 0;
    let mut dropped_subtitles = 0;
    for stream in probe.of_kind("subtitle") {
        let text = TEXT_SUBTITLE_CODECS.contains(&stream.codec.as_str());
        let codec = match (format, text) {
            (Format::CompatibleMp4, true) => "mov_text",
            (Format::CompatibleMp4, false) => {
                dropped_subtitles += 1;
                continue;
            }
            // Matroska cannot store mov_text; SubRip keeps the same text.
            (_, true) if stream.codec == "mov_text" => "srt",
            _ => "copy",
        };
        push(&["-map", &format!("0:{}", stream.index)]);
        push(&[&format!("-c:s:{subtitle_streams}"), codec]);
        subtitle_streams += 1;
    }
    if format != Format::CompatibleMp4 && probe.of_kind("attachment").next().is_some() {
        // Fonts used by styled (ASS) subtitles.
        push(&["-map", "0:t", "-c:t", "copy"]);
    }

    if format == Format::CompatibleMp4 {
        push(&["-movflags", "+faststart"]);
    }
    push(&["-max_muxing_queue_size", "4096"]);

    let unchanged = !trimmed
        && copy_video
        && source_extension.eq_ignore_ascii_case(format.extension())
        && !args.iter().any(|arg| {
            matches!(
                arg.as_str(),
                "libx264" | "libx265" | "libsvtav1" | "aac" | "libopus" | "mov_text" | "srt"
            )
        })
        && dropped_subtitles == 0;
    if unchanged {
        return Err("This video is already in that format.".into());
    }
    Ok(EncodePlan {
        args,
        muxer: format.muxer(),
        dropped_subtitles,
        audio_streams,
        subtitle_streams,
    })
}

/// The conversion must last as long as the source and carry every planned
/// stream; a truncated or partial encode never replaces the original.
pub fn verify_output(
    source: &SourceProbe,
    output: &SourceProbe,
    plan: &EncodePlan,
) -> Result<(), String> {
    if plan.muxer != "mp3" && output.video().is_none() {
        return Err("The converted file has no video stream.".into());
    }
    if output.of_kind("audio").count() != plan.audio_streams {
        return Err("The converted file is missing audio tracks.".into());
    }
    if output.of_kind("subtitle").count() != plan.subtitle_streams {
        return Err("The converted file is missing subtitle tracks.".into());
    }
    if let Some(expected) = source.duration_seconds {
        let actual = output
            .duration_seconds
            .ok_or("The converted file has no duration.")?;
        if (actual - expected).abs() > (expected * 0.005).max(2.0) {
            return Err(format!(
                "The converted file lasts {actual:.0}s instead of {expected:.0}s, so it was discarded."
            ));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

fn default_mode() -> String {
    MODE_REPLACE.to_string()
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub owner: String,
    pub item_id: String,
    pub root_id: String,
    pub root_label: String,
    pub relative_path: String,
    pub format: String,
    #[serde(default)]
    pub destination_root_id: Option<String>,
    /// `replace` (default) archives and replaces; `copy` writes a new file.
    #[serde(default = "default_mode")]
    pub mode: String,
    /// New leaf name for a copy job, stored beside the source.
    #[serde(default)]
    pub output_name: Option<String>,
    /// Kept playback range for an edited copy.
    #[serde(default)]
    pub trim_start_seconds: Option<f64>,
    #[serde(default)]
    pub trim_end_seconds: Option<f64>,
    /// Fingerprint when queued; a changed file is never converted.
    pub expected_source: String,
    pub source_bytes: u64,
    /// queued, encoding, installing, completed, failed, cancelled
    pub state: String,
    pub created_at: u64,
    #[serde(default)]
    pub started_at: Option<u64>,
    #[serde(default)]
    pub finished_at: Option<u64>,
    #[serde(default)]
    pub progress: Option<f64>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub plan_id: Option<String>,
    #[serde(default)]
    pub staging_filename: Option<String>,
    #[serde(default)]
    pub output_relative_path: Option<String>,
    #[serde(default)]
    pub output_bytes: Option<u64>,
    #[serde(default)]
    pub dropped_subtitles: usize,
}

impl Job {
    pub fn is_active(&self) -> bool {
        matches!(self.state.as_str(), "queued" | "encoding" | "installing")
    }

    pub fn copies_only(&self) -> bool {
        self.mode == MODE_COPY
    }

    /// Keep the chosen fragment; a missing duration cannot bound the end yet.
    pub fn trim_bounds(&self, duration: Option<f64>) -> Result<Option<(f64, f64)>, String> {
        match (self.trim_start_seconds, self.trim_end_seconds) {
            (None, None) => Ok(None),
            (Some(start), Some(end)) => {
                if !start.is_finite() || !end.is_finite() || start < 0.0 {
                    return Err("Choose a valid start and end time.".into());
                }
                let end = match duration {
                    Some(duration) if end > duration + 0.5 => {
                        return Err("The end time is past the end of the video.".into());
                    }
                    Some(duration) => end.min(duration),
                    None => end,
                };
                if end - start < 1.0 {
                    return Err("Choose a range of at least one second.".into());
                }
                Ok(Some((start, end)))
            }
            _ => Err("Choose both a start and end time, or neither.".into()),
        }
    }

    /// Where an edited copy is installed: beside the source, under its name.
    pub fn copy_relative_path(&self) -> Result<String, String> {
        let name = self
            .output_name
            .as_deref()
            .ok_or("Choose a name for the copy.")?;
        Ok(match self.relative_path.rsplit_once('/') {
            Some((folder, _)) if !folder.is_empty() => format!("{folder}/{name}"),
            _ => name.to_string(),
        })
    }

    /// Where the broker keeps the original, beneath the owner's `_Originals`.
    /// Deterministic so the broker can validate it and recover after a crash.
    pub fn archived_relative_path(&self) -> String {
        archived_relative_path(&self.root_id, &self.relative_path)
    }

    pub fn view(&self) -> Value {
        json!({
            "id": self.id,
            "itemId": self.item_id,
            "rootId": self.root_id,
            "rootLabel": self.root_label,
            "relativePath": self.relative_path,
            "format": self.format,
            "destinationRootId": self.destination_root_id,
            "mode": if self.mode.is_empty() { MODE_REPLACE } else { &self.mode },
            "trimStartSeconds": self.trim_start_seconds,
            "trimEndSeconds": self.trim_end_seconds,
            "state": self.state,
            "createdAt": self.created_at,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "progress": self.progress,
            "error": self.error,
            "sourceBytes": self.source_bytes,
            "outputBytes": self.output_bytes,
            "outputRelativePath": self.output_relative_path,
            "archivedPath": if self.copies_only() {
                Value::Null
            } else {
                json!(format!("{ORIGINALS_DIRECTORY}/{}", self.archived_relative_path()))
            },
            "droppedSubtitles": self.dropped_subtitles,
        })
    }

    pub fn save(&self, config: &AppConfig) -> Result<(), String> {
        owner_dir(config, &self.owner)?.write(
            &format!("{}.json", self.id),
            &serde_json::to_vec(self).map_err(|error| error.to_string())?,
        )
    }
}

pub fn archived_relative_path(root_id: &str, relative_path: &str) -> String {
    format!("Videos/{root_id}/{relative_path}")
}

/// A copy beside the source whose name people can tell apart from the original.
pub fn default_copy_name(relative_path: &str, format: Format) -> String {
    let file = relative_path.rsplit('/').next().unwrap_or(relative_path);
    let stem = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
    format!("{stem} (edited).{}", format.extension())
}

/// A copy name is one leaf with the chosen format's extension and no traversal.
pub fn valid_copy_name(name: &str, format: Format) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && name != "."
        && name != ".."
        && !name.starts_with('.')
        && !name.contains(['/', '\\'])
        && !name.chars().any(char::is_control)
        && name.rsplit_once('.').is_some_and(|(stem, extension)| {
            !stem.is_empty() && extension.eq_ignore_ascii_case(format.extension())
        })
}

/// The converted file's library path: same folder and name, new extension.
pub fn output_relative_path(relative_path: &str, format: Format) -> String {
    let stem = relative_path
        .rsplit_once('.')
        .map_or(relative_path, |(stem, _)| stem);
    format!("{stem}.{}", format.extension())
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn jobs_root(config: &AppConfig) -> Result<Dir, String> {
    Dir::open(&config.state_dir)?.create_shared(JOBS_DIRECTORY)
}

pub fn owner_dir(config: &AppConfig, username: &str) -> Result<Dir, String> {
    Identity::try_new(username, std::iter::empty::<&str>()).map_err(|_| "Invalid owner")?;
    jobs_root(config)?.create_shared(username)
}

pub fn jobs(config: &AppConfig, username: &str) -> Result<Vec<Job>, String> {
    let dir = owner_dir(config, username)?;
    let mut jobs = Vec::new();
    for name in dir
        .names()?
        .into_iter()
        .filter(|name| name.ends_with(".json"))
    {
        let Ok(bytes) = dir.read(&name, MAX_JOB_BYTES) else {
            continue;
        };
        if let Ok(job) = serde_json::from_slice::<Job>(&bytes)
            && job.owner == username
            && name == format!("{}.json", job.id)
        {
            jobs.push(job);
        }
    }
    jobs.sort_by_key(|job| std::cmp::Reverse((job.created_at, job.id.clone())));
    Ok(jobs)
}

/// Every owner's jobs, oldest first, so earlier requests are converted first.
pub fn all_jobs(config: &AppConfig) -> Result<Vec<Job>, String> {
    let root = jobs_root(config)?;
    let mut all = Vec::new();
    for owner in root.names()? {
        if Identity::try_new(&owner, std::iter::empty::<&str>()).is_ok()
            && root.child(&owner).is_ok()
        {
            all.extend(jobs(config, &owner)?);
        }
    }
    all.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(all)
}

/// Drop finished jobs beyond the history limit.
pub fn prune_history(config: &AppConfig, username: &str) -> Result<(), String> {
    let dir = owner_dir(config, username)?;
    for job in jobs(config, username)?
        .into_iter()
        .filter(|job| !job.is_active())
        .skip(HISTORY_LIMIT)
    {
        let _ = dir.remove(&format!("{}.json", job.id));
        let _ = dir.remove(&cancel_marker(&job.id));
    }
    Ok(())
}

pub fn cancel_marker(job_id: &str) -> String {
    format!("{job_id}.cancel")
}

pub fn cancel_requested(config: &AppConfig, job: &Job) -> bool {
    owner_dir(config, &job.owner)
        .and_then(|dir| dir.file(&cancel_marker(&job.id)))
        .is_ok()
}

/// Ask the worker to stop. Queued jobs are cancelled immediately; an encode
/// in progress stops at its next progress check. Installing cannot be undone.
pub fn request_cancel(config: &AppConfig, username: &str, job_id: &str) -> Result<Job, String> {
    let mut job = jobs(config, username)?
        .into_iter()
        .find(|job| job.id == job_id)
        .ok_or("That conversion was not found.")?;
    match job.state.as_str() {
        "queued" => {
            job.state = "cancelled".into();
            job.finished_at = Some(now());
            job.save(config)?;
        }
        "encoding" => {
            owner_dir(config, username)?.write(&cancel_marker(job_id), b"cancel")?;
        }
        "installing" => {
            return Err("The converted video is already being installed.".into());
        }
        _ => {}
    }
    Ok(job)
}

/// Touch the wake directory so the worker's path unit starts it.
pub fn wake_worker(config: &AppConfig) -> Result<(), String> {
    let dir = Dir::open(&config.state_dir)?.create_shared(WAKE_DIRECTORY)?;
    dir.write("wake", now().to_string().as_bytes())
}

pub fn formats_view() -> Value {
    json!(Format::ALL
        .iter()
        .map(|format| json!({ "id": format.id(), "extension": format.extension() }))
        .collect::<Vec<_>>())
}

/// Bytes available below `path` (or its nearest existing ancestor).
pub fn available_space(path: &std::path::Path) -> Result<u64, String> {
    let existing = path
        .ancestors()
        .find(|candidate| candidate.exists())
        .unwrap_or(path);
    fs2::available_space(existing)
        .map_err(|error| format!("check free space on {}: {error}", existing.display()))
}

/// The refusal shared by the worker and the broker.
pub fn not_enough_space(needed: u64, reserve: u64, available: u64) -> String {
    const GIB: f64 = 1024.0 * 1024.0 * 1024.0;
    format!(
        "Not enough free space: this conversion needs {:.1} GiB including a {:.0} GiB reserve for the server, but only {:.1} GiB is free. Free up space, then convert again.",
        needed as f64 / GIB,
        reserve as f64 / GIB,
        available as f64 / GIB
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(index: usize, kind: &str, codec: &str) -> SourceStream {
        SourceStream {
            index,
            kind: kind.into(),
            codec: codec.into(),
            ..SourceStream::default()
        }
    }

    fn dvd_rip() -> SourceProbe {
        SourceProbe {
            duration_seconds: Some(8514.0),
            streams: vec![
                SourceStream {
                    pix_fmt: Some("yuv420p".into()),
                    width: Some(720),
                    height: Some(576),
                    ..stream(0, "video", "h264")
                },
                SourceStream {
                    channels: Some(6),
                    ..stream(1, "audio", "ac3")
                },
                stream(2, "subtitle", "dvd_subtitle"),
                stream(3, "subtitle", "subrip"),
            ],
        }
    }

    #[test]
    fn browser_issues_name_the_container_and_codecs_that_fail() {
        let probe = VideoProbe {
            codec: Some("mpeg4".into()),
            audio_codecs: vec!["ac3".into()],
            ..VideoProbe::default()
        };
        let reasons = browser_issues("Films/Old.avi", &probe);
        assert_eq!(reasons.len(), 3);
        assert!(reasons[1].contains("XviD"));
        assert!(reasons[2].contains("AC-3"));
        let playable = VideoProbe {
            codec: Some("hevc".into()),
            audio_codecs: vec!["ac3".into(), "aac".into()],
            ..VideoProbe::default()
        };
        assert!(browser_issues("Films/New.mkv", &playable).is_empty());
    }

    #[test]
    fn compatible_formats_copy_h264_and_encode_only_the_audio() {
        let plan = plan(Format::CompatibleMkv, "mkv", &dvd_rip()).unwrap();
        let args = plan.args.join(" ");
        assert!(args.contains("-c:v copy"));
        assert!(args.contains("-c:a:0 aac -b:a:0 384k"));
        assert!(args.contains("-c:s:0 copy") && args.contains("-c:s:1 copy"));
        assert_eq!((plan.audio_streams, plan.subtitle_streams), (1, 2));

        let mp4 = super::plan(Format::CompatibleMp4, "mkv", &dvd_rip()).unwrap();
        let args = mp4.args.join(" ");
        assert!(args.contains("-c:s:0 mov_text") && !args.contains("0:2"));
        assert_eq!((mp4.dropped_subtitles, mp4.subtitle_streams), (1, 1));
        assert!(args.contains("+faststart"));
    }

    #[test]
    fn interlaced_ten_bit_and_cover_art_are_handled_when_encoding() {
        let probe = SourceProbe {
            duration_seconds: Some(60.0),
            streams: vec![
                SourceStream {
                    attached_pic: true,
                    ..stream(0, "video", "mjpeg")
                },
                SourceStream {
                    pix_fmt: Some("yuv420p10le".into()),
                    field_order: Some("tt".into()),
                    width: Some(721),
                    height: Some(480),
                    ..stream(1, "video", "h264")
                },
            ],
        };
        let args = plan(Format::CompatibleMp4, "mkv", &probe)
            .unwrap()
            .args
            .join(" ");
        assert!(args.starts_with("-map 0:1 "));
        assert!(args.contains("bwdif") && args.contains("trunc(iw/2)*2"));
        assert!(args.contains("libx264") && args.contains("yuv420p"));
    }

    #[test]
    fn av1_uses_opus_and_already_converted_files_are_refused() {
        let args = plan(Format::ModernAv1, "mkv", &dvd_rip())
            .unwrap()
            .args
            .join(" ");
        assert!(args.contains("libsvtav1") && args.contains("-c:a:0 libopus"));
        assert!(args.contains("-mapping_family:a:0 1"));

        let converted = SourceProbe {
            duration_seconds: Some(60.0),
            streams: vec![
                SourceStream {
                    pix_fmt: Some("yuv420p".into()),
                    ..stream(0, "video", "h264")
                },
                stream(1, "audio", "aac"),
            ],
        };
        assert!(plan(Format::CompatibleMp4, "mp4", &converted).is_err());
        assert!(plan(Format::CompatibleMp4, "avi", &converted).is_ok());
    }

    #[test]
    fn trimmed_copies_reencode_instead_of_stream_copying_around_the_cut() {
        let converted = SourceProbe {
            duration_seconds: Some(600.0),
            streams: vec![
                SourceStream {
                    pix_fmt: Some("yuv420p".into()),
                    ..stream(0, "video", "h264")
                },
                stream(1, "audio", "aac"),
            ],
        };
        assert!(plan(Format::CompatibleMp4, "mp4", &converted).is_err());
        let trimmed = plan_for_edit(Format::CompatibleMp4, "mp4", &converted, true).unwrap();
        let args = trimmed.args.join(" ");
        assert!(args.contains("libx264") && args.contains("-c:a:0 aac"));
        assert!(!args.contains("-c:v copy") && !args.contains("-c:a:0 copy"));
    }

    #[test]
    fn copy_names_stay_beside_the_source_and_match_the_format() {
        assert_eq!(
            default_copy_name("Films/Old (1999)/Old.mkv", Format::CompatibleMp4),
            "Old (edited).mp4"
        );
        assert!(valid_copy_name("Old (edited).mp4", Format::CompatibleMp4));
        assert!(!valid_copy_name("Old (edited).mkv", Format::CompatibleMp4));
        assert!(!valid_copy_name("../Old.mp4", Format::CompatibleMp4));
        assert!(!valid_copy_name(".Old.mp4", Format::CompatibleMp4));
        assert!(valid_copy_name("Old edit.MKV", Format::CompatibleMkv));
    }

    #[test]
    fn verification_rejects_truncated_or_incomplete_output() {
        let source = dvd_rip();
        let plan = plan(Format::CompatibleMkv, "mkv", &source).unwrap();
        let mut output = source.clone();
        assert!(verify_output(&source, &output, &plan).is_ok());
        output.duration_seconds = Some(8000.0);
        assert!(verify_output(&source, &output, &plan).is_err());
        output.duration_seconds = source.duration_seconds;
        output.streams.retain(|stream| stream.kind != "audio");
        assert!(verify_output(&source, &output, &plan).is_err());
    }

    #[test]
    fn paths_keep_the_name_and_archive_beneath_the_root() {
        assert_eq!(
            output_relative_path("Films/Old (1999)/Old.avi", Format::CompatibleMp4),
            "Films/Old (1999)/Old.mp4"
        );
        assert_eq!(
            archived_relative_path("shared-videos", "Films/Old.avi"),
            "Videos/shared-videos/Films/Old.avi"
        );
    }
}
