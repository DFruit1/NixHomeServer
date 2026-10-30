use std::collections::HashSet;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::pdf_archive;
use crate::text::{html_to_text, truncate_text};
use crate::timeutil::sha256_hex;

pub struct FreshRssExtractor {
    pub pdftotext: Option<PathBuf>,
}

struct EntryRow {
    guid: String,
    title: String,
    author: Option<String>,
    content: String,
    link: String,
    date: Option<i64>,
    feed_name: Option<String>,
}

fn open_read_only(path: &PathBuf) -> Result<Connection, String> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|err| format!("failed to open FreshRSS database {}: {err}", path.display()))
}

pub(crate) fn user_databases(state_dir: &str) -> Vec<PathBuf> {
    let mut databases = Vec::new();
    let users_dir = PathBuf::from(state_dir).join("users");
    let Ok(entries) = std::fs::read_dir(&users_dir) else {
        return databases;
    };
    for entry in entries.filter_map(|entry| entry.ok()) {
        let path = entry.path().join("db.sqlite");
        if path.is_file() {
            databases.push(path);
        }
    }
    databases.sort();
    databases
}

/// Fingerprints each user's SQLite database and WAL plus completed archived
/// PDFs (path, size, mtime) and source settings. FreshRSS writes new entries
/// into the WAL before checkpointing the database, so both files matter. An
/// unchanged fingerprint means no feed changed and the query/parse pass can be
/// skipped. Returns `None` when no database is present, so the indexer still
/// runs extraction (and its wipe guard) rather than skipping on an empty view.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let state_dir = source.setting_str("stateDir")?;
    let mut databases = user_databases(state_dir);
    if databases.is_empty() {
        return None;
    }
    let journals: Vec<PathBuf> = databases
        .iter()
        .flat_map(|database| {
            [
                database.with_file_name("db.sqlite-wal"),
                database.with_file_name("db.sqlite-journal"),
            ]
        })
        .filter(|path| path.exists())
        .collect();
    databases.extend(journals);
    if let Some(root) = source.setting_str("pdfArchiveRoot") {
        databases.extend(
            pdf_archive::archived_files(Path::new(root))
                .ok()?
                .into_values(),
        );
    }
    super::file_inventory_fingerprint(source, databases)
}

fn load_entries(connection: &Connection) -> Result<Vec<EntryRow>, String> {
    let mut statement = connection
        .prepare(
            "SELECT e.guid, e.title, e.author, e.content, e.link, e.date, f.name
             FROM entry AS e LEFT JOIN feed AS f ON e.id_feed = f.id",
        )
        .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok(EntryRow {
                guid: row.get(0)?,
                title: row.get(1)?,
                author: row.get(2)?,
                content: row.get(3)?,
                link: row.get(4)?,
                date: row.get(5)?,
                feed_name: row.get(6)?,
            })
        })
        .map_err(|err| format!("failed to query FreshRSS entries: {err}"))?;
    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|err| format!("failed to read FreshRSS entries: {err}"))?);
    }
    Ok(entries)
}

impl super::Extractor for FreshRssExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let state_dir = source.require_setting("stateDir")?;
        let app_base = source.app_base.trim_end_matches('/').to_string();
        let archived = source
            .setting_str("pdfArchiveRoot")
            .map(|root| pdf_archive::archived_files(Path::new(root)))
            .transpose()?
            .unwrap_or_default();
        let mut seen_pdfs = HashSet::new();
        let mut pdf_failure = None;

        for database in user_databases(&state_dir) {
            let username = database
                .parent()
                .and_then(|parent| parent.file_name())
                .and_then(|name| name.to_str())
                .unwrap_or("user")
                .to_string();
            let connection = open_read_only(&database)?;
            let entries = load_entries(&connection)?;

            for entry in entries {
                let mut metadata = serde_json::Map::new();
                metadata.insert(
                    "owner".to_string(),
                    serde_json::Value::String(username.clone()),
                );
                if let Some(feed) = entry.feed_name.filter(|feed| !feed.is_empty()) {
                    metadata.insert("feed".to_string(), serde_json::Value::String(feed));
                }
                if let Some(author) = entry.author.filter(|author| !author.is_empty()) {
                    metadata.insert("author".to_string(), serde_json::Value::String(author));
                }
                // Read only files already downloaded by the opt-in archive
                // pass. Indexing never fetches a feed's URLs over the network.
                for url in pdf_archive::pdf_urls_in_entry(&entry.link, &entry.content) {
                    let key = pdf_archive::manifest_key(&url);
                    let Some(path) = archived.get(&key) else {
                        continue;
                    };
                    let external_id = format!("pdf:{}", sha256_hex(&[&username, &key]));
                    if !seen_pdfs.insert(external_id.clone()) {
                        continue;
                    }
                    let text =
                        match super::paperless::extract_pdf_text(path, self.pdftotext.as_deref()) {
                            Ok(text) => text,
                            Err(err) => {
                                eprintln!("search: archived PDF extraction failed: {err}");
                                pdf_failure = Some(err);
                                continue;
                            }
                        };
                    emit(ExtractedDocument {
                        external_id,
                        kind: "document".to_string(),
                        title: if entry.title.is_empty() {
                            url.clone()
                        } else {
                            entry.title.clone()
                        },
                        body_text: truncate_text(&text, super::document::TEXT_LIMIT),
                        content_type: "application/pdf".to_string(),
                        origin_url: url,
                        app_url: app_base.clone(),
                        file_path: path.display().to_string(),
                        size_bytes: std::fs::metadata(path)
                            .map_err(|err| format!("failed to stat archived PDF: {err}"))?
                            .len() as i64,
                        content_created_at: entry.date,
                        content_modified_at: None,
                        metadata: serde_json::Value::Object(metadata.clone()),
                    });
                }
                emit(ExtractedDocument {
                    external_id: sha256_hex(&[&username, &entry.guid]),
                    kind: "feed-entry".to_string(),
                    title: if entry.title.is_empty() {
                        "(untitled entry)".to_string()
                    } else {
                        entry.title.clone()
                    },
                    body_text: html_to_text(&entry.content),
                    content_type: "text/html".to_string(),
                    origin_url: entry.link.clone(),
                    app_url: app_base.clone(),
                    file_path: database.display().to_string(),
                    size_bytes: 0,
                    content_created_at: entry.date,
                    content_modified_at: None,
                    metadata: serde_json::Value::Object(metadata),
                });
            }
        }
        // A transient local PDF failure must not prune its older document or
        // store an unchanged-input fingerprint that prevents a later retry.
        match pdf_failure {
            Some(err) => Err(format!("archived PDF extraction incomplete: {err}")),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_user_databases() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state_dir = dir.path().join("state");
        std::fs::create_dir_all(state_dir.join("users/alice")).expect("mkdir");
        std::fs::create_dir_all(state_dir.join("users/bob")).expect("mkdir");
        std::fs::write(state_dir.join("users/alice/db.sqlite"), b"").expect("write");
        std::fs::write(state_dir.join("users/bob/not-db.txt"), b"").expect("write");

        let found = user_databases(state_dir.to_str().expect("utf8"));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0], state_dir.join("users/alice/db.sqlite"));
    }
}
