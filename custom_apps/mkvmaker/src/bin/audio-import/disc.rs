//! What one ISO from the desktop ripper says about itself.
//!
//! An audio CD is archived as a data ISO of FLAC tracks with a `metadata.json`
//! written by the ripper; a data CD (MP3 or M4B audiobook) is a raw image whose
//! description lives only in the `.disc.json` sidecar beside it.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav", "wma",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DiscKind {
    /// The ripper's FLAC archive of an audio CD.
    AudioArchive,
    /// A raw data CD image holding audio files.
    Data,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub number: u32,
    pub title: String,
    pub file: String,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Disc {
    pub iso_name: String,
    pub kind: DiscKind,
    pub category: String,
    pub author: String,
    pub title: String,
    pub year: Option<i32>,
    pub release_id: String,
    pub disc_number: Option<u32>,
    pub disc_total: Option<u32>,
    /// MusicBrainz Disc ID outcome: matched, cdstub, no_match, ambiguous, error.
    pub lookup_status: String,
    /// The person at the drive typed the author and title.
    pub hint_applied: bool,
    pub publisher: String,
    pub tracks: Vec<Track>,
    pub cover: String,
    pub audio_files: Vec<String>,
    /// The ISO checksum the ripper recorded, when it sent one.
    pub recorded_sha256: String,
}

impl Disc {
    pub fn exact_match(&self) -> bool {
        self.lookup_status == "matched" && !self.release_id.is_empty()
    }
}

fn text(value: &Value, key: &str) -> String {
    match value.get(key) {
        Some(Value::String(text)) => text.split_whitespace().collect::<Vec<_>>().join(" "),
        Some(Value::Number(number)) => number.to_string(),
        _ => String::new(),
    }
}

fn number(value: &Value, key: &str) -> Option<u32> {
    match value.get(key) {
        Some(Value::Number(number)) => number.as_u64().and_then(|n| u32::try_from(n).ok()),
        Some(Value::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
    .filter(|number| *number > 0)
}

fn year(value: &Value, key: &str) -> Option<i32> {
    number(value, key)
        .and_then(|year| i32::try_from(year).ok())
        .filter(|year| (1000..=2999).contains(year))
}

fn read_json(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str::<Value>(&text)
        .ok()
        .filter(Value::is_object)
}

/// `X.iso` → `X<suffix>`.
pub fn sibling(iso: &Path, suffix: &str) -> PathBuf {
    let stem = iso
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    iso.with_file_name(format!("{stem}{suffix}"))
}

/// Every file that travels with an ISO, including the ISO.
pub fn companions(iso: &Path) -> Vec<PathBuf> {
    let mut files = vec![iso.to_path_buf()];
    let name = iso
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    for candidate in [
        iso.with_file_name(format!("{name}.sha256")),
        sibling(iso, ".audio.json"),
        sibling(iso, ".disc.json"),
    ] {
        if candidate.is_file() {
            files.push(candidate);
        }
    }
    files
}

/// The checksum in a `sha256sum`-style manifest beside the ISO.
pub fn manifest_sha256(iso: &Path) -> Option<String> {
    let name = iso.file_name()?.to_str()?;
    let text = fs::read_to_string(iso.with_file_name(format!("{name}.sha256"))).ok()?;
    let digest = text.split_whitespace().next()?.to_ascii_lowercase();
    (digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())).then_some(digest)
}

fn read_member(sevenzip: &Path, iso: &Path, member: &str) -> Option<Vec<u8>> {
    let output = Command::new(sevenzip)
        .args(["e", "-so", "-bd", "--"])
        .arg(iso)
        .arg(member)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    (output.status.success() && !output.stdout.is_empty()).then_some(output.stdout)
}

/// Regular files in the image, as 7-Zip names them.
pub fn list_files(sevenzip: &Path, iso: &Path) -> Result<Vec<String>> {
    let output = Command::new(sevenzip)
        .args(["l", "-slt", "-bd", "--"])
        .arg(iso)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", sevenzip.display()))?;
    if !output.status.success() {
        bail!(
            "7-Zip cannot read {}: {}",
            iso.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let listing = String::from_utf8_lossy(&output.stdout);
    let mut files = Vec::new();
    let mut in_entries = false;
    let mut path = String::new();
    let mut folder = false;
    let mut flush = |path: &mut String, folder: &mut bool| {
        if !path.is_empty() && !*folder {
            files.push(std::mem::take(path));
        }
        path.clear();
        *folder = false;
    };
    for line in listing.lines() {
        if line.starts_with("----------") {
            in_entries = true;
            continue;
        }
        if !in_entries {
            continue;
        }
        if let Some(value) = line.strip_prefix("Path = ") {
            flush(&mut path, &mut folder);
            path = value
                .replace('\\', "/")
                .trim_start_matches("./")
                .to_string();
        } else if let Some(value) = line.strip_prefix("Folder = ") {
            folder = value.trim() == "+";
        } else if line.trim().is_empty() {
            flush(&mut path, &mut folder);
        }
    }
    flush(&mut path, &mut folder);
    Ok(files)
}

pub fn is_audio_file(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            AUDIO_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
        })
}

/// Describe an ISO from its own contents and the sidecar beside it.
pub fn load(iso: &Path, sevenzip: &Path) -> Result<Disc> {
    let iso_name = iso
        .file_name()
        .and_then(|name| name.to_str())
        .context("ISO name is not valid UTF-8")?
        .to_string();
    let sidecar = read_json(&sibling(iso, ".audio.json"))
        .or_else(|| read_json(&sibling(iso, ".disc.json")))
        .unwrap_or(Value::Null);
    let hint_applied = sidecar
        .get("person_hint")
        .and_then(|hint| hint.get("applied"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let recorded_sha256 = manifest_sha256(iso).unwrap_or_else(|| text(&sidecar, "iso_sha256"));

    let archive = read_member(sevenzip, iso, "metadata.json")
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter(|value| {
            value.get("tracks").is_some_and(Value::is_array)
                && text(value, "tool").starts_with("rip_to_iso")
        });

    if let Some(archive) = archive {
        let lookup = archive.get("lookup").cloned().unwrap_or(Value::Null);
        let tracks = archive["tracks"]
            .as_array()
            .map(|tracks| {
                tracks
                    .iter()
                    .filter_map(|track| {
                        let file = text(track, "file");
                        let number = number(track, "number")?;
                        (!file.is_empty() && !file.contains('/')).then(|| Track {
                            number,
                            title: text(track, "title"),
                            file,
                            sha256: text(track, "sha256").to_ascii_lowercase(),
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if tracks.is_empty() {
            bail!("{iso_name} lists no audio tracks in its metadata.json");
        }
        let mut lookup_status = text(&lookup, "lookup_status");
        if lookup_status.is_empty() {
            lookup_status = sidecar
                .get("audio_lookup")
                .map(|lookup| text(lookup, "lookup_status"))
                .unwrap_or_default();
        }
        return Ok(Disc {
            iso_name,
            kind: DiscKind::AudioArchive,
            category: text(&archive, "category"),
            author: text(&archive, "author"),
            title: text(&archive, "title"),
            year: year(&archive, "year"),
            release_id: text(&archive, "release_id"),
            disc_number: number(&archive, "media_position")
                .or_else(|| number(&sidecar, "disc_number")),
            disc_total: number(&archive, "media_total").or_else(|| number(&sidecar, "disc_total")),
            lookup_status,
            hint_applied,
            publisher: text(&lookup, "label"),
            tracks,
            cover: text(&archive, "cover_art"),
            audio_files: Vec::new(),
            recorded_sha256,
        });
    }

    let mut audio_files: Vec<String> = list_files(sevenzip, iso)?
        .into_iter()
        .filter(|path| is_audio_file(path))
        .collect();
    audio_files.sort_by_key(|path| crate::fsops::natural_key(path));
    let category = match text(&sidecar, "category") {
        category if category.is_empty() && audio_files.is_empty() => "data".to_string(),
        category if category.is_empty() => "unidentified".to_string(),
        category => category,
    };
    Ok(Disc {
        iso_name,
        kind: DiscKind::Data,
        category,
        author: text(&sidecar, "author"),
        title: text(&sidecar, "title"),
        year: year(&sidecar, "year"),
        release_id: String::new(),
        disc_number: number(&sidecar, "disc_number"),
        disc_total: number(&sidecar, "disc_total"),
        lookup_status: String::new(),
        hint_applied,
        publisher: String::new(),
        tracks: Vec::new(),
        cover: String::new(),
        audio_files,
        recorded_sha256,
    })
}
