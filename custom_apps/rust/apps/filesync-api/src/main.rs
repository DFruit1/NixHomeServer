use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use cap_std::{ambient_authority, fs::Dir};
use futures_util::StreamExt;
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    env,
    io::{self, Read},
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::UNIX_EPOCH,
};
use tokio::{io::AsyncWriteExt, sync::RwLock};
use tokio_util::io::ReaderStream;
use uuid::Uuid;

const SERVICE: &str = "filesync-api";

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
    jwks: RwLock<JwkSet>,
}

#[derive(Debug, Deserialize)]
struct OidcMetadata {
    issuer: String,
    jwks_uri: String,
}

#[derive(Debug, Deserialize)]
struct Claims {
    iss: String,
    aud: Audience,
    exp: u64,
    preferred_username: String,
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
    let state = Arc::new(AppState {
        settings,
        http,
        jwks_uri: metadata.jwks_uri,
        jwks: RwLock::new(jwks),
    });

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/api/v1/config", get(config))
        .route("/api/v1/me", get(me))
        .route("/api/v1/presets", get(presets))
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
    let _ = tokio::signal::ctrl_c().await;
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

    let mut jwk = { state.jwks.read().await.find(kid).cloned() };
    if jwk.is_none() {
        match fetch_jwks(&state.http, &state.jwks_uri).await {
            Ok(fresh) => {
                *state.jwks.write().await = fresh;
            }
            Err(_) => {
                return Err(api_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "IDENTITY_UNAVAILABLE",
                    "Kanidm signing keys could not be refreshed.",
                ))
            }
        }
        jwk = state.jwks.read().await.find(kid).cloned();
    }
    let Some(jwk) = jwk else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "INVALID_TOKEN",
            "The access token signing key is unknown.",
        ));
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
    let data = decode::<Claims>(token, &key, &validation).map_err(|_| {
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
    if !valid_username(&claims.preferred_username) {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "INVALID_IDENTITY",
            "The Kanidm identity cannot be mapped to a server user.",
        ));
    }
    Ok(claims.preferred_username)
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
    let Some(base) = root_path(&state, &username, query.root.as_deref()) else {
        return api_error(
            StatusCode::BAD_REQUEST,
            "INVALID_ROOT",
            "This server folder is unavailable.",
        );
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
    let Some(base) = root_path(&state, &username, query.root.as_deref()) else {
        return api_error(
            StatusCode::BAD_REQUEST,
            "INVALID_ROOT",
            "This server folder is unavailable.",
        );
    };
    let file = tokio::task::spawn_blocking(move || -> io::Result<std::fs::File> {
        let root = Dir::open_ambient_dir(base, ambient_authority())?;
        root.open(relative).map(cap_std::fs::File::into_std)
    })
    .await;
    match file {
        Ok(Ok(file)) => {
            let file = tokio::fs::File::from_std(file);
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "application/octet-stream")
                .body(Body::from_stream(ReaderStream::new(file)))
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
    let Some(base) = root_path(&state, &username, query.root.as_deref()) else {
        return api_error(
            StatusCode::BAD_REQUEST,
            "INVALID_ROOT",
            "This server folder is unavailable.",
        );
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
    use super::{safe_file_path, safe_relative_path, valid_username};
    use std::path::Path;

    #[test]
    fn usernames_are_safe_to_map_to_user_directories() {
        assert!(valid_username("alice"));
        assert!(valid_username("alice.smith-2"));
        assert!(!valid_username("Alice"));
        assert!(!valid_username("../alice"));
        assert!(!valid_username("2alice"));
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
