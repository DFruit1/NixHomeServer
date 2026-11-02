use super::{Backend, Request, Turn, Word};
use serde_json::Value;
use std::{
    fs::File,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command};

pub struct Runtime {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    pub parakeet: PathBuf,
    pub whisper: PathBuf,
    pub diarization: PathBuf,
    pub models: PathBuf,
    pub timeout: u64,
}
pub struct Transcript {
    pub words: Vec<Word>,
    pub language: Option<String>,
    pub mean_token_confidence: Option<f64>,
}
impl Runtime {
    pub fn from_env() -> Result<Self, String> {
        let path = |key| {
            std::env::var_os(key)
                .map(PathBuf::from)
                .ok_or_else(|| format!("missing {key}"))
        };
        Ok(Self {
            ffmpeg: path("TRANSCRIBE_FFMPEG")?,
            ffprobe: path("TRANSCRIBE_FFPROBE")?,
            parakeet: path("TRANSCRIBE_PARAKEET")?,
            whisper: path("TRANSCRIBE_WHISPER")?,
            diarization: path("TRANSCRIBE_DIARIZATION")?,
            models: path("TRANSCRIBE_MODELS")?,
            timeout: std::env::var("TRANSCRIBE_TIMEOUT_SECONDS")
                .unwrap_or("21600".into())
                .parse()
                .map_err(|_| "invalid timeout")?,
        })
    }
    pub async fn extract(&self, source: File, directory: &Path) -> Result<(PathBuf, u64), String> {
        // The descriptor is opened beneath the owner root before spawning any
        // decoder. fd: permits seeking in MP4 containers. Allowing only the fd
        // protocol prevents playlists from opening other local files as root.
        let probe_source = source.try_clone().map_err(|e| e.to_string())?;
        let mut probe = Command::new(&self.ffprobe);
        probe
            .args([
                "-v",
                "error",
                "-protocol_whitelist",
                "fd",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                "-i",
                "fd:",
            ])
            .stdin(Stdio::from(probe_source));
        let (stdout, _) = run(&mut probe, 60)
            .await
            .map_err(|_| "audio_probe_failed")?;
        let data: Value = serde_json::from_slice(&stdout).map_err(|_| "audio_probe_invalid")?;
        if !data["streams"]
            .as_array()
            .is_some_and(|s| s.iter().any(|v| v["codec_type"] == "audio"))
        {
            return Err("no_audio_stream".into());
        }
        // dup() shares the seek offset. Rewind before the extraction child.
        use std::io::{Seek, SeekFrom};
        let mut source = source;
        source
            .seek(SeekFrom::Start(0))
            .map_err(|_| "source_seek_failed")?;
        let wav = directory.join("audio.wav");
        let mut command = Command::new(&self.ffmpeg);
        command
            .args([
                "-nostdin",
                "-v",
                "error",
                "-protocol_whitelist",
                "fd",
                "-i",
                "fd:",
                "-map",
                "0:a:0",
                "-vn",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-c:a",
                "pcm_s16le",
                "-f",
                "wav",
                "-y",
            ])
            .arg(&wav)
            .stdin(Stdio::from(source));
        run(&mut command, self.timeout)
            .await
            .map_err(|_| "audio_extraction_failed")?;
        // WAV includes a small header. Probe the completed private file for the
        // actual duration rather than trusting source container metadata.
        let mut probe = Command::new(&self.ffprobe);
        probe
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "json",
            ])
            .arg(&wav);
        let (stdout, _) = run(&mut probe, 60).await?;
        let data: Value = serde_json::from_slice(&stdout).map_err(|_| "audio_probe_invalid")?;
        let duration = data["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v > 0.0)
            .ok_or("audio_duration_invalid")?;
        Ok((wav, (duration * 1000.0) as u64))
    }
    pub async fn transcribe(
        &self,
        backend: Backend,
        request: &Request,
        wav: &Path,
        directory: &Path,
    ) -> Result<Transcript, String> {
        let mut command = Command::new(match backend {
            Backend::Parakeet => &self.parakeet,
            Backend::Whisper => &self.whisper,
        });
        command
            .arg("-m")
            .arg(self.models.join(match backend {
                Backend::Parakeet => "parakeet.bin",
                Backend::Whisper => "whisper.bin",
            }))
            .args(["-t", "4", "-f"])
            .arg(wav);
        match backend {
            Backend::Parakeet => {
                command.arg("-ps");
                let (_, stderr) = run(&mut command, self.timeout).await?;
                let text = String::from_utf8_lossy(&stderr);
                let words = parse_parakeet(&text)?;
                let probabilities: Vec<f64> = text
                    .lines()
                    .filter(|line| line.contains("word_start="))
                    .filter_map(|line| {
                        line.split_whitespace()
                            .find_map(|field| field.strip_prefix("p="))
                    })
                    .filter_map(|p| p.parse().ok())
                    .collect();
                Ok(Transcript {
                    words,
                    language: None,
                    mean_token_confidence: (!probabilities.is_empty())
                        .then(|| probabilities.iter().sum::<f64>() / probabilities.len() as f64),
                })
            }
            Backend::Whisper => {
                command
                    .args([
                        "-ojf",
                        "-sow",
                        "-ml",
                        "1",
                        "-l",
                        request.transcription.language.as_deref().unwrap_or("auto"),
                        "-of",
                    ])
                    .arg(directory.join("whisper"));
                let prompt = [
                    request.transcription.prompt.clone().unwrap_or_default(),
                    request.transcription.vocabulary.join(", "),
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
                if !prompt.is_empty() {
                    command.arg("--prompt").arg(prompt);
                }
                run(&mut command, self.timeout).await?;
                let json_file = tokio::fs::File::open(directory.join("whisper.json"))
                    .await
                    .map_err(|_| "whisper_output_missing")?;
                let mut bytes = Vec::new();
                json_file
                    .take(32 * 1024 * 1024 + 1)
                    .read_to_end(&mut bytes)
                    .await
                    .map_err(|_| "whisper_output_invalid")?;
                if bytes.len() > 32 * 1024 * 1024 {
                    return Err("whisper_output_too_large".into());
                }
                parse_whisper(&bytes)
            }
        }
    }
    pub async fn diarize(&self, wav: &Path) -> Result<Vec<Turn>, String> {
        let mut command = Command::new(&self.diarization);
        command
            .arg(format!(
                "--segmentation.pyannote-model={}",
                self.models.join("segmentation.onnx").display()
            ))
            .arg(format!(
                "--embedding.model={}",
                self.models.join("embedding.onnx").display()
            ))
            .args([
                "--segmentation.provider=cpu",
                "--embedding.provider=cpu",
                "--segmentation.num-threads=2",
                "--embedding.num-threads=2",
            ])
            .arg(wav);
        let (stdout, _) = run(&mut command, self.timeout).await?;
        let mut turns = Vec::new();
        for line in String::from_utf8_lossy(&stdout).lines() {
            let parts: Vec<_> = line.split_whitespace().collect();
            if parts.len() != 4 || parts[1] != "--" || !parts[3].starts_with("speaker_") {
                continue;
            }
            let start = parts[0]
                .parse::<f64>()
                .map_err(|_| "diarization_output_invalid")?;
            let end = parts[2]
                .parse::<f64>()
                .map_err(|_| "diarization_output_invalid")?;
            if !start.is_finite() || !end.is_finite() || start < 0.0 || end <= start {
                return Err("diarization_output_invalid".into());
            }
            turns.push(Turn {
                start_ms: (start * 1000.0) as u64,
                end_ms: (end * 1000.0) as u64,
                speaker: parts[3].to_string(),
            });
        }
        if turns.is_empty() {
            return Err("diarization_output_empty".into());
        }
        Ok(turns)
    }
}

async fn run(command: &mut Command, seconds: u64) -> Result<(Vec<u8>, Vec<u8>), String> {
    command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|_| "backend_spawn_failed")?;
    let mut stdout = child.stdout.take().ok_or("backend_stdout_missing")?;
    let mut stderr = child.stderr.take().ok_or("backend_stderr_missing")?;
    let result = tokio::time::timeout(Duration::from_secs(seconds), async {
        let read = async {
            let mut out = Vec::new();
            let mut err = Vec::new();
            async fn read_limited<R: tokio::io::AsyncRead + Unpin>(
                reader: &mut R,
                bytes: &mut Vec<u8>,
            ) -> Result<(), &'static str> {
                reader
                    .take(32 * 1024 * 1024 + 1)
                    .read_to_end(bytes)
                    .await
                    .map_err(|_| "backend_read_failed")?;
                if bytes.len() > 32 * 1024 * 1024 {
                    return Err("backend_output_limit");
                }
                Ok(())
            }
            tokio::try_join!(
                read_limited(&mut stdout, &mut out),
                read_limited(&mut stderr, &mut err)
            )?;
            if out.len() > 32 * 1024 * 1024 || err.len() > 32 * 1024 * 1024 {
                return Err("backend_output_limit");
            }
            Ok((out, err))
        };
        let (bytes, status) = tokio::try_join!(read, async {
            child.wait().await.map_err(|_| "backend_wait_failed")
        })?;
        if !status.success() {
            return Err("backend_failed");
        }
        Ok(bytes)
    })
    .await;
    match result {
        Ok(Ok(bytes)) => Ok(bytes),
        _ => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            Err("backend_failed_or_timed_out".into())
        }
    }
}

pub fn parse_parakeet(text: &str) -> Result<Vec<Word>, String> {
    let mut words: Vec<Word> = Vec::new();
    for line in text.lines().filter(|s| s.contains("word_start=")) {
        let fields: Vec<_> = line.split_whitespace().collect();
        let field = |name: &str| -> Result<&str, String> {
            let i = fields
                .iter()
                .position(|s| s.starts_with(name))
                .ok_or("parakeet_output_invalid")?;
            let value = fields[i].strip_prefix(name).unwrap_or_default();
            if value.is_empty() {
                fields
                    .get(i + 1)
                    .copied()
                    .ok_or_else(|| "parakeet_output_invalid".into())
            } else {
                Ok(value)
            }
        };
        let start = field("t0=")?
            .parse::<u64>()
            .map_err(|_| "parakeet_output_invalid")?
            .checked_mul(10)
            .ok_or("parakeet_output_invalid")?;
        let end = field("t1=")?
            .parse::<u64>()
            .map_err(|_| "parakeet_output_invalid")?
            .checked_mul(10)
            .ok_or("parakeet_output_invalid")?;
        let p = field("p=")?
            .parse::<f64>()
            .map_err(|_| "parakeet_output_invalid")?;
        if !p.is_finite() || !(0.0..=1.0).contains(&p) || end < start {
            return Err("parakeet_output_invalid".into());
        }
        let token = line
            .split_once('"')
            .and_then(|(_, v)| v.strip_suffix('"'))
            .ok_or("parakeet_output_invalid")?
            .replace('▁', " ");
        if field("word_start=")? == "false"
            && let Some(word) = words.last_mut()
        {
            word.text.push_str(&token);
            word.end_ms = end.max(word.end_ms);
        } else {
            words.push(Word {
                start_ms: start,
                end_ms: end.max(start + 1),
                text: token.trim().to_string(),
                confidence: Some(p),
            });
        }
    }
    // A changed CLI layout must fail visibly, never look like a silent clip.
    if words.is_empty() {
        return Err("parakeet_output_unparseable".into());
    }
    Ok(words)
}
pub fn parse_whisper(bytes: &[u8]) -> Result<Transcript, String> {
    let data: Value = serde_json::from_slice(bytes).map_err(|_| "whisper_output_invalid")?;
    let segments = data["transcription"]
        .as_array()
        .ok_or("whisper_output_invalid")?;
    let mut words = Vec::new();
    let mut all_confidences = Vec::new();
    for segment in segments {
        let start = segment["offsets"]["from"]
            .as_u64()
            .ok_or("whisper_output_invalid")?;
        let end = segment["offsets"]["to"]
            .as_u64()
            .ok_or("whisper_output_invalid")?;
        let text = segment["text"]
            .as_str()
            .ok_or("whisper_output_invalid")?
            .trim();
        if text.is_empty() {
            continue;
        }
        if end < start {
            return Err("whisper_output_invalid".into());
        }
        let confidences: Vec<f64> = segment["tokens"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|v| !v["text"].as_str().unwrap_or("").starts_with("[_"))
            .filter_map(|v| v["p"].as_f64())
            .filter(|p| p.is_finite() && (0.0..=1.0).contains(p))
            .collect();
        all_confidences.extend_from_slice(&confidences);
        words.push(Word {
            start_ms: start,
            end_ms: end.max(start + 1),
            text: text.to_string(),
            confidence: (!confidences.is_empty())
                .then(|| confidences.iter().sum::<f64>() / confidences.len() as f64),
        });
    }
    Ok(Transcript {
        words,
        language: data["result"]["language"].as_str().map(str::to_string),
        mean_token_confidence: (!all_confidences.is_empty())
            .then(|| all_confidences.iter().sum::<f64>() / all_confidences.len() as f64),
    })
}
