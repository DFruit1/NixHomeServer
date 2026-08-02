use crate::{
    broker::{
        file_fingerprint, open_regular_file_beneath, BrokerAction, InstallMetadataSidecarAction,
        InstallSubtitleAction, MoveAction,
    },
    catalog::{Catalog, CatalogHandle, CatalogItem, ConfirmPlanOutcome, MutationPlanDraft},
    config::{AppConfig, Identity, MutationMode, RootScope},
    naming::{
        canonical_movie_directory, canonical_music_track, canonical_tv_episode, clean_component,
    },
    scanner::{scan_root, ScanRoot},
    subtitles::{opensubtitles_movie_hash, OpenSubtitlesClient, OpenSubtitlesCredentials},
};
use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE},
        HeaderMap, StatusCode,
    },
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::Path as FilePath,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::io::AsyncWriteExt;

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const MAX_SUBTITLE_BYTES: usize = 10 * 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub catalog: CatalogHandle,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionResponse {
    username: String,
    groups: Vec<String>,
    can_edit: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemsQuery {
    root_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    operation: Value,
    item_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScanRequest {
    root_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UploadSubtitleQuery {
    language: String,
    #[serde(default)]
    hearing_impaired: bool,
    format: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SearchSubtitlesQuery {
    languages: String,
    query: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProviderSubtitleRequest {
    file_id: i64,
    language: String,
    #[serde(default)]
    hearing_impaired: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MetadataSidecarRequest {
    title: String,
    sort_title: Option<String>,
    year: Option<u16>,
    description: Option<String>,
    publisher: Option<String>,
    series: Option<String>,
    volume_number: Option<String>,
    isbn: Option<String>,
    language: Option<String>,
    #[serde(default)]
    authors: Vec<String>,
    #[serde(default)]
    narrators: Vec<String>,
    #[serde(default)]
    genres: Vec<String>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/assets/{*asset_path}", get(frontend_asset))
        .route("/api/v1/status", get(status))
        .route("/api/v1/session", get(session))
        .route("/api/v1/roots", get(roots))
        .route("/api/v1/items", get(items))
        .route("/api/v1/conversions", get(conversions))
        .route("/api/v1/scans", post(scan))
        .route(
            "/api/v1/items/{item_id}/subtitles/upload",
            post(upload_subtitle),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/search",
            get(search_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/provider",
            post(install_provider_subtitle),
        )
        .route(
            "/api/v1/items/{item_id}/metadata/sidecar",
            post(preview_metadata_sidecar),
        )
        .route(
            "/api/v1/integrations/{integration_id}/refresh",
            get(integration_refresh_status).post(queue_integration_refresh),
        )
        .route("/api/v1/plans", post(preview_plan))
        .route("/api/v1/plans/{plan_id}/confirm", post(confirm_plan))
        .layer(axum::extract::DefaultBodyLimit::max(
            MAX_SUBTITLE_BYTES + 1024,
        ))
        .fallback(not_found)
        .with_state(Arc::new(state))
}

async fn queue_integration_refresh(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(integration_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !refresh_adapter_available(&state.config, &integration_id) {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "refresh_adapter_unavailable",
            "This application does not have an available manual refresh adapter.",
            request_id,
        )
        .into_response();
    }
    let directory = state.config.state_dir.join("refresh-requests");
    if let Err(error) = tokio::fs::create_dir_all(&directory).await {
        log_event(
            "refresh_queue_failed",
            &request_id,
            json!({ "error": error.to_string() }),
        );
        return ApiError::internal(request_id).into_response();
    }
    let marker = directory.join(format!("{integration_id}.request"));
    let mut already_queued = false;
    match tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o640)
        .open(&marker)
        .await
    {
        Ok(mut file) => {
            let payload = json!({
                "schemaVersion": 1,
                "integrationId": integration_id,
                "actor": identity.username,
                "requestId": request_id,
                "queuedAt": unix_timestamp(),
                "state": "queued",
            })
            .to_string();
            let write_result = match file.write_all(payload.as_bytes()).await {
                Ok(()) => file.sync_all().await,
                Err(error) => Err(error),
            };
            if let Err(error) = write_result {
                let _ = tokio::fs::remove_file(&marker).await;
                log_event(
                    "refresh_queue_failed",
                    &request_id,
                    json!({ "error": error.to_string() }),
                );
                return ApiError::internal(request_id).into_response();
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            already_queued = true;
        }
        Err(error) => {
            log_event(
                "refresh_queue_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    }
    if let Ok(catalog) = state.catalog.open() {
        if let Err(error) = catalog.insert_audit_event(
            &request_id,
            &identity.username,
            "integration_refresh_queued",
            Some(&integration_id),
            &json!({ "alreadyQueued": already_queued }).to_string(),
        ) {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
        }
    }
    (
        StatusCode::ACCEPTED,
        Json(json!({
            "integrationId": integration_id,
            "state": "queued",
            "alreadyQueued": already_queued,
            "requestId": request_id,
        })),
    )
        .into_response()
}

async fn integration_refresh_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(integration_id): Path<String>,
) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    if !refresh_adapter_available(&state.config, &integration_id) {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "refresh_adapter_unavailable",
            "This application does not have an available manual refresh adapter.",
            request_id,
        )
        .into_response();
    }

    let paths = [
        state
            .config
            .state_dir
            .join("refresh-requests")
            .join(format!("{integration_id}.request")),
        state
            .config
            .state_dir
            .join("refresh-results")
            .join(format!("{integration_id}.json")),
    ];
    for path in paths {
        match read_refresh_status(&path, &integration_id).await {
            Ok(Some(status)) => return Json(status).into_response(),
            Ok(None) => {}
            Err(error) => {
                log_event(
                    "refresh_status_read_failed",
                    &request_id,
                    json!({ "integrationId": integration_id, "error": error }),
                );
                return ApiError::internal(request_id).into_response();
            }
        }
    }

    Json(json!({
        "integrationId": integration_id,
        "state": "idle",
    }))
    .into_response()
}

fn refresh_adapter_available(config: &AppConfig, integration_id: &str) -> bool {
    matches!(integration_id, "jellyfin" | "audiobookshelf" | "syncthing")
        && config.integrations.iter().any(|integration| {
            integration.id == integration_id
                && integration.available
                && integration.capabilities.iter().any(|capability| {
                    matches!(capability.as_str(), "library-refresh" | "folder-rescan")
                })
        })
}

async fn read_refresh_status(
    path: &FilePath,
    integration_id: &str,
) -> Result<Option<Value>, String> {
    let metadata = match tokio::fs::symlink_metadata(path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 16 * 1024 {
        return Err("refresh status is not a safe regular file".to_string());
    }
    let contents = tokio::fs::read_to_string(path)
        .await
        .map_err(|error| error.to_string())?;
    let value: Value = serde_json::from_str(&contents).map_err(|error| error.to_string())?;
    let object = value
        .as_object()
        .ok_or_else(|| "refresh status is not a JSON object".to_string())?;
    if object.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || object.get("integrationId").and_then(Value::as_str) != Some(integration_id)
    {
        return Err("refresh status identity is invalid".to_string());
    }
    let state = object
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| matches!(*state, "queued" | "running" | "succeeded" | "failed"))
        .ok_or_else(|| "refresh status state is invalid".to_string())?;
    let mut response = serde_json::Map::from_iter([
        ("integrationId".to_string(), json!(integration_id)),
        ("state".to_string(), json!(state)),
    ]);
    for field in ["requestId", "message"] {
        if let Some(value) = object.get(field).and_then(Value::as_str) {
            response.insert(field.to_string(), json!(value));
        }
    }
    for field in ["queuedAt", "startedAt", "finishedAt"] {
        if let Some(value) = object.get(field).and_then(Value::as_i64) {
            response.insert(field.to_string(), json!(value));
        }
    }
    Ok(Some(Value::Object(response)))
}

async fn search_subtitles(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Query(query): Query<SearchSubtitlesQuery>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let languages = match normalized_subtitle_languages(&query.languages) {
        Some(languages) => languages,
        None => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_subtitle_languages",
                "Supply one to five comma-separated subtitle language codes.",
                request_id,
            )
            .into_response()
        }
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitle search requires a cataloged video file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let search_query = query
        .query
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| video_search_title(&item.relative_path));
    if search_query.is_empty() || search_query.len() > 200 || search_query.contains('\0') {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_query",
            "The subtitle search query must contain between 1 and 200 characters.",
            request_id,
        )
        .into_response();
    }
    let client = match open_subtitles_client(&state.config, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let root_path = root.resolved_path;
    let relative_path = item.relative_path.clone();
    let movie_hash = match tokio::task::spawn_blocking(move || {
        let mut file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
            .map_err(|error| error.to_string())?;
        match opensubtitles_movie_hash(&mut file) {
            Ok(hash) => Ok(Some(hash)),
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => Ok(None),
            Err(error) => Err(format!("calculate movie hash: {error}")),
        }
    })
    .await
    {
        Ok(Ok(movie_hash)) => movie_hash,
        Ok(Err(error)) => {
            log_event(
                "subtitle_hash_failed",
                &request_id,
                json!({ "error": error, "itemId": item.id }),
            );
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_file_unavailable",
                "The selected video changed or can no longer be read safely. Scan the library again.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "subtitle_hash_task_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item.id }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };

    let exact_results = match movie_hash.as_ref() {
        Some(movie_hash) => match client.search_by_hash(movie_hash, &languages).await {
            Ok(results) => results
                .into_iter()
                .filter(|result| result.hash_matched)
                .collect::<Vec<_>>(),
            Err(error) => {
                return subtitle_provider_search_error(error, &request_id).into_response()
            }
        },
        None => Vec::new(),
    };
    if !exact_results.is_empty() {
        return Json(json!({
            "provider": "opensubtitles",
            "query": search_query,
            "languages": languages,
            "matchMethod": "movie-hash",
            "results": exact_results,
            "requestId": request_id,
        }))
        .into_response();
    }

    match client.search_by_query(search_query, &languages).await {
        Ok(results) => Json(json!({
            "provider": "opensubtitles",
            "query": search_query,
            "languages": languages,
            "matchMethod": "title-fallback",
            "results": results,
            "requestId": request_id,
        }))
        .into_response(),
        Err(error) => subtitle_provider_search_error(error, &request_id).into_response(),
    }
}

fn subtitle_provider_search_error(error: impl std::fmt::Display, request_id: &str) -> ApiError {
    log_event(
        "subtitle_provider_search_failed",
        request_id,
        json!({ "error": error.to_string() }),
    );
    ApiError::new(
        StatusCode::BAD_GATEWAY,
        "subtitle_provider_failed",
        "OpenSubtitles could not complete the search.",
        request_id.to_string(),
    )
}

async fn install_provider_subtitle(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<ProviderSubtitleRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let language = match normalized_subtitle_language(&request.language) {
        Some(language) => language,
        None => return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_language",
            "Use a two or three letter subtitle language code, optionally followed by a region.",
            request_id,
        )
        .into_response(),
    };
    if request.file_id <= 0 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_provider_file_id",
            "The selected provider file ID is invalid.",
            request_id,
        )
        .into_response();
    }
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitles can only be attached to a cataloged video file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let client = match open_subtitles_client(&state.config, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let bytes = match client.download(request.file_id).await {
        Ok(bytes) => bytes,
        Err(error) => {
            log_event(
                "subtitle_provider_download_failed",
                &request_id,
                json!({ "error": error.to_string(), "fileId": request.file_id }),
            );
            return ApiError::new(
                StatusCode::BAD_GATEWAY,
                "subtitle_provider_failed",
                "OpenSubtitles could not supply the selected subtitle.",
                request_id,
            )
            .into_response();
        }
    };
    if let Err(error) = validate_subtitle_bytes("srt", &bytes) {
        log_event(
            "subtitle_provider_payload_invalid",
            &request_id,
            json!({ "fileId": request.file_id }),
        );
        return error.with_request_id(request_id).into_response();
    }
    let destination_relative_path = subtitle_sidecar_path(
        &item.relative_path,
        &language,
        request.hearing_impaired,
        "srt",
    );
    let staged = match stage_sidecar(&state.config, "srt", &bytes, &request_id).await {
        Ok(staged) => staged,
        Err(error) => return error.into_response(),
    };
    let action = InstallSubtitleAction {
        staging_filename: staged.filename,
        destination_root_id: item.root_id.clone(),
        destination_relative_path,
        expected: staged.expected,
    };
    let staging_path = staged.path;
    match create_subtitle_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        action,
        "opensubtitles",
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(&staging_path).await;
            error.into_response()
        }
    }
}

async fn upload_subtitle(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Query(query): Query<UploadSubtitleQuery>,
    body: Bytes,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !valid_object_id(&item_id) {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_item_id",
            "The selected catalog item ID is invalid.",
            request_id,
        )
        .into_response();
    }
    let language = match normalized_subtitle_language(&query.language) {
        Some(language) => language,
        None => return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_language",
            "Use a two or three letter subtitle language code, optionally followed by a region.",
            request_id,
        )
        .into_response(),
    };
    let extension = match subtitle_extension(query.format.as_deref(), &headers) {
        Some(extension) => extension,
        None => {
            return ApiError::new(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "unsupported_subtitle_format",
                "Upload an SRT, WebVTT, or ASS subtitle file.",
                request_id,
            )
            .into_response()
        }
    };
    if let Err(error) = validate_subtitle_bytes(extension, &body) {
        return error.with_request_id(request_id).into_response();
    }
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    if item.media_kind != "video" {
        return ApiError::new(
            StatusCode::CONFLICT,
            "video_item_required",
            "Subtitles can only be attached to a cataloged video file.",
            request_id,
        )
        .into_response();
    }
    let destination_relative_path = subtitle_sidecar_path(
        &item.relative_path,
        &language,
        query.hearing_impaired,
        extension,
    );
    let staged = match stage_sidecar(&state.config, extension, &body, &request_id).await {
        Ok(staged) => staged,
        Err(error) => return error.into_response(),
    };
    let action = InstallSubtitleAction {
        staging_filename: staged.filename,
        destination_root_id: item.root_id.clone(),
        destination_relative_path,
        expected: staged.expected,
    };
    let staging_path = staged.path;
    match create_subtitle_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        action,
        "upload",
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(&staging_path).await;
            error.into_response()
        }
    }
}

async fn preview_metadata_sidecar(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<MetadataSidecarRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if let Err(error) = validate_metadata_request(&request) {
        return error.with_request_id(request_id).into_response();
    }
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if ["video", "music", "audiobook", "book"].contains(&item.media_kind.as_str()) => {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "metadata_item_unsupported",
                "Metadata sidecars require a video, music, audiobook, or book item.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let (destination_relative_path, extension, contents) = metadata_sidecar(&item, &request);
    let staged =
        match stage_sidecar(&state.config, extension, contents.as_bytes(), &request_id).await {
            Ok(staged) => staged,
            Err(error) => return error.into_response(),
        };
    let staging_path = staged.path.clone();
    let action = InstallMetadataSidecarAction {
        staging_filename: staged.filename,
        destination_root_id: item.root_id.clone(),
        destination_relative_path,
        expected: staged.expected,
    };
    match create_metadata_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        &request,
        action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(staging_path).await;
            error.into_response()
        }
    }
}

async fn index(State(state): State<Arc<AppState>>) -> Response {
    if let Some(frontend_dir) = &state.config.frontend_dir {
        match tokio::fs::read_to_string(frontend_dir.join("index.html")).await {
            Ok(contents) => return Html(contents).into_response(),
            Err(error) => log_event(
                "frontend_unavailable",
                &request_id(),
                json!({ "errorKind": error.kind().to_string() }),
            ),
        }
    }
    Html(
        "<!doctype html><html><head><meta charset=utf-8><title>Media Manager</title></head>\
         <body><main><h1>Media Manager</h1><p>The frontend bundle is unavailable.</p></main></body></html>",
    )
    .into_response()
}

async fn frontend_asset(
    State(state): State<Arc<AppState>>,
    Path(asset_path): Path<String>,
) -> Response {
    if !valid_asset_path(&asset_path) {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "asset_not_found",
            "The requested frontend asset does not exist.",
            request_id(),
        )
        .into_response();
    }
    let frontend_dir = match &state.config.frontend_dir {
        Some(path) => path,
        None => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "asset_not_found",
                "The requested frontend asset does not exist.",
                request_id(),
            )
            .into_response()
        }
    };
    let path = frontend_dir.join("assets").join(&asset_path);
    let metadata = match tokio::fs::symlink_metadata(&path).await {
        Ok(metadata)
            if metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.len() <= 16 * 1024 * 1024 =>
        {
            metadata
        }
        _ => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "asset_not_found",
                "The requested frontend asset does not exist.",
                request_id(),
            )
            .into_response()
        }
    };
    let _ = metadata;
    match tokio::fs::read(&path).await {
        Ok(bytes) => (
            StatusCode::OK,
            [
                (CONTENT_TYPE, frontend_content_type(&asset_path)),
                (CACHE_CONTROL, "public, max-age=31536000, immutable"),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => ApiError::new(
            StatusCode::NOT_FOUND,
            "asset_not_found",
            "The requested frontend asset does not exist.",
            request_id(),
        )
        .into_response(),
    }
}

async fn status(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    let mut integrations = state.config.integrations.clone();
    integrations.push(crate::config::IntegrationCapability {
        id: "mkvmaker".to_string(),
        label: "DVD ISO converter".to_string(),
        available: state.config.mkvmaker_progress_file.is_file(),
        capabilities: vec!["conversion-progress".to_string()],
    });
    integrations.push(crate::config::IntegrationCapability {
        id: "opensubtitles".to_string(),
        label: "OpenSubtitles".to_string(),
        available: state
            .config
            .open_subtitles_credentials_file
            .as_ref()
            .is_some_and(|path| path.is_file()),
        capabilities: vec![
            "subtitle-search".to_string(),
            "subtitle-download".to_string(),
        ],
    });
    Json(json!({
        "schemaVersion": 1,
        "service": "media-manager",
        "mutationMode": state.config.mutation_mode,
        "integrations": integrations,
        "requestId": request_id,
    }))
    .into_response()
}

async fn session(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    match identity_from_headers(&headers, &request_id) {
        Ok(identity) => Json(SessionResponse {
            can_edit: identity.can_edit(&state.config.editor_group),
            username: identity.username,
            groups: identity.groups,
        })
        .into_response(),
        Err(error) => error.into_response(),
    }
}

async fn roots(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    match identity_from_headers(&headers, &request_id) {
        Ok(identity) => Json(state.config.visible_roots(&identity)).into_response(),
        Err(error) => error.into_response(),
    }
}

async fn items(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ItemsQuery>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let root = match state
        .config
        .resolve_visible_root(&identity, query.root_id.as_str())
    {
        Some(root) => root,
        None => {
            return ApiError::new(
                StatusCode::FORBIDDEN,
                "root_not_visible",
                "The requested root is not visible to this identity.",
                request_id,
            )
            .into_response()
        }
    };
    let owner = (root.scope == RootScope::Personal).then_some(identity.username.as_str());
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    match catalog.list_items(&root.id, owner, 200) {
        Ok(items) => Json(json!({ "items": items, "nextCursor": null })).into_response(),
        Err(error) => {
            log_event(
                "catalog_query_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id).into_response()
        }
    }
}

async fn conversions(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    match tokio::fs::read(&state.config.mkvmaker_progress_file).await {
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
            Ok(progress) => {
                Json(json!({ "available": true, "progress": progress })).into_response()
            }
            Err(error) => {
                log_event(
                    "mkvmaker_progress_invalid",
                    &request_id,
                    json!({ "error": error.to_string() }),
                );
                ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "integration_payload_invalid",
                    "MKVMaker reported invalid progress data.",
                    request_id,
                )
                .into_response()
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Json(json!({
            "available": false,
            "progress": { "schemaVersion": 1, "state": "unavailable", "conversions": [] },
        }))
        .into_response(),
        Err(error) => {
            log_event(
                "mkvmaker_progress_read_failed",
                &request_id,
                json!({ "errorKind": error.kind().to_string() }),
            );
            ApiError::internal(request_id).into_response()
        }
    }
}

async fn scan(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<ScanRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let visible_root = match state
        .config
        .resolve_visible_root(&identity, request.root_id.as_str())
    {
        Some(root) => root,
        None => {
            return ApiError::new(
                StatusCode::FORBIDDEN,
                "root_not_visible",
                "The requested root is not visible to this identity.",
                request_id,
            )
            .into_response()
        }
    };
    let scan_root_spec = ScanRoot {
        id: visible_root.id,
        owner_username: (visible_root.scope == RootScope::Personal)
            .then_some(identity.username.clone()),
        path: visible_root.resolved_path.into(),
        category: visible_root.category,
    };
    let catalog_handle = state.catalog.clone();
    let scan_result = tokio::task::spawn_blocking(move || {
        let mut catalog = catalog_handle
            .open()
            .map_err(|error| format!("open catalog: {error}"))?;
        scan_root(&mut catalog, &scan_root_spec)
    })
    .await;
    let scan_result = match scan_result {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => {
            log_event(
                "catalog_scan_failed",
                &request_id,
                json!({ "error": error }),
            );
            return ApiError::new(
                StatusCode::BAD_GATEWAY,
                "scan_failed",
                "The selected media root could not be scanned.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "catalog_scan_task_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    if let Ok(catalog) = state.catalog.open() {
        if let Err(error) = catalog.insert_audit_event(
            &request_id,
            &identity.username,
            "catalog_root_scanned",
            Some(&request.root_id),
            &serde_json::to_string(&scan_result).unwrap_or_else(|_| "{}".to_string()),
        ) {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
        }
    }
    Json(json!({ "rootId": request.root_id, "result": scan_result, "requestId": request_id }))
        .into_response()
}

async fn preview_plan(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(plan): Json<PlanRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if plan.item_ids.is_empty()
        || plan.item_ids.len() > 500
        || plan.item_ids.iter().any(|item| !valid_object_id(item))
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_plan",
            "A plan requires between 1 and 500 valid item IDs.",
            request_id,
        )
        .into_response();
    }
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let actions = match build_move_actions(&state.config, &identity, &catalog, &plan) {
        Ok(actions) => actions,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let now = unix_timestamp();
    let expires_at = now.saturating_add(30 * 60);
    let canonical = match serde_json::to_vec(&json!({
        "actor": identity.username,
        "request": plan,
        "actions": actions,
        "expiresAt": expires_at,
    })) {
        Ok(value) => value,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let digest = sha256_hex(&canonical);
    let plan_id = format!("plan-{request_id}");
    let request_json = match serde_json::to_string(&plan) {
        Ok(value) => value,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    if let Err(error) = catalog.create_mutation_plan(&MutationPlanDraft {
        id: plan_id.clone(),
        owner_username: identity.username.clone(),
        digest: digest.clone(),
        request_json,
        expires_at,
        actions: actions.iter().cloned().map(BrokerAction::from).collect(),
    }) {
        log_event(
            "mutation_plan_write_failed",
            &request_id,
            json!({ "error": error.to_string() }),
        );
        return ApiError::internal(request_id).into_response();
    }
    if let Err(error) = catalog.insert_audit_event(
        &request_id,
        &identity.username,
        "mutation_plan_previewed",
        Some(&plan_id),
        &json!({ "digest": digest }).to_string(),
    ) {
        log_event(
            "audit_write_failed",
            &request_id,
            json!({ "error": error.to_string() }),
        );
        return ApiError::internal(request_id).into_response();
    }
    (
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "actions": actions,
            "expiresAt": expires_at,
            "mutationMode": state.config.mutation_mode,
            "warnings": if state.config.mutation_mode == MutationMode::ReadOnly {
                vec!["The service is in read-only mode; this plan cannot be confirmed."]
            } else {
                Vec::<&str>::new()
            },
            "requestId": request_id,
        })),
    )
        .into_response()
}

async fn confirm_plan(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::extract::Path(plan_id): axum::extract::Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let if_match = headers
        .get("if-match")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if if_match.is_empty() {
        return ApiError::new(
            StatusCode::PRECONDITION_REQUIRED,
            "plan_digest_required",
            "If-Match must contain the previewed plan digest.",
            request_id,
        )
        .into_response();
    }
    if state.config.mutation_mode == MutationMode::ReadOnly {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "mutation_mode_read_only",
            "Mutation confirmation is disabled while the service is in read-only mode.",
            request_id,
        )
        .into_response();
    }
    let digest = if_match
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .unwrap_or(if_match);
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return ApiError::new(
            StatusCode::PRECONDITION_FAILED,
            "plan_digest_mismatch",
            "If-Match does not contain the previewed plan digest.",
            request_id,
        )
        .into_response();
    }
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    match catalog.confirm_mutation_plan(&plan_id, &identity.username, digest, unix_timestamp()) {
        Ok(ConfirmPlanOutcome::Queued) => {
            if let Err(error) = catalog.insert_audit_event(
                &request_id,
                &identity.username,
                "mutation_plan_queued",
                Some(&plan_id),
                &json!({ "digest": digest }).to_string(),
            ) {
                log_event(
                    "audit_write_failed",
                    &request_id,
                    json!({ "error": error.to_string() }),
                );
            }
            (
                StatusCode::ACCEPTED,
                Json(json!({ "id": plan_id, "state": "queued", "requestId": request_id })),
            )
                .into_response()
        }
        Ok(ConfirmPlanOutcome::NotFound) => ApiError::new(
            StatusCode::NOT_FOUND,
            "plan_not_found",
            "The mutation plan does not exist for this identity.",
            request_id,
        )
        .into_response(),
        Ok(ConfirmPlanOutcome::DigestMismatch) => ApiError::new(
            StatusCode::PRECONDITION_FAILED,
            "plan_digest_mismatch",
            "If-Match does not contain the previewed plan digest.",
            request_id,
        )
        .into_response(),
        Ok(ConfirmPlanOutcome::Expired) => ApiError::new(
            StatusCode::CONFLICT,
            "plan_expired",
            "The mutation preview expired; create a new preview.",
            request_id,
        )
        .into_response(),
        Ok(ConfirmPlanOutcome::StateConflict) => ApiError::new(
            StatusCode::CONFLICT,
            "plan_state_conflict",
            "The mutation plan is no longer awaiting confirmation.",
            request_id,
        )
        .into_response(),
        Err(error) => {
            log_event(
                "mutation_plan_confirm_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id).into_response()
        }
    }
}

async fn not_found() -> Response {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_found",
        "The requested resource does not exist.",
        request_id(),
    )
    .into_response()
}

fn identity_from_headers(headers: &HeaderMap, request_id: &str) -> Result<Identity, ApiError> {
    let preferred_username = match headers.get("x-forwarded-preferred-username") {
        Some(value) => Some(value.to_str().map_err(|_| {
            ApiError::new(
                StatusCode::UNAUTHORIZED,
                "identity_required",
                "A valid authenticated identity is required.",
                request_id.to_string(),
            )
        })?),
        None => None,
    };
    let username = preferred_username
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            headers
                .get("x-forwarded-user")
                .and_then(|value| value.to_str().ok())
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_default();
    let groups = headers
        .get("x-forwarded-groups")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .split(',');
    Identity::try_new(username, groups).map_err(|_| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "identity_required",
            "A valid authenticated identity is required.",
            request_id.to_string(),
        )
    })
}

fn editor_identity(
    config: &AppConfig,
    headers: &HeaderMap,
    request_id: &str,
) -> Result<Identity, ApiError> {
    let identity = identity_from_headers(headers, request_id)?;
    if !identity.can_edit(&config.editor_group) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "editor_group_required",
            "This action requires the Media Manager editor group.",
            request_id.to_string(),
        ));
    }
    Ok(identity)
}

fn valid_object_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

fn valid_asset_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 240
        && value.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && component
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
}

fn frontend_content_type(path: &str) -> &'static str {
    match path.rsplit_once('.').map(|(_, extension)| extension) {
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn visible_catalog_item(
    config: &AppConfig,
    identity: &Identity,
    catalog: &Catalog,
    item_id: &str,
) -> Result<CatalogItem, ApiError> {
    let item = catalog
        .catalog_item(item_id)
        .map_err(|_| ApiError::internal(String::new()))?
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::CONFLICT,
                "catalog_item_missing",
                "The selected item is no longer present in the catalog.",
            )
        })?;
    let root = config
        .resolve_visible_root(identity, &item.root_id)
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::FORBIDDEN,
                "catalog_item_not_visible",
                "The selected item is outside the caller's visible roots.",
            )
        })?;
    if root.scope == RootScope::Personal
        && item.owner_username.as_deref() != Some(identity.username.as_str())
    {
        return Err(ApiError::without_request_id(
            StatusCode::FORBIDDEN,
            "catalog_item_not_visible",
            "The selected item is outside the caller's visible roots.",
        ));
    }
    Ok(item)
}

fn normalized_subtitle_language(value: &str) -> Option<String> {
    let value = value.trim().to_ascii_lowercase();
    if value.is_empty() || value.len() > 15 {
        return None;
    }
    let parts = value.split('-').collect::<Vec<_>>();
    let first = parts.first()?;
    if !(2..=3).contains(&first.len()) || !first.bytes().all(|byte| byte.is_ascii_alphabetic()) {
        return None;
    }
    if parts.iter().skip(1).any(|part| {
        !(2..=8).contains(&part.len()) || !part.bytes().all(|byte| byte.is_ascii_alphanumeric())
    }) {
        return None;
    }
    Some(value)
}

fn normalized_subtitle_languages(value: &str) -> Option<String> {
    let mut languages = value
        .split(',')
        .map(normalized_subtitle_language)
        .collect::<Option<Vec<_>>>()?;
    languages.sort();
    languages.dedup();
    if languages.is_empty() || languages.len() > 5 {
        return None;
    }
    Some(languages.join(","))
}

fn video_search_title(relative_path: &str) -> &str {
    let filename = relative_path
        .rsplit_once('/')
        .map(|(_, filename)| filename)
        .unwrap_or(relative_path);
    filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename)
}

fn open_subtitles_client(
    config: &AppConfig,
    request_id: &str,
) -> Result<OpenSubtitlesClient, ApiError> {
    let path = config
        .open_subtitles_credentials_file
        .as_deref()
        .filter(|path| path.is_file())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "subtitle_provider_unconfigured",
                "OpenSubtitles credentials are not configured on this server.",
                request_id.to_string(),
            )
        })?;
    let credentials = OpenSubtitlesCredentials::from_file(path).map_err(|error| {
        log_event(
            "subtitle_provider_credentials_invalid",
            request_id,
            json!({ "error": error.to_string() }),
        );
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "subtitle_provider_unconfigured",
            "OpenSubtitles credentials are not valid on this server.",
            request_id.to_string(),
        )
    })?;
    OpenSubtitlesClient::new(credentials).map_err(|error| {
        log_event(
            "subtitle_provider_client_failed",
            request_id,
            json!({ "error": error.to_string() }),
        );
        ApiError::internal(request_id.to_string())
    })
}

fn subtitle_extension<'a>(requested: Option<&'a str>, headers: &HeaderMap) -> Option<&'a str> {
    if let Some(requested) = requested {
        return match requested.to_ascii_lowercase().as_str() {
            "srt" => Some("srt"),
            "vtt" => Some("vtt"),
            "ass" => Some("ass"),
            _ => None,
        };
    }
    match headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .unwrap_or_default()
        .trim()
    {
        "application/x-subrip" | "application/srt" => Some("srt"),
        "text/vtt" => Some("vtt"),
        "text/x-ssa" | "application/x-ass" => Some("ass"),
        _ => None,
    }
}

fn validate_subtitle_bytes(extension: &str, bytes: &[u8]) -> Result<(), ApiError> {
    if bytes.is_empty() || bytes.len() > MAX_SUBTITLE_BYTES || bytes.contains(&0) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_file",
            "The subtitle must be a non-empty text file no larger than 10 MiB.",
        ));
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| {
            ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "subtitle_encoding_unsupported",
                "Subtitle uploads must use UTF-8 text encoding.",
            )
        })?
        .trim_start_matches('\u{feff}');
    let looks_valid = match extension {
        "srt" => text.contains("-->"),
        "vtt" => text.starts_with("WEBVTT"),
        "ass" => text.contains("[Script Info]") && text.contains("[Events]"),
        _ => false,
    };
    if !looks_valid {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "subtitle_syntax_invalid",
            "The uploaded text does not match the selected subtitle format.",
        ));
    }
    Ok(())
}

fn subtitle_sidecar_path(
    video_relative_path: &str,
    language: &str,
    hearing_impaired: bool,
    extension: &str,
) -> String {
    let without_extension = video_relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(video_relative_path);
    let hearing_impaired = if hearing_impaired { ".sdh" } else { "" };
    format!("{without_extension}.{language}{hearing_impaired}.{extension}")
}

fn validate_metadata_request(request: &MetadataSidecarRequest) -> Result<(), ApiError> {
    if !valid_metadata_value(&request.title, 500) || request.title.trim().is_empty() {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_title_required",
            "Metadata requires a non-empty title no longer than 500 characters.",
        ));
    }
    let scalar_fields = [
        (request.sort_title.as_deref(), 500usize),
        (request.description.as_deref(), 20_000usize),
        (request.publisher.as_deref(), 500usize),
        (request.series.as_deref(), 500usize),
        (request.volume_number.as_deref(), 32usize),
        (request.isbn.as_deref(), 64usize),
        (request.language.as_deref(), 15usize),
    ];
    if scalar_fields
        .iter()
        .any(|(value, maximum)| value.is_some_and(|value| !valid_metadata_value(value, *maximum)))
        || request.authors.len() > 32
        || request.narrators.len() > 32
        || request.genres.len() > 64
        || request
            .authors
            .iter()
            .chain(&request.narrators)
            .chain(&request.genres)
            .any(|value| !valid_metadata_value(value, 500) || value.trim().is_empty())
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_fields_invalid",
            "One or more metadata fields exceed the supported size or contain invalid control characters.",
        ));
    }
    if request.year.is_some_and(|year| year == 0 || year > 2100) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_year_invalid",
            "The release year must be omitted when unknown, or be between 1 and 2100.",
        ));
    }
    if request.language.as_deref().is_some_and(|language| {
        normalized_subtitle_language(language).as_deref() != Some(language.trim())
    }) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_language_invalid",
            "Use a lowercase two or three letter language code, optionally followed by a region.",
        ));
    }
    Ok(())
}

fn valid_metadata_value(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .chars()
            .all(|character| !character.is_control() || matches!(character, '\n' | '\r' | '\t'))
}

fn xml_text(value: &str) -> String {
    value
        .trim()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn xml_element(name: &str, value: Option<&str>) -> String {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| format!("  <{name}>{}</{name}>\n", xml_text(value)))
        .unwrap_or_default()
}

fn metadata_sidecar(
    item: &CatalogItem,
    request: &MetadataSidecarRequest,
) -> (String, &'static str, String) {
    let stem = item
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&item.relative_path);
    if item.media_kind == "video" || item.media_kind == "music" {
        let root = if item.media_kind == "video" {
            "movie"
        } else {
            "album"
        };
        let destination = if item.media_kind == "video" {
            format!("{stem}.nfo")
        } else {
            item.relative_path
                .rsplit_once('/')
                .map(|(parent, _)| format!("{parent}/album.nfo"))
                .unwrap_or_else(|| "album.nfo".to_string())
        };
        let mut xml = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{root}>\n");
        xml.push_str(&xml_element("title", Some(&request.title)));
        xml.push_str(&xml_element("sorttitle", request.sort_title.as_deref()));
        if let Some(year) = request.year {
            xml.push_str(&format!("  <year>{year}</year>\n"));
        }
        xml.push_str(&xml_element(
            if item.media_kind == "video" {
                "plot"
            } else {
                "review"
            },
            request.description.as_deref(),
        ));
        xml.push_str(&xml_element("studio", request.publisher.as_deref()));
        xml.push_str(&xml_element("language", request.language.as_deref()));
        for author in &request.authors {
            xml.push_str(&xml_element("artist", Some(author)));
        }
        for genre in &request.genres {
            xml.push_str(&xml_element("genre", Some(genre)));
        }
        xml.push_str(&format!("</{root}>\n"));
        return (destination, "nfo", xml);
    }

    let destination = if item.media_kind == "audiobook" {
        item.relative_path
            .rsplit_once('/')
            .map(|(parent, _)| format!("{parent}/metadata.opf"))
            .unwrap_or_else(|| "metadata.opf".to_string())
    } else {
        format!("{stem}.opf")
    };
    let mut xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\">\n <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n".to_string();
    xml.push_str(&xml_element("dc:title", Some(&request.title)));
    for author in &request.authors {
        xml.push_str(&xml_element("dc:creator", Some(author)));
    }
    xml.push_str(&xml_element(
        "dc:description",
        request.description.as_deref(),
    ));
    xml.push_str(&xml_element("dc:publisher", request.publisher.as_deref()));
    xml.push_str(&xml_element("dc:language", request.language.as_deref()));
    if let Some(year) = request.year {
        xml.push_str(&format!("  <dc:date>{year}</dc:date>\n"));
    }
    if let Some(isbn) = request.isbn.as_deref() {
        xml.push_str(&format!(
            "  <dc:identifier id=\"isbn\">{}</dc:identifier>\n",
            xml_text(isbn)
        ));
    }
    for genre in &request.genres {
        xml.push_str(&xml_element("dc:subject", Some(genre)));
    }
    if let Some(series) = request.series.as_deref() {
        xml.push_str(&format!(
            "  <meta name=\"calibre:series\" content=\"{}\"/>\n",
            xml_text(series)
        ));
    }
    if let Some(volume) = request.volume_number.as_deref() {
        xml.push_str(&format!(
            "  <meta name=\"calibre:series_index\" content=\"{}\"/>\n",
            xml_text(volume)
        ));
    }
    for narrator in &request.narrators {
        xml.push_str(&format!(
            "  <meta name=\"narrator\" content=\"{}\"/>\n",
            xml_text(narrator)
        ));
    }
    xml.push_str(" </metadata>\n</package>\n");
    (destination, "opf", xml)
}

struct StagedSidecar {
    filename: String,
    expected: String,
    path: std::path::PathBuf,
}

async fn stage_sidecar(
    config: &AppConfig,
    extension: &str,
    bytes: &[u8],
    request_id: &str,
) -> Result<StagedSidecar, ApiError> {
    let staging_directory = config.state_dir.join("provider-staging");
    tokio::fs::create_dir_all(&staging_directory)
        .await
        .map_err(|error| {
            log_event(
                "subtitle_staging_failed",
                request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.to_string())
        })?;
    let staging_filename = format!("sidecar-{request_id}.{extension}");
    let staging_path = staging_directory.join(&staging_filename);
    let mut staged = tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o660)
        .open(&staging_path)
        .await
        .map_err(|error| {
            log_event(
                "subtitle_staging_failed",
                request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.to_string())
        })?;
    let write_result = match staged.write_all(bytes).await {
        Ok(()) => staged.sync_all().await,
        Err(error) => Err(error),
    };
    if let Err(error) = write_result {
        let _ = tokio::fs::remove_file(&staging_path).await;
        log_event(
            "subtitle_staging_failed",
            request_id,
            json!({ "error": error.to_string() }),
        );
        return Err(ApiError::internal(request_id.to_string()));
    }
    drop(staged);
    let expected = match file_fingerprint(&staging_path) {
        Ok(expected) => expected,
        Err(error) => {
            let _ = tokio::fs::remove_file(&staging_path).await;
            log_event(
                "subtitle_staging_failed",
                request_id,
                json!({ "error": error.to_string() }),
            );
            return Err(ApiError::internal(request_id.to_string()));
        }
    };
    Ok(StagedSidecar {
        filename: staging_filename,
        expected,
        path: staging_path,
    })
}

fn create_subtitle_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    action: InstallSubtitleAction,
    source: &str,
    request_id: String,
) -> Result<Response, ApiError> {
    let now = unix_timestamp();
    let expires_at = now.saturating_add(30 * 60);
    let broker_action = BrokerAction::InstallSubtitle(action.clone());
    let canonical = serde_json::to_vec(&json!({
        "actor": identity.username,
        "itemId": item.id,
        "source": source,
        "action": broker_action,
        "expiresAt": expires_at,
    }))
    .map_err(|_| ApiError::internal(request_id.clone()))?;
    let digest = sha256_hex(&canonical);
    let plan_id = format!("plan-{request_id}");
    let request_json = json!({
        "kind": "install_subtitle",
        "itemId": item.id,
        "source": source,
    })
    .to_string();
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json,
            expires_at,
            actions: vec![broker_action.clone()],
        })
        .map_err(|error| {
            log_event(
                "mutation_plan_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;
    catalog
        .insert_audit_event(
            &request_id,
            &identity.username,
            "subtitle_install_previewed",
            Some(&plan_id),
            &json!({ "digest": digest, "source": source, "itemId": item.id }).to_string(),
        )
        .map_err(|error| {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;

    let root = state
        .config
        .resolve_visible_root(identity, &item.root_id)
        .ok_or_else(|| ApiError::internal(request_id.clone()))?;
    let destination_exists = FilePath::new(&root.resolved_path)
        .join(&action.destination_relative_path)
        .exists();
    let mut warnings = vec![
        "The subtitle will be installed as a sidecar; the video stream will not be re-encoded.",
        "Existing subtitle files are never overwritten.",
    ];
    if destination_exists {
        warnings.push("The destination already exists, so confirmation will fail safely.");
    }
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "actions": [broker_action],
            "expiresAt": expires_at,
            "mutationMode": state.config.mutation_mode,
            "warnings": warnings,
            "requestId": request_id,
        })),
    )
        .into_response())
}

fn create_metadata_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    request: &MetadataSidecarRequest,
    action: InstallMetadataSidecarAction,
    request_id: String,
) -> Result<Response, ApiError> {
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let broker_action = BrokerAction::InstallMetadataSidecar(action.clone());
    let canonical = serde_json::to_vec(&json!({
        "actor": identity.username,
        "itemId": item.id,
        "request": request,
        "action": broker_action,
        "expiresAt": expires_at,
    }))
    .map_err(|_| ApiError::internal(request_id.clone()))?;
    let digest = sha256_hex(&canonical);
    let plan_id = format!("plan-{request_id}");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json: serde_json::to_string(request)
                .map_err(|_| ApiError::internal(request_id.clone()))?,
            expires_at,
            actions: vec![broker_action.clone()],
        })
        .map_err(|error| {
            log_event(
                "mutation_plan_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;
    catalog
        .insert_audit_event(
            &request_id,
            &identity.username,
            "metadata_sidecar_previewed",
            Some(&plan_id),
            &json!({ "digest": digest, "itemId": item.id }).to_string(),
        )
        .map_err(|error| {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;

    let root = state
        .config
        .resolve_visible_root(identity, &item.root_id)
        .ok_or_else(|| ApiError::internal(request_id.clone()))?;
    let destination_exists = FilePath::new(&root.resolved_path)
        .join(&action.destination_relative_path)
        .exists();
    let mut warnings = vec![
        "Metadata is written as an application-compatible NFO or OPF sidecar; media streams are not re-encoded.",
        "Existing metadata sidecars are never overwritten by this initial safe workflow.",
    ];
    if destination_exists {
        warnings.push("The destination already exists, so confirmation will fail safely.");
    }
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "actions": [broker_action],
            "expiresAt": expires_at,
            "mutationMode": state.config.mutation_mode,
            "warnings": warnings,
            "requestId": request_id,
        })),
    )
        .into_response())
}

fn build_move_actions(
    config: &AppConfig,
    identity: &Identity,
    catalog: &Catalog,
    plan: &PlanRequest,
) -> Result<Vec<MoveAction>, ApiError> {
    let kind = plan.operation.get("kind").and_then(Value::as_str);
    match kind {
        Some("canonicalize_names") => validate_operation_fields(
            &plan.operation,
            &[
                "kind",
                "profile",
                "organizeFolders",
                "title",
                "year",
                "season",
                "episode",
                "episodeTitle",
                "artist",
                "album",
                "track",
                "disc",
                "author",
                "series",
            ],
        )?,
        Some("semantic_move") => {
            validate_operation_fields(&plan.operation, &["kind", "destinationRootId"])?
        }
        _ => {}
    }
    if kind == Some("canonicalize_names") && plan.item_ids.len() != 1 {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "single_item_required",
            "Canonical naming currently requires exactly one catalog item.",
        ));
    }
    let mut actions = Vec::with_capacity(plan.item_ids.len());
    let mut unique_ids = std::collections::BTreeSet::new();
    for item_id in &plan.item_ids {
        if !unique_ids.insert(item_id.as_str()) {
            return Err(ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "duplicate_item",
                "A mutation plan cannot contain the same item more than once.",
            ));
        }
        let item = catalog
            .catalog_item(item_id)
            .map_err(|_| ApiError::internal(String::new()))?
            .ok_or_else(|| {
                ApiError::without_request_id(
                    StatusCode::CONFLICT,
                    "catalog_item_missing",
                    "A selected item is no longer present in the catalog.",
                )
            })?;
        let source_root = config
            .resolve_visible_root(identity, &item.root_id)
            .ok_or_else(|| {
                ApiError::without_request_id(
                    StatusCode::FORBIDDEN,
                    "catalog_item_not_visible",
                    "A selected item is outside the caller's visible roots.",
                )
            })?;
        if source_root.scope == RootScope::Personal
            && item.owner_username.as_deref() != Some(identity.username.as_str())
        {
            return Err(ApiError::without_request_id(
                StatusCode::FORBIDDEN,
                "catalog_item_not_visible",
                "A selected item is outside the caller's visible roots.",
            ));
        }
        let (destination_root_id, destination_relative_path) = match kind {
            Some("canonicalize_names") => (
                item.root_id.clone(),
                canonical_destination(&plan.operation, &item.relative_path, &source_root.category)?,
            ),
            Some("semantic_move") => {
                let destination_root_id = plan
                    .operation
                    .get("destinationRootId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        ApiError::without_request_id(
                            StatusCode::BAD_REQUEST,
                            "destination_root_required",
                            "A semantic move requires a destination root ID.",
                        )
                    })?;
                config
                    .resolve_visible_root(identity, destination_root_id)
                    .ok_or_else(|| {
                        ApiError::without_request_id(
                            StatusCode::FORBIDDEN,
                            "destination_root_not_visible",
                            "The destination root is not visible to this identity.",
                        )
                    })?;
                (destination_root_id.to_string(), item.relative_path.clone())
            }
            _ => {
                return Err(ApiError::without_request_id(
                    StatusCode::NOT_IMPLEMENTED,
                    "operation_not_available",
                    "This operation is not available in the current broker milestone.",
                ))
            }
        };
        if destination_root_id == item.root_id && destination_relative_path == item.relative_path {
            return Err(ApiError::without_request_id(
                StatusCode::CONFLICT,
                "no_change",
                "The canonical destination is identical to the current name.",
            ));
        }
        actions.push(MoveAction {
            source_root_id: item.root_id,
            source_relative_path: item.relative_path,
            destination_root_id,
            destination_relative_path,
            expected: item.fingerprint,
        });
    }
    Ok(actions)
}

fn canonical_destination(
    operation: &Value,
    current_relative: &str,
    root_category: &str,
) -> Result<String, ApiError> {
    let title = operation
        .get("title")
        .and_then(Value::as_str)
        .map(clean_component)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "title_required",
                "Canonical naming requires a non-empty title.",
            )
        })?;
    let year = optional_release_year(operation)?;
    let extension = current_relative
        .rsplit_once('.')
        .map(|(_, extension)| extension)
        .filter(|extension| {
            !extension.is_empty() && extension.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "extension_required",
                "The selected catalog item has no safe file extension.",
            )
        })?;
    let profile = operation
        .get("profile")
        .and_then(Value::as_str)
        .unwrap_or("filename");
    let organize_folders = match operation.get("organizeFolders") {
        None => false,
        Some(value) => value.as_bool().ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "organize_folders_invalid",
                "organizeFolders must be a boolean.",
            )
        })?,
    };
    let season = operation
        .get("season")
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok());
    let episode = operation
        .get("episode")
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok());
    let (filename, organized_parent) = match profile {
        "filename" => match (season, episode) {
            (Some(season), Some(episode)) => (
                canonical_tv_episode(
                    &title,
                    year,
                    season,
                    episode,
                    operation.get("episodeTitle").and_then(Value::as_str),
                    extension,
                ),
                None,
            ),
            (None, None) => (
                format!("{}.{}", canonical_movie_directory(&title, year), extension),
                None,
            ),
            _ => return Err(season_episode_pair_error()),
        },
        "movie" if root_category == "videos" => {
            let label = canonical_movie_directory(&title, year);
            (
                format!("{label}.{extension}"),
                organize_folders.then_some(label),
            )
        }
        "tv" if root_category == "videos" => {
            let (Some(season), Some(episode)) = (season, episode) else {
                return Err(season_episode_pair_error());
            };
            if episode == 0 {
                return Err(ApiError::without_request_id(
                    StatusCode::BAD_REQUEST,
                    "episode_required",
                    "TV episode numbers must be at least 1.",
                ));
            }
            let show = canonical_movie_directory(&title, year);
            let filename = canonical_tv_episode(
                &title,
                year,
                season,
                episode,
                operation.get("episodeTitle").and_then(Value::as_str),
                extension,
            );
            (
                filename,
                organize_folders.then(|| format!("{show}/Season {season:02}")),
            )
        }
        "music" if root_category == "music" => {
            let artist = required_clean_field(operation, "artist", "Artist")?;
            let album = required_clean_field(operation, "album", "Album")?;
            let track = required_u16_field(operation, "track", "Track", 1)?;
            let disc = optional_u16_field(operation, "disc")?;
            let album = canonical_movie_directory(&album, year);
            (
                canonical_music_track(track, &title, disc, extension),
                organize_folders.then(|| format!("{artist}/{album}")),
            )
        }
        "audiobook" if root_category == "audiobooks" => {
            creator_collection_destination(operation, &title, year, extension, organize_folders)?
        }
        "book" if root_category == "books" => {
            creator_collection_destination(operation, &title, year, extension, organize_folders)?
        }
        _ => {
            return Err(ApiError::without_request_id(
                StatusCode::BAD_REQUEST,
                "profile_root_mismatch",
                "The selected naming profile is not valid for this media root.",
            ))
        }
    };
    let destination = if let Some(parent) = organized_parent {
        format!("{parent}/{filename}")
    } else {
        match current_relative.rsplit_once('/') {
            Some((parent, _)) => format!("{parent}/{filename}"),
            None => filename,
        }
    };
    validate_generated_destination(&destination)?;
    Ok(destination)
}

fn creator_collection_destination(
    operation: &Value,
    title: &str,
    year: Option<u16>,
    extension: &str,
    organize_folders: bool,
) -> Result<(String, Option<String>), ApiError> {
    let author = required_clean_field(operation, "author", "Author")?;
    let label = canonical_movie_directory(title, year);
    let series = optional_clean_field(operation, "series");
    let parent = organize_folders.then(|| match series {
        Some(series) => format!("{author}/{series}/{label}"),
        None => format!("{author}/{label}"),
    });
    Ok((format!("{label}.{extension}"), parent))
}

fn validate_operation_fields(operation: &Value, allowed: &[&str]) -> Result<(), ApiError> {
    let object = operation.as_object().ok_or_else(|| {
        ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "operation_invalid",
            "A mutation operation must be a JSON object.",
        )
    })?;
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "operation_field_unknown",
            "The mutation operation contains an unknown field.",
        ));
    }
    Ok(())
}

fn validate_generated_destination(destination: &str) -> Result<(), ApiError> {
    let valid = !destination.is_empty()
        && destination.len() <= 4096
        && !destination.starts_with('/')
        && destination.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && component.len() <= 255
                && !component.contains(['\\', '\0'])
        });
    if valid {
        Ok(())
    } else {
        Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "generated_path_invalid",
            "The supplied fields produce a path component that is too long or unsafe.",
        ))
    }
}

fn optional_release_year(operation: &Value) -> Result<Option<u16>, ApiError> {
    match operation.get("year") {
        None => Ok(None),
        Some(value) => value
            .as_u64()
            .and_then(|year| u16::try_from(year).ok())
            .filter(|year| (1..=2100).contains(year))
            .map(Some)
            .ok_or_else(|| {
                ApiError::without_request_id(
                    StatusCode::BAD_REQUEST,
                    "release_year_invalid",
                    "Release year must be a whole number from 1 through 2100, or omitted when unknown.",
                )
            }),
    }
}

fn required_clean_field(operation: &Value, key: &str, label: &str) -> Result<String, ApiError> {
    optional_clean_field(operation, key).ok_or_else(|| {
        ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "naming_field_required",
            format!("{label} is required for this naming profile."),
        )
    })
}

fn optional_clean_field(operation: &Value, key: &str) -> Option<String> {
    operation
        .get(key)
        .and_then(Value::as_str)
        .map(clean_component)
        .filter(|value| !value.is_empty())
}

fn required_u16_field(
    operation: &Value,
    key: &str,
    label: &str,
    minimum: u16,
) -> Result<u16, ApiError> {
    let value = optional_u16_field(operation, key)?.ok_or_else(|| {
        ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "naming_number_required",
            format!("{label} is required for this naming profile."),
        )
    })?;
    if value < minimum {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "naming_number_invalid",
            format!("{label} must be at least {minimum}."),
        ));
    }
    Ok(value)
}

fn optional_u16_field(operation: &Value, key: &str) -> Result<Option<u16>, ApiError> {
    match operation.get(key) {
        None => Ok(None),
        Some(value) => value
            .as_u64()
            .and_then(|value| u16::try_from(value).ok())
            .map(Some)
            .ok_or_else(|| {
                ApiError::without_request_id(
                    StatusCode::BAD_REQUEST,
                    "naming_number_invalid",
                    format!("{key} must be a non-negative whole number."),
                )
            }),
    }
}

fn season_episode_pair_error() -> ApiError {
    ApiError::without_request_id(
        StatusCode::BAD_REQUEST,
        "season_episode_pair_required",
        "Season and episode numbers must be supplied together.",
    )
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn request_id() -> String {
    let micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros();
    let sequence = REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("r{micros:x}-{sequence:x}")
}

fn unix_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

fn log_event(event: &str, request_id: &str, detail: Value) {
    eprintln!(
        "{}",
        json!({
            "level": "warn",
            "service": "media-manager",
            "event": event,
            "requestId": request_id,
            "detail": detail,
        })
    );
}

struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    request_id: String,
}

impl ApiError {
    fn new(
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
        request_id: String,
    ) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            request_id,
        }
    }

    fn internal(request_id: String) -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "The request could not be completed.",
            request_id,
        )
    }

    fn without_request_id(
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
    ) -> Self {
        Self::new(status, code, message, String::new())
    }

    fn with_request_id(mut self, request_id: String) -> Self {
        if self.request_id.is_empty() {
            self.request_id = request_id;
        }
        self
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "error": {
                    "code": self.code,
                    "message": self.message,
                    "requestId": self.request_id,
                }
            })),
        )
            .into_response()
    }
}
