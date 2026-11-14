//! Local semantic retrieval. Text stays in Postgres; Solr holds vectors and
//! byte offsets only. Inference services are loopback-only llama.cpp servers.
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio_postgres::Client;

use crate::db;
use crate::solr::{SearchFilters, SearchResponse, SolrClient, SolrDocument, SortOrder};

const DIMENSIONS: usize = 2560;
const VERSION: &str = "qwen4b-f16-e8b4e85c-passage-v1";
const CANDIDATES: usize = 100;
const RERANK_DOCS: usize = 40;
const PASSAGE_BYTES: usize = 1600;
const OVERLAP_BYTES: usize = 200;
const INDEX_BATCH_SIZE: usize = 1;

type QueryCache = std::sync::Arc<tokio::sync::Mutex<HashMap<String, (Instant, Vec<f32>)>>>;

#[derive(Clone)]
pub(crate) struct Semantic {
    http: reqwest::Client,
    query_url: String,
    rerank_url: String,
    core_url: String,
    query_cache: QueryCache,
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
            query_cache: Default::default(),
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

    async fn query_vector(&self, query: &str) -> Result<Vec<f32>, String> {
        {
            let cache = self.query_cache.lock().await;
            if let Some((_, vector)) = cache
                .get(query)
                .filter(|(when, _)| when.elapsed() < Duration::from_secs(600))
            {
                return Ok(vector.clone());
            }
        }
        let input = format!("Instruct: Given a library search query, retrieve relevant passages that address the user's request\nQuery: {query}");
        let vector = self
            .embed(&self.query_url, &[input], Duration::from_secs(90))
            .await?
            .remove(0);
        let mut cache = self.query_cache.lock().await;
        if cache.len() >= 128 {
            cache.clear();
        }
        cache.insert(query.into(), (Instant::now(), vector.clone()));
        Ok(vector)
    }
}

/// UTF-8 byte offsets with bounded paragraph-aware overlap. A title-only
/// catalog record still gets one passage; no long-book prefix truncation.
fn passages(body: &str) -> Vec<(usize, usize)> {
    if body.is_empty() {
        return vec![(0, 0)];
    }
    let mut spans = Vec::new();
    let mut start = 0;
    while start < body.len() {
        let max_end = body.floor_char_boundary((start + PASSAGE_BYTES).min(body.len()));
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
        let overlap = body.floor_char_boundary(end.saturating_sub(OVERLAP_BYTES));
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

/// Before vector backfill reaches a book, retain its strongest lexical
/// passages, including grammatical forms. A last-match tie can otherwise
/// present an unrelated chapter to the reranker and hide the useful section.
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
    let mut candidates: Vec<_> = passages(body)
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
    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.1));
    candidates
        .into_iter()
        .take(2)
        .map(|(text, _)| text)
        .collect()
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
    let pending_sql = "SELECT d.id FROM documents d LEFT JOIN semantic_documents s ON s.document_id=d.id
        WHERE d.source_id=ANY($1) AND (s.document_id IS NULL OR s.checksum<>d.checksum OR s.version<>$2)
        ORDER BY d.id LIMIT 8";
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

pub(crate) struct Request<'a> {
    pub solr: &'a SolrClient,
    pub database: &'a Client,
    pub query: &'a str,
    pub sources: &'a [String],
    pub filters: &'a SearchFilters,
    pub rows: usize,
    pub offset: usize,
}

pub(crate) struct Ranked {
    pub response: SearchResponse,
    pub snippets: HashMap<String, String>,
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

impl Semantic {
    /// A bounded hybrid result window: keyword and semantic candidates are
    /// fused by rank, not incompatible raw score magnitudes. All pages slice
    /// the same deterministic window; counts describe that window, not the
    /// number of semantically relevant documents in the entire library.
    pub(crate) async fn search(&self, request: Request<'_>) -> Result<Ranked, String> {
        let Request {
            solr,
            database,
            query,
            sources,
            filters,
            rows,
            offset,
        } = request;
        let vector = self.query_vector(query).await?;
        let vector_query = format!(
            "{{!knn f=vector topK=1000}}{}",
            serde_json::to_string(&vector).map_err(|e| e.to_string())?
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
        let (lexical, semantic) = tokio::join!(
            solr.search(query, sources, filters, CANDIDATES, 0, SortOrder::Relevance),
            self.select(params),
        );
        let mut response = lexical?;
        let semantic = semantic?;
        let vectors = semantic["response"]["docs"]
            .as_array()
            .ok_or("passage response missing docs")?;
        // An empty core is not semantic coverage. Keep ordinary keyword paging
        // and counts during initial backfill rather than truncating the library.
        if vectors.is_empty() {
            return Err("the semantic passage index has no matching passages yet".into());
        }
        let mut candidates: Vec<String> = Vec::new();
        let mut spans: HashMap<String, Vec<(usize, usize, String)>> = HashMap::new();
        for hit in vectors {
            let Some(id) = hit["parent_s"].as_str() else {
                continue;
            };
            if !spans.contains_key(id) {
                if candidates.len() >= CANDIDATES {
                    continue;
                }
                candidates.push(id.into());
            }
            let entries = spans.entry(id.into()).or_default();
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
        // Only the current main index can admit a semantic candidate. This
        // also blocks stale ownership/tags and removed sources immediately.
        let allowed = solr.filtered_ids(&candidates, sources, filters).await?;
        let mut scores: HashMap<String, f64> = HashMap::new();
        for (rank, hit) in response.hits.iter().enumerate() {
            scores.insert(hit.id.clone(), 1.0 / (60.0 + rank as f64));
        }
        let allowed_ids: HashSet<_> = allowed.hits.iter().map(|h| h.id.clone()).collect();
        for (rank, id) in candidates
            .iter()
            .enumerate()
            .filter(|(_, id)| allowed_ids.contains(*id))
        {
            *scores.entry(id.clone()).or_default() += 1.0 / (60.0 + rank as f64);
        }
        let mut known: HashSet<_> = response.hits.iter().map(|h| h.id.clone()).collect();
        for hit in allowed.hits {
            if known.insert(hit.id.clone()) {
                response.hits.push(hit);
            }
        }
        // Pin exact recovery matches before pagination, not just within each
        // displayed page. Read identifiers only, without loading every body.
        let all_ids: Vec<_> = response.hits.iter().map(|h| h.id.clone()).collect();
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
        let priority: HashMap<_, _> = response
            .hits
            .iter()
            .map(|hit| {
                let metadata = json!({"identifiers": identifiers.get(&hit.id)});
                (
                    hit.id.clone(),
                    crate::relevance::quality(&hit.title, &metadata, "", query).min(2),
                )
            })
            .collect();
        response.hits.sort_by(|a, b| {
            priority[&a.id].cmp(&priority[&b.id]).then_with(|| {
                scores[&b.id]
                    .total_cmp(&scores[&a.id])
                    .then(a.id.cmp(&b.id))
            })
        });
        let ids: Vec<_> = response
            .hits
            .iter()
            .take(RERANK_DOCS)
            .map(|h| h.id.clone())
            .collect();
        let documents: HashMap<_, _> = db::documents_by_ids(database, &ids)
            .await?
            .into_iter()
            .collect();
        let mut inputs = Vec::new();
        let mut owners = Vec::new();
        let mut contexts = Vec::new();
        for hit in response.hits.iter().take(RERANK_DOCS) {
            let Some(record) = documents.get(&hit.id) else {
                continue;
            };
            let expected = crate::timeutil::sha256_hex(&[&hit.id, &record.checksum, VERSION]);
            let mut texts: Vec<&str> = spans
                .get(&hit.id)
                .into_iter()
                .flatten()
                .filter(|(_, _, generation)| generation == &expected)
                .filter_map(|&(start, end, _)| record.body_text.get(start..end))
                .collect();
            // Give both retrieval methods a chance to supply evidence while
            // keeping the same two-passage budget per document.
            let lexical = lexical_passages(&record.body_text, query);
            if let Some(best) = lexical.first()
                && !texts.contains(best)
            {
                texts.insert(texts.len().min(1), best);
            }
            for text in lexical {
                if texts.len() >= 2 {
                    break;
                }
                if !texts.contains(&text) {
                    texts.push(text);
                }
            }
            texts.truncate(2);
            for text in texts {
                inputs.push(passage_input(&record.title, text));
                owners.push(hit.id.clone());
                contexts.push(text.to_string());
            }
        }
        if inputs.is_empty() {
            return Err("no current passages are available to rerank".into());
        }
        // The endpoint formats Qwen's trained query/document template; no
        // generated answer text or probability interpretation is involved.
        let ranked = self
            .post(
                &format!("{}/v1/rerank", self.rerank_url),
                &json!({"query":query, "documents":inputs, "top_n":inputs.len()}),
            )
            .await?;
        let ranked = ranked["results"]
            .as_array()
            .ok_or("reranker response missing results")?;
        if ranked.len() != inputs.len() {
            return Err("reranker returned an incomplete result set".into());
        }
        let mut seen = HashSet::new();
        let mut reranked: HashMap<String, f64> = HashMap::new();
        let mut snippets = HashMap::new();
        for item in ranked {
            let index = item["index"]
                .as_u64()
                .ok_or("reranker result missing index")? as usize;
            let score = item["relevance_score"]
                .as_f64()
                .filter(|s| s.is_finite())
                .ok_or("reranker result missing finite score")?;
            if index >= owners.len() || !seen.insert(index) {
                return Err("invalid reranker result index".into());
            }
            let id = &owners[index];
            if reranked.get(id).is_none_or(|previous| score > *previous) {
                reranked.insert(id.clone(), score);
                if let Some(snippet) = crate::text::result_snippet(&contexts[index], query) {
                    snippets.insert(id.clone(), snippet);
                }
            }
        }
        response
            .hits
            .retain(|h| !ids.contains(&h.id) || documents.contains_key(&h.id));
        response.hits.sort_by(|a, b| {
            priority[&a.id]
                .cmp(&priority[&b.id])
                .then_with(|| match (reranked.get(&a.id), reranked.get(&b.id)) {
                    (Some(a), Some(b)) => b.total_cmp(a),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => scores[&b.id].total_cmp(&scores[&a.id]),
                })
                .then(a.id.cmp(&b.id))
        });
        // Signatures deduplicate copies across lexical and semantic retrieval.
        let mut signatures: HashMap<String, (usize, u64)> = HashMap::new();
        let mut unique: Vec<crate::solr::SearchHit> = Vec::new();
        for hit in response.hits {
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
        response.hits = unique;
        response.relaxed = false;
        response.related_terms.clear();
        response.unknown_terms.clear();
        response.total = response.hits.len() as u64;
        response.hits = response.hits.into_iter().skip(offset).take(rows).collect();
        // Lexical facets remain lexical counts; the caller labels the bounded
        // semantic window explicitly rather than claiming exhaustive facets.
        Ok(Ranked { response, snippets })
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
