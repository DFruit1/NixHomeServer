//! Durable bridge from the web's staging area to the existing watched inboxes.
//! Only the filesystem broker writes libraries; server originals are never moved.
use crate::{
    config::{AppConfig, Identity},
    media::LibraryCategory,
    transcription::{fs::Dir, media_stem, Backend, Request},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

pub const MAX_INPUT_BYTES: u64 = 64 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Options {
    pub name: String,
    pub kind: String,
    #[serde(default = "default_backend")]
    pub backend: String,
    #[serde(default)]
    pub diarize: bool,
    pub language: Option<String>,
    pub storage_root_id: Option<String>,
    #[serde(default)]
    pub storage_folder: String,
}
fn default_backend() -> String {
    "parakeet".into()
}

impl Options {
    pub fn validate(&self, config: &AppConfig, identity: &Identity) -> Result<(), String> {
        if self.kind == "iso" {
            if !crate::transcription::valid_job_name(&self.name)
                || !self.name.to_ascii_lowercase().ends_with(".iso")
                || self.storage_root_id.is_some()
                || self.diarize
                || self.language.is_some()
            {
                return Err(
                    "Choose a DVD ISO. ISOs are retained in the shared DVD archive.".into(),
                );
            }
            if !config.dvd_inbox_path().is_dir() {
                return Err("The DVD converter inbox is unavailable.".into());
            }
        } else if self.kind == "transcription" {
            if media_stem(&self.name).is_none() || Backend::parse(&self.backend).is_none() {
                return Err(
                    "Choose a supported audio or video file and transcription engine.".into(),
                );
            }
            if !config
                .integrations
                .iter()
                .any(|i| i.id == "transcribe" && i.available)
                || config.transcribe_state_dir.is_none()
            {
                return Err("Local transcription is unavailable.".into());
            }
            Request::parse(&serde_json::to_vec(&self.request()).map_err(|e| e.to_string())?)?;
        } else {
            return Err("Choose transcription or DVD ISO conversion.".into());
        }
        if let Some(root) = &self.storage_root_id {
            let root = config
                .resolve_visible_root(identity, root)
                .ok_or("Choose a visible library folder.")?;
            if !root.available || !storage_category(root.category, &self.name) {
                return Err("Choose an appropriate audio or video library.".into());
            }
            validate_folder(&self.storage_folder)?;
        } else if !self.storage_folder.is_empty() {
            return Err("Choose a library before a destination subfolder.".into());
        }
        Ok(())
    }
    fn request(&self) -> Request {
        let mut request = Request::default();
        request.output.formats = vec!["txt".into(), "srt".into(), "vtt".into()];
        request.output.diarize = self.diarize;
        request.transcription.language = self.language.clone();
        request
    }
}
pub fn storage_category(category: LibraryCategory, name: &str) -> bool {
    let video = name.rsplit_once('.').is_some_and(|(_, e)| {
        matches!(
            e.to_ascii_lowercase().as_str(),
            "mp4" | "mkv" | "webm" | "mov" | "avi" | "m4v" | "mpeg" | "mpg" | "ts"
        )
    });
    if video {
        category == LibraryCategory::Videos
    } else {
        matches!(
            category,
            LibraryCategory::Music | LibraryCategory::Audiobooks | LibraryCategory::Podcasts
        )
    }
}
pub fn validate_folder(folder: &str) -> Result<(), String> {
    if folder.len() > 1024
        || (!folder.is_empty()
            && folder.split('/').any(|p| {
                p.is_empty()
                    || p == "."
                    || p == ".."
                    || p.len() > 180
                    || p.contains(['\\', '\0'])
                    || p.chars().any(char::is_control)
            }))
    {
        return Err("Use a relative subfolder without dot segments.".into());
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub owner: String,
    pub options: Options,
    pub inbox_name: String,
    pub state: String,
    pub created_at: u64,
    pub error: Option<String>,
    pub saved_path: Option<String>,
    pub transcript_id: Option<String>,
}
impl Job {
    pub fn new(owner: String, options: Options) -> Self {
        let id = homelab_common::random_hex(16);
        let (stem, ext) = options.name.rsplit_once('.').unwrap();
        let inbox_name = if options.kind == "iso" {
            format!("{stem}.iso")
        } else {
            let stem: String = stem
                .chars()
                .scan(0, |bytes, c| {
                    *bytes += c.len_utf8();
                    (*bytes <= 140).then_some(c)
                })
                .collect();
            format!("{stem}-{}.{}", &id[..12], ext.to_ascii_lowercase())
        };
        let transcript_id = (options.kind == "transcription").then(|| {
            homelab_common::sha256_hex(
                format!(
                    "{owner}\0{}\0{}",
                    options.backend,
                    inbox_name.rsplit_once('.').unwrap().0
                )
                .as_bytes(),
            )
        });
        Self {
            id,
            owner,
            options,
            inbox_name,
            state: "queued".into(),
            created_at: crate::transcription::worker::now(),
            error: None,
            saved_path: None,
            transcript_id,
        }
    }
    pub fn view(&self) -> Value {
        json!({"id":self.id,"name":self.options.name,"kind":self.options.kind,"state":self.state,"createdAt":self.created_at,"error":self.error,"savedPath":self.saved_path,"transcriptId":self.transcript_id})
    }
    pub fn save(&self, config: &AppConfig) -> Result<(), String> {
        owner_dir(config, &self.owner)?.write(
            &format!("{}.json", self.id),
            &serde_json::to_vec(self).map_err(|e| e.to_string())?,
        )
    }
}
pub fn staging_root(config: &AppConfig) -> PathBuf {
    config
        .conversion_staging_dir
        .clone()
        .unwrap_or_else(|| config.state_dir.join("conversion-staging"))
}
pub fn staging_dir(config: &AppConfig, username: &str) -> Result<Dir, String> {
    Identity::try_new(username, std::iter::empty::<&str>()).map_err(|_| "Invalid owner")?;
    let path = staging_root(config);
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    Dir::open(&path)?.create_shared(username)
}
pub fn staging_path(config: &AppConfig, username: &str) -> PathBuf {
    staging_root(config).join(username)
}
pub fn owner_dir(config: &AppConfig, username: &str) -> Result<Dir, String> {
    Identity::try_new(username, std::iter::empty::<&str>()).map_err(|_| "Invalid owner")?;
    Dir::open(&config.state_dir)?
        .create_shared("conversion-jobs")?
        .create_shared(username)
}
pub fn jobs(config: &AppConfig, username: &str) -> Result<Vec<Job>, String> {
    let dir = owner_dir(config, username)?;
    let mut jobs = Vec::new();
    for name in dir.names()?.into_iter().filter(|n| n.ends_with(".json")) {
        let job: Job = serde_json::from_slice(&dir.read(&name, 65536)?)
            .map_err(|_| "Invalid intake record")?;
        if job.owner == username {
            jobs.push(job);
        }
    }
    jobs.sort_by_key(|j| std::cmp::Reverse(j.created_at));
    Ok(jobs)
}
fn inbox(config: &AppConfig, job: &Job) -> Result<Dir, String> {
    if job.options.kind == "iso" {
        Dir::open(&config.shared_root)?
            .child("_ISO")?
            .child("_DVDs")
    } else {
        Dir::open(&config.users_root)?
            .child(&job.owner)?
            .child("_Transcribe")?
            .child(&job.options.backend)
    }
}

/// Called with the existing broker's exclusive lock. All publication is atomic
/// and no-replace. Interrupted submissions are visible failures, never retries
/// that might overwrite another user's work or enqueue a second conversion.
pub fn reconcile(config: &AppConfig) -> Result<(), String> {
    if config.mutation_mode != crate::config::MutationMode::Enabled {
        return Ok(());
    }
    let root = Dir::open(&config.state_dir)?.create_shared("conversion-jobs")?;
    let mut submitted = false;
    for owner in root.names()? {
        if Identity::try_new(&owner, std::iter::empty::<&str>()).is_err()
            || root.child(&owner).is_err()
        {
            continue;
        }
        for mut job in jobs(config, &owner)? {
            // One large intake per broker tick leaves capacity for library edits.
            if job.state == "queued" {
                if submitted {
                    continue;
                }
                submitted = true;
            }
            if matches!(job.state.as_str(), "completed" | "failed") {
                continue;
            }
            if let Err(error) = advance(config, &mut job) {
                job.state = "failed".into();
                job.error = Some(error);
                job.save(config)?;
            }
        }
    }
    Ok(())
}
fn advance(config: &AppConfig, job: &mut Job) -> Result<(), String> {
    let identity =
        Identity::try_new(&job.owner, std::iter::empty::<&str>()).map_err(|_| "Invalid owner")?;
    if matches!(job.state.as_str(), "submitting" | "saving") {
        return Err("Processing was interrupted. The source copy was preserved; check the inbox before submitting again.".into());
    }
    if job.state == "queued" {
        // Capabilities were checked by the API. Recheck path/options here; the
        // broker receives the same enabled integration configuration as the web.
        job.options.validate(config, &identity)?;
        let dir = inbox(config, job)?;
        if job.options.kind == "iso" {
            for archive in ["", "_Processed", "_Failed", "_Duplicate"] {
                let location = if archive.is_empty() {
                    Dir(dir.0.try_clone().map_err(|e| e.to_string())?)
                } else {
                    dir.child(archive)?
                };
                if location
                    .names()?
                    .iter()
                    .any(|n| n.eq_ignore_ascii_case(&job.inbox_name))
                {
                    return Err("An ISO with that name already exists in the DVD inbox or archive. Rename your source before submitting it again.".into());
                }
            }
        }
        job.state = "submitting".into();
        job.save(config)?;
        if job.options.kind == "transcription" {
            dir.write(
                &format!(
                    "{}.transcribe.request.json",
                    job.inbox_name.rsplit_once('.').unwrap().0
                ),
                &serde_json::to_vec(&job.options.request()).map_err(|e| e.to_string())?,
            )?;
        }
        let source = staging_dir(config, &job.owner)?.file(&format!("{}.source", job.id))?;
        dir.copy_new(&job.inbox_name, source)?;
        job.state = "processing".into();
        job.save(config)?;
        // The inbox now owns the durable copy. Only our staging copy is removed.
        let _ = staging_dir(config, &job.owner)?.remove(&format!("{}.source", job.id));
    }
    if job.state != "processing" {
        return Ok(());
    }
    let dir = inbox(config, job)?;
    let source = if job.options.kind == "iso" {
        if dir
            .child("_Failed")
            .and_then(|d| d.file(&job.inbox_name))
            .is_ok()
        {
            return Err("DVD conversion failed. Open its conversion log below.".into());
        }
        if dir
            .child("_Duplicate")
            .and_then(|d| d.file(&job.inbox_name))
            .is_ok()
        {
            return Err("This DVD is a duplicate; the converter retained it in _Duplicate.".into());
        }
        let processed = dir.child("_Processed")?;
        // Require the output manifest as well as the archived ISO.
        if processed
            .read(&format!("{}.output.json", job.inbox_name), 65536)
            .is_err()
        {
            return Ok(());
        }
        processed.file(&job.inbox_name)?
    } else {
        let Some(state) = &config.transcribe_state_dir else {
            return Err("Transcription was disabled.".into());
        };
        let record = Dir::open(state)?
            .child("users")
            .and_then(|d| d.child(&job.owner))
            .and_then(|d| {
                d.read(
                    &format!("{}.json", job.transcript_id.as_ref().unwrap()),
                    1024 * 1024,
                )
            });
        let Ok(record) = record else {
            return Ok(());
        };
        let record: Value =
            serde_json::from_slice(&record).map_err(|_| "Invalid transcription result")?;
        if record["state"] == "failed" {
            return Err(format!(
                "Transcription failed: {}",
                record["error"].as_str().unwrap_or("unknown error")
            ));
        }
        if record["state"] != "completed" {
            return Ok(());
        }
        dir.file(&job.inbox_name)?
    };
    if let Some(root_id) = &job.options.storage_root_id {
        let root = config
            .resolve_visible_root(&identity, root_id)
            .ok_or("Destination library unavailable")?;
        job.state = "saving".into();
        job.save(config)?;
        let mut destination = Dir::open(std::path::Path::new(&root.resolved_path))?;
        for part in job
            .options
            .storage_folder
            .split('/')
            .filter(|p| !p.is_empty())
        {
            destination = destination.create_shared(part)?;
        }
        destination.copy_new(&job.options.name, source).map_err(|e| format!("Processing succeeded, but saving the library copy failed: {e}. The source remains in the job folder."))?;
        job.saved_path = Some(format!(
            "{}/{}{}",
            root.label,
            if job.options.storage_folder.is_empty() {
                String::new()
            } else {
                format!("{}/", job.options.storage_folder)
            },
            job.options.name
        ));
    }
    job.state = "completed".into();
    job.save(config)
}

#[cfg(test)]
mod safety_tests {
    use super::*;
    use std::os::unix::fs::symlink;

    // A new post-processing copy must never overwrite existing library files,
    // or write through a library symlink into an unrelated private directory.
    #[test]
    fn conversion_copy_preserves_existing_files_and_rejects_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let directory = Dir::open(temp.path()).unwrap();
        let private = temp.path().join("private.mp3");
        std::fs::write(&private, b"irreplaceable original").unwrap();
        std::fs::write(temp.path().join("upload.mp3"), b"new upload").unwrap();
        symlink(&private, temp.path().join("link.mp3")).unwrap();
        for target in ["private.mp3", "link.mp3", "../escape.mp3"] {
            assert!(directory
                .copy_new(target, directory.file("upload.mp3").unwrap())
                .is_err());
        }
        assert_eq!(std::fs::read(&private).unwrap(), b"irreplaceable original");
        directory
            .copy_new("saved.mp3", directory.file("upload.mp3").unwrap())
            .unwrap();
        assert_eq!(
            std::fs::read(temp.path().join("saved.mp3")).unwrap(),
            b"new upload"
        );
        assert!(!directory
            .names()
            .unwrap()
            .iter()
            .any(|n| n.starts_with(".media-copy-")));
    }
}
