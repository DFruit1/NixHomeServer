use super::read::{self, Archive, Record, MAX_BYTES, MAX_ITEMS};
use super::*;
use serde_json::{json, Value};
use std::{
    collections::{BTreeSet, HashMap},
    fs::File,
    io::Write,
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

pub fn export_archive(
    source: &Path,
    destination: &Path,
    options: &ExportOptions,
) -> Result<ArchiveReport, String> {
    materialize_archive(source, destination, &[], options)
}

/// Standalone derivative; every external input is explicitly authorized by the
/// caller and hash-checked from the same bytes used by the parser.
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
    let mut omitted = vec![];
    let mut records = vec![];
    for mut record in archive.records {
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
            || (page
                && !options.include_urls.is_empty()
                && !options.include_urls.iter().any(|u| u == record.url()));
        if excluded {
            omitted.push(json!({"url":record.url(),"date":record.field("warc-date"),"recordId":record.field("warc-record-id"),"reason":"explicit export filter"}));
            continue;
        }
        if page && !rules.is_empty() {
            if record.mime == "application/xhtml+xml" {
                return Err("XHTML selector transformation unsupported; original preserved".into());
            }
            let dom = content::dom(&content::payload(&record)?)?;
            selectors::remove(&dom, &rules)?;
            let mut html = vec![];
            dom.serialize(&mut html).map_err(|e| e.to_string())?;
            replace_payload(&mut record, html)?;
        }
        records.push(record);
    }
    if !records
        .iter()
        .any(|r| matches!(r.kind(), "response" | "resource"))
    {
        return Err("Export selection contains no resources".into());
    }
    if options.deduplicate {
        dedupe_local(&mut records)?;
    }
    let pages = archive
        .page_meta
        .into_iter()
        .filter(|p| records.iter().any(|r| r.url() == p.url))
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
        json!({"operation":"standalone-derived-export","sourceSha256":source_hash,"omissions":omitted,"removeSelectors":options.remove_selectors,"resourcePolicy":"retain all non-page resources unless explicitly excluded; hidden DOM never proves unused resources","fidelity":"derived content; captured originals retained"}),
    )
}

fn dependencies_for(
    source: &Archive,
    authorized: &[AuthorizedDependency],
) -> Result<BTreeMap<String, Archive>, String> {
    if authorized.len() > 16 {
        return Err("At most 16 authorized dependency inputs".into());
    }
    let mut archives = BTreeMap::new();
    let mut cost = source.cost;
    for input in authorized {
        if input.archive_id.is_empty()
            || input.archive_id.len() > 256
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
        if cost > MAX_BYTES * 2 {
            return Err("Combined archive dependency inflation exceeds 512 MiB".into());
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
            for input in inputs.values() {
                if !required.is_empty() && input.report.sha256 != required {
                    continue;
                }
                if input.records.len() > work {
                    return Err("Revisit resolution work limit exceeded".into());
                }
                work -= input.records.len();
                if let Some(target) = read::find_revisit(record, &input.records) {
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
            record.payload_digest = target.payload_digest.clone();
            record.resolved = true;
            if record.mime.is_empty() {
                record.mime = target.mime.clone();
            }
            if record.status == 0 {
                record.status = target.status;
            }
            if record.block.is_empty() {
                record.block = target.block.clone();
            }
        }
        // A revisit's HTTP headers belong to the new capture; retain them and
        // attach the original encoded entity body without changing its encoding.
        let end = record
            .block
            .windows(4)
            .position(|x| x == b"\r\n\r\n")
            .ok_or("Revisit HTTP headers missing")?
            + 4;
        record.block.truncate(end);
        record.block.extend_from_slice(&record.payload);
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
            if matches!(record.kind(), "response" | "resource") && !record.payload.is_empty() {
                payloads
                    .entry((record.digest(), record.mime.clone()))
                    .or_insert((id, input, record));
            }
        }
    }
    let mut used = BTreeMap::new();
    let mut converted = 0;
    for record in &mut archive.records {
        if record.kind() != "response" || record.payload.is_empty() {
            continue;
        }
        if let Some((id, input, target)) = payloads.get(&(record.digest(), record.mime.clone())) {
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
        return Err("No matching response payloads in authorized captures".into());
    }
    write_archive(
        destination,
        archive.records,
        archive.page_meta,
        &archive.report.title,
        used,
        json!({"operation":"cross-capture-payload-dedupe","sourceSha256":archive.report.sha256,"convertedResponses":converted,"standalone":false}),
    )
}
fn to_revisit(record: &mut Record, target: &Record) -> Result<(), String> {
    if target.field("warc-record-id").is_empty() || target.field("warc-date").is_empty() {
        return Err("Dedupe target lacks stable WARC identity".into());
    }
    let end = record
        .block
        .windows(4)
        .position(|x| x == b"\r\n\r\n")
        .ok_or("Response headers missing")?
        + 4;
    record.block.truncate(end);
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
fn dedupe_local(records: &mut [Record]) -> Result<(), String> {
    let mut seen = HashMap::<(String, String), usize>::new();
    for i in 0..records.len() {
        if records[i].kind() != "response" || records[i].payload.is_empty() {
            continue;
        }
        let key = (records[i].digest(), records[i].mime.clone());
        if let Some(&target) = seen.get(&key) {
            let original = records[target].clone();
            to_revisit(&mut records[i], &original)?;
        } else {
            seen.insert(key, i);
        }
    }
    Ok(())
}
fn replace_payload(record: &mut Record, bytes: Vec<u8>) -> Result<(), String> {
    let split = record
        .block
        .windows(4)
        .position(|x| x == b"\r\n\r\n")
        .ok_or("HTTP headers missing")?;
    let header_text =
        std::str::from_utf8(&record.block[..split]).map_err(|_| "NonUTF8 HTTP headers")?;
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
    if original.cost + patch.cost > MAX_BYTES * 2 {
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
    original.records.retain(|r| !successful.contains(r.url()));
    // Include patch dependencies too; limiting to selected HTML alone drops the
    // assets that make a repaired page render. Failed parent targets stay intact.
    for record in patch.records {
        if !targets.contains(&record.url().to_owned()) || successful.contains(record.url()) {
            original.records.push(record);
        }
    }
    if original.records.len() > MAX_ITEMS {
        return Err("Composed repair record limit exceeded".into());
    }
    original.page_meta.retain(|p| !successful.contains(&p.url));
    original.page_meta.extend(
        patch
            .page_meta
            .into_iter()
            .filter(|p| successful.contains(&p.url)),
    );
    write_archive(
        destination,
        original.records,
        original.page_meta,
        &original.report.title,
        BTreeMap::new(),
        json!({"operation":"repair-composition","parentSha256":original.report.sha256,"repairSha256":patch.report.sha256,"replacedTargets":successful,"requestedTargets":targets,"selectionPolicy":"successful repair replaces all parent responses for selected URL; other parent responses retained","mixedCaptureTimes":true}),
    )
}

fn surt(url: &str) -> Result<String, String> {
    let parsed = url::Url::parse(url).map_err(|_| "Cannot index non-URL WARC target")?;
    if parsed.scheme() == "urn" {
        return Ok(url.into());
    }
    let host = parsed
        .host_str()
        .ok_or("Indexed URL missing host")?
        .trim_start_matches("www.");
    let mut host = host.split('.').rev().collect::<Vec<_>>().join(",");
    if let Some(port) = parsed.port() {
        host.push_str(&format!(":{port}"));
    }
    let mut key = format!("{host}){}", parsed.path());
    if let Some(query) = parsed.query() {
        key.push('?');
        key.push_str(query);
    }
    if let Some(fragment) = parsed.fragment() {
        key.push('#');
        key.push_str(fragment);
    }
    Ok(key.to_ascii_lowercase())
}
fn encode_record(record: &Record) -> Result<Vec<u8>, String> {
    let mut headers = record.headers.clone();
    headers.insert("content-length".into(), record.block.len().to_string());
    headers.insert(
        "warc-block-digest".into(),
        format!("sha256:{}", read::hash(&record.block)),
    );
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
    let mut encoder = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
    encoder
        .write_all(raw.as_bytes())
        .map_err(|e| e.to_string())?;
    encoder
        .write_all(&record.block)
        .map_err(|e| e.to_string())?;
    encoder.write_all(b"\r\n\r\n").map_err(|e| e.to_string())?;
    encoder.finish().map_err(|e| e.to_string())
}
fn write_archive(
    destination: &Path,
    records: Vec<Record>,
    pages: Vec<PageRecord>,
    title: &str,
    dependencies: BTreeMap<String, String>,
    provenance: Value,
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
    let mut warc = vec![];
    let mut index = vec![];
    let mut page_rows = BTreeMap::<(String, String), PageRecord>::new();
    for page in pages {
        page_rows.insert((page.url.clone(), page.ts.clone()), page);
    }
    for record in &records {
        let offset = warc.len();
        let bytes = encode_record(record)?;
        if warc.len() + bytes.len() > MAX_BYTES {
            return Err("Output WARC exceeds bounded export size".into());
        }
        warc.extend_from_slice(&bytes);
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
                ("length", json!(bytes.len().to_string())),
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
                    surt(record.url())?
                } else {
                    record.index_key.clone()
                },
                read::timestamp_of(record.field("warc-date"))?,
                serde_json::to_string(&row).map_err(|e| e.to_string())?
            ));
            if matches!(record.mime.as_str(), "text/html" | "application/xhtml+xml")
                && record.resolved
                && (record.field("warc-resource-type") == "document"
                    || page_rows.keys().any(|(url, _)| url == record.url()))
            {
                let (text, title, links) = content::extract(record)?;
                page_rows.insert(
                    (record.url().into(), record.field("warc-date").into()),
                    PageRecord {
                        url: record.url().into(),
                        ts: record.field("warc-date").into(),
                        title,
                        text,
                        resource_urls: links,
                        bytes: bytes.len() as u64,
                        status: record.status,
                    },
                );
            }
        }
    }
    index.sort();
    let index = index.concat().into_bytes();
    let mut page_data = serde_json::to_vec(
        &json!({"format":"json-pages-1.0","id":"pages","title":"Derived archived pages"}),
    )
    .map_err(|e| e.to_string())?;
    page_data.push(b'\n');
    for page in page_rows.into_values() {
        page_data.extend_from_slice(&serde_json::to_vec(&page).map_err(|e| e.to_string())?);
        page_data.push(b'\n');
        if page_data.len() > MAX_BYTES {
            return Err("Page export limit exceeded".into());
        }
    }
    let entries = vec![
        ("archive/derived.warc.gz", warc),
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
    let manifest=serde_json::to_vec(&json!({"profile":"data-package","wacz_version":"1.1.1","title":title,"description":"Derived archive; provenance.json records omissions and source fixity","created":chrono::Utc::now().to_rfc3339(),"resources":manifest_resources,"webArchivesDependencies":dependencies.keys().collect::<Vec<_>>(),"webArchivesDependencyHashes":dependencies})).map_err(|e|e.to_string())?;
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
