use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use cap_std::{ambient_authority, fs::Dir};
use futures_util::StreamExt;
use jsonwebtoken::{
    decode, decode_header,
    jwk::{Jwk, JwkSet},
    Algorithm, DecodingKey, Validation,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    io::{self, Read},
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::AsyncWriteExt,
    sync::{Mutex, RwLock},
};
use tokio_util::io::ReaderStream;
use uuid::Uuid;

mod manifest;

use manifest::{CachedManifest, LocalFile, ManifestKey};

const SERVICE: &str = "filesync-api";

/// One estimate request carries one `(path, size, mtime)` record per device
/// file, so a large library can exceed axum's 2 MiB default body limit.
const ESTIMATE_BODY_LIMIT: usize = 64 * 1024 * 1024;

/// Minimum spacing between JWKS refreshes triggered by an unknown `kid`.
const JWKS_REFRESH_MIN_INTERVAL: Duration = Duration::from_secs(60);

/// Reserved root id that stands for the personal folder itself rather than one
/// of its library folders. It lets a client start browsing at the top of a
/// user's own libraries instead of inside a single one.
const HOME_ROOT_ID: &str = "home";

#[derive(Clone)]
struct Settings {
    listen: String,
    issuer: String,
    audience: String,
    users_root: PathBuf,
    client_id: String,
    redirect_uri: String,
    roots: Vec<SyncRoot>,
}

impl Settings {
    fn from_env() -> Result<Self, String> {
        let issuer = required_env("FILESYNC_OIDC_ISSUER")?;
        let client_id = required_env("FILESYNC_OIDC_CLIENT_ID")?;
        Ok(Self {
            listen: env::var("FILESYNC_LISTEN").unwrap_or_else(|_| "127.0.0.1:8335".into()),
            issuer: issuer.clone(),
            audience: client_id.clone(),
            users_root: PathBuf::from(required_env("FILESYNC_USERS_ROOT")?),
            client_id,
            redirect_uri: env::var("FILESYNC_OIDC_REDIRECT_URI")
                .unwrap_or_else(|_| "filesync://oauth/callback".into()),
            roots: serde_json::from_str(&required_env("FILESYNC_ROOTS_JSON")?)
                .map_err(|error| format!("FILESYNC_ROOTS_JSON is invalid: {error}"))?,
        })
    }
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name).map_err(|_| format!("{name} is required"))
}

struct AppState {
    settings: Settings,
    http: reqwest::Client,
    jwks_uri: String,
    userinfo_endpoint: String,
    jwks: RwLock<JwkSet>,
    /// Serializes JWKS refreshes so a burst of unknown-`kid` requests triggers
    /// one fetch instead of one per request.
    jwks_refresh: Mutex<()>,
    /// When the JWKS was last fetched, to bound outbound refreshes.
    jwks_refreshed_at: RwLock<Instant>,
    identities: RwLock<HashMap<String, CachedIdentity>>,
    /// Server-side folder manifests, keyed by (username, root id, path).
    /// Holds the recursive walk and any hashes it produced so a repeated
    /// estimate costs one directory walk instead of one hashed read per file.
    manifests: RwLock<HashMap<ManifestKey, CachedManifest>>,
}

#[derive(Clone)]
struct CachedIdentity {
    username: String,
    exp: u64,
}

#[derive(Debug, Deserialize)]
struct OidcMetadata {
    issuer: String,
    jwks_uri: String,
    userinfo_endpoint: String,
}

#[derive(Debug, Deserialize)]
struct AccessTokenClaims {
    iss: String,
    aud: Audience,
    exp: u64,
}

#[derive(Debug, Deserialize)]
struct UserInfoClaims {
    preferred_username: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

impl Audience {
    fn contains(&self, expected: &str) -> bool {
        match self {
            Self::One(value) => value == expected,
            Self::Many(values) => values.iter().any(|value| value == expected),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApiError {
    error: ErrorDetail,
}

#[derive(Serialize)]
struct ErrorDetail {
    code: &'static str,
    message: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApiConfig {
    issuer: String,
    client_id: String,
    redirect_uri: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Identity {
    username: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    name: String,
    path: String,
    kind: &'static str,
    size: u64,
    modified_unix_ms: u128,
    sha256: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncRoot {
    id: String,
    folder: String,
    service: String,
    service_title: String,
    title: String,
    description: String,
    server_path: String,
    local_subpath: String,
    direction: String,
}

#[derive(Deserialize)]
struct PathQuery {
    path: Option<String>,
    hashes: Option<bool>,
    root: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let settings = Settings::from_env().map_err(io::Error::other)?;
    let issuer_url = reqwest::Url::parse(&settings.issuer)?;
    if issuer_url.scheme() != "https" || issuer_url.host_str().is_none() {
        return Err(io::Error::other("FILESYNC_OIDC_ISSUER must be an HTTPS URL").into());
    }
    let http = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let metadata_url = format!(
        "{}/.well-known/openid-configuration",
        settings.issuer.trim_end_matches('/')
    );
    let metadata: OidcMetadata = http
        .get(metadata_url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    if metadata.issuer != settings.issuer {
        return Err(io::Error::other(
            "Kanidm discovery issuer does not match FILESYNC_OIDC_ISSUER",
        )
        .into());
    }
    let jwks_url = reqwest::Url::parse(&metadata.jwks_uri)?;
    if jwks_url.scheme() != "https" || jwks_url.host_str().is_none() {
        return Err(io::Error::other("Kanidm JWKS URL must use HTTPS").into());
    }
    let jwks = fetch_jwks(&http, &metadata.jwks_uri).await?;
    let userinfo_url = reqwest::Url::parse(&metadata.userinfo_endpoint)?;
    if userinfo_url.scheme() != "https" || userinfo_url.host_str().is_none() {
        return Err(io::Error::other("Kanidm userinfo URL must use HTTPS").into());
    }
    let state = Arc::new(AppState {
        settings,
        http,
        jwks_uri: metadata.jwks_uri,
        userinfo_endpoint: metadata.userinfo_endpoint,
        jwks: RwLock::new(jwks),
        jwks_refresh: Mutex::new(()),
        jwks_refreshed_at: RwLock::new(Instant::now()),
        identities: RwLock::new(HashMap::new()),
        manifests: RwLock::new(HashMap::new()),
    });

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/api/v1/config", get(config))
        .route("/api/v1/me", get(me))
        .route("/api/v1/presets", get(presets))
        .route("/api/v1/library-sizes", get(library_sizes))
        .route(
            "/api/v1/estimate",
            post(estimate).layer(DefaultBodyLimit::max(ESTIMATE_BODY_LIMIT)),
        )
        .route("/api/v1/tree", get(tree))
        .route("/api/v1/file", get(download).put(upload))
        .with_state(state.clone());

    let listener = tokio::net::TcpListener::bind(&state.settings.listen).await?;
    eprintln!("{SERVICE} listening on {}", state.settings.listen);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    // systemd stops the unit with SIGTERM, so drain in-flight transfers on it
    // too rather than letting the default disposition cut them off.
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}

async fn fetch_jwks(
    client: &reqwest::Client,
    uri: &str,
) -> Result<JwkSet, Box<dyn std::error::Error + Send + Sync>> {
    Ok(client
        .get(uri)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

/// Return the decoding key for `kid`, refreshing the JWKS at most once per
/// `JWKS_REFRESH_MIN_INTERVAL`.
///
/// The refresh is serialized and rate-limited: without it an unauthenticated
/// caller could send a valid-shaped token with an arbitrary `kid` and force an
/// outbound fetch to Kanidm on every request.
async fn jwk_for(state: &AppState, kid: &str) -> Result<Option<Jwk>, ()> {
    if let Some(jwk) = state.jwks.read().await.find(kid).cloned() {
        return Ok(Some(jwk));
    }
    let _guard = state.jwks_refresh.lock().await;
    // Another task may have refreshed while this one waited for the lock.
    if let Some(jwk) = state.jwks.read().await.find(kid).cloned() {
        return Ok(Some(jwk));
    }
    if state.jwks_refreshed_at.read().await.elapsed() < JWKS_REFRESH_MIN_INTERVAL {
        return Ok(None);
    }
    match fetch_jwks(&state.http, &state.jwks_uri).await {
        Ok(fresh) => {
            let found = fresh.find(kid).cloned();
            *state.jwks.write().await = fresh;
            *state.jwks_refreshed_at.write().await = Instant::now();
            Ok(found)
        }
        Err(_) => Err(()),
    }
}

async fn authenticate(state: &AppState, headers: &HeaderMap) -> Result<String, Response> {
    let Some(raw) = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "UNAUTHENTICATED",
            "Sign in with Kanidm to continue.",
        ));
    };
    let Some(token) = raw.strip_prefix("Bearer ") else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "UNAUTHENTICATED",
            "A bearer access token is required.",
        ));
    };
    let header = decode_header(token).map_err(|_| {
        api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token is invalid.",
        )
    })?;
    if header.alg != Algorithm::ES256 {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token uses an unsupported signature algorithm.",
        ));
    }
    let Some(kid) = header.kid.as_deref() else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token has no signing key id.",
        ));
    };

    let jwk = match jwk_for(state, kid).await {
        Ok(Some(jwk)) => jwk,
        Ok(None) => {
            return Err(api_error(
                StatusCode::UNAUTHORIZED,
                "INVALID_TOKEN",
                "The access token signing key is unknown.",
            ))
        }
        Err(()) => {
            return Err(api_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "IDENTITY_UNAVAILABLE",
                "Kanidm signing keys could not be refreshed.",
            ))
        }
    };
    let key = DecodingKey::from_jwk(&jwk).map_err(|_| {
        api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token signing key is invalid.",
        )
    })?;
    let mut validation = Validation::new(Algorithm::ES256);
    validation.set_issuer(&[state.settings.issuer.as_str()]);
    validation.set_audience(&[state.settings.audience.as_str()]);
    let data = decode::<AccessTokenClaims>(token, &key, &validation).map_err(|_| {
        api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token is expired or invalid.",
        )
    })?;
    let claims = data.claims;
    if claims.iss != state.settings.issuer
        || !claims.aud.contains(&state.settings.audience)
        || claims.exp <= unix_now()
    {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token does not authorize this application.",
        ));
    }
    let username = identity_for_token(state, token, claims.exp).await?;
    if !valid_username(&username) {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "INVALID_IDENTITY",
            "The Kanidm identity cannot be mapped to a server user.",
        ));
    }
    Ok(username)
}

async fn identity_for_token(
    state: &AppState,
    token: &str,
    token_exp: u64,
) -> Result<String, Response> {
    let cache_key = format!("{:x}", Sha256::digest(token.as_bytes()));
    if let Some(entry) = state.identities.read().await.get(&cache_key) {
        if entry.exp > unix_now() {
            return Ok(entry.username.clone());
        }
    }
    let response = state
        .http
        .get(&state.userinfo_endpoint)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| {
            api_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "IDENTITY_UNAVAILABLE",
                "Kanidm identity lookup failed.",
            )
        })?;
    let status = response.status();
    if status.is_client_error() {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token was rejected by Kanidm.",
        ));
    }
    if !status.is_success() {
        return Err(api_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "IDENTITY_UNAVAILABLE",
            "Kanidm identity lookup failed.",
        ));
    }
    let payload: UserInfoClaims = response.json().await.map_err(|_| {
        api_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "IDENTITY_UNAVAILABLE",
            "Kanidm identity lookup failed.",
        )
    })?;
    let username = payload
        .preferred_username
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            api_error(
                StatusCode::UNAUTHORIZED,
                "INVALID_TOKEN",
                "Kanidm did not release an identity for this access token.",
            )
        })?;
    let mut identities = state.identities.write().await;
    identities.retain(|_, entry| entry.exp > unix_now());
    identities.insert(
        cache_key,
        CachedIdentity {
            username: username.clone(),
            exp: token_exp,
        },
    );
    Ok(username)
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn valid_username(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.as_bytes()[0].is_ascii_lowercase()
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn api_error(status: StatusCode, code: &'static str, message: &str) -> Response {
    (
        status,
        Json(ApiError {
            error: ErrorDetail {
                code,
                message: message.to_owned(),
            },
        }),
    )
        .into_response()
}

async fn health() -> &'static str {
    "ok"
}

async fn config(State(state): State<Arc<AppState>>) -> Json<ApiConfig> {
    Json(ApiConfig {
        issuer: state.settings.issuer.clone(),
        client_id: state.settings.client_id.clone(),
        redirect_uri: state.settings.redirect_uri.clone(),
    })
}

async fn me(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    match authenticate(&state, &headers).await {
        Ok(username) => Json(Identity { username }).into_response(),
        Err(response) => response,
    }
}

async fn presets(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let home = state.settings.users_root.join(username);
    let roots: Vec<_> = state
        .settings
        .roots
        .iter()
        .filter(|root| home.join(&root.folder).join(&root.server_path).is_dir())
        .collect();
    Json(json!({ "data": roots })).into_response()
}

fn root_path(state: &AppState, username: &str, root_id: Option<&str>) -> Option<PathBuf> {
    let id = root_id.unwrap_or("files");
    state
        .settings
        .roots
        .iter()
        .find(|root| root.id == id)
        .map(|root| state.settings.users_root.join(username).join(&root.folder))
}

/// The library folders a personal folder actually exposes to File Sync.
///
/// The personal folder also holds the `_Shared` and `_Backups` bindfs mounts.
/// Those are infrastructure, not personal media, and the per-root ACL grant
/// deliberately does not include them, so the home listing is synthesised from
/// the configured roots instead of read off disk. That keeps the mount points
/// unreachable without widening the `filesync-api` grant to `r-x` on every
/// personal folder.
fn home_folders(state: &AppState, username: &str) -> Vec<String> {
    let mut folders: Vec<String> = state
        .settings
        .roots
        .iter()
        .filter(|root| {
            let folder = root.folder.as_str();
            !folder.is_empty()
                && state
                    .settings
                    .users_root
                    .join(username)
                    .join(folder)
                    .is_dir()
        })
        .map(|root| root.folder.clone())
        .collect();
    folders.sort_by_key(|folder| folder.to_lowercase());
    folders.dedup_by(|left, right| left.eq_ignore_ascii_case(right));
    folders
}

fn home_entry(name: &str) -> Entry {
    Entry {
        name: name.to_owned(),
        path: name.to_owned(),
        kind: "directory",
        size: 0,
        modified_unix_ms: 0,
        sha256: String::new(),
    }
}

/// A path under the home root may only descend into a configured library
/// folder. Without this the reserved root would be a way to reach `_Shared`
/// and `_Backups` by name.
fn split_home_path(
    roots: &[SyncRoot],
    relative: &Path,
) -> Result<(PathBuf, PathBuf), &'static str> {
    let mut components = relative.components();
    // `safe_relative_path` already rejected every other component kind, so the
    // only way to get here without a first component is the empty path.
    let Some(Component::Normal(first)) = components.next() else {
        return Err("Choose a library folder inside your personal folder.");
    };
    if !roots.iter().any(|root| Path::new(&root.folder) == first) {
        return Err("Only your own library folders can be browsed.");
    }
    Ok((PathBuf::from(first), components.collect()))
}

/// Resolve a request into the base directory to open and the path inside it.
///
/// The home root is anchored at the personal folder but may only descend into a
/// configured library folder, so `home` + `_Videos/Albums` reads
/// `_Videos/Albums` while `home` + `_Shared` is refused. The personal folder
/// itself is never a valid target: the ACL grant gives `filesync-api` traverse
/// on it, not read.
fn resolve_request_path(
    state: &AppState,
    username: &str,
    root_id: Option<&str>,
    relative: &Path,
) -> Result<(PathBuf, PathBuf), &'static str> {
    if root_id == Some(HOME_ROOT_ID) {
        let (folder, rest) = split_home_path(&state.settings.roots, relative)?;
        return Ok((state.settings.users_root.join(username).join(folder), rest));
    }
    let base = root_path(state, username, root_id).ok_or("This server folder is unavailable.")?;
    Ok((base, relative.to_path_buf()))
}

/// The directory a manifest's relative entry paths resolve against.
fn manifest_root(base: PathBuf, relative: &Path) -> PathBuf {
    if relative.as_os_str().is_empty() {
        base
    } else {
        base.join(relative)
    }
}

/// Return the manifest for one already-scoped folder, plus the directory that
/// on-demand hashing must read from.
///
/// The walk runs in a blocking task and reuses a cached manifest when one is
/// still fresh. The cache is not written here: the caller owns the manifest
/// because diffing it records the hashes it had to read.
async fn manifest_for(
    state: &AppState,
    key: &ManifestKey,
    base: PathBuf,
) -> Result<(manifest::Manifest, PathBuf), Response> {
    // The cached manifest is used as a hash source regardless of age: a hash is
    // only carried over when size and mtime still agree, so a stale entry is
    // still valid. Freshness only governs eviction in `store_manifest`.
    let cached = {
        let manifests = state.manifests.read().await;
        manifests.get(key).cloned()
    };
    let root = base.clone();
    let walk = tokio::task::spawn_blocking(move || {
        let mut fresh =
            manifest::scan(&root).map_err(|_| "The server folder could not be read.".to_owned())?;
        manifest::reuse_hashes(
            &mut fresh,
            cached.as_ref().map(|entry| entry.manifest.as_ref()),
        );
        Ok::<_, String>(fresh)
    });
    match walk.await {
        Ok(Ok(fresh)) => Ok((fresh, base)),
        Ok(Err(message)) => Err(api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            &message,
        )),
        Err(_) => Err(api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The server folder could not be read.",
        )),
    }
}

/// Keep the cache bounded so many users or deep paths cannot grow it without
/// limit. Stale entries go first; if that is not enough, the oldest goes too.
async fn store_manifest(state: &AppState, key: ManifestKey, manifest: manifest::Manifest) {
    const MAX_CACHED: usize = 256;
    let mut manifests = state.manifests.write().await;
    manifests.retain(|_, entry| entry.is_fresh());
    while manifests.len() >= MAX_CACHED {
        let oldest = manifests
            .iter()
            .min_by_key(|(_, entry)| entry.scanned_at)
            .map(|(key, _)| key.clone());
        match oldest {
            Some(key) => {
                manifests.remove(&key);
            }
            None => break,
        }
    }
    manifests.insert(
        key,
        CachedManifest {
            manifest: Arc::new(manifest),
            scanned_at: SystemTime::now(),
        },
    );
}

#[derive(Debug, Deserialize)]
struct SizesQuery {
    /// Limit the answer to one root. The app asks for a single folder when the
    /// user taps "calculate size" on one premade row, so the cost matches the
    /// question instead of walking every library.
    root: Option<String>,
}

/// Report the size of every syncable library root, keyed by root id.
///
/// Keyed by root id rather than by folder because roots share folders: the
/// Jellyfin and Offline Media presets both live in `_Videos`, but one syncs
/// all of it and the other only `_Videos/_YouTube`. A per-folder total would
/// show the wrong number for one of them.
async fn library_sizes(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<SizesQuery>,
) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let started = Instant::now();

    let mut sizes: HashMap<String, manifest::LibrarySize> = HashMap::new();
    for root in &state.settings.roots {
        if query
            .root
            .as_deref()
            .is_some_and(|wanted| wanted != root.id)
        {
            continue;
        }
        let base = state.settings.users_root.join(&username).join(&root.folder);
        if !base.join(&root.server_path).is_dir() {
            continue;
        }
        let target = manifest_root(base, Path::new(&root.server_path));
        let key: ManifestKey = (username.clone(), root.id.clone(), root.server_path.clone());
        let (manifest, _) = match manifest_for(&state, &key, target).await {
            Ok(value) => value,
            Err(response) => return response,
        };
        sizes.insert(
            root.id.clone(),
            manifest::LibrarySize {
                bytes: manifest.total_bytes,
                files: manifest.files,
                directories: manifest.directories,
                truncated: manifest.truncated,
            },
        );
        store_manifest(&state, key, manifest).await;
    }

    Json(json!({
        "data": sizes,
        "elapsedMs": started.elapsed().as_millis() as u64,
    }))
    .into_response()
}

#[derive(Debug, Deserialize)]
struct EstimateRequest {
    root: Option<String>,
    path: Option<String>,
    direction: String,
    #[serde(default)]
    local: Vec<LocalFile>,
}

/// Decide what a sync of one folder would move, without sending the library's
/// file list to the device.
///
/// The client sends what it holds as `(path, size, mtime)` and the server does
/// the diff against its own cached manifest. Files whose metadata agrees count
/// as identical without any hashing; the few that disagree come back as
/// `needsHash`, and only then does the client hash them and ask again.
async fn estimate(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<EstimateRequest>,
) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    if request.direction != "phone-to-server" && request.direction != "server-to-phone" {
        return api_error(
            StatusCode::BAD_REQUEST,
            "INVALID_DIRECTION",
            "Choose a supported sync direction.",
        );
    }
    let relative = match safe_relative_path(request.path.as_deref().unwrap_or("")) {
        Ok(value) => value,
        Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
    };
    for file in &request.local {
        if safe_relative_path(&file.path).is_err() {
            return api_error(
                StatusCode::BAD_REQUEST,
                "INVALID_PATH",
                "A folder list contained an invalid path.",
            );
        }
    }
    let (base, scoped) =
        match resolve_request_path(&state, &username, request.root.as_deref(), &relative) {
            Ok(value) => value,
            Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
        };
    let root_dir = manifest_root(base, &scoped);

    let started = Instant::now();
    let root_id = request.root.clone().unwrap_or_else(|| "files".to_owned());
    let key: ManifestKey = (username, root_id, scoped.to_string_lossy().into_owned());
    let (mut manifest, _) = match manifest_for(&state, &key, root_dir.clone()).await {
        Ok(value) => value,
        Err(response) => return response,
    };

    let remote_total_bytes = manifest.total_bytes;
    let files = manifest.files;
    let directories = manifest.directories;
    let truncated = manifest.truncated;
    let diff = match manifest::diff(&mut manifest, &root_dir, &request.local, &request.direction) {
        Ok(diff) => diff,
        Err(_) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "IO_ERROR",
                "A server file could not be read for comparison.",
            )
        }
    };
    // The diff may have read files to settle a comparison, so the hashes it
    // produced are worth keeping for the next estimate.
    store_manifest(&state, key, manifest).await;

    Json(json!({
        "data": {
            "pendingBytes": diff.pending_bytes,
            "pendingCount": diff.pending_count,
            "skipped": diff.skipped,
            "needsHash": diff.needs_hash,
            "unreadable": diff.unreadable,
            "remoteTotalBytes": remote_total_bytes,
            "files": files,
            "directories": directories,
            "truncated": truncated,
        },
        "elapsedMs": started.elapsed().as_millis() as u64,
    }))
    .into_response()
}

async fn tree(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let relative = match safe_relative_path(query.path.as_deref().unwrap_or("")) {
        Ok(value) => value,
        Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
    };
    if query.root.as_deref() == Some(HOME_ROOT_ID) && relative.as_os_str().is_empty() {
        let data: Vec<Entry> = home_folders(&state, &username)
            .iter()
            .map(|folder| home_entry(folder))
            .collect();
        return Json(json!({ "data": data })).into_response();
    }
    let (base, relative) =
        match resolve_request_path(&state, &username, query.root.as_deref(), &relative) {
            Ok(value) => value,
            Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
        };
    let include_hashes = query.hashes.unwrap_or(false);
    let result =
        tokio::task::spawn_blocking(move || list_directory(base, relative, include_hashes)).await;
    match result {
        Ok(Ok(entries)) => Json(json!({ "data": entries })).into_response(),
        Ok(Err(error)) if error.kind() == io::ErrorKind::NotFound => api_error(
            StatusCode::NOT_FOUND,
            "NOT_FOUND",
            "The requested server folder does not exist.",
        ),
        Ok(Err(_)) => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The server folder could not be read.",
        ),
        Err(_) => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The server folder could not be read.",
        ),
    }
}

fn list_directory(
    base: PathBuf,
    relative: PathBuf,
    include_hashes: bool,
) -> io::Result<Vec<Entry>> {
    let root = Dir::open_ambient_dir(base, ambient_authority())?;
    let dir = if relative.as_os_str().is_empty() {
        root
    } else {
        root.open_dir(relative)?
    };
    let mut entries = Vec::new();
    for item in dir.read_dir(".")? {
        let item = item?;
        let file_type = item.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        let metadata = item.metadata()?;
        let modified_unix_ms = metadata
            .modified()
            .ok()
            .and_then(|value| value.into_std().duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_millis())
            .unwrap_or_default();
        let sha256 = if include_hashes && file_type.is_file() {
            let mut file = dir.open(item.file_name())?;
            let mut hasher = Sha256::new();
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                let count = file.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                hasher.update(&buffer[..count]);
            }
            format!("{:x}", hasher.finalize())
        } else {
            String::new()
        };
        entries.push(Entry {
            name: item.file_name().to_string_lossy().into_owned(),
            path: item.file_name().to_string_lossy().into_owned(),
            kind: if file_type.is_dir() {
                "directory"
            } else if file_type.is_file() {
                "file"
            } else {
                "other"
            },
            size: metadata.len(),
            modified_unix_ms,
            sha256,
        });
    }
    entries.sort_by_key(|entry| entry.name.to_lowercase());
    Ok(entries)
}

async fn download(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let relative = match safe_file_path(query.path.as_deref()) {
        Ok(value) => value,
        Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
    };
    let (base, relative) =
        match resolve_request_path(&state, &username, query.root.as_deref(), &relative) {
            Ok(value) => value,
            Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
        };
    let file = tokio::task::spawn_blocking(move || -> io::Result<std::fs::File> {
        let root = Dir::open_ambient_dir(base, ambient_authority())?;
        root.open(relative).map(cap_std::fs::File::into_std)
    })
    .await;
    match file {
        Ok(Ok(file)) => {
            let length = file.metadata().map(|metadata| metadata.len()).ok();
            let file = tokio::fs::File::from_std(file);
            let mut builder = Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "application/octet-stream");
            if let Some(length) = length {
                builder = builder.header(header::CONTENT_LENGTH, length.to_string());
            }
            builder
                .body(Body::from_stream(ReaderStream::with_capacity(
                    file,
                    64 * 1024,
                )))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }
        Ok(Err(error)) if error.kind() == io::ErrorKind::NotFound => api_error(
            StatusCode::NOT_FOUND,
            "NOT_FOUND",
            "The requested server file does not exist.",
        ),
        _ => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The server file could not be opened.",
        ),
    }
}

async fn upload(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
    body: Body,
) -> Response {
    let username = match authenticate(&state, &headers).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let expected_hash = match headers
        .get("x-filesync-sha256")
        .and_then(|value| value.to_str().ok())
    {
        Some(value) if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) => {
            value.to_ascii_lowercase()
        }
        _ => {
            return api_error(
                StatusCode::BAD_REQUEST,
                "INVALID_CHECKSUM",
                "A SHA-256 checksum is required for upload.",
            )
        }
    };
    let relative = match safe_file_path(query.path.as_deref()) {
        Ok(value) => value,
        Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
    };
    let (base, relative) =
        match resolve_request_path(&state, &username, query.root.as_deref(), &relative) {
            Ok(value) => value,
            Err(message) => return api_error(StatusCode::BAD_REQUEST, "INVALID_PATH", message),
        };
    let parent = relative
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .to_path_buf();
    let file_name = match relative.file_name().and_then(|value| value.to_str()) {
        Some(value) => value.to_owned(),
        None => {
            return api_error(
                StatusCode::BAD_REQUEST,
                "INVALID_PATH",
                "A file name is required.",
            )
        }
    };
    let temporary_name = format!(".filesync-{}.upload", Uuid::new_v4());
    let target_dir = tokio::task::spawn_blocking(move || -> io::Result<Dir> {
        let root = Dir::open_ambient_dir(base, ambient_authority())?;
        if !parent.as_os_str().is_empty() {
            root.create_dir_all(&parent)?;
        }
        if parent.as_os_str().is_empty() {
            Ok(root)
        } else {
            root.open_dir(parent)
        }
    })
    .await;
    let dir = match target_dir {
        Ok(Ok(value)) => value,
        _ => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "IO_ERROR",
                "The server destination folder could not be opened.",
            )
        }
    };
    let mut options = cap_std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    let mut output = match dir.open_with(&temporary_name, &options) {
        Ok(file) => tokio::fs::File::from_std(file.into_std()),
        Err(_) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "IO_ERROR",
                "A temporary server file could not be created.",
            )
        }
    };
    let mut stream = body.into_data_stream();
    let mut bytes_written: u64 = 0;
    let mut hasher = Sha256::new();
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => {
                bytes_written = bytes_written.saturating_add(bytes.len() as u64);
                if bytes_written > 20 * 1024 * 1024 * 1024 {
                    drop(output);
                    let _ = dir.remove_file(&temporary_name);
                    return api_error(
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "FILE_TOO_LARGE",
                        "The file exceeds the 20 GiB upload limit.",
                    );
                }
                if output.write_all(&bytes).await.is_err() {
                    drop(output);
                    let _ = dir.remove_file(&temporary_name);
                    return api_error(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "IO_ERROR",
                        "The server file could not be written.",
                    );
                }
                hasher.update(&bytes);
            }
            Err(_) => {
                drop(output);
                let _ = dir.remove_file(&temporary_name);
                return api_error(
                    StatusCode::BAD_REQUEST,
                    "UPLOAD_INTERRUPTED",
                    "The upload was interrupted; retry the file.",
                );
            }
        }
    }
    if format!("{:x}", hasher.finalize()) != expected_hash {
        drop(output);
        let _ = dir.remove_file(&temporary_name);
        return api_error(
            StatusCode::BAD_REQUEST,
            "CHECKSUM_MISMATCH",
            "The upload contents changed during transfer; retry the file.",
        );
    }
    if output.flush().await.is_err() || output.sync_all().await.is_err() {
        drop(output);
        let _ = dir.remove_file(&temporary_name);
        return api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The server file could not be finalized.",
        );
    }
    drop(output);
    if dir.rename(&temporary_name, &dir, &file_name).is_err() {
        let _ = dir.remove_file(&temporary_name);
        return api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "IO_ERROR",
            "The uploaded file could not be installed.",
        );
    }
    // The file contents are synced; fsync the directory so the rename that
    // installs them is durable too and a crash cannot leave them unreferenced.
    if let Ok(dir_handle) = dir.open_dir(".") {
        let _ = dir_handle.into_std_file().sync_all();
    }
    (StatusCode::CREATED, Json(json!({ "size": bytes_written }))).into_response()
}

fn safe_relative_path(value: &str) -> Result<PathBuf, &'static str> {
    if value.starts_with('/') || value.contains('\\') || value.contains('\0') {
        return Err("Use a relative path without slash prefixes or backslashes.");
    }
    let path = Path::new(value);
    for component in path.components() {
        if !matches!(component, Component::Normal(_)) {
            return Err("The path contains an invalid or traversal component.");
        }
    }
    Ok(path.to_path_buf())
}

fn safe_file_path(value: Option<&str>) -> Result<PathBuf, &'static str> {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return Err("A relative file path is required.");
    };
    safe_relative_path(value)
}

#[cfg(test)]
mod tests {
    use super::{
        safe_file_path, safe_relative_path, split_home_path, valid_username, AccessTokenClaims,
        SyncRoot, UserInfoClaims,
    };
    use std::path::Path;

    fn roots() -> Vec<SyncRoot> {
        [
            ("files", "_Files"),
            ("videos", "_Videos"),
            ("audiobooks", "_Audiobooks"),
            ("books", "_Books"),
        ]
        .into_iter()
        .map(|(id, folder)| SyncRoot {
            id: id.to_owned(),
            folder: folder.to_owned(),
            service: "test".to_owned(),
            service_title: "Test".to_owned(),
            title: "Test".to_owned(),
            description: "Test".to_owned(),
            server_path: String::new(),
            local_subpath: String::new(),
            direction: "server-to-phone".to_owned(),
        })
        .collect()
    }

    #[test]
    fn home_paths_descend_into_a_configured_library_folder() {
        let roots = roots();
        assert_eq!(
            split_home_path(&roots, Path::new("_Videos/Albums/2024")).unwrap(),
            (
                Path::new("_Videos").to_path_buf(),
                Path::new("Albums/2024").to_path_buf()
            )
        );
        assert_eq!(
            split_home_path(&roots, Path::new("_Files")).unwrap(),
            (
                Path::new("_Files").to_path_buf(),
                Path::new("").to_path_buf()
            )
        );
    }

    #[test]
    fn home_paths_refuse_the_shared_and_backup_mounts() {
        let roots = roots();
        // The personal folder holds `_Shared` and `_Backups` bindfs mounts that
        // the filesync-api ACL grant deliberately excludes. Reaching them by
        // name through the home root would defeat that scoping.
        assert!(split_home_path(&roots, Path::new("_Shared")).is_err());
        assert!(split_home_path(&roots, Path::new("_Backups/Kopia")).is_err());
        assert!(split_home_path(&roots, Path::new("secrets")).is_err());
    }

    #[test]
    fn the_personal_folder_itself_is_not_a_target() {
        // Traversal is already rejected upstream, and an empty home path means
        // "list the libraries", not "sync the personal folder".
        assert!(split_home_path(&roots(), Path::new("")).is_err());
    }

    #[test]
    fn usernames_are_safe_to_map_to_user_directories() {
        assert!(valid_username("alice"));
        assert!(valid_username("alice.smith-2"));
        assert!(!valid_username("Alice"));
        assert!(!valid_username("../alice"));
        assert!(!valid_username("2alice"));
    }

    #[test]
    fn kanidm_access_tokens_are_accepted_without_a_username_claim() {
        let payload = r#"{
            "iss": "https://id.example.test/oauth2/openid/filesync-native",
            "sub": "2c9f8a3e-4f6b-4f2a-9f3e-1b2c3d4e5f60",
            "aud": "filesync-native",
            "exp": 1790600000,
            "nbf": 1790550000,
            "iat": 1790550000,
            "jti": "3b8f8a3e-4f6b-4f2a-9f3e-1b2c3d4e5f61",
            "client_id": "filesync-native",
            "scope": "openid profile email offline_access",
            "session_id": "4c8f8a3e-4f6b-4f2a-9f3e-1b2c3d4e5f62"
        }"#;
        let claims: AccessTokenClaims =
            serde_json::from_str(payload).expect("RFC 9068 access token must deserialize");
        assert_eq!(
            claims.iss,
            "https://id.example.test/oauth2/openid/filesync-native"
        );
        assert!(claims.aud.contains("filesync-native"));
        assert_eq!(claims.exp, 1790600000);
    }

    #[test]
    fn kanidm_userinfo_releases_the_preferred_username() {
        let payload = r#"{
            "iss": "https://id.example.test/oauth2/openid/filesync-native",
            "sub": "2c9f8a3e-4f6b-4f2a-9f3e-1b2c3d4e5f60",
            "aud": "filesync-native",
            "exp": 1790600000,
            "iat": 1790550000,
            "auth_time": 1790549000,
            "preferred_username": "canary-user",
            "name": "Canary User",
            "scopes": ["openid", "profile", "email", "offline_access"]
        }"#;
        let claims: UserInfoClaims =
            serde_json::from_str(payload).expect("userinfo payload must deserialize");
        assert_eq!(claims.preferred_username.as_deref(), Some("canary-user"));
    }

    #[test]
    fn relative_paths_reject_absolute_and_traversal_components() {
        assert_eq!(
            safe_relative_path("music/album/song.flac").unwrap(),
            Path::new("music/album/song.flac")
        );
        assert!(safe_relative_path("../private.txt").is_err());
        assert!(safe_relative_path("/etc/passwd").is_err());
        assert!(safe_relative_path("music\\song.flac").is_err());
    }

    #[test]
    fn file_paths_require_a_nonempty_relative_filename() {
        assert!(safe_file_path(None).is_err());
        assert!(safe_file_path(Some("")).is_err());
        assert_eq!(
            safe_file_path(Some("album/song.flac")).unwrap(),
            Path::new("album/song.flac")
        );
    }
}
