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
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::path::{Component, Path as FilePath, PathBuf};
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
    let (mut file, size) = open_archive(&state.config.archive_root, &archive_file).await?;
    let range_header = header(&headers, "range");
    let range = compute_range(range_header, size);
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
    if query.as_deref().is_some_and(|query| {
        url::form_urlencoded::parse(query.as_bytes())
            .any(|(key, value)| key == "download" && value == "1")
    }) {
        let safe_name = archive_file.replace(['"', '\r', '\n'], "");
        builder = builder.header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{safe_name}\""),
        );
    }
    builder
        .body(Body::from_stream(stream))
        .map_err(ApiError::internal)
}

pub fn compute_range(header: Option<&str>, size: u64) -> Option<(u64, u64)> {
    let value = header?.trim().strip_prefix("bytes=")?;
    if value.contains(',') {
        return None;
    }
    let (raw_start, raw_end) = value.split_once('-')?;
    if raw_start.is_empty() && raw_end.is_empty() || size == 0 {
        return None;
    }
    if raw_start.is_empty() {
        let suffix = raw_end.parse::<u64>().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((size.saturating_sub(suffix), size - 1));
    }
    let start = raw_start.parse::<u64>().ok()?;
    if start >= size {
        return None;
    }
    let end = if raw_end.is_empty() {
        size - 1
    } else {
        raw_end.parse::<u64>().ok()?.min(size - 1)
    };
    (end >= start).then_some((start, end))
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
    let candidate = root.join(&relative);
    let canonical_root = match tokio::fs::canonicalize(root).await {
        Ok(path) => path,
        Err(_) => return Ok(None),
    };
    let canonical_candidate = match tokio::fs::canonicalize(&candidate).await {
        Ok(path) => path,
        Err(_) => return Ok(None),
    };
    if !canonical_candidate.starts_with(&canonical_root) {
        return Err(ApiError::not_found("static path not found"));
    }
    let metadata = tokio::fs::metadata(&canonical_candidate)
        .await
        .map_err(ApiError::internal)?;
    if !metadata.is_file() {
        return Ok(None);
    }
    let bytes = tokio::fs::read(&canonical_candidate)
        .await
        .map_err(ApiError::internal)?;
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type(&candidate));
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

fn decode_relative_path(value: &str) -> Option<PathBuf> {
    let mut path = PathBuf::new();
    for segment in value.split('/') {
        if segment.is_empty() {
            continue;
        }
        let decoded = percent_decode(segment)?;
        if matches!(decoded.as_str(), "." | "..") || decoded.contains(['/', '\\', '\0']) {
            return None;
        }
        path.push(decoded);
    }
    Some(path)
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = *bytes.get(index + 1)?;
            let low = *bytes.get(index + 2)?;
            decoded.push((hex(high)? << 4) | hex(low)?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

fn hex(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn content_type(path: &FilePath) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("css") => "text/css; charset=utf-8",
        Some("gif") => "image/gif",
        Some("gz") => "application/gzip",
        Some("html") => "text/html; charset=utf-8",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("png") => "image/png",
        Some("svg") => "image/svg+xml",
        Some("wasm") => "application/wasm",
        Some("webp") => "image/webp",
        _ => "application/octet-stream",
    }
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
    if let Some(fetch_site) = header(headers, "sec-fetch-site") {
        if fetch_site != "same-origin" {
            return Err(ApiError::forbidden("request is not same-origin"));
        }
    }
    let origin = header(headers, "origin")
        .ok_or_else(|| ApiError::forbidden("origin and host headers are required"))?;
    let host = header(headers, "host")
        .ok_or_else(|| ApiError::forbidden("origin and host headers are required"))?;
    let parsed = url::Url::parse(origin).map_err(|_| ApiError::forbidden("invalid origin"))?;
    let serialized = parsed.origin().ascii_serialization();
    let authority = &parsed[url::Position::BeforeHost..url::Position::AfterPort];
    if !matches!(parsed.scheme(), "http" | "https")
        || serialized != origin
        || !authority.eq_ignore_ascii_case(host)
    {
        return Err(ApiError::forbidden("origin mismatch"));
    }
    Ok(())
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
