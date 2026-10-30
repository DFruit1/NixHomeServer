//! Risk basis: fixtures must exercise real WARC/index/manifest validation before
//! testing interruption custody, immutable derivatives and owner isolation.
#![allow(dead_code)]
use sha2::{Digest, Sha256};
use std::{io::Write, path::Path};
pub fn fixture(path: &Path, title: &str) {
    let payload=format!("<!doctype html><html><head><title>{title}</title></head><body><h1>{title}</h1><p>Durable archived content</p><script>fetch('https://leak.invalid/')</script></body></html>");
    let block = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{payload}",
        payload.len()
    );
    let raw=format!("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: https://example.com/\r\nWARC-Date: 2026-01-02T03:04:05Z\r\nWARC-Record-ID: <urn:uuid:fixture>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {}\r\n\r\n{block}\r\n\r\n",block.len());
    let mut gz = flate2::write::GzEncoder::new(vec![], flate2::Compression::default());
    gz.write_all(raw.as_bytes()).unwrap();
    let warc = gz.finish().unwrap();
    let index=format!("com,example)/ 20260102030405 {}\n",serde_json::json!({"url":"https://example.com/","filename":"capture.warc.gz","offset":0,"length":warc.len(),"status":"200","mime":"text/html"})).into_bytes();
    let pages = format!(
        "{{\"format\":\"json-pages-1.0\"}}\n{}\n",
        serde_json::json!({"url":"https://example.com/","title":title,"ts":"2026-01-02T03:04:05Z"})
    )
    .into_bytes();
    let mut entries = vec![
        ("archive/capture.warc.gz", warc),
        ("indexes/index.cdxj", index),
        ("pages/pages.jsonl", pages),
    ];
    let resources=entries.iter().map(|(name,bytes)|serde_json::json!({"path":name,"bytes":bytes.len(),"hash":format!("sha256:{:x}",Sha256::digest(bytes))})).collect::<Vec<_>>();
    entries.push(("datapackage.json",serde_json::to_vec(&serde_json::json!({"profile":"data-package","wacz_version":"1.1.1","title":title,"resources":resources})).unwrap()));
    let mut zip = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
    for (name, bytes) in entries {
        zip.start_file(
            name,
            zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored),
        )
        .unwrap();
        zip.write_all(&bytes).unwrap();
    }
    zip.finish().unwrap();
}
pub fn request() -> browsertrix_downloader::model::CreateJobRequest {
    browsertrix_downloader::model::CreateJobRequest {
        url: "https://example.com/".into(),
        scope: browsertrix_downloader::model::CrawlScope::Page,
        page_limit: 5,
        time_limit_minutes: 2,
        collection: None,
        options: Default::default(),
    }
}
pub fn config(root: &Path) -> browsertrix_downloader::config::AppConfig {
    let mut config = browsertrix_downloader::config::AppConfig::for_test(root);
    config.archive_uid = unsafe { libc::geteuid() };
    config.archive_gid = unsafe { libc::getegid() };
    config.private_archive_gid = unsafe { libc::getegid() };
    config
}
pub fn fake_podman(root: &Path, fixture: &Path, partial: bool) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let script = root.join("fake-podman");
    let scripttext = format!(
        r#"#!/bin/sh
set -eu
if [ "${{1:-}}" = image ]; then exit 0; fi
volume=''
collection=''
while [ "$#" -gt 0 ]; do
 case "$1" in
 -v) case "$2" in *:/crawls) volume="$2";; esac; shift 2;;
 --collection) collection="$2"; shift 2;;
 *) shift;;
 esac
done
crawl_root="${{volume%:/crawls}}"
mkdir -p "$crawl_root/collections/$collection/crawls"
cp '{}' "$crawl_root/collections/$collection/$collection.wacz"
printf 'state: {{finished: false}}\n' > "$crawl_root/collections/$collection/crawls/fixture.yaml"
printf '%s\n' '{{"stats":{{"done":1,"queued":{},"failed":0}}}}'
exit {}
"#,
        fixture.display(),
        if partial { 1 } else { 0 },
        if partial { 14 } else { 0 }
    );
    std::fs::write(&script, scripttext).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}
pub fn tar_gz(path: &Path, name: &str, kind: u8) {
    let mut header = [0u8; 512];
    header[..name.len()].copy_from_slice(name.as_bytes());
    header[100..108].copy_from_slice(b"0000600\0");
    header[108..116].copy_from_slice(b"0000000\0");
    header[116..124].copy_from_slice(b"0000000\0");
    header[124..136].copy_from_slice(b"00000000000\0");
    header[136..148].copy_from_slice(b"00000000000\0");
    header[148..156].fill(b' ');
    header[156] = kind;
    header[257..263].copy_from_slice(b"ustar\0");
    let checksum: u64 = header.iter().map(|b| u64::from(*b)).sum();
    header[148..156].copy_from_slice(format!("{checksum:06o}\0 ").as_bytes());
    let mut encoder = flate2::write::GzEncoder::new(
        std::fs::File::create(path).unwrap(),
        flate2::Compression::default(),
    );
    encoder.write_all(&header).unwrap();
    encoder.write_all(&[0u8; 1024]).unwrap();
    encoder.finish().unwrap();
}
