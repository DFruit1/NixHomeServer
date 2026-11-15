//! Fetches the article behind a feed entry whose feed carries only a summary.
//! Most feeds publish a sentence or two (the median stored entry here was 283
//! bytes), so a search could match an article's headline but nothing it says.
//!
//! Like the PDF archive this is a separate pass, never part of indexing or of
//! a search: the indexer only reads what this pass has already saved. Entry
//! links are chosen by whoever publishes a feed, so every request, and every
//! redirect it follows, is confined to public web addresses.
use std::collections::HashSet;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::config::{Settings, SourceConfig};
use crate::text::html_to_text;

const USER_AGENT: &str = "NixHomeServer-Search-Articles/0.1";
const DEFAULT_MAX_PER_RUN: usize = 200;
const MAX_BYTES: usize = 3_000_000;
const TEXT_LIMIT: usize = 400_000;
const REDIRECTS: usize = 5;
const TIMEOUT: Duration = Duration::from_secs(20);
/// Pause between requests; a run is a slow walk, not a crawl.
const DELAY: Duration = Duration::from_secs(1);
/// A stored entry with at least this much text already carries its article.
pub(crate) const SUMMARY_BYTES: usize = 1_500;
/// A fetch that failed is tried again after this long.
const RETRY_AFTER: Duration = Duration::from_secs(30 * 24 * 60 * 60);

pub(crate) fn key(url: &str) -> String {
    crate::timeutil::sha256_hex(&[url])
}

fn saved_path(root: &Path, key: &str, extension: &str) -> PathBuf {
    root.join(&key[..2]).join(format!("{key}.{extension}"))
}

/// The saved text of an article, if a fetch pass has stored one.
pub(crate) fn saved_text(root: &Path, url: &str) -> Option<String> {
    std::fs::read_to_string(saved_path(root, &key(url), "txt"))
        .ok()
        .filter(|text| !text.trim().is_empty())
}

/// Saved article files, for the source fingerprint.
pub(crate) fn saved_files(root: &Path) -> Vec<PathBuf> {
    crate::extract::collect_files(root, 1, &|file: &Path| {
        file.extension().is_some_and(|extension| extension == "txt")
    })
}

/// Whether an address is on the public internet. Private, loopback,
/// link-local, carrier-grade NAT (the overlay network uses it) and other
/// special ranges are refused, as are IPv4 addresses wrapped in IPv6.
fn is_public(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || v4.is_multicast()
                || octets[0] == 0
                || (octets[0] == 100 && (64..128).contains(&octets[1]))
                || (octets[0] == 192 && octets[1] == 0 && octets[2] == 0)
                || (octets[0] == 198 && (18..20).contains(&octets[1]))
                || octets[0] >= 240)
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped().or_else(|| v6.to_ipv4()) {
                return is_public(IpAddr::V4(v4));
            }
            let first = v6.segments()[0];
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80)
        }
    }
}

/// Resolves a link and returns the public address to connect to, or why the
/// link may not be fetched.
async fn public_target(url: &url::Url) -> Result<(String, std::net::SocketAddr), String> {
    if !matches!(url.scheme(), "http" | "https") {
        return Err("not a web address".to_string());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("address carries credentials".to_string());
    }
    let host = url.host_str().ok_or("address has no host")?.to_string();
    let port = url.port_or_known_default().ok_or("address has no port")?;
    let addresses: Vec<_> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|err| format!("host did not resolve: {err}"))?
        .collect();
    // Every answer must be public: a name that resolves to both a public and
    // a private address could otherwise be steered to the private one.
    if addresses.is_empty() || !addresses.iter().all(|address| is_public(address.ip())) {
        return Err("host is not a public address".to_string());
    }
    Ok((host, addresses[0]))
}

/// Fetches one page, following redirects by hand so each hop is checked and
/// the connection goes to the address that was checked.
async fn fetch(start: &str) -> Result<String, String> {
    let mut url = url::Url::parse(start).map_err(|err| format!("invalid address: {err}"))?;
    for _ in 0..=REDIRECTS {
        let (host, address) = public_target(&url).await?;
        let client = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .user_agent(USER_AGENT)
            .redirect(reqwest::redirect::Policy::none())
            .resolve(&host, address)
            .build()
            .map_err(|err| format!("failed to build HTTP client: {err}"))?;
        let mut response = client
            .get(url.clone())
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|err| format!("request failed: {err}"))?;
        if response.status().is_redirection() {
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or("redirect without a destination")?;
            url = url
                .join(location)
                .map_err(|err| format!("invalid redirect: {err}"))?;
            continue;
        }
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !(content_type.starts_with("text/html") || content_type.starts_with("application/xhtml"))
        {
            return Err(format!("not a web page (content-type '{content_type}')"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|err| format!("failed to read page: {err}"))?
        {
            if bytes.len() + chunk.len() > MAX_BYTES {
                return Err(format!("page is over the {MAX_BYTES}-byte limit"));
            }
            bytes.extend_from_slice(&chunk);
        }
        return Ok(crate::text::decode_document_text(&bytes));
    }
    Err("too many redirects".to_string())
}

/// Removes every `<tag ...>...</tag>` block, ASCII case-insensitively.
fn without_blocks(html: &str, tag: &str) -> String {
    let lower = html.to_ascii_lowercase();
    let open = format!("<{tag}");
    let close = format!("</{tag}>");
    let mut out = String::with_capacity(html.len());
    let mut position = 0;
    while let Some(found) = lower[position..].find(&open) {
        let start = position + found;
        // "<nav" must not match "<navigation-menu".
        let boundary = lower.as_bytes().get(start + open.len()).copied();
        if !matches!(boundary, Some(b'>' | b' ' | b'\t' | b'\n' | b'\r' | b'/')) {
            out.push_str(&html[position..start + open.len()]);
            position = start + open.len();
            continue;
        }
        out.push_str(&html[position..start]);
        match lower[start..].find(&close) {
            Some(end) => position = start + end + close.len(),
            None => {
                position = html.len();
                break;
            }
        }
    }
    out.push_str(&html[position..]);
    out
}

/// The inside of the first `<tag>` element, to its last closing tag.
fn element<'a>(html: &'a str, lower: &str, tag: &str) -> Option<&'a str> {
    let start = lower.find(&format!("<{tag}"))?;
    let open_end = start + lower[start..].find('>')? + 1;
    let end = lower.rfind(&format!("</{tag}>"))?;
    (end > open_end).then(|| &html[open_end..end])
}

/// The article's own words: the page's `<article>` or `<main>` element when it
/// has one, without navigation, sidebars, forms and scripts.
pub(crate) fn article_text(html: &str) -> String {
    let mut html = html.to_string();
    for tag in [
        "script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "iframe",
    ] {
        html = without_blocks(&html, tag);
    }
    let lower = html.to_ascii_lowercase();
    let content = element(&html, &lower, "article")
        .or_else(|| element(&html, &lower, "main"))
        .unwrap_or(&html);
    let text = html_to_text(content);
    crate::text::truncate_text(text.trim(), TEXT_LIMIT)
}

struct Candidate {
    url: String,
}

fn candidates(source: &SourceConfig) -> Result<Vec<Candidate>, String> {
    let state_dir = source.require_setting("stateDir")?;
    let mut found = Vec::new();
    for database in crate::extract::freshrss::user_databases(&state_dir) {
        let connection = rusqlite::Connection::open_with_flags(
            &database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .map_err(|err| format!("failed to open FreshRSS database: {err}"))?;
        let mut statement = connection
            .prepare("SELECT link, content FROM entry ORDER BY date DESC")
            .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            })
            .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
        for row in rows {
            let (link, content) =
                row.map_err(|err| format!("failed to read FreshRSS entries: {err}"))?;
            let link = link.unwrap_or_default();
            if link.starts_with("http")
                && html_to_text(&content.unwrap_or_default()).len() < SUMMARY_BYTES
            {
                found.push(Candidate { url: link });
            }
        }
    }
    Ok(found)
}

pub async fn run() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let root = PathBuf::from(
        std::env::var("SEARCH_ARTICLE_ARCHIVE_DIR")
            .map_err(|_| "SEARCH_ARTICLE_ARCHIVE_DIR must be set".to_string())?,
    );
    let max_per_run = match std::env::var("SEARCH_ARTICLE_ARCHIVE_MAX_PER_RUN") {
        Ok(value) => value
            .parse()
            .map_err(|_| "SEARCH_ARTICLE_ARCHIVE_MAX_PER_RUN must be a number".to_string())?,
        Err(_) => DEFAULT_MAX_PER_RUN,
    };
    let mut seen = HashSet::new();
    let (mut fetched, mut failed, mut kept) = (0usize, 0usize, 0usize);
    for source in settings
        .sources
        .iter()
        .filter(|source| source.source_type == "freshrss")
    {
        let found = match candidates(source) {
            Ok(found) => found,
            Err(err) => {
                eprintln!("search: articles: source '{}': {err}", source.id);
                continue;
            }
        };
        for candidate in found {
            let key = key(&candidate.url);
            if !seen.insert(key.clone()) {
                continue;
            }
            let text_path = saved_path(&root, &key, "txt");
            let failure_path = saved_path(&root, &key, "failed");
            let recently_failed = std::fs::metadata(&failure_path)
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age < RETRY_AFTER);
            if text_path.exists() || recently_failed {
                kept += 1;
                continue;
            }
            if fetched + failed >= max_per_run {
                continue;
            }
            if fetched + failed > 0 {
                tokio::time::sleep(DELAY).await;
            }
            if let Some(parent) = text_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
            }
            let outcome = fetch(&candidate.url).await.and_then(|html| {
                let text = article_text(&html);
                (text.len() >= SUMMARY_BYTES)
                    .then_some(text)
                    .ok_or_else(|| "page has no more text than the feed".to_string())
            });
            match outcome {
                Ok(text) => {
                    let temporary = text_path.with_extension("part");
                    std::fs::write(&temporary, text)
                        .and_then(|()| std::fs::rename(&temporary, &text_path))
                        .map_err(|err| format!("failed to save article: {err}"))?;
                    let _ = std::fs::remove_file(&failure_path);
                    fetched += 1;
                }
                Err(err) => {
                    // The reason only; addresses are a reader's private list.
                    let _ = std::fs::write(&failure_path, &err);
                    failed += 1;
                }
            }
        }
    }
    eprintln!("search: articles: fetched={fetched} failed={failed} already_handled={kept}");
    Ok(())
}
