//! Unattended import of the desktop ripper's audio CD ISOs.
//!
//! Each watched inbox holds one folder per book with one ISO per CD. A book
//! is published into its library only when the whole set is present and its
//! identity is certain (see `book`); an incomplete set waits in the inbox and
//! anything doubtful moves to `_NeedsIdentification` with an `identify.json`
//! saying why. Renaming a held folder to `Author - Title (Year) [N discs]`
//! confirms it. Published sets are archived in `_Processed`, repeated ISOs in
//! `_Duplicate`, and sets that keep failing in `_Failed`.
//!
//! One pass handles everything that is ready and exits; a systemd timer
//! starts the next pass.

mod book;
mod build;
mod chapters;
mod disc;
mod fsops;
mod identify;
// Shared with the DVD identifier: the Bonsai gate client with its busy
// handling, the Parakeet excerpt transcriber with the provider broker's
// Unix-socket transport, and the name comparison helpers.
#[allow(dead_code)]
#[path = "../disc-identify/bonsai.rs"]
mod bonsai;
#[allow(dead_code)]
#[path = "../disc-identify/content.rs"]
mod content;
#[allow(dead_code)]
#[path = "../disc-identify/text.rs"]
mod text;

use anyhow::{bail, Context, Result};
use book::{confirming_name, decide, parse_folder_name, Decision, HoldKind, Proposal};
use build::{Built, Stopped, Tools};
use clap::Parser;
use disc::Disc;
use fsops::{
    move_file, natural_key, normalized, rename_noreplace, safe_component, sha256_file, signature,
    unique_destination, write_json_atomic, Signature,
};
use identify::{Identifier, Resolution, Source, Unavailable, Unsettled};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const HOLD_DIR: &str = "_NeedsIdentification";
const PROCESSED_DIR: &str = "_Processed";
const FAILED_DIR: &str = "_Failed";
const DUPLICATE_DIR: &str = "_Duplicate";
const STAGING_DIR: &str = ".audiocd-import";
const EVIDENCE_FILE: &str = "identify.json";
const MARKER_FILE: &str = ".audiobook.json";
/// Hours after which a set held for something temporary is tried again.
const RETRY_HOURS: [u64; 3] = [1, 6, 24];
/// Quarter-hourly tries for provider details before a certain book is
/// published without them.
const ENRICH_ATTEMPTS: u32 = 4;
const HOW_TO_CONFIRM: &str = "Rename this folder to the confirmWith name to import it. Correct the author, title, year or number of discs in the name first if they are wrong.";

#[derive(Parser)]
#[command(
    version,
    about = "Import the desktop ripper's audio CD ISOs into Audiobookshelf"
)]
struct Args {
    /// A watched inbox and the library its books are published to.
    #[arg(long = "inbox", value_name = "INBOX=LIBRARY")]
    inboxes: Vec<String>,
    /// Directory holding one folder per user, each with its own inbox and library.
    #[arg(long)]
    users_root: Option<PathBuf>,
    /// A user's inbox, relative to that user's folder.
    #[arg(long, default_value = "_ISO/_AudioCDs")]
    user_inbox: String,
    /// A user's library, relative to that user's folder.
    #[arg(long, default_value = "_Audiobooks")]
    user_library: String,
    #[arg(long)]
    state_dir: PathBuf,
    /// JSON status for Media Manager.
    #[arg(long)]
    status_file: Option<PathBuf>,
    #[arg(long, default_value = "ffmpeg")]
    ffmpeg: PathBuf,
    #[arg(long, default_value = "ffprobe")]
    ffprobe: PathBuf,
    #[arg(long, default_value = "7zz")]
    sevenzip: PathBuf,
    /// Seconds a set's files must stay unchanged before it is read.
    #[arg(long, default_value_t = 60)]
    settle_seconds: u64,
    /// Failures allowed before a set is preserved in `_Failed`.
    #[arg(long, default_value_t = 3)]
    max_attempts: u32,
    /// Base delay between retries, multiplied by the attempt number.
    #[arg(long, default_value_t = 900)]
    retry_seconds: u64,
    /// Provider broker system socket (Audible catalogue lookups and covers).
    /// Without it books are published from the ripper's evidence alone.
    #[arg(long)]
    provider_socket: Option<PathBuf>,
    /// OpenAI-compatible Bonsai endpoint that reads the spoken credits.
    #[arg(long)]
    bonsai_url: Option<String>,
    #[arg(long, default_value = "bonsai-ternary-27b")]
    bonsai_model: String,
    /// parakeet-cli, which transcribes the opening and closing announcements.
    #[arg(long, requires = "parakeet_model")]
    parakeet: Option<PathBuf>,
    #[arg(long, requires = "parakeet")]
    parakeet_model: Option<PathBuf>,
    #[arg(long, default_value_t = 4)]
    identify_threads: u32,
    /// Print the chapters heard in these audio files, taken in order as one
    /// book, and exit. Needs --parakeet; scratch goes under --state-dir.
    #[arg(long, num_args = 1.., value_name = "FILE")]
    find_chapters: Vec<PathBuf>,
}

struct Inbox {
    label: String,
    root: PathBuf,
    library: PathBuf,
}

/// The files of one book as they lie in an inbox or in the holding folder.
struct SetSource {
    /// Folder holding the files; the inbox root for a loose ISO.
    dir: PathBuf,
    name: String,
    /// Folder path relative to the inbox, so later discs find a held set.
    origin: String,
    loose: bool,
    held: bool,
    isos: Vec<PathBuf>,
    files: Vec<PathBuf>,
}

impl SetSource {
    fn key(&self) -> String {
        if self.loose {
            self.isos[0].to_string_lossy().into_owned()
        } else {
            self.dir.to_string_lossy().into_owned()
        }
    }
}

struct Loaded {
    path: PathBuf,
    disc: Disc,
    sha256: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Observed {
    signature: Signature,
    since: u64,
}

#[derive(Clone, Serialize, Deserialize)]
struct CachedDisc {
    signature: Signature,
    sha256: String,
    disc: Disc,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Attempts {
    attempts: u32,
    next_attempt: u64,
    error: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Processed {
    book: String,
    published: String,
    at: String,
}

/// A published book whose ISOs still have to be archived.
#[derive(Clone, Serialize, Deserialize)]
struct Unarchived {
    published: String,
    report: serde_json::Value,
}

#[derive(Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    files: BTreeMap<String, Observed>,
    #[serde(default)]
    discs: BTreeMap<String, CachedDisc>,
    #[serde(default)]
    sets: BTreeMap<String, Attempts>,
    #[serde(default)]
    processed: BTreeMap<String, Processed>,
    #[serde(default)]
    unarchived: BTreeMap<String, Unarchived>,
    /// Held folders that received another disc and must be looked at again.
    #[serde(default)]
    reevaluate: BTreeSet<String>,
    /// Held folders waiting for something temporary, by folder path.
    #[serde(default)]
    retries: BTreeMap<String, RetryRecord>,
    /// Certain books waiting for provider details, by set key.
    #[serde(default)]
    deferred: BTreeMap<String, Deferred>,
    #[serde(default)]
    identify: identify::Cache,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct RetryRecord {
    /// Retries scheduled so far.
    attempt: usize,
    next_attempt: u64,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Deferred {
    count: u32,
    next_attempt: u64,
    reason: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RetryView {
    attempt: usize,
    of: usize,
    next_attempt_at: String,
}

/// Why a set is held and what identification found.
struct Held {
    proposal: Option<Proposal>,
    reason: String,
    identification: Value,
    /// Held only because something was temporarily unavailable.
    transient: bool,
}

impl Held {
    fn plain(proposal: Option<Proposal>, reason: String) -> Self {
        Self {
            proposal,
            reason,
            identification: Value::Null,
            transient: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiscSummary {
    iso: String,
    disc_number: Option<u32>,
    disc_total: Option<u32>,
    category: String,
    author: String,
    title: String,
    lookup_status: String,
    typed_at_drive: bool,
    tracks: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Evidence {
    schema_version: u32,
    updated_at: String,
    origin: String,
    reason: String,
    proposal: Option<Proposal>,
    confirm_with: String,
    how_to_confirm: String,
    discs: Vec<DiscSummary>,
    /// Transcript excerpts, the spoken credits and the catalogue editions
    /// compared, when identification ran.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    identification: Value,
    /// Present while the set is tried again automatically.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    retry: Option<RetryView>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SetStatus {
    inbox: String,
    folder: String,
    path: String,
    /// settling, waiting, held, retrying or skipped.
    state: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    missing_discs: Vec<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proposal: Option<Proposal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    confirm_with: Option<String>,
    discs: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Active<'a> {
    inbox: &'a str,
    folder: &'a str,
    step: &'a str,
    percent: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusFile<'a> {
    schema_version: u32,
    updated_at: String,
    state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    active: Option<Active<'a>>,
    sets: &'a [SetStatus],
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn timestamp() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_iso(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("iso"))
}

/// Entries of a directory in natural order; unreadable directories are empty.
fn entries(directory: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = fs::read_dir(directory)
        .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
        .unwrap_or_default();
    paths.sort_by_key(|path| natural_key(&file_name(path)));
    paths
}

fn is_real_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir())
}

fn is_real_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file())
}

fn set_from_dir(root: &Path, dir: &Path, held: bool) -> Option<SetSource> {
    let files: Vec<PathBuf> = entries(dir)
        .into_iter()
        .filter(|path| is_real_file(path) && file_name(path) != EVIDENCE_FILE)
        .collect();
    let isos: Vec<PathBuf> = files
        .iter()
        .filter(|path| is_iso(path) && !file_name(path).starts_with('.'))
        .cloned()
        .collect();
    if isos.is_empty() {
        return None;
    }
    Some(SetSource {
        dir: dir.to_path_buf(),
        name: file_name(dir),
        origin: dir
            .strip_prefix(root)
            .unwrap_or(dir)
            .to_string_lossy()
            .into_owned(),
        loose: false,
        held,
        isos,
        files,
    })
}

/// Book folders anywhere up to three levels below the inbox (the ripper
/// sends `Audiobooks/<book>/`), plus ISOs dropped straight into the inbox.
fn discover_sets(root: &Path) -> Vec<SetSource> {
    fn walk(root: &Path, dir: &Path, depth: usize, sets: &mut Vec<SetSource>) {
        for path in entries(dir) {
            let name = file_name(&path);
            if name.starts_with('.') || name.starts_with('_') {
                continue;
            }
            if depth == 0 && is_real_file(&path) && is_iso(&path) {
                sets.push(SetSource {
                    dir: root.to_path_buf(),
                    name: path
                        .file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or(name),
                    origin: String::new(),
                    loose: true,
                    held: false,
                    files: disc::companions(&path),
                    isos: vec![path],
                });
            } else if is_real_dir(&path) {
                match set_from_dir(root, &path, false) {
                    Some(set) => sets.push(set),
                    None if depth < 2 => walk(root, &path, depth + 1, sets),
                    None => {}
                }
            }
        }
    }
    let mut sets = Vec::new();
    walk(root, root, 0, &mut sets);
    sets
}

fn discover_held(root: &Path) -> Vec<SetSource> {
    let holds = root.join(HOLD_DIR);
    entries(&holds)
        .into_iter()
        .filter(|path| is_real_dir(path) && !file_name(path).starts_with('.'))
        .filter_map(|path| set_from_dir(&holds, &path, true))
        .collect()
}

fn discover_inboxes(args: &Args) -> Result<Vec<Inbox>> {
    let mut inboxes = Vec::new();
    for pair in &args.inboxes {
        let (root, library) = pair
            .split_once('=')
            .with_context(|| format!("--inbox needs INBOX=LIBRARY: {pair}"))?;
        inboxes.push(Inbox {
            label: "Shared".to_string(),
            root: PathBuf::from(root),
            library: PathBuf::from(library),
        });
    }
    if let Some(users_root) = &args.users_root {
        for user in entries(users_root) {
            let root = user.join(&args.user_inbox);
            let library = user.join(&args.user_library);
            if is_real_dir(&root) && is_real_dir(&library) {
                inboxes.push(Inbox {
                    label: file_name(&user),
                    root,
                    library,
                });
            }
        }
    }
    Ok(inboxes)
}

fn read_evidence(dir: &Path) -> Option<Evidence> {
    serde_json::from_str(&fs::read_to_string(dir.join(EVIDENCE_FILE)).ok()?).ok()
}

fn marker_total(dir: &Path) -> Option<u32> {
    let marker: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(dir.join(MARKER_FILE)).ok()?).ok()?;
    marker["disc_total"]
        .as_u64()
        .and_then(|total| u32::try_from(total).ok())
        .filter(|n| *n > 0)
}

fn disc_summaries(discs: &[Loaded]) -> Vec<DiscSummary> {
    discs
        .iter()
        .map(|loaded| DiscSummary {
            iso: loaded.disc.iso_name.clone(),
            disc_number: loaded.disc.disc_number,
            disc_total: loaded.disc.disc_total,
            category: loaded.disc.category.clone(),
            author: loaded.disc.author.clone(),
            title: loaded.disc.title.clone(),
            lookup_status: loaded.disc.lookup_status.clone(),
            typed_at_drive: loaded.disc.hint_applied,
            tracks: loaded.disc.tracks.len().max(loaded.disc.audio_files.len()),
        })
        .collect()
}

fn strip_year(name: &str) -> &str {
    let name = name.trim();
    if name.ends_with(')')
        && let Some(open) = name.rfind('(')
        && name[open + 1..name.len() - 1].parse::<u32>().is_ok()
    {
        return name[..open].trim_end();
    }
    name
}

/// A folder name such as `Book 3 - Title (2003)` names this title.
fn names_title(folder: &str, title: &str) -> bool {
    let wanted = normalized(title);
    let bare = strip_year(folder);
    normalized(bare) == wanted
        || bare
            .split_once(" - ")
            .is_some_and(|(_, rest)| normalized(rest) == wanted)
}

/// The author's folder (existing spelling preferred) and any folder under it,
/// directly or one series level down, that already holds this title.
fn library_lookup(library: &Path, proposal: &Proposal) -> (PathBuf, Option<PathBuf>) {
    let wanted = normalized(&proposal.author);
    let author_dir = entries(library)
        .into_iter()
        .find(|path| is_real_dir(path) && normalized(&file_name(path)) == wanted)
        .unwrap_or_else(|| library.join(safe_component(&proposal.author, "Unknown Author")));
    for path in entries(&author_dir) {
        if !is_real_dir(&path) {
            continue;
        }
        if names_title(&file_name(&path), &proposal.title) {
            return (author_dir, Some(path));
        }
        for nested in entries(&path) {
            if is_real_dir(&nested) && names_title(&file_name(&nested), &proposal.title) {
                return (author_dir, Some(nested));
            }
        }
    }
    (author_dir, None)
}

struct Worker {
    args: Args,
    tools: Tools,
    identifier: Identifier,
    state: State,
    state_path: PathBuf,
    stop: Arc<AtomicBool>,
    statuses: Vec<SetStatus>,
    shown: Vec<SetStatus>,
    counter: u32,
}

impl Worker {
    fn save(&self) -> Result<()> {
        write_json_atomic(&self.state_path, &self.state)
    }

    fn write_status(&self, active: Option<Active<'_>>, sets: &[SetStatus]) {
        let Some(path) = &self.args.status_file else {
            return;
        };
        let status = StatusFile {
            schema_version: 1,
            updated_at: timestamp(),
            state: if active.is_some() { "working" } else { "idle" },
            active,
            sets,
        };
        if let Err(error) = write_json_atomic(path, &status) {
            eprintln!("cannot write the status file: {error:#}");
        }
    }

    fn note(&mut self, inbox: &Inbox, set: &SetSource, state: &'static str, message: String) {
        self.statuses.push(SetStatus {
            inbox: inbox.label.clone(),
            folder: set.name.clone(),
            path: set.dir.to_string_lossy().into_owned(),
            state,
            message,
            missing_discs: Vec::new(),
            proposal: None,
            confirm_with: None,
            discs: set.isos.len(),
        });
    }

    /// True once none of the files has changed for the settle period.
    fn settled(&mut self, files: &[PathBuf]) -> bool {
        let time = now();
        let mut ready = true;
        for file in files {
            let Ok(current) = signature(file) else {
                ready = false;
                continue;
            };
            let key = file.to_string_lossy().into_owned();
            let since = match self.state.files.get(&key) {
                Some(seen) if seen.signature == current => seen.since,
                _ => {
                    self.state.files.insert(
                        key,
                        Observed {
                            signature: current,
                            since: time,
                        },
                    );
                    time
                }
            };
            if time.saturating_sub(since) < self.args.settle_seconds {
                ready = false;
            }
        }
        ready
    }

    fn load_discs(&mut self, isos: &[PathBuf]) -> Result<Vec<Loaded>> {
        let mut discs = Vec::new();
        for iso in isos {
            if self.stop.load(Ordering::Relaxed) {
                return Err(Stopped.into());
            }
            let key = iso.to_string_lossy().into_owned();
            let current = signature(iso)?;
            let cached = match self.state.discs.get(&key) {
                Some(cached) if cached.signature == current => cached.clone(),
                _ => {
                    let cached = CachedDisc {
                        signature: current,
                        sha256: sha256_file(iso)?,
                        disc: disc::load(iso, &self.tools.sevenzip)?,
                    };
                    self.state.discs.insert(key, cached.clone());
                    cached
                }
            };
            if !cached.disc.recorded_sha256.is_empty()
                && cached.disc.recorded_sha256 != cached.sha256
            {
                bail!(
                    "{} does not match the checksum the ripper recorded; send it again",
                    cached.disc.iso_name
                );
            }
            discs.push(Loaded {
                path: iso.clone(),
                disc: cached.disc,
                sha256: cached.sha256,
            });
        }
        Ok(discs)
    }

    /// Forget observations of paths that no longer exist.
    fn prune(&mut self) {
        self.state.files.retain(|path, _| Path::new(path).exists());
        self.state.discs.retain(|path, _| Path::new(path).exists());
        self.state.sets.retain(|path, _| Path::new(path).exists());
        self.state
            .unarchived
            .retain(|path, _| Path::new(path).exists());
        self.state
            .reevaluate
            .retain(|path| Path::new(path).exists());
        self.state
            .retries
            .retain(|path, _| Path::new(path).exists());
        self.state
            .deferred
            .retain(|path, _| Path::new(path).exists());
        let known: BTreeSet<&str> = self
            .state
            .discs
            .values()
            .map(|disc| disc.sha256.as_str())
            .collect();
        self.state.identify.transcripts.retain(|key, _| {
            key.split(':')
                .next()
                .is_some_and(|sha256| known.contains(sha256))
        });
        if self.state.identify.credits.len() > 500 {
            self.state.identify.credits.clear();
        }
    }

    fn clean_stale_staging(&self, inboxes: &[Inbox]) {
        for inbox in inboxes {
            for path in entries(&inbox.library.join(STAGING_DIR)) {
                if is_real_dir(&path) {
                    println!("Removing unfinished staging folder {}", path.display());
                    let _ = fs::remove_dir_all(&path);
                }
            }
        }
    }

    fn remove_source_dir(&self, set: &SetSource) {
        if !set.loose && fs::remove_dir(&set.dir).is_err() && set.dir.exists() {
            eprintln!("{} is not empty and was left in place", set.dir.display());
        }
    }

    /// Move every file of a set into `destination`, never replacing one.
    fn move_set(&self, set: &SetSource, destination: &Path) -> Result<()> {
        fs::create_dir_all(destination)
            .with_context(|| format!("cannot create {}", destination.display()))?;
        for file in &set.files {
            move_file(file, &destination.join(file_name(file)))?;
        }
        let evidence = set.dir.join(EVIDENCE_FILE);
        if set.held && evidence.is_file() {
            move_file(&evidence, &destination.join(EVIDENCE_FILE))?;
        }
        self.remove_source_dir(set);
        Ok(())
    }

    fn held_for_origin(&self, inbox: &Inbox, origin: &str) -> Option<PathBuf> {
        if origin.is_empty() {
            return None;
        }
        entries(&inbox.root.join(HOLD_DIR))
            .into_iter()
            .find(|path| {
                is_real_dir(path)
                    && read_evidence(path).is_some_and(|evidence| evidence.origin == origin)
            })
    }

    /// Later discs of a held book join it instead of being held separately.
    fn merge_into_hold(&mut self, set: &SetSource, held: &Path) -> Result<()> {
        for file in &set.files {
            let target = held.join(file_name(file));
            if file_name(file) == MARKER_FILE && target.is_file() {
                fs::remove_file(&target)?;
            }
            move_file(file, &target)?;
        }
        self.remove_source_dir(set);
        self.state
            .reevaluate
            .insert(held.to_string_lossy().into_owned());
        println!("Added {} to the held book {}", set.name, held.display());
        Ok(())
    }

    fn move_duplicates(
        &mut self,
        inbox: &Inbox,
        set: &SetSource,
        discs: &[Loaded],
    ) -> Result<bool> {
        let duplicates: Vec<&Loaded> = discs
            .iter()
            .filter(|disc| self.state.processed.contains_key(&disc.sha256))
            .collect();
        if duplicates.is_empty() {
            return Ok(false);
        }
        let destination = unique_destination(&inbox.root.join(DUPLICATE_DIR), &set.name);
        fs::create_dir_all(&destination)?;
        for duplicate in duplicates {
            let earlier = &self.state.processed[&duplicate.sha256];
            println!(
                "{} repeats a disc already imported as {}; preserved in {}",
                duplicate.disc.iso_name,
                earlier.book,
                destination.display()
            );
            for file in disc::companions(&duplicate.path) {
                move_file(&file, &destination.join(file_name(&file)))?;
            }
            write_json_atomic(
                &destination.join(format!("{}.duplicate.json", duplicate.disc.iso_name)),
                &serde_json::json!({
                    "sha256": duplicate.sha256,
                    "alreadyImportedAs": earlier.book,
                    "published": earlier.published,
                    "importedAt": earlier.at,
                }),
            )?;
        }
        if !set.loose && entries(&set.dir).iter().all(|path| !is_iso(path)) {
            // Only the ripper's folder marker can remain; it describes
            // discs that are all preserved elsewhere now.
            let _ = fs::remove_file(set.dir.join(MARKER_FILE));
            self.remove_source_dir(set);
        }
        Ok(true)
    }

    /// Record why a set waits for a person, moving it out of the inbox the
    /// first time. Returns true when files moved.
    fn hold(
        &mut self,
        inbox: &Inbox,
        set: &SetSource,
        discs: &[Loaded],
        held: Held,
    ) -> Result<bool> {
        let Held {
            proposal,
            mut reason,
            identification,
            transient,
        } = held;
        let (directory, moved) = if set.held {
            (set.dir.clone(), false)
        } else {
            let holds = inbox.root.join(HOLD_DIR);
            let directory = unique_destination(&holds, &set.name);
            self.move_set(set, &directory)?;
            (directory, true)
        };
        let directory_key = directory.to_string_lossy().into_owned();
        let mut retry = None;
        if transient {
            let used = self
                .state
                .retries
                .get(&directory_key)
                .map_or(0, |record| record.attempt);
            if let Some(hours) = RETRY_HOURS.get(used) {
                let next_attempt = now() + hours * 3600;
                self.state.retries.insert(
                    directory_key.clone(),
                    RetryRecord {
                        attempt: used + 1,
                        next_attempt,
                    },
                );
                retry = Some(RetryView {
                    attempt: used + 1,
                    of: RETRY_HOURS.len(),
                    next_attempt_at: chrono::DateTime::from_timestamp(next_attempt as i64, 0)
                        .map(|at| at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                        .unwrap_or_default(),
                });
                reason.push_str(&format!(" It is tried again in {hours} h."));
            } else {
                // Keep the record so the count is not started again.
                self.state.retries.insert(
                    directory_key.clone(),
                    RetryRecord {
                        attempt: used,
                        next_attempt: u64::MAX,
                    },
                );
                reason.push_str(
                    " Three later tries did not help; rename the folder to confirm it by hand.",
                );
            }
        } else {
            self.state.retries.remove(&directory_key);
        }
        let confirm_with = confirming_name(proposal.as_ref(), discs.len());
        let mut evidence = Evidence {
            schema_version: 1,
            updated_at: timestamp(),
            origin: if set.held {
                read_evidence(&directory)
                    .map(|old| old.origin)
                    .unwrap_or_default()
            } else {
                set.origin.clone()
            },
            reason: reason.clone(),
            proposal: proposal.clone(),
            confirm_with: confirm_with.clone(),
            how_to_confirm: HOW_TO_CONFIRM.to_string(),
            discs: disc_summaries(discs),
            identification,
            retry,
        };
        let unchanged = read_evidence(&directory).is_some_and(|old| {
            evidence.updated_at.clone_from(&old.updated_at);
            old == evidence
        });
        if !unchanged {
            evidence.updated_at = timestamp();
            write_json_atomic(&directory.join(EVIDENCE_FILE), &evidence)?;
            println!("Holding {} for a person: {reason}", directory.display());
        }
        self.state.reevaluate.remove(&directory_key);
        self.statuses.push(SetStatus {
            inbox: inbox.label.clone(),
            folder: file_name(&directory),
            path: directory_key,
            state: "held",
            message: reason,
            missing_discs: Vec::new(),
            proposal,
            confirm_with: Some(confirm_with),
            discs: discs.len(),
        });
        Ok(moved)
    }

    fn archive(
        &mut self,
        inbox: &Inbox,
        set: &SetSource,
        discs: &[Loaded],
        pending: &Unarchived,
    ) -> Result<()> {
        let destination = unique_destination(&inbox.root.join(PROCESSED_DIR), &set.name);
        self.move_set(set, &destination)?;
        write_json_atomic(&destination.join("import.json"), &pending.report)?;
        let book = pending.report["book"]
            .as_str()
            .unwrap_or(&set.name)
            .to_string();
        for loaded in discs {
            self.state.processed.insert(
                loaded.sha256.clone(),
                Processed {
                    book: book.clone(),
                    published: pending.published.clone(),
                    at: timestamp(),
                },
            );
        }
        self.state.unarchived.remove(&set.key());
        println!("Archived the ISOs of {book} in {}", destination.display());
        Ok(())
    }

    fn publish(
        &mut self,
        inbox: &Inbox,
        set: &SetSource,
        discs: &[Loaded],
        proposal: Proposal,
        order: &[usize],
        identification: Value,
    ) -> Result<bool> {
        let (author_dir, existing) = library_lookup(&inbox.library, &proposal);
        if let Some(existing) = existing {
            let reason = format!(
                "{} by {} is already in the library at {}. Move that folder away, then give this one its confirmWith name to import it.",
                proposal.title,
                proposal.author,
                existing.display()
            );
            let held = Held {
                proposal: Some(proposal),
                reason,
                identification,
                transient: false,
            };
            return self.hold(inbox, set, discs, held);
        }
        let mut folder = safe_component(&proposal.title, "Audiobook");
        if let Some(year) = proposal.year {
            folder.push_str(&format!(" ({year})"));
        }
        let book = format!("{} - {folder}", file_name(&author_dir));
        // Audiobookshelf's own layout for a series: Author/Series/Book N - Title.
        let mut parent = author_dir.clone();
        if let Some(series) = &proposal.series {
            parent = author_dir.join(safe_component(&series.name, "Series"));
            let sequence = safe_component(&series.sequence, "");
            if !sequence.is_empty() {
                folder = format!("Book {sequence} - {folder}");
            }
        }
        let target = parent.join(&folder);

        let iso_bytes: u64 = set
            .isos
            .iter()
            .filter_map(|iso| fs::metadata(iso).ok())
            .map(|m| m.len())
            .sum();
        let needed = iso_bytes + iso_bytes / 4 + (512 << 20);
        let free = fsops::free_bytes(&inbox.library)?;
        if free < needed {
            bail!(
                "not enough free space to build the book ({} MiB free, {} MiB needed)",
                free >> 20,
                needed >> 20
            );
        }

        let staging_root = inbox.library.join(STAGING_DIR);
        fs::create_dir_all(&staging_root)
            .with_context(|| format!("cannot create {}", staging_root.display()))?;
        // Audiobookshelf skips a folder holding a `.ignore` file.
        let _ = fs::write(staging_root.join(".ignore"), "");
        self.counter += 1;
        let staging = staging_root.join(format!("{}-{}", std::process::id(), self.counter));
        fs::create_dir_all(staging.join("work"))?;
        if !proposal.cover_url.is_empty() {
            self.identifier.fetch_cover(
                &proposal.cover_url,
                &staging.join("work").join(build::PROVIDER_COVER),
            );
        }
        let ordered: Vec<(PathBuf, Disc)> = order
            .iter()
            .map(|index| (discs[*index].path.clone(), discs[*index].disc.clone()))
            .collect();

        println!("Building {book} from {} disc(s)", ordered.len());
        let mut last_write = Instant::now() - std::time::Duration::from_secs(10);
        let shown = self.shown.clone();
        let built = {
            let mut progress = |step: &str, percent: f64| {
                if last_write.elapsed().as_secs() >= 2 {
                    last_write = Instant::now();
                    self.write_status(
                        Some(Active {
                            inbox: &inbox.label,
                            folder: &set.name,
                            step,
                            percent,
                        }),
                        &shown,
                    );
                }
            };
            let (work, output) = (staging.join("work"), staging.join("book"));
            let job = build::Job {
                proposal: &proposal,
                discs: &ordered,
                work: &work,
                output: &output,
                speech: self.identifier.parakeet.as_ref().map(|(parakeet, model)| {
                    chapters::Speech {
                        ffmpeg: &self.tools.ffmpeg,
                        parakeet,
                        model,
                        threads: self.identifier.threads,
                        bonsai: self.identifier.bonsai.as_ref(),
                    }
                }),
            };
            build::build(&self.tools, &job, &mut progress, &self.stop)
        };
        let built: Built = match built {
            Ok(built) => built,
            Err(error) => {
                let _ = fs::remove_dir_all(&staging);
                return Err(error);
            }
        };

        let published = fs::create_dir_all(&parent)
            .with_context(|| format!("cannot create {}", parent.display()))
            .and_then(|()| {
                rename_noreplace(&staging.join("book"), &target)
                    .with_context(|| format!("cannot publish {}", target.display()))
            });
        let _ = fs::remove_dir_all(&staging);
        published?;
        println!(
            "Published {} ({}, {:.0} min, {} chapters)",
            target.display(),
            built.audio,
            built.duration_seconds / 60.0,
            built.chapters
        );

        let pending = Unarchived {
            published: target.to_string_lossy().into_owned(),
            report: serde_json::json!({
                "schemaVersion": 1,
                "importedAt": timestamp(),
                "book": book,
                "published": target.to_string_lossy(),
                "proposal": proposal,
                "identification": identification,
                "result": built,
                "discs": order.iter().map(|index| serde_json::json!({
                    "iso": discs[*index].disc.iso_name,
                    "sha256": discs[*index].sha256,
                })).collect::<Vec<_>>(),
            }),
        };
        self.state.unarchived.insert(set.key(), pending.clone());
        self.save()?;
        self.archive(inbox, set, discs, &pending)?;
        Ok(true)
    }

    fn process(&mut self, inbox: &Inbox, set: &SetSource) -> Result<bool> {
        let discs = self.load_discs(&set.isos)?;
        if let Some(pending) = self.state.unarchived.get(&set.key()).cloned() {
            self.archive(inbox, set, &discs, &pending)?;
            return Ok(true);
        }
        if !set.held {
            if self.move_duplicates(inbox, set, &discs)? {
                return Ok(true);
            }
            if let Some(held) = self.held_for_origin(inbox, &set.origin) {
                self.merge_into_hold(set, &held)?;
                return Ok(true);
            }
        }
        let plain: Vec<Disc> = discs.iter().map(|loaded| loaded.disc.clone()).collect();
        let total = if set.loose {
            None
        } else {
            marker_total(&set.dir)
        };
        let key = set.key();
        match decide(&set.name, &plain, total) {
            Decision::Publish {
                mut proposal,
                order,
            } => {
                // The identity is certain; a matching edition only adds to it.
                let runtime: Option<f64> =
                    order.iter().map(|index| discs[*index].disc.seconds).sum();
                let details = match self.identifier.enrich(&mut proposal, runtime) {
                    Ok(details) => details,
                    Err(Unavailable(reason)) => {
                        let record = self.state.deferred.entry(key.clone()).or_default();
                        record.count += 1;
                        if record.count <= ENRICH_ATTEMPTS {
                            record.next_attempt = now() + 900;
                            record.reason = format!(
                                "{reason} Trying again in 15 minutes; after an hour the book is published without provider details."
                            );
                            let message = record.reason.clone();
                            self.note(inbox, set, "waiting", message);
                            return Ok(false);
                        }
                        json!({ "provider": "audible", "matchedBy": "none", "unavailable": reason })
                    }
                };
                self.state.deferred.remove(&key);
                self.publish(inbox, set, &discs, proposal, &order, details)
            }
            Decision::Hold {
                kind,
                proposal,
                reason,
            } if kind != HoldKind::Conflict && self.identifier.can_identify() => {
                let scratch = self.args.state_dir.join("scratch");
                let _ = fs::remove_dir_all(&scratch);
                fs::create_dir_all(&scratch)
                    .with_context(|| format!("cannot create {}", scratch.display()))?;
                self.write_status(
                    Some(Active {
                        inbox: &inbox.label,
                        folder: &set.name,
                        step: "Identifying",
                        percent: 0.0,
                    }),
                    &self.shown,
                );
                let sources: Vec<Source> = discs
                    .iter()
                    .map(|loaded| Source {
                        path: &loaded.path,
                        disc: &loaded.disc,
                        sha256: &loaded.sha256,
                    })
                    .collect();
                let resolution = self.identifier.resolve(
                    &self.tools,
                    Unsettled {
                        kind,
                        proposal,
                        reason,
                    },
                    &sources,
                    &mut self.state.identify,
                    &scratch,
                );
                let _ = fs::remove_dir_all(&scratch);
                match resolution {
                    Resolution::Publish {
                        proposal,
                        order,
                        evidence,
                    } => self.publish(inbox, set, &discs, proposal, &order, evidence),
                    Resolution::Hold {
                        proposal,
                        reason,
                        evidence,
                    } => self.hold(
                        inbox,
                        set,
                        &discs,
                        Held {
                            proposal,
                            reason,
                            identification: evidence,
                            transient: false,
                        },
                    ),
                    Resolution::Retry {
                        proposal,
                        reason,
                        evidence,
                    } => self.hold(
                        inbox,
                        set,
                        &discs,
                        Held {
                            proposal,
                            reason,
                            identification: evidence,
                            transient: true,
                        },
                    ),
                }
            }
            Decision::Hold {
                proposal, reason, ..
            } => self.hold(inbox, set, &discs, Held::plain(proposal, reason)),
            Decision::Wait {
                proposal, message, ..
            } if set.held => self.hold(inbox, set, &discs, Held::plain(Some(proposal), message)),
            Decision::Skip { message } if set.held => {
                self.hold(inbox, set, &discs, Held::plain(None, message))
            }
            Decision::Wait {
                proposal,
                missing,
                message,
            } => {
                self.statuses.push(SetStatus {
                    inbox: inbox.label.clone(),
                    folder: set.name.clone(),
                    path: set.dir.to_string_lossy().into_owned(),
                    state: "waiting",
                    message,
                    missing_discs: missing,
                    proposal: Some(proposal),
                    confirm_with: None,
                    discs: discs.len(),
                });
                Ok(false)
            }
            Decision::Skip { message } => {
                self.note(inbox, set, "skipped", message);
                Ok(false)
            }
        }
    }

    /// Charge a failed attempt; after the last one an inbox set is preserved
    /// in `_Failed` and a held set waits for its next rename.
    fn fail(&mut self, inbox: &Inbox, set: &SetSource, error: &anyhow::Error) -> Result<bool> {
        let message = format!("{error:#}");
        let key = set.key();
        let record = self.state.sets.entry(key.clone()).or_default();
        record.attempts += 1;
        record.error.clone_from(&message);
        record.next_attempt = now()
            + self
                .args
                .retry_seconds
                .saturating_mul(u64::from(record.attempts));
        let attempts = record.attempts;
        eprintln!("Attempt {attempts} on {} failed: {message}", set.name);
        if attempts < self.args.max_attempts {
            self.note(inbox, set, "retrying", message);
            return Ok(false);
        }
        if set.held {
            self.note(
                inbox,
                set,
                "held",
                format!(
                    "The import failed {attempts} times: {message} Rename the folder to try again."
                ),
            );
            return Ok(false);
        }
        let destination = unique_destination(&inbox.root.join(FAILED_DIR), &set.name);
        self.move_set(set, &destination)?;
        fs::write(
            destination.join("error.txt"),
            format!(
                "The import failed {attempts} times.\n\n{message}\n\nFix the cause, then move this folder back into the inbox to try again.\n"
            ),
        )?;
        self.state.sets.remove(&key);
        eprintln!("Preserved {} in {}", set.name, destination.display());
        Ok(true)
    }

    fn handle(&mut self, inbox: &Inbox, set: SetSource) -> Result<bool> {
        if !self.settled(&set.files) {
            self.note(
                inbox,
                &set,
                "settling",
                "Waiting for the upload to finish.".to_string(),
            );
            return Ok(false);
        }
        let key = set.key();
        if let Some(record) = self.state.sets.get(&key).cloned() {
            if set.held && record.attempts >= self.args.max_attempts {
                self.note(
                    inbox,
                    &set,
                    "held",
                    format!(
                        "The import failed: {} Rename the folder to try again.",
                        record.error
                    ),
                );
                return Ok(false);
            }
            if record.next_attempt > now() {
                self.note(inbox, &set, "retrying", record.error);
                return Ok(false);
            }
        }
        if let Some(deferred) = self.state.deferred.get(&key).cloned()
            && deferred.next_attempt > now()
        {
            self.note(inbox, &set, "waiting", deferred.reason);
            return Ok(false);
        }
        let retry_due = self
            .state
            .retries
            .get(&key)
            .is_some_and(|record| record.next_attempt <= now());
        if set.held
            && !retry_due
            && !self.state.reevaluate.contains(&key)
            && !self.state.unarchived.contains_key(&key)
            && !parse_folder_name(&set.name).is_some_and(|claim| claim.discs.is_some())
        {
            let evidence = read_evidence(&set.dir);
            self.statuses.push(SetStatus {
                inbox: inbox.label.clone(),
                folder: set.name.clone(),
                path: set.dir.to_string_lossy().into_owned(),
                state: "held",
                message: evidence
                    .as_ref()
                    .map(|evidence| evidence.reason.clone())
                    .unwrap_or_else(|| "Waiting for a person to name this book.".to_string()),
                missing_discs: Vec::new(),
                proposal: evidence
                    .as_ref()
                    .and_then(|evidence| evidence.proposal.clone()),
                confirm_with: evidence.map(|evidence| evidence.confirm_with),
                discs: set.isos.len(),
            });
            return Ok(false);
        }
        match self.process(inbox, &set) {
            Ok(worked) => {
                self.state.sets.remove(&key);
                Ok(worked)
            }
            Err(error) if error.is::<Stopped>() => Err(error),
            Err(error) => self.fail(inbox, &set, &error),
        }
    }

    fn pass(&mut self, inboxes: &[Inbox]) -> Result<bool> {
        self.statuses.clear();
        self.prune();
        let mut worked = false;
        for inbox in inboxes {
            let mut sets = discover_held(&inbox.root);
            sets.extend(discover_sets(&inbox.root));
            for set in sets {
                if self.stop.load(Ordering::Relaxed) {
                    return Err(Stopped.into());
                }
                worked |= self.handle(inbox, set)?;
                self.save()?;
            }
        }
        self.shown.clone_from(&self.statuses);
        self.write_status(None, &self.shown);
        Ok(worked)
    }
}

/// Diagnostic: what chapter detection hears in a set of audio files.
fn find_chapters(
    args: &Args,
    tools: &Tools,
    identifier: &Identifier,
    stop: &AtomicBool,
) -> Result<()> {
    let (parakeet, model) = identifier
        .parakeet
        .as_ref()
        .context("--find-chapters needs --parakeet and --parakeet-model")?;
    let mut pieces = Vec::new();
    for file in &args.find_chapters {
        let seconds = build::media_seconds(tools, file)
            .with_context(|| format!("cannot read the length of {}", file.display()))?;
        pieces.push((file.clone(), seconds));
    }
    let scratch = args.state_dir.join("scratch");
    fs::create_dir_all(&scratch)?;
    let speech = chapters::Speech {
        ffmpeg: &tools.ffmpeg,
        parakeet,
        model,
        threads: identifier.threads,
        bonsai: identifier.bonsai.as_ref(),
    };
    let found = chapters::spoken_chapters(
        &speech,
        &pieces,
        &scratch,
        &mut |step, percent| eprintln!("{step}: {percent:.0}%"),
        stop,
    );
    let _ = fs::remove_dir_all(&scratch);
    match found? {
        Some(found) => println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({ "chapters": found.chapters, "details": found.note })
            )?
        ),
        None => println!("No believable run of chapter headings was heard."),
    }
    Ok(())
}

fn run() -> Result<()> {
    let args = Args::parse();
    fs::create_dir_all(&args.state_dir)
        .with_context(|| format!("cannot create {}", args.state_dir.display()))?;
    let lock = fs::File::create(args.state_dir.join("audio-import.lock"))?;
    if fs2::FileExt::try_lock_exclusive(&lock).is_err() {
        println!("Another audio import is already running.");
        return Ok(());
    }
    let stop = Arc::new(AtomicBool::new(false));
    {
        let stop = Arc::clone(&stop);
        ctrlc::set_handler(move || stop.store(true, Ordering::Relaxed))
            .context("cannot install the stop handler")?;
    }
    let state_path = args.state_dir.join("audio-import.json");
    let state = match fs::read_to_string(&state_path) {
        Ok(text) => serde_json::from_str(&text).with_context(|| {
            format!(
                "{} is not valid; move it away to start afresh",
                state_path.display()
            )
        })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => State::default(),
        Err(error) => return Err(error).context("cannot read the import state"),
    };
    let tools = Tools {
        ffmpeg: args.ffmpeg.clone(),
        ffprobe: args.ffprobe.clone(),
        sevenzip: args.sevenzip.clone(),
    };
    let identifier = Identifier {
        bonsai: args
            .bonsai_url
            .as_deref()
            .map(|url| {
                bonsai::Bonsai::new(url, &args.bonsai_model, std::time::Duration::from_secs(300))
            })
            .transpose()?,
        parakeet: args.parakeet.clone().zip(args.parakeet_model.clone()),
        threads: args.identify_threads,
        socket: args.provider_socket.clone(),
    };
    let _ = fs::remove_dir_all(args.state_dir.join("scratch"));
    if !args.find_chapters.is_empty() {
        return find_chapters(&args, &tools, &identifier, &stop);
    }
    let inboxes = discover_inboxes(&args)?;
    if inboxes.is_empty() {
        bail!("no inbox was given and no user inbox exists");
    }
    let mut worker = Worker {
        args,
        tools,
        identifier,
        state,
        state_path,
        stop,
        statuses: Vec::new(),
        shown: Vec::new(),
        counter: 0,
    };
    worker.clean_stale_staging(&inboxes);
    // Each unit of work can make another set ready (a late disc completes a
    // held book), so repeat until a pass changes nothing.
    for _ in 0..500 {
        let worked = worker.pass(&inboxes);
        worker.save()?;
        if !worked? {
            break;
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) if error.is::<Stopped>() => {
            eprintln!("Stopped; unfinished work resumes on the next run.");
            ExitCode::from(130)
        }
        Err(error) => {
            eprintln!("audio-import: {error:#}");
            ExitCode::FAILURE
        }
    }
}
