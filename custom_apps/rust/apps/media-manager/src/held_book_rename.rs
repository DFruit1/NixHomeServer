//! Confirming a held audiobook from the Conversions page.
//!
//! The audio CD importer holds a set of discs it cannot settle in
//! `_ISO/_AudioCDs/_NeedsIdentification/<folder>/` with an `identify.json`,
//! and imports the book once that folder is named
//! `Author - Title (Year) [N discs]`. As with held DVDs (decision 0001), the
//! web service only checks the request and queues it; the filesystem broker
//! repeats every check and renames the folder within that one directory,
//! never replacing an existing entry.
use crate::{
    config::{AppConfig, Identity, MutationMode},
    held_disc_rename::{Refusal, NEEDS_IDENTIFICATION},
    transcription::fs::Dir,
};
use serde::{Deserialize, Serialize};
use std::os::unix::fs::MetadataExt;

const REQUESTS: &str = "audiobook-renames";
const MAX_NAME_BYTES: usize = 200;
/// Results stay visible on the page for this long after the broker acts.
const RESULT_SECONDS: u64 = 24 * 60 * 60;
const APPLIED_NOTICE_SECONDS: u64 = 10 * 60;
const EXAMPLE: &str = "Terry Pratchett - Guards! Guards! (1989) [6 discs]";

fn invalid(message: impl Into<String>) -> Refusal {
    Refusal::Invalid(message.into())
}

/// Parse `Author - Title (Year) [N discs]`, the form the importer accepts as
/// a person's statement of a book's identity and completeness. The year is
/// optional, and `[music]` before the disc tag marks an album
/// (`Artist - Album (Year) [music] [N discs]`). Returns the number of discs
/// the name states.
pub fn parse_book_name(name: &str) -> Result<u32, Refusal> {
    let pattern = format!("Use the author, title and number of discs, such as {EXAMPLE}");
    if name.is_empty() {
        return Err(invalid(format!("{pattern}.")));
    }
    if name.trim() != name {
        return Err(invalid(format!(
            "Remove spaces from the start and end. {pattern}."
        )));
    }
    if name.starts_with('.') {
        return Err(invalid("The name must not start with a dot."));
    }
    if name.len() > MAX_NAME_BYTES {
        return Err(invalid(format!(
            "Use a name of at most {MAX_NAME_BYTES} bytes."
        )));
    }
    if let Some(bad) = name
        .chars()
        .find(|c| c.is_control() || "<>:\"/\\|?*".contains(*c))
    {
        let shown = if bad.is_control() {
            "control characters".to_owned()
        } else {
            format!("“{bad}”")
        };
        return Err(invalid(format!("Folder names cannot contain {shown}.")));
    }
    let tagged = name
        .strip_suffix(']')
        .and_then(|rest| rest.rsplit_once(" ["))
        .and_then(|(book, tag)| {
            let count = tag
                .strip_suffix(" discs")
                .or_else(|| tag.strip_suffix(" disc"))?;
            let discs = count
                .parse::<u32>()
                .ok()
                .filter(|discs| (1..=99).contains(discs))?;
            Some((book.trim_end(), discs))
        });
    let tagged = tagged.map(|(book, discs)| {
        let book = book.strip_suffix(" [music]").map_or(book, str::trim_end);
        (book, discs)
    });
    let Some((mut book, discs)) = tagged else {
        return Err(invalid(format!(
            "End the name with the number of discs in square brackets. {pattern}."
        )));
    };
    if let Some(open) = book.rfind(" (").filter(|_| book.ends_with(')')) {
        let year = &book[open + 2..book.len() - 1];
        if year.len() == 4 && year.bytes().all(|byte| byte.is_ascii_digit()) {
            book = book[..open].trim_end();
        }
    }
    match book.split_once(" - ") {
        Some((author, title)) if !author.trim().is_empty() && !title.trim().is_empty() => Ok(discs),
        _ => Err(invalid(format!(
            "Separate the author and the title with “ - ”. {pattern}."
        ))),
    }
}

fn valid_folder_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('.')
        && !name.contains(['/', '\\', '\0'])
}

fn gone() -> Refusal {
    Refusal::Missing("This book is no longer waiting. Refresh to see its current name.".into())
}

/// Every check the rename needs, repeated by the broker just before it acts.
/// Returns the held folder's inode.
pub fn check(folder: &Dir, from: &str, to: &str, expected: Option<u64>) -> Result<u64, Refusal> {
    if !valid_folder_name(from) {
        return Err(Refusal::Missing("That book is not in the folder.".into()));
    }
    let discs = parse_book_name(to)?;
    if from == to {
        return Err(invalid("The folder already has that name."));
    }
    let held = folder.child(from).map_err(|_| gone())?;
    let inode = held.0.metadata().map_err(|_| gone())?.ino();
    if expected.is_some_and(|expected| expected != inode) {
        return Err(Refusal::Conflict(
            "This book changed since the page loaded. Refresh and try again.".into(),
        ));
    }
    let present = held
        .names()
        .map_err(|_| Refusal::Conflict("The book's folder could not be read.".into()))?
        .iter()
        .filter(|name| name.to_ascii_lowercase().ends_with(".iso"))
        .count();
    if present != discs as usize {
        return Err(invalid(format!(
            "The name says {discs} disc{}, but the folder holds {present}. Name the discs that are there, or wait for the rest.",
            if discs == 1 { "" } else { "s" },
        )));
    }
    let names = folder
        .names()
        .map_err(|_| Refusal::Conflict("The folder could not be read.".into()))?;
    if names
        .iter()
        .any(|name| name != from && name.eq_ignore_ascii_case(to))
    {
        return Err(Refusal::Conflict(format!(
            "{to} already exists in {NEEDS_IDENTIFICATION}. Choose another name."
        )));
    }
    Ok(inode)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub id: String,
    pub owner: String,
    pub from: String,
    pub to: String,
    /// The held folder's inode when the request was queued.
    pub inode: u64,
    pub created_at: u64,
    /// `queued`, then `applied` or `failed`.
    pub state: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub updated_at: u64,
}

fn requests_dir(config: &AppConfig) -> Result<Dir, String> {
    Dir::open(&config.state_dir)?.create_shared(REQUESTS)
}
fn needs_folder(config: &AppConfig) -> Result<Dir, String> {
    Dir::open(&config.audio_inbox_path())?.child(NEEDS_IDENTIFICATION)
}
fn requests(dir: &Dir) -> Vec<Request> {
    let mut found: Vec<Request> = dir
        .names()
        .unwrap_or_default()
        .into_iter()
        .filter(|name| name.ends_with(".json"))
        .filter_map(|name| dir.read(&name, 64 * 1024).ok())
        .filter_map(|bytes| serde_json::from_slice(&bytes).ok())
        .collect();
    found.sort_by_key(|request: &Request| (request.created_at, request.id.clone()));
    found
}
fn save(dir: &Dir, request: &Request) -> Result<(), String> {
    dir.write(
        &format!("{}.json", request.id),
        &serde_json::to_vec(request).map_err(|e| e.to_string())?,
    )
}

/// Web side: check the request and queue it for the broker.
pub fn queue(
    config: &AppConfig,
    identity: &Identity,
    from: &str,
    to: &str,
    expected: Option<u64>,
) -> Result<Request, Refusal> {
    let folder = needs_folder(config)
        .map_err(|_| Refusal::Missing("The identification folder is unavailable.".into()))?;
    let inode = check(&folder, from, to, expected)?;
    let dir = requests_dir(config)
        .map_err(|_| Refusal::Conflict("The rename could not be queued.".into()))?;
    for earlier in requests(&dir) {
        if earlier.state == "queued" && (earlier.from == from || earlier.to == to) {
            return Err(Refusal::Conflict(
                "A rename of this book is already waiting.".into(),
            ));
        }
        if earlier.from == from && earlier.state == "failed" {
            // The new attempt replaces the reason shown for the last one.
            let _ = dir.remove(&format!("{}.json", earlier.id));
        }
    }
    let now = crate::transcription::worker::now();
    let request = Request {
        id: homelab_common::random_hex(16),
        owner: identity.username.clone(),
        from: from.to_owned(),
        to: to.to_owned(),
        inode,
        created_at: now,
        state: "queued".into(),
        error: None,
        updated_at: now,
    };
    save(&dir, &request)
        .map_err(|_| Refusal::Conflict("The rename could not be queued.".into()))?;
    Ok(request)
}

/// Recent requests for the listing: a queued or failed request under the
/// folder's original name, a recent success under the new one.
pub fn statuses(config: &AppConfig) -> Vec<Request> {
    let Ok(dir) = Dir::open(&config.state_dir).and_then(|dir| dir.child(REQUESTS)) else {
        return Vec::new();
    };
    let now = crate::transcription::worker::now();
    requests(&dir)
        .into_iter()
        .filter(|request| match request.state.as_str() {
            "applied" => now.saturating_sub(request.updated_at) <= APPLIED_NOTICE_SECONDS,
            _ => now.saturating_sub(request.updated_at) <= RESULT_SECONDS,
        })
        .collect()
}

/// Broker side, under its exclusive lock: apply queued renames, oldest first.
pub fn reconcile(config: &AppConfig) -> Result<(), String> {
    if config.mutation_mode != MutationMode::Enabled {
        return Ok(());
    }
    // No request has ever been queued on a server without the importer.
    let Ok(dir) = Dir::open(&config.state_dir).and_then(|dir| dir.child(REQUESTS)) else {
        return Ok(());
    };
    let now = crate::transcription::worker::now();
    let folder = needs_folder(config);
    for mut request in requests(&dir) {
        if request.state != "queued" {
            if now.saturating_sub(request.updated_at) > RESULT_SECONDS {
                let _ = dir.remove(&format!("{}.json", request.id));
            }
            continue;
        }
        let result = match &folder {
            Ok(folder) => apply(folder, &request),
            Err(_) => Err("The identification folder is unavailable.".to_owned()),
        };
        request.updated_at = now;
        match result {
            Ok(()) => {
                request.state = "applied".into();
                log("info", "held_book_renamed", &request, None);
            }
            Err(error) => {
                request.state = "failed".into();
                log("error", "held_book_rename_failed", &request, Some(&error));
                request.error = Some(error);
            }
        }
        save(&dir, &request)?;
    }
    Ok(())
}

/// One rename of one folder. A broker stopped after renaming but before
/// saving the result finds the folder already under the new name with the
/// recorded inode, and reports the rename as applied.
pub fn apply(folder: &Dir, request: &Request) -> Result<(), String> {
    let inode_of = |name: &str| {
        folder
            .child(name)
            .ok()
            .and_then(|dir| dir.0.metadata().ok())
            .map(|metadata| metadata.ino())
    };
    if inode_of(&request.from).is_none() && inode_of(&request.to) == Some(request.inode) {
        return Ok(());
    }
    check(folder, &request.from, &request.to, Some(request.inode))
        .map_err(|refusal| refusal.message().to_owned())?;
    folder.rename_new(&request.to, folder, &request.from)
}

fn log(level: &str, event: &str, request: &Request, error: Option<&str>) {
    eprintln!(
        "{}",
        serde_json::json!({
            "level": level,
            "service": "media-manager-broker",
            "event": event,
            "from": request.from,
            "to": request.to,
            "owner": request.owner,
            "error": error,
        })
    );
}
