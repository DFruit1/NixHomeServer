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
use crate::identity::Identity;
use crate::solr::SolrClient;
use crate::timeutil::now_epoch;
use crate::zim_search::{self, ZimHit, ZimIndexEntry, ZimSearchConfig};

const MAX_RESULTS: usize = 50;
/// How long the discovered ZIM library listing is cached between queries.
const ZIM_CACHE_TTL_SECONDS: i64 = 300;

#[derive(Clone)]
struct AppState {
    inner: std::sync::Arc<Inner>,
}

struct Inner {
    settings: Settings,
    solr: SolrClient,
    zim_cache: Mutex<ZimCache>,
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
                .map(|source| json!({ "id": source.id, "displayName": source.display_name }))
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
    owner: Option<String>,
    #[serde(default)]
    after: Option<String>,
    #[serde(default)]
    before: Option<String>,
    #[serde(default)]
    page: Option<usize>,
}

impl SearchParams {
    fn filters(&self) -> crate::solr::SearchFilters {
        crate::solr::SearchFilters {
            source: nonempty(self.source.as_deref()),
            content_type: nonempty(self.content_type.as_deref()),
            owner: nonempty(self.owner.as_deref()),
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

/// Filters federated ZIM hits (which are not Solr documents) by the facets the
/// admin selected. ZIM articles have no owner, so any owner filter excludes
/// them, and they carry no timestamp, so any date filter excludes them too.
fn zim_hit_matches(hit: &ZimHit, filters: &crate::solr::SearchFilters) -> bool {
    let source_ok = filters
        .source
        .as_deref()
        .is_none_or(|source| source == "kiwix");
    let type_ok = filters
        .content_type
        .as_deref()
        .is_none_or(|value| value == "text/html");
    let owner_ok = filters.owner.is_none();
    let date_free = filters.created_after.is_none() && filters.created_before.is_none();
    source_ok && type_ok && owner_ok && date_free && hit.origin_url.starts_with("http")
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

    // Federated ZIM article hits are only queried (and only make sense) when
    // the kiwix source is actually in scope. They have no pagination of their
    // own, so they are pinned to the first page.
    let zim_in_scope = filters
        .source
        .as_deref()
        .is_none_or(|source| source == "kiwix");
    let include_zim_hits = page == 0 && zim_in_scope && filters.owner.is_none();
    let zim_hits = if include_zim_hits {
        federate_zims(&state, &selected, &query).await
    } else {
        Vec::new()
    };

    match state
        .inner
        .solr
        .search(&query, &selected, &filters, rows, offset)
        .await
    {
        Ok(response) => {
            let mut hits: Vec<serde_json::Value> = zim_hits
                .iter()
                .filter(|hit| zim_hit_matches(hit, &filters))
                .map(|hit| {
                    json!({
                        "id": format!("kiwix:{}", crate::timeutil::sha256_hex(&[&hit.origin_url])),
                        "source": "kiwix",
                        "title": hit.title,
                        "snippet": hit.snippet,
                        "originUrl": hit.origin_url,
                        "appUrl": hit.app_url,
                        "contentType": "text/html",
                        "owner": "shared",
                        "score": 0,
                        "created": null,
                    })
                })
                .collect();
            for hit in response.hits.iter() {
                hits.push(json!({
                    "id": hit.id,
                    "source": hit.source,
                    "title": hit.title,
                    "snippet": hit.snippet,
                    "originUrl": hit.origin_url,
                    "appUrl": hit.app_url,
                    "contentType": hit.content_type,
                    "owner": hit.owner,
                    "score": hit.score,
                    "created": hit.created,
                }));
            }
            Json(json!({
                "hits": hits,
                "total": response.total + if include_zim_hits { zim_hits.len() as u64 } else { 0 },
                "sourceFacets": facet_json(&response.source_facets),
                "contentTypeFacets": facet_json(&response.content_type_facets),
                "ownerFacets": facet_json(&response.owner_facets),
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

/// Queries the ZIM archives' native Xapian indexes for any kiwix source that is
/// part of the current search, returning merged article hits. Never fails the
/// whole request: unavailable archives or tools are skipped inside `zim_search`.
async fn federate_zims(state: &AppState, selected: &[String], query: &str) -> Vec<ZimHit> {
    let mut hits: Vec<ZimHit> = Vec::new();
    for source in &state.inner.settings.sources {
        if source.source_type != "kiwix" || !selected.iter().any(|id| id == &source.id) {
            continue;
        }
        let Some(library_root) = source.setting_str("libraryRoot") else {
            continue;
        };
        let config = ZimSearchConfig {
            kiwix_search: state.inner.settings.kiwix_search.clone(),
            zimdump: state.inner.settings.zimdump.clone(),
            library_root: std::path::PathBuf::from(library_root),
            app_base: source.app_base.clone(),
        };
        if !config.enabled() {
            continue;
        }
        let entries = zim_entries(state, &config).await;
        hits.extend(zim_search::search(&config, &entries, query).await);
    }
    hits
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
    fn zim_hits_follow_filters() {
        let hit = ZimHit {
            title: "Article".to_string(),
            snippet: None,
            origin_url: "https://wiki.example.org/content/w/A/Help.html".to_string(),
            app_url: "https://wiki.example.org".to_string(),
        };
        let none = crate::solr::SearchFilters::default();
        assert!(zim_hit_matches(&hit, &none));
        let owner = crate::solr::SearchFilters {
            owner: Some("dsaw".to_string()),
            ..Default::default()
        };
        assert!(!zim_hit_matches(&hit, &owner));
        let other_source = crate::solr::SearchFilters {
            source: Some("paperless".to_string()),
            ..Default::default()
        };
        assert!(!zim_hit_matches(&hit, &other_source));
        let dated = crate::solr::SearchFilters {
            created_after: Some("2024-01-01".to_string()),
            ..Default::default()
        };
        assert!(!zim_hit_matches(&hit, &dated));
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
}
