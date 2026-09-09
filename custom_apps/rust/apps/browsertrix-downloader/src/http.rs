use crate::{
    auth::current_user,
    config::AppConfig,
    database::Database,
    model::CurrentUser,
    queue::{JobQueue, QueueError},
    validation::CreateJobInput,
};
use axum::{
    body::{Body, Bytes},
    extract::{Path, RawQuery, State},
    http::{header, HeaderMap, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use homelab_common::{content_type_for_path, decode_relative_path, parse_range, read_static_file};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::path::{Component, Path as FilePath};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

const MAX_JSON_BODY_BYTES: usize = 16 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub database: Database,
    pub queue: JobQueue,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/api/me", get(me))
        .route(
            "/api/jobs",
            get(list_jobs).post(create_job).delete(clear_history),
        )
        .route("/api/jobs/{job_id}", get(get_job).delete(delete_job))
        .route("/api/jobs/{job_id}/cancel", post(cancel_job))
        .route("/api/jobs/{job_id}/retry", post(retry_job))
        .route("/api/jobs/{job_id}/wacz", get(serve_archive))
        .route("/api/zims", get(list_zims))
        .route("/api/zims/{name}", get(serve_zim))
        .fallback(serve_static)
        .layer(axum::extract::DefaultBodyLimit::max(MAX_JSON_BODY_BYTES))
        .with_state(state)
}

async fn serve_archive(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
    RawQuery(query): RawQuery,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let user = authenticated_user(&headers)?;
    let job = state
        .database
        .job_for_user(&job_id, &user.username)?
        .filter(|job| job.status == crate::model::JobStatus::Completed)
        .filter(|job| job.archive_file.is_some())
        .ok_or_else(|| ApiError::not_found("archive not found"))?;
    let archive_file = job.archive_file.expect("filtered archive file");
    file_response(
        &state.config.archive_root,
        &archive_file,
        query.as_deref(),
        &headers,
    )
    .await
}

async fn serve_zim(
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(query): RawQuery,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    authenticated_user(&headers)?;
    let zim_root = state
        .config
        .zim_root
        .as_deref()
        .ok_or_else(|| ApiError::not_found("zim library is not configured"))?;
    file_response(zim_root, &name, query.as_deref(), &headers).await
}

async fn list_zims(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    authenticated_user(&headers)?;
    let reader_url = state
        .config
        .zim_reader_url
        .as_deref()
        .filter(|_| state.config.zim_root.is_some());
    let zims = match state.config.zim_root.as_deref() {
        Some(root) => scan_zims(root).await?,
        None => Vec::new(),
    };
    Ok(Json(json!({
        "readerUrl": reader_url,
        "zims": zims,
    })))
}

async fn scan_zims(root: &FilePath) -> Result<Vec<Value>, ApiError> {
    let root_metadata = tokio::fs::symlink_metadata(root)
        .await
        .map_err(|_| ApiError::not_found("zim library is not available"))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(ApiError::not_found("zim library is not available"));
    }
    let canonical_root = std::fs::canonicalize(root)
        .map_err(|_| ApiError::not_found("zim library is not available"))?;
    let mut reader = tokio::fs::read_dir(root)
        .await
        .map_err(ApiError::internal)?;
    let mut zims = Vec::new();
    while let Some(entry) = reader.next_entry().await.map_err(ApiError::internal)? {
        let path = entry.path();
        let name = match path.file_name().and_then(|name| name.to_str()) {
            Some(name) => name.to_owned(),
            None => continue,
        };
        if FilePath::new(&name)
            .extension()
            .and_then(|value| value.to_str())
            != Some("zim")
        {
            continue;
        }
        let metadata = match tokio::fs::symlink_metadata(&path).await {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            continue;
        }
        let canonical = match std::fs::canonicalize(&path) {
            Ok(canonical) => canonical,
            Err(_) => continue,
        };
        if canonical.parent() != Some(canonical_root.as_path()) {
            continue;
        }
        let modified_at = metadata
            .modified()
            .ok()
            .and_then(|stamp| stamp.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs().to_string());
        zims.push(json!({
            "name": name,
            "bytes": metadata.len(),
            "modifiedAt": modified_at,
        }));
    }
    zims.sort_by(|left, right| {
        let left = left["name"].as_str().unwrap_or_default();
        let right = right["name"].as_str().unwrap_or_default();
        left.cmp(right)
    });
    Ok(zims)
}

async fn file_response(
    root: &FilePath,
    name: &str,
    query: Option<&str>,
    headers: &HeaderMap,
) -> Result<Response, ApiError> {
    let (mut file, size) = open_archive(root, name).await?;
    let range_header = header(headers, "range");
    let range = parse_range(range_header, size);
    if range_header.is_some() && range.is_none() {
        return Response::builder()
            .status(StatusCode::RANGE_NOT_SATISFIABLE)
            .header(header::CONTENT_RANGE, format!("bytes */{size}"))
            .body(Body::empty())
            .map_err(ApiError::internal);
    }
    let (status, start, end) = match range {
        Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end),
        None => (StatusCode::OK, 0, size.saturating_sub(1)),
    };
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(ApiError::internal)?;
    let length = if size == 0 { 0 } else { end - start + 1 };
    let stream = ReaderStream::new(file.take(length));
    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "private, max-age=3600")
        .header(header::CONTENT_LENGTH, length.to_string());
    if status == StatusCode::PARTIAL_CONTENT {
        builder = builder.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }
    if query.is_some_and(|query| {
        url::form_urlencoded::parse(query.as_bytes())
            .any(|(key, value)| key == "download" && value == "1")
    }) {
        let safe_name = name.replace(['"', '\r', '\n'], "");
        builder = builder.header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{safe_name}\""),
        );
    }
    builder
        .body(Body::from_stream(stream))
        .map_err(ApiError::internal)
}

async fn open_archive(
    root: &FilePath,
    archive_file: &str,
) -> Result<(tokio::fs::File, u64), ApiError> {
    let relative = FilePath::new(archive_file);
    if relative.components().count() != 1
        || !matches!(relative.components().next(), Some(Component::Normal(_)))
    {
        return Err(ApiError::not_found("archive not found"));
    }
    let root_metadata =
        std::fs::symlink_metadata(root).map_err(|_| ApiError::not_found("archive not found"))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(ApiError::not_found("archive not found"));
    }
    let canonical_root =
        std::fs::canonicalize(root).map_err(|_| ApiError::not_found("archive not found"))?;
    let candidate = root.join(relative);
    let candidate_metadata = std::fs::symlink_metadata(&candidate)
        .map_err(|_| ApiError::not_found("archive not found"))?;
    if candidate_metadata.file_type().is_symlink() || !candidate_metadata.is_file() {
        return Err(ApiError::not_found("archive not found"));
    }
    let canonical_candidate =
        std::fs::canonicalize(&candidate).map_err(|_| ApiError::not_found("archive not found"))?;
    if canonical_candidate.parent() != Some(canonical_root.as_path()) {
        return Err(ApiError::not_found("archive not found"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(&candidate)
        .map_err(|_| ApiError::not_found("archive not found"))?;
    let metadata = file
        .metadata()
        .map_err(|_| ApiError::not_found("archive not found"))?;
    if !metadata.is_file() {
        return Err(ApiError::not_found("archive not found"));
    }
    Ok((tokio::fs::File::from_std(file), metadata.len()))
}

async fn serve_static(State(state): State<AppState>, uri: Uri) -> Result<Response, ApiError> {
    let raw_path = uri.path();
    if raw_path == "/replay" || raw_path.starts_with("/replay/") {
        let relative = if matches!(raw_path, "/replay" | "/replay/") {
            "index.html"
        } else {
            raw_path.trim_start_matches("/replay/")
        };
        if let Some(response) = static_file(&state.config.replay_dir, relative, true).await? {
            return Ok(response);
        }
        return static_file(&state.config.replay_dir, "index.html", true)
            .await?
            .ok_or_else(|| ApiError::not_found("static path not found"));
    }
    let relative = if raw_path == "/" {
        "index.html"
    } else {
        raw_path.trim_start_matches('/')
    };
    if let Some(response) = static_file(&state.config.frontend_dir, relative, false).await? {
        return Ok(response);
    }
    static_file(&state.config.frontend_dir, "index.html", false)
        .await?
        .ok_or_else(|| ApiError::not_found("static path not found"))
}

async fn static_file(
    root: &FilePath,
    encoded_relative: &str,
    replay: bool,
) -> Result<Option<Response>, ApiError> {
    let relative = decode_relative_path(encoded_relative)
        .ok_or_else(|| ApiError::not_found("static path not found"))?;
    let bytes = match read_static_file(root, &relative).await {
        Ok(bytes) => bytes,
        Err(homelab_common::StaticFileError::EscapesRoot) => {
            return Err(ApiError::not_found("static path not found"))
        }
        Err(homelab_common::StaticFileError::NotFound) => return Ok(None),
        Err(homelab_common::StaticFileError::Io(error)) => return Err(ApiError::internal(error)),
    };
    let candidate = root.join(&relative);
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type_for_path(&candidate));
    if replay && relative == FilePath::new("sw.js") {
        builder = builder
            .header("service-worker-allowed", "/replay/")
            .header(header::CACHE_CONTROL, "no-cache");
    }
    builder
        .body(Body::from(bytes))
        .map(Some)
        .map_err(ApiError::internal)
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

async fn me(headers: HeaderMap) -> Result<Json<CurrentUser>, ApiError> {
    Ok(Json(authenticated_user(&headers)?))
}

async fn list_jobs(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = authenticated_user(&headers)?;
    let jobs = state.database.list_jobs(&user.username, 100)?;
    Ok(Json(
        serde_json::to_value(jobs).map_err(ApiError::internal)?,
    ))
}

async fn get_job(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = authenticated_user(&headers)?;
    let job = state
        .database
        .job_for_user(&job_id, &user.username)?
        .ok_or_else(|| ApiError::not_found("job not found"))?;
    Ok(Json(serde_json::to_value(job).map_err(ApiError::internal)?))
}

async fn create_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = authenticated_user(&headers)?;
    let input = mutation_json::<CreateJobInput>(&headers, &body)?;
    let job_id = state.queue.enqueue(&user, input).await?;
    Ok((StatusCode::CREATED, Json(json!({ "jobId": job_id }))))
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Value>, ApiError> {
    let user = authenticated_user(&headers)?;
    let _: Value = mutation_json(&headers, &body)?;
    state.queue.cancel(&job_id, &user)?;
    Ok(Json(json!({ "ok": true })))
}

async fn retry_job(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = authenticated_user(&headers)?;
    let _: Value = mutation_json(&headers, &body)?;
    let retry_id = state.queue.retry(&job_id, &user).await?;
    Ok((StatusCode::CREATED, Json(json!({ "jobId": retry_id }))))
}

async fn delete_job(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let user = authenticated_user(&headers)?;
    let _: Value = mutation_json(&headers, &body)?;
    if state
        .database
        .job_for_user(&job_id, &user.username)?
        .is_none()
    {
        return Err(ApiError::not_found("job not found"));
    }
    if state.database.delete_job(&job_id, &user.username)? == 0 {
        return Err(ApiError::bad_request("active jobs cannot be deleted"));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn clear_history(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let user = authenticated_user(&headers)?;
    let _: Value = mutation_json(&headers, &body)?;
    state.database.clear_history(&user.username)?;
    Ok(StatusCode::NO_CONTENT)
}

fn authenticated_user(headers: &HeaderMap) -> Result<CurrentUser, ApiError> {
    current_user(headers)
        .map_err(|error| ApiError::new(StatusCode::UNAUTHORIZED, error.to_string()))
}

fn mutation_json<T: DeserializeOwned>(headers: &HeaderMap, body: &[u8]) -> Result<T, ApiError> {
    assert_same_origin(headers)?;
    let content_type = header(headers, "content-type")
        .and_then(|value| value.split(';').next())
        .map(str::trim);
    if content_type != Some("application/json") {
        return Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "JSON content type is required",
        ));
    }
    let value: Value = if body.is_empty() {
        json!({})
    } else {
        serde_json::from_slice(body)
            .map_err(|_| ApiError::bad_request("JSON request body must be an object"))?
    };
    if !value.is_object() {
        return Err(ApiError::bad_request("JSON request body must be an object"));
    }
    serde_json::from_value(value).map_err(|error| ApiError::bad_request(error.to_string()))
}

fn assert_same_origin(headers: &HeaderMap) -> Result<(), ApiError> {
    homelab_common::assert_same_origin(headers)
        .map_err(|error| ApiError::forbidden(error.to_string()))
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name)?.to_str().ok().map(str::trim)
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            format!("not authorised: {}", message.into()),
        )
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, message)
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        eprintln!(
            "{}",
            json!({
                "level": "error",
                "service": "browsertrix-downloader",
                "event": "request_failed",
                "error": error.to_string(),
            })
        );
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        Self::internal(error)
    }
}

impl From<QueueError> for ApiError {
    fn from(error: QueueError) -> Self {
        match error {
            QueueError::BadRequest(message) => Self::bad_request(message),
            QueueError::NotFound(message) => Self::not_found(message),
            QueueError::Internal(message) => Self::internal(message),
        }
    }
}
