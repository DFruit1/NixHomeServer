use std::collections::HashMap;
use std::time::Duration;

use serde_json::Value;
use tokio_postgres::{Client, NoTls, Statement};

use crate::config::SourceConfig;
use crate::timeutil::now_epoch;

/// Bound on how many external ids one pruning statement may carry.
const DB_DELETE_CHUNK: usize = 5000;

/// The full persistence record for one indexed document.
#[derive(Debug, Clone)]
pub struct DocumentRecord {
    pub external_id: String,
    pub kind: String,
    pub title: String,
    pub body_text: String,
    pub content_type: String,
    pub origin_url: String,
    pub app_url: String,
    pub file_path: String,
    pub size_bytes: i64,
    pub checksum: String,
    pub content_created_at: Option<i64>,
    pub content_modified_at: Option<i64>,
    pub metadata: Value,
}

pub async fn connect(database_url: &str) -> Result<Client, String> {
    // tokio_postgres::connect returns (Client, Connection); the connection
    // task must be driven on the current runtime, which spawn achieves.
    //
    // Keepalives and a statement timeout keep a silently half-opened
    // connection (e.g. after a NixOS activation churns the network) from
    // deadlocking the indexer forever.
    let mut pg_config: tokio_postgres::Config = database_url
        .parse()
        .map_err(|err| format!("invalid database URL: {err}"))?;
    pg_config.tcp_user_timeout(Duration::from_secs(60));
    pg_config.keepalives(true);
    pg_config.keepalives_idle(Duration::from_secs(30));
    let (client, connection) = pg_config.connect(NoTls).await.map_err(|err| {
        format!("failed to connect to the search database ({database_url}): {err}")
    })?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("search database connection error: {err}");
        }
    });
    Ok(client)
}

pub async fn migrate(client: &mut Client) -> Result<(), String> {
    client
        .batch_execute(
            "
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                source_type TEXT NOT NULL,
                -- Legacy source-level ACL column; unused since Search became
                -- admin-only and every admin searches every source.
                acl_group TEXT,
                app_base TEXT NOT NULL DEFAULT '',
                settings JSONB NOT NULL DEFAULT '{}',
                last_synced_at BIGINT
            );
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                external_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body_text TEXT NOT NULL DEFAULT '',
                content_type TEXT NOT NULL DEFAULT '',
                origin_url TEXT NOT NULL DEFAULT '',
                app_url TEXT NOT NULL DEFAULT '',
                file_path TEXT NOT NULL DEFAULT '',
                size_bytes BIGINT NOT NULL DEFAULT 0,
                checksum TEXT NOT NULL DEFAULT '',
                content_created_at BIGINT,
                content_modified_at BIGINT,
                metadata JSONB NOT NULL DEFAULT '{}',
                indexed_at BIGINT NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS documents_source_external
                ON documents (source_id, external_id);
            ",
        )
        .await
        .map_err(|err| format!("failed to apply search schema: {err}"))?;
    // Fingerprint of the source's inputs from the last fully successful pass.
    // NULL means "no cheap change signal"; the indexer then always extracts.
    // Added separately so existing databases pick the column up on migration.
    client
        .batch_execute("ALTER TABLE sources ADD COLUMN IF NOT EXISTS source_fingerprint TEXT")
        .await
        .map_err(|err| format!("failed to add source_fingerprint column: {err}"))
}

pub async fn register_source(client: &mut Client, source: &SourceConfig) -> Result<(), String> {
    let settings = serde_json::to_value(&source.settings)
        .map_err(|err| format!("failed to serialize source settings: {err}"))?;
    client
        .execute(
            "
            INSERT INTO sources (id, display_name, source_type, app_base, settings)
            VALUES ($1, $2, $3, $4, $5::jsonb)
            ON CONFLICT (id) DO UPDATE SET
                display_name = EXCLUDED.display_name,
                source_type = EXCLUDED.source_type,
                app_base = EXCLUDED.app_base,
                settings = EXCLUDED.settings
            ",
            &[
                &source.id,
                &source.display_name,
                &source.source_type,
                &source.app_base,
                &settings,
            ],
        )
        .await
        .map_err(|err| format!("failed to register source '{}': {err}", source.id))?;
    Ok(())
}

/// Records a fully successful pass: the sync time and (when the extractor
/// provides one) the input fingerprint that lets a later pass skip
/// re-extraction. Only called after every document was persisted and pruned.
pub async fn mark_synced(
    client: &mut Client,
    source_id: &str,
    fingerprint: Option<&str>,
) -> Result<(), String> {
    client
        .execute(
            "UPDATE sources SET last_synced_at = $2, source_fingerprint = $3 WHERE id = $1",
            &[&source_id, &now_epoch(), &fingerprint],
        )
        .await
        .map_err(|err| format!("failed to update sync time for source '{source_id}': {err}"))?;
    Ok(())
}

/// Returns the input fingerprint recorded by the last successful pass, if any.
pub async fn source_fingerprint(
    client: &Client,
    source_id: &str,
) -> Result<Option<String>, String> {
    let rows = client
        .query(
            "SELECT source_fingerprint FROM sources WHERE id = $1",
            &[&source_id],
        )
        .await
        .map_err(|err| format!("failed to read source fingerprint for '{source_id}': {err}"))?;
    Ok(rows.into_iter().next().and_then(|row| row.get(0)))
}

/// Counts the documents stored for a source. Used to detect drift against the
/// derived Solr index.
pub async fn count_documents(client: &Client, source_id: &str) -> Result<i64, String> {
    let row = client
        .query_one(
            "SELECT COUNT(*) FROM documents WHERE source_id = $1",
            &[&source_id],
        )
        .await
        .map_err(|err| format!("failed to count documents for '{source_id}': {err}"))?;
    Ok(row.get(0))
}

/// Loads existing document checksums for a source, keyed by external id.
pub async fn existing_checksums(
    client: &mut Client,
    source_id: &str,
) -> Result<HashMap<String, String>, String> {
    let rows = client
        .query(
            "SELECT external_id, checksum FROM documents WHERE source_id = $1",
            &[&source_id],
        )
        .await
        .map_err(|err| format!("failed to read existing documents for '{source_id}': {err}"))?;
    Ok(rows
        .into_iter()
        .map(|row| (row.get::<_, String>(0), row.get::<_, String>(1)))
        .collect())
}

/// Loads one keyset-paginated batch of a source's documents, ordered by the
/// full document id. Pass the previous batch's last id as `after_id` to fetch
/// the next page. Returning each row's id lets a full Solr rebuild stream a
/// source without holding every document (bodies included) in memory at once.
pub async fn documents_batch(
    client: &Client,
    source_id: &str,
    after_id: Option<&str>,
    limit: i64,
) -> Result<Vec<(String, DocumentRecord)>, String> {
    const COLUMNS: &str = "id, external_id, kind, title, body_text, content_type, \
        origin_url, app_url, file_path, size_bytes, checksum, content_created_at, \
        content_modified_at, metadata";
    let rows = match after_id {
        Some(after) => {
            client
                .query(
                    &format!(
                        "SELECT {COLUMNS} FROM documents \
                         WHERE source_id = $1 AND id > $2 ORDER BY id LIMIT $3"
                    ),
                    &[&source_id, &after, &limit],
                )
                .await
        }
        None => {
            client
                .query(
                    &format!(
                        "SELECT {COLUMNS} FROM documents \
                         WHERE source_id = $1 ORDER BY id LIMIT $2"
                    ),
                    &[&source_id, &limit],
                )
                .await
        }
    }
    .map_err(|err| format!("failed to read documents for '{source_id}': {err}"))?;
    Ok(rows.into_iter().map(row_to_document).collect())
}

fn row_to_document(row: tokio_postgres::Row) -> (String, DocumentRecord) {
    (
        row.get(0),
        DocumentRecord {
            external_id: row.get(1),
            kind: row.get(2),
            title: row.get(3),
            body_text: row.get(4),
            content_type: row.get(5),
            origin_url: row.get(6),
            app_url: row.get(7),
            file_path: row.get(8),
            size_bytes: row.get(9),
            checksum: row.get(10),
            content_created_at: row.get(11),
            content_modified_at: row.get(12),
            metadata: row.get(13),
        },
    )
}

/// Body text and metadata for one already-indexed document. Loaded after a Solr
/// query so the authoritative body copy is only ever read from Postgres; Solr
/// holds the inverted index, not a second stored copy of the text.
#[derive(Debug, Clone)]
pub struct DocumentEnrichment {
    pub body_text: String,
    pub metadata: Value,
}

/// Loads body text and metadata for the given full document ids in one query.
/// Ids that no longer exist (deleted between the Solr query and this read) are
/// simply absent from the result rather than an error.
pub async fn enrich_documents(
    client: &Client,
    ids: &[String],
) -> Result<HashMap<String, DocumentEnrichment>, String> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let ids = ids.to_vec();
    let rows = client
        .query(
            "SELECT id, body_text, metadata FROM documents WHERE id = ANY($1)",
            &[&ids],
        )
        .await
        .map_err(|err| format!("failed to load result bodies from Postgres: {err}"))?;
    Ok(rows
        .into_iter()
        .map(|row| {
            (
                row.get::<_, String>(0),
                DocumentEnrichment {
                    body_text: row.get(1),
                    metadata: row.get(2),
                },
            )
        })
        .collect())
}

/// Postgres TEXT and jsonb reject NUL bytes; source data (emails, HTML,
/// titles) can contain them. Strip them at the database boundary so no
/// extractor's output can fail an insert.
fn strip_nul_str(value: &str) -> String {
    value.replace('\0', "")
}

fn strip_nul_json(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::String(text) => serde_json::Value::String(strip_nul_str(&text)),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.into_iter().map(strip_nul_json).collect())
        }
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.into_iter()
                .map(|(key, value)| (strip_nul_str(&key), strip_nul_json(value)))
                .collect(),
        ),
        other => other,
    }
}

/// Prepares the document upsert once so a whole source can reuse the parsed
/// statement instead of re-parsing it for every document.
pub async fn prepare_upsert(client: &Client) -> Result<Statement, String> {
    client
        .prepare(
            "
            INSERT INTO documents (
                id, source_id, external_id, kind, title, body_text, content_type,
                origin_url, app_url, file_path, size_bytes, checksum,
                content_created_at, content_modified_at, metadata, indexed_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::jsonb, $16
            )
            ON CONFLICT (id) DO UPDATE SET
                kind = EXCLUDED.kind,
                title = EXCLUDED.title,
                body_text = EXCLUDED.body_text,
                content_type = EXCLUDED.content_type,
                origin_url = EXCLUDED.origin_url,
                app_url = EXCLUDED.app_url,
                file_path = EXCLUDED.file_path,
                size_bytes = EXCLUDED.size_bytes,
                checksum = EXCLUDED.checksum,
                content_created_at = EXCLUDED.content_created_at,
                content_modified_at = EXCLUDED.content_modified_at,
                metadata = EXCLUDED.metadata,
                indexed_at = EXCLUDED.indexed_at
            ",
        )
        .await
        .map_err(|err| format!("failed to prepare document upsert: {err}"))
}

pub async fn upsert_document(
    client: &Client,
    statement: &Statement,
    source: &SourceConfig,
    doc: &DocumentRecord,
) -> Result<(), String> {
    let id = full_document_id(&source.id, &doc.external_id);
    let metadata = strip_nul_json(
        serde_json::to_value(&doc.metadata)
            .map_err(|err| format!("failed to serialize document metadata: {err}"))?,
    );
    client
        .execute(
            statement,
            &[
                &id,
                &source.id,
                &doc.external_id,
                &strip_nul_str(&doc.kind),
                &strip_nul_str(&doc.title),
                &strip_nul_str(&doc.body_text),
                &strip_nul_str(&doc.content_type),
                &strip_nul_str(&doc.origin_url),
                &strip_nul_str(&doc.app_url),
                &strip_nul_str(&doc.file_path),
                &doc.size_bytes,
                &doc.checksum,
                &doc.content_created_at,
                &doc.content_modified_at,
                &metadata,
                &now_epoch(),
            ],
        )
        .await
        .map_err(|err| format!("failed to upsert document '{id}': {err}"))?;
    Ok(())
}

/// Removes documents whose external ids are no longer produced by the source.
/// Ids are deleted in bounded chunks so a source that disappears wholesale does
/// not build one unbounded array parameter.
pub async fn delete_missing(
    client: &mut Client,
    source_id: &str,
    external_ids: &[String],
) -> Result<(), String> {
    for chunk in external_ids.chunks(DB_DELETE_CHUNK) {
        client
            .execute(
                "DELETE FROM documents WHERE source_id = $1 AND external_id = ANY($2)",
                &[&source_id, &chunk],
            )
            .await
            .map_err(|err| format!("failed to prune documents for source '{source_id}': {err}"))?;
    }
    Ok(())
}

/// Returns source ids present in the database but absent from the configured set.
pub async fn orphan_sources(
    client: &mut Client,
    active_ids: &[String],
) -> Result<Vec<String>, String> {
    let rows = client
        .query("SELECT id FROM sources", &[])
        .await
        .map_err(|err| format!("failed to list indexed sources: {err}"))?;
    Ok(rows
        .into_iter()
        .map(|row| row.get::<_, String>(0))
        .filter(|id| !active_ids.contains(id))
        .collect())
}

/// Deletes every trace of a source: its documents, its registry row.
pub async fn purge_source(client: &mut Client, source_id: &str) -> Result<(), String> {
    client
        .execute("DELETE FROM documents WHERE source_id = $1", &[&source_id])
        .await
        .map_err(|err| format!("failed to delete documents for source '{source_id}': {err}"))?;
    client
        .execute("DELETE FROM sources WHERE id = $1", &[&source_id])
        .await
        .map_err(|err| format!("failed to delete source '{source_id}': {err}"))?;
    Ok(())
}

#[derive(Debug)]
pub struct UiSource {
    pub id: String,
    pub display_name: String,
}

pub async fn list_sources(client: &Client) -> Result<Vec<UiSource>, String> {
    let rows = client
        .query(
            "SELECT id, display_name FROM sources ORDER BY display_name",
            &[],
        )
        .await
        .map_err(|err| format!("failed to list sources: {err}"))?;
    Ok(rows
        .into_iter()
        .map(|row| UiSource {
            id: row.get(0),
            display_name: row.get(1),
        })
        .collect())
}

pub fn full_document_id(source_id: &str, external_id: &str) -> String {
    format!("{source_id}:{external_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_full_document_ids() {
        assert_eq!(
            full_document_id("paperless", "42"),
            "paperless:42".to_string()
        );
    }

    #[test]
    fn strips_nul_bytes_from_text_and_json() {
        assert_eq!(strip_nul_str("a\0b\0c"), "abc");
        let cleaned = strip_nul_json(serde_json::json!({
            "body": "line\0break",
            "nested": { "list": ["x\0", 3, null] }
        }));
        assert_eq!(
            cleaned,
            serde_json::json!({
                "body": "linebreak",
                "nested": { "list": ["x", 3, null] }
            })
        );
    }
}
