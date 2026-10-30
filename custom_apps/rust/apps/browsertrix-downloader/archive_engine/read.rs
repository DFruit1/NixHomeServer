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
    pub payload_digest: String,
    pub status: u16,
    pub mime: String,
    pub member: String,
    pub offset: u64,
    pub length: u64,
    pub stored: u64,
    pub resolved: bool,
    pub index: BTreeMap<String, Value>,
    pub index_key: String,
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
        self.payload_digest.clone()
    }
}

pub(super) struct Archive {
    pub report: ArchiveReport,
    pub records: Vec<Record>,
    pub page_meta: Vec<PageRecord>,
    pub dependency_hashes: BTreeMap<String, String>,
    pub cost: usize,
}

pub(super) fn load(path: &Path) -> Result<Archive, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let archive_bytes = file.metadata().map_err(|e| e.to_string())?.len();
    if archive_bytes > MAX_BYTES as u64 {
        return Err("Archive file exceeds 256 MiB engine limit".into());
    }
    // Bind parsing and hashing to the same immutable in-memory snapshot.
    let file_bytes = bounded(file, MAX_BYTES)?;
    let sha256 = hash(&file_bytes);
    let mut zip = ZipArchive::new(Cursor::new(file_bytes)).map_err(|e| e.to_string())?;
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
            sha256: sha256,
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
        dependency_hashes: manifest
            .get("webArchivesDependencyHashes")
            .map(|v| serde_json::from_value(v.clone()))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or_default(),
        cost: 0,
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
    if !members.contains_key("pages/pages.jsonl") {
        return Err("Missing pages/pages.jsonl".into());
    }
    validate_indexes(&members, &mut archive.records, &mut inflated)?;
    archive.cost = total + inflated;
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
        let resolved = kind != "revisit";
        let mut record = Record {
            headers,
            block,
            payload,
            payload_digest: String::new(),
            status,
            mime,
            member: member.into(),
            offset,
            length,
            stored: 0,
            resolved,
            index: BTreeMap::new(),
            index_key: String::new(),
        };
        if matches!(record.kind(), "response" | "resource") {
            let entity = content::transfer_payload(&record)?;
            record.payload_digest = format!("sha256:{}", hash(&entity));
            if let Some(expected) = record
                .headers
                .get("warc-payload-digest")
                .filter(|d| d.starts_with("sha256:"))
            {
                check_digest(expected, &entity)?;
            }
        }
        records.push(record);
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
    records: &mut [Record],
    inflated: &mut usize,
) -> Result<(), String> {
    let mut locations = HashMap::<(String, u64, u64, String), Vec<usize>>::new();
    for (i, r) in records
        .iter()
        .enumerate()
        .filter(|(_, r)| matches!(r.kind(), "response" | "resource" | "revisit"))
    {
        locations
            .entry((r.member.clone(), r.offset, r.length, r.url().into()))
            .or_default()
            .push(i);
    }
    let mut indexed = BTreeSet::new();
    let mut count = 0;
    for (name, bytes) in members {
        if name.ends_with(".idx") {
            for line in lines(bytes)? {
                let start = line.find('{').ok_or("Invalid compressed CDX block index")?;
                let v: Value = serde_json::from_str(&line[start..]).map_err(|e| e.to_string())?;
                let filename = v
                    .get("filename")
                    .and_then(Value::as_str)
                    .ok_or("CDX block filename missing")?;
                let path = if members.contains_key(filename) {
                    filename.to_owned()
                } else {
                    format!("indexes/{filename}")
                };
                let data = members.get(&path).ok_or("CDX block file missing")?;
                let offset = numeric(&v, "offset")?;
                let length = numeric(&v, "length")?;
                let end = offset
                    .checked_add(length)
                    .filter(|e| *e <= data.len() as u64)
                    .ok_or("CDX block outside index file")?;
                if data.get(offset as usize..offset as usize + 2) != Some(&[0x1f, 0x8b]) {
                    return Err("CDX block is not a gzip boundary".into());
                }
                if length == 0 || end <= offset {
                    return Err("Empty CDX block".into());
                }
                count += 1;
                if count > MAX_ITEMS {
                    return Err("CDX block count limit exceeded".into());
                }
            }
        }
        if !(name.ends_with(".cdx") || name.ends_with(".cdxj") || name.ends_with(".cdx.gz")) {
            continue;
        }
        let raw = if name.ends_with(".gz") {
            bounded(MultiGzDecoder::new(bytes.as_slice()), MAX_BYTES - *inflated)?
        } else {
            bounded(bytes.as_slice(), MAX_BYTES - *inflated)?
        };
        *inflated += raw.len();
        for line in lines(&raw)? {
            count += 1;
            if count > MAX_ITEMS {
                return Err("CDX count limit exceeded".into());
            }
            let start = line.find('{').ok_or("CDXJ JSON missing")?;
            let value: Value = serde_json::from_str(&line[start..]).map_err(|e| e.to_string())?;
            let filename = value
                .get("filename")
                .and_then(Value::as_str)
                .ok_or("CDX filename missing")?;
            let filename = if members.contains_key(filename) {
                filename.into()
            } else {
                format!("archive/{filename}")
            };
            let url = value
                .get("url")
                .and_then(Value::as_str)
                .ok_or("CDX URL missing")?;
            let group = locations
                .get(&(
                    filename,
                    numeric(&value, "offset")?,
                    numeric(&value, "length")?,
                    url.into(),
                ))
                .ok_or("CDX points outside matching WARC gzip span")?;
            let timestamp = line[..start]
                .split_whitespace()
                .nth(1)
                .ok_or("CDX timestamp missing")?;
            let candidates: Vec<_> = group
                .iter()
                .copied()
                .filter(|i| {
                    timestamp_of(records[*i].field("warc-date")).as_deref() == Ok(timestamp)
                })
                .collect();
            if candidates.len() != 1 {
                return Err("CDX record timestamp is ambiguous or mismatched".into());
            }
            let i = candidates[0];
            if !indexed.insert(i) {
                return Err("Duplicate CDX identity; request-variant ambiguity unsupported".into());
            }
            records[i].index_key = line[..start]
                .split_whitespace()
                .next()
                .ok_or("CDX lookup key missing")?
                .into();
            records[i].index = serde_json::from_value(value).map_err(|e| e.to_string())?;
        }
    }
    for (i, r) in records
        .iter()
        .enumerate()
        .filter(|(_, r)| matches!(r.kind(), "response" | "resource" | "revisit"))
    {
        if !indexed.contains(&i) {
            return Err(format!("WARC resource missing CDXJ index: {}", r.url()));
        }
    }
    if indexed.is_empty() {
        return Err("Missing CDXJ index".into());
    }
    Ok(())
}
pub(super) fn timestamp_of(date: &str) -> Result<String, String> {
    chrono::DateTime::parse_from_rfc3339(date)
        .map(|d| {
            d.with_timezone(&chrono::Utc)
                .format("%Y%m%d%H%M%S")
                .to_string()
        })
        .map_err(|_| "Invalid WARC capture date".into())
}

impl Archive {
    pub fn resolve_local(&mut self) -> Result<(), String> {
        let mut pending = true;
        let mut rounds = 0;
        let mut work = 2_000_000usize;
        while pending && rounds < 64 {
            pending = false;
            rounds += 1;
            for i in 0..self.records.len() {
                if self.records[i].kind() != "revisit"
                    || self.records[i].resolved
                    || !self.records[i].field("warc-x-dependency-sha256").is_empty()
                {
                    continue;
                }
                if self.records.len() > work {
                    return Err("Local revisit resolution work limit exceeded".into());
                }
                work -= self.records.len();
                if let Some(target) = find_revisit(&self.records[i], &self.records) {
                    let payload = target.payload.clone();
                    let digest = target.payload_digest.clone();
                    let mime = target.mime.clone();
                    let status = target.status;
                    if target.resolved {
                        self.records[i].resolved = true;
                        self.records[i].payload = payload;
                        self.records[i].payload_digest = digest;
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
            let ts = chrono::DateTime::parse_from_rfc3339(&page.ts)
                .map(|d| d.to_rfc3339())
                .unwrap_or_else(|_| page.ts.clone());
            pages.insert((page.url.clone(), ts), page.clone());
        }
        let mut seen = BTreeSet::new();
        for record in &self.records {
            if !matches!(record.kind(), "response" | "resource" | "revisit") {
                continue;
            }
            let unresolved = record.kind() == "revisit" && !record.resolved;
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
            let resource = ResourceRecord {
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
            if (record.mime == "text/html" || record.mime == "application/xhtml+xml")
                && (self.page_meta.iter().any(|p| p.url == record.url())
                    || record.field("warc-resource-type") == "document"
                    || self.page_meta.is_empty())
            {
                let (text, title, links) = content::extract(record)?;
                let ts = chrono::DateTime::parse_from_rfc3339(record.field("warc-date"))
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_else(|_| record.field("warc-date").into());
                let key = (record.url().into(), ts);
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
            report.resources.push(resource);
        }
        report.pages = pages.into_values().collect();
        let mut attribution = BTreeMap::<String, BTreeSet<String>>::new();
        for page in &report.pages {
            attribution
                .entry(page.url.clone())
                .or_default()
                .insert(page.url.clone());
            for url in &page.resource_urls {
                attribution
                    .entry(url.clone())
                    .or_default()
                    .insert(page.url.clone());
            }
        }
        for resource in &mut report.resources {
            resource.pages = attribution
                .get(&resource.url)
                .map(|s| s.iter().cloned().collect())
                .unwrap_or_default();
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
    let mut matches = candidates.iter().filter(|r| {
        if !r.resolved {
            return false;
        }
        let id = record.field("warc-refers-to");
        let url = record.field("warc-refers-to-target-uri");
        let date = record.field("warc-refers-to-date");
        let digest = record.field("warc-payload-digest");
        if id.is_empty() && (url.is_empty() || date.is_empty() || digest.is_empty()) {
            return false;
        }
        if !id.is_empty() && r.field("warc-record-id") != id {
            return false;
        }
        if !url.is_empty() && r.url() != url {
            return false;
        }
        if !date.is_empty() && r.field("warc-date") != date {
            return false;
        }
        let location = record.field("warc-x-dependency-location");
        if !location.is_empty() && location != format!("{}:{}:{}", r.member, r.offset, r.length) {
            return false;
        }
        digest.is_empty() || r.field("warc-payload-digest") == digest || r.digest() == digest
    });
    let first = matches.next();
    if matches.next().is_some() {
        None
    } else {
        first
    }
}
