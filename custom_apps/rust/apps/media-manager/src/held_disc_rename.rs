//! Confirming a held TV disc from the Conversions page.
//!
//! MKVMaker holds a disc it cannot identify in `_ISO/_DVDs/_NeedsIdentification`
//! with `<name>.iso.identify.json` evidence, and publishes the held videos once
//! the ISO is renamed to a Jellyfin TV name with its episode range. The web
//! service stays filesystem read-only (decision 0001): it checks the request and
//! queues it; the filesystem broker repeats every check and renames the ISO and
//! its evidence within that one folder, never replacing an existing entry.
//! The importer keys a held disc by inode and size, so a rename keeps it.
use crate::{
    config::{AppConfig, Identity, MutationMode},
    transcription::fs::Dir,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::unix::fs::MetadataExt;

pub const NEEDS_IDENTIFICATION: &str = "_NeedsIdentification";
const REQUESTS: &str = "identify-renames";
const EVIDENCE_SUFFIX: &str = ".identify.json";
const MAX_EVIDENCE_BYTES: u64 = 64 * 1024;
/// Leaves room for the evidence suffix within a path component.
const MAX_NAME_BYTES: usize = 200;
/// Results stay visible on the page for this long after the broker acts.
const RESULT_SECONDS: u64 = 24 * 60 * 60;
pub const APPLIED_NOTICE_SECONDS: u64 = 10 * 60;
const MODIFIED_TOLERANCE_NS: u64 = 1_000;
const EXAMPLE: &str = "Show (1978) S01E05-E06.iso";

#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The requested name is not one the importer would publish.
    Invalid(String),
    /// The disc or folder changed, or the name is taken.
    Conflict(String),
    /// The held disc is no longer in the folder.
    Missing(String),
}
impl Refusal {
    pub fn message(&self) -> &str {
        match self {
            Self::Invalid(message) | Self::Conflict(message) | Self::Missing(message) => message,
        }
    }
}
fn invalid(message: impl Into<String>) -> Refusal {
    Refusal::Invalid(message.into())
}

/// The episodes a confirmed name assigns to the held videos.
#[derive(Debug, PartialEq, Eq)]
pub struct EpisodeName {
    pub series: String,
    pub season: u32,
    pub first: u32,
    pub last: u32,
}

/// Parse `Series (Year) [provider-id] SxxEyy[-Ezz].iso`, the form the importer
/// accepts, with the year and provider tag optional. Anything else is refused
/// rather than left for the importer to interpret differently.
pub fn parse_episode_name(name: &str) -> Result<EpisodeName, Refusal> {
    let pattern = format!("Use the show, season and episodes, such as {EXAMPLE}");
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
        return Err(invalid(format!("File names cannot contain {shown}.")));
    }
    let Some(stem) = name
        .len()
        .checked_sub(4)
        .filter(|&end| name.is_char_boundary(end) && name[end..].eq_ignore_ascii_case(".iso"))
        .map(|end| &name[..end])
    else {
        return Err(invalid(format!("End the name with .iso. {pattern}.")));
    };
    let (prefix, token) = stem.rsplit_once(' ').unwrap_or(("", stem));
    let (season, first, last) = parse_episodes(token)
        .ok_or_else(|| invalid(format!("End with the season and episodes. {pattern}.")))?;
    let mut series = prefix.trim_end();
    if let Some(open) = series.rfind(" [").filter(|_| series.ends_with(']')) {
        if !valid_provider(&series[open + 2..series.len() - 1]) {
            return Err(invalid(
                "Write the provider tag as [tvdbid-…], [tmdbid-…] or [imdbid-…].",
            ));
        }
        series = series[..open].trim_end();
    }
    if let Some(open) = series.rfind(" (").filter(|_| series.ends_with(')')) {
        let year = &series[open + 2..series.len() - 1];
        if year.len() == 4
            && year.bytes().all(|b| b.is_ascii_digit())
            && (year.starts_with("19") || year.starts_with("20"))
        {
            series = series[..open].trim_end();
        }
    }
    if series.is_empty() {
        return Err(invalid(format!("Start with the show's name. {pattern}.")));
    }
    if series.contains(['[', ']', '{', '}']) {
        return Err(invalid(
            "Put the year and provider tag after the show's name, as in Show (1978) [tvdbid-78289] S01E05.iso.",
        ));
    }
    if has_season_marker(series) {
        return Err(invalid(
            "Give the season once, at the end, as in Show S01E05-E06.iso.",
        ));
    }
    if last < first {
        return Err(invalid(format!(
            "The episode range E{first:02}-E{last:02} runs backwards."
        )));
    }
    Ok(EpisodeName {
        series: series.to_owned(),
        season,
        first,
        last,
    })
}

/// `S01E05`, `S01E05-E06` or `S01E05-06`, case-insensitive.
fn parse_episodes(token: &str) -> Option<(u32, u32, u32)> {
    let digits = |text: &str, max: usize| -> Option<(u32, usize)> {
        let count = text.bytes().take_while(u8::is_ascii_digit).count();
        (1..=max)
            .contains(&count)
            .then(|| text[..count].parse().ok().map(|n| (n, count)))
            .flatten()
    };
    let rest = token.strip_prefix(['S', 's'])?;
    let (season, used) = digits(rest, 2)?;
    let rest = rest[used..].strip_prefix(['E', 'e'])?;
    let (first, used) = digits(rest, 3)?;
    let rest = &rest[used..];
    let last = if rest.is_empty() {
        first
    } else {
        let rest = rest.strip_prefix('-')?;
        let rest = rest.strip_prefix(['E', 'e']).unwrap_or(rest);
        let (last, used) = digits(rest, 3)?;
        if used != rest.len() {
            return None;
        }
        last
    };
    (first >= 1).then_some((season, first, last))
}

fn valid_provider(tag: &str) -> bool {
    tag.split_once('-').is_some_and(|(provider, value)| {
        ["tvdbid", "tmdbid", "imdbid"]
            .iter()
            .any(|known| provider.eq_ignore_ascii_case(known))
            && !value.is_empty()
            && value.bytes().all(|b| b.is_ascii_alphanumeric())
    })
}

/// The importer reads the first `S<n>`/`Season <n>` it finds, so one in the
/// show's name would override the episodes given at the end.
fn has_season_marker(series: &str) -> bool {
    let lower = series.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    (0..bytes.len()).any(|start| {
        if start > 0 && bytes[start - 1].is_ascii_alphanumeric() {
            return false;
        }
        ["season", "s"].iter().any(|marker| {
            lower[start..].starts_with(marker) && {
                let after = lower[start + marker.len()..].trim_start_matches([' ', '.', '_', '-']);
                after.starts_with(|c: char| c.is_ascii_digit())
            }
        })
    })
}

/// The ISO's identity when the page listed it. Size and modification time
/// come from the page; the inode is recorded when the request is queued.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Fingerprint {
    pub size_bytes: u64,
    pub modified_ns: i64,
    #[serde(default)]
    pub inode: Option<u64>,
}
fn fingerprint_of(metadata: &std::fs::Metadata) -> Fingerprint {
    Fingerprint {
        size_bytes: metadata.len(),
        modified_ns: metadata
            .mtime()
            .saturating_mul(1_000_000_000)
            .saturating_add(metadata.mtime_nsec()),
        inode: Some(metadata.ino()),
    }
}

fn valid_held_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('.')
        && !name.contains(['/', '\\', '\0'])
        && name.to_ascii_lowercase().ends_with(".iso")
}

/// Every check the rename needs, repeated by the broker just before it acts.
/// Returns the ISO's current fingerprint.
pub fn check(
    folder: &Dir,
    from: &str,
    to: &str,
    expected: &Fingerprint,
) -> Result<Fingerprint, Refusal> {
    if !valid_held_name(from) {
        return Err(Refusal::Missing("That disc is not in the folder.".into()));
    }
    let episodes = parse_episode_name(to)?;
    if from == to {
        return Err(invalid("The disc already has that name."));
    }
    let iso = folder.file(from).map_err(|_| {
        Refusal::Missing("This disc is no longer waiting. Refresh to see its current name.".into())
    })?;
    let current = fingerprint_of(&iso.metadata().map_err(|_| {
        Refusal::Missing("This disc is no longer waiting. Refresh to see its current name.".into())
    })?);
    // Browsers hold the nanosecond time as a double, which keeps it only to
    // a few hundred nanoseconds; a real change moves it far further.
    if current.size_bytes != expected.size_bytes
        || current.modified_ns.abs_diff(expected.modified_ns) > MODIFIED_TOLERANCE_NS
        || expected
            .inode
            .is_some_and(|inode| Some(inode) != current.inode)
    {
        return Err(Refusal::Conflict(
            "This disc changed since the page loaded. Refresh and try again.".into(),
        ));
    }
    let held = held_count(folder, from)?;
    let named = episodes.last - episodes.first + 1;
    if named as usize != held {
        let example = if held == 1 {
            format!("S{:02}E{:02}", episodes.season, episodes.first)
        } else {
            format!(
                "S{:02}E{:02}-E{:02}",
                episodes.season,
                episodes.first,
                episodes.first as usize + held - 1
            )
        };
        return Err(invalid(format!(
            "The name covers {named} episode{}, but this disc holds {held} video{}. Name {}, e.g. {example}.",
            plural(named as usize),
            plural(held),
            if held == 1 { "one episode" } else { "the full range" },
        )));
    }
    let evidence_to = format!("{to}{EVIDENCE_SUFFIX}");
    let names = folder
        .names()
        .map_err(|_| Refusal::Conflict("The folder could not be read.".into()))?;
    if names.iter().any(|name| {
        name != from
            && name != &format!("{from}{EVIDENCE_SUFFIX}")
            && (name.eq_ignore_ascii_case(to) || name.eq_ignore_ascii_case(&evidence_to))
    }) {
        return Err(Refusal::Conflict(format!(
            "{to} already exists in {NEEDS_IDENTIFICATION}. Choose another name."
        )));
    }
    Ok(current)
}
fn plural(count: usize) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}

/// The number of encoded videos the importer held for this ISO.
fn held_count(folder: &Dir, iso: &str) -> Result<usize, Refusal> {
    let missing = || {
        Refusal::Conflict(
            "This disc's identification record is missing, so its held videos cannot be matched. Rename it in Files instead.".into(),
        )
    };
    let bytes = folder
        .read(&format!("{iso}{EVIDENCE_SUFFIX}"), MAX_EVIDENCE_BYTES)
        .map_err(|_| missing())?;
    let evidence: Value = serde_json::from_slice(&bytes).map_err(|_| missing())?;
    match evidence["heldFiles"].as_array() {
        Some(files) if !files.is_empty() => Ok(files.len()),
        _ => Err(missing()),
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub id: String,
    pub owner: String,
    pub from: String,
    pub to: String,
    pub fingerprint: Fingerprint,
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
    Dir::open(&config.dvd_inbox_path())?.child(NEEDS_IDENTIFICATION)
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
    expected: Fingerprint,
) -> Result<Request, Refusal> {
    let folder = needs_folder(config)
        .map_err(|_| Refusal::Missing("The identification folder is unavailable.".into()))?;
    let current = check(
        &folder,
        from,
        to,
        &Fingerprint {
            inode: None,
            ..expected
        },
    )?;
    let dir = requests_dir(config)
        .map_err(|_| Refusal::Conflict("The rename could not be queued.".into()))?;
    for earlier in requests(&dir) {
        if earlier.state == "queued" && (earlier.from == from || earlier.to == to) {
            return Err(Refusal::Conflict(
                "A rename of this disc is already waiting.".into(),
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
        fingerprint: current,
        created_at: now,
        state: "queued".into(),
        error: None,
        updated_at: now,
    };
    save(&dir, &request)
        .map_err(|_| Refusal::Conflict("The rename could not be queued.".into()))?;
    Ok(request)
}

/// The latest request per held ISO name, for the inbox listing: a queued or
/// failed request under its original name, a recent success under the new one.
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
    let dir = requests_dir(config)?;
    let now = crate::transcription::worker::now();
    let pending = requests(&dir);
    if pending.is_empty() {
        return Ok(());
    }
    let folder = needs_folder(config);
    for mut request in pending {
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
                log("info", "held_disc_renamed", &request, None);
            }
            Err(error) => {
                request.state = "failed".into();
                log("error", "held_disc_rename_failed", &request, Some(&error));
                request.error = Some(error);
            }
        }
        save(&dir, &request)?;
    }
    Ok(())
}

/// Rename the evidence first: until the ISO carries an episode name the
/// importer ignores it, so it never sees a renamed ISO without its evidence
/// beside it. A failed ISO rename puts the evidence back.
///
/// A broker stopped between the two renames (or before saving the result)
/// is resumed on the next tick: evidence already under the new name beside
/// the unrenamed ISO is put back and the checks run again, and a rename that
/// fully happened is reported as applied.
pub fn apply(folder: &Dir, request: &Request) -> Result<(), String> {
    let evidence_from = format!("{}{EVIDENCE_SUFFIX}", request.from);
    let evidence_to = format!("{}{EVIDENCE_SUFFIX}", request.to);
    let present = |name: &str| folder.file(name).is_ok();
    if !present(&evidence_from) && present(&evidence_to) {
        if present(&request.from) && !present(&request.to) {
            folder.rename_new(&evidence_from, folder, &evidence_to)?;
        } else if !present(&request.from) && renamed_disc_matches(folder, request) {
            return Ok(());
        }
    }
    check(folder, &request.from, &request.to, &request.fingerprint)
        .map_err(|refusal| refusal.message().to_owned())?;
    folder.rename_new(&evidence_to, folder, &evidence_from)?;
    if let Err(error) = folder.rename_new(&request.to, folder, &request.from) {
        if folder
            .rename_new(&evidence_from, folder, &evidence_to)
            .is_err()
        {
            return Err(format!(
                "{error} The identification record is now named {evidence_to}."
            ));
        }
        return Err(error);
    }
    Ok(())
}

/// The ISO already carries the requested name and is the disc the request
/// was made for (same size and time, and inode when recorded).
fn renamed_disc_matches(folder: &Dir, request: &Request) -> bool {
    let Ok(metadata) = folder
        .file(&request.to)
        .and_then(|file| file.metadata().map_err(|error| error.to_string()))
    else {
        return false;
    };
    let current = fingerprint_of(&metadata);
    let expected = &request.fingerprint;
    current.size_bytes == expected.size_bytes
        && current.modified_ns.abs_diff(expected.modified_ns) <= MODIFIED_TOLERANCE_NS
        && expected
            .inode
            .is_none_or(|inode| Some(inode) == current.inode)
}

fn log(level: &str, event: &str, request: &Request, error: Option<&str>) {
    eprintln!(
        "{}",
        serde_json::json!({
            "level": level,
            "service": "media-manager-broker",
            "event": event,
            "detail": {
                "requestId": request.id,
                "owner": request.owner,
                "from": request.from,
                "to": request.to,
                "error": error,
            },
        })
    );
}

#[cfg(test)]
mod tests {
    //! Renames move people's discs, so the refusals are pinned: a wrong
    //! episode count, an existing name, a path or hidden name, or a disc
    //! that changed must leave the folder untouched.
    use super::*;
    use std::path::Path;

    fn held(root: &Path, iso: &str, videos: usize) -> Fingerprint {
        std::fs::write(root.join(iso), b"iso").unwrap();
        let files: Vec<String> = (0..videos).map(|n| format!("/held/{n}.mkv")).collect();
        std::fs::write(
            root.join(format!("{iso}{EVIDENCE_SUFFIX}")),
            serde_json::to_vec(&serde_json::json!({ "heldFiles": files })).unwrap(),
        )
        .unwrap();
        let mut print = fingerprint_of(&std::fs::metadata(root.join(iso)).unwrap());
        print.inode = None;
        print
    }
    fn request(from: &str, to: &str, fingerprint: Fingerprint) -> Request {
        Request {
            id: "r".into(),
            owner: "alice".into(),
            from: from.into(),
            to: to.into(),
            fingerprint,
            created_at: 0,
            state: "queued".into(),
            error: None,
            updated_at: 0,
        }
    }

    #[test]
    fn accepts_the_importers_names() {
        assert_eq!(
            parse_episode_name(
                "All Creatures Great and Small (1978) [tvdbid-78289] S01E05-E06.iso"
            ),
            Ok(EpisodeName {
                series: "All Creatures Great and Small".into(),
                season: 1,
                first: 5,
                last: 6
            })
        );
        let special = parse_episode_name("Show S00E03.iso").unwrap();
        assert_eq!((special.season, special.first, special.last), (0, 3, 3));
        assert!(parse_episode_name("Rumpole of the Bailey (1978) s02e04-06.ISO").is_ok());
    }

    #[test]
    fn refuses_paths_hidden_and_malformed_names() {
        for name in [
            "../Show S01E01.iso",
            "sub/Show S01E01.iso",
            "Show\\S01E01.iso",
            ".Show S01E01.iso",
            " Show S01E01.iso",
            "Show S01E01.mkv",
            "Show.iso",
            "S01E01.iso",
            "Show S01E06-E05.iso",
            "Show S01E00.iso",
            "Season 2 Show S01E01.iso",
            "Show [tvdbid-] S01E01.iso",
            "Show S01E05-E06 extra.iso",
            "Show\u{7}S01E01.iso",
        ] {
            assert!(
                matches!(parse_episode_name(name), Err(Refusal::Invalid(_))),
                "{name} should be refused"
            );
        }
    }

    #[test]
    fn renames_iso_and_evidence_when_the_range_matches() {
        let temp = tempfile::tempdir().unwrap();
        let print = held(temp.path(), "DISC.iso", 2);
        let folder = Dir::open(temp.path()).unwrap();
        apply(&folder, &request("DISC.iso", "Show S01E05-E06.iso", print)).unwrap();
        assert!(temp.path().join("Show S01E05-E06.iso").is_file());
        assert!(temp
            .path()
            .join("Show S01E05-E06.iso.identify.json")
            .is_file());
        assert!(!temp.path().join("DISC.iso").exists());
    }

    #[test]
    fn refuses_a_range_that_does_not_match_the_held_videos() {
        let temp = tempfile::tempdir().unwrap();
        let print = held(temp.path(), "DISC.iso", 3);
        let folder = Dir::open(temp.path()).unwrap();
        let refusal = check(&folder, "DISC.iso", "Show S01E05-E06.iso", &print).unwrap_err();
        assert!(refusal.message().contains("holds 3 videos"), "{refusal:?}");
        assert!(refusal.message().contains("S01E05-E07"), "{refusal:?}");
        assert!(temp.path().join("DISC.iso").is_file());
    }

    #[test]
    fn never_replaces_an_existing_name() {
        let temp = tempfile::tempdir().unwrap();
        let print = held(temp.path(), "DISC.iso", 1);
        std::fs::write(temp.path().join("show s01e05.ISO"), b"other").unwrap();
        let folder = Dir::open(temp.path()).unwrap();
        let refusal = check(&folder, "DISC.iso", "Show S01E05.iso", &print).unwrap_err();
        assert!(matches!(refusal, Refusal::Conflict(_)), "{refusal:?}");
        // The broker's no-replace rename still refuses a file that appears
        // after the check.
        std::fs::write(temp.path().join("Show S01E05.iso"), b"other").unwrap();
        let folder = Dir::open(temp.path()).unwrap();
        assert!(folder
            .rename_new("Show S01E05.iso", &folder, "DISC.iso")
            .is_err());
        assert_eq!(
            std::fs::read(temp.path().join("Show S01E05.iso")).unwrap(),
            b"other"
        );
        assert!(temp.path().join("DISC.iso.identify.json").is_file());
    }

    #[test]
    fn resumes_a_rename_interrupted_between_its_two_steps() {
        let temp = tempfile::tempdir().unwrap();
        let print = held(temp.path(), "DISC.iso", 2);
        let folder = Dir::open(temp.path()).unwrap();
        let to = "Show S01E05-E06.iso";
        let request = request("DISC.iso", to, print);
        // Stopped after the evidence rename: finished on the next tick.
        std::fs::rename(
            temp.path().join(format!("DISC.iso{EVIDENCE_SUFFIX}")),
            temp.path().join(format!("{to}{EVIDENCE_SUFFIX}")),
        )
        .unwrap();
        assert_eq!(apply(&folder, &request), Ok(()));
        assert!(temp.path().join(to).is_file());
        assert!(temp.path().join(format!("{to}{EVIDENCE_SUFFIX}")).is_file());
        assert!(!temp.path().join("DISC.iso").exists());
        // Stopped after both renames, before the result was saved.
        assert_eq!(apply(&folder, &request), Ok(()));
        // A different disc under the new name is not taken as done.
        let other = Request {
            fingerprint: Fingerprint {
                size_bytes: print.size_bytes + 7,
                ..print
            },
            ..request
        };
        assert!(apply(&folder, &other).is_err());
    }

    #[test]
    fn refuses_a_disc_that_changed_or_left() {
        let temp = tempfile::tempdir().unwrap();
        let print = held(temp.path(), "DISC.iso", 1);
        let folder = Dir::open(temp.path()).unwrap();
        let stale = Fingerprint {
            size_bytes: print.size_bytes + 1,
            ..print
        };
        assert!(matches!(
            check(&folder, "DISC.iso", "Show S01E05.iso", &stale),
            Err(Refusal::Conflict(_))
        ));
        let touched = Fingerprint {
            modified_ns: print.modified_ns - 1_000_000,
            ..print
        };
        assert!(matches!(
            check(&folder, "DISC.iso", "Show S01E05.iso", &touched),
            Err(Refusal::Conflict(_))
        ));
        // The time as a browser's double still matches.
        let rounded = Fingerprint {
            modified_ns: (print.modified_ns as f64) as i64,
            ..print
        };
        assert!(check(&folder, "DISC.iso", "Show S01E05.iso", &rounded).is_ok());
        assert!(matches!(
            check(&folder, "../DISC.iso", "Show S01E05.iso", &print),
            Err(Refusal::Missing(_))
        ));
        std::os::unix::fs::symlink(temp.path().join("DISC.iso"), temp.path().join("LINK.iso"))
            .unwrap();
        assert!(matches!(
            check(&folder, "LINK.iso", "Show S01E05.iso", &print),
            Err(Refusal::Missing(_))
        ));
        assert!(temp.path().join("DISC.iso").is_file());
    }
}
