//! What an encoded episode actually says: a short local transcript, and the
//! published subtitle text of candidate episodes for comparison.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

pub struct Asr<'a> {
    pub ffmpeg: &'a Path,
    pub parakeet: &'a Path,
    pub model: &'a Path,
    pub threads: u32,
}

/// Transcribe `seconds` of the first audio track starting at `start`.
/// Parakeet runs on the CPU so it never competes with Bonsai for the GPU.
pub fn transcribe_excerpt(
    asr: &Asr,
    video: &Path,
    work: &Path,
    start: u32,
    seconds: u32,
) -> Result<String> {
    let wav = work.join("excerpt.wav");
    let status = Command::new(asr.ffmpeg)
        .args([
            "-v",
            "error",
            "-y",
            "-ss",
            &start.to_string(),
            "-t",
            &seconds.to_string(),
            "-i",
        ])
        .arg(video)
        .args([
            "-map",
            "0:a:0",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
        ])
        .arg(&wav)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("start ffmpeg audio extraction")?;
    if !status.success() {
        bail!("ffmpeg could not extract audio from {}", video.display());
    }
    let output = Command::new(asr.parakeet)
        .arg("-m")
        .arg(asr.model)
        .args(["-t", &asr.threads.to_string(), "-ng", "-f"])
        .arg(&wav)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .context("start Parakeet")?;
    let _ = std::fs::remove_file(&wav);
    if !output.status.success() {
        bail!("Parakeet failed with {}", output.status);
    }
    let text = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if text.split(' ').count() < 30 {
        bail!("the excerpt contains too little speech to compare");
    }
    Ok(text)
}

#[derive(Debug)]
pub enum SubtitleText {
    Text(String),
    NoAccount,
    NotFound,
    Quota,
    Unavailable(String),
}

/// Ask the provider broker's system socket for an episode's subtitle text,
/// using the OpenSubtitles account of `owner` (the person who uploaded the
/// disc). The broker never returns credentials.
pub fn episode_subtitle_text(
    socket: &Path,
    owner: &str,
    imdb_id: &str,
    season: u32,
    episode: u32,
) -> SubtitleText {
    let body = json!({
        "owner": owner,
        "parentImdbId": imdb_id,
        "season": season,
        "episode": episode,
        "language": "en",
    })
    .to_string();
    match post_unix(socket, "/system/v1/opensubtitles/episode-text", &body) {
        Ok((200, value)) => match value["text"].as_str() {
            Some(text) if !text.trim().is_empty() => SubtitleText::Text(text.to_string()),
            _ => SubtitleText::NotFound,
        },
        Ok((404, value)) if value["error"] == "no_account" => SubtitleText::NoAccount,
        Ok((404, _)) => SubtitleText::NotFound,
        Ok((429, _)) => SubtitleText::Quota,
        Ok((status, value)) => SubtitleText::Unavailable(format!(
            "broker answered {status} {}",
            value["error"].as_str().unwrap_or("")
        )),
        Err(error) => SubtitleText::Unavailable(error.to_string()),
    }
}

/// Minimal HTTP/1.1 POST over a Unix socket (reqwest has no Unix transport).
pub fn post_unix(socket: &Path, path: &str, body: &str) -> Result<(u16, Value)> {
    let mut stream =
        UnixStream::connect(socket).with_context(|| format!("connect to {}", socket.display()))?;
    stream.set_read_timeout(Some(Duration::from_secs(120)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    write!(
        stream,
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\
Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    let mut raw = Vec::new();
    stream
        .take(4 * 1024 * 1024)
        .read_to_end(&mut raw)
        .context("read broker response")?;
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .context("malformed broker response")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let mut payload = raw[split + 4..].to_vec();
    let status: u16 = head
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse().ok())
        .context("broker response has no status")?;
    if head.lines().any(|line| {
        line.to_ascii_lowercase()
            .starts_with("transfer-encoding: chunked")
    }) {
        payload = dechunk(&payload).context("malformed chunked broker response")?;
    }
    let value = serde_json::from_slice(&payload).unwrap_or(Value::Null);
    Ok((status, value))
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let line_end = data.windows(2).position(|w| w == b"\r\n")?;
        let size_text = std::str::from_utf8(&data[..line_end]).ok()?;
        let size = usize::from_str_radix(size_text.split(';').next()?.trim(), 16).ok()?;
        data = &data[line_end + 2..];
        if size == 0 {
            return Some(out);
        }
        out.extend_from_slice(data.get(..size)?);
        data = data.get(size + 2..)?;
    }
}

#[cfg(test)]
mod tests {
    use super::dechunk;

    #[test]
    fn chunked_bodies_are_reassembled() {
        let body = b"4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n";
        assert_eq!(dechunk(body).unwrap(), b"{\"a\":1}");
    }
}
