//! Durable bridge from the web's staging area to the existing watched inboxes.
//! Only the filesystem broker writes libraries. Transcription inputs are copied
//! and their originals kept; a DVD ISO chosen on the server moves into the DVD
//! inbox, which is how archived discs are reprocessed (owner request, 2026-11-15).
use crate::{
    config::{AppConfig, Identity},
    media::LibraryCategory,
    transcription::{fs::Dir, media_stem, Backend, Request},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

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

/// Input root holding the converter's inbox and its archive folders.
pub const DVD_INBOX_ROOT: &str = "dvd-inbox";
const DVD_ARCHIVES: [&str; 4] = [
    "_Processed",
    "_Failed",
    "_Duplicate",
    "_NeedsIdentification",
];

/// Folders a user may pick conversion inputs from. The broker recomputes the
/// same list for the job owner, so a stored root id never widens access.
pub fn source_roots(config: &AppConfig, identity: &Identity) -> Vec<Value> {
    let mut roots: Vec<Value> = config
        .visible_roots(identity)
        .into_iter()
        .filter(|r| r.available && r.category != LibraryCategory::Books)
        .map(|r| json!({"id":r.id,"label":r.label,"path":r.resolved_path,"category":r.category}))
        .collect();
    if config.dvd_inbox_path().is_dir() {
        roots.push(json!({"id":DVD_INBOX_ROOT,"label":"Shared DVD inbox","path":config.dvd_inbox_path(),"category":"iso"}));
    }
    let transcribe = config
        .users_root
        .join(&identity.username)
        .join("_Transcribe");
    if transcribe.is_dir() {
        roots.push(json!({"id":"transcription-inbox","label":"My transcription inbox","path":transcribe,"category":"transcription"}));
    }
    roots
}

/// A server file named by its input root and a contained relative path.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceFile {
    pub root_id: String,
    pub relative_path: String,
}
impl SourceFile {
    pub fn locate(config: &AppConfig, identity: &Identity, path: &str) -> Result<Self, String> {
        let path = Path::new(path);
        for root in source_roots(config, identity) {
            let base = Path::new(root["path"].as_str().ok_or("Invalid root")?);
            if let Ok(relative) = path.strip_prefix(base) {
                let relative = relative.to_str().ok_or("Invalid file path")?;
                if relative.is_empty() || validate_folder(relative).is_err() {
                    return Err("Choose a file inside one of the listed folders.".into());
                }
                return Ok(Self {
                    root_id: root["id"].as_str().unwrap_or_default().into(),
                    relative_path: relative.into(),
                });
            }
        }
        Err("Choose a file in a listed shared library, your own library, or an input inbox.".into())
    }
    /// Whether this file is already waiting at the top of the DVD inbox.
    pub fn in_dvd_queue(&self) -> bool {
        self.root_id == DVD_INBOX_ROOT && !self.relative_path.contains('/')
    }
    /// Open the parent directory and file without following any link.
    pub fn open(
        &self,
        config: &AppConfig,
        identity: &Identity,
    ) -> Result<(Dir, String, std::fs::File), String> {
        let root = source_roots(config, identity)
            .into_iter()
            .find(|r| r["id"] == self.root_id.as_str())
            .ok_or("The source folder is no longer available.")?;
        validate_folder(&self.relative_path)?;
        let (folder, leaf) = self
            .relative_path
            .rsplit_once('/')
            .unwrap_or(("", &self.relative_path));
        let mut dir = Dir::open(Path::new(root["path"].as_str().ok_or("Invalid root")?))?;
        for part in folder.split('/').filter(|p| !p.is_empty()) {
            dir = dir.child(part)?;
        }
        let file = dir
            .file(leaf)
            .map_err(|_| format!("{leaf} is no longer in that folder."))?;
        Ok((dir, leaf.into(), file))
    }
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
    /// Set when a DVD ISO moves from the server instead of a staged copy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceFile>,
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
            source: None,
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
/// The converter and job tracking identify discs by file name, so a new ISO
/// may not share a name with any queued or archived disc other than itself.
pub fn check_dvd_name(
    config: &AppConfig,
    inbox_name: &str,
    source: Option<&SourceFile>,
) -> Result<(), String> {
    let dir = Dir::open(&config.dvd_inbox_path())
        .map_err(|_| "The DVD converter inbox is unavailable.")?;
    for archive in std::iter::once("").chain(DVD_ARCHIVES) {
        let location = if archive.is_empty() {
            Dir(dir.0.try_clone().map_err(|e| e.to_string())?)
        } else {
            match dir.child(archive) {
                Ok(location) => location,
                Err(_) => continue,
            }
        };
        let clash = location.names()?.into_iter().any(|n| {
            n.eq_ignore_ascii_case(inbox_name)
                && !source.is_some_and(|s| {
                    s.root_id == DVD_INBOX_ROOT && s.relative_path == format!("{archive}/{n}")
                })
        });
        if clash {
            return Err("An ISO with that name already exists in the DVD inbox or archive. Rename your source before submitting it again.".into());
        }
    }
    Ok(())
}
/// The archived ISO whose output manifest names `source` as its original;
/// identified discs are archived under their episode name. Only
/// manifests finished after the job was created count, newest first, so an
/// older disc that once had the same name is never taken for this job's.
fn renamed_archive(
    processed: &Dir,
    source: &str,
    created_at: u64,
) -> Result<Option<String>, String> {
    let mut best: Option<(u64, String)> = None;
    for manifest in processed.names()? {
        let Some(iso) = manifest.strip_suffix(".output.json") else {
            continue;
        };
        let Ok(bytes) = processed.read(&manifest, 65536) else {
            continue;
        };
        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        let finished = value["finishedAt"].as_u64().unwrap_or(0);
        if value["sourceIso"].as_str() == Some(source)
            && finished >= created_at
            && best.as_ref().is_none_or(|(newest, _)| finished > *newest)
        {
            best = Some((finished, iso.to_string()));
        }
    }
    Ok(best.map(|(_, iso)| iso))
}

fn inbox(config: &AppConfig, job: &Job) -> Result<Dir, String> {
    if job.options.kind == "iso" {
        Dir::open(&config.shared_root)?
            .child("_ISO")?
            .child("_DVDs")
    } else {
        Dir::open(&config.users_root)?
            .traverse(&job.owner)?
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
    let mut pending = Vec::new();
    for owner in root.names()? {
        if Identity::try_new(&owner, std::iter::empty::<&str>()).is_ok()
            && root.child(&owner).is_ok()
        {
            pending.extend(
                jobs(config, &owner)?
                    .into_iter()
                    .filter(|job| !matches!(job.state.as_str(), "completed" | "failed")),
            );
        }
    }
    // Display history newest first, but dispatch the oldest job across all
    // owners first so a stream of newer uploads cannot starve earlier files.
    pending.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let mut submitted = false;
    for mut job in pending {
        if job.state == "queued" {
            if submitted {
                continue;
            }
            submitted = true;
        }
        if let Err(error) = advance(config, &mut job) {
            job.state = "failed".into();
            job.error = Some(error);
            job.save(config)?;
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
            check_dvd_name(config, &job.inbox_name, job.source.as_ref())?;
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
        if let Some(source) = job.source.clone() {
            let (parent, leaf, file) = source.open(config, &identity)?;
            if source.root_id == DVD_INBOX_ROOT {
                // Archived discs already carry the converter's permissions.
                drop(file);
                dir.rename_new(&job.inbox_name, &parent, &leaf)?;
            } else {
                // A fresh copy inherits the inbox ACLs that the converter needs;
                // a rename would keep the library's. Then drop the original.
                dir.copy_new(
                    &job.inbox_name,
                    file.try_clone().map_err(|e| e.to_string())?,
                )?;
                if let Err(error) = parent.remove_same(&leaf, &file) {
                    job.error = Some(format!(
                        "The ISO was queued, but the original could not be removed: {error}"
                    ));
                }
            }
            job.state = "processing".into();
            job.save(config)?;
        } else {
            let source = staging_dir(config, &job.owner)?.file(&format!("{}.source", job.id))?;
            dir.copy_new(&job.inbox_name, source)?;
            job.state = "processing".into();
            job.save(config)?;
            // The inbox now owns the durable copy. Only our staging copy is removed.
            let _ = staging_dir(config, &job.owner)?.remove(&format!("{}.source", job.id));
        }
    }
    if job.state != "processing" {
        return Ok(());
    }
    let dir = inbox(config, job)?;
    let source = if job.options.kind == "iso" {
        // Still queued or converting. Checked first so results left by an
        // earlier run of a reprocessed disc are not mistaken for this one.
        if dir.file(&job.inbox_name).is_ok() {
            return Ok(());
        }
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
        if dir
            .child("_NeedsIdentification")
            .and_then(|d| d.file(&job.inbox_name))
            .is_ok()
        {
            return Err("The DVD was converted, but its episodes need identifying. Rename it as described under Process, needs identifying.".into());
        }
        let processed = dir.child("_Processed")?;
        // Require the output manifest as well as the archived ISO. The
        // importer records each manifest's source name and finish time.
        // Identified TV discs are archived under their episode name, and
        // "Convert again" leaves an older manifest of the same name behind,
        // so only a manifest finished after this job was created counts.
        let Some(archived) = renamed_archive(&processed, &job.inbox_name, job.created_at)? else {
            return Ok(());
        };
        processed.file(&archived)?
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
        let source = dir.file(&job.inbox_name)?;
        if job.options.storage_root_id.is_some() {
            let fingerprint =
                crate::broker::opened_file_fingerprint(&source).map_err(|e| e.to_string())?;
            if record["sourceFingerprint"].as_str() != Some(fingerprint.as_str()) {
                return Err("Transcription finished, but the source changed afterward. The library copy was not saved; your transcript and source remain in the job folders.".into());
            }
        }
        source
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

    // Regression (2026-11-15 review): identified TV discs are archived under
    // their episode name, so a submitted job must find its manifest by the
    // recorded source name rather than wait on its own name forever.
    #[test]
    fn renamed_dvd_archives_are_found_by_their_recorded_source() {
        let temp = tempfile::tempdir().unwrap();
        let processed = Dir::open(temp.path()).unwrap();
        let manifest = |iso: &str, source: &str, finished: u64| {
            std::fs::write(
                temp.path().join(format!("{iso}.output.json")),
                json!({"sourceIso": source, "finishedAt": finished}).to_string(),
            )
            .unwrap();
        };
        manifest("Show (1978) S01E01-E02.iso", "DISC.iso", 50);
        manifest("Show (1978) S01E05-E06.iso", "DISC.iso", 200);
        manifest("Other.iso", "OTHER.iso", 300);
        // "Convert again" leaves the earlier same-name manifest behind.
        manifest("DISC.iso", "DISC.iso", 40);
        assert_eq!(
            renamed_archive(&processed, "DISC.iso", 100)
                .unwrap()
                .as_deref(),
            Some("Show (1978) S01E05-E06.iso")
        );
        // An older disc that once had the same name is not this job's.
        assert_eq!(renamed_archive(&processed, "DISC.iso", 250).unwrap(), None);
    }

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

    // Queuing a server ISO now removes or renames the original. It must never
    // replace an existing disc, and a library original goes only after its
    // copy is published in the inbox.
    #[test]
    fn dvd_moves_never_replace_and_remove_originals_only_after_copying() {
        let temp = tempfile::tempdir().unwrap();
        let shared = temp.path().join("shared");
        let inbox = shared.join("_ISO/_DVDs");
        std::fs::create_dir_all(inbox.join("_Processed")).unwrap();
        std::fs::create_dir_all(shared.join("_Videos")).unwrap();
        std::fs::create_dir_all(temp.path().join("state")).unwrap();
        std::fs::write(inbox.join("_Processed/Old.iso"), b"archived disc").unwrap();
        std::fs::write(shared.join("_Videos/New.iso"), b"library disc").unwrap();
        std::fs::write(shared.join("_Videos/Taken.iso"), b"second disc").unwrap();
        std::fs::write(inbox.join("Taken.iso"), b"queued disc").unwrap();
        let mut config = AppConfig::for_test(
            shared.to_str().unwrap(),
            temp.path().join("users").to_str().unwrap(),
        );
        config.state_dir = temp.path().join("state");
        config.mutation_mode = crate::config::MutationMode::Enabled;
        let alice = Identity::try_new("alice", ["users"]).unwrap();
        let queue = |path: std::path::PathBuf, created_at| {
            let source = SourceFile::locate(&config, &alice, path.to_str().unwrap()).unwrap();
            let name = path.file_name().unwrap().to_str().unwrap();
            let options: Options = serde_json::from_value(
                json!({"name":name,"kind":"iso","language":null,"storageRootId":null}),
            )
            .unwrap();
            let mut job = Job::new("alice".into(), options);
            job.created_at = created_at;
            job.source = Some(source);
            job.save(&config).unwrap();
            job.id
        };
        // The archived disc may return to the inbox under its own name.
        assert!(check_dvd_name(&config, "Old.iso", None).is_err());
        let old = queue(inbox.join("_Processed/Old.iso"), 1);
        let new = queue(shared.join("_Videos/New.iso"), 2);
        let taken = queue(shared.join("_Videos/Taken.iso"), 3);
        for _ in 0..3 {
            reconcile(&config).unwrap();
        }
        let state = |id: &str| {
            jobs(&config, "alice")
                .unwrap()
                .into_iter()
                .find(|j| j.id == id)
                .unwrap()
        };
        assert_eq!(
            std::fs::read(inbox.join("Old.iso")).unwrap(),
            b"archived disc"
        );
        assert!(!inbox.join("_Processed/Old.iso").exists());
        assert_eq!(state(&old).state, "processing");
        assert_eq!(
            std::fs::read(inbox.join("New.iso")).unwrap(),
            b"library disc"
        );
        assert!(!shared.join("_Videos/New.iso").exists());
        assert_eq!(state(&new).state, "processing");
        assert_eq!(state(&taken).state, "failed");
        assert_eq!(
            std::fs::read(inbox.join("Taken.iso")).unwrap(),
            b"queued disc"
        );
        assert_eq!(
            std::fs::read(shared.join("_Videos/Taken.iso")).unwrap(),
            b"second disc"
        );
    }
}
