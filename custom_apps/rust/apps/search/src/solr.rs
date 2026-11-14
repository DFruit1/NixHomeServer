use std::time::Duration;

use serde_json::{json, Value};

use crate::db;
use crate::facets;
use crate::retry;
use crate::timeutil::epoch_to_solr_date;

/// Attempts per Solr HTTP operation. Solr restarts and brief network blips are
/// common on a home server; retrying an idempotent add/delete avoids throwing
/// away a long extraction pass.
const SOLR_ATTEMPTS: u32 = 4;
/// Bound on how many ids one delete request may carry, so a source that is
/// emptied wholesale cannot build a multi-megabyte request body.
const SOLR_DELETE_CHUNK: usize = 1000;
/// Solr soft-commit horizon for streaming adds/deletes. Batches coalesce into
/// one commit instead of imposing a hard commit per batch; the indexer issues
/// one explicit hard commit once a source has finished syncing.
const SOLR_COMMIT_WITHIN_MS: u64 = 10_000;

/// One document rendered for the Solr index.
///
/// The body is sent for full-text indexing only; the Solr schema stores it
/// `stored="false"` so the authoritative copy lives solely in Postgres. Solr
/// holds the inverted index, and snippets are rebuilt from Postgres at query
/// time. The full per-key metadata bag also stays in Postgres. Bounded
/// discovery text and normalised facets (owner, author, tag, series, year)
/// are projected into dynamic fields for discovery, filtering and faceting.
#[derive(Debug, Clone)]
pub struct SolrDocument {
    pub id: String,
    pub source: String,
    /// Extract-kind (email, web-page, book, …). Indexed as `kind_s` so the UI
    /// can filter results by the sort of thing a document is; the `_s` dynamic
    /// field in the stock configset already provides the definition.
    pub kind: String,
    pub title: String,
    pub body: String,
    pub discovery: String,
    pub content_type: String,
    pub origin_url: String,
    pub app_url: String,
    pub file_path: String,
    pub size_bytes: i64,
    pub content_created: Option<i64>,
    pub content_modified: Option<i64>,
    /// Owning user for per-user sources, or a shared sentinel for collections
    /// with no per-user ownership. Indexed as `owner_s` for filtering/faceting.
    pub owner: String,
    /// Normalised cross-source facets indexed as `author_ss`, `tag_ss`,
    /// `series_ss`, and `year_i` for filtering/faceting.
    pub authors: Vec<String>,
    pub tags: Vec<String>,
    pub series: Vec<String>,
    pub year: Option<i64>,
    /// Content signature indexed as `dedupe_s`. Identical items filed in
    /// several places (one message in three mail folders) share a signature,
    /// so a search shows one result for them instead of a page of copies.
    pub dedupe: String,
}

/// Everyday words for a kind of content, indexed as discovery text so "billy
/// connolly movie" or "pdf manual" matches without the user knowing the filter.
fn kind_words(kind: &str, content_type: &str) -> &'static str {
    match (kind, content_type) {
        ("movie", _) => "movie film video",
        ("episode", _) => "episode tv television show series video",
        ("video", _) => "video",
        ("audiobook", _) => "audiobook audio book",
        ("book", "application/pdf") => "book ebook pdf",
        ("book", "application/epub+zip") => "book ebook epub",
        ("book", _) => "book ebook",
        ("email", _) => "email mail message",
        ("feed-entry", _) => "article feed post news",
        ("web-page", _) => "web page website article",
        ("web-crawl", _) => "web archive crawl capture",
        ("zim-archive", _) => "wiki offline archive collection",
        ("zim-article", _) => "wiki article",
        ("document", "application/pdf") => "document pdf",
        ("document", _) => "document",
        (_, "application/pdf") => "pdf",
        _ => "",
    }
}

/// Splits a file or folder name into searchable words. Release names join
/// words with dots and underscores, which the index would keep as one token.
fn name_words(name: &str) -> String {
    name.replace(['_', '-', '.', '[', ']', '(', ')', '{', '}'], " ")
}

impl SolrDocument {
    pub fn from_record(source_id: &str, record: &db::DocumentRecord, owner: &str) -> Self {
        let extracted = facets::extract(&record.metadata, record.content_created_at);
        // Rebuilds also project metadata from older records whose body predates
        // metadata enrichment. Never index URL credentials/query strings or full
        // filesystem paths; only the basename is useful for ordinary discovery.
        let path = std::path::Path::new(&record.file_path);
        let filename = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        let mut discovery = format!("{filename}\n{}", name_words(filename));
        // A library-relative path names the author, series or album in its
        // folders. Absolute paths stay private: they describe the server.
        if path.is_relative() {
            for folder in path
                .parent()
                .into_iter()
                .flat_map(std::path::Path::components)
                .filter_map(|part| part.as_os_str().to_str())
                .take(8)
            {
                discovery.push_str(&format!("\n{}", name_words(folder)));
            }
        }
        if let Ok(url) = url::Url::parse(&record.origin_url)
            && let Some(host) = url.host_str()
        {
            discovery.push_str(&format!("\n{host}"));
        }
        let words = kind_words(&record.kind, &record.content_type);
        if !words.is_empty() {
            discovery.push_str(&format!("\n{words}"));
        }
        if record
            .metadata
            .get("attachments")
            .is_some_and(|value| value.as_array().is_some_and(|items| !items.is_empty()))
        {
            discovery.push_str("\nattachment attachments attached");
        }
        crate::extract::append_search_metadata(&mut discovery, &record.metadata);
        let created = record
            .content_created_at
            .map(|value| value.to_string())
            .unwrap_or_default();
        let dedupe = crate::timeutil::sha256_hex(&[
            &record.kind,
            &record.title.trim().to_lowercase(),
            &created,
            &record.body_text,
        ]);
        Self {
            dedupe,
            id: db::full_document_id(source_id, &record.external_id),
            source: source_id.to_string(),
            kind: record.kind.clone(),
            title: record.title.clone(),
            body: record.body_text.clone(),
            discovery,
            content_type: record.content_type.clone(),
            origin_url: record.origin_url.clone(),
            app_url: record.app_url.clone(),
            file_path: record.file_path.clone(),
            size_bytes: record.size_bytes,
            content_created: record.content_created_at,
            content_modified: record.content_modified_at,
            owner: owner.to_string(),
            authors: extracted.authors,
            tags: extracted.tags,
            series: extracted.series,
            year: extracted.year,
        }
    }

    pub(crate) fn to_solr_json(&self) -> Value {
        let mut doc = json!({
            "id": self.id,
            "source": self.source,
            "kind_s": self.kind,
            "title": self.title,
            "body": self.body,
            "discovery_txt": self.discovery,
            "content_type": self.content_type,
            "origin_url": self.origin_url,
            "app_url": self.app_url,
            "file_path": self.file_path,
            "size_bytes": self.size_bytes,
            "dedupe_s": self.dedupe,
        });
        if let Some(created) = self.content_created {
            doc["content_created"] = json!(epoch_to_solr_date(created));
        }
        if let Some(modified) = self.content_modified {
            doc["content_modified"] = json!(epoch_to_solr_date(modified));
        }
        if !self.owner.is_empty() {
            doc["owner_s"] = json!(self.owner);
        }
        // Dynamic fields (defined by the stock `_default` configset) keep the
        // facet vocabulary out of the managed schema, so adding a dimension
        // never requires a configset rebuild.
        if !self.authors.is_empty() {
            doc["author_ss"] = json!(self.authors);
        }
        if !self.tags.is_empty() {
            doc["tag_ss"] = json!(self.tags);
        }
        if !self.series.is_empty() {
            doc["series_ss"] = json!(self.series);
        }
        if let Some(year) = self.year {
            doc["year_i"] = json!(year);
        }
        doc
    }
}

#[derive(Debug)]
pub struct SearchHit {
    pub id: String,
    pub kind: String,
    pub source: String,
    pub title: String,
    pub origin_url: String,
    pub app_url: String,
    pub content_type: String,
    pub owner: String,
    pub score: f64,
    pub created: Option<i64>,
    /// Identical copies folded into this result.
    pub copies: u64,
}

#[derive(Debug)]
pub struct SearchResponse {
    pub hits: Vec<SearchHit>,
    pub total: u64,
    /// Related wording that was searched and exists in the library.
    pub related_terms: Vec<String>,
    /// Query words the library does not contain in any form; close spellings
    /// were searched for these instead.
    pub unknown_terms: Vec<String>,
    /// Nothing contained every idea, so these results match most of them.
    pub relaxed: bool,
    pub source_facets: Vec<(String, u64)>,
    pub kind_facets: Vec<(String, u64)>,
    pub content_type_facets: Vec<(String, u64)>,
    pub owner_facets: Vec<(String, u64)>,
    pub author_facets: Vec<(String, u64)>,
    pub tag_facets: Vec<(String, u64)>,
    pub series_facets: Vec<(String, u64)>,
    pub year_facets: Vec<(String, u64)>,
}

/// Admin-selected filters applied to the Solr query. Every field is optional;
/// an unset filter does not constrain results.
#[derive(Debug, Clone, Default)]
pub struct SearchFilters {
    pub matching: MatchMode,
    /// Set by the server only when a wiki source or page filter is selected.
    pub wiki_full_text: bool,
    pub source: Option<String>,
    pub kind: Option<String>,
    pub content_type: Option<String>,
    pub owner: Option<String>,
    pub author: Option<String>,
    pub creator: Option<String>,
    pub tag: Option<String>,
    pub series: Option<String>,
    pub year: Option<i64>,
    /// Inclusive lower/upper bounds, `YYYY-MM-DD`, on `content_created`.
    pub created_after: Option<String>,
    pub created_before: Option<String>,
}

impl SearchFilters {
    pub fn matches_kind(&self, kind: &str) -> bool {
        self.kind
            .as_deref()
            .is_none_or(|selected| kind_terms(selected).contains(&kind))
    }

    /// Builds the Solr `fq` clauses for the selected filters.
    fn clauses(&self, selected_sources: &[String]) -> Vec<String> {
        let mut clauses = Vec::new();
        // This constraint must survive facet exclusion and a hand-edited source
        // filter. Removed/unregistered sources are never part of this search.
        if selected_sources.is_empty() {
            clauses.push("(*:* AND -(*:*))".to_string());
        } else {
            let allowed = selected_sources
                .iter()
                .map(|source| solr_string_term(source))
                .collect::<Vec<_>>()
                .join(" OR ");
            clauses.push(format!("source:({allowed})"));
        }
        if let Some(source) = &self.source {
            clauses.push(format!("{{!tag=src}}source:{}", solr_string_term(source)));
        }
        if let Some(kind) = &self.kind {
            let terms = kind_terms(kind);
            let term = if terms.len() == 1 {
                solr_string_term(terms[0])
            } else {
                format!(
                    "({})",
                    terms
                        .iter()
                        .map(|term| solr_string_term(term))
                        .collect::<Vec<_>>()
                        .join(" OR ")
                )
            };
            clauses.push(format!("{{!tag=kind}}kind_s:{term}"));
        }
        if let Some(content_type) = &self.content_type {
            clauses.push(format!(
                "{{!tag=ct}}content_type:{}",
                solr_string_term(content_type)
            ));
        }
        if let Some(owner) = &self.owner {
            clauses.push(format!("{{!tag=own}}owner_s:{}", solr_string_term(owner)));
        }
        if let Some(author) = &self.author {
            clauses.push(format!(
                "{{!tag=auth}}author_ss:{}",
                solr_string_term(author)
            ));
        }
        if let Some(creator) = &self.creator {
            // Facets are already indexed, so partial creator/sender matching
            // needs no new schema or corpus rebuild. Escape every regex literal.
            let mut expression = String::new();
            for ch in creator.chars() {
                let variants: std::collections::BTreeSet<_> =
                    [ch.to_lowercase().to_string(), ch.to_uppercase().to_string()]
                        .into_iter()
                        .filter(|variant| {
                            variant.chars().count() == 1
                                || variant == &ch.to_lowercase().to_string()
                        })
                        .collect();
                let variants: Vec<_> = variants
                    .into_iter()
                    .map(|word| {
                        word.chars()
                            .map(|c| {
                                if c.is_alphanumeric() || c == ' ' {
                                    c.to_string()
                                } else {
                                    format!("\\{c}")
                                }
                            })
                            .collect::<String>()
                    })
                    .collect();
                expression.push_str(&format!("({})", variants.join("|")));
            }
            clauses.push(format!("author_ss:/.*{expression}.*/"));
        }
        if let Some(tag) = &self.tag {
            clauses.push(format!("{{!tag=tag}}tag_ss:{}", solr_string_term(tag)));
        }
        if let Some(series) = &self.series {
            clauses.push(format!(
                "{{!tag=ser}}series_ss:{}",
                solr_string_term(series)
            ));
        }
        if let Some(year) = self.year {
            clauses.push(format!("{{!tag=yr}}year_i:{year}"));
        }
        if self.created_after.is_some() || self.created_before.is_some() {
            let lower = self
                .created_after
                .as_ref()
                .map(|date| format!("{date}T00:00:00Z"))
                .unwrap_or_else(|| "*".to_string());
            let upper = self
                .created_before
                .as_ref()
                .map(|date| format!("{date}T23:59:59.999Z"))
                .unwrap_or_else(|| "*".to_string());
            clauses.push(format!("content_created:[{lower} TO {upper}]"));
        }
        clauses
    }
}

fn kind_terms(kind: &str) -> Vec<&str> {
    match kind {
        "video" => vec!["video", "movie", "episode"],
        "web-page" => vec!["web-page", "feed-entry"],
        _ => vec![kind],
    }
}

fn solr_string_term(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Result ordering chosen by the user. Relevance uses Solr's score order;
/// Newest orders by the document's content date so the most recent material
/// surfaces first regardless of score.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SortOrder {
    #[default]
    Relevance,
    Newest,
    /// Asked for in words ("latest newsletter"): still ranked by relevance,
    /// with recency weighted heavily. A strict date order would put any item
    /// that merely mentions the word above the thing the user means.
    Recent,
}

impl SortOrder {
    /// Stable ordering prevents equal-score hits from moving between pages.
    fn clause(self) -> Option<&'static str> {
        match self {
            SortOrder::Relevance | SortOrder::Recent => Some("score desc, id asc"),
            // The unique id also breaks equal-date, equal-score ties.
            SortOrder::Newest => Some("content_created desc, score desc, id asc"),
        }
    }
}

pub struct SolrClient {
    http: reqwest::Client,
    base_url: String,
    core: String,
}

impl SolrClient {
    pub fn new(base_url: &str, core: &str) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .build()
                .expect("reqwest client"),
            base_url: base_url.trim_end_matches('/').to_string(),
            core: core.to_string(),
        }
    }

    pub fn core(&self) -> &str {
        &self.core
    }

    pub async fn core_status(&self, name: &str) -> Result<Option<String>, String> {
        let url = format!(
            "{}/admin/cores?action=STATUS&wt=json&core={}",
            self.base_url, name
        );
        let response: Value = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|err| format!("solr status request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr status response parse failed: {err}"))?;
        let status = response
            .pointer("/status")
            .and_then(Value::as_object)
            .ok_or_else(|| format!("unexpected solr status response: {response}"))?;
        Ok(status.get(name).map(|core| {
            core.get("state")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string()
        }))
    }

    /// Creates the search core from the default configset if it does not exist.
    pub async fn create_core(&self, config_set: &str) -> Result<(), String> {
        let mut url = format!(
            "{}/admin/cores?action=CREATE&name={}&wt=json",
            self.base_url, self.core
        );
        if !config_set.is_empty() {
            url.push_str(&format!("&configSet={config_set}"));
        }
        let response: Value = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|err| format!("solr core create request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr core create response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr refused to create core: {response}"));
        }
        Ok(())
    }

    pub async fn add_documents(&self, docs: &[SolrDocument]) -> Result<(), String> {
        if docs.is_empty() {
            return Ok(());
        }
        let payload: Vec<Value> = docs.iter().map(SolrDocument::to_solr_json).collect();
        let url = format!(
            "{}/{}/update?commitWithin={SOLR_COMMIT_WITHIN_MS}",
            self.base_url, self.core
        );
        retry::with_retry("solr add", SOLR_ATTEMPTS, || async {
            let response: Value = self
                .http
                .post(&url)
                .json(&json!({ "add": payload }))
                .send()
                .await
                .map_err(|err| format!("solr add request failed: {err}"))?
                .json()
                .await
                .map_err(|err| format!("solr add response parse failed: {err}"))?;
            if response.get("error").is_some() {
                return Err(format!("solr rejected document add: {response}"));
            }
            Ok(())
        })
        .await
    }

    /// Deletes documents by id, splitting the request into bounded chunks so a
    /// source whose whole document set disappears cannot push an unbounded body.
    pub async fn delete_ids(&self, ids: &[String]) -> Result<(), String> {
        for chunk in ids.chunks(SOLR_DELETE_CHUNK) {
            self.delete_ids_chunk(chunk).await?;
        }
        Ok(())
    }

    async fn delete_ids_chunk(&self, ids: &[String]) -> Result<(), String> {
        if ids.is_empty() {
            return Ok(());
        }
        let url = format!(
            "{}/{}/update?commitWithin={SOLR_COMMIT_WITHIN_MS}",
            self.base_url, self.core
        );
        let payload: Value = Value::Array(ids.iter().map(|id| json!({ "delete": id })).collect());
        retry::with_retry("solr delete", SOLR_ATTEMPTS, || async {
            let response: Value = self
                .http
                .post(&url)
                .json(&payload)
                .send()
                .await
                .map_err(|err| format!("solr delete request failed: {err}"))?
                .json()
                .await
                .map_err(|err| format!("solr delete response parse failed: {err}"))?;
            if response.get("error").is_some() {
                return Err(format!("solr rejected deletes: {response}"));
            }
            Ok(())
        })
        .await
    }

    pub async fn delete_by_source(&self, source: &str) -> Result<(), String> {
        let url = format!(
            "{}/{}/update?commitWithin={SOLR_COMMIT_WITHIN_MS}",
            self.base_url, self.core
        );
        let query = format!("source:{}", solr_string_term(source));
        retry::with_retry("solr delete-by-source", SOLR_ATTEMPTS, || async {
            let response: Value = self
                .http
                .post(&url)
                .json(&json!({ "delete": { "query": query } }))
                .send()
                .await
                .map_err(|err| format!("solr delete-by-source request failed: {err}"))?
                .json()
                .await
                .map_err(|err| format!("solr delete-by-source response parse failed: {err}"))?;
            if response.get("error").is_some() {
                return Err(format!("solr rejected delete-by-source: {response}"));
            }
            Ok(())
        })
        .await
    }

    /// Issues one explicit hard commit. Streaming adds/deletes use
    /// `commitWithin`, so the indexer calls this once per source (and once per
    /// completed rebuild) to make the pass durable without paying a hard commit
    /// on every batch.
    pub async fn commit(&self) -> Result<(), String> {
        let url = format!("{}/{}/update?commit=true", self.base_url, self.core);
        retry::with_retry("solr commit", SOLR_ATTEMPTS, || async {
            let response: Value = self
                .http
                .post(&url)
                .json(&json!({ "commit": {} }))
                .send()
                .await
                .map_err(|err| format!("solr commit request failed: {err}"))?
                .json()
                .await
                .map_err(|err| format!("solr commit response parse failed: {err}"))?;
            if response.get("error").is_some() {
                return Err(format!("solr rejected commit: {response}"));
            }
            Ok(())
        })
        .await
    }

    /// Returns how many documents Solr currently holds for a source. Used by
    /// the reconciler to detect drift between the authoritative Postgres copy
    /// and the derived Solr index.
    pub async fn document_count(&self, source: &str) -> Result<u64, String> {
        let url = format!("{}/{}/select", self.base_url, self.core);
        let params = [
            ("q", "*:*".to_string()),
            ("fq", format!("source:{}", solr_string_term(source))),
            ("rows", "0".to_string()),
            ("wt", "json".to_string()),
        ];
        retry::with_retry("solr count", SOLR_ATTEMPTS, || async {
            let response: Value = self
                .http
                .post(&url)
                .form(&params)
                .send()
                .await
                .map_err(|err| format!("solr count request failed: {err}"))?
                .json()
                .await
                .map_err(|err| format!("solr count response parse failed: {err}"))?;
            if response.get("error").is_some() {
                return Err(format!("solr rejected count query: {response}"));
            }
            response
                .pointer("/response/numFound")
                .and_then(Value::as_u64)
                .ok_or_else(|| format!("solr count response missing numFound: {response}"))
        })
        .await
    }

    /// How many documents contain each term in any searched text field.
    /// Terms the library lacks are simply absent from the result.
    async fn term_frequencies(
        &self,
        terms: &[String],
    ) -> Result<std::collections::HashMap<String, u64>, String> {
        let mut params: Vec<(&str, String)> = SEARCHED_TEXT_FIELDS
            .iter()
            .map(|field| ("terms.fl", (*field).to_string()))
            .collect();
        params.push(("terms.list", terms.join(",")));
        params.push(("terms.limit", "-1".to_string()));
        params.push(("omitHeader", "true".to_string()));
        params.push(("wt", "json".to_string()));
        let url = format!("{}/{}/terms", self.base_url, self.core);
        let response: Value = self
            .http
            .post(&url)
            .form(&params)
            .timeout(Duration::from_secs(4))
            .send()
            .await
            .map_err(|err| format!("solr term lookup failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr term lookup response parse failed: {err}"))?;
        let fields = response
            .get("terms")
            .and_then(Value::as_object)
            .ok_or_else(|| format!("solr term lookup returned no terms: {response}"))?;
        let mut frequencies = std::collections::HashMap::new();
        for counts in fields.values() {
            for (term, count) in facet_pairs(counts) {
                let known = frequencies.entry(term).or_insert(0);
                *known = (*known).max(count);
            }
        }
        Ok(frequencies)
    }

    /// Consults the library before expanding a plain query, so only wording it
    /// actually contains is searched and close spellings are tried solely for
    /// words it has never seen.
    async fn plan(&self, query: &str, filters: &SearchFilters) -> Option<Vec<PlannedConcept>> {
        if filters.matching != MatchMode::Broad {
            return None;
        }
        let concepts = crate::text::concepts(query)?;
        let mut terms: Vec<String> = Vec::new();
        for concept in &concepts {
            for term in std::iter::once(&concept.word)
                .chain(&concept.forms)
                .chain(&concept.related)
            {
                // The lookup takes a comma-separated list of plain terms.
                if !term.contains(',') && !terms.contains(term) {
                    terms.push(term.clone());
                }
            }
        }
        let frequencies = match self.term_frequencies(&terms).await {
            Ok(frequencies) => Some(frequencies),
            Err(err) => {
                eprintln!("search: {err}; searching without library term statistics");
                None
            }
        };
        Some(plan_concepts(&concepts, frequencies.as_ref()))
    }

    pub async fn search(
        &self,
        query: &str,
        selected_sources: &[String],
        filters: &SearchFilters,
        rows: usize,
        offset: usize,
        sort: SortOrder,
    ) -> Result<SearchResponse, String> {
        let plan = self.plan(query, filters).await;
        let request = SelectRequest {
            query,
            plan: plan.as_deref(),
            relaxed: false,
            selected_sources,
            filters,
            rows,
            offset,
            sort,
        };
        let response = match self.select(&request).await {
            Ok(response) => response,
            Err(err) => {
                // A user query can contain Lucene syntax characters (`:`, `[`,
                // an unbalanced quote, ...) that make Solr reject the whole
                // request. Retry once with every special character escaped so a
                // literal search still returns results instead of a 502.
                if !is_query_parse_error(&err) {
                    return Err(err);
                }
                let escaped = escape_lucene_query(query);
                if escaped == query {
                    return Err(err);
                }
                eprintln!("search: solr rejected the query; retrying with escaped terms");
                self.select(&SelectRequest {
                    query: &escaped,
                    plan: None,
                    ..request
                })
                .await?
            }
        };
        let mut response = parse_search_response(&response)?;
        if let Some(plan) = &plan {
            // Nothing holds every idea: show what holds most of them rather
            // than an empty page. Deterministic, so later pages agree.
            if response.total == 0 && plan.len() >= 2 {
                let relaxed = self
                    .select(&SelectRequest {
                        relaxed: true,
                        ..request
                    })
                    .await?;
                let relaxed = parse_search_response(&relaxed)?;
                if relaxed.total > 0 {
                    response = relaxed;
                    response.relaxed = true;
                }
            }
            if sort != SortOrder::Newest {
                response.related_terms = plan
                    .iter()
                    .flat_map(|concept| concept.related.iter().cloned())
                    .collect();
            }
            response.unknown_terms = plan
                .iter()
                .filter(|concept| concept.fuzzy)
                .map(|concept| concept.word.clone())
                .collect();
        }
        Ok(response)
    }

    /// Issues one Solr select and returns the raw response, surfacing a Solr
    /// error payload as an `Err` string so the caller can decide whether to
    /// retry with an escaped query.
    async fn select(&self, request: &SelectRequest<'_>) -> Result<Value, String> {
        let SelectRequest {
            query,
            plan,
            relaxed,
            selected_sources,
            filters,
            rows,
            offset,
            sort,
        } = *request;
        // Date order shows whatever matched, newest first, so only the user's
        // own words and their grammatical forms may admit a document.
        let precise = sort == SortOrder::Newest;
        let broad = plan.map(|plan| broad_query(plan, relaxed, precise));
        let main_query = broad
            .clone()
            .or_else(|| literal_reference_query(query))
            .unwrap_or_else(|| query.to_string());
        // A document that mentions each idea in a different, unrelated passage
        // is not really about the query. A related-passage query lets a mild
        // penalty demote those without removing them, as a strict proximity
        // filter would when a genuinely relevant long document discusses the
        // ideas in separate sections. A relaxed pass matches only some ideas,
        // so there is no complete set to keep together.
        let coherence = if precise || relaxed {
            None
        } else {
            plan.and_then(coherence_query)
        };
        let recency = format!(
            "sum(1,product({},recip(abs(ms(NOW/DAY,content_created)),3.16e-11,1,1)))",
            if sort == SortOrder::Recent {
                "4"
            } else {
                "0.1"
            }
        );
        let boost = coherence
            .as_ref()
            .map(|_| {
                format!(
                    "product(if(query($coherence),1,{}),{recency})",
                    INCOHERENT_SCORE_FACTOR
                )
            })
            .unwrap_or(recency);
        let mut params: Vec<(&str, String)> = vec![
            ("q", main_query.clone()),
            // Stored fields only; the body is index-only and is enriched from
            // Postgres after the query.
            (
                "fl",
                "id kind_s source title origin_url app_url content_type owner_s content_created dedupe_s score"
                    .to_string(),
            ),
            ("defType", "edismax".to_string()),
            ("qf", "title^6 body discovery_txt^2".to_string()),
            // Phrase boosts: documents whose title or body contains the query
            // terms adjacent (within the phrase slop `ps`) rank above documents
            // where the same terms appear scattered.
            ("pf", "title^8 body^2".to_string()),
            ("ps", "2".to_string()),
            ("qs", "0".to_string()),
            ("tie", "0.1".to_string()),
            // Between otherwise comparable matches, prefer the more recent:
            // up to +10% for something dated today, half of that after a
            // year, fading to nothing. Undated documents are unaffected.
            // "latest …" raises that to +400%, so recency dominates among
            // relevant matches without admitting irrelevant ones. A related
            // passage keeps its full score; a document whose ideas are only
            // scattered is demoted rather than excluded.
            ("boost", boost),
            ("rows", rows.to_string()),
            ("start", offset.to_string()),
            // Identical copies share a content signature; show the best one
            // and count the rest. Documents indexed before signatures existed
            // have none and are each kept.
            ("fq", "{!collapse field=dedupe_s nullPolicy=expand}".to_string()),
            ("expand", "true".to_string()),
            ("expand.rows", "0".to_string()),
            ("facet", "true".to_string()),
            ("facet.field", "{!ex=src}source".to_string()),
            ("facet.field", "{!ex=kind}kind_s".to_string()),
            ("facet.field", "{!ex=ct}content_type".to_string()),
            ("facet.field", "{!ex=own}owner_s".to_string()),
            ("facet.field", "{!ex=auth limit=12}author_ss".to_string()),
            ("facet.field", "{!ex=tag limit=12}tag_ss".to_string()),
            ("facet.field", "{!ex=ser limit=12}series_ss".to_string()),
            ("facet.field", "{!ex=yr limit=12}year_i".to_string()),
            ("facet.mincount", "1".to_string()),
            ("facet.limit", "50".to_string()),
            ("wt", "json".to_string()),
        ];
        if let Some(coherence) = coherence {
            params.push(("coherence", coherence));
        }
        if !filters.wiki_full_text {
            // Extracted fallback articles must follow the same title-only
            // scope as native archive searches. Keep other kinds unrestricted.
            params.push(("wikiTitleQuery", main_query));
            params.push(("fq", r#"{!lucene}(*:* AND -kind_s:"zim-article") OR _query_:"{!edismax qf=title pf=title v=$wikiTitleQuery}""#.to_string()));
        }
        // Explicit syntax (quotes, fields, boolean operators) keeps Solr's
        // normal semantics. Broad queries require each concept, with OR only
        // between alternatives for that concept.
        if let Some(plan) = plan {
            params.push(("q.op", "OR".to_string()));
            params.push((
                "mm",
                if relaxed {
                    relaxed_minimum(plan).to_string()
                } else {
                    "0".to_string()
                },
            ));
            // Reward containing every idea. This boost never admits a document
            // by itself; the related-passage penalty decides whether those
            // ideas look like one subject or scattered mentions.
            let coverage = plan
                .iter()
                .map(|concept| {
                    let direct = std::iter::once(&concept.word)
                        .chain(&concept.forms)
                        .flat_map(|term| field_terms(term, [12.0, 3.0, 4.0]));
                    let related = concept
                        .related
                        .iter()
                        .flat_map(|term| field_terms(term, [4.0, 1.0, 1.3]));
                    format!(
                        "({})",
                        direct.chain(related).collect::<Vec<_>>().join(" OR ")
                    )
                })
                .collect::<Vec<_>>()
                .join(" AND ");
            params.push(("primaryQuery", coverage));
            params.push(("bq", "{!lucene v=$primaryQuery}".to_string()));
            let words: Vec<&str> = plan.iter().map(|concept| concept.word.as_str()).collect();
            let phrase = words.join(" ");
            params.push((
                "bq",
                format!(
                    "title:{}~2^12 body:{}~2^3",
                    solr_string_term(&phrase),
                    solr_string_term(&phrase)
                ),
            ));
            // Nearby pairs still matter in longer conversational queries.
            for pair in words.windows(2) {
                let phrase = pair.join(" ");
                params.push((
                    "bq",
                    format!(
                        "title:{}~2^4 body:{}~2",
                        solr_string_term(&phrase),
                        solr_string_term(&phrase)
                    ),
                ));
            }
            // The same adjacency through another form or related word:
            // "water filters" also rewards "water filter" and "water filtration".
            let alternatives: Vec<Vec<&String>> = plan
                .iter()
                .map(|concept| {
                    std::iter::once(&concept.word)
                        .chain(&concept.forms)
                        .chain(&concept.related)
                        .take(3)
                        .collect()
                })
                .collect();
            let phrases = alternatives.windows(2).flat_map(|pair| {
                pair[0]
                    .iter()
                    .enumerate()
                    .flat_map(move |(left_index, left)| {
                        pair[1]
                            .iter()
                            .enumerate()
                            .filter(move |(right_index, _)| left_index != 0 || *right_index != 0)
                            .map(move |(_, right)| format!("{left} {right}"))
                    })
            });
            for phrase in phrases.take(24) {
                params.push((
                    "bq",
                    format!(
                        "title:{}~2^4 body:{}~2",
                        solr_string_term(&phrase),
                        solr_string_term(&phrase)
                    ),
                ));
            }
        } else if filters.matching == MatchMode::All {
            params.push(("q.op", "AND".to_string()));
        }
        if let Some(clause) = sort.clause() {
            params.push(("sort", clause.to_string()));
        }
        for clause in filters.clauses(selected_sources) {
            params.push(("fq", clause));
        }
        let url = format!("{}/{}/select", self.base_url, self.core);
        let response: Value = self
            .http
            .post(&url)
            .form(&params)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|err| format!("solr query failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr query response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr query rejected: {response}"));
        }
        Ok(response)
    }
}

/// Text fields a plain query searches, strongest first.
const SEARCHED_TEXT_FIELDS: [&str; 3] = ["title", "body", "discovery_txt"];

#[derive(Clone, Copy)]
struct SelectRequest<'a> {
    query: &'a str,
    plan: Option<&'a [PlannedConcept]>,
    /// Require most ideas instead of all of them.
    relaxed: bool,
    selected_sources: &'a [String],
    filters: &'a SearchFilters,
    rows: usize,
    offset: usize,
    sort: SortOrder,
}

/// One required idea of a plain query, after consulting the library.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PlannedConcept {
    word: String,
    forms: Vec<String>,
    related: Vec<String>,
    /// The library has neither the word nor another form of it, so it is most
    /// likely a misspelling: close spellings are searched as well.
    fuzzy: bool,
    /// Documents containing the word or a form of it, when known.
    frequency: Option<u64>,
}

/// Keeps only wording the library contains. Without statistics (a failed
/// lookup) fall back to a bounded expansion and tolerate close spellings
/// everywhere, which is what every plain query did before statistics existed.
fn plan_concepts(
    concepts: &[crate::text::Concept],
    frequencies: Option<&std::collections::HashMap<String, u64>>,
) -> Vec<PlannedConcept> {
    concepts
        .iter()
        .map(|concept| {
            let Some(frequencies) = frequencies else {
                return PlannedConcept {
                    word: concept.word.clone(),
                    forms: concept.forms.iter().take(3).cloned().collect(),
                    related: concept.related.iter().take(4).cloned().collect(),
                    fuzzy: true,
                    frequency: None,
                };
            };
            let count = |term: &String| frequencies.get(term).copied().unwrap_or(0);
            let known = |term: &&String| count(term) > 0;
            let forms: Vec<String> = concept.forms.iter().filter(known).cloned().collect();
            PlannedConcept {
                fuzzy: !known(&&concept.word) && forms.is_empty(),
                frequency: Some(forms.iter().map(count).fold(count(&concept.word), u64::max)),
                word: concept.word.clone(),
                forms,
                related: concept.related.iter().filter(known).cloned().collect(),
            }
        })
        .collect()
}

/// `field:"term"^weight` for each searched text field.
fn field_terms(term: &str, weights: [f32; 3]) -> impl Iterator<Item = String> + '_ {
    SEARCHED_TEXT_FIELDS
        .into_iter()
        .zip(weights)
        .map(move |(field, weight)| format!("{field}:{}^{weight}", solr_string_term(term)))
}

/// The idea a relaxed search keeps mandatory: the rarest one the library
/// knows. Rare words carry the meaning ("rumpole" in "rumpole season 7");
/// dropping one in favour of two common words returns noise.
fn relaxed_anchor(plan: &[PlannedConcept]) -> Option<usize> {
    plan.iter()
        .enumerate()
        .filter_map(|(index, concept)| Some((concept.frequency.filter(|count| *count > 0)?, index)))
        .min()
        .map(|(_, index)| index)
}

/// Optional ideas a relaxed search still requires, besides its anchor: none
/// for a short query, about half of a long one.
fn relaxed_minimum(plan: &[PlannedConcept]) -> usize {
    let optional = plan.len() - usize::from(relaxed_anchor(plan).is_some());
    match optional {
        0..=1 => usize::from(relaxed_anchor(plan).is_none()),
        2..=3 => 1,
        _ => optional / 2,
    }
}

/// Broad discovery is the default; strict searches remain available without
/// making users learn operators. Existing explicit syntax is never expanded.
#[derive(Debug, Clone, Copy, Default, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MatchMode {
    #[default]
    Broad,
    All,
}

/// One clause per idea: the word, then its other forms, then weaker matches
/// (close spellings, word beginnings, related wording). Every idea is required
/// unless `relaxed`, where the caller sets how many must match.
fn broad_query(plan: &[PlannedConcept], relaxed: bool, precise: bool) -> String {
    let anchor = if relaxed { relaxed_anchor(plan) } else { None };
    let clauses: Vec<String> = plan
        .iter()
        .enumerate()
        .map(|(index, concept)| {
            let word = &concept.word;
            let length = word.chars().count();
            let alphabetic = word.chars().all(char::is_alphabetic);
            let mut alternatives = vec![format!("{word}^4")];
            alternatives.extend(concept.forms.iter().map(|form| format!("{form}^3")));
            // Numeric identifiers stay literal.
            if concept.fuzzy && alphabetic && (4..=32).contains(&length) {
                alternatives.push(if length >= 8 {
                    format!("{word}~2^0.4")
                } else {
                    format!("{word}~1^0.4")
                });
            }
            if !precise {
                let base = crate::thesaurus::base_form(word);
                if alphabetic && (5..=32).contains(&base.chars().count()) {
                    alternatives.push(format!("{base}*^0.2"));
                }
                alternatives.extend(concept.related.iter().map(|term| format!("{term}^0.6")));
            }
            format!(
                "{}({})",
                if anchor == Some(index) { "+" } else { "" },
                alternatives.join(" OR ")
            )
        })
        .collect();
    clauses.join(if relaxed { " " } else { " AND " })
}

/// How many tokens apart two ideas may be and still read as one passage. This
/// spans a few sentences, so a book that discusses the subject in a paragraph
/// stays coherent, while a word in an unrelated chapter or glossary does not.
const COHERENCE_SLOP: usize = 50;

/// Score kept by a document whose query ideas are only scattered. It remains
/// visible so a long document that discusses the ideas in separate sections is
/// not lost, but it ranks behind documents that discuss them together.
const INCOHERENT_SCORE_FACTOR: f32 = 0.3;

/// Matches documents that discuss adjacent query ideas near each other. Used
/// only by the score penalty, never to admit a document. Adjacent pairs and
/// their two strongest forms are enough for a strong signal without turning a
/// long conversational query into an unbounded span expression.
fn coherence_query(plan: &[PlannedConcept]) -> Option<String> {
    if plan.len() < 2 {
        return None;
    }
    let mut clauses = Vec::new();
    for pair in plan.windows(2).take(3) {
        let left = std::iter::once(pair[0].word.as_str())
            .chain(pair[0].forms.iter().take(1).map(String::as_str))
            .collect::<Vec<_>>();
        let right = std::iter::once(pair[1].word.as_str())
            .chain(pair[1].forms.iter().take(1).map(String::as_str))
            .collect::<Vec<_>>();
        for left in &left {
            for right in &right {
                // Word order is not evidence of meaning: "grow potatoes" and
                // "potatoes grow" both describe the subject.
                clauses.push(format!(
                    "body:{}~{}",
                    solr_string_term(&format!("{left} {right}")),
                    COHERENCE_SLOP
                ));
                clauses.push(format!(
                    "body:{}~{}",
                    solr_string_term(&format!("{right} {left}")),
                    COHERENCE_SLOP
                ));
            }
        }
        // A title that names both ideas is coherent even though it is much
        // shorter than the body window.
        clauses.push(format!(
            "title:{}~2",
            solr_string_term(&format!("{} {}", pair[0].word, pair[1].word))
        ));
        clauses.push(format!(
            "title:{}~2",
            solr_string_term(&format!("{} {}", pair[1].word, pair[0].word))
        ));
    }
    Some(format!("({})", clauses.join(" OR ")))
}

/// A plain formatted reference must not become an OR between its numeric
/// parts (e.g. a date accidentally matching a numbered film). Explicit query
/// syntax is excluded; only quote reference tokens inside otherwise plain text.
fn literal_reference_query(query: &str) -> Option<String> {
    let mut changed = false;
    let mut terms = Vec::new();
    for word in query.split_whitespace() {
        if matches!(word, "AND" | "OR" | "NOT" | "TO")
            || !word.chars().next().is_some_and(char::is_alphanumeric)
            || word
                .chars()
                .any(|ch| !ch.is_alphanumeric() && !matches!(ch, '-' | '/' | '.' | '\'' | '’'))
        {
            return None;
        }
        if word.chars().any(char::is_numeric)
            && word.chars().any(|ch| matches!(ch, '-' | '/' | '.'))
        {
            terms.push(solr_string_term(word));
            changed = true;
        } else {
            terms.push(word.to_string());
        }
    }
    changed.then(|| terms.join(" "))
}

/// Escapes the Lucene/edismax syntax characters so a literal user query is
/// treated as text rather than operators. Whitespace is preserved so the query
/// still splits into separate terms.
fn escape_lucene_query(query: &str) -> String {
    const SPECIAL: &str = r#"\+-&|!(){}[]^"~*?:/"#;
    let mut escaped = String::with_capacity(query.len());
    for ch in query.chars() {
        if SPECIAL.contains(ch) {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

/// Whether a Solr error looks like the query itself was rejected (bad syntax,
/// unknown field) as opposed to a server or transport problem. Solr reports
/// these with HTTP 400 and a `code:400` in the error payload.
fn is_query_parse_error(err: &str) -> bool {
    err.contains("\"code\":400")
        || err.contains("Cannot parse")
        || err.contains("SyntaxError")
        || err.contains("undefined field")
}

/// Parses a Solr facet field. Solr returns facets as a flat array interleaving
/// name and count (`["paperless", 3, "mail", 1]`); accept the object form too
/// for hand-written fixtures. Numeric facet keys (e.g. `year_i`) come back as
/// numbers in the array form, so both are stringified.
fn facet_pairs(facet: &Value) -> Vec<(String, u64)> {
    if let Some(entries) = facet.as_array() {
        return entries
            .chunks_exact(2)
            .filter_map(|pair| {
                let name = match &pair[0] {
                    Value::String(text) => text.clone(),
                    Value::Number(number) => number.to_string(),
                    _ => return None,
                };
                let count = pair[1].as_u64()?;
                (count > 0).then_some((name, count))
            })
            .collect();
    }
    facet
        .as_object()
        .map(|entries| {
            entries
                .iter()
                .filter_map(|(name, count)| {
                    count.as_u64().and_then(|count| {
                        if count > 0 {
                            Some((name.clone(), count))
                        } else {
                            None
                        }
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_response(response: &Value) -> Result<SearchResponse, String> {
    let body = response
        .pointer("/response")
        .ok_or_else(|| format!("solr response missing /response: {response}"))?;
    let total = body
        .get("numFound")
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("solr response missing numFound: {response}"))?;

    let mut hits = Vec::new();
    for doc in body
        .get("docs")
        .and_then(Value::as_array)
        .unwrap_or(&Vec::new())
    {
        let id = doc
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let score = doc.get("score").and_then(Value::as_f64).unwrap_or_default();
        hits.push(SearchHit {
            id,
            kind: doc
                .get("kind_s")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            source: doc
                .get("source")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            title: doc
                .get("title")
                // text_general is multiValued in the stock configset, so
                // even one title is returned as ["Subject or book title"].
                // Accept scalar responses too for explicitly single-valued
                // schemas; never drop a valid stored title at this boundary.
                .and_then(|value| {
                    value.as_str().or_else(|| {
                        value
                            .as_array()?
                            .iter()
                            .filter_map(Value::as_str)
                            .find(|title| !title.trim().is_empty())
                    })
                })
                .unwrap_or_default()
                .to_string(),
            origin_url: doc
                .get("origin_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            app_url: doc
                .get("app_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            content_type: doc
                .get("content_type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            owner: doc
                .get("owner_s")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            created: doc
                .get("content_created")
                .and_then(Value::as_str)
                .and_then(crate::timeutil::parse_date),
            score,
            copies: doc
                .get("dedupe_s")
                .and_then(Value::as_str)
                .and_then(|signature| response.pointer("/expanded")?.get(signature))
                .and_then(|group| group.get("numFound"))
                .and_then(Value::as_u64)
                .unwrap_or(0),
        });
    }

    let facet_fields = response
        .pointer("/facet_counts/facet_fields")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let facets_of = |name: &str| -> Vec<(String, u64)> {
        facet_fields.get(name).map(facet_pairs).unwrap_or_default()
    };

    Ok(SearchResponse {
        hits,
        total,
        related_terms: Vec::new(),
        unknown_terms: Vec::new(),
        relaxed: false,
        source_facets: facets_of("source"),
        kind_facets: facets_of("kind_s"),
        content_type_facets: facets_of("content_type"),
        owner_facets: facets_of("owner_s"),
        author_facets: facets_of("author_ss"),
        tag_facets: facets_of("tag_ss"),
        series_facets: facets_of("series_ss"),
        year_facets: facets_of("year_i"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_solr_select_response() {
        let response = json!({
            "response": {
                "numFound": 2,
                "docs": [
                    {
                        "id": "paperless:1",
                        "source": "paperless",
                        "title": "Invoice",
                        "origin_url": "",
                        "app_url": "https://paperless.example.org/documents/1",
                        "content_type": "application/pdf",
                        "score": 1.5,
                        "content_created": "2024-02-01T00:00:00Z"
                    },
                    {
                        "id": "kiwix:A/Help.html",
                        "source": "kiwix",
                        "title": "Help",
                        "origin_url": "https://wiki.example.org/content/w/A/Help.html",
                        "app_url": "https://wiki.example.org",
                        "content_type": "text/html",
                        "score": 0.75
                    }
                ]
            },
            "facet_counts": {
                "facet_fields": {
                    "source": ["paperless", 1, "kiwix", 1],
                    "kind_s": ["document", 1],
                    "content_type": ["application/pdf", 1],
                    "owner_s": ["acme", 1],
                    "author_ss": ["ACME", 1],
                    "tag_ss": ["invoice", 1],
                    "series_ss": ["Fees", 1],
                    "year_i": [2024, 1]
                }
            }
        });
        let parsed = parse_search_response(&response).expect("parse");
        assert_eq!(parsed.total, 2);
        assert_eq!(parsed.hits.len(), 2);
        assert_eq!(parsed.hits[0].id, "paperless:1");
        assert_eq!(parsed.hits[0].created, Some(1_706_745_600));
        assert_eq!(parsed.source_facets.len(), 2);
        assert_eq!(parsed.kind_facets, vec![("document".to_string(), 1u64)]);
        assert_eq!(
            parsed.content_type_facets,
            vec![("application/pdf".to_string(), 1u64)]
        );
        assert_eq!(parsed.owner_facets, vec![("acme".to_string(), 1u64)]);
        assert_eq!(parsed.author_facets, vec![("ACME".to_string(), 1u64)]);
        assert_eq!(parsed.tag_facets, vec![("invoice".to_string(), 1u64)]);
        assert_eq!(parsed.series_facets, vec![("Fees".to_string(), 1u64)]);
        // Numeric facet keys are stringified so the UI can treat years like
        // every other chip.
        assert_eq!(parsed.year_facets, vec![("2024".to_string(), 1u64)]);
    }

    #[test]
    fn filters_build_fq_clauses() {
        let selected = vec!["paperless".to_string(), "mail-archive".to_string()];
        let none = SearchFilters::default();
        assert_eq!(
            none.clauses(&selected),
            vec!["source:(\"paperless\" OR \"mail-archive\")"]
        );

        let filtered = SearchFilters {
            wiki_full_text: false,
            matching: MatchMode::Broad,
            source: Some("mail-archive".to_string()),
            kind: Some("email".to_string()),
            content_type: Some("message/rfc822".to_string()),
            owner: Some("dsaw".to_string()),
            author: Some("Alice".to_string()),
            creator: None,
            tag: Some("invoice".to_string()),
            series: Some("Fees".to_string()),
            year: Some(2024),
            created_after: Some("2024-01-01".to_string()),
            created_before: Some("2024-12-31".to_string()),
        };
        let clauses = filtered.clauses(&selected);
        assert!(clauses.contains(&"{!tag=src}source:\"mail-archive\"".to_string()));
        assert!(clauses.contains(&"{!tag=kind}kind_s:\"email\"".to_string()));
        assert!(clauses.contains(&"{!tag=ct}content_type:\"message/rfc822\"".to_string()));
        assert!(clauses.contains(&"{!tag=own}owner_s:\"dsaw\"".to_string()));
        assert!(clauses.contains(&"{!tag=auth}author_ss:\"Alice\"".to_string()));
        assert!(clauses.contains(&"{!tag=tag}tag_ss:\"invoice\"".to_string()));
        assert!(clauses.contains(&"{!tag=ser}series_ss:\"Fees\"".to_string()));
        assert!(clauses.contains(&"{!tag=yr}year_i:2024".to_string()));
        assert!(clauses.contains(
            &"content_created:[2024-01-01T00:00:00Z TO 2024-12-31T23:59:59.999Z]".to_string()
        ));
    }

    #[test]
    fn source_scope_cannot_be_bypassed_by_filters_or_facets() {
        let filters = SearchFilters {
            source: Some("removed".into()),
            ..Default::default()
        };
        let clauses = filters.clauses(&["registered".into()]);
        assert!(clauses.contains(&"source:(\"registered\")".to_string()));
        assert!(SearchFilters::default()
            .clauses(&[])
            .contains(&"(*:* AND -(*:*))".to_string()));
    }

    #[test]
    fn one_sided_dates_keep_wildcards_and_include_subseconds() {
        let after = SearchFilters {
            created_after: Some("2024-01-01".into()),
            ..Default::default()
        };
        assert!(after
            .clauses(&[])
            .contains(&"content_created:[2024-01-01T00:00:00Z TO *]".to_string()));
        let before = SearchFilters {
            created_before: Some("2024-12-31".into()),
            ..Default::default()
        };
        assert!(before
            .clauses(&[])
            .contains(&"content_created:[* TO 2024-12-31T23:59:59.999Z]".to_string()));
    }

    #[test]
    fn payload_indexes_body_and_discovery_with_normalised_facets() {
        let record = db::DocumentRecord {
            external_id: "1".to_string(),
            kind: "document".to_string(),
            title: "t".to_string(),
            body_text: "searchable body".to_string(),
            content_type: "application/pdf".to_string(),
            origin_url: String::new(),
            app_url: String::new(),
            file_path: String::new(),
            size_bytes: 10,
            checksum: "sum".to_string(),
            content_created_at: Some(1_706_745_600),
            content_modified_at: None,
            metadata: serde_json::json!({ "owner": "acme", "correspondent": "acme", "tags": ["invoice"], "page_count": 4 }),
        };
        let doc = SolrDocument::from_record("paperless", &record, "acme");
        let rendered = doc.to_solr_json();
        // Body is sent for indexing (the schema stores it `stored="false"`).
        assert_eq!(rendered["body"], json!("searchable body"));
        // The extract kind is indexed for the kind facet/filter.
        assert_eq!(rendered["kind_s"], json!("document"));
        // Owner and the normalised facets are copied for filtering/faceting.
        assert_eq!(rendered["owner_s"], json!("acme"));
        assert_eq!(rendered["author_ss"], json!(["acme"]));
        assert_eq!(rendered["tag_ss"], json!(["invoice"]));
        assert_eq!(rendered["year_i"], json!(2024));
        // Arbitrary per-key metadata still stays in Postgres only.
        assert!(rendered.get("meta_correspondent_s").is_none());
        assert!(rendered.get("meta_page_count_s").is_none());
        assert!(rendered.get("meta_owner_s").is_none());
        assert_eq!(rendered["content_created"], json!("2024-02-01T00:00:00Z"));
        assert!(rendered.get("content_modified").is_none());
    }

    #[test]
    fn maps_sort_and_escapes_queries() {
        // Both orders break otherwise equal results by unique id.
        assert_eq!(SortOrder::Relevance.clause(), Some("score desc, id asc"));
        assert_eq!(
            SortOrder::Newest.clause(),
            Some("content_created desc, score desc, id asc")
        );

        assert_eq!(escape_lucene_query("plain terms"), "plain terms");
        assert_eq!(escape_lucene_query("field:value"), r"field\:value");
        assert_eq!(escape_lucene_query("a[b]"), r"a\[b\]");
        assert_eq!(escape_lucene_query("c++"), r"c\+\+");
        // An already-escaped query is escaped again; the fallback is only used
        // when the original was rejected, so idempotence is not required.
        assert_eq!(escape_lucene_query("a?b"), r"a\?b");
        // Non-syntax characters are left untouched.
        assert_eq!(escape_lucene_query("50%"), "50%");
    }

    #[test]
    fn recognises_query_parse_errors() {
        assert!(is_query_parse_error(
            r#"solr query rejected: {"error":{"msg":"Cannot parse 'foo:': ...","code":400}}"#
        ));
        assert!(is_query_parse_error("undefined field bogus"));
        assert!(is_query_parse_error("SyntaxError: ..."));
        // Transport and server errors are not query parse errors and must not
        // be retried with escaping.
        assert!(!is_query_parse_error(
            "solr query failed: connection refused"
        ));
        assert!(!is_query_parse_error(
            r#"solr query rejected: {"error":{"msg":"boom","code":500}}"#
        ));
    }
}
