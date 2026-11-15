//! Extract distinct still frames from a DVD image's menu VOBs.
//!
//! Menus (VIDEO_TS.VOB and VTS_nn_0.VOB) are small next to the titles, and
//! box sets commonly print "Series One - Episode Five 'Title'" on them. Only
//! the menu files are read from the ISO; HandBrake never decodes menus.

use anyhow::{bail, Context, Result};
use std::{
    fs,
    io::Cursor,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const MAX_MENU_FILE: u64 = 300 * 1024 * 1024;
const MAX_MENU_TOTAL: u64 = 600 * 1024 * 1024;
const SAMPLES_PER_FILE: u32 = 600;

pub struct Tools<'a> {
    pub sevenzip: &'a Path,
    pub ffmpeg: &'a Path,
}

fn is_menu_vob(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    let Some(file) = upper.strip_prefix("VIDEO_TS/") else {
        return false;
    };
    if file == "VIDEO_TS.VOB" {
        return true;
    }
    // VTS_nn_0.VOB holds that title set's menus; VTS_nn_1.. are the titles.
    file.len() == 12
        && file.starts_with("VTS_")
        && file[4..6].bytes().all(|b| b.is_ascii_digit())
        && &file[6..] == "_0.VOB"
}

/// List (path, size) of menu VOBs inside the image.
fn list_menu_files(tools: &Tools, iso: &Path) -> Result<Vec<(String, u64)>> {
    let output = Command::new(tools.sevenzip)
        .args(["l", "-slt", "-ba"])
        .arg(iso)
        .stdin(Stdio::null())
        .output()
        .context("run 7-Zip to list the image")?;
    if !output.status.success() {
        bail!("7-Zip could not list {}", iso.display());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut files = Vec::new();
    let mut path: Option<String> = None;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("Path = ") {
            path = Some(value.replace('\\', "/"));
        } else if let Some(value) = line.strip_prefix("Size = ")
            && let (Some(name), Ok(size)) = (path.take(), value.trim().parse::<u64>())
            && is_menu_vob(&name)
            && size > 0
            && size <= MAX_MENU_FILE
        {
            files.push((name, size));
        }
    }
    files.sort();
    let mut total = 0;
    files.retain(|(_, size)| {
        total += size;
        total <= MAX_MENU_TOTAL
    });
    Ok(files)
}

fn run_quiet(command: &mut Command, what: &str) -> Result<()> {
    let status = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .with_context(|| format!("start {what}"))?;
    if !status.success() {
        bail!("{what} failed with {status}");
    }
    Ok(())
}

const PRINT_W: u32 = 96;
const PRINT_H: u32 = 72;

/// Small greyscale thumbnail and grey-level spread of a frame. Menu pages
/// often share one background and differ only in their text, so frames are
/// compared pixel by pixel rather than by a coarse perceptual hash.
fn fingerprint(jpeg: &[u8]) -> Option<(Vec<u8>, f64)> {
    let image = image::ImageReader::new(Cursor::new(jpeg))
        .with_guessed_format()
        .ok()?
        .decode()
        .ok()?;
    let small = image
        .resize_exact(PRINT_W, PRINT_H, image::imageops::FilterType::Triangle)
        .to_luma8()
        .into_raw();
    let mean = small.iter().map(|v| f64::from(*v)).sum::<f64>() / small.len() as f64;
    let spread = (small
        .iter()
        .map(|v| (f64::from(*v) - mean).powi(2))
        .sum::<f64>()
        / small.len() as f64)
        .sqrt();
    Some((small, spread))
}

/// Mean absolute grey-level difference (0..=255).
fn difference(left: &[u8], right: &[u8]) -> f64 {
    let total: u64 = left
        .iter()
        .zip(right)
        .map(|(l, r)| u64::from(l.abs_diff(*r)))
        .sum();
    total as f64 / left.len().max(1) as f64
}

/// Return up to `limit` distinct, non-blank JPEG frames from the menus.
pub fn menu_frames(tools: &Tools, iso: &Path, work: &Path, limit: usize) -> Result<Vec<Vec<u8>>> {
    let files = list_menu_files(tools, iso)?;
    if files.is_empty() {
        return Ok(Vec::new());
    }
    let extract_dir = work.join("vob");
    let frame_dir = work.join("frames");
    fs::create_dir_all(&extract_dir)?;
    fs::create_dir_all(&frame_dir)?;
    let mut extract = Command::new(tools.sevenzip);
    extract
        .args(["e", "-y", "-bso0", "-bsp0"])
        .arg(format!("-o{}", extract_dir.display()))
        .arg(iso);
    for (name, _) in &files {
        extract.arg(name);
    }
    run_quiet(&mut extract, "7-Zip menu extraction")?;

    // Per menu file, frames in decoding order.
    let mut sequences: Vec<Vec<PathBuf>> = Vec::new();
    for (index, (name, _)) in files.iter().enumerate() {
        let file = extract_dir.join(name.rsplit('/').next().unwrap_or(name));
        if !file.is_file() {
            continue;
        }
        // Menu cells restart their timestamps, so sample by frame number
        // (about one frame per second) instead of by time or scene change:
        // pages that share a background differ only in their text, which
        // scene detection does not notice.
        let pattern = frame_dir.join(format!("{index:02}_%04d.jpg"));
        let _ = run_quiet(
            Command::new(tools.ffmpeg)
                .args(["-v", "error", "-y", "-i"])
                .arg(&file)
                .args([
                    "-vf",
                    "select='not(mod(n\\,25))',scale=720:-2",
                    "-fps_mode",
                    "passthrough",
                    "-frames:v",
                    &SAMPLES_PER_FILE.to_string(),
                    "-q:v",
                    "3",
                ])
                .arg(&pattern),
            "ffmpeg menu sampling",
        );
        let _ = fs::remove_file(&file);
        let mut produced: Vec<PathBuf> = fs::read_dir(&frame_dir)?
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| {
                path.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with(&format!("{index:02}_")))
            })
            .collect();
        produced.sort();
        sequences.push(produced);
    }

    // Text pages hold still; animated backgrounds and transitions do not.
    // Prefer frames that match the previous sample, then fall back to any
    // distinct frame for menus that never hold still.
    let mut stable: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
    let mut moving: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
    for sequence in sequences {
        let single = sequence.len() == 1;
        let mut previous: Option<Vec<u8>> = None;
        for path in sequence {
            let Ok(bytes) = fs::read(&path) else { continue };
            let Some((print, spread)) = fingerprint(&bytes) else {
                continue;
            };
            let still = single
                || previous
                    .as_ref()
                    .is_some_and(|prior| difference(prior, &print) < 1.5);
            previous = Some(print.clone());
            // Black, white and flat transition frames carry no text.
            if spread < 10.0 {
                continue;
            }
            let target = if still { &mut stable } else { &mut moving };
            // A changed episode title moves the mean by several levels;
            // encoder noise and highlight flicker stay well under this.
            if target
                .iter()
                .any(|(known, _)| difference(known, &print) < 2.0)
            {
                continue;
            }
            target.push((print, bytes));
        }
    }
    let mut chosen: Vec<Vec<u8>> = stable.into_iter().map(|(_, bytes)| bytes).collect();
    if chosen.is_empty() {
        chosen = moving.into_iter().map(|(_, bytes)| bytes).collect();
    }
    chosen.truncate(limit);
    Ok(chosen)
}

#[cfg(test)]
mod tests {
    use super::is_menu_vob;

    #[test]
    fn only_menu_vobs_are_selected() {
        assert!(is_menu_vob("VIDEO_TS/VIDEO_TS.VOB"));
        assert!(is_menu_vob("VIDEO_TS/VTS_01_0.VOB"));
        assert!(is_menu_vob("video_ts/vts_12_0.vob"));
        assert!(!is_menu_vob("VIDEO_TS/VTS_01_1.VOB"));
        assert!(!is_menu_vob("VIDEO_TS/VTS_01_0.IFO"));
        assert!(!is_menu_vob("AUDIO_TS/VTS_01_0.VOB"));
    }
}
