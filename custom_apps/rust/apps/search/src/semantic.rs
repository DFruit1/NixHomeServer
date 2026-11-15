//! Local semantic retrieval. Text stays in Postgres; Solr holds vectors and
//! byte offsets only. Inference services are loopback-only llama.cpp servers.
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio_postgres::Client;

use crate::cache::TtlCache;
use crate::db;
use crate::solr::{SearchFilters, SearchHit, SearchResponse, SolrClient, SolrDocument, SortOrder};

const DIMENSIONS: usize = 2560;
const VERSION: &str = "qwen4b-f16-e8b4e85c-passage-v1";
const CANDIDATES: usize = 100;
const PASSAGE_BYTES: usize = 1600;
const OVERLAP_BYTES: usize = 200;
const INDEX_BATCH_SIZE: usize = 1;

/// Query-time budgets, measured on the deployed 0.6B reranker: about 730
/// tokens a second while indexing shares the GPU, so an 800-byte library
/// passage (a median 268 tokens) costs ~0.35s and a full indexed passage
/// ~0.7s. Reranking 40 documents on two full passages each held every search
/// for 22-47s. The reranker now reads each document's strongest evidence in
/// rank order, in small requests, and stops at a deadline.
const RERANK_DOCS: usize = 30;
const RERANK_CHUNK: usize = 3;
const RERANK_BUDGET: Duration = Duration::from_secs(5);
/// Keyword evidence shown to the reranker: the densest window of a matching
/// document, about a paragraph, rather than a whole indexed passage.
const EVIDENCE_BYTES: usize = 640;
const EVIDENCE_OVERLAP_BYTES: usize = 128;
/// A query embedding normally takes well under a second. A slow one must not
/// hold the answer; it finishes in the background for the next search.
const VECTOR_BUDGET: Duration = Duration::from_secs(5);
/// Passages closer than this to the query are candidates. On this library
/// related passages measured 0.54-0.74 and unrelated ones at most 0.30, so the
/// nearest neighbours of an unrelated query are not mistaken for matches.
const MIN_COSINE: f64 = 0.4;
/// The reranker's relevance probability a document needs when it lacks the
/// query's words: clearly related passages score above 0.9, tangential ones
/// below 0.1.
const ADMIT_SCORE: f64 = 0.5;
/// Below this the reranker read a keyword match's best passage and found it
/// unrelated: such matches measured 0.00-0.09 where relevant ones scored 0.4
/// or more. They rank after matches it had no time to read, whose order is
/// still the keyword order.
const REJECT_SCORE: f64 = 0.1;

/// One ranked answer: keyword candidates and related passages fused, the head
/// reranked. Later pages and repeats slice it instead of ranking again.
struct Window {
    hits: Vec<SearchHit>,
    snippets: HashMap<String, String>,
    /// The keyword response behind the window, its hits moved into `hits`.
    keyword: SearchResponse,
    /// Keyword results consumed from the front of the full keyword ranking.
    consumed: usize,
}

#[derive(Clone)]
pub(crate) struct Semantic {
    http: reqwest::Client,
    query_url: String,
    rerank_url: String,
    core_url: String,
    /// Embeddings are deterministic, so a repeated query never pays twice.
    vectors: Arc<TtlCache<Arc<Vec<f32>>>>,
    windows: Arc<TtlCache<Arc<Window>>>,
}

impl Semantic {
    pub(crate) fn from_env() -> Result<Option<Self>, String> {
        let Ok(query_url) = std::env::var("SEARCH_EMBED_QUERY_URL") else {
            return Ok(None);
        };
        let rerank_url =
            std::env::var("SEARCH_RERANK_URL").map_err(|_| "SEARCH_RERANK_URL is required")?;
        for endpoint in [&query_url, &rerank_url] {
            let url = url::Url::parse(endpoint).map_err(|e| e.to_string())?;
            if url.scheme() != "http"
                || url.host_str().is_none_or(|h| {
                    h.parse::<std::net::IpAddr>()
                        .map_or(true, |ip| !ip.is_loopback())
                })
            {
                return Err("Search inference endpoints must use loopback HTTP".into());
            }
        }
        Ok(Some(Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(90))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|e| e.to_string())?,
            query_url,
            rerank_url,
            core_url: format!(
                "{}/{}",
                std::env::var("SEARCH_SOLR_URL").map_err(|e| e.to_string())?,
                std::env::var("SEARCH_PASSAGE_CORE")
                    .unwrap_or_else(|_| "search-passages-v1".into())
            ),
            vectors: Arc::new(TtlCache::new(Duration::from_secs(3600), 256)),
            windows: Arc::new(TtlCache::new(Duration::from_secs(600), 32)),
        }))
    }

    async fn post(&self, url: &str, body: &Value) -> Result<Value, String> {
        self.post_with_timeout(url, body, Duration::from_secs(90))
            .await
    }

    async fn post_with_timeout(
        &self,
        url: &str,
        body: &Value,
        timeout: Duration,
    ) -> Result<Value, String> {
        let response: Value = self
            .http
            .post(url)
            .json(body)
            .timeout(timeout)
            .send()
            .await
            .map_err(|e| format!("inference/index request: {e}"))?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        if response.get("error").is_some() {
            return Err("inference/index rejected request".into());
        }
        Ok(response)
    }

    async fn embed(
        &self,
        endpoint: &str,
        inputs: &[String],
        timeout: Duration,
    ) -> Result<Vec<Vec<f32>>, String> {
        let body = self
            .post_with_timeout(
                &format!("{endpoint}/v1/embeddings"),
                &json!({"input": inputs, "encoding_format": "float"}),
                timeout,
            )
            .await?;
        let rows = body["data"]
            .as_array()
            .ok_or("embedding response missing data")?;
        if rows.len() != inputs.len() {
            return Err("embedding response has wrong row count".into());
        }
        let mut vectors = vec![Vec::new(); inputs.len()];
        for row in rows {
            let i = row["index"]
                .as_u64()
                .ok_or("embedding response missing index")? as usize;
            if i >= vectors.len() || !vectors[i].is_empty() {
                return Err("invalid embedding index".into());
            }
            let mut vector: Vec<f32> =
                serde_json::from_value(row["embedding"].clone()).map_err(|e| e.to_string())?;
            let norm = vector
                .iter()
                .map(|v| f64::from(*v).powi(2))
                .sum::<f64>()
                .sqrt();
            if vector.len() != DIMENSIONS || !norm.is_finite() || norm <= 0.0 {
                return Err("invalid embedding dimensions or norm".into());
            }
            for v in &mut vector {
                *v = (f64::from(*v) / norm) as f32;
            }
            vectors[i] = vector;
        }
        Ok(vectors)
    }

    async fn query_vector(&self, query: &str) -> Result<Arc<Vec<f32>>, String> {
        let (vector, _) = self
            .vectors
            .get_or_try_init(query, || async {
                let input = format!("Instruct: Given a library search query, retrieve relevant passages that address the user's request\nQuery: {query}");
                let vector = self
                    .embed(&self.query_url, &[input], Duration::from_secs(90))
                    .await?
                    .remove(0);
                Ok(Arc::new(vector))
            })
            .await?;
        Ok(vector)
    }
}

/// UTF-8 byte offsets with bounded paragraph-aware overlap. A title-only
/// catalog record still gets one passage; no long-book prefix truncation.
fn passages(body: &str) -> Vec<(usize, usize)> {
    spans(body, PASSAGE_BYTES, OVERLAP_BYTES)
}

fn spans(body: &str, size: usize, overlap: usize) -> Vec<(usize, usize)> {
    if body.is_empty() {
        return vec![(0, 0)];
    }
    let mut spans = Vec::new();
    let mut start = 0;
    while start < body.len() {
        let max_end = body.floor_char_boundary((start + size).min(body.len()));
        let end = if max_end < body.len() {
            body[start..max_end]
                .rfind('\n')
                .map(|i| start + i + 1)
                .filter(|end| *end > start + (max_end - start) / 2)
                .unwrap_or(max_end)
        } else {
            max_end
        };
        spans.push((start, end));
        if end == body.len() {
            break;
        }
        let overlap = body.floor_char_boundary(end.saturating_sub(overlap));
        start = overlap.max(start + body[start..].chars().next().unwrap().len_utf8());
    }
    spans
}

fn passage_input(title: &str, body: &str) -> String {
    format!(
        "{}\n\n{body}",
        &title[..title.floor_char_boundary(title.len().min(256))]
    )
}

/// The windows of a document that best cover the query's words, including
/// grammatical forms, strongest first. A last-match tie can otherwise present
/// an unrelated chapter to the reranker and hide the useful section. A body
/// without any of the words (a title match) is represented by its opening.
fn lexical_passages<'a>(body: &'a str, query: &str) -> Vec<&'a str> {
    let words =
        crate::text::discovery_words(query).unwrap_or_else(|| crate::text::query_terms(query));
    let forms: Vec<HashSet<String>> = words
        .iter()
        .map(|word| {
            std::iter::once(word.clone())
                .chain(crate::thesaurus::word_forms(word))
                .collect()
        })
        .collect();
    let mut candidates: Vec<_> = spans(body, EVIDENCE_BYTES, EVIDENCE_OVERLAP_BYTES)
        .into_iter()
        .map(|(start, end)| {
            let text = &body[start..end];
            let lower = text.to_lowercase();
            let tokens: Vec<_> = lower
                .split(|ch: char| !ch.is_alphanumeric())
                .filter(|word| !word.is_empty())
                .collect();
            let counts: Vec<_> = forms
                .iter()
                .map(|group| tokens.iter().filter(|word| group.contains(**word)).count())
                .collect();
            let score = (
                counts.iter().filter(|count| **count > 0).count(),
                counts.iter().min().copied().unwrap_or(0),
                counts.iter().sum::<usize>(),
            );
            (text, score)
        })
        .collect();
    let opening = candidates.first().map(|candidate| candidate.0);
    candidates.retain(|candidate| candidate.1 .0 > 0);
    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.1));
    let best: Vec<_> = candidates
        .into_iter()
        .take(2)
        .map(|(text, _)| text)
        .collect();
    if best.is_empty() {
        opening.into_iter().collect()
    } else {
        best
    }
}

/// A separate maintenance pass catches existing and newly changed documents.
/// Successful Solr commits precede checkpoint updates, so interrupted passes
/// retry instead of silently omitting text. Tombstones survive PG deletion
/// until the matching vectors have been removed.
pub(crate) async fn run_index() -> Result<(), String> {
    let semantic = Semantic::from_env()?.ok_or("semantic search is not configured")?;
    let settings = crate::config::Settings::from_env()?;
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&mut client).await?;
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS semantic_documents (
        document_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, checksum TEXT NOT NULL,
        version TEXT NOT NULL, passages INTEGER NOT NULL)",
        )
        .await
        .map_err(|e| e.to_string())?;
    if !client
        .query_one("SELECT pg_try_advisory_lock(1397047629, 1)", &[])
        .await
        .map_err(|e| e.to_string())?
        .get::<_, bool>(0)
    {
        return Err("another semantic index pass is running".into());
    }
    let selected: Vec<String> = settings
        .sources
        .iter()
        .filter(|s| !crate::config::is_federated(&s.source_type))
        .map(|s| s.id.clone())
        .collect();
    // Remove vectors for deleted documents and disabled integrations first.
    let stale = client.query("SELECT s.document_id FROM semantic_documents s LEFT JOIN documents d ON d.id=s.document_id
        WHERE d.id IS NULL OR NOT (s.source_id = ANY($1))", &[&selected]).await.map_err(|e| e.to_string())?;
    for row in stale {
        let id: String = row.get(0);
        semantic.delete_parent(&id).await?;
        client
            .execute(
                "DELETE FROM semantic_documents WHERE document_id=$1",
                &[&id],
            )
            .await
            .map_err(|e| e.to_string())?;
    }
    // A missing/recreated vector core must not be mistaken for a completed
    // backfill just because its database checkpoints survived.
    let count = semantic
        .select(vec![("q", "manifest_b:true".into()), ("rows", "0".into())])
        .await?;
    let expected: i64 = client
        .query_one("SELECT count(*) FROM semantic_documents", &[])
        .await
        .map_err(|e| e.to_string())?
        .get(0);
    if count["response"]["numFound"].as_i64() != Some(expected) {
        client
            .execute("UPDATE semantic_documents SET version=''", &[])
            .await
            .map_err(|e| e.to_string())?;
    }
    // Shortest first: a passage costs seconds, so this makes the most
    // documents searchable by meaning soonest and leaves whole books for last.
    // The stored size is read without loading the text.
    let pending_sql = "SELECT d.id FROM documents d LEFT JOIN semantic_documents s ON s.document_id=d.id
        WHERE d.source_id=ANY($1) AND (s.document_id IS NULL OR s.checksum<>d.checksum OR s.version<>$2)
        ORDER BY octet_length(d.body_text), d.id LIMIT 8";
    if client
        .query(pending_sql, &[&selected, &VERSION])
        .await
        .map_err(|e| e.to_string())?
        .is_empty()
    {
        eprintln!("search semantic: all active documents are up to date");
        return Ok(());
    }
    // Child lifetime is exactly this pass, including errors and cancellation.
    // The query embedder is a different process with GPU offload disabled.
    let binary =
        std::env::var("SEARCH_LLAMA_SERVER").map_err(|_| "SEARCH_LLAMA_SERVER is required")?;
    let model =
        std::env::var("SEARCH_EMBED_MODEL").map_err(|_| "SEARCH_EMBED_MODEL is required")?;
    let port = std::env::var("SEARCH_EMBED_INDEX_PORT")
        .map_err(|_| "SEARCH_EMBED_INDEX_PORT is required")?;
    let layers = std::env::var("SEARCH_EMBED_GPU_LAYERS").unwrap_or_else(|_| "1".into());
    let mut child = tokio::process::Command::new(binary)
        .args([
            "--model",
            &model,
            "--host",
            "127.0.0.1",
            "--port",
            &port,
            "--embedding",
            "--pooling",
            "last",
            "--n-gpu-layers",
            &layers,
            "--ctx-size",
            "2048",
            "--batch-size",
            "2048",
            "--ubatch-size",
            "2048",
            "--parallel",
            "1",
            "--threads",
            "4",
            "--flash-attn",
            "on",
        ])
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("start indexing embedder: {e}"))?;
    let endpoint = format!("http://127.0.0.1:{port}");
    let result = async {
        let started = Instant::now();
        loop {
            if child.try_wait().map_err(|e| e.to_string())?.is_some() { return Err("indexing embedder exited before readiness; check GPU capacity and logs".into()); }
            if semantic.http.get(format!("{endpoint}/health")).timeout(Duration::from_secs(2)).send().await.is_ok_and(|r| r.status().is_success()) { break; }
            if started.elapsed() > Duration::from_secs(180) { return Err("indexing embedder readiness timed out".into()); }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        loop {
            let rows = client.query(pending_sql, &[&selected, &VERSION]).await.map_err(|e| e.to_string())?;
            if rows.is_empty() { break; }
            let ids: Vec<String> = rows.iter().map(|r| r.get(0)).collect();
            for (id, record) in db::documents_by_ids(&client, &ids).await? {
                let source_id = settings.sources.iter().find(|s| id == db::full_document_id(&s.id, &record.external_id)).map(|s| s.id.as_str()).ok_or("document source is not active")?;
                let owner = record.metadata["owner"].as_str().filter(|s| !s.trim().is_empty()).unwrap_or(crate::indexer::SHARED_OWNER);
                let projection = SolrDocument::from_record(source_id, &record, owner);
                let spans = passages(&record.body_text);
                // A document fingerprint doubles as a generation identifier.
                // New vectors become visible before old generations are pruned.
                let generation = crate::timeutil::sha256_hex(&[&id, &record.checksum, VERSION]);
                for (batch, pairs) in spans.chunks(INDEX_BATCH_SIZE).enumerate() {
                    let input: Vec<_> = pairs.iter().map(|&(start, end)| passage_input(&record.title, &record.body_text[start..end])).collect();
                    // Limited GPU offload leaves most 4B work on CPU. A library
                    // batch can take minutes; do not apply the query deadline.
                    let vectors = semantic.embed(&endpoint, &input, Duration::from_secs(10 * 60)).await?;
                    let mut docs = Vec::new();
                    for (index, ((start, end), vector)) in pairs.iter().zip(vectors).enumerate() {
                        let mut doc = projection.to_solr_json();
                        let object = doc.as_object_mut().unwrap();
                        object.remove("body");
                        object.insert("id".into(), json!(format!("{generation}:{}", batch * INDEX_BATCH_SIZE + index)));
                        object.insert("parent_s".into(), json!(id));
                        object.insert("generation_s".into(), json!(generation));
                        object.insert("start_l".into(), json!(start));
                        object.insert("end_l".into(), json!(end));
                        object.insert("manifest_b".into(), json!(false));
                        object.insert("vector".into(), json!(vector));
                        docs.push(doc);
                    }
                    semantic.post(&format!("{}/update?commitWithin=10000", semantic.core_url), &json!(docs)).await?;
                }
                semantic.post(&format!("{}/update?commit=true", semantic.core_url), &json!([
                    {"id": format!("{}:manifest", crate::timeutil::sha256_hex(&[&id])), "parent_s": id, "source": source_id, "manifest_b": true}
                ])).await?;
                semantic.post(&format!("{}/update?commit=true", semantic.core_url), &json!({"delete": {"query": format!("parent_s:{} AND manifest_b:false AND -generation_s:{}", term(&id), term(&generation))}})).await?;
                client.execute("INSERT INTO semantic_documents(document_id,source_id,checksum,version,passages) VALUES($1,$2,$3,$4,$5)
                    ON CONFLICT(document_id) DO UPDATE SET source_id=EXCLUDED.source_id, checksum=EXCLUDED.checksum,version=EXCLUDED.version,passages=EXCLUDED.passages",
                    &[&id, &source_id, &record.checksum, &VERSION, &(spans.len() as i32)]).await.map_err(|e| e.to_string())?;
                eprintln!("search semantic: indexed {id} ({} passages)", spans.len());
            }
        }
        Ok(())
    }.await;
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

fn term(value: &str) -> String {
    // JSON quoted strings use the same escapes as Solr quoted terms.
    serde_json::to_string(value).unwrap()
}

impl Semantic {
    async fn select(&self, mut params: Vec<(&str, String)>) -> Result<Value, String> {
        params.push(("wt", "json".into()));
        let result: Value = self
            .http
            .post(format!("{}/select", self.core_url))
            .form(&params)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        if result.get("error").is_some() {
            return Err("passage query rejected".into());
        }
        Ok(result)
    }
    async fn delete_parent(&self, id: &str) -> Result<(), String> {
        self.post(
            &format!("{}/update?commit=true", self.core_url),
            &json!({"delete":{"query":format!("parent_s:{}",term(id))}}),
        )
        .await?;
        Ok(())
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Request<'a> {
    pub solr: &'a SolrClient,
    pub database: &'a Client,
    pub query: &'a str,
    pub sources: &'a [String],
    pub filters: &'a SearchFilters,
    /// Changes whenever a source finishes syncing, so a ranked answer is not
    /// reused across an index update.
    pub generation: &'a str,
    pub rows: usize,
    pub offset: usize,
}

pub(crate) struct Ranked {
    pub response: SearchResponse,
    pub snippets: HashMap<String, String>,
    pub has_more: bool,
}

pub(crate) fn eligible(query: &str, filters: &SearchFilters, sort: SortOrder) -> bool {
    sort == SortOrder::Relevance
        && filters.matching == crate::solr::MatchMode::Broad
        && query.chars().count() <= 256
        && !query.contains([':', '*', '~', '^', '[', ']', '(', ')', '"'])
        && !query
            .split_whitespace()
            .any(|w| matches!(w, "AND" | "OR" | "NOT" | "TO") || w.starts_with(['-', '+']))
}

/// Documents with a passage close to the query, nearest first, and the
/// passages that put them there.
#[derive(Default)]
struct Neighbours {
    parents: Vec<String>,
    spans: HashMap<String, Vec<(usize, usize, String)>>,
}

impl Semantic {
    /// Keyword and related-passage candidates fused by rank, never by
    /// incompatible raw score magnitudes, with the leading documents reordered
    /// by the reranker. Results continue into the remaining keyword matches,
    /// so counts and paging cover the whole library.
    pub(crate) async fn search(&self, request: Request<'_>) -> Result<Ranked, String> {
        let Request {
            solr,
            query,
            sources,
            filters,
            generation,
            rows,
            offset,
            ..
        } = request;
        let key = crate::timeutil::sha256_hex(&[
            query,
            &sources.join("\u{1f}"),
            &format!("{filters:?}"),
            generation,
        ]);
        let (window, _) = self
            .windows
            .get_or_try_init(&key, || self.window(request))
            .await?;
        let remaining = window.keyword.total.saturating_sub(window.consumed as u64);
        let total = window.hits.len() as u64 + remaining;
        let mut hits: Vec<SearchHit> = window
            .hits
            .iter()
            .skip(offset)
            .take(rows)
            .cloned()
            .collect();
        if hits.len() < rows && remaining > 0 {
            let past_window = offset.saturating_sub(window.hits.len());
            let more = solr
                .search(
                    query,
                    sources,
                    filters,
                    rows - hits.len(),
                    window.consumed + past_window,
                    SortOrder::Relevance,
                )
                .await?;
            // A related passage admitted above may also be a distant keyword
            // match; show it once.
            let shown: HashSet<&str> = window.hits.iter().map(|hit| hit.id.as_str()).collect();
            hits.extend(
                more.hits
                    .into_iter()
                    .filter(|hit| !shown.contains(hit.id.as_str())),
            );
        }
        let mut response = window.keyword.clone();
        response.hits = hits;
        response.total = total;
        Ok(Ranked {
            response,
            snippets: window.snippets.clone(),
            has_more: ((offset + rows) as u64) < total,
        })
    }

    async fn neighbours(
        &self,
        query: &str,
        sources: &[String],
        filters: &SearchFilters,
    ) -> Result<Neighbours, String> {
        let embedder = self.clone();
        let text = query.to_string();
        // Detached, so an embedding that outlives its budget still lands in
        // the cache for the next search of the same words.
        let embedding = tokio::spawn(async move { embedder.query_vector(&text).await });
        let vector = match tokio::time::timeout(VECTOR_BUDGET, embedding).await {
            Ok(Ok(vector)) => vector?,
            Ok(Err(error)) => return Err(format!("query embedding task failed: {error}")),
            Err(_) => {
                eprintln!(
                    "search: query embedding exceeded its budget; ranking keyword candidates only"
                );
                return Ok(Neighbours::default());
            }
        };
        let vector_query = format!(
            "{{!knn f=vector topK=1000}}{}",
            serde_json::to_string(vector.as_ref()).map_err(|e| e.to_string())?
        );
        let mut params = vec![
            ("q", vector_query),
            ("fq", "manifest_b:false".into()),
            ("rows", "1000".into()),
            ("fl", "parent_s start_l end_l generation_s score".into()),
        ];
        params.extend(
            filters
                .clauses(sources)
                .into_iter()
                .map(|clause| ("fq", clause)),
        );
        if !filters.wiki_full_text {
            params.push(("fq", "-kind_s:zim-article".into()));
        }
        let passages = self.select(params).await?;
        let mut neighbours = Neighbours::default();
        for hit in passages["response"]["docs"]
            .as_array()
            .ok_or("passage response missing docs")?
        {
            // Unit vectors: Solr reports (1 + cosine) / 2, nearest first.
            let cosine = 2.0 * hit["score"].as_f64().unwrap_or(0.0) - 1.0;
            if cosine < MIN_COSINE {
                break;
            }
            let Some(id) = hit["parent_s"].as_str() else {
                continue;
            };
            if !neighbours.spans.contains_key(id) {
                if neighbours.parents.len() >= CANDIDATES {
                    continue;
                }
                neighbours.parents.push(id.into());
            }
            let entries = neighbours.spans.entry(id.into()).or_default();
            if entries.len() < 2
                && let (Some(start), Some(end), Some(generation)) = (
                    hit["start_l"].as_u64(),
                    hit["end_l"].as_u64(),
                    hit["generation_s"].as_str(),
                )
            {
                entries.push((start as usize, end as usize, generation.into()));
            }
        }
        Ok(neighbours)
    }

    /// Relevance probabilities for `documents`, in input order.
    async fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f64>, String> {
        // The endpoint formats Qwen's trained query/document template; no
        // generated answer text is involved.
        let ranked = self
            .post(
                &format!("{}/v1/rerank", self.rerank_url),
                &json!({"query": query, "documents": documents, "top_n": documents.len()}),
            )
            .await?;
        let ranked = ranked["results"]
            .as_array()
            .ok_or("reranker response missing results")?;
        if ranked.len() != documents.len() {
            return Err("reranker returned an incomplete result set".into());
        }
        let mut scores = vec![None; documents.len()];
        for item in ranked {
            let index = item["index"]
                .as_u64()
                .ok_or("reranker result missing index")? as usize;
            let score = item["relevance_score"]
                .as_f64()
                .filter(|s| s.is_finite())
                .ok_or("reranker result missing finite score")?;
            if index >= scores.len() || scores[index].is_some() {
                return Err("invalid reranker result index".into());
            }
            scores[index] = Some(score);
        }
        Ok(scores.into_iter().flatten().collect())
    }

    async fn window(&self, request: Request<'_>) -> Result<Arc<Window>, String> {
        let Request {
            solr,
            database,
            query,
            sources,
            filters,
            ..
        } = request;
        let started = Instant::now();
        let (keyword, neighbours) = tokio::join!(
            solr.search(query, sources, filters, CANDIDATES, 0, SortOrder::Relevance),
            self.neighbours(query, sources, filters),
        );
        let mut keyword = keyword?;
        let neighbours = neighbours?;
        let mut hits = std::mem::take(&mut keyword.hits);
        let consumed = hits.len();
        let keyword_ids: HashSet<String> = hits.iter().map(|hit| hit.id.clone()).collect();
        let mut scores: HashMap<String, f64> = HashMap::new();
        for (rank, hit) in hits.iter().enumerate() {
            scores.insert(hit.id.clone(), 1.0 / (60.0 + rank as f64));
        }
        if !neighbours.parents.is_empty() {
            // Only the current main index can admit a related passage. This
            // also blocks stale ownership/tags and removed sources immediately.
            let allowed = solr
                .filtered_ids(&neighbours.parents, sources, filters)
                .await?;
            let allowed_ids: HashSet<_> = allowed.hits.iter().map(|h| h.id.clone()).collect();
            for (rank, id) in neighbours
                .parents
                .iter()
                .enumerate()
                .filter(|(_, id)| allowed_ids.contains(*id))
            {
                *scores.entry(id.clone()).or_default() += 1.0 / (60.0 + rank as f64);
            }
            for hit in allowed.hits {
                if !keyword_ids.contains(&hit.id) {
                    hits.push(hit);
                }
            }
        }
        let retrieved = started.elapsed();
        // Pin exact recovery matches before pagination, not just within each
        // displayed page. Read identifiers only, without loading every body.
        let all_ids: Vec<_> = hits.iter().map(|h| h.id.clone()).collect();
        let identifier_rows = database
            .query(
                "SELECT id, metadata->'identifiers' FROM documents WHERE id=ANY($1)",
                &[&all_ids],
            )
            .await
            .map_err(|e| e.to_string())?;
        let identifiers: HashMap<String, Value> = identifier_rows
            .into_iter()
            .map(|row| {
                (
                    row.get(0),
                    row.get::<_, Option<Value>>(1).unwrap_or(Value::Null),
                )
            })
            .collect();
        // Tiers up to 2 name the query in an identifier or the title.
        let evidence_tier: HashMap<_, _> = hits
            .iter()
            .map(|hit| {
                let metadata = json!({"identifiers": identifiers.get(&hit.id)});
                (
                    hit.id.clone(),
                    crate::relevance::quality(&hit.title, &metadata, "", query),
                )
            })
            .collect();
        let priority: HashMap<_, _> = evidence_tier
            .iter()
            .map(|(id, tier)| (id.clone(), (*tier).min(2)))
            .collect();
        hits.sort_by(|a, b| {
            priority[&a.id].cmp(&priority[&b.id]).then_with(|| {
                scores[&b.id]
                    .total_cmp(&scores[&a.id])
                    .then(a.id.cmp(&b.id))
            })
        });
        let head: Vec<_> = hits
            .iter()
            .take(RERANK_DOCS)
            .map(|h| h.id.clone())
            .collect();
        let documents: HashMap<_, _> = db::documents_by_ids(database, &head)
            .await?
            .into_iter()
            .collect();
        // Every document's strongest evidence is read before any document's
        // second passage, so a deadline costs depth rather than coverage.
        let mut evidence: [Vec<(&String, &str)>; 2] = [Vec::new(), Vec::new()];
        for id in &head {
            let Some(record) = documents.get(id) else {
                continue;
            };
            let expected = crate::timeutil::sha256_hex(&[id, &record.checksum, VERSION]);
            let related = neighbours
                .spans
                .get(id)
                .into_iter()
                .flatten()
                .filter(|(_, _, generation)| generation == &expected)
                .filter_map(|&(start, end, _)| record.body_text.get(start..end));
            let worded = lexical_passages(&record.body_text, query);
            // A keyword match is judged first on the words the user typed; a
            // related passage is all the evidence a document without them has.
            let ordered: Vec<&str> = if keyword_ids.contains(id) {
                worded.into_iter().chain(related).collect()
            } else {
                related.chain(worded).collect()
            };
            let mut chosen: Vec<&str> = Vec::new();
            for text in ordered {
                if chosen.len() < 2 && !chosen.contains(&text) {
                    chosen.push(text);
                }
            }
            for (round, text) in chosen.into_iter().enumerate() {
                evidence[round].push((id, text));
            }
        }
        let queue: Vec<(&String, &str)> = evidence.into_iter().flatten().collect();
        let deadline = tokio::time::Instant::now() + RERANK_BUDGET;
        let reranking = Instant::now();
        let mut scored: u32 = 0;
        let mut reranked: HashMap<String, f64> = HashMap::new();
        let mut snippets = HashMap::new();
        for chunk in queue.chunks(RERANK_CHUNK) {
            // A request that cannot finish in time would only delay the answer.
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if scored > 0 && remaining < reranking.elapsed() / scored * chunk.len() as u32 {
                break;
            }
            let titled: Vec<String> = chunk
                .iter()
                .map(|(id, text)| passage_input(&documents[*id].title, text))
                .collect();
            let relevance =
                match tokio::time::timeout_at(deadline, self.rerank(query, &titled)).await {
                    Ok(Ok(relevance)) => relevance,
                    // Scores are per passage, so those already returned stand.
                    Ok(Err(error)) if scored > 0 => {
                        eprintln!("search: reranking stopped early: {error}");
                        break;
                    }
                    Ok(Err(error)) => return Err(error),
                    Err(_) => break,
                };
            for ((id, text), score) in chunk.iter().zip(relevance) {
                scored += 1;
                if reranked.get(*id).is_none_or(|previous| score > *previous) {
                    reranked.insert((*id).clone(), score);
                    if let Some(snippet) = crate::text::result_snippet(text, query) {
                        snippets.insert((*id).clone(), snippet);
                    }
                }
            }
        }
        if scored == 0 && !queue.is_empty() {
            return Err("the reranker did not answer within its budget".into());
        }
        let candidates = hits.len();
        hits.retain(|hit| {
            // Deleted since it was indexed.
            if head.contains(&hit.id) && !documents.contains_key(&hit.id) {
                return false;
            }
            // Without the user's words, only a passage the reranker read and
            // judged relevant belongs in the results.
            keyword_ids.contains(&hit.id)
                || reranked
                    .get(&hit.id)
                    .is_some_and(|score| *score >= ADMIT_SCORE)
        });
        // Read and kept, then not yet read, then read and rejected. A title
        // that names the query is never rejected on one passage of its text.
        let standing = |hit: &SearchHit| match reranked.get(&hit.id) {
            Some(score) if *score >= REJECT_SCORE || evidence_tier[&hit.id] <= 2 => 0,
            None => 1,
            Some(_) => 2,
        };
        hits.sort_by(|a, b| {
            priority[&a.id]
                .cmp(&priority[&b.id])
                .then(standing(a).cmp(&standing(b)))
                .then_with(|| match (reranked.get(&a.id), reranked.get(&b.id)) {
                    (Some(a), Some(b)) => b.total_cmp(a),
                    _ => scores[&b.id].total_cmp(&scores[&a.id]),
                })
                .then(a.id.cmp(&b.id))
        });
        // Signatures deduplicate copies across keyword and related retrieval.
        let mut signatures: HashMap<String, (usize, u64)> = HashMap::new();
        let mut unique: Vec<SearchHit> = Vec::new();
        for hit in hits {
            if !hit.dedupe.is_empty() {
                if let Some((index, members)) = signatures.get_mut(&hit.dedupe) {
                    *members += 1;
                    unique[*index].copies = unique[*index].copies.max(hit.copies).max(*members - 1);
                    continue;
                }
                signatures.insert(hit.dedupe.clone(), (unique.len(), 1));
            }
            unique.push(hit);
        }
        // Durations and counts only: queries are private.
        eprintln!(
            "search: ranked library results retrieval_ms={} keyword={consumed} related={} rerank_ms={} passages={scored}/{} results={}",
            retrieved.as_millis(),
            candidates - consumed,
            reranking.elapsed().as_millis(),
            queue.len(),
            unique.len(),
        );
        Ok(Arc::new(Window {
            hits: unique,
            snippets,
            keyword,
            consumed,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::lexical_passages;

    #[test]
    fn reranking_reads_cultivation_instead_of_late_keyword_mentions() {
        // "Growing potatoes" relevance regressed twice: first through scattered
        // document terms, then because rollout selected a late poultry chapter
        // instead of the gardening manual's cultivation passages.
        let cultivation = "Potato crops grow in loose soil. Plant seed tubers in rows and hill soil around the stems. ".repeat(50);
        let poultry = format!(
            "{} Growing hens can eat potatoes as part of their feed.",
            "Keep the hens in a fenced yard. ".repeat(50)
        );
        let body = format!("{cultivation}\n{poultry}");
        let passages = lexical_passages(&body, "growing potatoes");
        assert!(passages[0].contains("Plant seed tubers"));
        assert!(!passages[0].contains("Growing hens"));
    }
}
