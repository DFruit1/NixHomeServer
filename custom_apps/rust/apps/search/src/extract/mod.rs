pub mod browsertrix;
pub mod calibre;
pub mod freshrss;
pub mod kiwix;
pub mod mail;
pub mod media_snapshot;
pub mod paperless;

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::config::{is_federated, Settings, SourceConfig};

/// A single extracted document ready for persistence and indexing.
#[derive(Debug, Clone)]
pub struct ExtractedDocument {
    pub external_id: String,
    pub kind: String,
    pub title: String,
    pub body_text: String,
    pub content_type: String,
    pub origin_url: String,
    pub app_url: String,
    pub file_path: String,
    pub size_bytes: i64,
    pub content_created_at: Option<i64>,
    pub content_modified_at: Option<i64>,
    pub metadata: Value,
}

impl ExtractedDocument {
    pub fn checksum(&self) -> String {
        let metadata = self.metadata.to_string();
        let created = self
            .content_created_at
            .map(|value| value.to_string())
            .unwrap_or_default();
        let modified = self
            .content_modified_at
            .map(|value| value.to_string())
            .unwrap_or_default();
        crate::timeutil::sha256_hex(&[
            &self.kind,
            &self.title,
            &self.body_text,
            &self.content_type,
            &self.origin_url,
            &self.app_url,
            &self.file_path,
            &metadata,
            &created,
            &modified,
        ])
    }

    pub fn into_record(self) -> crate::db::DocumentRecord {
        let checksum = self.checksum();
        crate::db::DocumentRecord {
            external_id: self.external_id,
            kind: self.kind,
            title: self.title,
            body_text: self.body_text,
            content_type: self.content_type,
            origin_url: self.origin_url,
            app_url: self.app_url,
            file_path: self.file_path,
            size_bytes: self.size_bytes,
            checksum,
            content_created_at: self.content_created_at,
            content_modified_at: self.content_modified_at,
            metadata: self.metadata,
        }
    }
}

/// Push-based extraction so large sources never hold the whole index in memory.
pub trait Extractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String>;
}

/// Returns a cheap fingerprint of a source's inputs when the extractor can
/// prove that unchanged inputs imply an unchanged document set. The indexer
/// skips re-extraction when the fingerprint still matches the last successful
/// pass. `None` means "no cheap signal; always extract".
///
/// Only sources whose inputs are genuinely observable belong here: a wrong
/// fingerprint silently serves a stale index, so extractors without a reliable
/// signal must return `None`.
pub fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    match source.source_type.as_str() {
        "kiwix" => kiwix::source_fingerprint(source),
        "mail-archive" => mail::source_fingerprint(source),
        "browsertrix" => browsertrix::source_fingerprint(source),
        "freshrss" => freshrss::source_fingerprint(source),
        "calibre" => calibre::source_fingerprint(source),
        "media-snapshot" => media_snapshot::source_fingerprint(source),
        "paperless" => paperless::source_fingerprint(source),
        _ => None,
    }
}

/// Fingerprints a set of input files together with the source's settings.
///
/// Each file contributes its path, byte length, and mtime; an unchanged set
/// means the source's inputs cannot have changed, so the expensive extraction
/// pass can be skipped. Returns `None` when any file cannot be stat'd, which
/// leaves the indexer to extract and hit its normal error path rather than
/// skipping on a partial view.
pub(crate) fn file_inventory_fingerprint(
    source: &SourceConfig,
    files: impl IntoIterator<Item = PathBuf>,
) -> Option<String> {
    let settings = serde_json::to_string(&source.settings).ok()?;
    let mut parts: Vec<String> = Vec::new();
    for path in files {
        let meta = std::fs::metadata(&path).ok()?;
        let mtime_nanos = meta
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        parts.push(format!(
            "{}\u{1f}{}\u{1f}{mtime_nanos}",
            path.display(),
            meta.len()
        ));
    }
    parts.sort();
    Some(crate::timeutil::sha256_hex(&[
        &source.source_type,
        &settings,
        &parts.join("\n"),
    ]))
}

/// Recursively collects files under `dir` (bounded by `max_depth`) whose path
/// satisfies `matches`. Used to enumerate a source's inputs for fingerprinting.
pub(crate) fn collect_files(
    dir: &Path,
    max_depth: usize,
    matches: &dyn Fn(&Path) -> bool,
) -> Vec<PathBuf> {
    fn walk(
        dir: &Path,
        depth: usize,
        max_depth: usize,
        matches: &dyn Fn(&Path) -> bool,
        out: &mut Vec<PathBuf>,
    ) {
        if depth > max_depth {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, depth + 1, max_depth, matches, out);
            } else if matches(&path) {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, 0, max_depth, matches, &mut out);
    out
}

pub fn run(
    source: &SourceConfig,
    settings: &Settings,
    emit: &mut dyn FnMut(ExtractedDocument),
) -> Result<(), String> {
    // Runtime-federated sources are queried live at search time (see
    // `server::federate_runtime_sources`) and are never copied into the index.
    // Emitting nothing here still lets the indexer prune any documents left by
    // an earlier extraction-based configuration of the same source.
    if is_federated(&source.source_type) {
        return Ok(());
    }
    let extractor: Box<dyn Extractor> = match source.source_type.as_str() {
        "paperless" => Box::new(paperless::PaperlessExtractor {
            pdftotext: settings.pdftotext.clone(),
        }),
        "kiwix" => Box::new(kiwix::KiwixExtractor {
            zimdump: settings
                .zimdump
                .clone()
                .ok_or_else(|| "SEARCH_ZIMDUMP must be set for the kiwix source".to_string())?,
        }),
        "browsertrix" => Box::new(browsertrix::BrowsertrixExtractor),
        "mail-archive" => Box::new(mail::MailExtractor),
        "freshrss" => Box::new(freshrss::FreshRssExtractor),
        "calibre" => Box::new(calibre::CalibreExtractor {
            pdftotext: settings.pdftotext.clone(),
        }),
        "media-snapshot" => Box::new(media_snapshot::MediaSnapshotExtractor),
        other => return Err(format!("no extractor for source type '{other}'")),
    };
    extractor.extract(source, emit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(raw: &str) -> SourceConfig {
        crate::config::parse_sources(raw)
            .expect("sources")
            .remove(0)
    }

    #[test]
    fn file_inventory_fingerprint_tracks_content_and_settings() {
        let dir = tempfile::tempdir().expect("tempdir");
        let file = dir.path().join("input.txt");
        std::fs::write(&file, b"one").expect("write");
        let source = parse(&format!(
            r#"[{{"id":"x","source_type":"paperless","app_base":"https://a","settings":{{"exportPath":"{}"}}}}]"#,
            dir.path().display()
        ));

        let first = file_inventory_fingerprint(&source, [file.clone()]).expect("fingerprint");
        // Recomputing with unchanged inputs is stable, so a pass can be skipped.
        assert_eq!(
            file_inventory_fingerprint(&source, [file.clone()]),
            Some(first.clone())
        );

        // Changing a file's content changes the fingerprint.
        std::fs::write(&file, b"one changed and longer").expect("rewrite");
        let second = file_inventory_fingerprint(&source, [file.clone()]).expect("fingerprint");
        assert_ne!(first, second);

        // A missing file yields no fingerprint so extraction still runs.
        assert_eq!(
            file_inventory_fingerprint(&source, [dir.path().join("missing")]),
            None
        );
    }

    #[test]
    fn dispatches_fingerprints_for_filesystem_sources() {
        let dir = tempfile::tempdir().expect("tempdir");
        let snapshot = dir.path().join("metadata.json");
        std::fs::write(&snapshot, b"{}").expect("write");
        let source = parse(&format!(
            r#"[{{"id":"m","source_type":"media-snapshot","app_base":"https://a","settings":{{"snapshotPath":"{}"}}}}]"#,
            snapshot.display()
        ));
        assert!(source_fingerprint(&source).is_some());

        // A source whose required root setting is absent has no signal.
        let kiwix = parse(r#"[{"id":"k","source_type":"kiwix","app_base":"https://a"}]"#);
        assert_eq!(source_fingerprint(&kiwix), None);
    }
}
