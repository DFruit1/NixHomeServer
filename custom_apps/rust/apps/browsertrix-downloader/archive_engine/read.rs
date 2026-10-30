use super::*;
use flate2::{bufread::GzDecoder, read::MultiGzDecoder};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap},
    fs::File,
    io::{Cursor, Read},
};
use zip::ZipArchive;

pub(super) const MAX_BYTES: usize = 256 * 1024 * 1024;
pub(super) const MAX_RECORD: usize = 32 * 1024 * 1024;
pub(super) const MAX_ITEMS: usize = 50_000;
const MAX_HEADER: usize = 64 * 1024;

pub(super) fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub(super) fn bounded(reader: impl Read, limit: usize) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    reader
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err(format!("Inflated byte limit exceeded ({limit})"));
    }
    Ok(bytes)
}

#[derive(Clone, Debug)]
pub(super) struct Record {
    pub headers: BTreeMap<String, String>,
    pub block: Vec<u8>,
    pub payload: Vec<u8>,
    pub status: u16,
    pub mime: String,
    pub member: String,
    pub offset: u64,
    pub length: u64,
    pub stored: u64,
}
impl Record {
    pub fn field(&self, key: &str) -> &str {
        self.headers.get(key).map(String::as_str).unwrap_or("")
    }
    pub fn url(&self) -> &str {
        self.field("warc-target-uri")
    }
    pub fn kind(&self) -> &str {
        self.field("warc-type")
    }
    pub fn digest(&self) -> String {
        format!("sha256:{}", hash(&self.payload))
    }
}

pub(super) struct Archive {
    pub report: ArchiveReport,
    pub records: Vec<Record>,
    pub page_meta: Vec<PageRecord>,
}

pub(super) fn load(path: &Path) -> Result<Archive, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let archive_bytes = file.metadata().map_err(|e| e.to_string())?.len();
    if archive_bytes > MAX_BYTES as u64 {
        return Err("Archive file exceeds 256 MiB engine limit".into());
    }
    let mut hasher = Sha256::new();
    let mut hashing = file.try_clone().map_err(|e| e.to_string())?;
    std::io::copy(&mut hashing, &mut hasher).map_err(|e| e.to_string())?;
    // File clones share a seek offset on Unix; reopen before parsing.
    let mut zip =
        ZipArchive::new(File::open(path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    if zip.len() > 10_000 {
        return Err("ZIP member count exceeds 10000".into());
    }
    let mut members = BTreeMap::<String, Vec<u8>>::new();
    let mut total = 0usize;
    for index in 0..zip.len() {
        let entry = zip.by_index(index).map_err(|e| e.to_string())?;
        let name = entry.name().to_owned();
        if name.len() > 1024
            || name.contains('\\')
            || name.contains(':')
            || name.chars().any(char::is_control)
            || name.starts_with('/')
            || name.split('/').any(|p| p == ".." || p == ".")
            || entry.enclosed_name().is_none()
            || entry.encrypted()
            || entry.unix_mode().is_some_and(|mode| {
                mode & 0o170000 != 0 && mode & 0o170000 != 0o100000 && mode & 0o170000 != 0o040000
            })
        {
            return Err("Unsafe ZIP member name, encryption or special file".into());
        }
        if entry.is_dir() {
            continue;
        }
        if members.contains_key(&name) {
            return Err("Duplicate ZIP member".into());
        }
        let bytes = bounded(entry, MAX_BYTES - total)?;
        total += bytes.len();
        members.insert(name, bytes);
    }
    let manifest: Value = serde_json::from_slice(
        members
            .get("datapackage.json")
            .ok_or("Missing datapackage.json")?,
    )
    .map_err(|e| e.to_string())?;
    let resources = manifest
        .get("resources")
        .and_then(Value::as_array)
        .ok_or("Manifest resources missing")?;
    if resources.is_empty() || resources.len() > 10_000 {
        return Err("Invalid manifest resource count".into());
    }
    let mut listed = BTreeSet::new();
    for resource in resources {
        let name = resource
            .get("path")
            .and_then(Value::as_str)
            .ok_or("Manifest resource path missing")?;
        if !listed.insert(name) {
            return Err("Duplicate manifest path".into());
        }
        let bytes = members
            .get(name)
            .ok_or("Manifest references missing member")?;
        if resource.get("bytes").and_then(Value::as_u64) != Some(bytes.len() as u64) {
            return Err(format!("Manifest size mismatch: {name}"));
        }
        let digest = resource
            .get("hash")
            .and_then(Value::as_str)
            .ok_or("Manifest hash missing")?;
        check_digest(digest, bytes)?;
    }
    for name in members.keys() {
        if name != "datapackage.json"
            && name != "datapackage-digest.json"
            && !listed.contains(name.as_str())
        {
            return Err(format!("Unhashed ZIP member: {name}"));
        }
    }
    if let Some(bytes) = members.get("datapackage-digest.json") {
        let digest: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        check_digest(
            digest
                .get("hash")
                .and_then(Value::as_str)
                .ok_or("Package digest missing")?,
            &members["datapackage.json"],
        )?;
    }
    let mut archive = Archive {
        report: ArchiveReport {
            archive_bytes,
            sha256: format!("{:x}", hasher.finalize()),
            title: manifest
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("")
                .into(),
            description: manifest
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .into(),
            ..Default::default()
        },
        records: vec![],
        page_meta: vec![],
    };
    if let Some(dependencies) = manifest.get("webArchivesDependencies") {
        archive.report.dependencies =
            serde_json::from_value(dependencies.clone()).map_err(|e| e.to_string())?;
    }
    let mut inflated = 0;
    for (name, bytes) in &members {
        if name.ends_with(".warc.gz") {
            let mut cursor = Cursor::new(bytes.as_slice());
            while (cursor.position() as usize) < bytes.len() {
                let offset = cursor.position();
                let raw = bounded(GzDecoder::new(&mut cursor), MAX_BYTES - inflated)?;
                inflated += raw.len();
                let length = cursor.position() - offset;
                if length == 0 {
                    return Err("Gzip member made no progress".into());
                }
                let start = archive.records.len();
                parse_warc(&raw, name, offset, length, &mut archive.records)?;
                let count = archive.records.len() - start;
                // Attribute the compressed span once, apportioned by record count.
                for (position, record) in archive.records[start..].iter_mut().enumerate() {
                    record.stored = length / count as u64
                        + u64::from((position as u64) < length % count as u64);
                }
            }
        } else if name.ends_with(".warc") {
            return Err("Uncompressed WARC is unsupported; use per-record gzip WARC".into());
        }
        if name.starts_with("pages/") && name.ends_with(".jsonl") {
            for (i, line) in lines(bytes)?.enumerate() {
                if i > MAX_ITEMS {
                    return Err("Page JSONL count limit exceeded".into());
                }
                let value: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
                if value.get("url").is_none() {
                    continue;
                }
                archive
                    .page_meta
                    .push(serde_json::from_value(value).map_err(|e| e.to_string())?);
                if archive.page_meta.len() > MAX_ITEMS {
                    return Err("Page count limit exceeded".into());
                }
            }
        }
    }
    if archive.records.is_empty() {
        return Err("No WARC records".into());
    }
    validate_indexes(&members, &archive.records, &mut inflated)?;
    archive.resolve_local()?;
    Ok(archive)
}

fn check_digest(expected: &str, bytes: &[u8]) -> Result<(), String> {
    let actual = format!("sha256:{}", hash(bytes));
    if !expected.eq_ignore_ascii_case(&actual) {
        return Err("SHA-256 mismatch or unsupported digest algorithm".into());
    }
    Ok(())
}
fn lines(bytes: &[u8]) -> Result<impl Iterator<Item = &str>, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| e.to_string())?;
    if text.lines().any(|line| line.len() > MAX_RECORD) {
        return Err("JSONL line too large".into());
    }
    Ok(text.lines().filter(|line| !line.trim().is_empty()))
}
pub(super) fn headers(bytes: &[u8]) -> Result<(String, BTreeMap<String, String>), String> {
    if bytes.len() > MAX_HEADER {
        return Err("Header size limit exceeded".into());
    }
    let text = std::str::from_utf8(bytes).map_err(|_| "Non-UTF8 headers unsupported")?;
    let mut lines = text.split("\r\n");
    let first = lines.next().ok_or("Empty header")?.to_owned();
    let mut out = BTreeMap::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (key, value) = line.split_once(':').ok_or("Malformed header")?;
        let key = key.to_ascii_lowercase();
        if out.insert(key.clone(), value.trim().into()).is_some()
            && matches!(
                key.as_str(),
                "content-length" | "warc-type" | "warc-target-uri" | "warc-record-id" | "warc-date"
            )
        {
            return Err("Duplicate structural header".into());
        }
    }
    Ok((first, out))
}
fn boundary(bytes: &[u8]) -> Result<usize, String> {
    bytes
        .windows(4)
        .position(|x| x == b"\r\n\r\n")
        .ok_or_else(|| "Missing header terminator".into())
}
fn parse_warc(
    raw: &[u8],
    member: &str,
    offset: u64,
    length: u64,
    records: &mut Vec<Record>,
) -> Result<(), String> {
    let mut position = 0;
    while position < raw.len() {
        while raw
            .get(position)
            .is_some_and(|b| matches!(b, b'\r' | b'\n'))
        {
            position += 1;
        }
        if position == raw.len() {
            break;
        }
        if records.len() >= MAX_ITEMS {
            return Err("WARC resource count limit exceeded".into());
        }
        let end = position + boundary(&raw[position..raw.len().min(position + MAX_HEADER + 4)])?;
        let (version, headers) = headers(&raw[position..end])?;
        if version != "WARC/1.0" && version != "WARC/1.1" {
            return Err("Unsupported WARC version".into());
        }
        let size: usize = headers
            .get("content-length")
            .ok_or("WARC Content-Length missing")?
            .parse()
            .map_err(|_| "Invalid WARC length")?;
        if size > MAX_RECORD {
            return Err("WARC record exceeds 32 MiB".into());
        }
        let start = end + 4;
        let finish = start
            .checked_add(size)
            .filter(|end| *end <= raw.len())
            .ok_or("Truncated WARC record")?;
        let block = raw[start..finish].to_vec();
        let kind = headers.get("warc-type").map(String::as_str).unwrap_or("");
        let (payload, status, mime) = match kind {
            "response" | "revisit" => {
                if block.is_empty() && kind == "revisit" {
                    (vec![], 0, String::new())
                } else {
                    let split = boundary(&block)?;
                    let (status, http) = self::headers(&block[..split])?;
                    if !status.starts_with("HTTP/") {
                        return Err("Invalid HTTP response".into());
                    }
                    let status = status
                        .split_whitespace()
                        .nth(1)
                        .ok_or("Missing HTTP status")?
                        .parse()
                        .map_err(|_| "Invalid HTTP status")?;
                    (
                        block[split + 4..].to_vec(),
                        status,
                        http.get("content-type")
                            .map(|s| {
                                s.split(';')
                                    .next()
                                    .unwrap_or("")
                                    .trim()
                                    .to_ascii_lowercase()
                            })
                            .unwrap_or_default(),
                    )
                }
            }
            "resource" => (
                block.clone(),
                200,
                headers.get("content-type").cloned().unwrap_or_default(),
            ),
            _ => (vec![], 0, String::new()),
        };
        if let Some(digest) = headers
            .get("warc-block-digest")
            .filter(|d| d.starts_with("sha256:"))
        {
            check_digest(digest, &block)?;
        }
        if kind != "revisit" {
            if let Some(digest) = headers
                .get("warc-payload-digest")
                .filter(|d| d.starts_with("sha256:"))
            {
                check_digest(digest, &payload)?;
            }
        }
        records.push(Record {
            headers,
            block,
            payload,
            status,
            mime,
            member: member.into(),
            offset,
            length,
            stored: 0,
        });
        position = finish;
    }
    Ok(())
}
fn numeric(value: &Value, key: &str) -> Result<u64, String> {
    value
        .get(key)
        .and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .ok_or_else(|| format!("Invalid CDX {key}"))
}
fn validate_indexes(
    members: &BTreeMap<String, Vec<u8>>,
    records: &[Record],
    inflated: &mut usize,
) -> Result<(), String> {
    let mut indexed = BTreeSet::new();
    let locations: HashMap<_, Vec<_>> = records
        .iter()
        .filter(|r| matches!(r.kind(), "response" | "resource" | "revisit"))
        .fold(HashMap::new(), |mut m, r| {
            m.entry((r.member.as_str(), r.offset, r.length))
                .or_default()
                .push(r);
            m
        });
    let mut count = 0;
    for (name, bytes) in members {
        if !(name.ends_with(".cdx") || name.ends_with(".cdxj") || name.ends_with(".cdx.gz")) {
            continue;
        }
        let raw = if name.ends_with(".gz") {
            bounded(MultiGzDecoder::new(bytes.as_slice()), MAX_BYTES - *inflated)?
        } else {
            bytes.clone()
        };
        *inflated += raw.len();
        for line in lines(&raw)? {
            count += 1;
            if count > MAX_ITEMS {
                return Err("CDX count limit exceeded".into());
            }
            let json = line
                .find('{')
                .ok_or("Unsupported CDX format (requires CDXJ)")?;
            let value: Value = serde_json::from_str(&line[json..]).map_err(|e| e.to_string())?;
            let filename = value
                .get("filename")
                .and_then(Value::as_str)
                .ok_or("CDX filename missing")?;
            let filename = if members.contains_key(filename) {
                filename.to_owned()
            } else {
                format!("archive/{filename}")
            };
            let offset = numeric(&value, "offset")?;
            let length = numeric(&value, "length")?;
            let group = locations
                .get(&(filename.as_str(), offset, length))
                .ok_or("CDX points outside a gzip record span")?;
            let url = value
                .get("url")
                .and_then(Value::as_str)
                .ok_or("CDX URL missing")?;
            let record = group
                .iter()
                .find(|r| r.url() == url)
                .ok_or("CDX URL does not match indexed WARC record")?;
            indexed.insert((
                record.member.clone(),
                record.offset,
                record.url().to_owned(),
            ));
        }
    }
    if count == 0 {
        return Err("Missing CDXJ index".into());
    }
    for record in records
        .iter()
        .filter(|r| matches!(r.kind(), "response" | "resource" | "revisit"))
    {
        if !indexed.contains(&(
            record.member.clone(),
            record.offset,
            record.url().to_owned(),
        )) {
            return Err("WARC resource missing from CDXJ index".into());
        }
    }
    Ok(())
}

impl Archive {
    pub fn resolve_local(&mut self) -> Result<(), String> {
        let mut pending = true;
        let mut rounds = 0;
        while pending && rounds < 64 {
            pending = false;
            rounds += 1;
            for i in 0..self.records.len() {
                if self.records[i].kind() != "revisit" || !self.records[i].payload.is_empty() {
                    continue;
                }
                if let Some(target) = find_revisit(&self.records[i], &self.records) {
                    let payload = target.payload.clone();
                    let mime = target.mime.clone();
                    let status = target.status;
                    if !payload.is_empty() {
                        self.records[i].payload = payload;
                        if self.records[i].mime.is_empty() {
                            self.records[i].mime = mime;
                        }
                        if self.records[i].status == 0 {
                            self.records[i].status = status;
                        }
                        pending = true;
                    }
                }
            }
        }
        Ok(())
    }
    pub fn report(&self) -> Result<ArchiveReport, String> {
        let mut report = self.report.clone();
        let mut pages = BTreeMap::<(String, String), PageRecord>::new();
        for page in &self.page_meta {
            pages.insert((page.url.clone(), page.ts.clone()), page.clone());
        }
        let mut seen = BTreeSet::new();
        for record in &self.records {
            if !matches!(record.kind(), "response" | "resource" | "revisit") {
                continue;
            }
            let unresolved = record.kind() == "revisit" && record.payload.is_empty();
            if unresolved {
                report.warnings.push(format!(
                    "Unresolved revisit: {} {}",
                    record.url(),
                    record.field("warc-record-id")
                ));
                if report.dependencies.is_empty() {
                    report
                        .dependencies
                        .push("unresolved-external-revisit".into());
                }
            }
            if record.field("warc-payload-digest").starts_with("sha1:")
                && !report.warnings.iter().any(|w| w.starts_with("SHA-1"))
            {
                report.warnings.push("SHA-1 WARC digests are recorded but not verified; ZIP manifest SHA-256 is verified".into());
            }
            let digest = if unresolved {
                record.field("warc-payload-digest").into()
            } else {
                record.digest()
            };
            if seen.insert(digest.clone()) {
                report.unique_payload_bytes += record.stored;
            } else {
                report.duplicate_payload_bytes += record.stored;
            }
            let mut resource = ResourceRecord {
                url: record.url().into(),
                mime: record.mime.clone(),
                status: record.status,
                bytes: record.stored,
                digest,
                domain: url::Url::parse(record.url())
                    .ok()
                    .and_then(|u| u.host_str().map(str::to_owned))
                    .unwrap_or_default(),
                pages: vec![],
            };
            if record.mime == "text/html" || record.mime == "application/xhtml+xml" {
                let (text, title, links) = content::extract(record)?;
                let key = pages
                    .keys()
                    .find(|(u, ts)| {
                        u == record.url() && (ts == record.field("warc-date") || ts.is_empty())
                    })
                    .cloned()
                    .unwrap_or((record.url().into(), record.field("warc-date").into()));
                let page = pages.entry(key).or_default();
                page.url = record.url().into();
                page.ts = record.field("warc-date").into();
                if !title.is_empty() {
                    page.title = title;
                }
                page.text = text;
                page.bytes = record.stored;
                page.status = record.status;
                page.resource_urls = links;
            }
            resource.pages = self
                .records
                .iter()
                .filter(|r| r.url() == record.field("warc-refers-to-target-uri"))
                .map(|r| r.url().into())
                .collect();
            report.resources.push(resource);
        }
        report.pages = pages.into_values().collect();
        for resource in &mut report.resources {
            resource.pages = report
                .pages
                .iter()
                .filter(|p| p.url == resource.url || p.resource_urls.contains(&resource.url))
                .map(|p| p.url.clone())
                .collect();
        }
        report.metadata_bytes = report
            .archive_bytes
            .checked_sub(report.unique_payload_bytes + report.duplicate_payload_bytes)
            .ok_or("Storage accounting overflow")?;
        report.warnings.push("Resource bytes apportion stored gzip spans; metadata includes ZIP/index/page overhead. Transfer and shared-page bytes are not additive storage.".into());
        report.warnings.push("Dependency attribution uses captured HTML references; dynamic script requests are retained conservatively on export.".into());
        Ok(report)
    }
}
pub(super) fn find_revisit<'a>(record: &Record, candidates: &'a [Record]) -> Option<&'a Record> {
    candidates.iter().find(|r| {
        if !matches!(r.kind(), "response" | "resource") && r.payload.is_empty() {
            return false;
        }
        if !record.field("warc-refers-to").is_empty() {
            return r.field("warc-record-id") == record.field("warc-refers-to");
        }
        let url = record.field("warc-refers-to-target-uri");
        let date = record.field("warc-refers-to-date");
        let digest = record.field("warc-payload-digest");
        !url.is_empty()
            && !date.is_empty()
            && !digest.is_empty()
            && r.url() == url
            && r.field("warc-date") == date
            && (r.field("warc-payload-digest") == digest || r.digest() == digest)
    })
}
