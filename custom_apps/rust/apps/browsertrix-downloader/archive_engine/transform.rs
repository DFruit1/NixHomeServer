use super::read::{self, Archive, Record, MAX_ITEMS};
use super::*;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap},
    fs::File,
    io::Write,
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

/// Stable no-savings outcome; other errors remain fatal.
pub const NO_MATCHING_PAYLOADS: &str = "No matching response payloads in authorized captures";

/// Read-only authorization boundary shared by derived views. Hydration keeps
/// checked lazy payload sources; it never publishes a temporary WACZ.
pub(super) fn authorized_archive(
    path: &Path,
    dependencies: &[AuthorizedDependency],
) -> Result<Archive, String> {
    authorized_archive_limited(path, dependencies, super::streaming::MAX_METADATA * 8)
}
pub(super) fn authorized_archive_limited(
    path: &Path,
    dependencies: &[AuthorizedDependency],
    metadata_limit: usize,
) -> Result<Archive, String> {
    let mut archive = read::load(path)?;
    let inputs = dependencies_for_limited(&archive, dependencies, metadata_limit)?;
    hydrate(&mut archive, &inputs)?;
    Ok(archive)
}

pub fn export_archive(
    source: &Path,
    destination: &Path,
    options: &ExportOptions,
) -> Result<ArchiveReport, String> {
    materialize_archive(source, destination, &[], options)
}

/// Standalone derivative; every external input is explicitly authorized by the
/// caller and hash-checked from the same bytes used by the parser.
fn page_base(url: &str) -> String {
    url::Url::parse(url)
        .map(|mut u| {
            u.set_fragment(None);
            u.to_string()
        })
        .unwrap_or_else(|_| url.into())
}
fn selected_pages(archive: &Archive, options: &ExportOptions) -> Result<BTreeSet<String>, String> {
    let inventory: BTreeSet<_> = archive
        .page_meta
        .iter()
        .map(|p| page_base(&p.url))
        .collect();
    if options.include_urls.is_empty() {
        return Ok(inventory);
    }
    let mut retained: BTreeSet<_> = options.include_urls.iter().map(|u| page_base(u)).collect();
    // All non-page HTML remains an asset, including unlisted iframe documents.
    // Index by base URL so the closure is linear rather than rescanning every
    // record for every frame in a long chain.
    let mut documents = BTreeMap::<String, Vec<&Record>>::new();
    for r in &archive.records {
        if matches!(r.mime.as_str(), "text/html" | "application/xhtml+xml") {
            let base = page_base(r.url());
            if !inventory.contains(&base) {
                retained.insert(base.clone());
            }
            documents.entry(base).or_default().push(r);
        }
    }
    let mut pending: Vec<_> = retained.iter().cloned().collect();
    let mut work = 0u64;
    let mut link_bytes = 0usize;
    while let Some(url) = pending.pop() {
        for record in documents.get(&url).into_iter().flatten() {
            work = work.saturating_add(record.payload_length);
            // Optional analysis has a fixed aggregate budget. Unknown closure
            // keeps the complete page inventory; explicit resource exclusions
            // below are still honored as deliberately lossy user choices.
            if work > super::streaming::MAX_METADATA as u64 {
                retained.extend(inventory);
                return Ok(retained);
            }
            let Some(links) = content::embedded_documents(record)? else {
                retained.extend(inventory);
                return Ok(retained);
            };
            for link in links {
                link_bytes = link_bytes.saturating_add(link.len());
                if link_bytes > super::streaming::MAX_METADATA {
                    retained.extend(inventory);
                    return Ok(retained);
                }
                let base = page_base(&link);
                if retained.insert(base.clone()) {
                    pending.push(base);
                }
            }
        }
    }
    Ok(retained)
}
pub fn materialize_archive(
    source: &Path,
    destination: &Path,
    dependencies: &[AuthorizedDependency],
    options: &ExportOptions,
) -> Result<ArchiveReport, String> {
    let mut archive = read::load(source)?;
    let inputs = dependencies_for(&archive, dependencies)?;
    hydrate(&mut archive, &inputs)?;
    let source_hash = archive.report.sha256.clone();
    let rules = selectors::parse(&options.remove_selectors)?;
    if options.include_urls.len()
        + options.exclude_urls.len()
        + options.exclude_domains.len()
        + options.exclude_mime_prefixes.len()
        > MAX_ITEMS
    {
        return Err("Export filter count limit exceeded".into());
    }
    let inventory: BTreeSet<_> = archive
        .page_meta
        .iter()
        .map(|p| page_base(&p.url))
        .collect();
    let retained_pages = selected_pages(&archive, options)?;
    let mut omitted = vec![];
    let mut records = vec![];
    for record in archive.records {
        let page = matches!(record.mime.as_str(), "text/html" | "application/xhtml+xml");
        let domain = url::Url::parse(record.url())
            .ok()
            .and_then(|u| u.host_str().map(str::to_owned))
            .unwrap_or_default();
        let excluded = options.exclude_urls.iter().any(|u| u == record.url())
            || options.exclude_domains.iter().any(|d| {
                domain.eq_ignore_ascii_case(d)
                    || domain
                        .to_ascii_lowercase()
                        .ends_with(&format!(".{}", d.to_ascii_lowercase()))
            })
            || options
                .exclude_mime_prefixes
                .iter()
                .any(|m| record.mime.starts_with(m))
            || (inventory.contains(&page_base(record.url()))
                && !options.include_urls.is_empty()
                && !retained_pages.contains(&page_base(record.url())));
        if excluded {
            omitted.push(json!({"url":record.url(),"date":record.field("warc-date"),"recordId":record.field("warc-record-id"),"reason":"explicit export filter"}));
            continue;
        }
        if page && !rules.is_empty() && record.mime == "application/xhtml+xml" {
            return Err("XHTML selector transformation unsupported; original preserved".into());
        }
        records.push(record);
    }
    if !records
        .iter()
        .any(|r| matches!(r.kind(), "response" | "resource"))
    {
        return Err("Export selection contains no resources".into());
    }
    let retained_bases: BTreeSet<_> = records.iter().map(|r| page_base(r.url())).collect();
    let pages = archive
        .page_meta
        .into_iter()
        .filter(|p| {
            (options.include_urls.is_empty() || retained_pages.contains(&page_base(&p.url)))
                && !options.exclude_urls.contains(&p.url)
                && retained_bases.contains(&page_base(&p.url))
        })
        .collect();
    let title = if options.title.is_empty() {
        archive.report.title
    } else {
        options.title.clone()
    };
    write_archive(
        destination,
        records,
        pages,
        &title,
        BTreeMap::new(),
        &rules,
        options.deduplicate,
        json!({"operation":"standalone-derived-export","sourceSha256":source_hash,"omissions":omitted,"removeSelectors":options.remove_selectors,"resourcePolicy":"retain non-page resources and embedded page closure; unknown dynamic/analysis closure retains page inventory; only explicit resource exclusions are lossy","fidelity":"derived content; captured originals retained"}),
    )
}

fn dependencies_for(
    source: &Archive,
    authorized: &[AuthorizedDependency],
) -> Result<BTreeMap<String, Archive>, String> {
    dependencies_for_limited(source, authorized, super::streaming::MAX_METADATA * 8)
}
fn dependencies_for_limited(
    source: &Archive,
    authorized: &[AuthorizedDependency],
    metadata_limit: usize,
) -> Result<BTreeMap<String, Archive>, String> {
    if authorized.len() > 16 {
        return Err("At most 16 authorized dependency inputs".into());
    }
    let mut archives = BTreeMap::new();
    let mut cost = source.cost;
    if cost > metadata_limit {
        return Err("Archive metadata exceeds bounded view budget".into());
    }
    for input in authorized {
        if !read::valid_dependency_id(&input.archive_id)
            || input.sha256.len() != 64
            || !input.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("Invalid immutable dependency identity".into());
        }
        if archives.contains_key(&input.archive_id) {
            return Err("Duplicate authorized dependency ID".into());
        }
        let archive = read::load(&input.authorized_local_path)?;
        if !archive.report.sha256.eq_ignore_ascii_case(&input.sha256) {
            return Err(format!("Dependency hash changed: {}", input.archive_id));
        }
        cost = cost
            .checked_add(archive.cost)
            .ok_or("Dependency memory budget overflow")?;
        if cost > metadata_limit {
            return Err("Combined archive dependency metadata exceeds bounded view budget".into());
        }
        archives.insert(input.archive_id.clone(), archive);
    }
    fn visit(
        archive: &Archive,
        inputs: &BTreeMap<String, Archive>,
        active: &mut BTreeSet<String>,
        done: &mut BTreeSet<String>,
    ) -> Result<(), String> {
        for id in &archive.report.dependencies {
            let expected = archive
                .dependency_hashes
                .get(id)
                .ok_or("Dependency missing immutable hash binding")?;
            let target = inputs
                .get(id)
                .ok_or_else(|| format!("Missing authorized dependency: {id}"))?;
            if expected != &target.report.sha256 {
                return Err(format!("Dependency binding mismatch: {id}"));
            }
            if active.contains(id) {
                return Err("Cyclic archive dependencies".into());
            }
            if done.contains(id) {
                continue;
            }
            active.insert(id.clone());
            visit(target, inputs, active, done)?;
            active.remove(id);
            done.insert(id.clone());
        }
        Ok(())
    }
    visit(
        source,
        &archives,
        &mut BTreeSet::new(),
        &mut BTreeSet::new(),
    )?;
    for (id, input) in &archives {
        let mut active = BTreeSet::new();
        active.insert(id.clone());
        visit(input, &archives, &mut active, &mut BTreeSet::new())?;
    }
    Ok(archives)
}
fn hydrate(archive: &mut Archive, inputs: &BTreeMap<String, Archive>) -> Result<(), String> {
    // Resolve only complete payload records. Our own dedupe always refers to a
    // response/resource; arbitrary unresolved revisit chains fail closed.
    let mut work = 2_000_000usize;
    let lookups: BTreeMap<_, _> = inputs
        .iter()
        .map(|(id, input)| (id, read::RecordLookup::new(&input.records)))
        .collect();
    for record in &mut archive.records {
        if record.kind() == "continuation"
            || record
                .headers
                .keys()
                .any(|k| k.starts_with("warc-segment-"))
        {
            return Err("Segmented WARC transformation unsupported".into());
        }
        if record.kind() != "revisit" {
            continue;
        }
        if !record.resolved {
            let required = record.field("warc-x-dependency-sha256");
            let mut candidates = vec![];
            for (id, input) in inputs {
                if !required.is_empty() && input.report.sha256 != required {
                    continue;
                }
                if let Some(target) = lookups[id].find(record, &input.records, &mut work)? {
                    candidates.push(target);
                }
            }
            if candidates.len() != 1 {
                return Err(format!(
                    "Unresolvable/ambiguous external revisit: {} {}",
                    record.url(),
                    record.field("warc-record-id")
                ));
            }
            let target = candidates[0];
            record.payload = target.payload.clone();
            record.payload_source = target
                .payload_source
                .clone()
                .or_else(|| target.source.clone());
            record.payload_length = target.payload_length;
            record.payload_digest = target.payload_digest.clone();
            record.resolved = true;
            if record.mime.is_empty() {
                record.mime = target.mime.clone();
            }
            if record.status == 0 {
                record.status = target.status;
            }
            if record.http_headers.is_empty() {
                record.http_headers = target.http_headers.clone();
            }
        }
        // Bodies remain lazy: retain this capture's HTTP headers, reference the
        // canonical response payload, and stream it only when emitting output.
        record.headers.insert("warc-type".into(), "response".into());
        for key in [
            "warc-profile",
            "warc-refers-to",
            "warc-refers-to-target-uri",
            "warc-refers-to-date",
            "warc-x-dependency-sha256",
            "warc-x-dependency-id",
            "warc-x-dependency-location",
        ] {
            record.headers.remove(key);
        }
        record.headers.remove("warc-truncated");
    }
    archive.report.dependencies.clear();
    archive.dependency_hashes.clear();
    Ok(())
}

/// Produce actual response->revisit deduplication against explicitly supplied
/// immutable captures. The resulting dependency map belongs in retention/replay.
pub fn deduplicate_archive(
    source: &Path,
    destination: &Path,
    dependencies: &[AuthorizedDependency],
) -> Result<ArchiveReport, String> {
    let mut archive = read::load(source)?;
    let inputs = dependencies_for(&archive, dependencies)?;
    hydrate(&mut archive, &inputs)?;
    let mut payloads = HashMap::new();
    for (id, input) in &inputs {
        for record in &input.records {
            if matches!(record.kind(), "response" | "resource") && record.payload_length > 0 {
                payloads
                    .entry((record.digest(), record.mime.clone(), record.transport_key()))
                    .or_insert((id, input, record));
            }
        }
    }
    let mut used = BTreeMap::new();
    let mut converted = 0;
    for record in &mut archive.records {
        if record.kind() != "response" || record.payload_length == 0 {
            continue;
        }
        if let Some((id, input, target)) =
            payloads.get(&(record.digest(), record.mime.clone(), record.transport_key()))
        {
            to_revisit(record, target)?;
            record
                .headers
                .insert("warc-x-dependency-id".into(), (*id).clone());
            record.headers.insert(
                "warc-x-dependency-sha256".into(),
                input.report.sha256.clone(),
            );
            record.headers.insert(
                "warc-x-dependency-location".into(),
                format!("{}:{}:{}", target.member, target.offset, target.length),
            );
            used.insert((*id).clone(), input.report.sha256.clone());
            converted += 1;
        }
    }
    if converted == 0 {
        return Err(NO_MATCHING_PAYLOADS.into());
    }
    write_archive(
        destination,
        archive.records,
        archive.page_meta,
        &archive.report.title,
        used,
        &[],
        false,
        json!({"operation":"cross-capture-payload-dedupe","sourceSha256":archive.report.sha256,"convertedResponses":converted,"standalone":false}),
    )
}
fn to_revisit(record: &mut Record, target: &Record) -> Result<(), String> {
    if target.field("warc-record-id").is_empty() || target.field("warc-date").is_empty() {
        return Err("Dedupe target lacks stable WARC identity".into());
    }
    record.headers.insert("warc-type".into(), "revisit".into());
    record.headers.insert(
        "warc-profile".into(),
        "http://netpreserve.org/warc/1.1/revisit/identical-payload-digest".into(),
    );
    record.headers.insert(
        "warc-refers-to".into(),
        target.field("warc-record-id").into(),
    );
    record
        .headers
        .insert("warc-refers-to-target-uri".into(), target.url().into());
    record.headers.insert(
        "warc-refers-to-date".into(),
        target.field("warc-date").into(),
    );
    record
        .headers
        .insert("warc-payload-digest".into(), target.digest());
    record.payload_digest = target.digest();
    record.payload.clear();
    record.resolved = false;
    Ok(())
}
fn replace_payload(record: &mut Record, bytes: Vec<u8>) -> Result<(), String> {
    let header_text = std::str::from_utf8(
        record
            .http_headers
            .strip_suffix(b"\r\n\r\n")
            .ok_or("HTTP headers missing")?,
    )
    .map_err(|_| "NonUTF8 HTTP headers")?;
    let mut lines = header_text.split("\r\n");
    let status = lines.next().ok_or("Missing HTTP status")?;
    let mut block = format!("{status}\r\n");
    for line in lines {
        let (key, _) = line.split_once(':').ok_or("Invalid HTTP header")?;
        if !matches!(
            key.to_ascii_lowercase().as_str(),
            "content-encoding"
                | "transfer-encoding"
                | "content-length"
                | "content-type"
                | "content-md5"
                | "digest"
                | "etag"
        ) {
            block.push_str(line);
            block.push_str("\r\n");
        }
    }
    block.push_str(&format!(
        "Content-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n\r\n",
        bytes.len()
    ));
    record.block = block.into_bytes();
    record.block.extend_from_slice(&bytes);
    record.payload_digest = format!("sha256:{}", read::hash(&bytes));
    record.payload = bytes;
    record.payload_length = record.payload.len() as u64;
    record.body_length = record.block.len() as u64;
    record.source = None;
    record.payload_source = None;
    record.http_headers = record.block[..record.block.len() - record.payload.len()].to_vec();
    record.headers.insert("warc-type".into(), "response".into());
    record.headers.remove("warc-payload-digest");
    record.headers.remove("warc-block-digest");
    Ok(())
}

/// Prefer successful repaired targets by retaining all parent records for other
/// URLs and removing replaced targets from this new derivative's replay index.
/// Actual capture dates remain unchanged (mixed-time provenance is recorded).
pub fn compose_repair(
    parent: &Path,
    repair: &Path,
    destination: &Path,
    dependencies: &[AuthorizedDependency],
    targets: &[String],
) -> Result<ArchiveReport, String> {
    if targets.is_empty() || targets.len() > MAX_ITEMS {
        return Err("Repair requires a bounded nonempty target set".into());
    }
    let mut original = read::load(parent)?;
    let mut patch = read::load(repair)?;
    let inputs = dependencies_for(&original, dependencies)?;
    hydrate(&mut original, &inputs)?;
    let inputs = dependencies_for(&patch, dependencies)?;
    hydrate(&mut patch, &inputs)?;
    if original.cost + patch.cost > super::streaming::MAX_METADATA * 8 {
        return Err("Combined repair inflation limit exceeded".into());
    }
    let successful: BTreeSet<String> = patch
        .records
        .iter()
        .filter(|r| {
            targets.contains(&r.url().to_owned())
                && matches!(r.kind(), "response" | "resource")
                && (200..400).contains(&r.status)
        })
        .map(|r| r.url().into())
        .collect();
    if successful.is_empty() {
        return Err("Repair contains no successful selected targets".into());
    }
    let patch_pages: BTreeMap<_, _> = patch
        .page_meta
        .iter()
        .map(|p| {
            let ts = chrono::DateTime::parse_from_rfc3339(&p.ts)
                .map(|d| d.to_rfc3339())
                .unwrap_or_else(|_| p.ts.clone());
            ((p.url.clone(), ts), p.clone())
        })
        .collect();
    let successful_pages: BTreeSet<_> = patch
        .records
        .iter()
        .filter(|r| {
            successful.contains(r.url())
                && matches!(r.kind(), "response" | "resource")
                && (200..400).contains(&r.status)
        })
        .filter_map(|r| read::page_key(&patch_pages, r, Some(&patch.page_ids)))
        .collect();
    original.records.retain(|r| !successful.contains(r.url()));
    // Include patch dependencies too; limiting to selected HTML alone drops the
    // assets that make a repaired page render. Failed parent targets stay intact.
    for record in patch.records {
        if !targets.contains(&record.url().to_owned())
            || (successful.contains(record.url())
                && matches!(record.kind(), "response" | "resource")
                && (200..400).contains(&record.status))
        {
            original.records.push(record);
        }
    }
    if original.records.len() > MAX_ITEMS {
        return Err("Composed repair record limit exceeded".into());
    }
    original.page_meta.retain(|p| !successful.contains(&p.url));
    original.page_meta.extend(
        patch_pages
            .into_iter()
            .filter(|(key, _)| successful_pages.contains(key))
            .map(|(_, page)| page),
    );
    write_archive(
        destination,
        original.records,
        original.page_meta,
        &original.report.title,
        BTreeMap::new(),
        &[],
        false,
        json!({"operation":"repair-composition","parentSha256":original.report.sha256,"repairSha256":patch.report.sha256,"replacedTargets":successful,"requestedTargets":targets,"selectionPolicy":"only successful repair responses replace selected URLs; failed alternatives excluded; other parent responses and patch assets retained","mixedCaptureTimes":true}),
    )
}

struct OutputHash<'a, W> {
    inner: &'a mut W,
    hash: &'a mut Sha256,
    position: &'a mut u64,
}
impl<W: Write> Write for OutputHash<'_, W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if (*self.position).saturating_add(bytes.len() as u64) > super::streaming::MAX_ARCHIVE {
            return Err(std::io::Error::other("Output WARC exceeds 32 GiB limit"));
        }
        let n = self.inner.write(bytes)?;
        self.hash.update(&bytes[..n]);
        *self.position += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
fn encode_record(record: &Record, out: impl Write) -> Result<(), String> {
    let length = record.output_length();
    let (actual, block_digest) =
        super::streaming::stream_hash(record.output_reader()?, super::streaming::MAX_BODY)?;
    if length != actual {
        return Err("Record output length mismatch".into());
    }
    let mut headers = record.headers.clone();
    headers.insert("content-length".into(), length.to_string());
    headers.insert("warc-block-digest".into(), block_digest);
    if record.kind() != "revisit" && matches!(record.kind(), "response" | "resource") {
        headers.insert("warc-payload-digest".into(), record.digest());
    }
    let mut raw = String::from("WARC/1.1\r\n");
    for (key, value) in headers {
        if key.chars().any(|c| c == '\r' || c == '\n')
            || value.chars().any(|c| c == '\r' || c == '\n')
        {
            return Err("Unsafe WARC header".into());
        }
        raw.push_str(&format!("{key}: {value}\r\n"));
    }
    raw.push_str("\r\n");
    let mut encoder = flate2::write::GzEncoder::new(out, flate2::Compression::default());
    encoder
        .write_all(raw.as_bytes())
        .map_err(|e| e.to_string())?;
    let copied =
        std::io::copy(&mut record.output_reader()?, &mut encoder).map_err(|e| e.to_string())?;
    if copied != length {
        return Err("Source body changed during output".into());
    }
    encoder.write_all(b"\r\n\r\n").map_err(|e| e.to_string())?;
    encoder.finish().map_err(|e| e.to_string())?;
    Ok(())
}

fn write_archive(
    destination: &Path,
    records: Vec<Record>,
    pages: Vec<PageRecord>,
    title: &str,
    dependencies: BTreeMap<String, String>,
    rules: &[selectors::Selector],
    deduplicate: bool,
    mut provenance: Value,
) -> Result<ArchiveReport, String> {
    if destination.exists() {
        return Err("Destination exists; originals are immutable".into());
    }
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut staging = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    let mut zip = ZipWriter::new(staging.as_file_mut());
    let mut seen_ids = BTreeSet::new();
    for record in &records {
        let id = record.field("warc-record-id");
        if !id.is_empty() && !seen_ids.insert(id.to_owned()) {
            return Err("Duplicate WARC record IDs in output; ambiguous identity refused".into());
        }
    }
    let mut manifest_resources = vec![];
    zip.start_file(
        "archive/derived.warc.gz",
        SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .large_file(true),
    )
    .map_err(|e| e.to_string())?;
    let mut warc_hash = Sha256::new();
    let mut warc_position = 0u64;
    let mut index = vec![];
    let mut page_rows = BTreeMap::<(String, String), PageRecord>::new();
    let infer_pages = pages.is_empty();
    for mut page in pages {
        if !rules.is_empty() {
            // Rendered native baselines may contain removed confidential text.
            // Clear all rows, including unmatched capture timestamps, before
            // rebuilding bounded text from the actual rewritten responses.
            page.text.clear();
            page.title.clear();
            page.resource_urls.clear();
        }
        page_rows.insert((page.url.clone(), page.ts.clone()), page);
    }
    let mut page_data = serde_json::to_vec(
        &json!({"format":"json-pages-1.0","id":"pages","title":"Derived archived pages"}),
    )
    .map_err(|e| e.to_string())?;
    page_data.push(b'\n');
    let row_bytes = |page: &PageRecord| -> Result<usize, String> {
        Ok(serde_json::to_vec(page).map_err(|e| e.to_string())?.len() + 1)
    };
    let mut page_metadata_bytes = page_data.len();
    for page in page_rows.values() {
        page_metadata_bytes += row_bytes(page)?;
    }
    if page_metadata_bytes > super::streaming::MAX_METADATA {
        return Err("Source page metadata exceeds output inventory bound".into());
    }
    let mut analysis_omissions = 0u64;
    let page_urls: BTreeSet<_> = page_rows.keys().map(|(url, _)| url.clone()).collect();
    let mut canonical = HashMap::<(String, String, String), Record>::new();
    for original in &records {
        // Transform one small HTML body at a time. Never retain all edited
        // page payloads in memory across a multi-GiB export.
        let mut record = original.clone();
        if !rules.is_empty() && record.mime == "text/html" {
            let dom = content::dom(&content::payload_limited(&record, content::MAX_HTML)?)?;
            selectors::remove(&dom, rules)?;
            let mut html = vec![];
            dom.serialize(&mut html).map_err(|e| e.to_string())?;
            replace_payload(&mut record, html)?;
        }
        let page_analysis = if matches!(record.mime.as_str(), "text/html" | "application/xhtml+xml")
            && record.resolved
            && (infer_pages || page_urls.contains(record.url()))
        {
            Some(content::analyse(&record)?)
        } else {
            None
        };
        if page_analysis
            .as_ref()
            .is_some_and(|analysis| analysis.content.is_none())
        {
            analysis_omissions += 1;
        }
        let page_text = page_analysis.and_then(|analysis| analysis.content);
        if deduplicate && record.kind() == "response" && record.payload_length > 0 {
            let key = (record.digest(), record.mime.clone(), record.transport_key());
            if let Some(target) = canonical.get(&key) {
                to_revisit(&mut record, target)?;
            } else {
                let mut reference = record.clone();
                reference.block.clear();
                reference.payload.clear();
                canonical.insert(key, reference);
            }
        }
        let offset = warc_position;
        encode_record(
            &record,
            OutputHash {
                inner: &mut zip,
                hash: &mut warc_hash,
                position: &mut warc_position,
            },
        )?;
        if warc_position > super::streaming::MAX_ARCHIVE {
            return Err("Output WARC exceeds 32 GiB limit".into());
        }
        let encoded_length = warc_position - offset;
        if matches!(record.kind(), "response" | "resource" | "revisit") {
            let mut row = record.index.clone();
            for (key, value) in [
                ("url", json!(record.url())),
                ("status", json!(record.status.to_string())),
                (
                    "mime",
                    json!(if record.kind() == "revisit" {
                        "warc/revisit"
                    } else {
                        &record.mime
                    }),
                ),
                (
                    "digest",
                    json!(if record.kind() == "revisit" {
                        record.field("warc-payload-digest").to_owned()
                    } else {
                        record.digest()
                    }),
                ),
                ("offset", json!(offset.to_string())),
                ("length", json!(encoded_length.to_string())),
                ("filename", json!("derived.warc.gz")),
            ] {
                row.insert(key.into(), value);
            }
            if record.kind() == "revisit" {
                row.insert(
                    "orig.url".into(),
                    json!(record.field("warc-refers-to-target-uri")),
                );
                row.insert(
                    "orig.timestamp".into(),
                    json!(read::timestamp_of(record.field("warc-refers-to-date"))?),
                );
            }
            index.push(format!(
                "{} {} {}\n",
                if record.index_key.is_empty() {
                    super::index_key::surt(record.url())
                } else {
                    record.index_key.clone()
                },
                read::timestamp_of(record.field("warc-date"))?,
                serde_json::to_string(&row).map_err(|e| e.to_string())?
            ));
            if let Some((text, title, links)) = page_text {
                let key = read::page_key(&page_rows, &record, None)
                    .unwrap_or((record.url().into(), record.field("warc-date").into()));
                let previous_bytes = page_rows
                    .get(&key)
                    .map(&row_bytes)
                    .transpose()?
                    .unwrap_or(0);
                let mut page = page_rows.get(&key).cloned().unwrap_or_default();
                page.url = record.url().into();
                if page.ts.is_empty() {
                    page.ts = record.field("warc-date").into();
                }
                page.bytes = encoded_length;
                page.status = record.status;
                let baseline = page.clone();
                // Native Browsertrix rendered baselines include JavaScript
                // content absent from the original response. Regenerate only
                // when this derivative actually rewrites HTML selectors.
                if !rules.is_empty() || page.text.is_empty() {
                    page.text = text;
                }
                if !rules.is_empty() || page.title.is_empty() {
                    page.title = title;
                }
                page.resource_urls = links;
                let without = page_metadata_bytes - previous_bytes;
                if without + row_bytes(&page)? > super::streaming::MAX_METADATA {
                    page = baseline;
                    analysis_omissions += 1;
                }
                page_metadata_bytes = without + row_bytes(&page)?;
                if page_metadata_bytes > super::streaming::MAX_METADATA {
                    return Err("Page structural metadata exceeds output inventory bound".into());
                }
                page_rows.insert(key, page);
            } else if infer_pages
                && matches!(record.mime.as_str(), "text/html" | "application/xhtml+xml")
            {
                let key = (record.url().into(), record.field("warc-date").into());
                if !page_rows.contains_key(&key) {
                    let page = PageRecord {
                        url: record.url().into(),
                        ts: record.field("warc-date").into(),
                        bytes: encoded_length,
                        status: record.status,
                        ..Default::default()
                    };
                    page_metadata_bytes += row_bytes(&page)?;
                    if page_metadata_bytes > super::streaming::MAX_METADATA {
                        return Err(
                            "Page structural metadata exceeds output inventory bound".into()
                        );
                    }
                    page_rows.insert(key, page);
                }
            }
        }
    }
    manifest_resources.push(json!({"name":"derived.warc.gz","path":"archive/derived.warc.gz","bytes":warc_position,"hash":format!("sha256:{:x}",warc_hash.finalize())}));
    if index.iter().map(String::len).sum::<usize>() > super::streaming::MAX_METADATA {
        return Err("Output CDX inventory exceeds 32 MiB".into());
    }
    index.sort();
    let index = index.concat().into_bytes();
    provenance["optionalPageAnalysisOmissions"] = json!(analysis_omissions);
    for page in page_rows.into_values() {
        page_data.extend_from_slice(&serde_json::to_vec(&page).map_err(|e| e.to_string())?);
        page_data.push(b'\n');
        if page_data.len() > super::streaming::MAX_METADATA {
            return Err("Page export limit exceeded".into());
        }
    }
    let entries = vec![
        ("indexes/index.cdxj", index),
        ("pages/pages.jsonl", page_data),
        (
            "provenance.json",
            serde_json::to_vec(&provenance).map_err(|e| e.to_string())?,
        ),
    ];
    for (name, data) in entries {
        manifest_resources.push(json!({"name":name,"path":name,"bytes":data.len(),"hash":format!("sha256:{}",read::hash(&data))}));
        zip.start_file(
            name,
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
        )
        .map_err(|e| e.to_string())?;
        zip.write_all(&data).map_err(|e| e.to_string())?;
    }
    // wabac 2.27.2 WACZFile reads relation.requires filenames for revisit
    // fallback. These labels match the backend's MultiWACZ resources.name;
    // they are never filesystem paths or permission to fetch a dependency.
    let requires: Vec<_> = dependencies
        .iter()
        .map(|(id, hash)| json!({"filename":format!("{id}.wacz"),"hash":format!("sha256:{hash}")}))
        .collect();
    let manifest=serde_json::to_vec(&json!({"profile":"data-package","wacz_version":"1.1.1","title":title,"description":"Derived archive; provenance.json records omissions and source fixity","created":chrono::Utc::now().to_rfc3339(),"resources":manifest_resources,"relation":{"requires":requires},"webArchivesDependencies":dependencies.keys().collect::<Vec<_>>(),"webArchivesDependencyHashes":dependencies})).map_err(|e|e.to_string())?;
    zip.start_file(
        "datapackage.json",
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .map_err(|e| e.to_string())?;
    zip.write_all(&manifest).map_err(|e| e.to_string())?;
    zip.start_file(
        "datapackage-digest.json",
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .map_err(|e| e.to_string())?;
    zip.write_all(
        &serde_json::to_vec(
            &json!({"path":"datapackage.json","hash":format!("sha256:{}",read::hash(&manifest))}),
        )
        .map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    zip.finish().map_err(|e| e.to_string())?;
    staging.as_file().sync_all().map_err(|e| e.to_string())?;
    let report = read::load(staging.path())?.report()?;
    staging
        .persist_noclobber(destination)
        .map_err(|e| e.to_string())?;
    File::open(parent)
        .and_then(|d| d.sync_all())
        .map_err(|e| format!("Output published but directory sync failed: {e}"))?;
    Ok(report)
}
