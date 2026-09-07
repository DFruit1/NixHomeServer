use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::process::Command;
use tokio::time::timeout;

use crate::extract::kiwix::{clean_title_from_path, entry_origin, has_xapian_fulltext};
use crate::text::{html_title, html_to_text};

/// How many ZIM archives a single query will search at most.
const MAX_ZIMS_PER_QUERY: usize = 8;
/// How many article hits are kept per ZIM.
const MAX_RESULTS_PER_ZIM: usize = 5;
/// Total ZIM article hits returned for one query.
const MAX_TOTAL_ZIM_RESULTS: usize = 20;
/// Bound for a single kiwix-search invocation.
const SEARCH_TIMEOUT: Duration = Duration::from_secs(15);
/// Bound for a single title fetch.
const TITLE_TIMEOUT: Duration = Duration::from_secs(5);
/// HTML considered for a snippet; conversion cost is capped by this.
const SNIPPET_HTML_LIMIT: usize = 200_000;

/// Everything the query-time ZIM federator needs.
pub struct ZimSearchConfig {
    pub kiwix_search: Option<PathBuf>,
    pub zimdump: Option<PathBuf>,
    pub library_root: PathBuf,
    pub app_base: String,
}

impl ZimSearchConfig {
    pub fn enabled(&self) -> bool {
        self.kiwix_search.is_some() && self.zimdump.is_some()
    }
}

/// A single ZIM archive in the library, with its runtime index status.
#[derive(Debug, Clone)]
pub struct ZimIndexEntry {
    pub path: PathBuf,
    pub stem: String,
    pub has_xapian: bool,
}

/// One article hit surfaced from a ZIM's native Xapian index.
#[derive(Debug, Clone)]
pub struct ZimHit {
    pub title: String,
    pub snippet: Option<String>,
    pub origin_url: String,
    pub app_url: String,
}

/// Enumerates the ZIM archives in the library root and records, for each,
/// whether it embeds its own Xapian fulltext index. The library is capped to
/// a bounded number of archives so a large collection cannot make a single
/// query unbounded; archives beyond the cap are reported so an oversized
/// library is never silently unsearchable. Runs blocking subprocesses, so
/// call from spawn_blocking.
pub fn discover_zims(zimdump: &Path, library_root: &Path) -> Vec<ZimIndexEntry> {
    let mut zims: Vec<PathBuf> = std::fs::read_dir(library_root)
        .map(|reader| {
            reader
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| {
                    path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("zim")
                })
                .collect()
        })
        .unwrap_or_default();
    zims.sort();
    if zims.len() > MAX_ZIMS_PER_QUERY {
        eprintln!(
            "search: ZIM library holds {} archives; federating native indexes for the first {} only",
            zims.len(),
            MAX_ZIMS_PER_QUERY
        );
    }
    zims.into_iter()
        .take(MAX_ZIMS_PER_QUERY)
        .map(|path| {
            let stem = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .trim_end_matches(".zim")
                .to_string();
            let has_xapian = has_xapian_fulltext(zimdump, &path);
            ZimIndexEntry {
                path,
                stem,
                has_xapian,
            }
        })
        .collect()
}

/// Runs the query against every Xapian-bearing ZIM in `entries` and returns
/// the merged, bounded set of article hits. ZIMs without an embedded index are
/// skipped: their articles are already indexed into Solr by the fallback
/// extractor, so searching them here would only duplicate results. Archives
/// are queried concurrently; any single ZIM that fails (missing tool,
/// unreadable archive, timeout) is skipped rather than failing the whole
/// query, and results keep their archive ordering.
pub async fn search(
    config: &ZimSearchConfig,
    entries: &[ZimIndexEntry],
    query: &str,
) -> Vec<ZimHit> {
    let query = query.trim();
    let (Some(kiwix_search), Some(zimdump)) = (&config.kiwix_search, &config.zimdump) else {
        return Vec::new();
    };
    if query.is_empty() {
        return Vec::new();
    }

    let mut tasks = tokio::task::JoinSet::new();
    for (index, entry) in entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| entry.has_xapian)
    {
        let kiwix_search = kiwix_search.clone();
        let zimdump = zimdump.clone();
        let zim = entry.path.clone();
        let stem = entry.stem.clone();
        let app_base = config.app_base.clone();
        let query = query.to_string();
        tasks.spawn(async move {
            (
                index,
                search_zim(&kiwix_search, &zimdump, &zim, &stem, &app_base, &query).await,
            )
        });
    }
    let mut ordered: Vec<(usize, Vec<ZimHit>)> = Vec::new();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok((index, hits)) => ordered.push((index, hits)),
            Err(err) => eprintln!("search: ZIM federation task failed: {err}"),
        }
    }
    ordered.sort_by_key(|(index, _)| *index);
    let mut hits: Vec<ZimHit> = ordered.into_iter().flat_map(|(_, hits)| hits).collect();
    hits.truncate(MAX_TOTAL_ZIM_RESULTS);
    hits
}

/// Searches one ZIM archive and resolves its hits' titles and snippets.
async fn search_zim(
    kiwix_search: &Path,
    zimdump: &Path,
    zim: &Path,
    stem: &str,
    app_base: &str,
    query: &str,
) -> Vec<ZimHit> {
    let Ok(paths) = search_paths(kiwix_search, zim, query).await else {
        return Vec::new();
    };
    let mut hits = Vec::new();
    for path in paths.into_iter().take(MAX_RESULTS_PER_ZIM) {
        let path = path.trim().to_string();
        if path.is_empty() {
            continue;
        }
        let (title, snippet) = fetch_title_and_snippet(zimdump, zim, &path, query).await;
        hits.push(ZimHit {
            title,
            snippet,
            origin_url: entry_origin(app_base, stem, &path),
            app_url: app_base.trim_end_matches('/').to_string(),
        });
    }
    hits
}

/// Runs `kiwix-search ZIM PATTERN` and returns the matching entry paths.
async fn search_paths(kiwix_search: &Path, zim: &Path, query: &str) -> Result<Vec<String>, String> {
    let output = timeout(
        SEARCH_TIMEOUT,
        Command::new(kiwix_search).arg(zim).arg(query).output(),
    )
    .await
    .map_err(|_| format!("kiwix-search timed out for {}", zim.display()))?
    .map_err(|err| format!("failed to run kiwix-search: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "kiwix-search failed for {}: {}",
            zim.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect())
}

/// Resolves an article's real title (and a snippet) from the ZIM. Falls back to
/// a title derived from the entry path when the archive cannot be read or the
/// article has no `<title>`.
async fn fetch_title_and_snippet(
    zimdump: &Path,
    zim: &Path,
    path: &str,
    query: &str,
) -> (String, Option<String>) {
    let derived = clean_title_from_path(path);
    let html = match show_html(zimdump, zim, path, None).await {
        Some(html) => html,
        // Some `kiwix-search` outputs carry an `A/` namespace prefix while the
        // ZIM URL itself does not, so a failed first attempt retries with the
        // namespace split out.
        None => match split_namespace(path) {
            Some((namespace, rest)) => match show_html(zimdump, zim, rest, Some(namespace)).await {
                Some(html) => html,
                None => return (derived, None),
            },
            None => return (derived, None),
        },
    };
    title_and_snippet(&html, &derived, query)
}

/// Splits `A/Heat_wave` into `("A", "Heat_wave")`. Only single-letter
/// namespace-looking prefixes qualify; anything else is left untouched.
fn split_namespace(path: &str) -> Option<(&str, &str)> {
    let (prefix, rest) = path.split_once('/')?;
    if prefix.len() == 1
        && prefix
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
        && !rest.is_empty()
    {
        Some((prefix, rest))
    } else {
        None
    }
}

/// Fetches an article's HTML with `zimdump show`. `namespace` is optional:
/// when the caller splits a namespace off the entry path it must be passed
/// here, because `--url` combined with `--ns` defaults the namespace to `A`.
async fn show_html(
    zimdump: &Path,
    zim: &Path,
    path: &str,
    namespace: Option<&str>,
) -> Option<Vec<u8>> {
    let mut command = Command::new(zimdump);
    command.arg("show");
    match namespace {
        Some(ns) => {
            command
                .arg(format!("--url={path}"))
                .arg(format!("--ns={ns}"));
        }
        None => {
            command.arg(format!("--url={path}"));
        }
    }
    command.arg(zim);
    let output = timeout(TITLE_TIMEOUT, command.output()).await.ok()?.ok()?;
    if !output.status.success() {
        return None;
    }
    Some(output.stdout)
}

/// Extracts a display title and a query-aware snippet from article HTML.
fn title_and_snippet(html: &[u8], derived: &str, query: &str) -> (String, Option<String>) {
    let html = String::from_utf8_lossy(html);
    let title = html_title(&html).unwrap_or_else(|| derived.to_string());
    let snippet = make_snippet(&html, query);
    (title, snippet)
}

/// Builds a short snippet around the query's first keyword and wraps every
/// query term present in it in `<em>` tags, the same highlight markup Solr
/// emits for its own snippets. Returns None when the first keyword is not
/// present or the text is not convertible.
fn make_snippet(html: &str, query: &str) -> Option<String> {
    let terms = query_terms(query);
    let needle = terms.first()?;
    // `get` instead of byte slicing: the limit can land inside a multi-byte
    // UTF-8 character, which would panic a plain range index.
    let truncated = html
        .get(..html.len().min(SNIPPET_HTML_LIMIT))
        .unwrap_or(html);
    let text = html_to_text(truncated);
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let (position, needle_len) = find_case_insensitive_from(text, 0, needle)?;
    let start = position.saturating_sub(50);
    let end = (position + needle_len + 140).min(text.len());
    let window = &text[snap_to_boundary(text, start)..snap_to_boundary(text, end)];
    let window = window.trim();
    if window.is_empty() {
        None
    } else {
        Some(highlight_terms(window, &terms))
    }
}

/// Normalises a query into lowercase alphanumeric terms, in order, deduped.
fn query_terms(query: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    for word in query.split_whitespace() {
        let term = word
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase();
        if !term.is_empty() && !terms.contains(&term) {
            terms.push(term);
        }
    }
    terms
}

/// Wraps every case-insensitive occurrence of each term in `<em>` tags so ZIM
/// snippets render through the same UI path as Solr highlight fragments.
/// Matches never overlap: terms are applied left to right over plain text.
fn highlight_terms(text: &str, terms: &[String]) -> String {
    if terms.is_empty() {
        return text.to_string();
    }
    let mut marked = String::with_capacity(text.len());
    let mut cursor = 0;
    while let Some((start, end)) = terms
        .iter()
        .filter_map(|term| find_case_insensitive_from(text, cursor, term))
        .min_by_key(|&(start, _)| start)
    {
        marked.push_str(&text[cursor..start]);
        marked.push_str("<em>");
        marked.push_str(&text[start..end]);
        marked.push_str("</em>");
        cursor = end;
    }
    marked.push_str(&text[cursor..]);
    marked
}

/// Case-insensitive byte-span search for `needle` at or after `from`, returning
/// (start, end) offsets into `haystack`. Only matches when lowercasing both
/// sides preserves the byte layout, so returned offsets are always valid
/// character boundaries; exotic casing expansions (e.g. 'İ') are skipped as a
/// cosmetic no-op rather than risking misplaced or invalid spans.
fn find_case_insensitive_from(haystack: &str, from: usize, needle: &str) -> Option<(usize, usize)> {
    let hay = haystack.get(from..)?;
    let hay_lower = hay.to_lowercase();
    let needle_lower = needle.to_lowercase();
    if hay_lower.len() != hay.len() || needle_lower.len() != needle.len() {
        return None;
    }
    hay_lower
        .find(&needle_lower)
        .map(|at| (from + at, from + at + needle_lower.len()))
}

/// Clamps a byte offset to a UTF-8 character boundary.
fn snap_to_boundary(value: &str, byte: usize) -> usize {
    let byte = byte.min(value.len());
    let mut boundary = byte;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    boundary
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_titles_from_paths() {
        assert_eq!(clean_title_from_path("A/Heat_wave"), "Heat wave");
        assert_eq!(
            clean_title_from_path("A/Foo_(disambiguation)"),
            "Foo (disambiguation)"
        );
        assert_eq!(clean_title_from_path("index.html"), "index");
    }

    #[test]
    fn finds_spans_case_insensitively() {
        assert_eq!(
            find_case_insensitive_from("Hello World", 0, "world"),
            Some((6, 11))
        );
        assert_eq!(
            find_case_insensitive_from("Hello World", 0, "WORLD"),
            Some((6, 11))
        );
        assert_eq!(find_case_insensitive_from("Hello World", 0, "xyz"), None);
        // A search resumes after `from` and offsets stay absolute.
        assert_eq!(
            find_case_insensitive_from("ab cd ab", 3, "ab"),
            Some((6, 8))
        );
        assert_eq!(find_case_insensitive_from("ab", 2, "ab"), None);
    }

    #[test]
    fn normalises_query_terms() {
        assert_eq!(
            query_terms("Quantum  computing!!"),
            vec!["quantum", "computing"]
        );
        assert_eq!(query_terms("a b a"), vec!["a", "b"]);
        assert_eq!(query_terms("!!!"), Vec::<String>::new());
    }

    #[test]
    fn highlights_terms_like_solr() {
        assert_eq!(
            highlight_terms("about quantum physics", &["quantum".to_string()]),
            "about <em>quantum</em> physics"
        );
        // Multiple terms, case-insensitive, left to right.
        assert_eq!(
            highlight_terms(
                "Quantum COMPUTING notes",
                &["quantum".to_string(), "computing".to_string()]
            ),
            "<em>Quantum</em> <em>COMPUTING</em> notes"
        );
        // Repeated occurrences of one term are all marked.
        assert_eq!(
            highlight_terms("a b a", &["a".to_string()]),
            "<em>a</em> b <em>a</em>"
        );
        // An absent term leaves the text untouched.
        assert_eq!(
            highlight_terms("plain text", &["zebra".to_string()]),
            "plain text"
        );
    }

    #[test]
    fn snaps_to_char_boundaries() {
        let value = "héllo wörld";
        let snapped = snap_to_boundary(value, 3);
        assert!(value.is_char_boundary(snapped));
        let snapped = snap_to_boundary(value, 0);
        assert_eq!(snapped, 0);
        let snapped = snap_to_boundary(value, value.len() + 5);
        assert_eq!(snapped, value.len());
    }

    #[test]
    fn splits_namespace_only_for_single_letter_prefixes() {
        assert_eq!(split_namespace("A/Heat_wave"), Some(("A", "Heat_wave")));
        assert_eq!(split_namespace("C/Song"), Some(("C", "Song")));
        assert_eq!(split_namespace("wikipedia/Heat_wave"), None);
        assert_eq!(split_namespace("Heat_wave"), None);
        assert_eq!(split_namespace("A/"), None);
        assert_eq!(split_namespace(""), None);
    }

    #[test]
    fn snippet_slicing_survives_multibyte_boundary() {
        // 'é' is two bytes; a naive byte slice at SNIPPET_HTML_LIMIT would
        // panic if the limit lands inside a character. The keyword must sit
        // inside the retained window so the snippet itself is still produced.
        let filler = "é".repeat(SNIPPET_HTML_LIMIT);
        let html = format!("<html><body><p>about quantum physics {filler}</p></body></html>");
        let snippet = make_snippet(&html, "quantum");
        assert!(snippet.expect("snippet").contains("quantum"));
    }

    #[test]
    fn builds_snippets_around_keyword() {
        let html = "<html><body><p>This is a long article about quantum computing and other topics.</p></body></html>";
        let snippet = make_snippet(html, "quantum");
        let snippet = snippet.expect("snippet");
        assert!(snippet.contains("<em>quantum</em>"));
        // Multiple query terms are all highlighted when present.
        let multi = make_snippet(html, "QUANTUM other");
        let multi = multi.expect("multi-term snippet");
        assert!(multi.contains("<em>quantum</em>") && multi.contains("<em>other</em>"));
        // A query whose keyword is absent produces no snippet.
        assert_eq!(make_snippet(html, "zebra"), None);
        // A query with no alphanumeric keyword produces no snippet.
        assert_eq!(make_snippet(html, "!!!"), None);
        // Empty text produces no snippet.
        assert_eq!(make_snippet("<html><body></body></html>", "quantum"), None);
    }

    #[test]
    fn discovers_zims_from_directory() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("a.zim"), b"zim").expect("write");
        std::fs::write(dir.path().join("b.zim"), b"zim").expect("write");
        std::fs::write(dir.path().join("notes.txt"), b"x").expect("write");
        // A missing zimdump binary makes every entry report "no index", which
        // is the safe fallback, but discovery still returns the archives.
        let entries = discover_zims(Path::new("/nonexistent/zimdump"), dir.path());
        let stems: Vec<String> = entries.iter().map(|entry| entry.stem.clone()).collect();
        assert_eq!(stems, vec!["a".to_string(), "b".to_string()]);
        assert!(entries.iter().all(|entry| !entry.has_xapian));
    }

    #[test]
    fn search_without_tools_returns_empty() {
        let config = ZimSearchConfig {
            kiwix_search: None,
            zimdump: None,
            library_root: PathBuf::from("/tmp"),
            app_base: "https://wiki.example.org".to_string(),
        };
        let entries = vec![ZimIndexEntry {
            path: PathBuf::from("/tmp/a.zim"),
            stem: "a".to_string(),
            has_xapian: true,
        }];
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("runtime");
        let hits = runtime.block_on(search(&config, &entries, "quantum"));
        assert!(hits.is_empty());
    }
}
