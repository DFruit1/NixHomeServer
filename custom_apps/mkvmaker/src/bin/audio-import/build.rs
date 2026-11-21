//! Turn the discs of one book into the files Audiobookshelf reads: one M4B
//! with embedded chapters and cover, plus the `metadata.json` that
//! Audiobookshelf gives the highest precedence.

use crate::{
    book::Proposal,
    disc::{Disc, DiscKind},
    fsops::{natural_key, normalized, safe_component, sha256_file},
};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::BTreeSet,
    fmt, fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
};

/// A cover fetched from the metadata provider, which the caller may place
/// in the work folder. It is used when the discs carry none.
pub const PROVIDER_COVER: &str = "provider-cover.jpg";

pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    pub sevenzip: PathBuf,
}

/// The worker was asked to stop; nothing is charged to the book.
#[derive(Debug)]
pub struct Stopped;

impl fmt::Display for Stopped {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("stopped before the book was finished")
    }
}

impl std::error::Error for Stopped {}

#[derive(Clone, Debug, Serialize)]
pub struct Chapter {
    pub id: usize,
    pub start: f64,
    pub end: f64,
    pub title: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Built {
    /// How the audio was produced: `aac-mono`, `aac-stereo`, `remux` or `copy`.
    pub audio: String,
    pub duration_seconds: f64,
    pub chapters: usize,
    pub chapter_source: String,
    pub files: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AbsMetadata<'a> {
    title: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    subtitle: &'a str,
    authors: Vec<&'a str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    narrators: Vec<&'a str>,
    /// `Name #3`, the form Audiobookshelf parses into name and sequence.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    series: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    published_year: Option<String>,
    #[serde(skip_serializing_if = "str::is_empty")]
    publisher: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    description: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    asin: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    abridged: Option<bool>,
    #[serde(skip_serializing_if = "<[Chapter]>::is_empty")]
    chapters: &'a [Chapter],
}

struct Piece {
    path: PathBuf,
    disc: usize,
    number: u32,
    title: String,
    seconds: f64,
}

fn check_stop(stop: &AtomicBool) -> Result<()> {
    if stop.load(Ordering::Relaxed) {
        return Err(Stopped.into());
    }
    Ok(())
}

fn extract(tools: &Tools, iso: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    let mut output_flag = std::ffi::OsString::from("-o");
    output_flag.push(destination);
    let output = Command::new(&tools.sevenzip)
        .args(["x", "-y", "-bd", "-bso0", "-bsp0"])
        .arg(output_flag)
        .arg("--")
        .arg(iso)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", tools.sevenzip.display()))?;
    if !output.status.success() {
        bail!(
            "7-Zip cannot extract {}: {}",
            iso.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

/// Seconds and channel count from a FLAC STREAMINFO block.
fn flac_info(path: &Path) -> Result<(f64, u32)> {
    let mut header = [0u8; 26];
    fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut header))
        .with_context(|| format!("cannot read {}", path.display()))?;
    if &header[..4] != b"fLaC" || header[4] & 0x7f != 0 {
        bail!("{} is not a FLAC file", path.display());
    }
    let packed = u64::from_be_bytes(header[18..26].try_into().expect("eight bytes"));
    let rate = packed >> 44;
    let channels = ((packed >> 41) & 0x7) as u32 + 1;
    let samples = packed & ((1 << 36) - 1);
    if rate == 0 || samples == 0 {
        bail!("{} does not record its length", path.display());
    }
    Ok((samples as f64 / rate as f64, channels))
}

fn probe(tools: &Tools, path: &Path, entries: &str, chapters: bool) -> Result<Value> {
    let mut command = Command::new(&tools.ffprobe);
    command.args(["-v", "error", "-show_entries", entries, "-of", "json"]);
    if chapters {
        command.arg("-show_chapters");
    }
    let output = command
        .arg(path)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", tools.ffprobe.display()))?;
    if !output.status.success() {
        bail!(
            "ffprobe cannot read {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).context("ffprobe printed invalid JSON")
}

/// Playing time of an audio file: exact for FLAC, probed for the rest.
pub fn media_seconds(tools: &Tools, path: &Path) -> Option<f64> {
    flac_info(path)
        .map(|(seconds, _)| seconds)
        .ok()
        .or_else(|| probed_duration(&probe(tools, path, "format=duration", false).ok()?))
}

fn probed_duration(value: &Value) -> Option<f64> {
    value["format"]["duration"]
        .as_str()?
        .parse::<f64>()
        .ok()
        .filter(|seconds| *seconds > 0.0)
}

/// True when the left and right channels carry the same signal, as on most
/// spoken-word CDs, so a mono encode loses nothing.
fn channels_identical(tools: &Tools, path: &Path) -> Result<bool> {
    let output = Command::new(&tools.ffmpeg)
        .args(["-hide_banner", "-nostdin", "-v", "info", "-t", "120", "-i"])
        .arg(path)
        .args([
            "-map",
            "0:a:0",
            "-af",
            "pan=mono|c0=0.5*c0-0.5*c1,volumedetect",
            "-f",
            "null",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", tools.ffmpeg.display()))?;
    if !output.status.success() {
        bail!("ffmpeg cannot compare the channels of {}", path.display());
    }
    let log = String::from_utf8_lossy(&output.stderr);
    let Some(level) = log
        .lines()
        .rev()
        .find_map(|line| line.split("max_volume:").nth(1))
        .map(|value| value.trim().trim_end_matches("dB").trim().to_string())
    else {
        return Ok(false);
    };
    Ok(level == "-inf" || level.parse::<f64>().is_ok_and(|decibels| decibels <= -60.0))
}

fn ffmetadata_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '=' | ';' | '#' | '\\' => {
                escaped.push('\\');
                escaped.push(ch);
            }
            '\n' | '\r' => escaped.push(' '),
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn write_ffmetadata(path: &Path, proposal: &Proposal, chapters: &[Chapter]) -> Result<()> {
    let mut text = String::from(";FFMETADATA1\n");
    let mut tag = |key: &str, value: &str| {
        if !value.is_empty() {
            text.push_str(&format!("{key}={}\n", ffmetadata_escape(value)));
        }
    };
    tag("title", &proposal.title);
    tag("album", &proposal.title);
    tag("artist", &proposal.author);
    tag("album_artist", &proposal.author);
    tag("composer", &proposal.narrator);
    tag(
        "date",
        &proposal
            .year
            .map(|year| year.to_string())
            .unwrap_or_default(),
    );
    tag("publisher", &proposal.publisher);
    tag("genre", "Audiobook");
    tag("media_type", "2");
    for chapter in chapters {
        text.push_str(&format!(
            "[CHAPTER]\nTIMEBASE=1/1000\nSTART={}\nEND={}\ntitle={}\n",
            (chapter.start * 1000.0).round() as u64,
            (chapter.end * 1000.0).round() as u64,
            ffmetadata_escape(&chapter.title)
        ));
    }
    fs::write(path, text).with_context(|| format!("cannot write {}", path.display()))
}

fn write_concat_list(path: &Path, pieces: &[Piece]) -> Result<()> {
    let mut text = String::from("ffconcat version 1.0\n");
    for piece in pieces {
        let name = piece
            .path
            .to_str()
            .context("extracted path is not valid UTF-8")?;
        text.push_str(&format!("file '{}'\n", name.replace('\'', "'\\''")));
    }
    fs::write(path, text).with_context(|| format!("cannot write {}", path.display()))
}

/// Run ffmpeg, reporting the share of `total_seconds` written so far.
fn run_ffmpeg(
    tools: &Tools,
    arguments: &[std::ffi::OsString],
    total_seconds: f64,
    log: &Path,
    progress: &mut dyn FnMut(f64),
    stop: &AtomicBool,
) -> Result<()> {
    let log_file = fs::File::create(log)?;
    let mut child = Command::new(&tools.ffmpeg)
        .args(["-hide_banner", "-nostdin", "-loglevel", "error", "-y"])
        .args(arguments)
        .args(["-progress", "pipe:1", "-nostats"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log_file))
        .spawn()
        .with_context(|| format!("cannot run {}", tools.ffmpeg.display()))?;
    let reader = BufReader::new(child.stdout.take().expect("piped stdout"));
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if stop.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Stopped.into());
        }
        if let Some(value) = line
            .strip_prefix("out_time_us=")
            .or_else(|| line.strip_prefix("out_time_ms="))
            && let Ok(microseconds) = value.trim().parse::<f64>()
            && total_seconds > 0.0
        {
            progress((microseconds / 1_000_000.0 / total_seconds * 100.0).clamp(0.0, 100.0));
        }
    }
    let status = child.wait()?;
    check_stop(stop)?;
    if !status.success() {
        let detail = fs::read_to_string(log).unwrap_or_default();
        let detail: Vec<&str> = detail.lines().rev().take(4).collect();
        bail!(
            "ffmpeg failed ({status}): {}",
            detail.into_iter().rev().collect::<Vec<_>>().join(" | ")
        );
    }
    Ok(())
}

fn validate_output(
    tools: &Tools,
    output: &Path,
    expected_seconds: f64,
    expected_chapters: usize,
) -> Result<()> {
    let report = probe(tools, output, "format=duration", true)?;
    let seconds = probed_duration(&report).context("the finished file has no duration")?;
    let tolerance = f64::max(2.0, expected_seconds * 0.002);
    if (seconds - expected_seconds).abs() > tolerance {
        bail!("the finished file runs {seconds:.1} s but the discs hold {expected_seconds:.1} s");
    }
    let chapters = report["chapters"].as_array().map_or(0, Vec::len);
    if chapters != expected_chapters {
        bail!("the finished file has {chapters} chapters instead of {expected_chapters}");
    }
    Ok(())
}

fn generic_track_title(title: &str, number: u32) -> bool {
    let name = normalized(title);
    name.is_empty() || name == format!("track{number}") || name == format!("track{number:02}")
}

/// One chapter per piece. A ripper placeholder such as `Track 05` becomes
/// `Disc 2, Track 5`; real titles repeated across discs get a disc prefix.
fn chapters_from_pieces(pieces: &[Piece], disc_count: usize) -> Vec<Chapter> {
    let named: Vec<String> = pieces
        .iter()
        .filter(|piece| !generic_track_title(&piece.title, piece.number))
        .map(|piece| normalized(&piece.title))
        .collect();
    let unique = named.iter().collect::<BTreeSet<_>>().len() == named.len();
    let multi = disc_count > 1;
    let mut start = 0.0;
    pieces
        .iter()
        .enumerate()
        .map(|(id, piece)| {
            let title = if generic_track_title(&piece.title, piece.number) {
                if multi {
                    format!("Disc {}, Track {}", piece.disc, piece.number)
                } else {
                    format!("Track {}", piece.number)
                }
            } else if multi && !unique {
                format!("Disc {}: {}", piece.disc, piece.title)
            } else {
                piece.title.clone()
            };
            let chapter = Chapter {
                id,
                start,
                end: start + piece.seconds,
                title,
            };
            start += piece.seconds;
            chapter
        })
        .collect()
}

fn write_abs_metadata(output: &Path, proposal: &Proposal, chapters: &[Chapter]) -> Result<()> {
    let metadata = AbsMetadata {
        title: &proposal.title,
        subtitle: &proposal.subtitle,
        authors: vec![proposal.author.as_str()],
        narrators: proposal
            .narrator
            .split(", ")
            .filter(|name| !name.is_empty())
            .collect(),
        series: proposal
            .series
            .iter()
            .map(|series| {
                if series.sequence.is_empty() {
                    series.name.clone()
                } else {
                    format!("{} #{}", series.name, series.sequence)
                }
            })
            .collect(),
        published_year: proposal.year.map(|year| year.to_string()),
        publisher: &proposal.publisher,
        description: &proposal.description,
        asin: &proposal.asin,
        abridged: proposal.abridged,
        chapters,
    };
    let mut text = serde_json::to_string_pretty(&metadata)?;
    text.push('\n');
    fs::write(output.join("metadata.json"), text).context("cannot write metadata.json")
}

fn os(value: &str) -> std::ffi::OsString {
    value.into()
}

fn build_from_archives(
    tools: &Tools,
    proposal: &Proposal,
    discs: &[(PathBuf, Disc)],
    work: &Path,
    output: &Path,
    progress: &mut dyn FnMut(&str, f64),
    stop: &AtomicBool,
) -> Result<Built> {
    let mut pieces = Vec::new();
    let mut cover: Option<PathBuf> = None;
    let mut channels = 1;
    for (index, (iso, disc)) in discs.iter().enumerate() {
        check_stop(stop)?;
        progress(
            "Reading the discs",
            index as f64 / discs.len() as f64 * 100.0,
        );
        let directory = work.join(format!("disc{:02}", index + 1));
        extract(tools, iso, &directory)?;
        let mut tracks = disc.tracks.clone();
        tracks.sort_by_key(|track| track.number);
        for track in tracks {
            check_stop(stop)?;
            let path = directory.join(&track.file);
            if !fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file()) {
                bail!("{} is missing track file {}", disc.iso_name, track.file);
            }
            if !track.sha256.is_empty() && sha256_file(&path)? != track.sha256 {
                bail!(
                    "{} track {} does not match the checksum recorded when it was ripped",
                    disc.iso_name,
                    track.number
                );
            }
            let (seconds, track_channels) = flac_info(&path)?;
            channels = channels.max(track_channels);
            pieces.push(Piece {
                path,
                disc: index + 1,
                number: track.number,
                title: track.title,
                seconds,
            });
        }
        if cover.is_none() && !disc.cover.is_empty() && !disc.cover.contains('/') {
            let candidate = directory.join(&disc.cover);
            if candidate.is_file() {
                cover = Some(candidate);
            }
        }
    }
    if cover.is_none() && work.join(PROVIDER_COVER).is_file() {
        cover = Some(work.join(PROVIDER_COVER));
    }
    let total: f64 = pieces.iter().map(|piece| piece.seconds).sum();
    let chapters = chapters_from_pieces(&pieces, discs.len());

    let mut mono = channels == 1;
    if !mono {
        let samples = [0, pieces.len() / 2, pieces.len() - 1];
        let samples: BTreeSet<usize> = samples.into_iter().collect();
        mono = true;
        for index in samples {
            check_stop(stop)?;
            if !channels_identical(tools, &pieces[index].path)? {
                mono = false;
                break;
            }
        }
    }

    let list = work.join("concat.txt");
    let tags = work.join("chapters.ffmeta");
    write_concat_list(&list, &pieces)?;
    write_ffmetadata(&tags, proposal, &chapters)?;
    fs::create_dir_all(output)?;
    let file_name = format!("{}.m4b", safe_component(&proposal.title, "Audiobook"));
    let target = output.join(&file_name);

    let mut arguments = vec![
        os("-f"),
        os("concat"),
        os("-safe"),
        os("0"),
        os("-i"),
        list.into_os_string(),
    ];
    arguments.extend([os("-f"), os("ffmetadata"), os("-i"), tags.into_os_string()]);
    if let Some(cover) = &cover {
        arguments.extend([os("-i"), cover.clone().into_os_string()]);
    }
    arguments.extend([os("-map"), os("0:a:0")]);
    if cover.is_some() {
        arguments.extend(
            [
                "-map",
                "2:v:0",
                "-c:v",
                "copy",
                "-disposition:v:0",
                "attached_pic",
            ]
            .map(os),
        );
    }
    arguments.extend(["-map_metadata", "1", "-map_chapters", "1", "-c:a", "aac"].map(os));
    arguments.extend(if mono {
        ["-b:a", "64k", "-ac", "1"].map(os)
    } else {
        ["-b:a", "96k", "-ac", "2"].map(os)
    });
    // The mp4 muxer accepts cover art that the ipod muxer refuses; players
    // read the audiobook from the .m4b extension.
    arguments.extend(["-movflags", "+faststart", "-f", "mp4"].map(os));
    arguments.push(target.clone().into_os_string());

    run_ffmpeg(
        tools,
        &arguments,
        total,
        &work.join("ffmpeg.log"),
        &mut |percent| progress("Encoding", percent),
        stop,
    )?;
    progress("Checking the result", 100.0);
    validate_output(tools, &target, total, chapters.len())?;

    let mut files = vec![file_name, "metadata.json".to_string()];
    if let Some(cover) = cover {
        let extension = cover
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("jpg");
        let name = format!("cover.{}", extension.to_ascii_lowercase());
        fs::copy(&cover, output.join(&name)).context("cannot copy the cover")?;
        files.push(name);
    }
    write_abs_metadata(output, proposal, &chapters)?;
    Ok(Built {
        audio: if mono { "aac-mono" } else { "aac-stereo" }.to_string(),
        duration_seconds: total,
        chapters: chapters.len(),
        chapter_source: "cd-tracks".to_string(),
        files,
    })
}

fn move_into(source: &Path, destination: &Path) -> Result<()> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    crate::fsops::move_file(source, destination)
}

/// A data CD already holds lossy files. M4B and M4A sources are joined
/// without re-encoding; anything else (MP3) is copied unchanged, because a
/// second lossy encode would only cost quality.
fn build_from_data(
    tools: &Tools,
    proposal: &Proposal,
    discs: &[(PathBuf, Disc)],
    work: &Path,
    output: &Path,
    progress: &mut dyn FnMut(&str, f64),
    stop: &AtomicBool,
) -> Result<Built> {
    struct Source {
        path: PathBuf,
        relative: String,
        disc: usize,
    }
    let mut sources = Vec::new();
    for (index, (iso, disc)) in discs.iter().enumerate() {
        check_stop(stop)?;
        progress(
            "Reading the discs",
            index as f64 / discs.len() as f64 * 100.0,
        );
        let directory = work.join(format!("disc{:02}", index + 1));
        extract(tools, iso, &directory)?;
        let mut files = disc.audio_files.clone();
        files.sort_by_key(|path| natural_key(path));
        for relative in files {
            if relative
                .split('/')
                .any(|part| part == ".." || part.is_empty())
            {
                bail!("{} has an unsafe file name: {relative}", disc.iso_name);
            }
            let path = directory.join(&relative);
            if !fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file()) {
                bail!("{} is missing {relative}", disc.iso_name);
            }
            sources.push(Source {
                path,
                relative,
                disc: index + 1,
            });
        }
    }
    if sources.is_empty() {
        bail!("the discs hold no audio files");
    }
    fs::create_dir_all(output)?;
    let extension = |source: &Source| {
        Path::new(&source.relative)
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase()
    };
    let file_name = format!("{}.m4b", safe_component(&proposal.title, "Audiobook"));
    let mp4_family = sources
        .iter()
        .all(|source| matches!(extension(source).as_str(), "m4a" | "m4b"));

    if mp4_family && sources.len() == 1 {
        let seconds = probed_duration(&probe(tools, &sources[0].path, "format=duration", false)?)
            .unwrap_or_default();
        move_into(&sources[0].path, &output.join(&file_name))?;
        write_abs_metadata(output, proposal, &[])?;
        return Ok(Built {
            audio: "copy".to_string(),
            duration_seconds: seconds,
            chapters: 0,
            chapter_source: "embedded".to_string(),
            files: vec![file_name, "metadata.json".to_string()],
        });
    }

    if mp4_family {
        let mut formats = BTreeSet::new();
        let mut pieces = Vec::new();
        for (index, source) in sources.iter().enumerate() {
            check_stop(stop)?;
            let report = probe(
                tools,
                &source.path,
                "format=duration:stream=codec_type,codec_name,sample_rate,channels",
                false,
            )?;
            let audio = report["streams"]
                .as_array()
                .and_then(|streams| {
                    streams
                        .iter()
                        .find(|stream| stream["codec_type"] == "audio")
                })
                .cloned()
                .unwrap_or(Value::Null);
            formats.insert(format!(
                "{}/{}/{}",
                audio["codec_name"], audio["sample_rate"], audio["channels"]
            ));
            let title = Path::new(&source.relative)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or_default()
                .to_string();
            pieces.push(Piece {
                path: source.path.clone(),
                disc: source.disc,
                number: index as u32 + 1,
                title,
                seconds: probed_duration(&report)
                    .with_context(|| format!("{} has no duration", source.relative))?,
            });
        }
        if formats.len() == 1 && formats.iter().all(|format| format.starts_with("\"aac\"")) {
            let total: f64 = pieces.iter().map(|piece| piece.seconds).sum();
            let chapters = chapters_from_pieces(&pieces, discs.len());
            let list = work.join("concat.txt");
            let tags = work.join("chapters.ffmeta");
            write_concat_list(&list, &pieces)?;
            write_ffmetadata(&tags, proposal, &chapters)?;
            let target = output.join(&file_name);
            let mut arguments = vec![
                os("-f"),
                os("concat"),
                os("-safe"),
                os("0"),
                os("-i"),
                list.into_os_string(),
            ];
            arguments.extend([os("-f"), os("ffmetadata"), os("-i"), tags.into_os_string()]);
            arguments.extend(
                [
                    "-map",
                    "0:a:0",
                    "-map_metadata",
                    "1",
                    "-map_chapters",
                    "1",
                    "-c:a",
                    "copy",
                    "-movflags",
                    "+faststart",
                    "-f",
                    "mp4",
                ]
                .map(os),
            );
            arguments.push(target.clone().into_os_string());
            run_ffmpeg(
                tools,
                &arguments,
                total,
                &work.join("ffmpeg.log"),
                &mut |percent| progress("Joining", percent),
                stop,
            )?;
            validate_output(tools, &target, total, chapters.len())?;
            write_abs_metadata(output, proposal, &chapters)?;
            return Ok(Built {
                audio: "remux".to_string(),
                duration_seconds: total,
                chapters: chapters.len(),
                chapter_source: "files".to_string(),
                files: vec![file_name, "metadata.json".to_string()],
            });
        }
    }

    // Audiobookshelf builds its own chapters from separate files.
    let multi = discs.len() > 1;
    let mut files = Vec::new();
    let mut seconds = 0.0;
    for source in &sources {
        check_stop(stop)?;
        seconds += probed_duration(&probe(tools, &source.path, "format=duration", false)?)
            .unwrap_or_default();
        let mut relative = PathBuf::new();
        if multi {
            relative.push(format!("Disc {:02}", source.disc));
        }
        for part in source.relative.split('/') {
            relative.push(safe_component(part, "file"));
        }
        move_into(&source.path, &output.join(&relative))?;
        files.push(relative.to_string_lossy().into_owned());
    }
    write_abs_metadata(output, proposal, &[])?;
    files.push("metadata.json".to_string());
    Ok(Built {
        audio: "copy".to_string(),
        duration_seconds: seconds,
        chapters: 0,
        chapter_source: "files".to_string(),
        files,
    })
}

/// Build the book folder in `output` from the ordered discs, using `work`
/// for extraction scratch.
pub fn build(
    tools: &Tools,
    proposal: &Proposal,
    discs: &[(PathBuf, Disc)],
    work: &Path,
    output: &Path,
    progress: &mut dyn FnMut(&str, f64),
    stop: &AtomicBool,
) -> Result<Built> {
    if discs
        .iter()
        .all(|(_, disc)| disc.kind == DiscKind::AudioArchive)
    {
        build_from_archives(tools, proposal, discs, work, output, progress, stop)
    } else if discs.iter().all(|(_, disc)| disc.kind == DiscKind::Data) {
        let mut built = build_from_data(tools, proposal, discs, work, output, progress, stop)?;
        if work.join(PROVIDER_COVER).is_file() && !output.join("cover.jpg").exists() {
            fs::copy(work.join(PROVIDER_COVER), output.join("cover.jpg"))
                .context("cannot copy the cover")?;
            built.files.push("cover.jpg".to_string());
        }
        Ok(built)
    } else {
        bail!("the set mixes audio CDs and data CDs")
    }
}
