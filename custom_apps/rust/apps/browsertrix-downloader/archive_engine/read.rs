use super::*;
use flate2::read::MultiGzDecoder;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap},
    io::{Cursor, Read},
};

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
    pub http_headers: Vec<u8>,
    pub payload_length: u64,
    pub body_length: u64,
    pub source: Option<std::sync::Arc<super::streaming::BodySource>>,
    pub payload_source: Option<std::sync::Arc<super::streaming::BodySource>>,
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
    pub fn transport_key(&self) -> String {
        if self.http_headers.is_empty() {
            return String::new();
        }
        headers(&self.http_headers[..self.http_headers.len() - 4])
            .ok()
            .and_then(|(_, h)| h.get("transfer-encoding").cloned())
            .unwrap_or_default()
            .to_ascii_lowercase()
    }
    pub fn body_reader(&self) -> Result<Box<dyn Read>, String> {
        if let Some(source) = &self.payload_source {
            return Ok(Box::new(
                Cursor::new(self.http_headers.clone()).chain(source.reader(true)?),
            ));
        }
        if let Some(source) = &self.source {
            return source.reader(false);
        }
        Ok(Box::new(Cursor::new(self.block.clone())))
    }
    pub fn output_length(&self) -> u64 {
        if self.kind() == "revisit" {
            self.http_headers.len() as u64
        } else if self.payload_source.is_some() {
            self.http_headers.len() as u64 + self.payload_length
        } else if self.source.is_some() {
            self.body_length
        } else {
            self.block.len() as u64
        }
    }
    pub fn output_reader(&self) -> Result<Box<dyn Read>, String> {
        if self.kind() == "revisit" {
            Ok(Box::new(Cursor::new(self.http_headers.clone())))
        } else {
            self.body_reader()
        }
    }
    pub fn eager_body_limited(&self, limit: usize) -> Result<Record, String> {
        let mut loaded = self.clone();
        loaded.block = bounded(self.body_reader()?, limit)?;
        loaded.payload = if self.http_headers.is_empty() {
            loaded.block.clone()
        } else {
            loaded
                .block
                .get(self.http_headers.len()..)
                .ok_or("Truncated lazy HTTP body")?
                .to_vec()
        };
        loaded.source = None;
        loaded.payload_source = None;
        Ok(loaded)
    }
}

pub(super) struct Archive {
    pub report: ArchiveReport,
    pub records: Vec<Record>,
    pub page_meta: Vec<PageRecord>,
    pub page_ids: BTreeMap<(String, String), String>,
    pub dependency_hashes: BTreeMap<String, String>,
    pub cost: usize,
}

pub(super) fn load(path: &Path) -> Result<Archive, String> {
    super::streaming::load(path)
}

pub(super) fn normalize_sha256(value: &str) -> Result<String, String> {
    let (algorithm, encoded) = value
        .split_once(':')
        .ok_or("Unsupported digest algorithm")?;
    if !algorithm.eq_ignore_ascii_case("sha256") {
        return Err("Unsupported digest algorithm".into());
    }
    if encoded.len() == 64 && encoded.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Ok(format!("sha256:{}", encoded.to_ascii_lowercase()));
    }
    let encoded = encoded.trim_end_matches('=');
    if encoded.len() != 52 {
        return Err("Invalid SHA-256 digest encoding".into());
    }
    let mut bytes = Vec::with_capacity(32);
    let mut acc = 0u32;
    let mut bits = 0;
    for ch in encoded.bytes() {
        let value = match ch.to_ascii_uppercase() {
            b'A'..=b'Z' => ch.to_ascii_uppercase() - b'A',
            b'2'..=b'7' => ch - b'2' + 26,
            _ => return Err("Invalid SHA-256 Base32 digest".into()),
        };
        acc = (acc << 5) | value as u32;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            bytes.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    if bytes.len() != 32 || acc != 0 {
        return Err("Invalid SHA-256 Base32 padding".into());
    }
    Ok(format!(
        "sha256:{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ))
}
pub(super) fn check_digest(expected: &str, bytes: &[u8]) -> Result<(), String> {
    if normalize_sha256(expected)? != format!("sha256:{}", hash(bytes)) {
        return Err("SHA-256 mismatch".into());
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

fn numeric(value: &Value, key: &str) -> Result<u64, String> {
    value
        .get(key)
        .and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .ok_or_else(|| format!("Invalid CDX {key}"))
}
pub(super) fn validate_indexes(
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
    let mut block_inflated = 0usize;
    let mut block_count = 0usize;
    let mut block_spans = BTreeMap::<String, Vec<(u64, u64)>>::new();
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
                let segment = &data[offset as usize..end as usize];
                let mut decoder = flate2::bufread::GzDecoder::new(Cursor::new(segment));
                let expanded = bounded(
                    &mut decoder,
                    super::streaming::MAX_METADATA - block_inflated,
                )?;
                if decoder.into_inner().position() != length {
                    return Err("CDX block length is not one exact gzip member".into());
                }
                block_inflated += expanded.len();
                if let Some(digest) = v
                    .get("digest")
                    .and_then(Value::as_str)
                    .filter(|d| d.starts_with("sha256:"))
                {
                    check_digest(digest, segment)?;
                }
                let first = lines(&expanded)?
                    .next()
                    .ok_or("Empty compressed CDX block")?;
                let first_end = first.find('{').ok_or("Malformed compressed CDX block")?;
                if line[..start].trim_end() != first[..first_end].trim_end() {
                    return Err("CDX block lookup key mismatch".into());
                }
                block_spans
                    .entry(path.clone())
                    .or_default()
                    .push((offset, length));
                block_count += 1;
                if block_count > MAX_ITEMS {
                    return Err("CDX block count limit exceeded".into());
                }
            }
        }
        if !(name.ends_with(".cdx")
            || name.ends_with(".cdxj")
            || name.ends_with(".cdx.gz")
            || name.ends_with(".cdxj.gz"))
        {
            continue;
        }
        let raw = if name.ends_with(".gz") {
            bounded(
                MultiGzDecoder::new(bytes.as_slice()),
                super::streaming::MAX_METADATA - *inflated,
            )?
        } else {
            bounded(bytes.as_slice(), super::streaming::MAX_METADATA - *inflated)?
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
            if let Some(digest) = value.get("digest").and_then(Value::as_str) {
                let normalized = digest.strip_prefix("sha256:").unwrap_or(digest);
                if digest.starts_with("sha256:")
                    || (normalized.len() == 64 && normalized.bytes().all(|b| b.is_ascii_hexdigit()))
                    || normalized.trim_end_matches('=').len() == 52
                {
                    let actual = if records[i].kind() == "revisit" {
                        records[i].field("warc-payload-digest").to_owned()
                    } else {
                        records[i].digest()
                    };
                    if normalize_sha256(&format!("sha256:{normalized}"))?
                        != normalize_sha256(&actual)?
                    {
                        return Err("CDX digest differs from WARC payload".into());
                    }
                }
            }
            records[i].index_key = line[..start]
                .split_whitespace()
                .next()
                .ok_or("CDX lookup key missing")?
                .into();
            records[i].index = serde_json::from_value(value).map_err(|e| e.to_string())?;
        }
    }
    for (name, data) in members
        .iter()
        .filter(|(name, _)| name.ends_with(".cdx.gz") || name.ends_with(".cdxj.gz"))
    {
        let spans = block_spans
            .get_mut(name)
            .ok_or("Compressed CDX requires a matching .idx block index for ReplayWeb.page")?;
        spans.sort_unstable();
        let mut end = 0;
        for (offset, length) in spans {
            if *offset != end {
                return Err("Compressed CDX block coverage overlaps or has gaps".into());
            }
            end += *length;
        }
        if end != data.len() as u64 {
            return Err("Compressed CDX block index omits bytes".into());
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
pub(super) fn page_key(
    pages: &BTreeMap<(String, String), PageRecord>,
    record: &Record,
    ids: Option<&BTreeMap<(String, String), String>>,
) -> Option<(String, String)> {
    let target = chrono::DateTime::parse_from_rfc3339(record.field("warc-date"))
        .map(|d| d.timestamp_millis())
        .ok();
    pages
        .range(
            (record.url().to_owned(), String::new())
                ..=(record.url().to_owned(), "\u{10ffff}".to_owned()),
        )
        .min_by_key(|(key, _)| {
            let matching_id = ids
                .and_then(|ids| ids.get(*key))
                .is_some_and(|id| !id.is_empty() && id == record.field("warc-page-id"));
            let delta = target
                .and_then(|target| {
                    chrono::DateTime::parse_from_rfc3339(&key.1)
                        .ok()
                        .map(|stamp| stamp.timestamp_millis().abs_diff(target))
                })
                .unwrap_or(u64::MAX);
            (!matching_id, delta)
        })
        .map(|(key, _)| key.clone())
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
        let lookup = RecordLookup::new(&self.records);
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
                if let Some(target) = lookup.find(&self.records[i], &self.records, &mut work)? {
                    let payload = target.payload.clone();
                    let source = target
                        .payload_source
                        .clone()
                        .or_else(|| target.source.clone());
                    let length = target.payload_length;
                    let digest = target.payload_digest.clone();
                    let mime = target.mime.clone();
                    let status = target.status;
                    if target.resolved {
                        self.records[i].resolved = true;
                        self.records[i].payload = payload;
                        self.records[i].payload_source = source;
                        self.records[i].payload_length = length;
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
        let mut extracted_bytes = 0usize;
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
                    || self.page_meta.is_empty())
            {
                let mut analysis = content::analyse(record)?;
                if let Some((text, title, links)) = &analysis.content {
                    let extra =
                        text.len() + title.len() + links.iter().map(String::len).sum::<usize>();
                    if extracted_bytes.saturating_add(extra) > super::streaming::MAX_METADATA {
                        analysis.content = None;
                        analysis.omitted =
                            Some("Aggregate optional text/link analysis budget exhausted".into());
                    } else {
                        extracted_bytes += extra;
                    }
                }
                if let Some(reason) = analysis.omitted {
                    report.warnings.push(format!("DOM/text/dependency analysis omitted for {}: {reason}; crawler page metadata retained and asset closure conservative",record.url()));
                }
                let ts = chrono::DateTime::parse_from_rfc3339(record.field("warc-date"))
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_else(|_| record.field("warc-date").into());
                let key = page_key(&pages, record, Some(&self.page_ids))
                    .unwrap_or((record.url().into(), ts));
                let page = pages.entry(key).or_default();
                page.url = record.url().into();
                if page.ts.is_empty() {
                    page.ts = record.field("warc-date").into();
                }
                page.bytes = record.stored;
                page.status = record.status;
                if let Some((text, title, links)) = analysis.content {
                    if page.title.is_empty() {
                        page.title = title;
                    }
                    if page.text.is_empty() {
                        page.text = text;
                    }
                    page.resource_urls = links;
                }
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
        let mut attribution_bytes = 0usize;
        let mut attribution_omissions = 0usize;
        for resource in &mut report.resources {
            if let Some(pages) = attribution.get(&resource.url) {
                // Repeated captures of one shared URL can multiply a bounded
                // page inventory into an unbounded resource/pages cross product.
                let extra = pages
                    .iter()
                    .map(|p| p.len() + std::mem::size_of::<String>())
                    .sum::<usize>();
                if attribution_bytes.saturating_add(extra) <= super::streaming::MAX_METADATA {
                    resource.pages = pages.iter().cloned().collect();
                    attribution_bytes += extra;
                } else {
                    attribution_omissions += 1;
                }
            }
        }
        if attribution_omissions > 0 {
            report.warnings.push(format!("Page attribution omitted for {attribution_omissions} resource rows at the 32 MiB optional attribution budget; all resource rows retained and export asset closure conservative"));
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
pub(super) struct RecordLookup {
    ids: HashMap<String, Vec<usize>>,
    targets: HashMap<(String, String), Vec<usize>>,
}
impl RecordLookup {
    pub fn new(records: &[Record]) -> Self {
        let mut out = Self {
            ids: HashMap::new(),
            targets: HashMap::new(),
        };
        for (i, r) in records.iter().enumerate() {
            out.ids
                .entry(r.field("warc-record-id").into())
                .or_default()
                .push(i);
            out.targets
                .entry((r.url().into(), r.field("warc-date").into()))
                .or_default()
                .push(i);
        }
        out
    }
    pub fn find<'a>(
        &self,
        record: &Record,
        records: &'a [Record],
        work: &mut usize,
    ) -> Result<Option<&'a Record>, String> {
        let indices = if record.field("warc-refers-to").is_empty() {
            self.targets.get(&(
                record.field("warc-refers-to-target-uri").into(),
                record.field("warc-refers-to-date").into(),
            ))
        } else {
            self.ids.get(record.field("warc-refers-to"))
        };
        let Some(indices) = indices else {
            return Ok(None);
        };
        *work = work
            .checked_sub(indices.len())
            .ok_or("Revisit resolution work limit exceeded")?;
        let mut found = None;
        for i in indices {
            let r = &records[*i];
            if revisit_matches(record, r) {
                if found.is_some() {
                    return Ok(None);
                }
                found = Some(r);
            }
        }
        Ok(found)
    }
}
fn revisit_matches(record: &Record, r: &Record) -> bool {
    if !r.resolved
        || (!record.http_headers.is_empty() && record.transport_key() != r.transport_key())
    {
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
    digest.is_empty()
        || r.field("warc-payload-digest") == digest
        || r.digest() == digest
        || (digest.starts_with("sha256:")
            && normalize_sha256(digest)
                .ok()
                .zip(normalize_sha256(&r.digest()).ok())
                .is_some_and(|(expected, actual)| expected == actual))
}
