//! Persistent cache for external metadata lookups.
//!
//! Provider searches and detail lookups are keyed by the caller, provider,
//! operation and canonical request so repeated lookups for the same title reuse
//! one stored result for a week. Entries are best effort: a missing, corrupt or
//! unavailable cache only means the provider is asked again.

use crate::http::ApiError;
use axum::{
    body::{to_bytes, Body, HttpBody},
    extract::{Request, State},
    http::{header::CONTENT_TYPE, Method, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use homelab_common::{request_id, sha256_hex};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

/// Lookup responses change rarely; a week avoids re-querying providers on every
/// visit while still refreshing series, editions and ratings eventually.
pub(crate) const LOOKUP_CACHE_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const MAX_ENTRIES: i64 = 10_000;
const MAX_CACHE_BYTES: i64 = 64 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const SQLITE_BUSY_TIMEOUT: Duration = Duration::from_secs(2);

/// A disabled cache keeps tests and unconfigured callers on the direct provider
/// path without creating a database.
#[derive(Clone)]
pub(crate) struct LookupCache {
    database_path: Option<PathBuf>,
}

impl LookupCache {
    pub(crate) fn open(database_path: &Path) -> Result<Self, String> {
        if let Some(parent) = database_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("create lookup cache directory: {error}"))?;
        }
        let connection = Connection::open(database_path)
            .map_err(|error| format!("open lookup cache: {error}"))?;
        connection
            .busy_timeout(SQLITE_BUSY_TIMEOUT)
            .map_err(|error| format!("configure lookup cache: {error}"))?;
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA synchronous=NORMAL;
                 CREATE TABLE IF NOT EXISTS lookup_cache (
                     cache_key TEXT PRIMARY KEY,
                     scope TEXT NOT NULL,
                     subject TEXT NOT NULL,
                     created_at INTEGER NOT NULL,
                     payload TEXT NOT NULL
                 ) WITHOUT ROWID;
                 CREATE INDEX IF NOT EXISTS lookup_cache_created_at
                     ON lookup_cache(created_at);
                 CREATE INDEX IF NOT EXISTS lookup_cache_scope_subject
                     ON lookup_cache(scope, subject);",
            )
            .map_err(|error| format!("initialize lookup cache: {error}"))?;
        Ok(Self {
            database_path: Some(database_path.to_path_buf()),
        })
    }

    pub(crate) fn disabled() -> Self {
        Self {
            database_path: None,
        }
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.database_path.is_some()
    }

    pub(crate) async fn get(&self, cache_key: &str) -> Option<Value> {
        let database_path = self.database_path.clone()?;
        let cache_key = cache_key.to_string();
        tokio::task::spawn_blocking(move || read_entry(&database_path, &cache_key))
            .await
            .ok()
            .flatten()
    }

    pub(crate) async fn put(&self, cache_key: String, scope: &str, subject: &str, value: Value) {
        let Some(database_path) = self.database_path.clone() else {
            return;
        };
        let Ok(payload) = serde_json::to_string(&value) else {
            return;
        };
        let scope = scope.to_string();
        let subject = subject.to_string();
        let _ = tokio::task::spawn_blocking(move || {
            write_entry(&database_path, &cache_key, &scope, &subject, &payload)
        })
        .await;
    }

    /// Drop lookups that could depend on a provider account that changed.
    pub(crate) async fn invalidate(&self, scope: &str, subject: &str) {
        let Some(database_path) = self.database_path.clone() else {
            return;
        };
        let scope = scope.to_string();
        let subject = subject.to_string();
        let _ = tokio::task::spawn_blocking(move || {
            let Ok(connection) = open_connection(&database_path) else {
                return;
            };
            let _ = connection.execute(
                "DELETE FROM lookup_cache WHERE scope = ?1 AND subject = ?2",
                params![scope, subject],
            );
        })
        .await;
    }
}

fn open_connection(database_path: &Path) -> rusqlite::Result<Connection> {
    let connection = Connection::open(database_path)?;
    connection.busy_timeout(SQLITE_BUSY_TIMEOUT)?;
    Ok(connection)
}

fn read_entry(database_path: &Path, cache_key: &str) -> Option<Value> {
    let connection = open_connection(database_path).ok()?;
    let entry = connection
        .query_row(
            "SELECT created_at, payload FROM lookup_cache WHERE cache_key = ?1",
            params![cache_key],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()
        .ok()??;
    let (created_at, payload) = entry;
    if crate::http::unix_timestamp().saturating_sub(created_at) > LOOKUP_CACHE_TTL_SECONDS {
        let _ = connection.execute(
            "DELETE FROM lookup_cache WHERE cache_key = ?1",
            params![cache_key],
        );
        return None;
    }
    serde_json::from_str(&payload).ok()
}

fn write_entry(
    database_path: &Path,
    cache_key: &str,
    scope: &str,
    subject: &str,
    payload: &str,
) -> rusqlite::Result<()> {
    let connection = open_connection(database_path)?;
    let now = crate::http::unix_timestamp();
    connection.execute(
        "INSERT INTO lookup_cache (cache_key, scope, subject, created_at, payload)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(cache_key) DO UPDATE SET
           scope = excluded.scope,
           subject = excluded.subject,
           created_at = excluded.created_at,
           payload = excluded.payload",
        params![cache_key, scope, subject, now, payload],
    )?;
    let _ = connection.execute(
        "DELETE FROM lookup_cache WHERE created_at < ?1",
        params![now - LOOKUP_CACHE_TTL_SECONDS],
    );
    let _ = connection.execute(
        "DELETE FROM lookup_cache WHERE cache_key IN (
             SELECT cache_key FROM lookup_cache
             ORDER BY created_at DESC
             LIMIT -1 OFFSET ?1
         )",
        params![MAX_ENTRIES],
    );
    prune_to_byte_budget(&connection);
    Ok(())
}

/// Oldest entries go first so a few large provider payloads cannot grow the
/// cache beyond its budget.
fn prune_to_byte_budget(connection: &Connection) {
    let Ok(mut total) = connection.query_row(
        "SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM lookup_cache",
        [],
        |row| row.get::<_, i64>(0),
    ) else {
        return;
    };
    if total <= MAX_CACHE_BYTES {
        return;
    }
    let Ok(mut statement) = connection
        .prepare("SELECT cache_key, LENGTH(payload) FROM lookup_cache ORDER BY created_at")
    else {
        return;
    };
    let mut excess = Vec::new();
    if let Ok(mut rows) = statement.query([]) {
        while total > MAX_CACHE_BYTES {
            let Ok(Some(row)) = rows.next() else {
                break;
            };
            let Ok(cache_key) = row.get::<_, String>(0) else {
                break;
            };
            total -= row.get::<_, i64>(1).unwrap_or_default();
            excess.push(cache_key);
        }
    }
    drop(statement);
    for cache_key in excess {
        let _ = connection.execute(
            "DELETE FROM lookup_cache WHERE cache_key = ?1",
            params![cache_key],
        );
    }
}

/// Provider-broker search and detail responses, plus Open Library edition pages.
pub(crate) async fn cache_provider_lookups(
    State(cache): State<Arc<LookupCache>>,
    request: Request,
    next: Next,
) -> Response {
    let scope = provider_lookup_scope(&request);
    serve_cached(cache, scope, request, next).await
}

/// Music lookup and the legacy direct TMDB lookups in the web process.
pub(crate) async fn cache_media_metadata_lookups(
    State(cache): State<Arc<LookupCache>>,
    request: Request,
    next: Next,
) -> Response {
    let scope = media_metadata_scope(&request);
    serve_cached(cache, scope, request, next).await
}

fn provider_lookup_scope(request: &Request) -> Option<String> {
    let path = request.uri().path();
    let rest = path.strip_prefix("/api/v1/provider-lookups/")?;
    let (provider, suffix) = rest.split_once('/')?;
    if provider.is_empty()
        || provider.len() > 64
        // Subtitle availability changes often and is not item metadata.
        || matches!(provider, "opensubtitles" | "subdl")
    {
        return None;
    }
    let cacheable = match (request.method(), suffix) {
        (&Method::POST, "search" | "details") => true,
        (&Method::GET, suffix) => suffix.starts_with("works/") && suffix.ends_with("/editions"),
        _ => false,
    };
    cacheable.then(|| provider.to_string())
}

fn media_metadata_scope(request: &Request) -> Option<String> {
    if request.method() != Method::POST {
        return None;
    }
    let path = request.uri().path();
    if matches!(
        path,
        "/api/v1/metadata/tmdb/search" | "/api/v1/metadata/tmdb/details"
    ) {
        return Some("tmdb".to_string());
    }
    (path.starts_with("/api/v1/items/") && path.ends_with("/metadata/lookup"))
        .then(|| "musicbrainz".to_string())
}

async fn serve_cached(
    cache: Arc<LookupCache>,
    scope: Option<String>,
    request: Request,
    next: Next,
) -> Response {
    if !cache.is_enabled() {
        return next.run(request).await;
    }
    let Some(scope) = scope else {
        return next.run(request).await;
    };
    let (parts, body) = request.into_parts();
    let Ok(identity) = crate::config::Identity::try_from_forwarded_headers(&parts.headers) else {
        return next.run(Request::from_parts(parts, body)).await;
    };
    let groups = identity.groups.join(",");
    let body = match to_bytes(body, MAX_REQUEST_BYTES).await {
        Ok(body) => body,
        Err(_) => {
            return ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "request_body_too_large",
                "The provider lookup request is too large.",
                request_id(),
            )
            .into_response();
        }
    };
    // JSON objects serialize with sorted keys, so whitespace and member order
    // do not create duplicate cache entries for the same search.
    let canonical_body = serde_json::from_slice::<Value>(&body)
        .ok()
        .and_then(|value| serde_json::to_vec(&value).ok())
        .unwrap_or_else(|| body.to_vec());
    let cache_key = lookup_cache_key(
        &scope,
        &identity.subject,
        &groups,
        parts.method.as_str(),
        &parts.uri.to_string(),
        &canonical_body,
    );
    if let Some(mut value) = cache.get(&cache_key).await {
        if let Some(object) = value.as_object_mut()
            && object.contains_key("requestId")
        {
            object.insert("requestId".to_string(), Value::String(request_id()));
        }
        return Json(value).into_response();
    }
    let response = next.run(Request::from_parts(parts, Body::from(body))).await;
    store_response(&cache, cache_key, &scope, &identity.subject, response).await
}

async fn store_response(
    cache: &LookupCache,
    cache_key: String,
    scope: &str,
    subject: &str,
    response: Response,
) -> Response {
    let cacheable_json = response.status().is_success()
        && response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.starts_with("application/json"));
    if !cacheable_json
        || response
            .body()
            .size_hint()
            .upper()
            .is_none_or(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return response;
    }
    let (parts, body) = response.into_parts();
    let bytes = match to_bytes(body, MAX_RESPONSE_BYTES).await {
        Ok(bytes) => bytes,
        Err(_) => return ApiError::internal(request_id()).into_response(),
    };
    if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
        cache.put(cache_key, scope, subject, value).await;
    }
    Response::from_parts(parts, Body::from(bytes))
}

fn lookup_cache_key(
    scope: &str,
    subject: &str,
    groups: &str,
    method: &str,
    uri: &str,
    body: &[u8],
) -> String {
    let mut material = Vec::with_capacity(
        scope.len() + subject.len() + groups.len() + method.len() + uri.len() + body.len() + 48,
    );
    for part in [
        scope.as_bytes(),
        subject.as_bytes(),
        groups.as_bytes(),
        method.as_bytes(),
        uri.as_bytes(),
    ] {
        material.extend_from_slice(&(part.len() as u64).to_be_bytes());
        material.extend_from_slice(part);
    }
    material.extend_from_slice(&(body.len() as u64).to_be_bytes());
    material.extend_from_slice(body);
    sha256_hex(&material)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cache_with_age(database_path: &Path, age_seconds: i64) -> LookupCache {
        let cache = LookupCache::open(database_path).expect("cache");
        let connection = Connection::open(database_path).expect("connection");
        connection
            .execute(
                "INSERT OR REPLACE INTO lookup_cache
                 (cache_key, scope, subject, created_at, payload)
                 VALUES ('key', 'tmdb', 'owner', ?1, ?2)",
                params![
                    crate::http::unix_timestamp() - age_seconds,
                    r#"{"results":[{"title":"Arrival"}]}"#
                ],
            )
            .expect("insert entry");
        cache
    }

    #[tokio::test]
    async fn entries_are_reused_within_the_week_and_expire_afterwards() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let database_path = temp.path().join("lookups.sqlite3");

        let fresh = cache_with_age(&database_path, LOOKUP_CACHE_TTL_SECONDS - 60);
        assert_eq!(
            fresh.get("key").await.expect("cached value")["results"][0]["title"],
            "Arrival"
        );

        let expired = cache_with_age(&database_path, LOOKUP_CACHE_TTL_SECONDS + 1);
        assert!(expired.get("key").await.is_none());
    }

    #[tokio::test]
    async fn account_invalidation_drops_only_that_callers_provider_entries() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let cache = LookupCache::open(&temp.path().join("lookups.sqlite3")).expect("cache");
        cache
            .put("tmdb-key".into(), "tmdb", "owner", json!({"results": []}))
            .await;
        cache
            .put(
                "open-library-key".into(),
                "open-library",
                "owner",
                json!({"results": []}),
            )
            .await;
        cache
            .put("other-key".into(), "tmdb", "other", json!({"results": []}))
            .await;

        cache.invalidate("tmdb", "owner").await;

        assert!(cache.get("tmdb-key").await.is_none());
        assert!(cache.get("open-library-key").await.is_some());
        assert!(cache.get("other-key").await.is_some());
    }

    #[tokio::test]
    async fn media_metadata_middleware_reuses_one_music_lookup() {
        use axum::{routing::post, Router};
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tower::ServiceExt;

        let temp = tempfile::tempdir().expect("temporary directory");
        let cache =
            Arc::new(LookupCache::open(&temp.path().join("lookups.sqlite3")).expect("cache"));
        let calls = Arc::new(AtomicUsize::new(0));
        let handler_calls = calls.clone();
        let app = Router::new()
            .route(
                "/api/v1/items/{item_id}/metadata/lookup",
                post(move || {
                    let calls = handler_calls.clone();
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Json(json!({"candidates": [], "requestId": "fresh"}))
                    }
                }),
            )
            .layer(axum::middleware::from_fn_with_state(
                cache,
                cache_media_metadata_lookups,
            ));

        let request = || {
            Request::builder()
                .method("POST")
                .uri("/api/v1/items/item-1/metadata/lookup")
                .header("content-type", "application/json")
                .header("x-forwarded-user", "owner")
                .header("x-forwarded-preferred-username", "owner")
                .header("x-forwarded-groups", "users")
                .body(Body::from(r#"{"mode":"search","title":"Dune"}"#))
                .expect("request")
        };
        let first = app.clone().oneshot(request()).await.expect("first lookup");
        assert_eq!(first.status(), StatusCode::OK);
        let second = app.oneshot(request()).await.expect("cached lookup");
        assert_eq!(second.status(), StatusCode::OK);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let body = to_bytes(second.into_body(), 4096).await.expect("body");
        let value: Value = serde_json::from_slice(&body).expect("JSON");
        assert_ne!(value["requestId"], "fresh");
        assert!(value["requestId"].as_str().is_some_and(|id| !id.is_empty()));
    }

    #[test]
    fn keys_change_with_scope_subject_groups_uri_and_body() {
        let base = lookup_cache_key(
            "tmdb",
            "owner",
            "users",
            "POST",
            "/search",
            b"{\"query\":\"Dune\"}",
        );
        assert_eq!(
            base,
            lookup_cache_key(
                "tmdb",
                "owner",
                "users",
                "POST",
                "/search",
                b"{\"query\":\"Dune\"}"
            )
        );
        assert_ne!(
            base,
            lookup_cache_key(
                "tmdb",
                "owner",
                "users",
                "POST",
                "/search",
                b"{\"query\":\"Arrival\"}"
            )
        );
        assert_ne!(
            base,
            lookup_cache_key(
                "tmdb",
                "other",
                "users",
                "POST",
                "/search",
                b"{\"query\":\"Dune\"}"
            )
        );
        assert_ne!(
            base,
            lookup_cache_key(
                "tmdb",
                "owner",
                "users,editors",
                "POST",
                "/search",
                b"{\"query\":\"Dune\"}"
            )
        );
    }
}
