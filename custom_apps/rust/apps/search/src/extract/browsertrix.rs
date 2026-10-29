use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Cursor, Read};
use std::path::{Path, PathBuf};

use flate2::read::{MultiGzDecoder, ZlibDecoder};
use serde_json::Value;
use zip::ZipArchive;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::{decode_document_text, html_title, html_to_text, truncate_text};
use crate::timeutil::{parse_date, sha256_hex};

const MAX_PAGE_TEXT_BYTES: usize = 400_000;
const MAX_RESPONSE_BYTES: u64 = 16_000_000;

pub struct BrowsertrixExtractor {
    pub pdftotext: Option<PathBuf>,
}

struct CapturedContent {
    title: String,
    text: String,
    content_type: String,
    timestamp: Option<i64>,
}

struct PageRecord {
    url: String,
    title: Option<String>,
    timestamp: Option<i64>,
    text: Option<String>,
    content_type: String,
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
                content_type: "text/html".to_string(),
            })
        })
        .collect()
}

/// Parses captured documents without fetching their URLs.
///
/// The gzip stream is decompressed incrementally and parsed record-by-record
/// into the crawl's page set, without collecting a second copy of its text.
/// Successful URLs are shared across WARC members so duplicate responses are
/// discarded before HTML/office conversion or PDF subprocesses run again.
fn parse_warc_content<R: Read>(
    reader: R,
    pdftotext: Option<&Path>,
    captured_urls: &mut HashSet<String>,
    emit: &mut dyn FnMut(String, CapturedContent),
) {
    // WARC writers commonly gzip each record independently, then concatenate
    // the members. A single-member decoder silently loses every later page.
    let mut decoder = BufReader::new(MultiGzDecoder::new(reader));
    while let Some(record) = read_warc_record(&mut decoder) {
        if record.record_type != "response" {
            continue;
        }
        if !url::Url::parse(&record.target_uri)
            .is_ok_and(|url| matches!(url.scheme(), "http" | "https"))
            || captured_urls.contains(&record.target_uri)
        {
            continue;
        }
        if let Some(mut content) = captured_content(&record.payload, pdftotext) {
            content.timestamp = record.timestamp;
            captured_urls.insert(record.target_uri.clone());
            emit(record.target_uri, content);
        }
    }
}

fn looks_like_html(body: &str) -> bool {
    let lower = body.to_ascii_lowercase();
    lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<body")
}

struct WarcRecord {
    record_type: String,
    target_uri: String,
    payload: Vec<u8>,
    timestamp: Option<i64>,
}

fn read_warc_record<R: BufRead>(reader: &mut R) -> Option<WarcRecord> {
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
        if headers.len() > 65_536 {
            return None;
        }
    }
    if !saw_any {
        return None;
    }

    let mut record_type = String::new();
    let mut target_uri = String::new();
    let mut content_length = None;
    let mut timestamp = None;
    for line in headers.lines() {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "warc-type" => record_type = value.to_string(),
            "warc-target-uri" => target_uri = value.to_string(),
            "content-length" => content_length = value.parse::<u64>().ok(),
            "warc-date" => timestamp = parse_date(value),
            _ => {}
        }
    }
    if !first_line.starts_with("WARC/") {
        return None;
    }

    let content_length = content_length?;
    let mut payload = Vec::new();
    if content_length <= MAX_RESPONSE_BYTES && record_type == "response" {
        reader.take(content_length).read_to_end(&mut payload).ok()?;
        if payload.len() as u64 != content_length {
            return None;
        }
    } else if std::io::copy(&mut reader.take(content_length), &mut std::io::sink()).ok()?
        != content_length
    {
        return None;
    }
    // The next header read skips optional blank record separators.
    Some(WarcRecord {
        record_type,
        target_uri,
        payload,
        timestamp,
    })
}

fn read_line<R: BufRead>(reader: &mut R) -> Option<String> {
    let mut line = Vec::new();
    // Bound the read itself: read_until without take could allocate an entire
    // malformed archive while searching for a missing newline.
    if reader.take(65_538).read_until(b'\n', &mut line).ok()? == 0 {
        return None;
    }
    if line.ends_with(b"\n") {
        line.pop();
    }
    if line.len() > 65_536 {
        return None;
    }
    if line.ends_with(b"\r") {
        line.pop();
    }
    Some(String::from_utf8_lossy(&line).into_owned())
}

fn http_response(payload: &[u8]) -> Option<(&str, &[u8])> {
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
    if separator > 65_536 {
        return None;
    }
    let headers = std::str::from_utf8(&payload[..separator]).ok()?;
    Some((headers, &payload[separator..]))
}

fn unchunk(mut bytes: &[u8]) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let line_end = bytes.windows(2).position(|pair| pair == b"\r\n")?;
        let size = std::str::from_utf8(&bytes[..line_end])
            .ok()?
            .split(';')
            .next()?;
        let size = usize::from_str_radix(size.trim(), 16).ok()?;
        bytes = bytes.get(line_end + 2..)?;
        if size == 0 {
            return Some(body);
        }
        if size > MAX_RESPONSE_BYTES as usize - body.len()
            || bytes.get(size..size.checked_add(2)?)? != b"\r\n"
        {
            return None;
        }
        body.extend_from_slice(bytes.get(..size)?);
        bytes = &bytes[size + 2..];
    }
}

fn captured_content(payload: &[u8], pdftotext: Option<&Path>) -> Option<CapturedContent> {
    let (headers, bytes) = http_response(payload)?;
    let status = headers
        .lines()
        .next()?
        .split_whitespace()
        .nth(1)?
        .parse::<u16>()
        .ok()?;
    if !(200..300).contains(&status) {
        return None;
    }
    let header = |key: &str| {
        headers
            .lines()
            .skip(1)
            .filter_map(|line| line.split_once(':'))
            .find(|(name, _)| name.trim().eq_ignore_ascii_case(key))
            .map(|(_, value)| value.trim())
    };
    let mime = header("content-type")
        .unwrap_or_default()
        .split(';')
        .next()?
        .trim()
        .to_ascii_lowercase();
    // Reuse the bounded document readers used for books and mail attachments.
    // Macros are never executed, and ZIP members are never unpacked to disk.
    let document_format = match mime.as_str() {
        "application/epub+zip" => Some("epub"),
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => Some("docx"),
        "application/vnd.ms-word.document.macroenabled.12" => Some("docm"),
        "application/vnd.oasis.opendocument.text" => Some("odt"),
        "application/vnd.oasis.opendocument.spreadsheet" => Some("ods"),
        "application/vnd.oasis.opendocument.presentation" => Some("odp"),
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => Some("xlsx"),
        "application/vnd.ms-excel.sheet.macroenabled.12" => Some("xlsm"),
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" => Some("pptx"),
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow" => Some("ppsx"),
        "application/vnd.ms-powerpoint.presentation.macroenabled.12" => Some("pptm"),
        "application/x-fictionbook+xml" => Some("fb2"),
        _ => None,
    };
    // Keep captured scripts, styles, images and API responses out of results.
    if document_format.is_none()
        && !matches!(
            mime.as_str(),
            "" | "text/html"
                | "application/xhtml+xml"
                | "text/plain"
                | "text/markdown"
                | "text/csv"
                | "text/tab-separated-values"
                | "application/pdf"
        )
    {
        return None;
    }
    let bytes = match header("transfer-encoding")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "chunked" => Cow::Owned(unchunk(bytes)?),
        "" | "identity" => Cow::Borrowed(bytes),
        _ => return None,
    };
    let bytes = match header("content-encoding")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "" | "identity" => bytes,
        "gzip" | "x-gzip" => Cow::Owned(decode_response(MultiGzDecoder::new(bytes.as_ref()))?),
        // HTTP deflate uses the zlib wrapper (RFC 9110, section 8.4.1.2).
        "deflate" => Cow::Owned(decode_response(ZlibDecoder::new(bytes.as_ref()))?),
        _ => return None,
    };
    let (title, text, content_type) = if let Some(format) = document_format {
        let text = if format == "fb2" {
            super::document::xml_text(&decode_document_text(&bytes))?
        } else {
            super::document::zip_text(Cursor::new(bytes.as_ref()), format)?
        };
        (String::new(), text, mime)
    } else if mime == "application/pdf" {
        (
            String::new(),
            super::paperless::extract_pdf_bytes(&bytes, pdftotext).ok()?,
            mime,
        )
    } else {
        let raw = decode_document_text(&bytes);
        if matches!(mime.as_str(), "text/html" | "application/xhtml+xml")
            || (mime.is_empty() && looks_like_html(&raw))
        {
            (
                html_title(&raw).unwrap_or_default(),
                html_to_text(&raw),
                "text/html".to_string(),
            )
        } else if !mime.is_empty() {
            (String::new(), raw, mime)
        } else {
            return None;
        }
    };
    if text.trim().is_empty() && title.trim().is_empty() {
        return None;
    }
    Some(CapturedContent {
        title: truncate_text(&title, 2_000),
        text: truncate_text(&text, MAX_PAGE_TEXT_BYTES),
        content_type,
        timestamp: None,
    })
}

fn decode_response(reader: impl Read) -> Option<Vec<u8>> {
    let mut decoded = Vec::new();
    reader
        .take(MAX_RESPONSE_BYTES + 1)
        .read_to_end(&mut decoded)
        .ok()?;
    (decoded.len() as u64 <= MAX_RESPONSE_BYTES).then_some(decoded)
}

fn parse_wacz(path: &PathBuf, pdftotext: Option<&Path>) -> Result<CrawlPackage, String> {
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

    if let Ok(entry) = archive.by_name("datapackage.json")
        && let Ok(value) = serde_json::from_reader::<_, Value>(entry)
    {
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

    // Browsertrix may put discovered pages in extraPages.jsonl or split a
    // crawl across multiple page lists. Read them all, preferring the normal
    // pages.jsonl record and filling missing fields from duplicate URLs.
    let mut page_lists: Vec<String> = archive
        .file_names()
        .filter(|name| {
            (name.starts_with("pages/") && name.ends_with(".jsonl"))
                || name.ends_with("pages.jsonl")
        })
        .map(str::to_string)
        .collect();
    page_lists.sort_by_key(|name| (name != "pages/pages.jsonl", name.clone()));
    let mut positions = HashMap::new();
    for name in page_lists {
        let mut raw = String::new();
        archive
            .by_name(&name)
            .map_err(|err| format!("failed to read WACZ page list {name}: {err}"))?
            .read_to_string(&mut raw)
            .map_err(|err| format!("failed to decode WACZ page list {name}: {err}"))?;
        for mut page in parse_pages_jsonl(&raw) {
            page.text = page
                .text
                .map(|text| truncate_text(&text, MAX_PAGE_TEXT_BYTES));
            if let Some(&position) = positions.get(&page.url) {
                let existing: &mut PageRecord = &mut package.pages[position];
                existing.title = existing.title.take().or(page.title);
                existing.text = existing.text.take().or(page.text);
                existing.timestamp = existing.timestamp.or(page.timestamp);
            } else {
                positions.insert(page.url.clone(), package.pages.len());
                package.pages.push(page);
            }
        }
    }

    // Page lists describe browser visits, but captures also hold linked PDFs,
    // text downloads and HTML pages absent from those lists. Include those
    // documents too, preserving page-list text and the first successful capture.
    let mut captured_urls = HashSet::new();
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
        parse_warc_content(entry, pdftotext, &mut captured_urls, &mut |url, content| {
            if let Some(&position) = positions.get(&url) {
                let page = &mut package.pages[position];
                if page.title.is_none() && !content.title.is_empty() {
                    page.title = Some(content.title);
                }
                if page.text.as_ref().is_none_or(|text| text.trim().is_empty()) {
                    page.text = Some(content.text);
                }
                page.content_type = content.content_type;
                page.timestamp = page.timestamp.or(content.timestamp);
            } else {
                positions.insert(url.clone(), package.pages.len());
                package.pages.push(PageRecord {
                    url,
                    title: (!content.title.is_empty()).then_some(content.title),
                    timestamp: content.timestamp,
                    text: Some(content.text),
                    content_type: content.content_type,
                });
            }
        });
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
            let package = parse_wacz(&wacz, self.pdftotext.as_deref())?;
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
                    kind: if page.content_type == "text/html" {
                        "web-page"
                    } else {
                        "document"
                    }
                    .to_string(),
                    title,
                    body_text: page.text.clone().unwrap_or_default(),
                    content_type: page.content_type.clone(),
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
        let (_, body) = http_response(payload).expect("body");
        let body = decode_document_text(body);
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

        let mut map = HashMap::new();
        parse_warc_content(
            Cursor::new(compressed),
            None,
            &mut HashSet::new(),
            &mut |url, content| {
                map.insert(url, content);
            },
        );
        let content = map.get("https://example.org/a").expect("record");
        assert_eq!(content.title, "Page A");
        assert!(content.text.contains("Hello world"));
    }
}
