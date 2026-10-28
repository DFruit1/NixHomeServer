use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::process::Command;
use tokio::time::timeout;

use crate::extract::kiwix::{clean_title_from_path, entry_origin, has_xapian_fulltext};
use crate::text::{html_title, snippet_from_html};

/// How many ZIM archives a single query searches concurrently. Every Xapian-
/// bearing archive in the library is searched (no archive-count cap); this
/// bounds the number of in-flight `kiwix-search` subprocesses instead.
const MAX_ZIM_CONCURRENCY: usize = 8;
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

/// One article hit surfaced from a ZIM's native Xapian index. The body text is
/// never copied into the Search index; it is resolved from the archive at query
/// time, so these hits carry only what the current query rendered.
#[derive(Debug, Clone)]
pub struct ZimHit {
    pub title: String,
    pub snippet: Option<String>,
    pub origin_url: String,
    pub app_url: String,
    /// Archive name and entry path, presented to the UI exactly like the
    /// metadata of indexed sources so federation is invisible to the user.
    pub metadata: serde_json::Value,
}

/// Enumerates the ZIM archives in the library root and records, for each,
/// whether it embeds its own Xapian fulltext index. Every archive is returned;
/// the caller bounds how many are queried concurrently, so a large library is
/// fully searchable rather than silently truncated. Runs blocking
/// subprocesses, so call from spawn_blocking.
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
    zims.into_iter()
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

#[derive(Default)]
pub struct ZimSearchResult {
    pub hits: Vec<ZimHit>,
    pub failed_archives: usize,
}

/// Runs the query against every Xapian-bearing ZIM in `entries` and returns
/// the merged, bounded set of article hits. ZIMs without an embedded index are
/// skipped: their articles are already indexed into Solr by the fallback
/// extractor, so searching them here would only duplicate results. Archives
/// are queried with bounded concurrency; any single ZIM that fails
/// (missing tool, unreadable archive, timeout) is skipped rather than failing
/// the whole query, and results keep their archive ordering.
pub async fn search(
    config: &ZimSearchConfig,
    entries: &[ZimIndexEntry],
    query: &str,
) -> ZimSearchResult {
    let query = query.trim();
    let (Some(kiwix_search), Some(zimdump)) = (&config.kiwix_search, &config.zimdump) else {
        return ZimSearchResult::default();
    };
    if query.is_empty() {
        return ZimSearchResult::default();
    }

    // Refill each slot as it finishes. Waiting for an entire batch left slots
    // idle behind one slow archive and delayed archives later in the library.
    let mut remaining = entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| entry.has_xapian);
    let mut tasks = tokio::task::JoinSet::new();
    let mut failed_archives = 0;
    let mut ordered: Vec<(usize, Vec<ZimHit>)> = Vec::new();
    loop {
        while tasks.len() < MAX_ZIM_CONCURRENCY {
            let Some((index, entry)) = remaining.next() else {
                break;
            };
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
        let Some(joined) = tasks.join_next().await else {
            break;
        };
        match joined {
            Ok((index, Ok(hits))) => ordered.push((index, hits)),
            Ok((_, Err(err))) => {
                failed_archives += 1;
                eprintln!("search: ZIM query failed: {err}");
            }
            Err(err) => {
                failed_archives += 1;
                eprintln!("search: ZIM federation task failed: {err}");
            }
        }
    }
    ordered.sort_by_key(|(index, _)| *index);
    let mut hits: Vec<ZimHit> = ordered.into_iter().flat_map(|(_, hits)| hits).collect();
    hits.truncate(MAX_TOTAL_ZIM_RESULTS);
    ZimSearchResult {
        hits,
        failed_archives,
    }
}

/// Searches one ZIM archive and resolves its hits' titles and snippets.
async fn search_zim(
    kiwix_search: &Path,
    zimdump: &Path,
    zim: &Path,
    stem: &str,
    app_base: &str,
    query: &str,
) -> Result<Vec<ZimHit>, String> {
    let paths = search_paths(kiwix_search, zim, query).await?;
    let paths: Vec<String> = paths
        .into_iter()
        .take(MAX_RESULTS_PER_ZIM)
        .map(|path| path.trim().to_string())
        .filter(|path| !path.is_empty())
        .collect();

    // Resolve titles and snippets concurrently; each fetch is a `zimdump show`
    // subprocess, so serialising them let a single multi-hit archive dominate
    // the query's latency.
    let mut tasks = tokio::task::JoinSet::new();
    for (position, path) in paths.into_iter().enumerate() {
        let zimdump = zimdump.to_path_buf();
        let zim = zim.to_path_buf();
        let query = query.to_string();
        tasks.spawn(async move {
            let (title, snippet) = fetch_title_and_snippet(&zimdump, &zim, &path, &query).await;
            (position, path, title, snippet)
        });
    }
    let mut resolved: Vec<(usize, String, String, Option<String>)> = Vec::new();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok(hit) => resolved.push(hit),
            Err(err) => eprintln!("search: ZIM snippet task failed: {err}"),
        }
    }
    resolved.sort_by_key(|(position, ..)| *position);
    Ok(resolved
        .into_iter()
        .map(|(_, path, title, snippet)| ZimHit {
            title,
            snippet,
            origin_url: entry_origin(app_base, stem, &path),
            app_url: entry_origin(app_base, stem, &path),
            metadata: serde_json::json!({ "archive": stem, "entry_path": path }),
        })
        .collect())
}

/// Runs `kiwix-search ZIM PATTERN` and returns the matching entry paths.
async fn search_paths(kiwix_search: &Path, zim: &Path, query: &str) -> Result<Vec<String>, String> {
    let output = timeout(
        SEARCH_TIMEOUT,
        Command::new(kiwix_search)
            .kill_on_drop(true)
            .arg(zim)
            .arg(query)
            .output(),
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
    command.kill_on_drop(true).arg("show");
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

/// Builds a short snippet around the query's first keyword from article HTML.
/// Delegates to the shared text snippet builder so ZIM hits and indexed hits
/// render through exactly the same highlighting path.
fn make_snippet(html: &str, query: &str) -> Option<String> {
    snippet_from_html(html, query, SNIPPET_HTML_LIMIT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn fixture_tool(root: &Path, name: &str, script: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = root.join(name);
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_slow_archive_does_not_block_later_archives_or_reorder_hits() {
        let dir = tempfile::tempdir().unwrap();
        let search_tool = fixture_tool(
            dir.path(),
            "search",
            r#"#!/bin/sh
root=${1%/*}
name=${1##*/}
printf 'start %s\n' "$name" >> "$root/events"
if [ "$name" = '00.zim' ]; then
    until [ -f "$root/last-started" ]; do sleep 0.01; done
fi
if [ "$name" = '24.zim' ]; then touch "$root/last-started"; fi
printf 'end %s\n' "$name" >> "$root/events"
printf 'A/Article\n'
"#,
        );
        let zimdump = fixture_tool(
            dir.path(),
            "zimdump",
            "#!/bin/sh\nprintf '<title>Article</title><p>test article</p>'\n",
        );
        let config = ZimSearchConfig {
            kiwix_search: Some(search_tool),
            zimdump: Some(zimdump),
            library_root: dir.path().into(),
            app_base: "https://wiki.example.test".into(),
        };
        let entries: Vec<_> = (0..25)
            .map(|i| ZimIndexEntry {
                path: dir.path().join(format!("{i:02}.zim")),
                stem: format!("{i:02}"),
                has_xapian: true,
            })
            .collect();
        let result = timeout(Duration::from_secs(5), search(&config, &entries, "test"))
            .await
            .expect("the last archive must start while the first is still pending");
        let events = std::fs::read_to_string(dir.path().join("events")).unwrap();
        let mut running = 0usize;
        let mut peak = 0;
        for line in events.lines() {
            if line.starts_with("start ") {
                running += 1;
                peak = peak.max(running);
            } else {
                running -= 1;
            }
        }
        assert_eq!(running, 0);
        assert!(peak > 1 && peak <= MAX_ZIM_CONCURRENCY, "peak {peak}");
        assert_eq!(result.failed_archives, 0);
        assert_eq!(result.hits.len(), MAX_TOTAL_ZIM_RESULTS);
        let archives: Vec<_> = result
            .hits
            .iter()
            .map(|hit| hit.metadata["archive"].as_str().unwrap())
            .collect();
        let expected: Vec<_> = (0..20).map(|i| format!("{i:02}")).collect();
        assert_eq!(archives, expected);
        assert!(
            dir.path().join("last-started").exists(),
            "all archives are searched despite the result cap"
        );
    }

    #[tokio::test]
    async fn failed_archive_is_reported_instead_of_becoming_zero_matches() {
        let config = ZimSearchConfig {
            kiwix_search: Some(PathBuf::from("/nonexistent/search-fixture-tool")),
            zimdump: Some(PathBuf::from("/nonexistent/zim-fixture-tool")),
            library_root: PathBuf::from("/nonexistent/fixture-library"),
            app_base: "https://wiki.example.test".into(),
        };
        let entries = vec![ZimIndexEntry {
            path: config.library_root.join("fixture.zim"),
            stem: "fixture".into(),
            has_xapian: true,
        }];
        let result = search(&config, &entries, "test").await;
        assert!(result.hits.is_empty());
        assert_eq!(result.failed_archives, 1);
    }

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
        assert!(hits.hits.is_empty());
    }
}
