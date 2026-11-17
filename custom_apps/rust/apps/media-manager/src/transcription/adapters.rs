use super::{Backend, Request, Turn, Word};
use serde_json::Value;
use std::{
    fs::File,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
};

/// The engine's own position in the audio it is decoding, as a percentage.
pub type Progress<'a> = &'a mut dyn FnMut(u8);
pub type TranscriptionProgress<'a> = &'a mut dyn FnMut(&'static str, u8);

pub struct Runtime {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    pub parakeet: PathBuf,
    pub whisper: PathBuf,
    pub diarization: PathBuf,
    pub models: PathBuf,
    pub timeout: u64,
    pub cleaner: Option<super::cleanup::Cleaner>,
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
            cleaner: super::cleanup::Cleaner::from_env()?,
        })
    }
    pub async fn extract(
        &self,
        source: File,
        directory: &Path,
        progress: Progress<'_>,
    ) -> Result<(PathBuf, u64), String> {
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
        let (stdout, _) = run(&mut probe, 60, None)
            .await
            .map_err(|_| "audio_probe_failed")?;
        let data: Value = serde_json::from_slice(&stdout).map_err(|_| "audio_probe_invalid")?;
        if !data["streams"]
            .as_array()
            .is_some_and(|s| s.iter().any(|v| v["codec_type"] == "audio"))
        {
            return Err("no_audio_stream".into());
        }
        // The source container's declared duration is the only scale ffmpeg's
        // extraction progress can be measured against. Without it the worker
        // reports the stage but no percentage.
        let source_ms = data["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v > 0.0)
            .map(|v| (v * 1000.0) as u64);
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
                "-progress",
                "pipe:2",
                "-nostats",
                "-y",
            ])
            .arg(&wav)
            .stdin(Stdio::from(source));
        let mut report = |line: &str| {
            if let Some(duration) = source_ms
                && let Some(percent) = ffmpeg_progress(line, duration)
            {
                progress(percent);
            }
        };
        run(&mut command, self.timeout, Some(&mut report))
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
        let (stdout, _) = run(&mut probe, 60, None).await?;
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
        duration_ms: u64,
        directory: &Path,
        progress: TranscriptionProgress<'_>,
    ) -> Result<Transcript, String> {
        if backend == Backend::Parakeet {
            return self
                .transcribe_parakeet(wav, duration_ms, directory, progress)
                .await;
        }
        let mut command = Command::new(&self.whisper);
        command
            .arg("-m")
            .arg(self.models.join("whisper.bin"))
            .args(["-t", "4", "-f"])
            .arg(wav)
            // whisper.cpp prints its decoded position as a percentage.
            .arg("-pp");
        let mut report = |line: &str| {
            if let Some(percent) = engine_progress(line) {
                progress("decoding", percent);
            }
        };
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
        run(&mut command, self.timeout, Some(&mut report)).await?;
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
    /// Parakeet encodes each input file in one pass, so its graphics memory
    /// grows with the file's length. Measured on the Arc Pro B60 beside the
    /// resident chat and search models (2.9 GiB free): one minute peaked at
    /// 1.12 GiB, two at 1.51, four at 2.66, and longer files ran out of card
    /// memory, displaced the search models into host RAM and, at 90 minutes,
    /// were killed at the unit's 32 GiB limit. Longer audio is therefore cut
    /// at pauses into chunks of about 90 seconds (1.42 GiB peak) and every
    /// chunk is passed to one parakeet-cli run, so the model loads once. On a
    /// 90-minute stand-up recording that matched three-minute chunks for
    /// accuracy and was clearly better than 30-second chunks.
    async fn transcribe_parakeet(
        &self,
        wav: &Path,
        duration_ms: u64,
        directory: &Path,
        progress: TranscriptionProgress<'_>,
    ) -> Result<Transcript, String> {
        let chunks = self
            .chunk(wav, duration_ms as f64 / 1000.0, directory)
            .await?;
        let total = chunks.len();
        let mut command = Command::new(&self.parakeet);
        command
            .arg("-m")
            .arg(self.models.join("parakeet.bin"))
            .args(["-t", "4", "-ps", "-pp"])
            .args(chunks.iter().map(|(path, _)| path));
        let mut started = 0usize;
        let mut report = |line: &str| {
            if line.starts_with(FILE_MARKER) {
                started += 1;
                return;
            }
            let Some(percent) = engine_progress(line) else {
                return;
            };
            let encoder = line.starts_with("parakeet_encoder_print_progress_callback:");
            if total == 1 {
                progress(if encoder { "encoding" } else { "decoding" }, percent);
            } else if !encoder {
                // Chunks decode in turn; report the share of the whole.
                let done = started.saturating_sub(1) * 100 + percent as usize;
                progress("decoding", (done / total).min(100) as u8);
            }
        };
        let (_, stderr) = run(&mut command, self.timeout, Some(&mut report)).await?;
        let text = String::from_utf8_lossy(&stderr);
        let sections = file_sections(&text);
        if sections.len() != total {
            return Err("parakeet_output_invalid".into());
        }
        let mut words = Vec::new();
        for ((_, offset_ms), section) in chunks.iter().zip(sections) {
            // A chunk of applause or music legitimately has no words.
            for mut word in parakeet_words(section)? {
                word.start_ms += offset_ms;
                word.end_ms += offset_ms;
                words.push(word);
            }
        }
        // A changed CLI layout must fail visibly, never look like silence.
        if words.is_empty() {
            return Err("parakeet_output_unparseable".into());
        }
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
    /// The audio as one file, or as chunks cut at pauses, with each chunk's
    /// start in milliseconds.
    async fn chunk(
        &self,
        wav: &Path,
        total_s: f64,
        directory: &Path,
    ) -> Result<Vec<(PathBuf, u64)>, String> {
        if total_s <= CHUNK_MAX_S {
            return Ok(vec![(wav.to_path_buf(), 0)]);
        }
        let mut silence_sets = Vec::new();
        for threshold in SILENCE_THRESHOLDS {
            let mut command = Command::new(&self.ffmpeg);
            command
                .args(["-nostdin", "-hide_banner", "-i"])
                .arg(wav)
                .args([
                    "-af",
                    &format!("silencedetect=noise={threshold}:d=0.25"),
                    "-f",
                    "null",
                    "-",
                ]);
            let (_, stderr) = run(&mut command, 3600, None)
                .await
                .map_err(|_| "audio_silence_scan_failed")?;
            silence_sets.push(parse_silences(&String::from_utf8_lossy(&stderr)));
        }
        let cuts = plan_cuts(total_s, &silence_sets);
        let chunk_dir = directory.join("chunks");
        std::fs::create_dir_all(&chunk_dir).map_err(|e| e.to_string())?;
        let list = chunk_dir.join("chunks.csv");
        let times = cuts
            .iter()
            .map(|t| format!("{t:.3}"))
            .collect::<Vec<_>>()
            .join(",");
        let mut command = Command::new(&self.ffmpeg);
        command
            .args(["-nostdin", "-v", "error", "-i"])
            .arg(wav)
            .args(["-f", "segment", "-segment_times", &times, "-segment_list"])
            .arg(&list)
            .args([
                "-segment_list_type",
                "csv",
                "-reset_timestamps",
                "1",
                "-c",
                "copy",
            ])
            .arg(chunk_dir.join("chunk%04d.wav"));
        run(&mut command, 3600, None)
            .await
            .map_err(|_| "audio_chunking_failed")?;
        let listing = std::fs::read_to_string(&list).map_err(|_| "audio_chunking_failed")?;
        let mut chunks = Vec::new();
        for line in listing.lines().filter(|l| !l.trim().is_empty()) {
            let mut fields = line.split(',');
            let (Some(name), Some(start)) = (fields.next(), fields.next()) else {
                return Err("audio_chunking_failed".into());
            };
            let start: f64 = start.parse().map_err(|_| "audio_chunking_failed")?;
            if name.contains('/') || !start.is_finite() || start < 0.0 {
                return Err("audio_chunking_failed".into());
            }
            chunks.push((chunk_dir.join(name), (start * 1000.0).round() as u64));
        }
        if chunks.len() != cuts.len() + 1 {
            return Err("audio_chunking_failed".into());
        }
        Ok(chunks)
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
        let (stdout, _) = run(&mut command, self.timeout, None).await?;
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

async fn run(
    command: &mut Command,
    seconds: u64,
    on_stderr_line: Option<&mut dyn FnMut(&str)>,
) -> Result<(Vec<u8>, Vec<u8>), String> {
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
            tokio::try_join!(
                read_limited(&mut stdout, &mut out),
                read_stderr(&mut stderr, &mut err, on_stderr_line)
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

async fn read_limited<R: AsyncRead + Unpin>(
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

/// Read stderr to the end for the caller's parser while handing each complete
/// line to `on_line` as it arrives, so progress is reported during the run
/// rather than only after the child exits.
async fn read_stderr<R: AsyncRead + Unpin>(
    reader: &mut R,
    bytes: &mut Vec<u8>,
    mut on_line: Option<&mut dyn FnMut(&str)>,
) -> Result<(), &'static str> {
    let mut chunk = [0u8; 8192];
    let mut pending: Vec<u8> = Vec::new();
    loop {
        let read = reader
            .read(&mut chunk)
            .await
            .map_err(|_| "backend_read_failed")?;
        if read == 0 {
            break;
        }
        if bytes.len() + read > 32 * 1024 * 1024 {
            return Err("backend_output_limit");
        }
        bytes.extend_from_slice(&chunk[..read]);
        let Some(handler) = on_line.as_deref_mut() else {
            continue;
        };
        pending.extend_from_slice(&chunk[..read]);
        while let Some(end) = pending.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end_matches(['\r', '\n']);
            if !line.is_empty() {
                handler(line);
            }
        }
        // A child that never ends a line must not grow this buffer without
        // bound; the complete stderr is still kept above for the final parse.
        if pending.len() > 64 * 1024 {
            pending.clear();
        }
    }
    if let Some(handler) = on_line
        && !pending.is_empty()
    {
        let line = String::from_utf8_lossy(&pending);
        let line = line.trim_end_matches(['\r', '\n']);
        if !line.is_empty() {
            handler(line);
        }
    }
    Ok(())
}

/// whisper.cpp and the patched parakeet-cli print `... print_progress_callback:
/// progress =  45%` while decoding, which is the position the engine reached.
fn engine_progress(line: &str) -> Option<u8> {
    let (_, rest) = line.split_once("print_progress_callback: progress =")?;
    let digits: String = rest
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse::<u8>().ok().filter(|value| *value <= 100)
}

/// ffmpeg's `-progress` stream reports how much output it has written. Its
/// `out_time_ms` key carries microseconds, the same as `out_time_us`.
fn ffmpeg_progress(line: &str, duration_ms: u64) -> Option<u8> {
    let value = line
        .strip_prefix("out_time_us=")
        .or_else(|| line.strip_prefix("out_time_ms="))?;
    let micros = value.trim().parse::<u64>().ok()?;
    if duration_ms == 0 {
        return None;
    }
    Some(
        (micros / 1000)
            .saturating_mul(100)
            .checked_div(duration_ms)
            .unwrap_or(0)
            .min(100) as u8,
    )
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

/// The words of one parakeet-cli file section; empty for a silent chunk.
fn parakeet_words(text: &str) -> Result<Vec<Word>, String> {
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
    Ok(words)
}

/// parakeet-cli announces each input file on stderr before its output.
const FILE_MARKER: &str = "read_audio_data: reading audio data from";
/// Chunk lengths for long Parakeet input: a pause between 0.75 and 1.15 times
/// the 90-second target, so no chunk exceeds the measured memory peak by much.
const CHUNK_TARGET_S: f64 = 90.0;
const CHUNK_MIN_S: f64 = CHUNK_TARGET_S * 0.75;
const CHUNK_MAX_S: f64 = CHUNK_TARGET_S * 1.15;
/// Quietest first: a true pause is preferred over a dip in audience noise.
const SILENCE_THRESHOLDS: [&str; 4] = ["-40dB", "-35dB", "-30dB", "-25dB"];

/// The stderr of each input file, in order.
fn file_sections(text: &str) -> Vec<&str> {
    let starts: Vec<usize> = text.match_indices(FILE_MARKER).map(|(i, _)| i).collect();
    starts
        .iter()
        .enumerate()
        .map(|(n, &start)| &text[start..starts.get(n + 1).copied().unwrap_or(text.len())])
        .collect()
}

/// `(start, end)` seconds of each pause ffmpeg's silencedetect reported.
fn parse_silences(text: &str) -> Vec<(f64, f64)> {
    let value = |line: &str, key: &str| -> Option<f64> {
        line.split_once(key)?
            .1
            .split_whitespace()
            .next()?
            .parse::<f64>()
            .ok()
            .filter(|v| v.is_finite())
    };
    let mut spans = Vec::new();
    let mut start = None;
    for line in text.lines() {
        if let Some(s) = value(line, "silence_start: ") {
            start = Some(s);
        } else if let (Some(s), Some(e)) = (start, value(line, "silence_end: ")) {
            spans.push((s.max(0.0), e));
            start = None;
        }
    }
    spans
}

/// Cut points for audio of `total_s` seconds. Each cut is the middle of the
/// longest pause between the minimum and maximum chunk length, taken from the
/// quietest threshold that has one; without any pause the cut falls at the
/// target length.
pub fn plan_cuts(total_s: f64, silence_sets: &[Vec<(f64, f64)>]) -> Vec<f64> {
    let mut cuts = Vec::new();
    let mut position = 0.0;
    while total_s - position > CHUNK_MAX_S {
        let (low, high) = (position + CHUNK_MIN_S, position + CHUNK_MAX_S);
        let want = position + CHUNK_TARGET_S;
        let cut = silence_sets
            .iter()
            .find_map(|spans| {
                spans
                    .iter()
                    .map(|&(s, e)| (e - s, (s + e) / 2.0))
                    .filter(|&(_, middle)| (low..=high).contains(&middle))
                    .max_by(|a, b| {
                        a.0.total_cmp(&b.0)
                            .then((b.1 - want).abs().total_cmp(&(a.1 - want).abs()))
                    })
                    .map(|(_, middle)| middle)
            })
            .unwrap_or(want);
        cuts.push(cut);
        position = cut;
    }
    cuts
}

#[cfg(test)]
mod chunk_tests {
    use super::{file_sections, parakeet_words, parse_silences, plan_cuts};

    #[test]
    fn cuts_at_the_longest_pause_near_ninety_seconds() {
        let quiet = vec![(80.0, 80.5), (95.0, 96.4), (170.0, 171.0)];
        // 95.7 is the longest pause in 67.5-103.5; 170.5 follows it in 163.2-199.2.
        assert_eq!(plan_cuts(260.0, &[quiet]), vec![95.7, 170.5]);
        // Without a pause the cut falls at the target; a short tail is kept.
        assert_eq!(plan_cuts(100.0, &[vec![]]), Vec::<f64>::new());
        assert_eq!(plan_cuts(180.0, &[vec![]]), vec![90.0]);
        assert_eq!(plan_cuts(200.0, &[vec![]]), vec![90.0, 180.0]);
        // A quieter threshold's pause wins over a longer, louder one.
        assert_eq!(
            plan_cuts(150.0, &[vec![(70.0, 70.3)], vec![(88.0, 92.0)]]),
            vec![70.15]
        );
    }

    #[test]
    fn reads_silencedetect_and_splits_output_per_file() {
        let log = "[silencedetect @ 0x1] silence_start: 12.5\n[silencedetect @ 0x1] silence_end: 13.25 | silence_duration: 0.75\n";
        assert_eq!(parse_silences(log), vec![(12.5, 13.25)]);
        let out = "Loading\nread_audio_data: reading audio data from 'a.wav' ...\n  [ 0] id= 1 p=0.9 t0= 10 t1= 20 word_start=true \"\u{2581}Hi\"\nread_audio_data: reading audio data from 'b.wav' ...\nSegments (0):\n";
        let sections = file_sections(out);
        assert_eq!(sections.len(), 2);
        assert_eq!(parakeet_words(sections[0]).unwrap()[0].text, "Hi");
        assert!(parakeet_words(sections[1]).unwrap().is_empty());
    }
}

#[cfg(test)]
mod progress_tests {
    use super::{engine_progress, ffmpeg_progress};

    #[test]
    fn reads_the_position_both_engines_report() {
        assert_eq!(
            engine_progress("whisper_print_progress_callback: progress =  45%"),
            Some(45)
        );
        assert_eq!(
            engine_progress("parakeet_print_progress_callback: progress =   0%"),
            Some(0)
        );
        assert_eq!(
            engine_progress("parakeet_print_progress_callback: progress = 100%"),
            Some(100)
        );
        assert_eq!(engine_progress("word_start= true t0= 100"), None);
        assert_eq!(
            engine_progress("whisper_print_progress_callback: progress = 140%"),
            None
        );
    }

    #[test]
    fn scales_ffmpeg_output_against_the_source_duration() {
        assert_eq!(ffmpeg_progress("out_time_us=5000000", 10000), Some(50));
        assert_eq!(ffmpeg_progress("out_time_ms=2500000", 10000), Some(25));
        assert_eq!(ffmpeg_progress("out_time_us=12000000", 10000), Some(100));
        assert_eq!(ffmpeg_progress("out_time_us=N/A", 10000), None);
        assert_eq!(ffmpeg_progress("out_time_us=1000", 0), None);
        assert_eq!(ffmpeg_progress("progress=continue", 10000), None);
    }
}
