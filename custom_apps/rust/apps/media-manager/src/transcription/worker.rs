use super::{adapters::Runtime, build_cues, fs::Dir, media_stem, Backend, Request};
use crate::{
    broker::opened_file_fingerprint,
    config::Identity,
    subtitle_format::{render_srt, render_vtt},
};
use homelab_common::sha256_hex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::OpenOptions,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub fn valid_user(name: &str) -> bool {
    Identity::try_new(name, std::iter::empty::<&str>()).is_ok()
}
#[derive(Clone, Debug, Deserialize, Serialize)]
struct Observation {
    fingerprint: String,
    since: u64,
}
#[derive(Clone)]
struct Candidate {
    owner: Option<String>,
    backend: Backend,
    name: String,
    stem: String,
    id: String,
    request: Request,
    fingerprint: String,
    request_fingerprint: String,
    queued_at: u64,
}
pub struct Worker {
    pub state: PathBuf,
    pub users: PathBuf,
    pub settle: u64,
    pub orphan_timeout: u64,
    pub max_backend_wait: u64,
}
impl Worker {
    pub fn from_env() -> Result<Self, String> {
        let number = |key, default: &str| {
            std::env::var(key)
                .unwrap_or(default.into())
                .parse::<u64>()
                .map_err(|_| format!("invalid {key}"))
        };
        Ok(Self {
            state: std::env::var_os("TRANSCRIBE_STATE")
                .map(PathBuf::from)
                .ok_or("missing TRANSCRIBE_STATE")?,
            users: std::env::var_os("TRANSCRIBE_USERS_ROOT")
                .map(PathBuf::from)
                .ok_or("missing TRANSCRIBE_USERS_ROOT")?,
            settle: number("TRANSCRIBE_SETTLE_SECONDS", "60")?,
            orphan_timeout: number("TRANSCRIBE_ORPHAN_SECONDS", "3600")?,
            max_backend_wait: number("TRANSCRIBE_MAX_BACKEND_WAIT", "300")?,
        })
    }
    pub fn provision(&self) -> Result<(), String> {
        let users = Dir::open(&self.users)?;
        for name in users.names()?.into_iter().filter(|n| valid_user(n)) {
            let Ok(owner) = users.child(&name) else {
                continue;
            };
            let inbox = owner.create("_Transcribe")?;
            inbox.allow_media_read()?;
            for backend in ["parakeet", "whisper", "_Failed"] {
                inbox.create(backend)?.allow_media_read()?;
            }
            owner.create("_Transcripts")?.allow_media_read()?;
        }
        Ok(())
    }
    fn owner(&self, username: Option<&str>) -> Result<Dir, String> {
        match username {
            Some(name) if valid_user(name) => Dir::open(&self.users)?.child(name),
            Some(_) => Err("invalid owner".into()),
            None => Dir::open(&self.state),
        }
    }
    fn inbox(&self, username: Option<&str>) -> Result<Dir, String> {
        self.owner(username)?.child(if username.is_some() {
            "_Transcribe"
        } else {
            "incoming"
        })
    }
    fn records(&self, username: Option<&str>) -> Result<Dir, String> {
        let state = Dir::open(&self.state)?;
        match username {
            Some(name) => state.create("users")?.create(name),
            None => state.create("server"),
        }
    }
    fn record(&self, job: &Candidate, state: &str, extra: Value) -> Result<(), String> {
        let mut data = json!({"id": job.id, "name": job.name, "backend": job.backend, "state": state, "queuedAt": job.queued_at, "updatedAt": now(), "sourceFingerprint": job.fingerprint, "requestFingerprint": job.request_fingerprint});
        if let Some(values) = extra.as_object() {
            data.as_object_mut().unwrap().extend(values.clone());
        }
        self.records(job.owner.as_deref())?.write(
            &format!("{}.json", job.id),
            &serde_json::to_vec(&data).map_err(|e| e.to_string())?,
        )
    }
    fn observe(
        observations: &mut BTreeMap<String, Observation>,
        key: String,
        fingerprint: String,
        settle: u64,
    ) -> bool {
        let entry = observations.entry(key).or_insert_with(|| Observation {
            fingerprint: fingerprint.clone(),
            since: now(),
        });
        if entry.fingerprint != fingerprint {
            *entry = Observation {
                fingerprint,
                since: now(),
            };
        }
        now().saturating_sub(entry.since) >= settle
    }
    fn fail(&self, job: &Candidate, code: &str) -> Result<(), String> {
        self.record(job, "failed", json!({"error": code}))?;
        let inbox = self.inbox(job.owner.as_deref())?;
        inbox.child(job.backend.name())?.write(
            &format!("{}.transcribe.error.txt", job.stem),
            format!("{code}\n").as_bytes(),
        )?;
        inbox.create("_Failed")?.write(
            &format!("{}.json", job.id),
            &serde_json::to_vec(&json!({"backend": job.backend, "name": job.name, "error": code}))
                .map_err(|e| e.to_string())?,
        )
    }
    fn scan(
        &self,
        observations: &mut BTreeMap<String, Observation>,
    ) -> Result<Vec<Candidate>, String> {
        let users = Dir::open(&self.users)?;
        let mut owners = vec![None];
        owners.extend(
            users
                .names()?
                .into_iter()
                .filter(|n| valid_user(n) && users.child(n).is_ok())
                .map(Some),
        );
        let mut jobs = Vec::new();
        for owner in owners {
            let Ok(inbox) = self.inbox(owner.as_deref()) else {
                continue;
            };
            for backend in [Backend::Parakeet, Backend::Whisper] {
                let Ok(directory) = inbox.child(backend.name()) else {
                    continue;
                };
                let Ok(names) = directory.names() else {
                    eprintln!("transcription_inbox_scan_failed: entry limit or access error");
                    continue;
                };
                let mut stems: BTreeMap<String, Vec<String>> = BTreeMap::new();
                for name in &names {
                    if let Some(stem) = media_stem(name) {
                        stems.entry(stem.into()).or_default().push(name.clone());
                    }
                }
                // Request-only stems need their own observation and orphan error.
                for name in &names {
                    if let Some(stem) = name
                        .strip_suffix(".transcribe.request.json")
                        .filter(|s| super::valid_job_name(s))
                    {
                        stems.entry(stem.into()).or_default();
                    }
                }
                for (stem, sources) in stems {
                    let name = sources
                        .first()
                        .cloned()
                        .unwrap_or_else(|| format!("{stem}.transcribe.request.json"));
                    let Ok(file) = directory.file(&name) else {
                        continue;
                    };
                    let fingerprint = opened_file_fingerprint(&file).map_err(|e| e.to_string())?;
                    let id = sha256_hex(
                        format!(
                            "{}\0{}\0{stem}",
                            owner.as_deref().unwrap_or("server"),
                            backend.name()
                        )
                        .as_bytes(),
                    );
                    let observation_key = format!("{id}:source");
                    let source_settled = Self::observe(
                        observations,
                        observation_key.clone(),
                        fingerprint.clone(),
                        self.settle,
                    );
                    let queued_at = observations[&observation_key].since;
                    let request_name = format!("{stem}.transcribe.request.json");
                    let request_file = directory.file(&request_name);
                    let mut request = Request::default();
                    let mut request_fingerprint = String::new();
                    let mut intake_error = None;
                    if let Ok(request_file) = request_file {
                        request_fingerprint =
                            opened_file_fingerprint(&request_file).map_err(|e| e.to_string())?;
                        if !Self::observe(
                            observations,
                            format!("{id}:request"),
                            request_fingerprint.clone(),
                            self.settle,
                        ) {
                            continue;
                        }
                        match directory
                            .read(&request_name, 65536)
                            .and_then(|bytes| Request::parse(&bytes))
                        {
                            Ok(value) => request = value,
                            Err(_) => intake_error = Some("request_invalid"),
                        }
                    } else if names.contains(&request_name) {
                        intake_error = Some("request_invalid");
                    }
                    if !source_settled {
                        continue;
                    }
                    let job = Candidate {
                        owner: owner.clone(),
                        backend,
                        name,
                        stem,
                        id,
                        request,
                        fingerprint,
                        request_fingerprint,
                        queued_at,
                    };
                    let records = self.records(owner.as_deref())?;
                    if let Ok(bytes) = records.read(&format!("{}.json", job.id), 1024 * 1024)
                        && let Ok(previous) = serde_json::from_slice::<Value>(&bytes)
                        && previous["sourceFingerprint"] == job.fingerprint
                    {
                        if matches!(previous["state"].as_str(), Some("completed" | "failed"))
                            && (!job.request.force
                                || previous["requestFingerprint"] == job.request_fingerprint)
                        {
                            continue;
                        }
                        if matches!(
                            previous["state"].as_str(),
                            Some("extracting" | "transcribing" | "diarising" | "writing")
                        ) && previous["requestFingerprint"] == job.request_fingerprint
                        {
                            // A prior worker died while holding the single-instance
                            // lock. Do not repeatedly restart an OOM-inducing job.
                            self.fail(&job, "worker_interrupted")?;
                            continue;
                        }
                    }
                    if sources.len() > 1 {
                        self.fail(&job, "ambiguous_source")?;
                        continue;
                    }
                    if sources.is_empty() {
                        if now().saturating_sub(queued_at) >= self.orphan_timeout {
                            self.fail(&job, "orphaned_declaration")?;
                        }
                        continue;
                    }
                    if let Some(error) = intake_error {
                        self.fail(&job, error)?;
                        continue;
                    }
                    self.record(&job, "queued", json!({}))?;
                    jobs.push(job);
                }
            }
        }
        jobs.sort_by_key(|job| job.queued_at);
        Ok(jobs)
    }
    pub async fn run(&self) -> Result<(), String> {
        let state = Dir::open(&self.state)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.state.join("worker.lock"))
            .map_err(|e| e.to_string())?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Ok(());
        }
        let mut observations: BTreeMap<String, Observation> = match state
            .read("observations.json", 8 * 1024 * 1024)
        {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| "invalid observation state")?,
            Err(_) => BTreeMap::new(),
        };
        let runtime = Runtime::from_env()?;
        let mut affinity = None;
        // Re-scan between jobs so an older job in the other backend cannot
        // starve. CLIs release all ASR memory after each job, including failure.
        loop {
            let mut jobs = self.scan(&mut observations)?;
            state.write(
                "observations.json",
                &serde_json::to_vec(&observations).map_err(|e| e.to_string())?,
            )?;
            if jobs.is_empty() {
                break;
            }
            let index = jobs
                .iter()
                .position(|job| {
                    affinity.is_some()
                        && Some(job.backend) != affinity
                        && now().saturating_sub(job.queued_at) >= self.max_backend_wait
                })
                .or_else(|| jobs.iter().position(|job| Some(job.backend) == affinity))
                .unwrap_or(0);
            let job = jobs.remove(index);
            affinity = Some(job.backend);
            if let Err(code) = self.process(&runtime, &job).await {
                self.fail(&job, &code)?;
            }
        }
        Ok(())
    }
    async fn process(&self, runtime: &Runtime, job: &Candidate) -> Result<(), String> {
        let directory = self
            .inbox(job.owner.as_deref())?
            .child(job.backend.name())?;
        let file = directory.file(&job.name)?;
        if opened_file_fingerprint(&file).map_err(|e| e.to_string())? != job.fingerprint {
            return Err("source_changed".into());
        }
        let scratch_root = std::env::var_os("TRANSCRIBE_WORK_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| self.state.join("work"));
        // This directory is root-only and outside every user-browsable root.
        std::fs::create_dir_all(&scratch_root).map_err(|e| e.to_string())?;
        let scratch = tempfile::Builder::new()
            .prefix("job-")
            .tempdir_in(scratch_root)
            .map_err(|e| e.to_string())?;
        self.record(job, "extracting", json!({}))?;
        let (wav, duration) = runtime
            .extract(file.try_clone().map_err(|e| e.to_string())?, scratch.path())
            .await?;
        if opened_file_fingerprint(&file).map_err(|e| e.to_string())? != job.fingerprint {
            return Err("source_changed".into());
        }
        self.record(job, "transcribing", json!({"durationMs": duration}))?;
        let transcript = runtime
            .transcribe(job.backend, &job.request, &wav, scratch.path())
            .await?;
        let super::adapters::Transcript {
            words,
            language,
            mean_token_confidence,
        } = transcript;
        let mut turns = Vec::new();
        if job.request.output.diarize {
            self.record(job, "diarising", json!({"durationMs": duration}))?;
            turns = runtime.diarize(&wav).await?;
        }
        self.record(job, "writing", json!({"durationMs": duration}))?;
        let output_digest = sha256_hex(
            format!("{}:{}:{}", job.id, job.fingerprint, job.request_fingerprint).as_bytes(),
        );
        let output_name = format!(
            "{}-{}",
            job.stem.chars().take(80).collect::<String>(),
            &output_digest[..16]
        );
        let output = self
            .owner(job.owner.as_deref())?
            .create("_Transcripts")?
            .create(&output_name)?;
        let cues = build_cues(&words, &[]);
        let transcript = cues
            .iter()
            .map(|c| c.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        output.write("transcript.txt", transcript.as_bytes())?;
        let mut artifacts = vec!["transcript.txt"];
        if job.request.output.formats.iter().any(|f| f == "srt") {
            output.write("subtitles.srt", render_srt(&cues)?.as_bytes())?;
            artifacts.push("subtitles.srt");
        }
        if job.request.output.formats.iter().any(|f| f == "vtt") {
            output.write("subtitles.vtt", render_vtt(&cues)?.as_bytes())?;
            artifacts.push("subtitles.vtt");
        }
        if !turns.is_empty() {
            output.write(
                "diarized.srt",
                render_srt(&build_cues(&words, &turns))?.as_bytes(),
            )?;
            artifacts.push("diarized.srt");
        }
        let result = json!({"backend": job.backend, "language": job.request.output.language, "detectedLanguage": language, "speakerCount": turns.iter().map(|t| &t.speaker).collect::<BTreeSet<_>>().len(), "durationMs": duration, "meanTokenConfidence": mean_token_confidence, "createdAt": now(), "source": job.request.source, "sourceFingerprint": job.fingerprint, "transcriptSha256": sha256_hex(transcript.as_bytes()), "outputDir": format!("_Transcripts/{output_name}"), "honoured": {"language": job.backend == Backend::Whisper && job.request.transcription.language.is_some(), "diarize": job.request.output.diarize}, "ignored": job.request.ignored(job.backend), "artifacts": artifacts});
        let bytes = serde_json::to_vec(&result).map_err(|e| e.to_string())?;
        output.write("meta.json", &bytes)?;
        directory.write(&format!("{}.transcribe.result.json", job.stem), &bytes)?;
        self.record(job, "completed", result)?;
        Ok(())
    }
}

pub fn read_jobs(state: &Path, username: &str) -> Result<Vec<Value>, String> {
    if !valid_user(username) {
        return Err("invalid owner".into());
    }
    let Ok(directory) = Dir::open(state)?
        .child("users")
        .and_then(|d| d.child(username))
    else {
        return Ok(Vec::new());
    };
    let mut jobs = Vec::new();
    let mut files = directory
        .names()?
        .into_iter()
        .filter(|n| n.ends_with(".json"))
        .filter_map(|name| {
            directory
                .file(&name)
                .ok()
                .and_then(|f| f.metadata().ok())
                .and_then(|m| m.modified().ok())
                .map(|modified| (std::cmp::Reverse(modified), name))
        })
        .collect::<Vec<_>>();
    files.sort();
    for (_, name) in files.into_iter().take(200) {
        let bytes = directory.read(&name, 1024 * 1024)?;
        let mut value: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid job record")?;
        // Provenance and fingerprints remain in meta.json for consumers; the
        // frequently polled envelope contains only the UI's typed job fields.
        if let Some(object) = value.as_object_mut() {
            object.retain(|key, _| {
                [
                    "id",
                    "name",
                    "backend",
                    "state",
                    "queuedAt",
                    "updatedAt",
                    "durationMs",
                    "outputDir",
                    "error",
                    "ignored",
                    "artifacts",
                ]
                .contains(&key.as_str())
            });
        }
        jobs.push(value);
    }
    jobs.sort_by_key(|v| std::cmp::Reverse(v["updatedAt"].as_u64().unwrap_or_default()));
    jobs.truncate(200);
    Ok(jobs)
}
