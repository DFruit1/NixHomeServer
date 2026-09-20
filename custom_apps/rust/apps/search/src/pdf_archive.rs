//! Admin-only PDF archival for stored RSS entries.
//!
//! FreshRSS keeps every subscribed entry in a per-user SQLite database. Many
//! academic and repository feeds publish only an abstract in the entry body
//! while the actual paper lives behind a PDF link. Readability (Af_Readability)
//! cannot extract those because it only parses HTML, so this module walks the
//! same entry tables, finds PDF URLs, and downloads them into a persistent
//! archive with a Postgres manifest.
//!
//! This is deliberately a server-admin surface, not a user feature: it runs as
//! a `search` CLI subcommand (optionally on a systemd timer) and never exposes
//! a mass-download endpoint to normal gateway users. The manifest is the system
//! of record; a later extractor can index the archived PDFs into Search using
//! the existing `pdftotext` pipeline.
//!
//! Trust boundary: the downloader runs as the `search` user, which is *not*
//! covered by the `freshrss` nftables egress policy (that policy is keyed on
//! `skuid freshrss`). It therefore reaches public *and* private/link-local
//! addresses. Keep the archive trigger admin-only, and prefer running it under
//! the same egress restriction as FreshRSS if the source set is ever widened
//! beyond trusted feeds.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags};
use sha2::{Digest, Sha256};
use url::Url;

use crate::config::{Settings, SourceConfig};
use crate::db::{self, PdfArchiveRecord};
use crate::extract::freshrss;
use crate::timeutil::now_epoch;

const DEFAULT_MAX_PER_RUN: usize = 200;
const DEFAULT_MAX_BYTES: u64 = 25 * 1024 * 1024;
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;
const DEFAULT_DELAY_MS: u64 = 1000;
const USER_AGENT: &str = "NixHomeServer-Search-PdfArchive/0.1";

/// Everything the archive pass needs, read from the environment so the same
/// binary can run under systemd, a timer, or an operator shell.
#[derive(Debug, Clone)]
pub struct ArchiveConfig {
    pub dir: PathBuf,
    /// Empty means "every configured FreshRSS source".
    pub source_ids: Vec<String>,
    pub max_per_run: usize,
    pub max_bytes: u64,
    pub timeout: Duration,
    pub delay: Duration,
    pub dry_run: bool,
}

impl ArchiveConfig {
    pub fn from_env() -> Result<Self, String> {
        let dir = std::env::var("SEARCH_PDF_ARCHIVE_DIR")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "SEARCH_PDF_ARCHIVE_DIR is required".to_string())?;

        let source_ids = std::env::var("SEARCH_PDF_ARCHIVE_SOURCES")
            .ok()
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|entry| !entry.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let max_per_run = parse_env_usize("SEARCH_PDF_ARCHIVE_MAX_PER_RUN", DEFAULT_MAX_PER_RUN)?;
        let max_bytes = parse_env_u64("SEARCH_PDF_ARCHIVE_MAX_BYTES", DEFAULT_MAX_BYTES)?;
        let timeout = Duration::from_secs(parse_env_u64(
            "SEARCH_PDF_ARCHIVE_TIMEOUT_SECONDS",
            DEFAULT_TIMEOUT_SECONDS,
        )?);
        let delay = Duration::from_millis(parse_env_u64(
            "SEARCH_PDF_ARCHIVE_DELAY_MS",
            DEFAULT_DELAY_MS,
        )?);
        let dry_run = std::env::var("SEARCH_PDF_ARCHIVE_DRY_RUN")
            .ok()
            .map(|value| {
                let value = value.trim().to_ascii_lowercase();
                !value.is_empty() && value != "0" && value != "false"
            })
            .unwrap_or(false);

        Ok(Self {
            dir: PathBuf::from(dir),
            source_ids,
            max_per_run,
            max_bytes,
            timeout,
            delay,
            dry_run,
        })
    }
}

fn parse_env_usize(name: &str, default: usize) -> Result<usize, String> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => value
            .trim()
            .parse()
            .map_err(|_| format!("{name} must be a non-negative integer")),
        _ => Ok(default),
    }
}

fn parse_env_u64(name: &str, default: u64) -> Result<u64, String> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => value
            .trim()
            .parse()
            .map_err(|_| format!("{name} must be a non-negative integer")),
        _ => Ok(default),
    }
}

/// One PDF worth downloading, attributed to the FreshRSS account and entry it
/// was discovered under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub owner: String,
    pub source_id: String,
    pub entry_external_id: String,
    pub feed: String,
    pub title: String,
    pub url: String,
}

struct EntryRow {
    guid: String,
    title: String,
    link: String,
    content: String,
    feed_name: String,
}

/// Reads every entry from one FreshRSS user database. Read-only so it never
/// contends with the live FreshRSS writer beyond SQLite's normal locking.
fn load_entries(connection: &Connection) -> Result<Vec<EntryRow>, String> {
    let mut statement = connection
        .prepare(
            "SELECT e.guid, e.title, e.link, e.content, f.name
             FROM entry AS e LEFT JOIN feed AS f ON e.id_feed = f.id",
        )
        .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok(EntryRow {
                guid: row.get(0)?,
                title: row.get(1)?,
                link: row.get(2)?,
                content: row.get(3)?,
                feed_name: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
            })
        })
        .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|err| format!("failed to read FreshRSS entries: {err}"))?);
    }
    Ok(entries)
}

fn open_read_only(path: &Path) -> Result<Connection, String> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|err| format!("failed to open FreshRSS database {}: {err}", path.display()))
}

/// Discovers PDF candidates for one configured FreshRSS source.
pub fn discover_candidates(source: &SourceConfig) -> Result<Vec<Candidate>, String> {
    let state_dir = source.require_setting("stateDir")?;
    let mut candidates = Vec::new();
    for database in freshrss::user_databases(&state_dir) {
        let owner = database
            .parent()
            .and_then(|parent| parent.file_name())
            .and_then(|name| name.to_str())
            .unwrap_or("unknown")
            .to_string();
        let connection = open_read_only(&database)?;
        for entry in load_entries(&connection)? {
            for url in pdf_urls_in_entry(&entry.link, &entry.content) {
                candidates.push(Candidate {
                    owner: owner.clone(),
                    source_id: source.id.clone(),
                    entry_external_id: entry.guid.clone(),
                    feed: entry.feed_name.clone(),
                    title: entry.title.clone(),
                    url,
                });
            }
        }
    }
    Ok(candidates)
}

/// Extracts PDF URLs from an entry's link and its HTML content.
///
/// The entry link is considered directly (repository feeds often point straight
/// at a `.pdf`), and every `href` in the content is resolved against that link
/// before being tested. Relative links are kept so a site that publishes
/// `files/paper.pdf` still resolves to the article URL.
pub fn pdf_urls_in_entry(link: &str, content: &str) -> Vec<String> {
    let mut urls: Vec<String> = Vec::new();
    let mut consider = |raw: &str| {
        if let Some(candidate) = resolve_url(link, raw) {
            if let Ok(url) = Url::parse(&candidate) {
                if url_path_is_pdf(&url) && !urls.iter().any(|existing| existing == &candidate) {
                    urls.push(candidate);
                }
            }
        }
    };
    consider(link);
    for href in extract_hrefs(content) {
        consider(&href);
    }
    urls
}

fn url_path_is_pdf(url: &Url) -> bool {
    url.path().to_ascii_lowercase().ends_with(".pdf")
}

fn resolve_url(base: &str, raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(url) = Url::parse(raw) {
        return Some(url.to_string());
    }
    // Protocol-relative links are common in feeds and need the base scheme.
    let base = Url::parse(base).ok()?;
    base.join(raw).ok().map(|url| url.to_string())
}

/// Minimal `href="…"` scanner. FreshRSS stores sanitized markup and Search
/// already ships no HTML parser, so this only needs to pull attribute values
/// out of well-formed content without pulling a new dependency in.
fn extract_hrefs(html: &str) -> Vec<String> {
    let bytes = html.as_bytes();
    let lower = html.to_ascii_lowercase();
    let lower_bytes = lower.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;
    while index + 4 <= bytes.len() {
        if &lower_bytes[index..index + 4] != b"href" {
            index += 1;
            continue;
        }
        let mut cursor = index + 4;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b'=' {
            index += 1;
            continue;
        }
        cursor += 1;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() {
            break;
        }
        let quote = bytes[cursor];
        if quote == b'"' || quote == b'\'' {
            let start = cursor + 1;
            if let Some(end) = bytes[start..].iter().position(|&byte| byte == quote) {
                let value = &html[start..start + end];
                if !value.is_empty() {
                    out.push(value.to_string());
                }
                index = start + end + 1;
                continue;
            }
        } else {
            let start = cursor;
            let mut end = cursor;
            while end < bytes.len() && !bytes[end].is_ascii_whitespace() && bytes[end] != b'>' {
                end += 1;
            }
            if end > start {
                out.push(html[start..end].to_string());
                index = end;
                continue;
            }
        }
        index += 1;
    }
    out
}

fn manifest_key(url: &str) -> String {
    crate::timeutil::sha256_hex(&[url])
}

fn sha256_hex_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn safe_owner(owner: &str) -> String {
    if homelab_common::is_safe_single_component(owner) {
        owner.to_string()
    } else {
        "unknown".to_string()
    }
}

fn looks_like_pdf(bytes: &[u8]) -> bool {
    let window = &bytes[..bytes.len().min(1024)];
    window.windows(5).any(|window| window == b"%PDF-")
}

/// Runs one archive pass. Returns an error only for a configuration or
/// infrastructure failure; individual download failures are recorded in the
/// manifest and reported in the summary.
pub async fn run() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let config = ArchiveConfig::from_env()?;

    let sources: Vec<&SourceConfig> = settings
        .sources
        .iter()
        .filter(|source| source.source_type == "freshrss")
        .filter(|source| {
            config.source_ids.is_empty() || config.source_ids.iter().any(|id| id == &source.id)
        })
        .collect();
    if sources.is_empty() {
        eprintln!("search: no FreshRSS sources configured for PDF archiving");
        return Ok(());
    }

    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;

    let http = reqwest::Client::builder()
        .timeout(config.timeout)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|err| format!("failed to build PDF archive HTTP client: {err}"))?;

    let mut discovered: Vec<Candidate> = Vec::new();
    for source in &sources {
        match discover_candidates(source) {
            Ok(mut candidates) => {
                eprintln!(
                    "search: pdf-archive: source '{}': {} candidate(s)",
                    source.id,
                    candidates.len()
                );
                discovered.append(&mut candidates);
            }
            Err(err) => eprintln!(
                "search: pdf-archive: source '{}': discovery failed: {err}",
                source.id
            ),
        }
    }

    let mut seen: HashSet<String> = HashSet::new();
    let mut considered = 0usize;
    let mut downloaded = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;

    for candidate in discovered {
        let key = manifest_key(&candidate.url);
        if !seen.insert(key.clone()) {
            continue;
        }
        if let Some(status) = db::pdf_archive_status(&client, &key).await? {
            if status == "downloaded" {
                skipped += 1;
                continue;
            }
        }
        if considered >= config.max_per_run {
            eprintln!(
                "search: pdf-archive: reached the per-run limit of {}; remaining candidates deferred",
                config.max_per_run
            );
            break;
        }
        considered += 1;

        let owner = safe_owner(&candidate.owner);
        let destination = config.dir.join(&owner).join(format!("{key}.pdf"));
        let discovered_at = now_epoch();

        if config.dry_run {
            record(
                &client,
                &candidate,
                &key,
                "candidate",
                Some(destination.display().to_string()),
                String::new(),
                0,
                None,
                discovered_at,
            )
            .await?;
            continue;
        }

        // Idempotency without the manifest: an interrupted earlier pass may
        // have written the file but not the row.
        if destination.is_file() {
            let size = std::fs::metadata(&destination)
                .map(|meta| meta.len())
                .unwrap_or(0);
            record(
                &client,
                &candidate,
                &key,
                "downloaded",
                Some(destination.display().to_string()),
                String::new(),
                size,
                None,
                discovered_at,
            )
            .await?;
            skipped += 1;
            continue;
        }

        match download_pdf(&http, &candidate.url, &destination, config.max_bytes).await {
            Ok((digest, size)) => {
                record(
                    &client,
                    &candidate,
                    &key,
                    "downloaded",
                    Some(destination.display().to_string()),
                    digest,
                    size,
                    None,
                    discovered_at,
                )
                .await?;
                downloaded += 1;
            }
            Err(err) => {
                eprintln!("search: pdf-archive: failed {} ({err})", candidate.url);
                record(
                    &client,
                    &candidate,
                    &key,
                    "failed",
                    None,
                    String::new(),
                    0,
                    Some(err),
                    discovered_at,
                )
                .await?;
                failed += 1;
            }
        }

        if !config.delay.is_zero() {
            tokio::time::sleep(config.delay).await;
        }
    }

    eprintln!(
        "search: pdf-archive complete ({downloaded} downloaded, {skipped} already archived, {failed} failed, {considered} considered)"
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn record(
    client: &tokio_postgres::Client,
    candidate: &Candidate,
    key: &str,
    status: &str,
    file_path: Option<String>,
    sha256: String,
    size_bytes: u64,
    error: Option<String>,
    discovered_at: i64,
) -> Result<(), String> {
    let downloaded_at = (status == "downloaded").then(now_epoch);
    db::upsert_pdf_archive(
        client,
        &PdfArchiveRecord {
            url_hash: key.to_string(),
            source_id: candidate.source_id.clone(),
            entry_external_id: candidate.entry_external_id.clone(),
            owner: candidate.owner.clone(),
            feed: candidate.feed.clone(),
            title: candidate.title.clone(),
            origin_url: candidate.url.clone(),
            file_path: file_path.unwrap_or_default(),
            sha256,
            size_bytes: size_bytes as i64,
            status: status.to_string(),
            error,
            discovered_at,
            downloaded_at,
        },
    )
    .await
}

/// Fetches one URL and writes it to `destination` only if it really is a PDF of
/// an acceptable size. Returns the content digest and byte count.
async fn download_pdf(
    http: &reqwest::Client,
    url: &str,
    destination: &Path,
    max_bytes: u64,
) -> Result<(String, u64), String> {
    let response = http
        .get(url)
        .send()
        .await
        .map_err(|err| format!("request failed: {err}"))?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !content_type.starts_with("application/pdf") {
        return Err(format!("not a PDF (content-type '{content_type}')"));
    }
    if let Some(length) = response.content_length() {
        if length > max_bytes {
            return Err(format!(
                "PDF is {length} bytes, over the {max_bytes}-byte limit"
            ));
        }
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|err| format!("failed to read body: {err}"))?;
    if bytes.len() as u64 > max_bytes {
        return Err(format!(
            "PDF is {} bytes, over the {max_bytes}-byte limit",
            bytes.len()
        ));
    }
    if !looks_like_pdf(&bytes) {
        return Err("response did not look like a PDF".to_string());
    }

    if let Some(parent) = destination.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    let temporary = destination.with_extension("pdf.part");
    tokio::fs::write(&temporary, &bytes)
        .await
        .map_err(|err| format!("failed to write {}: {err}", temporary.display()))?;
    tokio::fs::rename(&temporary, destination)
        .await
        .map_err(|err| format!("failed to publish {}: {err}", destination.display()))?;

    Ok((sha256_hex_bytes(&bytes), bytes.len() as u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_direct_and_relative_pdf_links() {
        let content = r#"
            <p>Read the <a href="files/paper.pdf">paper</a> or
            <a href='https://example.org/other.PDF?download=1'>this</a>.
            <a href="/notes.html">notes</a></p>
        "#;
        let urls = pdf_urls_in_entry("https://example.org/record/42", content);
        assert_eq!(
            urls,
            vec![
                "https://example.org/record/files/paper.pdf".to_string(),
                "https://example.org/other.PDF?download=1".to_string(),
            ]
        );
    }

    #[test]
    fn keeps_a_direct_pdf_entry_link() {
        let urls = pdf_urls_in_entry("https://example.org/paper.pdf", "");
        assert_eq!(urls, vec!["https://example.org/paper.pdf".to_string()]);
    }

    #[test]
    fn deduplicates_repeated_links() {
        let content = r#"<a href="a.pdf">1</a><a href="a.pdf">2</a>"#;
        let urls = pdf_urls_in_entry("https://example.org/", content);
        assert_eq!(urls, vec!["https://example.org/a.pdf".to_string()]);
    }

    #[test]
    fn ignores_non_pdf_hrefs() {
        let content = r#"<a href="https://example.org/page">page</a>"#;
        assert!(pdf_urls_in_entry("https://example.org/", content).is_empty());
    }

    #[test]
    fn extracts_unquoted_hrefs() {
        let hrefs = extract_hrefs(r#"<a href=a.pdf>x</a>"#);
        assert_eq!(hrefs, vec!["a.pdf".to_string()]);
    }

    #[test]
    fn manifest_key_is_stable() {
        assert_eq!(
            manifest_key("https://a/b.pdf"),
            manifest_key("https://a/b.pdf")
        );
        assert_ne!(
            manifest_key("https://a/b.pdf"),
            manifest_key("https://a/c.pdf")
        );
    }

    #[test]
    fn sanitizes_unsafe_owners() {
        assert_eq!(safe_owner("alice"), "alice");
        assert_eq!(safe_owner("../etc"), "unknown");
        assert_eq!(safe_owner(""), "unknown");
    }

    #[test]
    fn recognizes_pdf_magic_with_leading_junk() {
        assert!(looks_like_pdf(b"\n%PDF-1.7\n"));
        assert!(!looks_like_pdf(b"<html>nope</html>"));
    }
}
