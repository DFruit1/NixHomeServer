use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::{html_title, html_to_text};
use crate::timeutil::percent_encode_path;

const FULLTEXT_BODY_LIMIT: usize = 1_000_000;
const IMAGE_EXTENSIONS: [&str; 22] = [
    "png", "jpg", "jpeg", "gif", "webp", "css", "js", "svg", "ico", "woff", "woff2", "ttf", "otf",
    "eot", "mp3", "mp4", "ogg", "ogv", "webm", "zip", "pdf", "epub",
];

pub struct KiwixExtractor {
    pub zimdump: PathBuf,
}

struct ZimListing {
    paths: Vec<String>,
}

fn list_entries(zimdump: &Path, zim: &Path) -> Result<ZimListing, String> {
    let output = Command::new(zimdump)
        .arg("list")
        .arg(zim)
        .output()
        .map_err(|err| format!("failed to run zimdump list: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "zimdump list failed for {}: {}",
            zim.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let paths = stdout
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .map(|line| {
            // Defensive: some zimdump versions prefix entries with an index or
            // tab-separated title.
            match line.split_once('\t') {
                Some((_first, second)) => second.trim().to_string(),
                None => line,
            }
        })
        .collect();
    Ok(ZimListing { paths })
}

fn dump_entry(zimdump: &Path, zim: &Path, path: &str) -> Result<Option<Vec<u8>>, String> {
    let mut attempts: Vec<Vec<&std::ffi::OsStr>> = vec![vec![
        "dump".as_ref(),
        "--path".as_ref(),
        path.as_ref(),
        zim.as_os_str(),
    ]];
    attempts.push(vec![
        "dump".as_ref(),
        zim.as_os_str(),
        "--path".as_ref(),
        path.as_ref(),
    ]);
    let mut last_error = String::new();
    for args in attempts {
        let child = match Command::new(zimdump)
            .args(&args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .stdin(std::process::Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(err) => return Err(format!("failed to run zimdump dump: {err}")),
        };
        let output = match child.wait_with_output() {
            Ok(output) => output,
            Err(err) => return Err(format!("failed to run zimdump dump: {err}")),
        };
        if output.status.success() {
            return Ok(Some(output.stdout));
        }
        last_error = String::from_utf8_lossy(&output.stderr).trim().to_string();
    }
    Err(format!("zimdump dump failed for path {path}: {last_error}"))
}

fn is_text_entry(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    let extension = lower.rsplit('.').next().unwrap_or_default();
    if extension.is_empty() || extension == lower {
        return true;
    }
    !IMAGE_EXTENSIONS.contains(&extension)
}

pub(crate) fn clean_title_from_path(path: &str) -> String {
    let segment = path.rsplit('/').next().unwrap_or(path);
    let without_extension = segment.strip_suffix(".html").unwrap_or(segment);
    let cleaned = without_extension
        .replace(['_', '+'], " ")
        .trim()
        .to_string();
    if cleaned.is_empty() {
        "Untitled".to_string()
    } else {
        cleaned
    }
}

fn matches_any(file_name: &str, patterns: &[String]) -> bool {
    patterns
        .iter()
        .any(|pattern| file_name.to_lowercase().contains(&pattern.to_lowercase()))
}

/// Reports whether the ZIM embeds its own fulltext Xapian index.
///
/// Modern ZIMs carry the index as `X/fulltext/xapian`; older ones used
/// `Z/fulltextIndex/xapian`. The index entries live in the `X` namespace, so
/// listing that namespace is a cheap way to detect them (unlike listing the
/// whole archive, which can run to millions of articles). Any failure — a
/// missing zimdump, an unreadable ZIM, a name-space that does not exist — is
/// treated as "no index", which lets the caller fall back to extraction.
pub(crate) fn has_xapian_fulltext(zimdump: &Path, zim: &Path) -> bool {
    let output = Command::new(zimdump)
        .arg("list")
        .arg("--ns=X")
        .arg("--")
        .arg(zim)
        .output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    contains_fulltext_index(&String::from_utf8_lossy(&output.stdout))
}

fn contains_fulltext_index(listing: &str) -> bool {
    listing.contains("fulltext/xapian") || listing.contains("fulltextIndex/xapian")
}

/// Cheap fingerprint of a Kiwix source's inputs: the set of ZIM files and each
/// file's length and mtime, plus the configured settings (so changing
/// `fulltextZims` re-extracts). ZIM files are immutable once written, so an
/// unchanged fingerprint means the source cannot have changed and the whole
/// extraction (the `zimdump list`/`dump` calls that dominate a pass) can be
/// skipped. Returns `None` when the library root is unreadable, which leaves
/// the indexer to extraction and its normal error path.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let library_root = source.require_setting("libraryRoot").ok()?;
    let mut zims: Vec<PathBuf> = std::fs::read_dir(PathBuf::from(&library_root))
        .ok()?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("zim")
        })
        .collect();
    zims.sort();
    let mut parts: Vec<String> = Vec::with_capacity(zims.len());
    for zim in zims {
        let meta = std::fs::metadata(&zim).ok()?;
        let mtime_nanos = meta
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let name = zim
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        parts.push(format!("{name}\u{1f}{}\u{1f}{mtime_nanos}", meta.len()));
    }
    let settings = serde_json::to_string(&source.settings).ok()?;
    Some(crate::timeutil::sha256_hex(&[
        &source.source_type,
        &settings,
        &parts.join("\n"),
    ]))
}

pub(crate) fn entry_origin(app_base: &str, zim_stem: &str, entry_path: &str) -> String {
    format!(
        "{}/content/{}/{}",
        app_base.trim_end_matches('/'),
        percent_encode_path(zim_stem),
        percent_encode_path(entry_path)
    )
}

impl super::Extractor for KiwixExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let library_root = source.require_setting("libraryRoot")?;
        let fulltext_patterns = source.setting_str_list("fulltextZims");
        let metadata_patterns = source.setting_str_list("metadataZims");
        let library_dir = PathBuf::from(&library_root);
        let app_base = source.app_base.trim_end_matches('/').to_string();

        let mut zims: Vec<PathBuf> = std::fs::read_dir(&library_dir)
            .map_err(|err| format!("failed to read kiwix library root: {err}"))?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("zim")
            })
            .collect();
        zims.sort();

        for zim in zims {
            let file_name = zim
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .to_string();
            let zim_stem = file_name.trim_end_matches(".zim").to_string();
            let has_xapian = has_xapian_fulltext(&self.zimdump, &zim);
            // The ZIM's own embedded Xapian index is the authoritative
            // fulltext search for this archive (served natively by
            // kiwix-serve). When it is present we deliberately do not re-extract
            // every article body into Solr, which would duplicate a multi-million
            // article index for no benefit. We only fall back to per-article
            // extraction for ZIMs that carry no embedded index.
            let fulltext = !has_xapian && matches_any(&file_name, &fulltext_patterns);
            let metadata = !has_xapian && (matches_any(&file_name, &metadata_patterns) || fulltext);

            emit(ExtractedDocument {
                external_id: crate::timeutil::sha256_hex(&[&file_name]),
                kind: "zim-archive".to_string(),
                title: zim_stem.clone(),
                body_text: String::new(),
                content_type: "application/x-zim".to_string(),
                origin_url: entry_origin(&app_base, &zim_stem, ""),
                app_url: app_base.clone(),
                file_path: zim.display().to_string(),
                size_bytes: std::fs::metadata(&zim)
                    .map(|meta| meta.len() as i64)
                    .unwrap_or(0),
                content_created_at: None,
                content_modified_at: None,
                metadata: serde_json::json!({
                    "xapian": has_xapian.to_string(),
                    "fulltext": fulltext.to_string(),
                    "articles": metadata.to_string(),
                    "owner": "shared",
                }),
            });

            if !metadata {
                continue;
            }
            let listing = list_entries(&self.zimdump, &zim)?;
            let mut seen = HashSet::new();
            for entry_path in listing.paths {
                if !is_text_entry(&entry_path) || !seen.insert(entry_path.clone()) {
                    continue;
                }
                let title = clean_title_from_path(&entry_path);
                let mut body = String::new();
                let mut html_title_value = title.clone();
                if fulltext {
                    if let Some(bytes) = dump_entry(&self.zimdump, &zim, &entry_path)? {
                        let html = String::from_utf8_lossy(&bytes).into_owned();
                        if let Some(found) = html_title(&html) {
                            html_title_value = found;
                        }
                        body = truncate(&html_to_text(&html), FULLTEXT_BODY_LIMIT);
                    }
                }
                emit(ExtractedDocument {
                    external_id: crate::timeutil::sha256_hex(&[&file_name, &entry_path]),
                    kind: "zim-article".to_string(),
                    title: html_title_value,
                    body_text: body,
                    content_type: "text/html".to_string(),
                    origin_url: entry_origin(&app_base, &zim_stem, &entry_path),
                    app_url: app_base.clone(),
                    file_path: format!("{}#{}", zim.display(), entry_path),
                    size_bytes: 0,
                    content_created_at: None,
                    content_modified_at: None,
                    metadata: serde_json::json!({
                        "archive": zim_stem,
                        "entry_path": entry_path,
                        "owner": "shared",
                    }),
                });
            }
        }
        Ok(())
    }
}

fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        value.to_string()
    } else {
        let mut truncated = value[..limit].to_string();
        while !truncated.is_char_boundary(truncated.len()) {
            truncated.pop();
        }
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_entries() {
        assert!(is_text_entry("A/Some_article.html"));
        assert!(is_text_entry("A/mainPage"));
        assert!(!is_text_entry("I/img.png"));
        assert!(!is_text_entry("-/style.css"));
    }

    #[test]
    fn cleans_titles() {
        assert_eq!(clean_title_from_path("A/Hello_World.html"), "Hello World");
        assert_eq!(clean_title_from_path("A/"), "Untitled");
    }

    #[test]
    fn builds_origin_urls() {
        assert_eq!(
            entry_origin("https://wiki.example.org", "wikipedia_en_all", "A/Foo.html"),
            "https://wiki.example.org/content/wikipedia_en_all/A/Foo.html"
        );
        assert_eq!(
            entry_origin("https://wiki.example.org", "z", "A/Has Space.html"),
            "https://wiki.example.org/content/z/A/Has%20Space.html"
        );
    }

    #[test]
    fn truncates_on_char_boundaries() {
        let value = "héllo".repeat(10);
        let truncated = truncate(&value, 3);
        assert!(truncated.len() <= 3);
        assert!(value.starts_with(&truncated));
    }

    #[test]
    fn level_matching_is_case_insensitive_substring() {
        let patterns = vec!["WIKISOURCE".to_string()];
        assert!(matches_any("wikisource_en_all_maxi_2026-02.zim", &patterns));
        assert!(!matches_any("wikibooks_en_all_maxi_2026-04.zim", &patterns));
        assert!(!matches_any("wikisource_en_all_maxi_2026-02.zim", &[]));
    }

    #[test]
    fn fingerprint_tracks_zim_inventory_and_settings() {
        let dir = tempfile::tempdir().expect("tempdir");
        let library = dir.path().join("library");
        std::fs::create_dir_all(&library).expect("mkdir");
        std::fs::write(library.join("wiki.zim"), b"zim").expect("write");

        let parse = |library: &Path| {
            let raw = format!(
                r#"[{{"id":"kiwix","source_type":"kiwix","app_base":"https://wiki.example.org","settings":{{"libraryRoot":"{}"}}}}]"#,
                library.display()
            );
            crate::config::parse_sources(&raw)
                .expect("sources")
                .remove(0)
        };

        let source = parse(&library);
        let first = source_fingerprint(&source).expect("fingerprint");
        // Recomputing with unchanged inputs is stable, so a pass can be skipped.
        assert_eq!(source_fingerprint(&source), Some(first.clone()));

        // Adding a ZIM changes the fingerprint and forces re-extraction.
        std::fs::write(library.join("books.zim"), b"zim").expect("write");
        let second = source_fingerprint(&source).expect("fingerprint");
        assert_ne!(first, second);

        // Changing the extraction settings also changes the fingerprint.
        let raw = format!(
            r#"[{{"id":"kiwix","source_type":"kiwix","app_base":"https://wiki.example.org","settings":{{"libraryRoot":"{}","fulltextZims":["wiki"]}}}}]"#,
            library.display()
        );
        let configured = crate::config::parse_sources(&raw)
            .expect("sources")
            .remove(0);
        assert_ne!(source_fingerprint(&configured), Some(second));

        // An unreadable library root yields no fingerprint, so the indexer
        // falls back to extraction and its normal error path.
        let missing = parse(Path::new("/nonexistent/library/root"));
        assert_eq!(source_fingerprint(&missing), None);
    }

    #[test]
    fn detects_embedded_fulltext_index() {
        // Modern ZIMs expose the Xapian index in the X namespace.
        assert!(contains_fulltext_index("fulltext/xapian\ntitle/xapian"));
        assert!(contains_fulltext_index("X/fulltext/xapian"));
        // Legacy path variant.
        assert!(contains_fulltext_index("Z/fulltextIndex/xapian"));
        // A namespace listing with no index must be treated as absent.
        assert!(!contains_fulltext_index(""));
        assert!(!contains_fulltext_index("illustration.png\nindex.html"));
        assert!(!contains_fulltext_index("title/xapian"));
    }
}
