use std::time::Duration;

use crate::config::{Settings, SourceConfig};
use crate::db::{self, DocumentRecord};
use crate::extract::{self, ExtractedDocument};
use crate::solr::{SolrClient, SolrDocument};

const SOLR_BATCH_SIZE: usize = 200;
const CHANNEL_DEPTH: usize = 64;
/// Upper bound for a single source's index run. A healthy pass stays far
/// below this; a hung source (dead DB connection, stalled subprocess) must
/// not stall the daemon forever.
const SOURCE_TIMEOUT: Duration = Duration::from_secs(12 * 60 * 60);

pub async fn run_index() -> Result<(), String> {
    let settings = Settings::from_env()?;
    if settings.sources.is_empty() {
        eprintln!("search: no sources configured; nothing to index");
        return Ok(());
    }
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;
    let solr = SolrClient::new(&settings.solr_url, &settings.solr_core);

    for source in &settings.sources {
        let source_id = source.id.clone();
        let result = match tokio::time::timeout(
            SOURCE_TIMEOUT,
            index_source(source, &settings, &mut client, &solr),
        )
        .await
        {
            Ok(Ok(())) => Ok(()),
            Ok(Err(err)) => Err(err),
            Err(_elapsed) => Err(format!(
                "source exceeded the {}h watchdog",
                SOURCE_TIMEOUT.as_secs() / 3600
            )),
        };
        // One broken source must not stop the others from staying fresh.
        if let Err(err) = result {
            eprintln!("search: indexing source '{source_id}' failed: {err}");
        }
    }
    Ok(())
}

struct SourceSyncResult {
    seen: Vec<String>,
}

async fn index_source(
    source: &SourceConfig,
    settings: &Settings,
    client: &mut tokio_postgres::Client,
    solr: &SolrClient,
) -> Result<(), String> {
    eprintln!("search: indexing source '{}'…", source.id);
    db::register_source(client, source).await?;
    eprintln!("search: source '{}': registered", source.id);
    let existing = db::existing_checksums(client, &source.id).await?;
    eprintln!(
        "search: source '{}': {} known docs",
        source.id,
        existing.len()
    );
    let source_id = source.id.clone();
    let (sender, mut receiver) = tokio::sync::mpsc::channel::<ExtractedDocument>(CHANNEL_DEPTH);

    let extraction = {
        let source = source.clone();
        let settings = settings.clone();
        tokio::task::spawn_blocking(move || {
            let mut seen: Vec<String> = Vec::new();
            let mut failure: Option<String> = None;
            let mut emit = |doc: ExtractedDocument| {
                seen.push(doc.external_id.clone());
                if let Err(err) = sender.blocking_send(doc) {
                    failure = Some(format!("indexing channel closed: {err}"));
                }
            };
            let result = extract::run(&source, &settings, &mut emit);
            (seen, result, failure)
        })
    };

    let mut pending: Vec<DocumentRecord> = Vec::new();
    let mut failure: Option<String> = None;
    let mut changed_count: usize = 0;
    let mut processed: usize = 0;
    while let Some(doc) = receiver.recv().await {
        processed += 1;
        if processed.is_multiple_of(200) {
            eprintln!(
                "search: source '{}': pipeline at {} docs",
                source.id, processed
            );
        }
        let record: DocumentRecord = doc.into_record();
        let unchanged = existing
            .get(&record.external_id)
            .map(|checksum| *checksum == record.checksum)
            .unwrap_or(false);
        if unchanged {
            continue;
        }
        changed_count += 1;
        pending.push(record);
        if pending.len() >= SOLR_BATCH_SIZE {
            if let Err(err) = push_batch(solr, client, source, &source_id, &mut pending).await {
                failure = Some(err);
                break;
            }
        }
    }

    // On a mid-extraction failure the producer may still be parked in
    // blocking_send with a full channel; dropping the receiver closes the
    // channel so that task unwinds and the join below can resolve instead
    // of deadlocking the whole index pass.
    drop(receiver);

    let (seen, extract_result, emit_failure) = extraction
        .await
        .map_err(|err| format!("extraction task failed: {err}"))?;
    eprintln!(
        "search: source '{}': extraction finished ({} docs)",
        source.id,
        seen.len()
    );
    let sync = SourceSyncResult { seen };
    if let Some(err) = failure.or(emit_failure).or_else(|| extract_result.err()) {
        return Err(err);
    }
    push_batch(solr, client, source, &source_id, &mut pending).await?;

    let seen_set: std::collections::HashSet<&String> = sync.seen.iter().collect();
    let missing: Vec<String> = existing
        .keys()
        .filter(|external_id| !seen_set.contains(external_id))
        .cloned()
        .collect();
    db::delete_missing(client, &source_id, &missing).await?;
    let missing_ids: Vec<String> = missing
        .iter()
        .map(|external_id| db::full_document_id(&source_id, external_id))
        .collect();
    solr.delete_ids(&missing_ids).await?;
    db::mark_synced(client, &source_id).await?;
    eprintln!(
        "search: source '{}': synced ({} changed, {} missing removed)",
        source_id,
        changed_count,
        missing.len()
    );
    Ok(())
}

/// Pushes a batch to Solr first and persists it to Postgres afterwards, so a
/// failed push leaves nothing behind that a later pass would consider
/// already-indexed (the checksum lives only in Postgres once persisted).
/// If Postgres upserts fail after a successful push, the next pass simply
/// re-pushes the affected documents; Solr writes are idempotent.
async fn push_batch(
    solr: &SolrClient,
    client: &mut tokio_postgres::Client,
    source: &SourceConfig,
    source_id: &str,
    pending: &mut Vec<DocumentRecord>,
) -> Result<(), String> {
    if pending.is_empty() {
        return Ok(());
    }
    let records = std::mem::take(pending);
    let solr_docs: Vec<SolrDocument> = records
        .iter()
        .map(|record| SolrDocument::from_record(source_id, record, source.acl_group.as_deref()))
        .collect();
    flush_solr(solr, solr_docs).await?;
    for record in &records {
        db::upsert_document(client, source, record)
            .await
            .map_err(|err| format!("failed to persist indexed documents: {err}"))?;
    }
    Ok(())
}

async fn flush_solr(solr: &SolrClient, pending: Vec<SolrDocument>) -> Result<(), String> {
    if pending.is_empty() {
        return Ok(());
    }
    eprintln!("search: flushing {} docs to solr", pending.len());
    let result = solr.add_documents(&pending).await;
    if let Err(err) = &result {
        eprintln!("search: solr flush failed: {err}");
    }
    result
}

pub async fn run_reconcile() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;
    let solr = SolrClient::new(&settings.solr_url, &settings.solr_core);

    let active: Vec<String> = settings
        .sources
        .iter()
        .map(|source| source.id.clone())
        .collect();
    let orphans = db::orphan_sources(&mut client, &active).await?;
    for orphan in orphans {
        eprintln!("search: purging removed source '{orphan}'");
        solr.delete_by_source(&orphan).await?;
        db::purge_source(&mut client, &orphan).await?;
    }
    Ok(())
}

/// Long-running indexer loop. Runs as a Type=simple service so that NixOS
/// activations never wait on (or kill) a multi-hour initial extraction.
pub async fn run_index_daemon() -> Result<(), String> {
    let interval_seconds: u64 = std::env::var("SEARCH_INDEX_INTERVAL_SECONDS")
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|seconds| *seconds >= 60)
        .unwrap_or(3600);
    loop {
        if let Err(err) = run_index().await {
            eprintln!("search: index pass failed: {err}");
        }
        tokio::time::sleep(std::time::Duration::from_secs(interval_seconds)).await;
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::config::{parse_sources, Settings};
    use crate::solr::SolrDocument;
    use serde_json::json;

    #[test]
    fn flush_is_noop_for_empty_batch() {
        let result = tokio::runtime::Builder::new_current_thread()
            .build()
            .map_err(|err| err.to_string())
            .and_then(|runtime| {
                runtime.block_on(async {
                    let solr = SolrClient::new("http://127.0.0.1:1", "search");
                    let batch: Vec<SolrDocument> = Vec::new();
                    flush_solr(&solr, batch).await
                })
            });
        // An empty flush never touches the network.
        assert!(result.is_ok());
    }

    #[test]
    fn detects_missing_documents() {
        let seen = ["a".to_string(), "b".to_string()];
        let seen_set: std::collections::HashSet<&String> = seen.iter().collect();
        let existing: HashMap<String, String> = HashMap::from([
            ("a".to_string(), "1".to_string()),
            ("c".to_string(), "2".to_string()),
        ]);
        let missing: Vec<String> = existing
            .keys()
            .filter(|external_id| !seen_set.contains(external_id))
            .cloned()
            .collect();
        assert_eq!(missing, vec!["c".to_string()]);
    }

    /// Exercises the full extractor -> Solr contract: run a real extractor
    /// against on-disk fixtures, turn every emitted document into the exact
    /// Solr JSON payload it would be pushed as, and assert each payload is
    /// well-formed and carries the fields the query path reads back. This is
    /// the pipeline that would otherwise only be exercised against a live
    /// Solr + Postgres, so keeping it hermetic here catches extractor-to-Solr
    /// contract breakage in the normal unit-test run.
    #[test]
    fn paperless_extraction_produces_well_formed_solr_docs() {
        let dir = tempfile::tempdir().expect("tempdir");
        let export = dir.path();
        std::fs::write(
            export.join("manifest.json"),
            r#"[{
                "model": "documents.correspondent", "id": 7, "name": "ACME"
            }, {
                "model": "documents.document", "id": 42,
                "title": "Invoice 42", "content": "total due 100",
                "created": "2024-02-01T10:00:00Z", "modified": "2024-02-02T10:00:00Z",
                "correspondent": 7, "tags": [3]
            }]"#,
        )
        .expect("manifest");

        let settings = Settings {
            database_url: String::new(),
            solr_url: String::new(),
            solr_core: String::new(),
            sources: parse_sources(&format!(
                r#"[{{"id":"paperless","source_type":"paperless","app_base":"https://p.example.org","settings":{{"exportPath":"{}"}}}}]"#,
                export.display()
            ))
            .expect("sources"),
            zimdump: None,
            kiwix_search: None,
            pdftotext: None,
        };

        let mut docs = Vec::new();
        extract::run(&settings.sources[0], &settings, &mut |doc| {
            docs.push(doc);
        })
        .expect("extract");

        assert_eq!(docs.len(), 1, "expected exactly one paperless document");
        let record = docs.into_iter().next().expect("doc").into_record();
        let solr_doc = SolrDocument::from_record("paperless", &record, Some("paperless-users"));
        let payload = solr_doc.to_solr_json();

        assert_eq!(payload["id"], json!("paperless:42"));
        assert_eq!(payload["source"], json!("paperless"));
        assert_eq!(payload["title"], json!("Invoice 42"));
        assert_eq!(payload["body"], json!("total due 100"));
        assert_eq!(payload["content_type"], json!("application/pdf"));
        assert!(payload.get("content_created").is_some());
        assert_eq!(payload["acl_groups"], json!(["paperless-users"]));
        assert_eq!(payload["meta_correspondent_s"], json!("ACME"));
    }
}
