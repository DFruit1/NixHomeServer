use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use homelab_common::{env_or, log_server_started, read_secret_file, shutdown_signal};
use rand::RngCore;
use serde_json::json;

use crate::config::Settings;
use crate::db::{self, UiSource};
use crate::solr::SolrClient;
use crate::timeutil::now_epoch;
use crate::zim_search::{self, ZimHit, ZimIndexEntry, ZimSearchConfig};

const SESSION_COOKIE: &str = "search_session";
const SESSION_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const MAX_RESULTS: usize = 50;
/// How long the discovered ZIM library listing is cached between queries.
const ZIM_CACHE_TTL_SECONDS: i64 = 300;

#[derive(Clone)]
struct AppState {
    inner: std::sync::Arc<Inner>,
}

struct Inner {
    settings: Settings,
    http: reqwest::Client,
    solr: SolrClient,
    sessions: Mutex<HashMap<String, Session>>,
    pending_states: Mutex<HashMap<String, i64>>,
    discovery: Mutex<Option<Discovery>>,
    zim_cache: Mutex<ZimCache>,
    /// URL sign-out redirects to after the local session is cleared, so the
    /// browser continues through the shared SSO logout chain.
    logout_redirect: String,
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

#[derive(Clone)]
struct Session {
    username: String,
    groups: Vec<String>,
    expires_at: i64,
}

#[derive(Clone, Debug)]
struct Discovery {
    authorization_endpoint: String,
    token_endpoint: String,
    userinfo_endpoint: String,
}

pub async fn run() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let address = env_or("SEARCH_UI_ADDRESS", "127.0.0.1");
    let port: u16 = env_or("SEARCH_UI_PORT", "8092")
        .parse()
        .map_err(|_| "SEARCH_UI_PORT must be a port number".to_string())?;
    let issuer = env_or("SEARCH_OIDC_ISSUER", "");
    match std::env::var("SEARCH_OIDC_CLIENT_SECRET_FILE") {
        Ok(path) => read_secret_file(std::path::Path::new(&path)).map(|_| ())?,
        Err(_) => return Err("SEARCH_OIDC_CLIENT_SECRET_FILE must be set".to_string()),
    };
    let logout_redirect = env_or("SEARCH_LOGOUT_REDIRECT_URL", "");

    let state = AppState {
        inner: std::sync::Arc::new(Inner {
            settings,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()
                .expect("reqwest client"),
            solr: SolrClient::new(
                &env_or("SEARCH_SOLR_URL", "http://127.0.0.1:8983/solr"),
                &env_or("SEARCH_SOLR_CORE", "search"),
            ),
            sessions: Mutex::new(HashMap::new()),
            pending_states: Mutex::new(HashMap::new()),
            discovery: Mutex::new(None),
            zim_cache: Mutex::new(ZimCache::default()),
            logout_redirect,
            db: tokio::sync::Mutex::new(None),
        }),
    };

    // Warm the OIDC discovery cache so the first login is fast, but do not
    // block startup on Kanidm availability.
    let warm = state.clone();
    let issuer_warm = issuer.clone();
    tokio::spawn(async move {
        let _ = discovery(&warm, &issuer_warm).await;
    });

    let app = Router::new()
        .route("/", get(index))
        .route("/healthz", get(health))
        .route("/login", get(login))
        .route("/login/callback", get(login_callback))
        .route("/logout", post(logout))
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

/// Fetches (and caches) the OIDC discovery document for the issuer.
async fn discovery(state: &AppState, issuer: &str) -> Result<Discovery, String> {
    if let Some(cached) = state.inner.discovery.lock().unwrap().clone() {
        return Ok(cached);
    }
    if issuer.is_empty() {
        return Err("SEARCH_OIDC_ISSUER must be set".to_string());
    }
    let url = format!(
        "{}/.well-known/openid-configuration",
        issuer.trim_end_matches('/')
    );
    let response: serde_json::Value = state
        .inner
        .http
        .get(&url)
        .send()
        .await
        .map_err(|err| format!("failed to reach OIDC discovery: {err}"))?
        .json()
        .await
        .map_err(|err| format!("failed to parse OIDC discovery: {err}"))?;
    let endpoint = |name: &str| -> Result<String, String> {
        response
            .get(name)
            .and_then(serde_json::Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| format!("OIDC discovery is missing '{name}'"))
    };
    let found = Discovery {
        authorization_endpoint: endpoint("authorization_endpoint")?,
        token_endpoint: endpoint("token_endpoint")?,
        userinfo_endpoint: endpoint("userinfo_endpoint")?,
    };
    *state.inner.discovery.lock().unwrap() = Some(found.clone());
    Ok(found)
}

fn session_cookie(headers: &HeaderMap) -> Option<String> {
    let cookies = headers.get(header::COOKIE)?.to_str().ok()?;
    for pair in cookies.split(';') {
        let pair = pair.trim();
        if let Some((name, value)) = pair.split_once('=') {
            if name == SESSION_COOKIE && !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn current_session(state: &AppState, headers: &HeaderMap) -> Option<Session> {
    let cookie = session_cookie(headers)?;
    let mut sessions = state.inner.sessions.lock().unwrap();
    let session = sessions.get(&cookie).cloned()?;
    if session.expires_at < crate::timeutil::now_epoch() {
        sessions.remove(&cookie);
        return None;
    }
    Some(session)
}

async fn index(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match current_session(&state, &headers) {
        Some(_) => Html(include_str!("ui.html")).into_response(),
        None => Redirect::to("/login").into_response(),
    }
}

async fn login(State(state): State<AppState>) -> Response {
    let discovery = match discovery(&state, &env_or("SEARCH_OIDC_ISSUER", "")).await {
        Ok(discovery) => discovery,
        Err(err) => return (StatusCode::SERVICE_UNAVAILABLE, err).into_response(),
    };
    let app_base = env_or("SEARCH_APP_BASE", "");
    if app_base.is_empty() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "SEARCH_APP_BASE must be set",
        )
            .into_response();
    }
    let mut state_bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut state_bytes);
    let state_value = hex(&state_bytes);
    let created = crate::timeutil::now_epoch();
    state
        .inner
        .pending_states
        .lock()
        .unwrap()
        .insert(state_value.clone(), created);

    let redirect_uri = format!("{}/login/callback", app_base.trim_end_matches('/'));
    let authorize = form_urlencoded::Serializer::new(String::new())
        .append_pair("response_type", "code")
        .append_pair("client_id", &env_or("SEARCH_OIDC_CLIENT_ID", "search-web"))
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("scope", "openid profile email groups_name")
        .append_pair("state", &state_value)
        .finish();
    Redirect::to(&format!("{}?{authorize}", discovery.authorization_endpoint)).into_response()
}

async fn login_callback(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let code = params.get("code").cloned().unwrap_or_default();
    let returned_state = params.get("state").cloned().unwrap_or_default();
    if code.is_empty() || returned_state.is_empty() {
        return (StatusCode::BAD_REQUEST, "missing code or state").into_response();
    }
    if state
        .inner
        .pending_states
        .lock()
        .unwrap()
        .remove(&returned_state)
        .is_none()
    {
        return (StatusCode::BAD_REQUEST, "unknown login state").into_response();
    }

    let discovery = match discovery(&state, &env_or("SEARCH_OIDC_ISSUER", "")).await {
        Ok(discovery) => discovery,
        Err(err) => return (StatusCode::SERVICE_UNAVAILABLE, err).into_response(),
    };
    let app_base = env_or("SEARCH_APP_BASE", "");
    let redirect_uri = format!("{}/login/callback", app_base.trim_end_matches('/'));
    let client_secret = std::env::var("SEARCH_OIDC_CLIENT_SECRET_FILE")
        .map(|path| read_secret_file(std::path::Path::new(&path)).unwrap_or_default())
        .unwrap_or_default();

    let token_response: serde_json::Value = match state
        .inner
        .http
        .post(&discovery.token_endpoint)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("redirect_uri", redirect_uri.as_str()),
            (
                "client_id",
                env_or("SEARCH_OIDC_CLIENT_ID", "search-web").as_str(),
            ),
            ("client_secret", client_secret.trim()),
        ])
        .send()
        .await
    {
        Ok(response) => match response.json().await {
            Ok(value) => value,
            Err(err) => {
                return (
                    StatusCode::BAD_GATEWAY,
                    format!("token parse failed: {err}"),
                )
                    .into_response()
            }
        },
        Err(err) => {
            return (
                StatusCode::BAD_GATEWAY,
                format!("token request failed: {err}"),
            )
                .into_response()
        }
    };
    let access_token = token_response
        .get("access_token")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_string();
    if access_token.is_empty() {
        return (
            StatusCode::BAD_GATEWAY,
            "OIDC token response contained no access token",
        )
            .into_response();
    }

    let userinfo: serde_json::Value = match state
        .inner
        .http
        .get(&discovery.userinfo_endpoint)
        .bearer_auth(&access_token)
        .send()
        .await
    {
        Ok(response) => match response.json().await {
            Ok(value) => value,
            Err(err) => {
                return (
                    StatusCode::BAD_GATEWAY,
                    format!("userinfo parse failed: {err}"),
                )
                    .into_response()
            }
        },
        Err(err) => {
            return (
                StatusCode::BAD_GATEWAY,
                format!("userinfo request failed: {err}"),
            )
                .into_response()
        }
    };

    let username = userinfo
        .get("preferred_username")
        .and_then(serde_json::Value::as_str)
        .or_else(|| userinfo.get("sub").and_then(serde_json::Value::as_str))
        .unwrap_or("unknown")
        .to_string();
    let groups = parse_groups(&userinfo);

    let mut session_bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut session_bytes);
    let session_id = hex(&session_bytes);
    let expires_at = crate::timeutil::now_epoch() + SESSION_TTL_SECONDS;
    state.inner.sessions.lock().unwrap().insert(
        session_id.clone(),
        Session {
            username: username.clone(),
            groups: groups.clone(),
            expires_at,
        },
    );

    let cookie = format!(
        "{SESSION_COOKIE}={session_id}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECONDS}"
    );
    (
        StatusCode::FOUND,
        [
            (header::SET_COOKIE, cookie),
            (header::LOCATION, "/".to_string()),
        ],
    )
        .into_response()
}

fn parse_groups(userinfo: &serde_json::Value) -> Vec<String> {
    let Some(groups) = userinfo.get("groups") else {
        return Vec::new();
    };
    match groups {
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|item| match item {
                serde_json::Value::String(name) => Some(name.clone()),
                serde_json::Value::Object(object) => object
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Some(cookie) = session_cookie(&headers) {
        state.inner.sessions.lock().unwrap().remove(&cookie);
    }
    let cleared = format!("{SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0");
    let target = if state.inner.logout_redirect.is_empty() {
        "/".to_string()
    } else {
        state.inner.logout_redirect.clone()
    };
    (
        StatusCode::FOUND,
        [(header::SET_COOKIE, cleared), (header::LOCATION, target)],
    )
        .into_response()
}

/// Returns the shared, lazily-connected source-listing client. A failed
/// query evicts it so the next request reconnects instead of retrying a dead
/// connection forever.
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

/// Resolves the sources the current user may search.
async fn allowed_sources(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(Session, Vec<UiSource>), Box<Response>> {
    let Some(session) = current_session(state, headers) else {
        return Err(Box::new(
            (StatusCode::UNAUTHORIZED, "not signed in").into_response(),
        ));
    };
    let client = match shared_db_client(state).await {
        Ok(client) => client,
        Err(err) => {
            return Err(Box::new(
                (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
            ))
        }
    };
    let sources = match db::list_sources(&client).await {
        Ok(sources) => sources,
        Err(err) => {
            *state.inner.db.lock().await = None;
            return Err(Box::new(
                (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
            ));
        }
    };
    let allowed: Vec<UiSource> = sources
        .into_iter()
        .filter(|source| match &source.acl_group {
            Some(group) => session.groups.iter().any(|claimed| claimed == group),
            None => true,
        })
        .collect();
    Ok((session, allowed))
}

async fn api_sources(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match allowed_sources(&state, &headers).await {
        Ok((_session, sources)) => Json(json!({
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
    source: Option<String>,
    #[serde(default)]
    page: Option<usize>,
}

async fn api_search(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Response {
    let (session, allowed) = match allowed_sources(&state, &headers).await {
        Ok(result) => result,
        Err(response) => return *response,
    };
    let query = params.q.trim().to_string();
    if query.is_empty() {
        return Json(json!({ "hits": [], "total": 0 })).into_response();
    }

    let mut selected: Vec<&str> = allowed.iter().map(|source| source.id.as_str()).collect();
    if let Some(requested) = params.source.as_deref() {
        selected.retain(|source| *source == requested);
    }
    if selected.is_empty() {
        return Json(json!({ "hits": [], "total": 0, "message": "no sources available" }))
            .into_response();
    }

    let page = params.page.unwrap_or(0);
    let rows = MAX_RESULTS;
    let offset = page.saturating_mul(rows);
    eprintln!(
        "search: user '{}' queried {:?} across {:?}",
        session.username, query, selected
    );

    // Federate article hits from the ZIM archives' native Xapian indexes when
    // the kiwix source participates in this search. Index-less ZIMs are
    // already covered by Solr (the fallback extractor), so only Xapian-bearing
    // archives are queried here, avoiding duplicate results. ZIM hits are
    // pinned to the first page: they have no pagination of their own, and
    // re-prepending them on every page would repeat them and displace the
    // next Solr window.
    let include_zim_hits = page == 0;
    let zim_hits = if include_zim_hits {
        federate_zims(&state, &selected, &query).await
    } else {
        Vec::new()
    };

    match state
        .inner
        .solr
        .search(&query, &selected, rows, offset)
        .await
    {
        Ok(response) => {
            let mut hits: Vec<serde_json::Value> = zim_hits
                .iter()
                .map(|hit| {
                    json!({
                        "id": format!("kiwix:{}", crate::timeutil::sha256_hex(&[&hit.origin_url])),
                        "source": "kiwix",
                        "title": hit.title,
                        "snippet": hit.snippet,
                        "originUrl": hit.origin_url,
                        "appUrl": hit.app_url,
                        "contentType": "text/html",
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
                    "score": hit.score,
                    "created": hit.created,
                }));
            }
            // No truncate: Solr already returns at most `rows`, so truncating
            // the merged list would silently drop the tail of the Solr window.
            Json(json!({
                "hits": hits,
                "total": response.total + if include_zim_hits { zim_hits.len() as u64 } else { 0 },
                "sourceFacets": response.source_facets.iter().map(|(name, count)| json!({ "name": name, "count": count })).collect::<Vec<_>>(),
                "contentTypeFacets": response.content_type_facets.iter().map(|(name, count)| json!({ "name": name, "count": count })).collect::<Vec<_>>(),
            }))
            .into_response()
        }
        Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
    }
}

/// Queries the ZIM archives' native Xapian indexes for any kiwix source that is
/// part of the current search, returning merged article hits. Never fails the
/// whole request: unavailable archives or tools are skipped inside `zim_search`.
async fn federate_zims(state: &AppState, selected: &[&str], query: &str) -> Vec<ZimHit> {
    let mut hits: Vec<ZimHit> = Vec::new();
    for source in &state.inner.settings.sources {
        if source.source_type != "kiwix" || !selected.contains(&source.id.as_str()) {
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

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_group_claims() {
        let string_form = json!({ "groups": ["kiwix-users", "paperless-users"] });
        assert_eq!(
            parse_groups(&string_form),
            vec!["kiwix-users", "paperless-users"]
        );
        let object_form = json!({ "groups": [ { "name": "mail-archive-users" } ] });
        assert_eq!(parse_groups(&object_form), vec!["mail-archive-users"]);
        assert_eq!(parse_groups(&json!({})), Vec::<String>::new());
        assert_eq!(
            parse_groups(&json!({ "groups": "x" })),
            Vec::<String>::new()
        );
    }

    #[test]
    fn finds_session_cookie() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            "other=1; search_session=abc123".parse().expect("cookie"),
        );
        assert_eq!(
            session_cookie(&headers).as_deref(),
            Some("abc123".to_string()).as_deref()
        );
        let mut empty = HeaderMap::new();
        empty.insert(header::COOKIE, "other=1".parse().expect("cookie"));
        assert_eq!(session_cookie(&empty), None);
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
