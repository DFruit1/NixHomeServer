//! Evaluation-only record/replay of the slow or rationed inputs of `content`:
//! excerpt transcripts, Bonsai rankings and OpenSubtitles episode text.
//!
//! `identify_eval.py` points `--replay-cache` at a scratch directory so a
//! threshold sweep re-uses one transcription per MKV, and `--replay-only`
//! answers solely from it (a missing entry behaves like an unavailable
//! source), so every decision still comes from this binary's own rules.
//! Production never passes either flag. Entries hold transcripts and
//! subtitle text; keep the directory private and remove it afterwards.

use anyhow::{bail, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::hash_map::DefaultHasher,
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

pub struct Replay {
    dir: Option<PathBuf>,
    only: bool,
}

#[derive(Deserialize, Serialize)]
struct Entry<T> {
    key: String,
    value: T,
}

/// A recorded excerpt: its transcript, or why transcription failed.
#[derive(Deserialize, Serialize)]
enum Heard {
    Text(String),
    Failed(String),
}

fn file_identity(path: &Path) -> String {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let (size, modified) = fs::metadata(path)
        .map(|meta| {
            let modified = meta
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos());
            (meta.len(), modified)
        })
        .unwrap_or((0, 0));
    format!("{}|{size}|{modified}", canonical.display())
}

impl Replay {
    pub fn new(dir: Option<&Path>, only: bool) -> Result<Self> {
        if only && dir.is_none() {
            bail!("--replay-only needs --replay-cache");
        }
        if let Some(dir) = dir {
            fs::create_dir_all(dir)?;
        }
        Ok(Self {
            dir: dir.map(Path::to_path_buf),
            only,
        })
    }

    /// True when sources must not be contacted.
    pub fn only(&self) -> bool {
        self.only
    }

    fn file(&self, kind: &str, key: &str) -> Option<PathBuf> {
        let mut hasher = DefaultHasher::new();
        key.hash(&mut hasher);
        self.dir
            .as_ref()
            .map(|dir| dir.join(format!("{kind}-{:016x}.json", hasher.finish())))
    }

    fn load<T: DeserializeOwned>(&self, kind: &str, key: &str) -> Option<T> {
        let bytes = fs::read(self.file(kind, key)?).ok()?;
        let entry: Entry<T> = serde_json::from_slice(&bytes).ok()?;
        (entry.key == key).then_some(entry.value)
    }

    fn store<T: Serialize>(&self, kind: &str, key: &str, value: T) {
        let Some(file) = self.file(kind, key) else {
            return;
        };
        let entry = Entry {
            key: key.to_string(),
            value,
        };
        let temporary = file.with_extension("tmp");
        if let Ok(bytes) = serde_json::to_vec(&entry)
            && fs::write(&temporary, bytes).is_ok()
        {
            let _ = fs::rename(&temporary, &file);
        }
    }

    /// The excerpt transcript, keyed by the video's path, size and mtime,
    /// the excerpt window and the model file.
    pub fn transcript(
        &self,
        video: &Path,
        model: &Path,
        start: u32,
        seconds: u32,
        transcribe: impl FnOnce() -> Result<String>,
    ) -> Result<String> {
        let key = format!(
            "{}|{}|{start}|{seconds}",
            file_identity(video),
            file_identity(model)
        );
        match self.load::<Heard>("transcript", &key) {
            Some(Heard::Text(text)) => return Ok(text),
            Some(Heard::Failed(error)) => bail!("{error}"),
            None if self.only => bail!("no recorded transcript in the replay cache"),
            None => {}
        }
        let result = transcribe();
        if self.dir.is_some() {
            let heard = match &result {
                Ok(text) => Heard::Text(text.clone()),
                Err(error) => Heard::Failed(format!("{error:#}")),
            };
            self.store("transcript", &key, heard);
        }
        result
    }

    /// Bonsai's pick among `listing`, keyed by the model, transcript and listing.
    pub fn ranking(
        &self,
        model: &str,
        transcript: &str,
        listing: &[(String, String)],
        rank: impl FnOnce() -> Result<Option<(usize, f64)>>,
    ) -> Result<Option<(usize, f64)>> {
        let key = serde_json::to_string(&(model, transcript, listing))?;
        if let Some(answer) = self.load::<Option<(usize, f64)>>("ranking", &key) {
            return Ok(answer);
        }
        if self.only {
            bail!("no recorded ranking in the replay cache");
        }
        let answer = rank()?;
        self.store("ranking", &key, answer);
        Ok(answer)
    }

    /// Recorded subtitle text for an episode: `Some(None)` is a recorded
    /// "not found", `None` means it was never fetched.
    pub fn subtitle(&self, imdb: &str, season: u32, episode: u32) -> Option<Option<String>> {
        self.load("subtitle", &format!("{imdb}|{season}|{episode}"))
    }

    pub fn record_subtitle(&self, imdb: &str, season: u32, episode: u32, text: Option<&str>) {
        self.store("subtitle", &format!("{imdb}|{season}|{episode}"), text);
    }
}
