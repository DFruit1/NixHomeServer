use std::collections::HashMap;
use std::sync::Mutex;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use homelab_common::{env_or, log_server_started, shutdown_signal};
use serde_json::json;

use crate::config::Settings;
use crate::db;
use crate::federate::FederatedHit;
use crate::identity::Identity;
use crate::paperless_search;
use crate::solr::SolrClient;
use crate::text;
use crate::timeutil::now_epoch;
use crate::zim_search::{self, ZimIndexEntry, ZimSearchConfig};

const MAX_RESULTS: usize = 50;
/// How long the discovered ZIM library listing is cached between queries.
const ZIM_CACHE_TTL_SECONDS: i64 = 300;
/// How long Paperless correspondent/tag/document-type names are cached.
const PAPERLESS_TAXONOMY_TTL_SECONDS: i64 = 600;

#[derive(Clone)]
struct AppState {
    inner: std::sync::Arc<Inner>,
}

struct Inner {
    settings: Settings,
    solr: SolrClient,
    zim_cache: Mutex<ZimCache>,
    /// Shared HTTP client used for runtime-federated Paperless searches.
    paperless_http: reqwest::Client,
    /// Cached Paperless taxonomy names, keyed by base URL.
    paperless_taxonomy: Mutex<HashMap<String, (paperless_search::Taxonomy, i64)>>,
    /// Shared gateway sign-out URL the browser continues through, so a Search
    /// sign-out also clears the shared SSO cookie.
    logout_url: String,
    /// One shared Postgres connection for the small source-listing queries,
    /// connected lazily and evicted on failure so the next request reconnects.
    db: tokio::sync::Mutex<Option<std::sync::Arc<tokio_postgres::Client>>>,
}

/// Cached ZIM library inventories, keyed by the library root each was built
/// from, so multiple kiwix sources never evict each other's inventories.
#[derive(Default)]
struct ZimCache {
    entries: HashMap<String, (Vec<ZimIndexEntry>, i64)>,
}

pub async fn run() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let address = env_or("SEARCH_UI_ADDRESS", "127.0.0.1");
    let port: u16 = env_or("SEARCH_UI_PORT", "8092")
        .parse()
        .map_err(|_| "SEARCH_UI_PORT must be a port number".to_string())?;
    let logout_url = env_or("SEARCH_LOGOUT_REDIRECT_URL", "");
    address
        .parse::<std::net::IpAddr>()
        .ok()
        .filter(std::net::IpAddr::is_loopback)
        .ok_or_else(|| {
            "SEARCH_UI_ADDRESS must be loopback; Search trusts forwarded identity headers"
                .to_string()
        })?;

    let state = AppState {
        inner: std::sync::Arc::new(Inner {
            settings,
            solr: SolrClient::new(
                &env_or("SEARCH_SOLR_URL", "http://127.0.0.1:8983/solr"),
                &env_or("SEARCH_SOLR_CORE", "search"),
            ),
            zim_cache: Mutex::new(ZimCache::default()),
            paperless_http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(15))
                .build()
                .map_err(|err| format!("failed to build Paperless HTTP client: {err}"))?,
            paperless_taxonomy: Mutex::new(HashMap::new()),
            logout_url,
            db: tokio::sync::Mutex::new(None),
        }),
    };

    let app = Router::new()
        .route("/", get(index))
        .route("/healthz", get(health))
        .route("/api/sources", get(api_sources))
        .route("/api/search", get(api_search))
        .with_state(state.clone());

    let listener = tokio::net::TcpListener::bind((address.as_str(), port))
        .await
        .map_err(|err| format!("failed to bind {address}:{port}: {err}"))?;
    log_server_started("search", &format!("{address}:{port}"));
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|err| format!("server error: {err}"))?;
    Ok(())
}

async fn health() -> &'static str {
    "ok"
}

/// Serves the single-file UI. Authentication is enforced by the shared gateway
/// (admin-only) before requests reach this loopback server, so there is no
/// local session to check here.
async fn index(State(state): State<AppState>) -> Response {
    let logout = if state.inner.logout_url.is_empty() {
        String::new()
    } else {
        format!(
            "<script>window.SEARCH_LOGOUT_URL = {};</script>",
            serde_json::Value::String(state.inner.logout_url.clone())
        )
    };
    Html(include_str!("ui.html").replace("<!--LOGOUT_URL-->", &logout)).into_response()
}

async fn shared_db_client(
    state: &AppState,
) -> Result<std::sync::Arc<tokio_postgres::Client>, String> {
    let mut guard = state.inner.db.lock().await;
    if let Some(client) = guard.as_ref() {
        return Ok(client.clone());
    }
    let client = std::sync::Arc::new(db::connect(&state.inner.settings.database_url).await?);
    *guard = Some(client.clone());
    Ok(client)
}

/// Validates the gateway-forwarded identity and loads every registered source.
///
/// Authorization is enforced centrally by the shared auth gateway (admin-only
/// group). Every authenticated admin may search every source; there is no
/// per-source ACL any more.
async fn gate(state: &AppState, headers: &HeaderMap) -> Result<Vec<db::UiSource>, Box<Response>> {
    if Identity::from_headers(headers).is_err() {
        return Err(Box::new(not_signed_in()));
    }
    let client = match shared_db_client(state).await {
        Ok(client) => client,
        Err(err) => {
            return Err(Box::new(
                (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
            ))
        }
    };
    match db::list_sources(&client).await {
        Ok(sources) => Ok(sources),
        Err(err) => {
            *state.inner.db.lock().await = None;
            Err(Box::new(
                (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
            ))
        }
    }
}

fn not_signed_in() -> Response {
    (StatusCode::UNAUTHORIZED, "not signed in").into_response()
}

async fn api_sources(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match gate(&state, &headers).await {
        Ok(sources) => Json(json!({
            "sources": sources
                .into_iter()
                .map(|source| json!({
                    "id": source.id,
                    "displayName": source.display_name,
                    "lastSyncedAt": source.last_synced_at,
                    "lastError": source.last_error,
                }))
                .collect::<Vec<_>>(),
        }))
        .into_response(),
        Err(response) => *response,
    }
}

#[derive(serde::Deserialize)]
struct SearchParams {
    q: String,
    #[serde(default, rename = "type")]
    content_type: Option<String>,
    source: Option<String>,
    kind: Option<String>,
    owner: Option<String>,
    author: Option<String>,
    tag: Option<String>,
    series: Option<String>,
    year: Option<String>,
    #[serde(default)]
    after: Option<String>,
    #[serde(default)]
    before: Option<String>,
    #[serde(default)]
    page: Option<usize>,
    #[serde(default)]
    sort: Option<String>,
}

impl SearchParams {
    /// Maps the UI's `sort` value to a Solr ordering. Unknown or missing values
    /// fall back to relevance so a hand-edited URL cannot break the query.
    fn sort_order(&self) -> crate::solr::SortOrder {
        match nonempty(self.sort.as_deref()).as_deref() {
            Some("newest") => crate::solr::SortOrder::Newest,
            _ => crate::solr::SortOrder::Relevance,
        }
    }
    fn filters(&self) -> crate::solr::SearchFilters {
        crate::solr::SearchFilters {
            source: nonempty(self.source.as_deref()),
            kind: nonempty(self.kind.as_deref()),
            content_type: nonempty(self.content_type.as_deref()),
            owner: nonempty(self.owner.as_deref()),
            author: nonempty(self.author.as_deref()),
            tag: nonempty(self.tag.as_deref()),
            series: nonempty(self.series.as_deref()),
            year: self
                .year
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .and_then(|value| value.parse().ok()),
            created_after: nonempty(self.after.as_deref()),
            created_before: nonempty(self.before.as_deref()),
        }
    }
}

fn nonempty(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

async fn api_search(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Response {
    if Identity::from_headers(&headers).is_err() {
        return not_signed_in();
    }
    let query = params.q.trim().to_string();
    if query.is_empty() {
        return Json(json!({ "hits": [], "total": 0 })).into_response();
    }

    let client = match shared_db_client(&state).await {
        Ok(client) => client,
        Err(err) => return (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
    };
    let sources = match db::list_sources(&client).await {
        Ok(sources) => sources,
        Err(err) => {
            *state.inner.db.lock().await = None;
            return (StatusCode::INTERNAL_SERVER_ERROR, err).into_response();
        }
    };
    let selected: Vec<String> = sources.into_iter().map(|source| source.id).collect();
    let filters = params.filters();

    let page = params.page.unwrap_or(0);
    let rows = MAX_RESULTS;
    let offset = page.saturating_mul(rows);

    // Runtime-federated hits (a source's own index queried live) have no
    // pagination of their own, so they are pinned to the first page. The
    // per-source filter is applied inside the federator.
    let include_federated = page == 0;
    let federated_hits = if include_federated {
        federate_runtime_sources(&state, &selected, &query, &filters).await
    } else {
        Vec::new()
    };

    match state
        .inner
        .solr
        .search(
            &query,
            &selected,
            &filters,
            rows,
            offset,
            params.sort_order(),
        )
        .await
    {
        Ok(response) => {
            // Solr never returns the body; load it once for the returned page
            // and build snippets from the authoritative Postgres copy. A failed
            // enrichment degrades to title-only results rather than a 500.
            let ids: Vec<String> = response.hits.iter().map(|hit| hit.id.clone()).collect();
            let enrichment = match db::enrich_documents(client.as_ref(), &ids).await {
                Ok(map) => map,
                Err(err) => {
                    eprintln!("search: result enrichment failed: {err}");
                    Default::default()
                }
            };
            let mut hits: Vec<serde_json::Value> =
                federated_hits.iter().map(FederatedHit::to_json).collect();
            // Federated hits are only ever returned on the first page, so more
            // results remain exactly when Solr still has rows past this page.
            let has_more = offset + response.hits.len() < response.total as usize;
            for hit in response.hits.iter() {
                let enriched = enrichment.get(&hit.id);
                let snippet =
                    enriched.and_then(|doc| text::snippet_from_text(&doc.body_text, &query));
                let metadata = enriched
                    .map(|doc| present_metadata(&doc.metadata))
                    .unwrap_or_else(|| json!({}));
                hits.push(json!({
                    "id": hit.id,
                    "source": hit.source,
                    "title": hit.title,
                    "snippet": snippet,
                    "originUrl": hit.origin_url,
                    "appUrl": hit.app_url,
                    "contentType": hit.content_type,
                    "owner": hit.owner,
                    "score": hit.score,
                    "created": hit.created,
                    "metadata": metadata,
                }));
            }
            Json(json!({
                "hits": hits,
                "total": response.total + federated_hits.len() as u64,
                "hasMore": has_more,
                "sourceFacets": facet_json(&response.source_facets),
                "kindFacets": facet_json(&response.kind_facets),
                "contentTypeFacets": facet_json(&response.content_type_facets),
                "ownerFacets": facet_json(&response.owner_facets),
                "authorFacets": facet_json(&response.author_facets),
                "tagFacets": facet_json(&response.tag_facets),
                "seriesFacets": facet_json(&response.series_facets),
                "yearFacets": facet_json(&response.year_facets),
            }))
            .into_response()
        }
        Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
    }
}

fn facet_json(facets: &[(String, u64)]) -> Vec<serde_json::Value> {
    facets
        .iter()
        .map(|(name, count)| json!({ "name": name, "count": count }))
        .collect()
}

/// Projects a document's metadata into a small, size-bounded object for the API
/// response so the UI can present key metadata uniformly across every source.
/// The full metadata stays in Postgres; only scalar values and short string
/// lists are exposed, each capped so a long mail header cannot bloat a page.
fn present_metadata(metadata: &serde_json::Value) -> serde_json::Value {
    const MAX_STRING_CHARS: usize = 300;
    const MAX_LIST_ITEMS: usize = 20;
    let mut out = serde_json::Map::new();
    let serde_json::Value::Object(entries) = metadata else {
        return serde_json::Value::Object(out);
    };
    for (key, value) in entries {
        // Owner is a first-class result field, not repeat it here.
        if key == "owner" {
            continue;
        }
        match value {
            serde_json::Value::String(text) => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    out.insert(key.clone(), json!(truncate(trimmed, MAX_STRING_CHARS)));
                }
            }
            serde_json::Value::Number(_) | serde_json::Value::Bool(_) => {
                out.insert(key.clone(), value.clone());
            }
            serde_json::Value::Array(items) => {
                let values: Vec<String> = items
                    .iter()
                    .filter_map(|item| match item {
                        serde_json::Value::String(text) => {
                            let trimmed = text.trim();
                            (!trimmed.is_empty()).then(|| truncate(trimmed, 120))
                        }
                        serde_json::Value::Number(number) => Some(number.to_string()),
                        _ => None,
                    })
                    .take(MAX_LIST_ITEMS)
                    .collect();
                if !values.is_empty() {
                    out.insert(key.clone(), json!(values.join(", ")));
                }
            }
            _ => {}
        }
    }
    serde_json::Value::Object(out)
}

/// Truncates a string to at most `limit` characters on a UTF-8 boundary.
fn truncate(value: &str, limit: usize) -> String {
    if value.chars().count() <= limit {
        return value.to_string();
    }
    value.chars().take(limit).collect()
}

/// Queries every runtime-federated source in scope using that source's own
/// index, returning unified hits. Never fails the whole request: a source whose
/// tools, credentials, or upstream are unavailable simply contributes nothing.
async fn federate_runtime_sources(
    state: &AppState,
    selected: &[String],
    query: &str,
    filters: &crate::solr::SearchFilters,
) -> Vec<FederatedHit> {
    let mut hits: Vec<FederatedHit> = Vec::new();
    for source in &state.inner.settings.sources {
        if !selected.iter().any(|id| id == &source.id) {
            continue;
        }
        // A source filter that names a different source makes this one
        // entirely out of scope.
        if let Some(filter) = &filters.source {
            if filter != &source.id {
                continue;
            }
        }
        match source.source_type.as_str() {
            "kiwix" => {
                // ZIM articles carry no timestamps, so a date filter can never
                // match them: skip the archive walk entirely in that case.
                if filters.created_after.is_none() && filters.created_before.is_none() {
                    hits.extend(federate_kiwix(state, source, query).await);
                }
            }
            "paperless-api" => hits.extend(federate_paperless(state, source, query).await),
            _ => {}
        }
    }
    hits.retain(|hit| hit.matches_filters(filters));
    hits
}

/// Queries the ZIM archives' native Xapian indexes for one kiwix source.
async fn federate_kiwix(
    state: &AppState,
    source: &crate::config::SourceConfig,
    query: &str,
) -> Vec<FederatedHit> {
    let Some(library_root) = source.setting_str("libraryRoot") else {
        return Vec::new();
    };
    let config = ZimSearchConfig {
        kiwix_search: state.inner.settings.kiwix_search.clone(),
        zimdump: state.inner.settings.zimdump.clone(),
        library_root: std::path::PathBuf::from(library_root),
        app_base: source.app_base.clone(),
    };
    if !config.enabled() {
        return Vec::new();
    }
    let entries = zim_entries(state, &config).await;
    zim_search::search(&config, &entries, query)
        .await
        .into_iter()
        .map(|hit| FederatedHit::from_zim(&source.id, hit))
        .collect()
}

/// Queries one Paperless instance's own full-text index. The API token is read
/// from disk on demand, so a not-yet-minted or missing token degrades to "no
/// Paperless results" instead of failing the search.
async fn federate_paperless(
    state: &AppState,
    source: &crate::config::SourceConfig,
    query: &str,
) -> Vec<FederatedHit> {
    let Some(base_url) = source.setting_str("baseUrl") else {
        return Vec::new();
    };
    let token = match paperless_token(state) {
        Some(token) => token,
        None => return Vec::new(),
    };
    let config = paperless_search::PaperlessSearchConfig {
        source_id: source.id.clone(),
        client: state.inner.paperless_http.clone(),
        base_url: base_url.trim_end_matches('/').to_string(),
        token,
        app_base: source.app_base.trim_end_matches('/').to_string(),
        max_results: paperless_search::DEFAULT_MAX_RESULTS,
    };
    let taxonomy = paperless_taxonomy(state, &config).await;
    paperless_search::search(&config, &taxonomy, query).await
}

/// Reads the Paperless API token from its configured file. Returns `None` when
/// no file is configured, it is unreadable, or it is empty.
fn paperless_token(state: &AppState) -> Option<String> {
    let path = state.inner.settings.paperless_token_file.as_ref()?;
    std::fs::read_to_string(path)
        .ok()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

/// Returns cached Paperless taxonomy names, refreshing them when stale.
async fn paperless_taxonomy(
    state: &AppState,
    config: &paperless_search::PaperlessSearchConfig,
) -> paperless_search::Taxonomy {
    let key = config.base_url.clone();
    let now = now_epoch();
    {
        let cache = state.inner.paperless_taxonomy.lock().unwrap();
        if let Some((taxonomy, fetched_at)) = cache.get(&key) {
            if now - *fetched_at < PAPERLESS_TAXONOMY_TTL_SECONDS {
                return taxonomy.clone();
            }
        }
    }
    let taxonomy = paperless_search::load_taxonomy(&state.inner.paperless_http, config).await;
    let mut cache = state.inner.paperless_taxonomy.lock().unwrap();
    cache.insert(key, (taxonomy.clone(), now));
    taxonomy
}

/// Returns the cached ZIM library inventory for a kiwix source, refreshing it
/// when stale.
async fn zim_entries(state: &AppState, config: &ZimSearchConfig) -> Vec<ZimIndexEntry> {
    let root = config.library_root.to_string_lossy().to_string();
    let now = now_epoch();
    {
        let cache = state.inner.zim_cache.lock().unwrap();
        if let Some((entries, fetched_at)) = cache.entries.get(&root) {
            if now - *fetched_at < ZIM_CACHE_TTL_SECONDS {
                return entries.clone();
            }
        }
    }
    let zimdump = config.zimdump.clone();
    let library_root = config.library_root.clone();
    let entries = tokio::task::spawn_blocking(move || match zimdump {
        Some(zimdump) => zim_search::discover_zims(&zimdump, &library_root),
        None => Vec::new(),
    })
    .await
    .unwrap_or_default();
    let mut cache = state.inner.zim_cache.lock().unwrap();
    cache.entries.insert(root, (entries.clone(), now));
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_required() {
        assert!(Identity::from_headers(&HeaderMap::new()).is_err());
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-user", "admin".parse().expect("header"));
        assert!(Identity::from_headers(&headers).is_ok());
    }

    #[test]
    fn env_or_prefers_nonempty() {
        std::env::set_var("SEARCH_UI_TEST_ENV", "custom");
        assert_eq!(env_or("SEARCH_UI_TEST_ENV", "default"), "custom");
        std::env::set_var("SEARCH_UI_TEST_ENV", "");
        assert_eq!(env_or("SEARCH_UI_TEST_ENV", "default"), "default");
        assert_eq!(env_or("SEARCH_UI_TEST_UNSET", "default"), "default");
        std::env::remove_var("SEARCH_UI_TEST_ENV");
    }

    #[test]
    fn projects_metadata_for_display() {
        let metadata = json!({
            "owner": "dsaw",
            "from": "alice@example.org",
            "cc": ["bob@example.org", "carol@example.org"],
            "tags": ["invoice", "2024"],
            "page_count": 4,
            "empty": "",
            "nested": { "ignored": true }
        });
        let projected = present_metadata(&metadata);
        assert_eq!(projected["from"], json!("alice@example.org"));
        assert_eq!(projected["cc"], json!("bob@example.org, carol@example.org"));
        assert_eq!(projected["tags"], json!("invoice, 2024"));
        assert_eq!(projected["page_count"], json!(4));
        // Owner is a first-class field; empty and non-scalar values are dropped.
        assert!(projected.get("owner").is_none());
        assert!(projected.get("empty").is_none());
        assert!(projected.get("nested").is_none());
    }

    #[test]
    fn truncates_on_char_boundaries() {
        let value = "héllo".repeat(100);
        let out = truncate(&value, 3);
        assert_eq!(out.chars().count(), 3);
        assert!(value.starts_with(&out));
    }

    #[test]
    fn sort_param_maps_to_order() {
        let params = |value: serde_json::Value| -> SearchParams {
            serde_json::from_value(value).expect("params")
        };
        assert_eq!(
            params(json!({ "q": "x" })).sort_order(),
            crate::solr::SortOrder::Relevance
        );
        assert_eq!(
            params(json!({ "q": "x", "sort": "newest" })).sort_order(),
            crate::solr::SortOrder::Newest
        );
        // Unknown values fall back to relevance rather than failing the query.
        assert_eq!(
            params(json!({ "q": "x", "sort": "bogus" })).sort_order(),
            crate::solr::SortOrder::Relevance
        );
    }
}
