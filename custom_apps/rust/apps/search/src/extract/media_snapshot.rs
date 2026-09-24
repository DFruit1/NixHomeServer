use std::path::PathBuf;

use serde_json::{Map, Value};

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::timeutil::{parse_date, sha256_hex};

/// Upper bound on a single document body. Media descriptions are already
/// bounded by the exporting services, but a malformed snapshot must never
/// inflate the index or a query's memory use.
const BODY_LIMIT: usize = 2_000_000;

/// Indexes a Media Manager metadata snapshot.
///
/// Media Manager already exports bounded, read-only JSON snapshots of the
/// Jellyfin, Audiobookshelf, and Kavita libraries (titles, descriptions,
/// authors, narrators, genres, tags, …). Reading those snapshots lets Search
/// pick up catalogue metadata from every media application without needing
/// per-application credentials, APIs, or direct database access.
///
/// All three snapshots share the same envelope:
/// `{ "schemaVersion": 1, "observedAt": <epoch>, "entries": [ … ] }`.
pub struct MediaSnapshotExtractor;

/// Reads one scalar metadata field as a trimmed, non-empty string.
fn string_field(entry: &Value, key: &str) -> Option<String> {
    entry
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// Reads an integer metadata field, tolerating numeric strings.
fn number_field(entry: &Value, key: &str) -> Option<i64> {
    match entry.get(key) {
        Some(Value::Number(number)) => number.as_i64(),
        Some(Value::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Reads a list field whose items are strings or `{ "name": … }` objects,
/// deduplicated and trimmed. Handles the shape differences between the
/// Jellyfin (`writers`, `genres`), Audiobookshelf (`authors`, `narrators`),
/// and Kavita (`authors`, `writers`, `genres`, `tags`) exports.
fn string_list(entry: &Value, key: &str) -> Vec<String> {
    let Some(items) = entry.get(key).and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut values: Vec<String> = Vec::new();
    for item in items {
        let value = match item {
            Value::String(text) => text.trim().to_string(),
            Value::Object(map) => map
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .unwrap_or_default()
                .to_string(),
            _ => continue,
        };
        if !value.is_empty() && !values.contains(&value) {
            values.push(value);
        }
    }
    values
}

fn scalar_metadata(map: &mut Map<String, Value>, key: &str, value: Option<String>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::String(value));
    }
}

fn list_metadata(map: &mut Map<String, Value>, key: &str, values: Vec<String>) {
    if !values.is_empty() {
        map.insert(key.to_string(), Value::from(values));
    }
}

/// Composes the human-readable title, folding Jellyfin episode coordinates
/// into the title so search results read "Series S01E02 — Episode".
fn display_title(entry: &Value) -> String {
    let media_type = string_field(entry, "mediaType");
    let title = string_field(entry, "title")
        .or_else(|| string_field(entry, "episodeTitle"))
        .unwrap_or_else(|| "(untitled)".to_string());
    let series = string_field(entry, "series");
    if media_type.as_deref() == Some("episode") {
        let coordinates = match (
            number_field(entry, "season"),
            number_field(entry, "episode"),
        ) {
            (Some(season), Some(episode)) => Some(format!("S{season:02}E{episode:02}")),
            _ => None,
        };
        return match (series, coordinates) {
            (Some(series), Some(coordinates)) => format!("{series} {coordinates} — {title}"),
            (Some(series), None) => format!("{series} — {title}"),
            (None, _) => title,
        };
    }
    title
}

/// Builds the searchable body from every descriptive field in the snapshot, so
/// a query for an author, narrator, series, genre, or publisher matches even
/// when the description itself does not mention it.
fn build_body(entry: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(series) = string_field(entry, "series") {
        parts.push(match string_field(entry, "volumeNumber") {
            Some(volume) => format!("{series} {volume}"),
            None => series,
        });
    }
    for key in ["authors", "narrators", "writers", "genres", "tags"] {
        parts.push(string_list(entry, key).join(", "));
    }
    parts.push(string_field(entry, "publisher").unwrap_or_default());
    parts.push(
        number_field(entry, "year")
            .map(|year| year.to_string())
            .unwrap_or_default(),
    );
    parts.push(string_field(entry, "language").unwrap_or_default());
    parts.push(string_field(entry, "officialRating").unwrap_or_default());
    parts.push(string_field(entry, "publicationStatus").unwrap_or_default());
    parts.push(string_field(entry, "subtitle").unwrap_or_default());
    parts.push(string_field(entry, "description").unwrap_or_default());
    let mut body: String = parts
        .into_iter()
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if body.len() > BODY_LIMIT {
        let mut boundary = BODY_LIMIT;
        while boundary > 0 && !body.is_char_boundary(boundary) {
            boundary -= 1;
        }
        body.truncate(boundary);
    }
    body
}

/// Derives the record timestamp: an explicit publication/premiere date wins,
/// otherwise the publication year is treated as January 1 of that year.
fn created_at(entry: &Value) -> Option<i64> {
    for key in ["publishedDate", "premiereDate", "releaseDate"] {
        if let Some(raw) = string_field(entry, key) {
            if let Some(timestamp) = parse_date(&raw) {
                return Some(timestamp);
            }
        }
    }
    number_field(entry, "year").and_then(|year| parse_date(&format!("{year:04}-01-01")))
}

/// Owner facet value: the per-user root owner, or the shared sentinel when the
/// snapshot marks the entry as shared (`ownerUsername` is null).
fn owner_of(entry: &Value) -> String {
    string_field(entry, "ownerUsername").unwrap_or_else(|| "shared".to_string())
}

/// Stable external id for the entry, preferring the origin application's item
/// id and falling back to the root-relative path.
fn external_id(entry: &Value, title: &str) -> String {
    if let Some(item_id) = string_field(entry, "itemId") {
        return item_id;
    }
    let root = string_field(entry, "rootId").unwrap_or_default();
    let relative = string_field(entry, "relativePath").unwrap_or_default();
    sha256_hex(&[&root, &relative, title])
}

impl MediaSnapshotExtractor {
    fn snapshot_path(source: &SourceConfig) -> Result<PathBuf, String> {
        source
            .setting_str("snapshotPath")
            .map(PathBuf::from)
            .ok_or_else(|| {
                "media-snapshot source is missing required setting 'snapshotPath'".to_string()
            })
    }

    fn load_entries(path: &PathBuf) -> Result<Vec<Value>, String> {
        // A missing or unreadable snapshot is an error, not an empty result:
        // returning an empty set would make the indexer prune every document
        // from this source whenever an export is briefly unavailable.
        let raw = std::fs::read_to_string(path)
            .map_err(|err| format!("failed to read media snapshot {}: {err}", path.display()))?;
        let parsed: Value = serde_json::from_str(&raw)
            .map_err(|err| format!("invalid media snapshot {}: {err}", path.display()))?;
        let entries = parsed
            .get("entries")
            .and_then(Value::as_array)
            .or_else(|| parsed.as_array())
            .ok_or_else(|| {
                format!(
                    "media snapshot {} must contain an entries array",
                    path.display()
                )
            })?;
        Ok(entries.clone())
    }
}

/// Fingerprints the exported `metadata.json` snapshot (path, size, mtime) plus
/// the source settings. Media Manager rewrites the snapshot whenever a library
/// changes, so an unchanged fingerprint means the parse pass can be skipped.
/// Returns `None` when the snapshot is absent, so the indexer still runs
/// extraction and reports the missing-snapshot error.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let path = source.setting_str("snapshotPath").map(PathBuf::from)?;
    if !path.is_file() {
        return None;
    }
    super::file_inventory_fingerprint(source, [path])
}

impl super::Extractor for MediaSnapshotExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let path = Self::snapshot_path(source)?;
        let entries = Self::load_entries(&path)?;
        let app_base = source.app_base.trim_end_matches('/').to_string();
        let fallback_type = source
            .setting_str("contentType")
            .unwrap_or("application/octet-stream")
            .to_string();

        for entry in &entries {
            let title = display_title(entry);
            let media_type = string_field(entry, "mediaType");
            let owner = owner_of(entry);
            let relative_path = string_field(entry, "relativePath").unwrap_or_default();

            let mut metadata = Map::new();
            metadata.insert("owner".to_string(), Value::String(owner));
            scalar_metadata(&mut metadata, "series", string_field(entry, "series"));
            list_metadata(&mut metadata, "authors", string_list(entry, "authors"));
            list_metadata(&mut metadata, "narrators", string_list(entry, "narrators"));
            list_metadata(&mut metadata, "genres", string_list(entry, "genres"));
            list_metadata(&mut metadata, "tags", string_list(entry, "tags"));
            scalar_metadata(
                &mut metadata,
                "year",
                number_field(entry, "year").map(|y| y.to_string()),
            );
            scalar_metadata(&mut metadata, "publisher", string_field(entry, "publisher"));
            scalar_metadata(&mut metadata, "language", string_field(entry, "language"));

            emit(ExtractedDocument {
                external_id: external_id(entry, &title),
                kind: media_type.clone().unwrap_or_else(|| "media".to_string()),
                title,
                body_text: build_body(entry),
                content_type: media_type.unwrap_or_else(|| fallback_type.clone()),
                origin_url: String::new(),
                app_url: app_base.clone(),
                file_path: relative_path,
                size_bytes: 0,
                content_created_at: created_at(entry),
                content_modified_at: None,
                metadata: Value::Object(metadata),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse_sources;
    use crate::extract::Extractor;

    fn source(settings: &str) -> SourceConfig {
        parse_sources(&format!(
            r#"[{{"id":"media","source_type":"media-snapshot","app_base":"https://media.example.org","settings":{settings}}}]"#
        ))
        .expect("sources parse")
        .remove(0)
    }

    fn run_with(source: &SourceConfig) -> Result<Vec<ExtractedDocument>, String> {
        let mut docs = Vec::new();
        MediaSnapshotExtractor.extract(source, &mut |doc| docs.push(doc))?;
        Ok(docs)
    }

    fn write_snapshot(entries: &str) -> (tempfile::TempDir, SourceConfig) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("metadata.json");
        std::fs::write(
            &path,
            format!(r#"{{"schemaVersion":1,"observedAt":1700000000,"entries":{entries}}}"#),
        )
        .expect("write snapshot");
        let source = source(&format!(r#"{{"snapshotPath":"{}"}}"#, path.display()));
        (dir, source)
    }

    #[test]
    fn indexes_audiobook_metadata_into_a_searchable_body() {
        let (_dir, source) = write_snapshot(
            r#"[{
                "rootId":"shared-audiobooks","ownerUsername":null,"relativePath":"Sanderson/Mistborn/book1",
                "itemId":"abs-1","mediaType":"audiobook","title":"The Final Empire",
                "authors":[{"name":"Brandon Sanderson"}],"narrators":[{"name":"Michael Kramer"}],
                "series":[{"name":"Mistborn","sequence":"1"}],"seriesName":"Mistborn",
                "genres":[{"name":"Fantasy"}],"tags":["epic"],
                "publisher":"Macmillan","language":"en","year":2006,
                "description":"A thief crew plans an impossible heist."
            }]"#,
        );
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs.len(), 1);
        let doc = &docs[0];
        assert_eq!(doc.external_id, "abs-1");
        assert_eq!(doc.title, "The Final Empire");
        assert_eq!(doc.content_type, "audiobook");
        assert_eq!(doc.file_path, "Sanderson/Mistborn/book1");
        assert_eq!(doc.metadata["owner"], Value::String("shared".to_string()));
        assert_eq!(
            doc.metadata["authors"],
            Value::from(vec!["Brandon Sanderson"])
        );
        assert!(doc.body_text.contains("Brandon Sanderson"));
        assert!(doc.body_text.contains("Fantasy"));
        assert!(doc.body_text.contains("impossible heist"));
        assert_eq!(doc.content_created_at, Some(1_136_073_600));
    }

    #[test]
    fn composes_episode_titles_and_personal_owners() {
        let (_dir, source) = write_snapshot(
            r#"[{
                "rootId":"personal-videos","ownerUsername":"dsaw","relativePath":"_Shows/Dune/S01E02.mkv",
                "itemId":"jf-2","mediaType":"episode","title":"The Gathering Storm",
                "series":"Dune","season":1,"episode":2,"premiereDate":"2024-02-01",
                "description":"Paul learns the truth."
            }]"#,
        );
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs[0].title, "Dune S01E02 — The Gathering Storm");
        assert_eq!(docs[0].metadata["owner"], Value::String("dsaw".to_string()));
        assert_eq!(docs[0].content_created_at, Some(1_706_745_600));
    }

    #[test]
    fn applies_fallback_content_type_and_item_id() {
        let (_dir, source) = {
            let dir = tempfile::tempdir().expect("tempdir");
            let path = dir.path().join("metadata.json");
            std::fs::write(
                &path,
                r#"{"entries":[{"rootId":"shared-books","ownerUsername":null,"relativePath":"Manga/One Piece/vol1","title":"One Piece","description":"Pirates."}]}"#,
            )
            .expect("write");
            let source = source(&format!(
                r#"{{"snapshotPath":"{}","contentType":"book"}}"#,
                path.display()
            ));
            (dir, source)
        };
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs[0].content_type, "book");
        assert!(!docs[0].external_id.is_empty());
        assert_eq!(docs[0].kind, "media");
    }

    #[test]
    fn missing_snapshot_is_an_error_so_documents_are_not_pruned() {
        let source = source(r#"{"snapshotPath":"/nonexistent/media/metadata.json"}"#);
        assert!(run_with(&source).is_err());
    }

    #[test]
    fn malformed_snapshot_without_entries_is_an_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("metadata.json");
        std::fs::write(&path, r#"{"schemaVersion":1}"#).expect("write");
        let source = source(&format!(r#"{{"snapshotPath":"{}"}}"#, path.display()));
        assert!(run_with(&source).is_err());
    }

    #[test]
    fn empty_snapshot_emits_nothing() {
        let (_dir, source) = write_snapshot("[]");
        assert!(run_with(&source).expect("extract").is_empty());
    }

    #[test]
    fn missing_snapshot_path_setting_is_rejected() {
        let source = source("{}");
        assert!(run_with(&source).is_err());
    }
}
