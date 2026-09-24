use std::collections::HashMap;
use std::io::{BufReader, Read};
use std::path::PathBuf;

use flate2::read::GzDecoder;
use serde_json::Value;
use zip::ZipArchive;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::{html_title, html_to_text};
use crate::timeutil::{parse_date, sha256_hex};

const MAX_PAGE_TEXT_BYTES: usize = 400_000;

pub struct BrowsertrixExtractor;

struct PageRecord {
    url: String,
    title: Option<String>,
    timestamp: Option<i64>,
    text: Option<String>,
}

struct CrawlPackage {
    name: String,
    title: String,
    description: String,
    pages: Vec<PageRecord>,
}

fn parse_pages_jsonl(raw: &str) -> Vec<PageRecord> {
    raw.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            let value: Value = serde_json::from_str(line).ok()?;
            let url = value.get("url").and_then(Value::as_str)?.to_string();
            if url.is_empty() {
                return None;
            }
            Some(PageRecord {
                url,
                title: value
                    .get("title")
                    .and_then(Value::as_str)
                    .filter(|title| !title.trim().is_empty())
                    .map(str::to_string),
                timestamp: value
                    .get("ts")
                    .and_then(Value::as_str)
                    .and_then(parse_date)
                    .or_else(|| value.get("ts").and_then(Value::as_f64).map(|ts| ts as i64))
                    .or_else(|| value.get("ts").and_then(Value::as_i64)),
                text: value
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !text.trim().is_empty())
                    .map(str::to_string),
            })
        })
        .collect()
}

/// Parses one WARC stream, returning URL -> (title, text) for HTML responses.
///
/// The gzip stream is decompressed incrementally and parsed record-by-record
/// so only one WARC record's payload is ever held in memory, instead of the
/// whole (potentially multi-hundred-MB) decompressed archive.
pub fn parse_warc_html<R: Read>(reader: R) -> HashMap<String, (String, String)> {
    let mut results = HashMap::new();
    let mut decoder = GzDecoder::new(reader);
    while let Some(record) = read_warc_record(&mut decoder) {
        if record.record_type != "response" {
            continue;
        }
        let html = match http_body(&record.payload) {
            Some(body) => body,
            None => continue,
        };
        if !looks_like_html(&html) {
            continue;
        }
        let title = html_title(&html).unwrap_or_default();
        let text = html_to_text(&html);
        if text.trim().is_empty() && title.is_empty() {
            continue;
        }
        results.entry(record.target_uri.clone()).or_insert((
            truncate(&title, 2_000),
            truncate(&text, MAX_PAGE_TEXT_BYTES),
        ));
    }
    results
}

fn looks_like_html(body: &str) -> bool {
    let lower = body.to_ascii_lowercase();
    lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<body")
}

struct WarcRecord {
    record_type: String,
    target_uri: String,
    payload: Vec<u8>,
}

fn read_warc_record<R: Read>(reader: &mut R) -> Option<WarcRecord> {
    let mut headers = String::new();
    let mut first_line = String::new();
    let mut saw_any = false;
    loop {
        let line = read_line(reader)?;
        if line.trim().is_empty() {
            if !saw_any {
                continue;
            }
            break;
        }
        saw_any = true;
        if first_line.is_empty() {
            first_line = line.trim().to_string();
        }
        headers.push_str(&line);
        headers.push('\n');
    }
    if !saw_any {
        return None;
    }

    let mut record_type = String::new();
    let mut target_uri = String::new();
    let mut content_length: usize = 0;
    for line in headers.lines() {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "warc-type" => record_type = value.to_string(),
            "warc-target-uri" => target_uri = value.to_string(),
            "content-length" => content_length = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    if !first_line.starts_with("WARC/") {
        return Some(WarcRecord {
            record_type,
            target_uri,
            payload: Vec::new(),
        });
    }

    let mut payload = vec![0u8; content_length];
    reader.read_exact(&mut payload).ok()?;
    // Consume the trailing CRLF CRLF separator.
    let mut separator = [0u8; 4];
    let read = reader.read(&mut separator).unwrap_or(0);
    if &separator[..read] != b"\r\n\r\n" {
        // Some writers omit the trailing separator; seek back what we can.
        let _ = read;
    }
    Some(WarcRecord {
        record_type,
        target_uri,
        payload,
    })
}

fn read_line<R: Read>(reader: &mut R) -> Option<String> {
    let mut line = Vec::new();
    loop {
        let mut byte = [0u8; 1];
        match reader.read(&mut byte) {
            Ok(0) => {
                if line.is_empty() {
                    return None;
                }
                break;
            }
            Ok(_) => {
                if byte[0] == b'\n' {
                    break;
                }
                line.push(byte[0]);
            }
            Err(_) => return None,
        }
    }
    if line.is_empty() {
        return Some(String::new());
    }
    if line.ends_with(b"\r") {
        line.pop();
    }
    Some(String::from_utf8_lossy(&line).into_owned())
}

/// Splits an HTTP response payload into its body.
pub fn http_body(payload: &[u8]) -> Option<String> {
    let separator = payload
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
        .or_else(|| {
            payload
                .windows(2)
                .position(|window| window == b"\n\n")
                .map(|position| position + 2)
        })?;
    Some(String::from_utf8_lossy(&payload[separator..]).into_owned())
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

fn parse_wacz(path: &PathBuf) -> Result<CrawlPackage, String> {
    let file = std::fs::File::open(path)
        .map_err(|err| format!("failed to open {}: {err}", path.display()))?;
    let mut archive = ZipArchive::new(BufReader::new(file))
        .map_err(|err| format!("failed to read WACZ {}: {err}", path.display()))?;

    let mut package = CrawlPackage {
        name: path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("crawl")
            .to_string(),
        title: String::new(),
        description: String::new(),
        pages: Vec::new(),
    };

    if let Ok(entry) = archive.by_name("datapackage.json") {
        if let Ok(value) = serde_json::from_reader::<_, Value>(entry) {
            package.name = value
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .unwrap_or(package.name);
            package.title = value
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            package.description = value
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
        }
    }

    let pages_jsonl = archive
        .by_name("pages/pages.jsonl")
        .ok()
        .map(|mut entry| {
            let mut raw = String::new();
            let _ = entry.read_to_string(&mut raw);
            raw
        })
        .or_else(|| {
            let mut names: Vec<String> = archive
                .file_names()
                .filter(|name| name.ends_with("pages.jsonl"))
                .map(str::to_string)
                .collect();
            names.sort();
            names
                .into_iter()
                .next()
                .and_then(|name| archive.by_name(&name).ok())
                .map(|mut entry| {
                    let mut raw = String::new();
                    let _ = entry.read_to_string(&mut raw);
                    raw
                })
        });
    if let Some(raw) = pages_jsonl {
        package.pages = parse_pages_jsonl(&raw);
    }

    // Extract page text for pages the pages.jsonl did not carry.
    let page_urls: Vec<String> = package.pages.iter().map(|page| page.url.clone()).collect();
    let mut warc_text: HashMap<String, (String, String)> = HashMap::new();
    let mut warc_names: Vec<String> = archive
        .file_names()
        .filter(|name| name.ends_with(".warc.gz"))
        .map(str::to_string)
        .collect();
    warc_names.sort();
    for name in warc_names {
        let Ok(entry) = archive.by_name(&name) else {
            continue;
        };
        let parsed = parse_warc_html(entry);
        for url in &page_urls {
            if let Some(found) = parsed.get(url) {
                warc_text
                    .entry(url.clone())
                    .or_insert_with(|| found.clone());
            }
        }
    }

    for page in &mut package.pages {
        if page.text.as_ref().map(|text| text.trim().is_empty()) != Some(false) {
            if let Some((title, text)) = warc_text.get(&page.url) {
                if page.title.is_none() && !title.is_empty() {
                    page.title = Some(title.clone());
                }
                page.text = Some(text.clone());
            }
        }
    }

    Ok(package)
}

impl super::Extractor for BrowsertrixExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let archive_root = source.require_setting("archiveRoot")?;
        let app_base = source.app_base.trim_end_matches('/').to_string();
        let mut wacz_files: Vec<PathBuf> = walk(&PathBuf::from(&archive_root), 0);
        wacz_files.sort();

        for wacz in wacz_files {
            let file_name = wacz
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .to_string();
            let package = parse_wacz(&wacz)?;
            let crawl_title = if package.title.is_empty() {
                package.name.clone()
            } else {
                package.title.clone()
            };
            let crawl_base = sha256_hex(&[&file_name]);

            emit(ExtractedDocument {
                external_id: format!("{crawl_base}-crawl"),
                kind: "web-crawl".to_string(),
                title: crawl_title.clone(),
                body_text: package.description.clone(),
                content_type: "application/wacz".to_string(),
                origin_url: String::new(),
                app_url: app_base.clone(),
                file_path: wacz.display().to_string(),
                size_bytes: std::fs::metadata(&wacz)
                    .map(|meta| meta.len() as i64)
                    .unwrap_or(0),
                content_created_at: None,
                content_modified_at: None,
                metadata: serde_json::json!({ "crawl": package.name, "owner": "shared" }),
            });

            for page in &package.pages {
                let title = page
                    .title
                    .clone()
                    .filter(|title| !title.trim().is_empty())
                    .unwrap_or_else(|| page.url.clone());
                emit(ExtractedDocument {
                    external_id: sha256_hex(&[&crawl_base, &page.url]),
                    kind: "web-page".to_string(),
                    title,
                    body_text: page.text.clone().unwrap_or_default(),
                    content_type: "text/html".to_string(),
                    origin_url: page.url.clone(),
                    app_url: app_base.clone(),
                    file_path: wacz.display().to_string(),
                    size_bytes: 0,
                    content_created_at: page.timestamp,
                    content_modified_at: None,
                    metadata: serde_json::json!({ "crawl": package.name, "owner": "shared" }),
                });
            }
        }
        Ok(())
    }
}

fn walk(dir: &PathBuf, depth: usize) -> Vec<PathBuf> {
    if depth > 4 {
        return Vec::new();
    }
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in entries.filter_map(|entry| entry.ok()) {
        let path = entry.path();
        if path.is_dir() {
            found.extend(walk(&path, depth + 1));
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("wacz") {
            found.push(path);
        }
    }
    found
}

/// Fingerprints every `.wacz` crawl archive (path, size, mtime) plus the source
/// settings. WACZ archives are immutable once written, so an unchanged
/// inventory means the expensive per-archive parsing can be skipped. Returns
/// `None` when no archive is found, so the indexer still runs extraction.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let archive_root = source.setting_str("archiveRoot")?;
    let mut files = walk(&PathBuf::from(archive_root), 0);
    if files.is_empty() {
        return None;
    }
    files.sort();
    super::file_inventory_fingerprint(source, files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};

    const PAGES_JSONL: &str = r#"
{"id":"1","url":"https://example.org/","title":"Example","ts":"2024-03-01T00:00:00Z","text":"already have text"}
{"id":"2","url":"https://example.org/about","title":"About"}
{"url":"","title":"broken"}
not json
"#;

    #[test]
    fn parses_pages_jsonl() {
        let pages = parse_pages_jsonl(PAGES_JSONL);
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[0].title.as_deref(), Some("Example"));
        assert_eq!(pages[0].text.as_deref(), Some("already have text"));
        assert_eq!(pages[0].timestamp, Some(1_709_251_200));
        assert!(pages[1].text.is_none());
    }

    #[test]
    fn splits_http_payloads() {
        let payload =
            b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body>Hi</body></html>";
        let body = http_body(payload).expect("body");
        assert!(body.contains("Hi"));
        assert!(looks_like_html(&body));
        assert!(!looks_like_html("plain text"));
    }

    #[test]
    fn parses_simple_warc_stream() {
        let mut warc = String::new();
        warc.push_str("WARC/1.0\r\n");
        warc.push_str("WARC-Type: response\r\n");
        warc.push_str("WARC-Target-URI: https://example.org/a\r\n");
        let payload = b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><title>Page A</title><body>Hello world</body></html>";
        warc.push_str(&format!("Content-Length: {}\r\n", payload.len()));
        warc.push_str("\r\n");
        warc.push_str(std::str::from_utf8(payload).unwrap());
        warc.push_str("\r\n\r\n");

        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gzip.write_all(warc.as_bytes()).expect("gzip");
        let compressed = gzip.finish().expect("gzip finish");

        let map = parse_warc_html(Cursor::new(compressed));
        let (title, text) = map.get("https://example.org/a").expect("record");
        assert_eq!(title, "Page A");
        assert!(text.contains("Hello world"));
    }
}
