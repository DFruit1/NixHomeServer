use std::collections::HashSet;
use std::time::Duration;

use crate::config::{is_federated, Settings, SourceConfig};
use crate::db::{self, DocumentRecord};
use crate::extract::{self, ExtractedDocument};
use crate::solr::{SolrClient, SolrDocument};

const SOLR_BATCH_SIZE: usize = 200;
/// Rows read from Postgres and pushed to Solr per batch during a rebuild.
const REINDEX_BATCH_SIZE: usize = 500;
const CHANNEL_DEPTH: usize = 64;
/// Upper bound for a single source's index run. A healthy pass stays far
/// below this; a hung source (dead DB connection, stalled subprocess) must
/// not stall the daemon forever.
const SOURCE_TIMEOUT: Duration = Duration::from_secs(12 * 60 * 60);

/// Escape hatch for operators who genuinely emptied a source: set
/// `SEARCH_ALLOW_MASS_DELETE=1` to let a pass prune every known document.
const ALLOW_MASS_DELETE_ENV: &str = "SEARCH_ALLOW_MASS_DELETE";

/// Revision of the Postgres -> Solr projection (which fields and facets are
/// derived, and how). Bump this whenever `facets.rs` or `SolrDocument` mapping
/// changes: every source whose stored `index_version` differs is rebuilt from
/// Postgres, so the change reaches documents the checksum-based pass would
/// otherwise skip. 1 is the first revision (adds `kind_s`).
const INDEX_VERSION: i64 = 1;

/// Guards against a source silently producing no documents at all — most often
/// a mount that is present but empty, or an integration whose data was
/// temporarily moved. Deleting every known document on such a pass would wipe
/// the source from both Postgres and Solr, so the pass refuses instead.
///
/// This deliberately keys on the pass emitting *nothing*, not on a full id
/// turnover: a renamed archive or a re-hashed source legitimately replaces
/// every id while still emitting documents, and must be allowed to sync.
fn refuse_full_wipe(existing: usize, seen: usize) -> bool {
    existing > 0 && seen == 0
}

fn mass_delete_allowed() -> bool {
    std::env::var(ALLOW_MASS_DELETE_ENV)
        .ok()
        .map(|value| {
            let value = value.trim().to_ascii_lowercase();
            !value.is_empty() && value != "0" && value != "false"
        })
        .unwrap_or(false)
}

pub async fn run_index() -> Result<(), String> {
    let settings = Settings::from_env()?;
    if settings.sources.is_empty() {
        eprintln!("search: no sources configured; nothing to index");
        return Ok(());
    }
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;
    let solr = SolrClient::new(&settings.solr_url, &settings.solr_core);

    let mut failed: Vec<String> = Vec::new();
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
            Err(_elapsed) => {
                // The future was dropped before it could unlock; release the
                // per-source lock best-effort so the next pass can proceed.
                let _ = db::unlock_source(&client, &source_id).await;
                Err(format!(
                    "source exceeded the {}h watchdog",
                    SOURCE_TIMEOUT.as_secs() / 3600
                ))
            }
        };
        // One broken source must not stop the others from staying fresh, but
        // the failure is recorded per source and surfaced to the caller.
        if let Err(err) = result {
            eprintln!("search: indexing source '{source_id}' failed: {err}");
            if let Err(mark_err) = db::mark_failed(&client, &source_id, &err).await {
                eprintln!("search: could not record failure for '{source_id}': {mark_err}");
            }
            failed.push(source_id);
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "indexing failed for source(s): {}",
            failed.join(", ")
        ))
    }
}

async fn index_source(
    source: &SourceConfig,
    settings: &Settings,
    client: &mut tokio_postgres::Client,
    solr: &SolrClient,
) -> Result<(), String> {
    eprintln!("search: indexing source '{}'…", source.id);
    db::register_source(client, source).await?;

    // Refresh the Solr projection when the indexing mapping changes. A rebuild
    // reads from Postgres alone, so it is cheap and is what makes a
    // facets/schema change reach documents the checksum-based pass skips.
    if db::source_index_version(client, &source.id).await? != INDEX_VERSION {
        eprintln!(
            "search: source '{}': index mapping is out of date; rebuilding from database",
            source.id
        );
        if reindex_source(solr, client, &source.id).await?.is_none() {
            eprintln!(
                "search: source '{}': another indexing operation holds the lock; skipping",
                source.id
            );
            return Ok(());
        }
    }

    // A source that can prove its inputs are unchanged since the last fully
    // successful pass is skipped outright, avoiding the expensive per-document
    // extraction (pdftotext/zimdump) that otherwise runs on every pass.
    let fingerprint = extract::source_fingerprint(source);
    if let Some(fingerprint) = &fingerprint
        && let Some(previous) = db::source_fingerprint(client, &source.id).await?
        && &previous == fingerprint
    {
        eprintln!(
            "search: source '{}': inputs unchanged since last successful pass; skipping",
            source.id
        );
        return Ok(());
    }

    // Serialize with reconcile/reindex and with any overlapping pass for this
    // source so their Solr writes cannot interleave.
    if !db::try_source_lock(client, &source.id).await? {
        eprintln!(
            "search: source '{}': another indexing operation holds the lock; skipping",
            source.id
        );
        return Ok(());
    }
    let result = index_source_locked(source, settings, client, solr, fingerprint.as_deref()).await;
    if let Err(err) = db::unlock_source(client, &source.id).await {
        eprintln!(
            "search: source '{}': failed to release index lock: {err}",
            source.id
        );
    }
    result
}

/// The extraction/persist/prune pass for one source. The caller must already
/// hold that source's advisory lock.
async fn index_source_locked(
    source: &SourceConfig,
    settings: &Settings,
    client: &mut tokio_postgres::Client,
    solr: &SolrClient,
    fingerprint: Option<&str>,
) -> Result<(), String> {
    let existing = db::existing_checksums(client, &source.id).await?;
    eprintln!(
        "search: source '{}': {} known docs",
        source.id,
        existing.len()
    );
    let upsert = db::prepare_upsert(client).await?;
    let source_id = source.id.clone();
    let (sender, mut receiver) = tokio::sync::mpsc::channel::<ExtractedDocument>(CHANNEL_DEPTH);

    let extraction = {
        let source = source.clone();
        let settings = settings.clone();
        tokio::task::spawn_blocking(move || {
            let mut seen: HashSet<String> = HashSet::new();
            let mut failure: Option<String> = None;
            let mut emit = |doc: ExtractedDocument| {
                seen.insert(doc.external_id.clone());
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
        if pending.len() >= SOLR_BATCH_SIZE
            && let Err(err) =
                push_batch(solr, client, &upsert, source, &source_id, &mut pending).await
        {
            failure = Some(err);
            break;
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
    if let Some(err) = failure.or(emit_failure).or_else(|| extract_result.err()) {
        return Err(err);
    }
    push_batch(solr, client, &upsert, source, &source_id, &mut pending).await?;

    let missing: Vec<String> = existing
        .keys()
        .filter(|external_id| !seen.contains(*external_id))
        .cloned()
        .collect();
    // Federated sources intentionally emit nothing so that documents left by
    // an earlier extraction-based configuration are pruned; the wipe guard
    // must not block that intentional cleanup.
    if !is_federated(&source.source_type)
        && refuse_full_wipe(existing.len(), seen.len())
        && !mass_delete_allowed()
    {
        return Err(format!(
            "source '{}' produced no documents but {} are indexed; refusing to delete them \
             (set {ALLOW_MASS_DELETE_ENV}=1 to override)",
            source.id,
            existing.len()
        ));
    }
    if !missing.is_empty() {
        eprintln!(
            "search: source '{}': pruning {} documents no longer produced",
            source.id,
            missing.len()
        );
    }
    db::delete_missing(client, &source_id, &missing).await?;
    let missing_ids: Vec<String> = missing
        .iter()
        .map(|external_id| db::full_document_id(&source_id, external_id))
        .collect();
    solr.delete_ids(&missing_ids).await?;
    // Streaming adds/deletes use commitWithin; one explicit commit per source
    // makes the whole pass durable without a hard commit per batch.
    solr.commit().await?;
    db::mark_synced(client, &source_id, fingerprint).await?;
    eprintln!(
        "search: source '{}': synced ({} changed, {} missing removed)",
        source_id,
        changed_count,
        missing.len()
    );
    Ok(())
}

/// Owner filter sentinel for sources whose content is not user-scoped (Kiwix
/// archives, web-archive crawls). It surfaces as its own facet value so admins
/// can include or exclude shared material.
pub const SHARED_OWNER: &str = "shared";

/// Reads the `owner` metadata the extractors attach per document, falling back
/// to the shared sentinel for sources with no per-user ownership.
fn document_owner(record: &DocumentRecord) -> String {
    record
        .metadata
        .get("owner")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|owner| !owner.is_empty())
        .unwrap_or(SHARED_OWNER)
        .to_string()
}

/// Pushes a batch to Solr first and persists it to Postgres afterwards, so a
/// failed push leaves nothing behind that a later pass would consider
/// already-indexed (the checksum lives only in Postgres once persisted).
/// If Postgres upserts fail after a successful push, the next pass simply
/// re-pushes the affected documents; Solr writes are idempotent.
async fn push_batch(
    solr: &SolrClient,
    client: &mut tokio_postgres::Client,
    upsert: &tokio_postgres::Statement,
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
        .map(|record| SolrDocument::from_record(source_id, record, &document_owner(record)))
        .collect();
    flush_solr(solr, solr_docs).await?;
    let transaction = client
        .transaction()
        .await
        .map_err(|err| format!("failed to start document batch: {err}"))?;
    // Poll the bounded Solr-sized batch concurrently to pipeline PostgreSQL
    // requests; commit once, after every upsert has succeeded.
    // https://docs.rs/tokio-postgres/0.7.17/tokio_postgres/#pipelining
    futures_util::future::try_join_all(
        records
            .iter()
            .map(|record| db::upsert_document(&transaction, upsert, source, record)),
    )
    .await
    .map_err(|err| format!("failed to persist indexed documents: {err}"))?;
    transaction
        .commit()
        .await
        .map_err(|err| format!("failed to commit document batch: {err}"))?;
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

    // Detect drift between the authoritative Postgres copy and the derived
    // Solr index. A document lost from Solr while its Postgres row is unchanged
    // is invisible to the incremental checksum comparison, so only a count
    // comparison (and a rebuild) can heal it. Rebuilds only run on a mismatch,
    // so the normal daily pass costs two count queries per source.
    for source in &settings.sources {
        let postgres = db::count_documents(&client, &source.id).await?;
        let solr_docs = solr.document_count(&source.id).await?;
        if postgres as u64 == solr_docs {
            continue;
        }
        eprintln!(
            "search: source '{}': index drift detected (postgres {}, solr {}); rebuilding",
            source.id, postgres, solr_docs
        );
        match reindex_source(&solr, &client, &source.id).await? {
            Some(rebuilt) => {
                eprintln!("search: source '{}': rebuilt ({} docs)", source.id, rebuilt)
            }
            None => eprintln!(
                "search: source '{}': rebuild skipped; another indexing operation holds the lock",
                source.id
            ),
        }
    }
    Ok(())
}

/// Rebuilds the Solr index from the authoritative Postgres database alone.
///
/// Recovery for a lost, recreated, or schema-changed Solr core: the database
/// already stores every indexed field, so sources are not re-extracted.
/// Documents are re-added by their unique id, which overwrites any existing
/// copy, so the command is idempotent and safe to rerun.
pub async fn run_reindex() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;
    let solr = SolrClient::new(&settings.solr_url, &settings.solr_core);

    let sources = db::list_sources(&client).await?;
    let mut total = 0usize;
    for source in &sources {
        match reindex_source(&solr, &client, &source.id).await? {
            Some(source_total) => {
                total += source_total;
                eprintln!(
                    "search: reindexed source '{}' ({} docs)",
                    source.id, source_total
                );
            }
            None => eprintln!(
                "search: source '{}': reindex skipped; another indexing operation holds the lock",
                source.id
            ),
        }
    }
    eprintln!("search: reindex complete ({total} docs)");
    Ok(())
}

/// Rebuilds one source's Solr documents from the authoritative Postgres copy.
///
/// Takes the source's advisory lock; returns `None` when another indexing
/// operation holds it, so the caller skips rather than interleaving writes.
async fn reindex_source(
    solr: &SolrClient,
    client: &tokio_postgres::Client,
    source_id: &str,
) -> Result<Option<usize>, String> {
    if !db::try_source_lock(client, source_id).await? {
        return Ok(None);
    }
    let result = rebuild_source(solr, client, source_id).await;
    if result.is_ok() {
        // The rebuilt projection matches the current mapping revision.
        if let Err(err) = db::set_index_version(client, source_id, INDEX_VERSION).await {
            eprintln!("search: source '{source_id}': failed to record index version: {err}");
        }
    }
    if let Err(err) = db::unlock_source(client, source_id).await {
        eprintln!("search: source '{source_id}': failed to release index lock: {err}");
    }
    result.map(Some)
}

/// The rebuild body; the caller must already hold the source's advisory lock.
///
/// The source's existing Solr documents are deleted first so entries that no
/// longer exist in Postgres are removed too, then every stored document is
/// streamed back in and committed once. The Postgres copy carries every indexed
/// field, so no source re-extraction is needed, and a rerun is safe.
async fn rebuild_source(
    solr: &SolrClient,
    client: &tokio_postgres::Client,
    source_id: &str,
) -> Result<usize, String> {
    solr.delete_by_source(source_id).await?;
    // Commit the delete before re-adding: a delete-by-query and later adds
    // sharing one commit window are not guaranteed to be ordered, and the
    // delete could otherwise remove the freshly added documents.
    solr.commit().await?;
    let mut after: Option<String> = None;
    let mut total = 0usize;
    loop {
        let batch = db::documents_batch(
            client,
            source_id,
            after.as_deref(),
            REINDEX_BATCH_SIZE as i64,
        )
        .await?;
        if batch.is_empty() {
            break;
        }
        let docs: Vec<SolrDocument> = batch
            .iter()
            .map(|(_, record)| {
                SolrDocument::from_record(source_id, record, &document_owner(record))
            })
            .collect();
        solr.add_documents(&docs).await?;
        total += docs.len();
        let complete = batch.len() < REINDEX_BATCH_SIZE;
        after = batch.last().map(|(id, _)| id.clone());
        if complete {
            break;
        }
    }
    solr.commit().await?;
    Ok(total)
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
    fn refuses_to_wipe_a_source_that_produced_nothing() {
        // An empty index, or a pass that emitted documents, is allowed to prune.
        assert!(refuse_full_wipe(3, 0));
        assert!(refuse_full_wipe(1, 0));
        assert!(!refuse_full_wipe(3, 1));
        // A full id turnover (same count, all new ids) must still sync.
        assert!(!refuse_full_wipe(3, 3));
        assert!(!refuse_full_wipe(0, 0));
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
            paperless_token_file: None,
        };

        let mut docs = Vec::new();
        extract::run(&settings.sources[0], &settings, &mut |doc| {
            docs.push(doc);
        })
        .expect("extract");

        assert_eq!(docs.len(), 1, "expected exactly one paperless document");
        let record = docs.into_iter().next().expect("doc").into_record();
        let solr_doc = SolrDocument::from_record("paperless", &record, "ACME");
        let payload = solr_doc.to_solr_json();

        assert_eq!(payload["id"], json!("paperless:42"));
        assert_eq!(payload["source"], json!("paperless"));
        assert_eq!(payload["title"], json!("Invoice 42"));
        assert_eq!(payload["body"], json!("total due 100"));
        assert_eq!(payload["content_type"], json!("application/pdf"));
        assert!(payload.get("content_created").is_some());
        assert_eq!(payload["owner_s"], json!("ACME"));
        // Metadata stays authoritative in Postgres and is not copied to Solr.
        assert!(payload.get("meta_correspondent_s").is_none());
    }

    /// Opt-in against a disposable PostgreSQL database. A private schema keeps
    /// the fixture isolated; the HTTP stub exercises the real Solr request path.
    #[tokio::test]
    #[ignore = "requires disposable PostgreSQL fixture"]
    async fn postgres_batch_rolls_back_recovers_and_replays_idempotently() {
        use axum::{routing::post, Json, Router};
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };

        let database_url = std::env::var("SEARCH_BATCH_TEST_DATABASE_URL")
            .expect("SEARCH_BATCH_TEST_DATABASE_URL must point to a disposable PostgreSQL fixture");
        let mut client = db::connect(&database_url)
            .await
            .expect("fixture connection");
        let schema = format!(
            "search_batch_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        );
        client
            .batch_execute(&format!(
                "CREATE SCHEMA {schema}; SET search_path TO {schema}"
            ))
            .await
            .expect("isolated schema");
        db::migrate(&mut client).await.expect("migrate");
        let source = SourceConfig {
            id: "batch-fixture".into(),
            display_name: "Batch fixture".into(),
            source_type: "paperless".into(),
            app_base: "https://fixture.invalid".into(),
            settings: Default::default(),
        };
        db::register_source(&mut client, &source)
            .await
            .expect("register source");
        client.batch_execute("ALTER TABLE documents ADD CONSTRAINT reject_fixture_title CHECK (title <> 'reject-this-document')")
            .await.expect("failure constraint");
        let upsert = db::prepare_upsert(&client).await.expect("prepare upsert");
        let calls = Arc::new(AtomicUsize::new(0));
        let stub_calls = calls.clone();
        let app = Router::new().route(
            "/fixture/update",
            post(move |Json(payload): Json<serde_json::Value>| {
                let calls = stub_calls.clone();
                async move {
                    assert_eq!(
                        payload["add"].as_array().expect("Solr add documents").len(),
                        200
                    );
                    calls.fetch_add(1, Ordering::SeqCst);
                    Json(json!({"responseHeader": {"status": 0}}))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("stub listener");
        let address = listener.local_addr().expect("stub address");
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("Solr stub");
        });
        let solr = SolrClient::new(&format!("http://{address}"), "fixture");
        let records = (0..200)
            .map(|index| DocumentRecord {
                external_id: format!("document-{index:03}"),
                kind: "fixture".into(),
                title: format!("Document {index}"),
                body_text: "Fixture content".into(),
                content_type: "text/plain".into(),
                origin_url: String::new(),
                app_url: String::new(),
                file_path: String::new(),
                size_bytes: 15,
                checksum: format!("checksum-{index}"),
                content_created_at: None,
                content_modified_at: None,
                metadata: json!({}),
            })
            .collect::<Vec<_>>();

        // Fail near the end: all earlier pipelined writes must roll back too.
        let mut rejected = records.clone();
        rejected[199].title = "reject-this-document".into();
        let error = push_batch(
            &solr,
            &mut client,
            &upsert,
            &source,
            &source.id,
            &mut rejected,
        )
        .await
        .expect_err("one bad document must reject the whole batch");
        assert!(
            error.contains("failed to persist indexed documents"),
            "{error}"
        );
        assert!(rejected.is_empty());
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "Solr succeeds before PostgreSQL rejects"
        );
        let count: i64 = client
            .query_one("SELECT count(*) FROM documents", &[])
            .await
            .expect("same client recovers after rollback")
            .get(0);
        assert_eq!(count, 0, "no partial batch may survive");

        let mut recovery = records.clone();
        push_batch(
            &solr,
            &mut client,
            &upsert,
            &source,
            &source.id,
            &mut recovery,
        )
        .await
        .expect("retry on the same client succeeds");
        assert!(recovery.is_empty());
        let count: i64 = client
            .query_one("SELECT count(*) FROM documents", &[])
            .await
            .expect("count recovered documents")
            .get(0);
        assert_eq!(count, 200);

        // Replay the same IDs with changed content: upsert updates, never duplicates.
        let mut replay = records;
        replay[0].title = "Updated document".into();
        push_batch(
            &solr,
            &mut client,
            &upsert,
            &source,
            &source.id,
            &mut replay,
        )
        .await
        .expect("idempotent replay succeeds");
        let count: i64 = client
            .query_one("SELECT count(*) FROM documents", &[])
            .await
            .expect("count replayed documents")
            .get(0);
        assert_eq!(count, 200);
        let title: String = client
            .query_one(
                "SELECT title FROM documents WHERE external_id='document-000'",
                &[],
            )
            .await
            .expect("updated document")
            .get(0);
        assert_eq!(title, "Updated document");
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        client
            .batch_execute(&format!("DROP SCHEMA {schema} CASCADE"))
            .await
            .expect("fixture cleanup");
        server.abort();
    }
}
