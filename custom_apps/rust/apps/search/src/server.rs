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
use crate::source_cache::{CachedValue, SourceCache};
use crate::text;
use crate::zim_inventory::ZimInventoryCache;
use crate::zim_search::{self, ZimSearchConfig};

/// Default page size when the client does not ask for one, and the hard upper
/// bound a client may request. Paging is offset-based, so a very large page
/// would make Solr materialize an unbounded result window.
const DEFAULT_PAGE_SIZE: usize = 50;
const MAX_PAGE_SIZE: usize = 200;
/// How long Paperless correspondent/tag/document-type names are cached.
const PAPERLESS_TAXONOMY_TTL_SECONDS: i64 = 600;

#[derive(Clone)]
struct AppState {
    inner: std::sync::Arc<Inner>,
}

struct Inner {
    settings: Settings,
    solr: SolrClient,
    zim_cache: ZimInventoryCache,
    /// Shared HTTP client used for runtime-federated Paperless searches.
    paperless_http: reqwest::Client,
    /// Cached Paperless taxonomy names, keyed by base URL.
    paperless_taxonomy:
        Mutex<HashMap<String, std::sync::Arc<SourceCache<paperless_search::Taxonomy>>>>,
    /// Shared gateway sign-out URL the browser continues through, so a Search
    /// sign-out also clears the shared SSO cookie.
    logout_url: String,
    /// One shared Postgres connection for the small source-listing queries,
    /// connected lazily and evicted on failure so the next request reconnects.
    db: tokio::sync::Mutex<Option<std::sync::Arc<tokio_postgres::Client>>>,
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
            zim_cache: ZimInventoryCache::default(),
            paperless_http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(15))
                .redirect(reqwest::redirect::Policy::none())
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
        .layer(axum::middleware::map_response(
            |mut response: Response| async {
                response.headers_mut().insert(
                    axum::http::header::CACHE_CONTROL,
                    axum::http::HeaderValue::from_static("private, no-store"),
                );
                response
            },
        ))
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
        Err(err) => return Err(Box::new(database_unavailable(&err))),
    };
    match db::list_sources(&client).await {
        Ok(sources) => Ok(sources),
        Err(err) => {
            *state.inner.db.lock().await = None;
            Err(Box::new(database_unavailable(&err)))
        }
    }
}

fn not_signed_in() -> Response {
    (StatusCode::UNAUTHORIZED, "not signed in").into_response()
}

fn database_unavailable(_internal_error: &str) -> Response {
    // Connection errors can contain a DSN. Keep them out of public responses.
    eprintln!("search: database operation unavailable");
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({"error": "The search library is unavailable. Try again shortly."})),
    )
        .into_response()
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
    #[serde(default, rename = "pageSize")]
    page_size: Option<usize>,
    #[serde(default)]
    sort: Option<String>,
    /// The browser requests both scopes concurrently, so live archives never
    /// hold up indexed results. Older clients retain the combined response.
    #[serde(default)]
    scope: SearchScope,
}

#[derive(Default, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum SearchScope {
    #[default]
    All,
    Indexed,
    Live,
}

impl SearchParams {
    fn validate(&self) -> Result<(), &'static str> {
        if self.q.len() > 2048 {
            return Err("Search terms must be at most 2048 bytes.");
        }
        for date in [self.after.as_deref(), self.before.as_deref()]
            .into_iter()
            .flatten()
            .filter(|s| !s.trim().is_empty())
        {
            if chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d")
                .ok()
                .is_none_or(|parsed| parsed.format("%Y-%m-%d").to_string() != date)
            {
                return Err("Use a valid date in YYYY-MM-DD format.");
            }
        }
        if let (Some(after), Some(before)) = (
            nonempty(self.after.as_deref()),
            nonempty(self.before.as_deref()),
        ) && after > before
        {
            return Err("The start date must be on or before the end date.");
        }
        if nonempty(self.year.as_deref()).is_some_and(|value| value.parse::<i64>().is_err()) {
            return Err("Year must be a number.");
        }
        if self.page.unwrap_or(0).saturating_mul(self.page_size()) > 10_000 {
            return Err("Narrow your search to load more than 10,000 results.");
        }
        Ok(())
    }
    /// The requested page size, clamped so a client cannot ask for an
    /// unbounded result window.
    fn page_size(&self) -> usize {
        self.page_size
            .unwrap_or(DEFAULT_PAGE_SIZE)
            .clamp(1, MAX_PAGE_SIZE)
    }
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
    if let Err(message) = params.validate() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": message }))).into_response();
    }
    let query = params.q.trim().to_string();
    if query.is_empty() {
        return Json(json!({ "hits": [], "total": 0 })).into_response();
    }

    let client = match shared_db_client(&state).await {
        Ok(client) => client,
        Err(err) => return database_unavailable(&err),
    };
    let sources = match db::list_sources(&client).await {
        Ok(sources) => sources,
        Err(err) => {
            *state.inner.db.lock().await = None;
            return database_unavailable(&err);
        }
    };
    let selected: Vec<String> = sources.into_iter().map(|source| source.id).collect();
    let filters = params.filters();

    let page = params.page.unwrap_or(0);
    let rows = params.page_size();
    let offset = page.saturating_mul(rows);

    // Runtime-federated hits (a source's own index queried live) have no
    // pagination of their own, so they are pinned to the first page. The
    // per-source filter is applied inside the federator.
    let live = async {
        if page == 0 && params.scope != SearchScope::Indexed {
            federate_runtime_sources(&state, &selected, &query, &filters).await
        } else {
            LiveResults::default()
        }
    };
    if params.scope == SearchScope::Live {
        let mut result = live.await;
        if params.sort_order() == crate::solr::SortOrder::Newest {
            result
                .hits
                .sort_by_key(|hit| std::cmp::Reverse(hit.created));
        }
        let mut body = json!({ "hits": result.hits.iter().map(FederatedHit::to_json).collect::<Vec<_>>(), "total": result.hits.len(), "hasMore": false, "limited": true, "warnings": result.warnings });
        if let Some(facets) = result.facets.as_object() {
            body.as_object_mut().unwrap().extend(facets.clone());
        }
        return Json(body).into_response();
    }
    let indexed = state.inner.solr.search(
        &query,
        &selected,
        &filters,
        rows,
        offset,
        params.sort_order(),
    );
    let (response, federated) = tokio::join!(indexed, live);
    match response {
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
                federated.hits.iter().map(FederatedHit::to_json).collect();
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
                "total": response.total + federated.hits.len() as u64,
                "hasMore": has_more,
                "warnings": federated.warnings,
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
        Err(err) => {
            eprintln!("search: indexed query failed: {err}");
            (
                StatusCode::BAD_GATEWAY,
                Json(json!({ "error": "Library search is unavailable. Try again shortly." })),
            )
                .into_response()
        }
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

/// Live results are a bounded sample, with source-specific failures kept
/// separate from successful zero-match queries.
#[derive(Default)]
struct LiveResults {
    hits: Vec<FederatedHit>,
    warnings: Vec<serde_json::Value>,
    facets: serde_json::Value,
}

fn runtime_source_in_scope(
    source: &crate::config::SourceConfig,
    selected: &[String],
    filters: &crate::solr::SearchFilters,
) -> bool {
    selected.contains(&source.id)
        && filters.source.as_ref().is_none_or(|id| id == &source.id)
        && match source.source_type.as_str() {
            "kiwix" => filters.created_after.is_none() && filters.created_before.is_none(),
            // Kind is applied after sampling so its facet exposes alternatives.
            "paperless-api" => true,
            _ => false,
        }
}

async fn federate_runtime_sources(
    state: &AppState,
    selected: &[String],
    query: &str,
    filters: &crate::solr::SearchFilters,
) -> LiveResults {
    use futures_util::{stream, StreamExt};
    let sources: Vec<_> = state
        .inner
        .settings
        .sources
        .iter()
        .filter(|source| runtime_source_in_scope(source, selected, filters))
        .cloned()
        .collect();
    let mut results = stream::iter(sources)
        .map(|source| async move {
            let operation = async {
                match source.source_type.as_str() {
                    "kiwix" => federate_kiwix(state, &source, query).await,
                    _ => federate_paperless(state, &source, query).await,
                }
            };
            let result = tokio::time::timeout(std::time::Duration::from_secs(30), operation)
                .await
                .unwrap_or_else(|_| Err("The source took too long to respond.".to_string()));
            (source.id.clone(), result)
        })
        .buffer_unordered(4)
        .collect::<Vec<_>>()
        .await;
    results.sort_by(|a, b| a.0.cmp(&b.0));
    let mut output = LiveResults::default();
    for (source, result) in results {
        match result {
            Ok(result) => {
                output.hits.extend(result.hits);
                output.warnings.extend(result.warnings);
            }
            Err(message) => output
                .warnings
                .push(json!({ "source": source, "message": message })),
        }
    }
    output.facets = crate::federate::facet_counts(&output.hits, filters);
    output.hits.retain(|hit| hit.matches_filters(filters));
    output
}

/// Queries the ZIM archives' native Xapian indexes for one kiwix source.
async fn federate_kiwix(
    state: &AppState,
    source: &crate::config::SourceConfig,
    query: &str,
) -> Result<LiveResults, String> {
    let Some(library_root) = source.setting_str("libraryRoot") else {
        return Err("The archive library is not configured.".to_string());
    };
    let config = ZimSearchConfig {
        kiwix_search: state.inner.settings.kiwix_search.clone(),
        zimdump: state.inner.settings.zimdump.clone(),
        library_root: std::path::PathBuf::from(library_root),
        app_base: source.app_base.clone(),
    };
    if !config.enabled() {
        return Err("Offline archive search tools are unavailable.".to_string());
    }
    if !config.library_root.is_dir() {
        return Err("The archive library is unavailable.".to_string());
    }
    let inventory = state.inner.zim_cache.get(&config).await;
    let entries = inventory
        .value
        .as_deref()
        .map(Vec::as_slice)
        .unwrap_or_default();
    let result = zim_search::search(&config, entries, query).await;
    let mut warnings: Vec<_> = inventory
        .warning
        .into_iter()
        .map(|message| json!({ "source": source.id, "message": message }))
        .collect();
    if result.failed_archives > 0 {
        warnings.push(json!({ "source": source.id, "message": format!("{} offline archives could not be searched. These results are incomplete.", result.failed_archives) }));
    }
    Ok(LiveResults {
        hits: result
            .hits
            .into_iter()
            .map(|hit| FederatedHit::from_zim(&source.id, hit))
            .collect(),
        warnings,
        ..Default::default()
    })
}

/// Queries one Paperless instance's own full-text index. The API token is read
/// from disk on demand. An unavailable token becomes a source warning rather
/// than failing other sources or pretending there were no matches.
async fn federate_paperless(
    state: &AppState,
    source: &crate::config::SourceConfig,
    query: &str,
) -> Result<LiveResults, String> {
    let Some(base_url) = source.setting_str("baseUrl") else {
        return Err("The document server is not configured.".to_string());
    };
    let token = paperless_token(state)
        .ok_or("Document search is not ready. Its access token is unavailable.")?;
    let config = paperless_search::PaperlessSearchConfig {
        source_id: source.id.clone(),
        client: state.inner.paperless_http.clone(),
        base_url: base_url.trim_end_matches('/').to_string(),
        token,
        app_base: source.app_base.trim_end_matches('/').to_string(),
        max_results: paperless_search::DEFAULT_MAX_RESULTS,
    };
    let taxonomy = paperless_taxonomy(state, &config).await;
    let hits =
        paperless_search::search(&config, &taxonomy.value.unwrap_or_default(), query).await?;
    let warnings = taxonomy.warning.into_iter().map(|message| json!({"source": source.id, "message": format!("{message} Metadata filters and labels may be incomplete.")})).collect();
    Ok(LiveResults {
        hits,
        warnings,
        ..Default::default()
    })
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
) -> CachedValue<paperless_search::Taxonomy> {
    let cache = state
        .inner
        .paperless_taxonomy
        .lock()
        .unwrap()
        .entry(config.base_url.clone())
        .or_insert_with(|| {
            std::sync::Arc::new(SourceCache::new(
                std::time::Duration::from_secs(PAPERLESS_TAXONOMY_TTL_SECONDS as u64),
                std::time::Duration::from_secs(30),
            ))
        })
        .clone();
    cache
        .get_or_refresh(|| async {
            tokio::time::timeout(
                std::time::Duration::from_secs(6),
                paperless_search::load_taxonomy(&state.inner.paperless_http, config),
            )
            .await
            .unwrap_or_else(|_| Err("Document metadata lookup timed out.".into()))
        })
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_filter_preserves_alternative_live_samples_but_not_out_of_scope_sources() {
        let mut source = crate::config::SourceConfig {
            id: "archive".into(),
            display_name: "Archive".into(),
            source_type: "kiwix".into(),
            app_base: String::new(),
            settings: Default::default(),
        };
        let selected = vec![source.id.clone()];
        let mut filters = crate::solr::SearchFilters {
            kind: Some("document".into()),
            ..Default::default()
        };
        assert!(runtime_source_in_scope(&source, &selected, &filters));
        assert!(!runtime_source_in_scope(&source, &[], &filters));
        filters.created_after = Some("2024-01-01".into());
        assert!(!runtime_source_in_scope(&source, &selected, &filters));
        source.source_type = "paperless-api".into();
        filters.kind = Some("zim-article".into());
        assert!(runtime_source_in_scope(&source, &selected, &filters));
        filters.source = Some("other".into());
        assert!(!runtime_source_in_scope(&source, &selected, &filters));
    }

    #[test]
    fn validates_query_dates_and_result_window() {
        for invalid in [
            json!({"after":"2024-02-30"}),
            json!({"after":"*] OR *:*"}),
            json!({"after":"2024-2-01"}),
            json!({"after":"2025-01-01", "before":"2024-01-01"}),
            json!({"year":"abc"}),
            json!({"page":1000}),
            json!({"q":"x".repeat(2049)}),
        ] {
            let mut input = json!({"q":"test"});
            input
                .as_object_mut()
                .unwrap()
                .extend(invalid.as_object().unwrap().clone());
            assert!(
                serde_json::from_value::<SearchParams>(input.clone())
                    .unwrap()
                    .validate()
                    .is_err(),
                "{input}"
            );
        }
        for valid in [
            json!({"q":"test", "after":"2024-02-29"}),
            json!({"q":"test", "before":"2025-01-01"}),
            json!({"q":"test", "scope":"live"}),
        ] {
            assert!(serde_json::from_value::<SearchParams>(valid)
                .unwrap()
                .validate()
                .is_ok());
        }
    }

    #[test]
    fn identity_is_required() {
        assert!(Identity::from_headers(&HeaderMap::new()).is_err());
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-user", "admin".parse().expect("header"));
        assert!(Identity::from_headers(&headers).is_ok());
    }

    #[test]
    fn env_or_prefers_nonempty() {
        unsafe { std::env::set_var("SEARCH_UI_TEST_ENV", "custom") };
        assert_eq!(env_or("SEARCH_UI_TEST_ENV", "default"), "custom");
        unsafe { std::env::set_var("SEARCH_UI_TEST_ENV", "") };
        assert_eq!(env_or("SEARCH_UI_TEST_ENV", "default"), "default");
        assert_eq!(env_or("SEARCH_UI_TEST_UNSET", "default"), "default");
        unsafe { std::env::remove_var("SEARCH_UI_TEST_ENV") };
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

    #[test]
    fn page_size_is_bounded() {
        let params = |value: serde_json::Value| -> SearchParams {
            serde_json::from_value(value).expect("params")
        };
        assert_eq!(params(json!({ "q": "x" })).page_size(), DEFAULT_PAGE_SIZE);
        assert_eq!(
            params(json!({ "q": "x", "pageSize": 100 })).page_size(),
            100
        );
        // Zero is clamped up, an oversized request is clamped down.
        assert_eq!(params(json!({ "q": "x", "pageSize": 0 })).page_size(), 1);
        assert_eq!(
            params(json!({ "q": "x", "pageSize": 99_999 })).page_size(),
            MAX_PAGE_SIZE
        );
    }
}
