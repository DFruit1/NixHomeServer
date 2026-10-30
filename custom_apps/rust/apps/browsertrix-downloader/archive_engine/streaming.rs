//! Sequential ZIP fixity and WARC scanning. Payloads stay in their original
//! immutable file; inventories retain locations and hashes, not archive bodies.
use super::{
    read::{self, Archive, Record, MAX_ITEMS},
    *,
};
use flate2::bufread::GzDecoder;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{self, BufRead, BufReader, Read},
    os::unix::fs::FileExt,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};
use zip::{CompressionMethod, ZipArchive};

pub(super) const MAX_ARCHIVE: u64 = 32 * 1024 * 1024 * 1024;
pub(super) const MAX_INFLATED: u64 = 64 * 1024 * 1024 * 1024;
pub(super) const MAX_BODY: u64 = 2 * 1024 * 1024 * 1024 + 64 * 1024;
pub(super) const MAX_METADATA: usize = 32 * 1024 * 1024;
const MAX_HEADER: usize = 64 * 1024;

#[derive(Clone, Debug)]
pub(super) struct BodySource {
    pub file: Arc<File>,
    pub start: u64,
    pub compressed_length: u64,
    pub body_offset: u64,
    pub body_length: u64,
    pub http_length: u64,
    pub block_digest: String,
    pub read_budget: Arc<AtomicU64>,
}
struct Range {
    file: Arc<File>,
    position: u64,
    end: u64,
}
impl Read for Range {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = out.len().min(
            self.end
                .saturating_sub(self.position)
                .min(usize::MAX as u64) as usize,
        );
        let read = self.file.read_at(&mut out[..n], self.position)?;
        self.position += read as u64;
        Ok(read)
    }
}
struct Checked<R> {
    inner: R,
    hasher: Sha256,
    count: u64,
    expected: u64,
    digest: String,
}
impl<R: Read> Read for Checked<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(out)?;
        self.hasher.update(&out[..n]);
        self.count += n as u64;
        if (n == 0 && !out.is_empty()) || self.count == self.expected {
            let actual = format!("sha256:{:x}", self.hasher.clone().finalize());
            if self.count != self.expected || actual != self.digest {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Lazy source body changed/truncated",
                ));
            }
        }
        Ok(n)
    }
}
impl BodySource {
    pub fn reader(&self, payload: bool) -> Result<Box<dyn Read>, String> {
        self.read_budget
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |left| {
                left.checked_sub(self.body_offset.saturating_add(self.body_length))
            })
            .map_err(|_| "Gzip span reread budget exceeded")?;
        let end = self
            .start
            .checked_add(self.compressed_length)
            .ok_or("Invalid source span")?;
        let range = Range {
            file: self.file.clone(),
            position: self.start,
            end,
        };
        let mut decoder = GzDecoder::new(BufReader::new(range));
        let skipped = io::copy(
            &mut decoder.by_ref().take(self.body_offset),
            &mut io::sink(),
        )
        .map_err(|e| e.to_string())?;
        if skipped != self.body_offset {
            return Err("Truncated source WARC offset".into());
        }
        let mut reader = Checked {
            inner: decoder.take(self.body_length),
            hasher: Sha256::new(),
            count: 0,
            expected: self.body_length,
            digest: self.block_digest.clone(),
        };
        if payload {
            let skipped = io::copy(&mut reader.by_ref().take(self.http_length), &mut io::sink())
                .map_err(|e| e.to_string())?;
            if skipped != self.http_length {
                return Err("Truncated source HTTP header".into());
            }
        }
        Ok(Box::new(reader))
    }
}
struct Counted<R> {
    inner: R,
    count: u64,
    limit: u64,
}
impl<R: Read> Read for Counted<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.count > self.limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Aggregate inflated byte limit exceeded",
            ));
        }
        let cap = out.len().min(
            (self.limit - self.count)
                .saturating_add(1)
                .min(usize::MAX as u64) as usize,
        );
        let n = self.inner.read(&mut out[..cap])?;
        self.count += n as u64;
        if self.count > self.limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Aggregate inflated byte limit exceeded",
            ));
        }
        Ok(n)
    }
}
pub(super) fn stream_hash(mut input: impl Read, limit: u64) -> Result<(u64, String), String> {
    let mut hash = Sha256::new();
    let mut total = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        total = total
            .checked_add(n as u64)
            .filter(|n| *n <= limit)
            .ok_or("Stream byte budget exceeded")?;
        hash.update(&buffer[..n]);
    }
    Ok((total, format!("sha256:{:x}", hash.finalize())))
}
fn full_hash(file: &Arc<File>, size: u64) -> Result<String, String> {
    Ok(stream_hash(
        Range {
            file: file.clone(),
            position: 0,
            end: size,
        },
        MAX_ARCHIVE,
    )?
    .1
    .trim_start_matches("sha256:")
    .into())
}
fn named_bytes(
    zip: &mut ZipArchive<super::zip_directory::Input>,
    name: &str,
    limit: usize,
) -> Result<Vec<u8>, String> {
    read::bounded(zip.by_name(name).map_err(|e| e.to_string())?, limit)
}

pub(super) fn load(path: &Path) -> Result<Archive, String> {
    let file = Arc::new(File::open(path).map_err(|e| e.to_string())?);
    let before = file.metadata().map_err(|e| e.to_string())?;
    let size = before.len();
    if size > MAX_ARCHIVE {
        return Err("Archive exceeds 32 GiB bounded file limit".into());
    }
    let directory = super::zip_directory::validate(&file, size)?;
    let member_count = directory.count;
    let sha256 = full_hash(&file, size)?;
    let input = super::zip_directory::Input::new(file.clone(), directory);
    let metadata_only = input.metadata_only.clone();
    let mut zip = ZipArchive::with_config(
        zip::read::Config {
            archive_offset: zip::read::ArchiveOffset::Known(0),
        },
        input,
    )
    .map_err(|e| e.to_string())?;
    metadata_only.store(false, Ordering::Relaxed);
    if zip.len() != member_count {
        return Err("ZIP member identities changed after raw preflight".into());
    }
    let manifest_bytes = named_bytes(&mut zip, "datapackage.json", 4 * 1024 * 1024)?;
    let manifest: Value = serde_json::from_slice(&manifest_bytes).map_err(|e| e.to_string())?;
    let resources = manifest
        .get("resources")
        .and_then(Value::as_array)
        .ok_or("Manifest resources missing")?;
    if resources.is_empty() || resources.len() > 10_000 {
        return Err("Invalid manifest resource count".into());
    }
    let mut expected = BTreeMap::new();
    for resource in resources {
        let name = resource
            .get("path")
            .and_then(Value::as_str)
            .ok_or("Manifest resource path missing")?;
        let bytes = resource
            .get("bytes")
            .and_then(Value::as_u64)
            .ok_or("Manifest byte count missing")?;
        let hash = resource
            .get("hash")
            .and_then(Value::as_str)
            .ok_or("Manifest hash missing")?;
        if expected
            .insert(name.to_owned(), (bytes, hash.to_owned()))
            .is_some()
        {
            return Err("Duplicate manifest path".into());
        }
    }
    let mut archive = Archive {
        report: ArchiveReport {
            archive_bytes: size,
            sha256,
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
        page_ids: BTreeMap::new(),
        dependency_hashes: manifest
            .get("webArchivesDependencyHashes")
            .map(|v| serde_json::from_value(v.clone()))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or_default(),
        cost: 0,
    };
    if let Some(deps) = manifest.get("webArchivesDependencies") {
        archive.report.dependencies =
            serde_json::from_value(deps.clone()).map_err(|e| e.to_string())?;
    }
    read::validate_dependency_relations(&mut archive, &manifest)?;
    let mut members = BTreeMap::new();
    let mut names = std::collections::BTreeSet::new();
    let mut warcs = vec![];
    let mut zip_total = 0u64;
    let mut metadata_total = manifest_bytes.len();
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().to_owned();
        if name.len() > 1024
            || name.contains('\\')
            || name.contains(':')
            || name.chars().any(char::is_control)
            || name.starts_with('/')
            || name.split('/').any(|s| s == ".." || s == ".")
            || entry.enclosed_name().is_none()
            || entry.encrypted()
            || entry.unix_mode().is_some_and(|m| {
                m & 0o170000 != 0 && m & 0o170000 != 0o100000 && m & 0o170000 != 0o040000
            })
        {
            return Err("Unsafe ZIP member name, encryption or special file".into());
        }
        if !names.insert(name.clone()) {
            return Err("Duplicate ZIP member".into());
        }
        if entry.is_dir() {
            continue;
        }
        zip_total = zip_total
            .checked_add(entry.size())
            .filter(|n| *n <= MAX_INFLATED)
            .ok_or("ZIP inflated byte limit exceeded")?;
        if name == "datapackage.json" {
            continue;
        }
        if name == "datapackage-digest.json" {
            let data = read::bounded(entry, MAX_HEADER)?;
            let digest: Value = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
            read::check_digest(
                digest
                    .get("hash")
                    .and_then(Value::as_str)
                    .ok_or("Package digest missing")?,
                &manifest_bytes,
            )?;
            continue;
        }
        let (length, hash) = expected
            .get(&name)
            .ok_or_else(|| format!("Unhashed ZIP member: {name}"))?;
        if *length != entry.size() {
            return Err(format!("Manifest size mismatch: {name}"));
        }
        let is_warc = name.ends_with(".warc.gz");
        if name.ends_with(".warc") {
            return Err("Uncompressed WARC unsupported; gzip required".into());
        }
        if is_warc {
            if entry.compression() != CompressionMethod::Stored {
                return Err("WACZ WARC ZIP member must use STORE for bounded random access".into());
            }
            let start = entry.data_start().ok_or("ZIP member data offset missing")?;
            let (actual, digest) = stream_hash(&mut entry, MAX_ARCHIVE)?;
            if actual != *length || read::normalize_sha256(hash)? != digest {
                return Err(format!("Manifest SHA-256 mismatch: {name}"));
            }
            warcs.push((name, start, *length));
        } else if name.starts_with("pages/") && name.ends_with(".jsonl")
            || name.starts_with("indexes/")
        {
            let data = read::bounded(entry, MAX_METADATA.saturating_sub(metadata_total))?;
            metadata_total += data.len();
            read::check_digest(hash, &data)?;
            members.insert(name, data);
        } else {
            let (actual, digest) = stream_hash(&mut entry, MAX_INFLATED)?;
            if actual != *length || read::normalize_sha256(hash)? != digest {
                return Err(format!("Manifest SHA-256 mismatch: {name}"));
            }
        }
    }
    for name in expected.keys() {
        if !names.contains(name) {
            return Err("Manifest references missing member".into());
        }
    }
    if !members.contains_key("pages/pages.jsonl") {
        return Err("Missing pages/pages.jsonl".into());
    }
    for (name, data) in &members {
        if name.starts_with("pages/") && name.ends_with(".jsonl") {
            for line in std::str::from_utf8(data)
                .map_err(|e| e.to_string())?
                .lines()
                .filter(|l| !l.is_empty())
            {
                if line.len() > 2 * 1024 * 1024 {
                    return Err("Page JSONL line exceeds 2 MiB".into());
                }
                let value: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
                if value.get("url").is_none() {
                    continue;
                }
                let id = value.get("id").and_then(Value::as_str).map(str::to_owned);
                let page: PageRecord = serde_json::from_value(value).map_err(|e| e.to_string())?;
                if page.url.len() > 8192 || page.title.len() > 64 * 1024 {
                    return Err("Page metadata length limit exceeded".into());
                }
                if let Some(id) = id {
                    let ts = chrono::DateTime::parse_from_rfc3339(&page.ts)
                        .map(|d| d.to_rfc3339())
                        .unwrap_or_else(|_| page.ts.clone());
                    archive.page_ids.insert((page.url.clone(), ts), id);
                }
                archive.page_meta.push(page);
                if archive.page_meta.len() > MAX_ITEMS {
                    return Err("Page count limit exceeded".into());
                }
            }
        }
    }
    let mut inflated = 0u64;
    let mut record_metadata = 0usize;
    let read_budget = Arc::new(AtomicU64::new(MAX_INFLATED * 4));
    for (name, start, length) in warcs {
        scan_warc(
            file.clone(),
            read_budget.clone(),
            &name,
            start,
            length,
            &mut inflated,
            &mut record_metadata,
            &mut archive.records,
        )?;
    }
    if archive.records.is_empty() {
        return Err("No WARC records".into());
    }
    // Index validation also checks the gzip locations scanned from actual data.
    // Give the existing checker tiny path-only sentinels for WARC filenames.
    for r in &archive.records {
        members.entry(r.member.clone()).or_default();
    }
    let mut index_inflated = 0usize;
    read::validate_indexes(&members, &mut archive.records, &mut index_inflated)?;
    if index_inflated > MAX_METADATA {
        return Err("Inflated index metadata exceeds 32 MiB".into());
    }
    archive.cost = metadata_total + record_metadata;
    archive.resolve_local()?;
    if archive.report.title.is_empty() {
        archive.report.title = archive
            .page_meta
            .first()
            .map(|p| p.title.clone())
            .unwrap_or_default();
    }
    let after = file.metadata().map_err(|e| e.to_string())?;
    if before.len() != after.len()
        || before.modified().ok() != after.modified().ok()
        || full_hash(&file, size)? != archive.report.sha256
    {
        return Err("Source archive changed during streamed inspection".into());
    }
    Ok(archive)
}

fn read_header(input: &mut impl BufRead, skip_empty: bool) -> Result<Option<Vec<u8>>, String> {
    let mut bytes = vec![];
    loop {
        let mut line = vec![];
        let n = input
            .by_ref()
            .take((MAX_HEADER + 1) as u64)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if n == 0 {
            if bytes.is_empty() {
                return Ok(None);
            }
            return Err("Truncated WARC/HTTP header".into());
        }
        if skip_empty && bytes.is_empty() && line == b"\r\n" {
            continue;
        }
        if bytes.len() + line.len() > MAX_HEADER {
            return Err("Header size limit exceeded".into());
        }
        bytes.extend_from_slice(&line);
        if line == b"\r\n" {
            return Ok(Some(bytes));
        }
    }
}
fn scan_warc(
    file: Arc<File>,
    read_budget: Arc<AtomicU64>,
    member: &str,
    start: u64,
    length: u64,
    inflated: &mut u64,
    metadata: &mut usize,
    records: &mut Vec<Record>,
) -> Result<(), String> {
    let end = start.checked_add(length).ok_or("Invalid WARC ZIP span")?;
    let mut compressed = BufReader::new(Range {
        file: file.clone(),
        position: start,
        end,
    });
    while !compressed.fill_buf().map_err(|e| e.to_string())?.is_empty() {
        let offset = compressed.get_ref().position - start - compressed.buffer().len() as u64;
        let first = records.len();
        {
            let decoder = GzDecoder::new(&mut compressed);
            let counted = Counted {
                inner: decoder,
                count: 0,
                limit: (MAX_INFLATED - *inflated).min(MAX_BODY + 2 * MAX_HEADER as u64),
            };
            let mut raw = BufReader::new(counted);
            while let Some(header) = read_header(&mut raw, true)? {
                if records.len() - first >= 128 {
                    return Err("More than128 records in one gzip WARC member".into());
                }
                if records.len() >= MAX_ITEMS {
                    return Err("WARC record count limit exceeded".into());
                }
                let (version, headers) = read::headers(&header[..header.len() - 4])?;
                if !matches!(version.as_str(), "WARC/1.0" | "WARC/1.1") {
                    return Err("Unsupported WARC version".into());
                }
                *metadata = metadata
                    .checked_add(header.len())
                    .filter(|n| *n <= MAX_METADATA)
                    .ok_or("WARC header inventory exceeds 32 MiB")?;
                let size = headers
                    .get("content-length")
                    .ok_or("WARC Content-Length missing")?
                    .parse::<u64>()
                    .map_err(|_| "Invalid WARC length")?;
                if size > MAX_BODY {
                    return Err("WARC record body exceeds 2 GiB + header allowance".into());
                }
                let kind = headers.get("warc-type").map(String::as_str).unwrap_or("");
                let body_offset = raw.get_ref().count - raw.buffer().len() as u64;
                let mut block = Counted {
                    inner: raw.by_ref().take(size),
                    count: 0,
                    limit: size,
                };
                let mut block_hash = Sha256::new();
                let mut block_reader = HashReader {
                    inner: &mut block,
                    hash: &mut block_hash,
                };
                let mut buffered = BufReader::new(&mut block_reader);
                let (http_headers, status, mime, payload_hash, payload_length) =
                    if matches!(kind, "response" | "revisit") && size > 0 {
                        let http = read_header(&mut buffered, false)?
                            .ok_or("HTTP response header missing")?;
                        let (line, h) = read::headers(&http[..http.len() - 4])?;
                        if !line.starts_with("HTTP/") {
                            return Err("Invalid HTTP response".into());
                        }
                        let status = line
                            .split_whitespace()
                            .nth(1)
                            .ok_or("Missing HTTP status")?
                            .parse::<u16>()
                            .map_err(|_| "Invalid HTTP status")?;
                        let mime = h
                            .get("content-type")
                            .map(|s| {
                                s.split(';')
                                    .next()
                                    .unwrap_or("")
                                    .trim()
                                    .to_ascii_lowercase()
                            })
                            .unwrap_or_default();
                        let payload_length = size - http.len() as u64;
                        let digest = if kind == "revisit" {
                            io::copy(&mut buffered, &mut io::sink()).map_err(|e| e.to_string())?;
                            String::new()
                        } else {
                            entity_hash(&mut buffered, &h)?
                        };
                        (http, status, mime, digest, payload_length)
                    } else {
                        let (_, digest) = stream_hash(&mut buffered, size)?;
                        (
                            vec![],
                            if kind == "resource" { 200 } else { 0 },
                            headers.get("content-type").cloned().unwrap_or_default(),
                            digest,
                            if kind == "resource" { size } else { 0 },
                        )
                    };
                drop(buffered);
                drop(block_reader);
                *metadata = metadata
                    .checked_add(http_headers.len())
                    .filter(|n| *n <= MAX_METADATA)
                    .ok_or("HTTP header inventory exceeds 32 MiB")?;
                if block.count != size {
                    return Err("Truncated WARC record body".into());
                }
                let digest = format!("sha256:{:x}", block_hash.finalize());
                if let Some(expected) = headers
                    .get("warc-block-digest")
                    .filter(|d| d.starts_with("sha256:"))
                {
                    if read::normalize_sha256(expected)? != digest {
                        return Err("WARC block SHA-256 mismatch".into());
                    }
                }
                if kind != "revisit" && matches!(kind, "response" | "resource") {
                    if let Some(expected) = headers
                        .get("warc-payload-digest")
                        .filter(|d| d.starts_with("sha256:"))
                    {
                        if read::normalize_sha256(expected)? != payload_hash {
                            return Err("WARC payload SHA-256 mismatch".into());
                        }
                    }
                }
                let resolved = kind != "revisit";
                let source = Arc::new(BodySource {
                    file: file.clone(),
                    start: start + offset,
                    compressed_length: 0,
                    body_offset,
                    body_length: size,
                    http_length: http_headers.len() as u64,
                    block_digest: digest,
                    read_budget: read_budget.clone(),
                });
                records.push(Record {
                    headers,
                    block: vec![],
                    payload: vec![],
                    payload_digest: payload_hash,
                    status,
                    mime,
                    member: member.into(),
                    offset,
                    length: 0,
                    stored: 0,
                    resolved,
                    index: BTreeMap::new(),
                    index_key: String::new(),
                    http_headers,
                    payload_length,
                    body_length: size,
                    source: Some(source),
                    payload_source: None,
                });
            }
            *inflated += raw.get_ref().count;
        }
        let finish = compressed.get_ref().position - start - compressed.buffer().len() as u64;
        let span = finish
            .checked_sub(offset)
            .filter(|n| *n > 0)
            .ok_or("Invalid gzip span")?;
        let count = records.len() - first;
        if count == 0 {
            return Err("Empty gzip WARC member".into());
        }
        for (i, record) in records[first..].iter_mut().enumerate() {
            record.length = span;
            record.stored = span / count as u64 + u64::from((i as u64) < span % count as u64);
            let mut source = (**record.source.as_ref().unwrap()).clone();
            source.compressed_length = span;
            record.source = Some(Arc::new(source));
        }
    }
    Ok(())
}
struct HashReader<'a, R> {
    inner: R,
    hash: &'a mut Sha256,
}
impl<R: Read> Read for HashReader<'_, R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(out)?;
        self.hash.update(&out[..n]);
        Ok(n)
    }
}
fn entity_hash(
    input: &mut impl BufRead,
    headers: &BTreeMap<String, String>,
) -> Result<String, String> {
    if let Some(encoding) = headers.get("transfer-encoding") {
        if !encoding.eq_ignore_ascii_case("chunked") {
            return Err("Unsupported HTTP transfer encoding".into());
        }
        let mut hash = Sha256::new();
        let mut total = 0u64;
        let mut chunks = 0;
        loop {
            chunks += 1;
            if chunks > 1_000_000 {
                return Err("HTTP chunk count limit exceeded".into());
            }
            let mut line = vec![];
            input
                .by_ref()
                .take(MAX_HEADER as u64 + 1)
                .read_until(b'\n', &mut line)
                .map_err(|e| e.to_string())?;
            if line.len() > MAX_HEADER || !line.ends_with(b"\r\n") {
                return Err("Invalid HTTP chunk size line".into());
            }
            let text = std::str::from_utf8(&line).map_err(|_| "Invalid chunk size")?;
            let size = u64::from_str_radix(text.trim().split(';').next().unwrap_or(""), 16)
                .map_err(|_| "Invalid chunk size")?;
            if size == 0 {
                let mut trailer = 0;
                loop {
                    let mut line = vec![];
                    input
                        .by_ref()
                        .take(MAX_HEADER as u64 + 1)
                        .read_until(b'\n', &mut line)
                        .map_err(|e| e.to_string())?;
                    trailer += line.len();
                    if trailer > MAX_HEADER || !line.ends_with(b"\r\n") {
                        return Err("Invalid chunk trailer".into());
                    }
                    if line == b"\r\n" {
                        break;
                    }
                }
                if !input.fill_buf().map_err(|e| e.to_string())?.is_empty() {
                    return Err("Trailing bytes after chunked entity".into());
                }
                break;
            }
            total = total
                .checked_add(size)
                .filter(|n| *n <= MAX_BODY)
                .ok_or("Chunked entity size limit exceeded")?;
            let copied =
                io::copy(&mut input.by_ref().take(size), &mut hash).map_err(|e| e.to_string())?;
            if copied != size {
                return Err("Truncated HTTP chunk".into());
            }
            let mut delimiter = [0; 2];
            input
                .read_exact(&mut delimiter)
                .map_err(|e| e.to_string())?;
            if delimiter != *b"\r\n" {
                return Err("Invalid HTTP chunk delimiter".into());
            }
        }
        Ok(format!("sha256:{:x}", hash.finalize()))
    } else {
        Ok(stream_hash(input, MAX_BODY)?.1)
    }
}
