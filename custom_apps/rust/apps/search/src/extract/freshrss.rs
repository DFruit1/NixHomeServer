use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags};

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::html_to_text;
use crate::timeutil::sha256_hex;

pub struct FreshRssExtractor;

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

fn user_databases(state_dir: &str) -> Vec<PathBuf> {
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
        Ok(())
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
