use crate::musicbrainz::{
    AcoustidCredentials, LookupMode, MusicBrainzClient, MusicBrainzClientConfig, ACOUSTID_API_BASE,
    MUSICBRAINZ_API_BASE,
};
use crate::tmdb::TmdbClient;
use crate::{
    artwork::{
        is_embedded_artwork_capable, preferred_artwork, read_artwork_file, read_embedded_artwork,
        ArtworkBody,
    },
    broker::{
        file_fingerprint, open_directory_beneath, open_regular_file_beneath,
        opened_file_fingerprint, BrokerAction, InstallMetadataSidecarAction, InstallSubtitleAction,
        MoveAction, ReplaceArtworkAction, ReplaceEmbeddedMetadataAction,
        ReplaceMetadataSidecarAction,
    },
    catalog::{Catalog, CatalogHandle, CatalogItem, ConfirmPlanOutcome, MutationPlanDraft},
    config::{AppConfig, Identity, MutationMode, RootScope, VisibleRoot, TOMBSTONE_FOLDER},
    metadata::{
        application_observation, consumer_effects, filename_observation, folder_sidecar_path,
        health_issues, initial_field_sources, inspect_embedded_metadata, inspect_sidecar,
        item_sidecar_path, merge_managed_sidecar, modification_targets, rewrite_embedded_metadata,
        MetadataObservation,
    },
    naming::{
        canonical_movie_directory, canonical_music_track, canonical_tv_episode, clean_component,
    },
    scanner::{media_kind as scanned_media_kind, rescan_root, ScanRoot},
    subtitle_format::{parse_srt, parse_subtitle, subtitle_validation},
    subtitles::{
        opensubtitles_movie_hash, OpenSubtitlesClient, OpenSubtitlesCredentials, SubtitleMatch,
    },
    video_probe::{probe_video, refresh_root_probes, VideoProbe, VideoProbeCache},
};
use axum::{
    body::{to_bytes, Bytes},
    extract::{Path, Query, Request, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE},
        HeaderMap, HeaderName, StatusCode,
    },
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeSet, HashMap},
    io::{Cursor, Read},
    os::fd::AsRawFd,
    os::unix::fs::OpenOptionsExt,
    path::Path as FilePath,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const MAX_SUBTITLE_BYTES: usize = 10 * 1024 * 1024;
const MAX_ARTWORK_UPLOAD_BYTES: usize = 32 * 1024 * 1024;
const MAX_INBOX_ENTRIES: usize = 200;

const JELLYFIN_IMAGE_CACHE_TTL: Duration = Duration::from_secs(3600);
const JELLYFIN_IMAGE_CACHE_MAX_ENTRIES: usize = 2048;

pub struct JellyfinImageCache {
    entries: Mutex<HashMap<String, CachedJellyfinImage>>,
    max_entries: usize,
}

struct CachedJellyfinImage {
    data: Vec<u8>,
    content_type: String,
    expires: Instant,
}

impl Default for JellyfinImageCache {
    fn default() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            max_entries: JELLYFIN_IMAGE_CACHE_MAX_ENTRIES,
        }
    }
}

impl JellyfinImageCache {
    pub fn new() -> Self {
        Self::default()
    }

    fn get(&self, key: &str) -> Option<(Vec<u8>, String)> {
        let entries = self.entries.lock().expect("cache lock");
        entries
            .get(key)
            .filter(|entry| entry.expires > Instant::now())
            .map(|entry| (entry.data.clone(), entry.content_type.clone()))
    }

    fn insert(&self, key: String, data: Vec<u8>, content_type: String) {
        let mut entries = self.entries.lock().expect("cache lock");
        if entries.len() >= self.max_entries {
            let now = Instant::now();
            entries.retain(|_, entry| entry.expires > now);
        }
        if entries.len() < self.max_entries {
            entries.insert(
                key,
                CachedJellyfinImage {
                    data,
                    content_type,
                    expires: Instant::now() + JELLYFIN_IMAGE_CACHE_TTL,
                },
            );
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub catalog: CatalogHandle,
    pub jellyfin_image_cache: Arc<JellyfinImageCache>,
    pub tmdb_client: Option<Arc<TmdbClient>>,
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
    #[serde(default)]
    include_video_probes: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderMetadataQuery {
    root_id: String,
    relative_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArtworkReplacementQuery {
    format: String,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AdjustSubtitleRequest {
    file_id: i64,
    source_fps: f64,
    target_fps: f64,
    language: String,
    #[serde(default)]
    hearing_impaired: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BatchSubtitleSearchRequest {
    item_ids: Vec<String>,
    languages: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MetadataSidecarRequest {
    media_type: Option<String>,
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
    season: Option<u32>,
    episode: Option<u32>,
    episode_title: Option<String>,
    premiere_date: Option<String>,
    runtime_minutes: Option<u32>,
    official_rating: Option<String>,
    community_rating: Option<f32>,
    #[serde(default)]
    writers: Vec<String>,
    #[serde(default)]
    provider_ids: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MusicLookupRequest {
    mode: Option<String>,
    artist: Option<String>,
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TmdbSearchRequest {
    query: String,
    year: Option<u16>,
    media_type: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TmdbDetailsRequest {
    tmdb_id: u32,
    media_type: String,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/assets/{*asset_path}", get(frontend_asset))
        .route("/api/v1/status", get(status))
        .route("/api/v1/session", get(session))
        .route("/api/v1/roots", get(roots))
        .route("/api/v1/items", get(items))
        .route("/api/v1/items/{item_id}/image", get(item_image))
        .route(
            "/api/v1/items/{item_id}/image/replacement",
            post(preview_artwork_replacement),
        )
        .route("/api/v1/items/{item_id}/stream", get(item_stream))
        .route(
            "/api/v1/items/{item_id}/playback",
            get(get_playback_position).put(put_playback_position),
        )
        .route("/api/v1/items/{item_id}/metadata", get(item_metadata))
        .route("/api/v1/folders/metadata", get(folder_metadata))
        .route("/api/v1/conversions", get(conversions))
        .route("/api/v1/conversions/inbox", get(conversions_inbox))
        .route(
            "/api/v1/conversions/inbox/error",
            get(conversions_inbox_error),
        )
        .route("/api/v1/scans", post(scan))
        .route(
            "/api/v1/items/{item_id}/subtitles/upload",
            post(upload_subtitle),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles",
            get(installed_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/installed/{subtitle_id}/content",
            get(installed_subtitle_content),
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
            "/api/v1/items/{item_id}/subtitles/provider/{file_id}/content",
            get(subtitle_provider_content),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/adjust",
            post(adjust_subtitle_timing),
        )
        .route(
            "/api/v1/subtitles/batch-search",
            post(batch_search_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/metadata/sidecar",
            post(preview_metadata_sidecar),
        )
        .route(
            "/api/v1/folders/metadata/sidecar",
            post(preview_folder_metadata_sidecar),
        )
        .route(
            "/api/v1/items/{item_id}/metadata/lookup",
            post(lookup_music_metadata),
        )
        .route("/api/v1/metadata/tmdb/search", post(search_tmdb_metadata))
        .route("/api/v1/metadata/tmdb/details", post(get_tmdb_details))
        .route(
            "/api/v1/integrations/{integration_id}/refresh",
            get(integration_refresh_status).post(queue_integration_refresh),
        )
        .route("/api/v1/plans", post(preview_plan))
        .route("/api/v1/plans/{plan_id}", get(plan_status))
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
    matches!(
        integration_id,
        "jellyfin" | "audiobookshelf" | "kavita" | "syncthing"
    ) && config.integrations.iter().any(|integration| {
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
    let client = match open_subtitles_client(&state.config, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let relative_path = item.relative_path.clone();
    let video_probe = probe_for_video(&state, &root, &item, request_id.clone()).await;
    let root_path = root.resolved_path;
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
        return subtitle_result_payload(
            search_query,
            &languages,
            "movie-hash",
            exact_results,
            &video_probe,
            &request_id,
        );
    }

    match client.search_by_query(search_query, &languages).await {
        Ok(results) => subtitle_result_payload(
            search_query,
            &languages,
            "title-fallback",
            results,
            &video_probe,
            &request_id,
        ),
        Err(error) => subtitle_provider_search_error(error, &request_id).into_response(),
    }
}

async fn batch_search_subtitles(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<BatchSubtitleSearchRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let languages = match normalized_subtitle_languages(&request.languages) {
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
    if request.item_ids.is_empty() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "no_items",
            "At least one item ID must be provided.",
            request_id,
        )
        .into_response();
    }
    if request.item_ids.len() > 50 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "too_many_items",
            "Maximum 50 items per batch search.",
            request_id,
        )
        .into_response();
    }
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
    let client = match open_subtitles_client(&state.config, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };

    let mut batch_results = Vec::new();
    for item_id in request.item_ids {
        let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
            Ok(item) if item.media_kind == "video" => item,
            Ok(_) => continue,
            Err(_) => continue,
        };
        let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
            Some(root) => root,
            None => continue,
        };
        let relative_path = item.relative_path.clone();
        let video_probe =
            probe_for_video(&state, &root, &item, format!("{request_id}-{item_id}")).await;
        let root_path = root.resolved_path.clone();
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
            _ => None,
        };

        let search_query = video_search_title(&item.relative_path);
        let exact_results = match movie_hash.as_ref() {
            Some(movie_hash) => match client.search_by_hash(movie_hash, &languages).await {
                Ok(results) => results
                    .into_iter()
                    .filter(|result| result.hash_matched)
                    .collect::<Vec<_>>(),
                Err(_) => Vec::new(),
            },
            None => Vec::new(),
        };

        let has_exact_results = !exact_results.is_empty();

        let results = if has_exact_results {
            exact_results
        } else {
            client
                .search_by_query(search_query, &languages)
                .await
                .unwrap_or_default()
        };

        let video_fps = video_probe.as_ref().and_then(|probe| probe.fps);
        let video_codec = video_probe.as_ref().and_then(|probe| probe.codec.clone());
        let video_width = video_probe.as_ref().and_then(|probe| probe.width);
        let video_height = video_probe.as_ref().and_then(|probe| probe.height);

        let results_with_compat = results
            .into_iter()
            .map(|result| {
                let fps_compatible = subtitle_fps_compatible(result.fps, video_fps);
                let mut value = serde_json::to_value(&result).unwrap_or_else(|_| json!({}));
                value["fpsCompatible"] = match fps_compatible {
                    Some(compatible) => json!(compatible),
                    None => Value::Null,
                };
                value
            })
            .collect::<Vec<_>>();

        batch_results.push(json!({
            "itemId": item.id,
            "relativePath": item.relative_path,
            "videoSummary": {
                "codec": video_codec,
                "width": video_width,
                "height": video_height,
                "fps": video_fps,
            },
            "results": results_with_compat,
            "matchMethod": if has_exact_results { "movie-hash" } else { "title-fallback" },
        }));
    }

    Json(json!({
        "batchResults": batch_results,
        "requestId": request_id,
    }))
    .into_response()
}

fn subtitle_result_payload(
    search_query: &str,
    languages: &str,
    match_method: &str,
    results: Vec<SubtitleMatch>,
    video_probe: &Option<VideoProbe>,
    request_id: &str,
) -> Response {
    let video_fps = video_probe.as_ref().and_then(|probe| probe.fps);
    let video_codec = video_probe.as_ref().and_then(|probe| probe.codec.clone());
    let video_width = video_probe.as_ref().and_then(|probe| probe.width);
    let video_height = video_probe.as_ref().and_then(|probe| probe.height);
    let results = results
        .into_iter()
        .map(|result| {
            let fps_compatible = subtitle_fps_compatible(result.fps, video_fps);
            let mut value = serde_json::to_value(&result).unwrap_or_else(|_| json!({}));
            value["fpsCompatible"] = match fps_compatible {
                Some(compatible) => json!(compatible),
                None => Value::Null,
            };
            value
        })
        .collect::<Vec<_>>();
    Json(json!({
        "provider": "opensubtitles",
        "query": search_query,
        "languages": languages,
        "matchMethod": match_method,
        "results": results,
        "video": video_probe,
        "videoSummary": {
            "codec": video_codec,
            "width": video_width,
            "height": video_height,
            "fps": video_fps,
        },
        "requestId": request_id,
    }))
    .into_response()
}

fn subtitle_fps_compatible(subtitle_fps: Option<f64>, video_fps: Option<f64>) -> Option<bool> {
    match (subtitle_fps, video_fps) {
        (Some(subtitle_fps), Some(video_fps)) if video_fps > 0.0 => {
            Some((subtitle_fps - video_fps).abs() <= 0.5)
        }
        _ => None,
    }
}

async fn probe_for_video(
    state: &AppState,
    root: &VisibleRoot,
    item: &CatalogItem,
    request_id: String,
) -> Option<VideoProbe> {
    let ffprobe = state.config.ffprobe_path.clone()?;
    let state_dir = state.config.state_dir.clone();
    let root_id = root.id.clone();
    let root_path = root.resolved_path.clone();
    let relative_path = item.relative_path.clone();
    let fingerprint = item.fingerprint.clone();
    let item_id = item.id.clone();
    let request_id_for_probe = request_id.clone();
    let item_id_for_probe = item_id.clone();
    match tokio::task::spawn_blocking(move || {
        let mut cache = VideoProbeCache::open(&state_dir, &root_id);
        if let Some(probe) = cache.probe_for(&relative_path, &fingerprint) {
            return Some(probe);
        }
        let probe = match probe_video(
            FilePath::new(&ffprobe),
            &FilePath::new(&root_path).join(&relative_path),
        ) {
            Ok(probe) => Some(probe),
            Err(error) => {
                log_event(
                    "video_probe_failed",
                    &request_id_for_probe,
                    json!({ "error": error, "itemId": item_id_for_probe }),
                );
                None
            }
        };
        cache.set(&relative_path, &fingerprint, probe.clone());
        let _ = cache.save();
        probe
    })
    .await
    {
        Ok(probe) => probe,
        Err(error) => {
            log_event(
                "video_probe_task_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item_id }),
            );
            None
        }
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
    let client = match open_subtitles_client(&state.config, &identity, &request_id) {
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

async fn subtitle_provider_content(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((item_id, file_id)): Path<(String, i64)>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if file_id <= 0 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_provider_file_id",
            "The selected provider file ID is invalid.",
            request_id,
        )
        .into_response();
    }
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
    let _item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitle content requires a cataloged video file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let client = match open_subtitles_client(&state.config, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let bytes = match client.download(file_id).await {
        Ok(bytes) => bytes,
        Err(error) => {
            log_event(
                "subtitle_provider_download_failed",
                &request_id,
                json!({ "error": error.to_string(), "fileId": file_id }),
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
    if bytes.is_empty() || bytes.len() > MAX_SUBTITLE_BYTES || bytes.contains(&0) {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_file",
            "The subtitle must be a non-empty text file no larger than 10 MiB.",
            request_id,
        )
        .into_response();
    }
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text,
        Err(_) => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "subtitle_encoding_unsupported",
                "Subtitle previews require UTF-8 text encoding.",
                request_id,
            )
            .into_response()
        }
    };
    let cues = match parse_srt(text) {
        Ok(cues) => cues,
        Err(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_syntax_invalid",
                "The provider returned a subtitle that could not be parsed as SRT.",
                request_id,
            )
            .into_response()
        }
    };
    const MAX_PREVIEW_CUES: usize = 40;
    let truncated = cues.len() > MAX_PREVIEW_CUES;
    let preview = cues.into_iter().take(MAX_PREVIEW_CUES).collect::<Vec<_>>();
    Json(json!({
        "provider": "opensubtitles",
        "fileId": file_id,
        "cues": preview,
        "truncated": truncated,
        "requestId": request_id,
    }))
    .into_response()
}

async fn adjust_subtitle_timing(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<AdjustSubtitleRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if request.file_id <= 0
        || !request.source_fps.is_finite()
        || !request.target_fps.is_finite()
        || request.source_fps <= 0.0
        || request.target_fps <= 0.0
        || request.source_fps > 240.0
        || request.target_fps > 240.0
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_fps",
            "Source and target frame rates must be positive numbers.",
            request_id,
        )
        .into_response();
    }
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
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitle adjustment requires a cataloged video file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };

    let client = match open_subtitles_client(&state.config, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let bytes = match client.download(request.file_id).await {
        Ok(bytes) => bytes,
        Err(error) => {
            log_event(
                "subtitle_provider_download_failed",
                &request_id,
                json!({ "error": error, "fileId": request.file_id }),
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
        return error.with_request_id(request_id).into_response();
    }
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text,
        Err(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_encoding_unsupported",
                "Timing adjustment requires a UTF-8 SRT subtitle.",
                request_id,
            )
            .into_response()
        }
    };
    let ratio = request.target_fps / request.source_fps;
    let adjusted = adjust_srt_timing(text, ratio).into_bytes();
    if let Err(error) = validate_subtitle_bytes("srt", &adjusted) {
        return error.with_request_id(request_id).into_response();
    }
    let destination_relative_path = subtitle_sidecar_path(
        &item.relative_path,
        &language,
        request.hearing_impaired,
        "srt",
    );
    let staged = match stage_sidecar(&state.config, "srt", &adjusted, &request_id).await {
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
        "opensubtitles-fps-adjusted",
        request_id,
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(&staging_path).await;
            error.into_response()
        }
    }
}

fn adjust_srt_timing(text: &str, ratio: f64) -> String {
    let mut result = String::new();
    for line in text.lines() {
        if line.contains("-->") {
            let parts: Vec<&str> = line.split("-->").collect();
            if parts.len() == 2 {
                let start = adjust_timestamp(parts[0].trim(), ratio);
                let end = adjust_timestamp(parts[1].trim(), ratio);
                result.push_str(&format!("{} --> {}\n", start, end));
            } else {
                result.push_str(line);
                result.push('\n');
            }
        } else {
            result.push_str(line);
            result.push('\n');
        }
    }
    result
}

fn adjust_timestamp(timestamp: &str, ratio: f64) -> String {
    let (time_part, frac_part) = timestamp.split_once([',', '.']).unwrap_or((timestamp, "0"));
    let parts: Vec<u64> = time_part
        .split(':')
        .map(|p| p.parse::<u64>().unwrap_or(0))
        .collect();
    if parts.len() != 3 {
        return timestamp.to_string();
    }
    let total_ms = (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        + frac_part.parse::<u64>().unwrap_or(0) * 10_u64.pow(3 - frac_part.len().min(3) as u32);
    let adjusted_ms = ((total_ms as f64) / ratio).round() as u64;
    let hours = adjusted_ms / 3_600_000;
    let minutes = (adjusted_ms % 3_600_000) / 60_000;
    let seconds = (adjusted_ms % 60_000) / 1_000;
    let millis = adjusted_ms % 1_000;
    if timestamp.contains(',') {
        format!("{:02}:{:02}:{:02},{:03}", hours, minutes, seconds, millis)
    } else {
        format!("{:02}:{:02}:{:02}.{:03}", hours, minutes, seconds, millis)
    }
}

async fn installed_subtitles(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let video = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitle inventory requires a video item.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let owner = video.owner_username.as_deref();
    let directory = video
        .relative_path
        .rsplit_once('/')
        .map(|(directory, _)| directory)
        .unwrap_or("");
    let catalog_items =
        match catalog.list_subtitles_in_directory(&video.root_id, owner, directory, 256) {
            Ok(items) => items,
            Err(_) => return ApiError::internal(request_id).into_response(),
        };
    let mut subtitles = catalog_items
        .iter()
        .filter(|item| item.media_kind == "subtitle" && subtitle_belongs_to_video(&video, item))
        .map(|item| external_subtitle_inventory(&video, item))
        .collect::<Vec<_>>();
    let probe_cache = VideoProbeCache::open(&state.config.state_dir, &video.root_id);
    if let Some(probe) = probe_cache.probe_for(&video.relative_path, &video.fingerprint) {
        if probe.subtitle_streams.is_empty() {
            for language in probe.subtitle_languages {
                subtitles.push(json!({
                    "source": "embedded",
                    "language": language,
                    "format": null,
                    "isDefault": false,
                    "isForced": false,
                    "isHearingImpaired": false,
                    "isPreviewable": false,
                }));
            }
        } else {
            for stream in probe.subtitle_streams {
                subtitles.push(json!({
                    "source": "embedded",
                    "streamIndex": stream.index,
                    "language": stream.language,
                    "title": stream.title,
                    "format": stream.codec,
                    "isDefault": stream.is_default,
                    "isForced": stream.is_forced,
                    "isHearingImpaired": stream.is_hearing_impaired,
                    "isPreviewable": false,
                }));
            }
        }
    }
    Json(json!({
        "itemId": video.id,
        "subtitles": subtitles,
        "consumers": [{
            "id": "jellyfin",
            "label": "Jellyfin",
            "available": state.config.integrations.iter().any(|integration| integration.id == "jellyfin" && integration.available),
            "effect": "read-after-refresh",
            "canManageNatively": true,
            "nativeUrl": state.config.jellyfin_public_url,
            "message": "Jellyfin can list, upload, search, download, and remove subtitles natively. Media Manager adds portable-file inspection and validation."
        }],
        "requestId": request_id,
    }))
    .into_response()
}

async fn installed_subtitle_content(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((item_id, subtitle_id)): Path<(String, String)>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let video = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "video" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "video_item_required",
                "Subtitle previews require a video item.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let subtitle = match visible_catalog_item(&state.config, &identity, &catalog, &subtitle_id) {
        Ok(item) if item.media_kind == "subtitle" && subtitle_belongs_to_video(&video, &item) => {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "subtitle_item_mismatch",
                "The selected subtitle is not installed beside this video.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let root = match state.config.resolve_visible_root(&identity, &video.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let mut file = match open_regular_file_beneath(
        FilePath::new(&root.resolved_path),
        &subtitle.relative_path,
    ) {
        Ok(file) => file,
        Err(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "subtitle_file_missing",
                "The installed subtitle is no longer available.",
                request_id,
            )
            .into_response()
        }
    };
    let mut bytes = Vec::new();
    if file
        .by_ref()
        .take(MAX_SUBTITLE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.is_empty()
        || bytes.len() > MAX_SUBTITLE_BYTES
        || bytes.contains(&0)
    {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "subtitle_file_invalid",
            "The installed subtitle is empty, binary, or too large to preview.",
            request_id,
        )
        .into_response();
    }
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text,
        Err(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_encoding_unsupported",
                "Installed subtitle previews require UTF-8 text encoding.",
                request_id,
            )
            .into_response()
        }
    };
    let format = subtitle
        .relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    let cues = match parse_subtitle(&format, text) {
        Ok(cues) => cues,
        Err(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_syntax_invalid",
                "The installed subtitle could not be parsed.",
                request_id,
            )
            .into_response()
        }
    };
    const MAX_PREVIEW_CUES: usize = 40;
    let validation = subtitle_validation(&cues);
    let truncated = cues.len() > MAX_PREVIEW_CUES;
    Json(json!({
        "source": "installed",
        "itemId": subtitle.id,
        "relativePath": subtitle.relative_path,
        "format": format,
        "cues": cues.into_iter().take(MAX_PREVIEW_CUES).collect::<Vec<_>>(),
        "truncated": truncated,
        "validation": validation,
        "requestId": request_id,
    }))
    .into_response()
}

fn subtitle_belongs_to_video(video: &CatalogItem, subtitle: &CatalogItem) -> bool {
    let video_stem = video
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&video.relative_path);
    let subtitle_stem = subtitle
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&subtitle.relative_path);
    subtitle_stem == video_stem || subtitle_stem.starts_with(&format!("{video_stem}."))
}

fn external_subtitle_inventory(video: &CatalogItem, subtitle: &CatalogItem) -> Value {
    let video_stem = video
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&video.relative_path);
    let subtitle_stem = subtitle
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&subtitle.relative_path);
    let suffix = subtitle_stem
        .strip_prefix(video_stem)
        .unwrap_or_default()
        .trim_start_matches('.');
    let tokens = suffix
        .split('.')
        .filter(|token| !token.is_empty())
        .collect::<Vec<_>>();
    let language = tokens
        .first()
        .and_then(|language| normalized_subtitle_language(language));
    let is_forced = tokens
        .iter()
        .any(|token| matches!(token.to_ascii_lowercase().as_str(), "forced" | "foreign"));
    let is_hearing_impaired = tokens
        .iter()
        .any(|token| matches!(token.to_ascii_lowercase().as_str(), "sdh" | "cc" | "hi"));
    let is_default = tokens
        .iter()
        .any(|token| token.eq_ignore_ascii_case("default"));
    let format = subtitle
        .relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    json!({
        "source": "external",
        "itemId": subtitle.id,
        "relativePath": subtitle.relative_path,
        "sizeBytes": subtitle.size_bytes,
        "format": format,
        "language": language,
        "isDefault": is_default,
        "isForced": is_forced,
        "isHearingImpaired": is_hearing_impaired,
        "isPreviewable": matches!(format.as_str(), "srt" | "vtt" | "ass"),
    })
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
                "Metadata sidecars require a video, music, audiobook, or book item. Podcast tags are currently inspection-only.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let type_matches_item = matches!(
        (item.media_kind.as_str(), request.media_type.as_deref()),
        (_, None)
            | ("video", Some("movie" | "episode"))
            | ("music", Some("music"))
            | ("audiobook", Some("audiobook"))
            | ("book", Some("book"))
    );
    if !type_matches_item {
        return ApiError::new(
            StatusCode::CONFLICT,
            "metadata_type_mismatch",
            "The metadata type does not match the catalog item.",
            request_id,
        )
        .into_response();
    }
    if item.media_kind == "book" {
        let extension = item
            .relative_path
            .rsplit_once('.')
            .map(|(_, extension)| extension.to_ascii_lowercase())
            .unwrap_or_default();
        if !matches!(extension.as_str(), "epub" | "cbz") {
            return ApiError::new(
                StatusCode::CONFLICT,
                "embedded_book_metadata_read_only",
                "PDF and CBR metadata are inspection-only. Portable in-app edits are limited to EPUB and CBZ containers.",
                request_id,
            )
            .into_response();
        }
        let generated = if extension == "epub" {
            metadata_sidecar(&item, &request).2
        } else {
            comicinfo_sidecar(&request)
        };
        let prepared = match prepare_embedded_metadata_action(
            &state.config,
            &identity,
            &item,
            &extension,
            &generated,
            &request_id,
        )
        .await
        {
            Ok(prepared) => prepared,
            Err(error) => return error.into_response(),
        };
        return match create_metadata_plan(
            &state,
            &identity,
            &mut catalog,
            &item,
            &request,
            prepared.action,
            request_id.clone(),
        ) {
            Ok(response) => response,
            Err(error) => {
                let _ = tokio::fs::remove_file(prepared.staging_path).await;
                error.into_response()
            }
        };
    }
    let (destination_relative_path, extension, contents) = metadata_sidecar(&item, &request);
    let prepared = match prepare_metadata_action(
        &state.config,
        &identity,
        &item.root_id,
        destination_relative_path,
        extension,
        &contents,
        &request_id,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => return error.into_response(),
    };
    match create_metadata_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        &request,
        prepared.action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            error.into_response()
        }
    }
}

async fn item_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item)
            if ["video", "music", "audiobook", "podcast", "book"]
                .contains(&item.media_kind.as_str()) =>
        {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "metadata_item_unsupported",
                "Metadata is available for video, music, audiobook, podcast, or book items.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };

    let mut response = filename_metadata(&item);
    let mut observations = vec![filename_observation(&response)];
    let mut field_sources = initial_field_sources(&response, "filename");
    let mut inspection_warnings = Vec::new();
    if let Some(root) = state.config.resolve_visible_root(&identity, &item.root_id) {
        let root_path = root.resolved_path;
        let inspected_item = item.clone();
        match tokio::task::spawn_blocking(move || {
            inspect_embedded_metadata(FilePath::new(&root_path), &inspected_item)
        })
        .await
        {
            Ok(Ok(Some(observation))) => {
                merge_metadata(
                    &mut response,
                    &observation.fields,
                    &observation.source,
                    &mut field_sources,
                );
                observations.push(observation);
            }
            Ok(Ok(None)) => {}
            Ok(Err(message)) => inspection_warnings.push(message),
            Err(_) => inspection_warnings
                .push("Embedded metadata inspection did not complete.".to_string()),
        }
    }
    if let Some(cache_file) = &state.config.jellyfin_metadata_cache_file {
        if let Some(entry) = cached_application_metadata(cache_file, &item, false).await {
            observations.push(application_observation("jellyfin", "Jellyfin", &entry));
            merge_metadata(&mut response, &entry, "jellyfin", &mut field_sources);
        }
    }
    if matches!(item.media_kind.as_str(), "audiobook" | "podcast") {
        if let Some(cache_file) = &state.config.audiobookshelf_metadata_cache_file {
            if let Some(entry) = cached_application_metadata(cache_file, &item, true).await {
                observations.push(application_observation(
                    "audiobookshelf",
                    "Audiobookshelf",
                    &entry,
                ));
                merge_metadata(&mut response, &entry, "audiobookshelf", &mut field_sources);
            }
        }
    }
    if item.media_kind == "book" {
        if let Some(cache_file) = &state.config.kavita_metadata_cache_file {
            if let Some(entry) = cached_application_metadata(cache_file, &item, true).await {
                observations.push(application_observation("kavita", "Kavita", &entry));
                merge_metadata(&mut response, &entry, "kavita", &mut field_sources);
            }
        }
    }
    let media_type = response
        .get("mediaType")
        .and_then(Value::as_str)
        .unwrap_or("movie");
    let (sidecar_path, sidecar_format) = item_sidecar_path(&item, media_type);
    let consumer_effective = !matches!(item.media_kind.as_str(), "book" | "podcast");
    let root = state.config.resolve_visible_root(&identity, &item.root_id);
    let (sidecar, sidecar_observation) = root
        .as_ref()
        .map(|root| {
            inspect_sidecar(
                FilePath::new(&root.resolved_path),
                sidecar_path.clone(),
                sidecar_format,
                consumer_effective,
            )
        })
        .unwrap_or_else(|| {
            inspect_sidecar(
                FilePath::new("/nonexistent"),
                sidecar_path,
                sidecar_format,
                consumer_effective,
            )
        });
    if let Some(observation) = sidecar_observation {
        if consumer_effective {
            merge_metadata(
                &mut response,
                &observation.fields,
                "sidecar",
                &mut field_sources,
            );
        }
        observations.push(observation);
    }
    let sources = observations
        .iter()
        .map(|observation| observation.source.clone())
        .collect::<Vec<_>>();
    response["sources"] = json!(sources);
    response["observations"] = json!(observations);
    response["fieldSources"] = json!(field_sources);
    response["sidecar"] = json!(sidecar);
    let extension = item
        .relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    let mut consumers = consumer_effects(&state.config, &item.media_kind);
    if item.media_kind == "book" && matches!(extension.as_str(), "epub" | "cbz") {
        for consumer in &mut consumers {
            consumer.effect = "read-after-refresh".to_string();
            consumer.portable_write_supported = true;
            consumer.message =
                "Kavita reads the metadata embedded in this EPUB or CBZ after a library refresh."
                    .to_string();
        }
    }
    let application_available = consumers.iter().any(|consumer| consumer.available);
    response["consumers"] = json!(consumers);
    response["health"] = json!(health_issues(&item.media_kind, &response, &observations));
    response["modificationTargets"] = json!(modification_targets(
        &item.media_kind,
        &extension,
        application_available
    ));
    response["inspectionWarnings"] = json!(inspection_warnings);
    let mut result = Json(response).into_response();
    result.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    result
}

async fn folder_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<FolderMetadataQuery>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let folder = match visible_media_folder(&state.config, &identity, &query) {
        Ok(folder) => folder,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let folder_name = folder
        .relative_path
        .rsplit('/')
        .next()
        .unwrap_or(&folder.relative_path);
    let (title, year) = strip_trailing_year(folder_name);
    let media_type = folder_media_type(&folder);
    let mut response = json!({
        "mediaType": media_type,
        "title": title,
        "year": year,
        "series": null,
        "season": season_number_from_folder(&folder.relative_path),
        "episode": null,
        "episodeTitle": null,
        "description": null,
        "publisher": null,
        "language": null,
        "genres": [],
        "writers": [],
        "premiereDate": null,
        "runtimeMinutes": null,
        "officialRating": null,
        "communityRating": null,
        "providerIds": {},
        "videoStreams": [],
        "audioStreams": [],
        "subtitleStreams": [],
        "sources": ["folder"]
    });
    let mut observations = vec![MetadataObservation {
        source: "folder".to_string(),
        label: "Folder name".to_string(),
        observed_at: None,
        relative_path: Some(folder.relative_path.clone()),
        format: None,
        app_item_id: None,
        storage: "folder-name".to_string(),
        consumed_by: Vec::new(),
        survives_rescan: true,
        writable: false,
        locked: None,
        fields: crate::metadata::metadata_fields(&response),
        raw_preview: None,
    }];
    let mut field_sources = initial_field_sources(&response, "folder");
    let (sidecar_path, sidecar_format) = folder_sidecar_path(&folder.relative_path, media_type);
    let consumer_kind = match folder.category.as_str() {
        "videos" => "video",
        "music" => "music",
        "audiobooks" => "audiobook",
        "podcasts" => "podcast",
        "books" => "book",
        _ => "",
    };
    let consumer_effective = !matches!(consumer_kind, "book" | "podcast");
    let root = state
        .config
        .resolve_visible_root(&identity, &folder.root_id);
    let (sidecar, sidecar_observation) = root
        .as_ref()
        .map(|root| {
            inspect_sidecar(
                FilePath::new(&root.resolved_path),
                sidecar_path.clone(),
                sidecar_format,
                consumer_effective,
            )
        })
        .unwrap_or_else(|| {
            inspect_sidecar(
                FilePath::new("/nonexistent"),
                sidecar_path,
                sidecar_format,
                consumer_effective,
            )
        });
    if let Some(observation) = sidecar_observation {
        if consumer_effective {
            merge_metadata(
                &mut response,
                &observation.fields,
                "sidecar",
                &mut field_sources,
            );
        }
        observations.push(observation);
    }
    response["sources"] = json!(observations
        .iter()
        .map(|observation| observation.source.clone())
        .collect::<Vec<_>>());
    response["observations"] = json!(observations);
    response["fieldSources"] = json!(field_sources);
    response["sidecar"] = json!(sidecar);
    let consumers = consumer_effects(&state.config, consumer_kind);
    let application_available = consumers.iter().any(|consumer| consumer.available);
    response["consumers"] = json!(consumers);
    response["health"] = json!(health_issues(consumer_kind, &response, &observations));
    response["modificationTargets"] = json!(modification_targets(
        consumer_kind,
        "folder",
        application_available
    ));
    response["inspectionWarnings"] = json!([]);
    let mut result = Json(response).into_response();
    result.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    result
}

async fn preview_folder_metadata_sidecar(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<FolderMetadataQuery>,
    Json(request): Json<MetadataSidecarRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let folder = match visible_media_folder(&state.config, &identity, &query) {
        Ok(folder) => folder,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let expected_media_type = folder_media_type(&folder);
    if expected_media_type == "collection" {
        return ApiError::new(
            StatusCode::CONFLICT,
            "folder_sidecar_unsupported",
            "This folder groups other media folders and does not have a media sidecar of its own.",
            request_id,
        )
        .into_response();
    }
    if expected_media_type == "book" {
        return ApiError::new(
            StatusCode::CONFLICT,
            "embedded_book_metadata_required",
            "Kavita ignores external OPF sidecars. Edit the metadata embedded in the EPUB, comic archive, or PDF with a compatible tool.",
            request_id,
        )
        .into_response();
    }
    if let Err(error) = validate_metadata_request(&request) {
        return error.with_request_id(request_id).into_response();
    }
    if request.media_type.as_deref().unwrap_or(expected_media_type) != expected_media_type {
        return ApiError::new(
            StatusCode::CONFLICT,
            "metadata_type_mismatch",
            "The metadata type does not match the selected folder.",
            request_id,
        )
        .into_response();
    }
    let (destination_relative_path, extension, contents) =
        folder_metadata_sidecar(&folder, &request);
    let prepared = match prepare_metadata_action(
        &state.config,
        &identity,
        &folder.root_id,
        destination_relative_path,
        extension,
        &contents,
        &request_id,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => return error.into_response(),
    };
    let pseudo_item = CatalogItem {
        id: format!("folder:{}:{}", folder.root_id, folder.relative_path),
        root_id: folder.root_id,
        owner_username: None,
        relative_path: folder.relative_path,
        media_kind: folder.category,
        size_bytes: 0,
        modified_ns: 0,
        fingerprint: String::new(),
    };
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            return ApiError::internal(request_id).into_response();
        }
    };
    match create_metadata_plan(
        &state,
        &identity,
        &mut catalog,
        &pseudo_item,
        &request,
        prepared.action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            error.into_response()
        }
    }
}

async fn lookup_music_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<MusicLookupRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let mode = match LookupMode::parse(request.mode.as_deref()) {
        Some(mode) => mode,
        None => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "musicbrainz_mode_invalid",
                "Choose auto, fingerprint, or search lookup mode.",
                request_id,
            )
            .into_response()
        }
    };
    let artist = request
        .artist
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let mut title = request
        .title
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    for (label, value) in [("Artist", &artist), ("Title", &title)] {
        if value
            .as_ref()
            .is_some_and(|value| value.len() > 500 || value.contains('\0'))
        {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "musicbrainz_query_invalid",
                format!("{label} must contain between 1 and 500 characters."),
                request_id,
            )
            .into_response();
        }
    }
    if artist.is_none() && title.is_none() && mode == LookupMode::Search {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "musicbrainz_query_required",
            "An artist or title is required to search MusicBrainz.",
            request_id,
        )
        .into_response();
    }
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
        Ok(item) if item.media_kind == "music" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "music_item_required",
                "MusicBrainz lookup requires a cataloged music file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let client = match musicbrainz_client(&state.config, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let runtime_acoustid = state.config.provider_broker_base_url.is_some()
        && provider_account_configured(&state.config, &identity, "acoustid").await;
    if mode == LookupMode::Fingerprint && !client.has_fingerprint() && !runtime_acoustid {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "musicbrainz_lookup_unconfigured",
            "Configure your AcoustID account from Accounts to use fingerprint lookup.",
            request_id,
        )
        .into_response();
    }
    if title.is_none() {
        title = music_title_from_relative_path(&item.relative_path);
    }
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let root_path = root.resolved_path;
    let relative_path = item.relative_path.clone();
    let file_path = match tokio::task::spawn_blocking(move || {
        let file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
            .map_err(|error| error.to_string())?;
        drop(file);
        let path = FilePath::new(&root_path).join(&relative_path);
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|error| format!("stat media file: {error}"))?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return Err("media file is not a regular file".to_string());
        }
        Ok(path)
    })
    .await
    {
        Ok(Ok(path)) => path,
        Ok(Err(error)) => {
            log_event(
                "musicbrainz_file_unavailable",
                &request_id,
                json!({ "error": error, "itemId": item.id }),
            );
            return ApiError::new(
                StatusCode::CONFLICT,
                "music_file_unavailable",
                "The selected audio changed or can no longer be read safely. Scan the library again.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "musicbrainz_file_task_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item.id }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let lookup = if runtime_acoustid && mode != LookupMode::Search {
        match client.fingerprint_file(&file_path).await {
            Ok((fingerprint, duration)) => {
                match broker_acoustid_lookup(&state.config, &identity, &fingerprint, duration).await
                {
                    Ok(ids) if !ids.is_empty() => client.release_groups_from_ids(&ids).await,
                    Ok(_) if mode == LookupMode::Auto => {
                        client
                            .lookup_music(
                                &file_path,
                                artist.as_deref(),
                                title.as_deref(),
                                LookupMode::Search,
                            )
                            .await
                    }
                    Ok(_) => Ok(Vec::new()),
                    Err(_) if mode == LookupMode::Auto => {
                        client
                            .lookup_music(
                                &file_path,
                                artist.as_deref(),
                                title.as_deref(),
                                LookupMode::Search,
                            )
                            .await
                    }
                    Err(error) => {
                        log_event(
                            "acoustid_broker_lookup_failed",
                            &request_id,
                            json!({ "error": error, "itemId": item.id }),
                        );
                        return ApiError::new(
                            StatusCode::BAD_GATEWAY,
                            "acoustid_lookup_failed",
                            "AcoustID could not complete the fingerprint lookup.",
                            request_id,
                        )
                        .into_response();
                    }
                }
            }
            Err(error) => Err(error),
        }
    } else {
        client
            .lookup_music(&file_path, artist.as_deref(), title.as_deref(), mode)
            .await
    };
    let candidates = match lookup {
        Ok(candidates) => candidates,
        Err(error) => {
            log_event(
                "musicbrainz_lookup_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item.id }),
            );
            return ApiError::new(
                StatusCode::BAD_GATEWAY,
                "musicbrainz_lookup_failed",
                "MusicBrainz could not complete the metadata lookup.",
                request_id,
            )
            .into_response();
        }
    };
    Json(json!({
        "candidates": candidates,
        "requestId": request_id,
    }))
    .into_response()
}

async fn search_tmdb_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<TmdbSearchRequest>,
) -> Response {
    let request_id = request_id();
    let _identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };

    if request.query.trim().is_empty() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "tmdb_query_empty",
            "TMDB search requires a non-empty query.",
            request_id,
        )
        .into_response();
    }

    if request.query.len() > 500 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "tmdb_query_too_long",
            "Query must be 500 characters or less.",
            request_id,
        )
        .into_response();
    }

    let tmdb_client = match &state.tmdb_client {
        Some(client) => client,
        None => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "tmdb_unconfigured",
                "TMDB API key is not configured on this server. Set MEDIA_MANAGER_TMDB_API_KEY_FILE to enable TMDB search.",
                request_id,
            )
            .into_response();
        }
    };

    let media_type = request.media_type.as_deref().unwrap_or("auto");
    let year = request.year.filter(|y| *y > 1800 && *y <= 2100);

    let mut all_results = Vec::new();

    match media_type {
        "movie" | "auto" => match tmdb_client.search_movies(&request.query, year).await {
            Ok(movies) => {
                for movie in movies {
                    let release_year = movie
                        .release_date
                        .as_ref()
                        .and_then(|d| d.get(0..4))
                        .and_then(|y| y.parse::<u16>().ok());
                    let item = json!({
                        "mediaType": "movie",
                        "title": movie.title,
                        "year": release_year,
                        "overview": movie.overview,
                        "posterPath": movie.poster_path,
                        "backdropPath": movie.backdrop_path,
                        "voteAverage": movie.vote_average,
                        "voteCount": movie.vote_count,
                        "genres": movie.genre_ids,
                        "tmdbId": movie.id,
                    });
                    all_results.push(item);
                }
            }
            Err(error) => {
                log_event(
                    "tmdb_movie_search_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "query": request.query }),
                );
            }
        },
        "tv" => {}
        _ => {}
    }

    if media_type == "tv" || media_type == "auto" {
        match tmdb_client.search_tv_shows(&request.query, year).await {
            Ok(shows) => {
                for show in shows {
                    let first_air_year = show
                        .first_air_date
                        .as_ref()
                        .and_then(|d| d.get(0..4))
                        .and_then(|y| y.parse::<u16>().ok());
                    let item = json!({
                        "mediaType": "tv",
                        "title": show.name,
                        "year": first_air_year,
                        "overview": show.overview,
                        "posterPath": show.poster_path,
                        "backdropPath": show.backdrop_path,
                        "voteAverage": show.vote_average,
                        "voteCount": show.vote_count,
                        "genres": show.genre_ids,
                        "originCountry": show.origin_country,
                        "tmdbId": show.id,
                    });
                    all_results.push(item);
                }
            }
            Err(error) => {
                log_event(
                    "tmdb_tv_search_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "query": request.query }),
                );
            }
        }
    }

    all_results.sort_by(|a, b| {
        let a_pop = a.get("voteCount").and_then(|v| v.as_u64()).unwrap_or(0);
        let b_pop = b.get("voteCount").and_then(|v| v.as_u64()).unwrap_or(0);
        b_pop.cmp(&a_pop)
    });

    Json(json!({
        "results": all_results,
        "query": request.query,
        "year": year,
        "mediaType": media_type,
        "requestId": request_id,
    }))
    .into_response()
}

async fn get_tmdb_details(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<TmdbDetailsRequest>,
) -> Response {
    let request_id = request_id();
    let _identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };

    let tmdb_client = match &state.tmdb_client {
        Some(client) => client,
        None => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "tmdb_unconfigured",
                "TMDB API key is not configured on this server. Set MEDIA_MANAGER_TMDB_API_KEY_FILE to enable TMDB search.",
                request_id,
            )
            .into_response();
        }
    };

    let result = match request.media_type.as_str() {
        "movie" => match tmdb_client.get_movie_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "movie",
                "tmdbId": details.id,
                "title": details.title,
                "originalTitle": details.original_title,
                "overview": details.overview,
                "releaseDate": details.release_date,
                "year": details.release_date.as_ref().and_then(|d| d.get(0..4)).and_then(|y| y.parse::<u16>().ok()),
                "runtimeMinutes": details.runtime,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|g| g.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|l| l.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "tagline": details.tagline,
                "cast": details.credits.as_ref().map(|c| c.cast.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "character": m.character,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|c| c.crew.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "job": m.job,
                    "department": m.department,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|k| k.keywords.iter().map(|kw| kw.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|e| json!({
                    "imdbId": e.imdb_id,
                    "wikidataId": e.wikidata_id,
                })).unwrap_or_default(),
            }),
            Err(error) => {
                log_event(
                    "tmdb_movie_details_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "tmdbId": request.tmdb_id }),
                );
                return ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "tmdb_details_failed",
                    "TMDB could not fetch movie details.",
                    request_id,
                )
                .into_response();
            }
        },
        "tv" => match tmdb_client.get_tv_show_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "tv",
                "tmdbId": details.id,
                "title": details.name,
                "originalTitle": details.original_name,
                "overview": details.overview,
                "firstAirDate": details.first_air_date,
                "lastAirDate": details.last_air_date,
                "year": details.first_air_date.as_ref().and_then(|d| d.get(0..4)).and_then(|y| y.parse::<u16>().ok()),
                "numberOfSeasons": details.number_of_seasons,
                "numberOfEpisodes": details.number_of_episodes,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|g| g.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|l| l.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "type": details.show_type,
                "inProduction": details.in_production,
                "episodeRunTime": details.episode_run_time,
                "cast": details.credits.as_ref().map(|c| c.cast.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "character": m.character,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|c| c.crew.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "job": m.job,
                    "department": m.department,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|k| k.keywords.iter().map(|kw| kw.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|e| json!({
                    "imdbId": e.imdb_id,
                    "wikidataId": e.wikidata_id,
                })).unwrap_or_default(),
            }),
            Err(error) => {
                log_event(
                    "tmdb_tv_details_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "tmdbId": request.tmdb_id }),
                );
                return ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "tmdb_details_failed",
                    "TMDB could not fetch TV show details.",
                    request_id,
                )
                .into_response();
            }
        },
        _ => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "tmdb_media_type_invalid",
                "mediaType must be 'movie' or 'tv'.",
                request_id,
            )
            .into_response();
        }
    };

    Json(json!({
        "details": result,
        "requestId": request_id,
    }))
    .into_response()
}

fn music_title_from_relative_path(relative_path: &str) -> Option<String> {
    let filename = relative_path
        .rsplit_once('/')
        .map(|(_, filename)| filename)
        .unwrap_or(relative_path);
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let stem = stem.trim();
    (!stem.is_empty() && stem.len() <= 500).then(|| stem.to_string())
}

fn filename_metadata(item: &CatalogItem) -> Value {
    let filename = item
        .relative_path
        .rsplit('/')
        .next()
        .unwrap_or(&item.relative_path);
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let mut title = stem.to_string();
    let mut year = Value::Null;
    let mut media_type = match item.media_kind.as_str() {
        "music" => "music",
        "audiobook" => "audiobook",
        "podcast" => "podcast",
        "book" => "book",
        _ => "movie",
    };
    let mut series = Value::Null;
    let mut season = Value::Null;
    let mut episode = Value::Null;
    let mut episode_title = Value::Null;
    if item.media_kind == "video" {
        if let Some((marker_start, marker_end)) = split_episode_marker(stem) {
            media_type = "episode";
            let marker = &stem[marker_start..marker_end];
            let digits = marker.trim_start_matches(['S', 's']);
            if let Some((season_text, episode_text)) = digits.split_once(['E', 'e']) {
                season = season_text
                    .parse::<u32>()
                    .map(Value::from)
                    .unwrap_or(Value::Null);
                episode = episode_text
                    .parse::<u32>()
                    .map(Value::from)
                    .unwrap_or(Value::Null);
            }
            let prefix = stem[..marker_start].trim().trim_end_matches('-').trim();
            let suffix_title = stem[marker_end..].trim().trim_start_matches('-').trim();
            let (series_title, parsed_year) = strip_trailing_year(prefix);
            series = Value::String(series_title.to_string());
            title = if suffix_title.is_empty() {
                series_title.to_string()
            } else {
                suffix_title.to_string()
            };
            episode_title = Value::String(title.clone());
            year = parsed_year.map(Value::from).unwrap_or(Value::Null);
        } else {
            let (parsed_title, parsed_year) = strip_trailing_year(stem);
            title = parsed_title.to_string();
            year = parsed_year.map(Value::from).unwrap_or(Value::Null);
        }
    }
    json!({
        "mediaType": media_type, "title": title, "year": year, "series": series,
        "season": season, "episode": episode, "episodeTitle": episode_title,
        "description": null, "publisher": null, "language": null, "genres": [],
        "writers": [], "premiereDate": null, "runtimeMinutes": null,
        "officialRating": null, "communityRating": null, "providerIds": {},
        "videoStreams": [], "audioStreams": [], "subtitleStreams": [],
        "sources": ["filename"]
    })
}

fn split_episode_marker(stem: &str) -> Option<(usize, usize)> {
    let bytes = stem.as_bytes();
    for index in 0..bytes.len() {
        if !matches!(bytes[index], b'S' | b's') {
            continue;
        }
        let season_start = index + 1;
        let mut cursor = season_start;
        while cursor < bytes.len() && bytes[cursor].is_ascii_digit() && cursor - season_start < 3 {
            cursor += 1;
        }
        if cursor == season_start || cursor >= bytes.len() || !matches!(bytes[cursor], b'E' | b'e')
        {
            continue;
        }
        cursor += 1;
        let episode_start = cursor;
        while cursor < bytes.len() && bytes[cursor].is_ascii_digit() && cursor - episode_start < 4 {
            cursor += 1;
        }
        if cursor > episode_start {
            return Some((index, cursor));
        }
    }
    None
}

fn strip_trailing_year(value: &str) -> (&str, Option<u16>) {
    if value.len() >= 7 && value.ends_with(')') {
        let start = value.len() - 6;
        if value.as_bytes().get(start) == Some(&b'(') {
            if let Ok(year) = value[start + 1..value.len() - 1].parse::<u16>() {
                return (value[..start].trim(), Some(year));
            }
        }
    }
    (value.trim(), None)
}

async fn cached_application_metadata(
    cache_file: &FilePath,
    item: &CatalogItem,
    allow_folder_prefix: bool,
) -> Option<Value> {
    const MAX_CACHE_BYTES: u64 = 16 * 1024 * 1024;
    const MAX_CACHE_AGE_SECONDS: u64 = 2 * 60 * 60;
    let metadata = tokio::fs::symlink_metadata(cache_file).await.ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES
    {
        return None;
    }
    if SystemTime::now()
        .duration_since(metadata.modified().ok()?)
        .ok()?
        .as_secs()
        > MAX_CACHE_AGE_SECONDS
    {
        return None;
    }
    let bytes = tokio::fs::read(cache_file).await.ok()?;
    let cache: Value = serde_json::from_slice(&bytes).ok()?;
    if cache.get("schemaVersion")?.as_u64()? != 1 {
        return None;
    }
    cache
        .get("entries")?
        .as_array()?
        .iter()
        .filter(|entry| {
            entry.get("rootId").and_then(Value::as_str) == Some(item.root_id.as_str())
                && entry.get("ownerUsername").and_then(Value::as_str)
                    == item.owner_username.as_deref()
        })
        .filter(|entry| {
            let Some(relative_path) = entry.get("relativePath").and_then(Value::as_str) else {
                return false;
            };
            relative_path == item.relative_path
                || (allow_folder_prefix
                    && !relative_path.is_empty()
                    && item
                        .relative_path
                        .strip_prefix(relative_path)
                        .is_some_and(|suffix| suffix.starts_with('/')))
        })
        .max_by_key(|entry| {
            entry
                .get("relativePath")
                .and_then(Value::as_str)
                .map(str::len)
                .unwrap_or_default()
        })
        .cloned()
}

fn merge_metadata(
    base: &mut Value,
    entry: &Value,
    source: &str,
    field_sources: &mut std::collections::BTreeMap<String, String>,
) {
    let Some(base) = base.as_object_mut() else {
        return;
    };
    let Some(entry) = entry.as_object() else {
        return;
    };
    const FIELDS: &[&str] = &[
        "mediaType",
        "title",
        "subtitle",
        "year",
        "authors",
        "narrators",
        "series",
        "volumeNumber",
        "isbn",
        "season",
        "episode",
        "episodeTitle",
        "description",
        "publisher",
        "language",
        "genres",
        "writers",
        "premiereDate",
        "runtimeMinutes",
        "officialRating",
        "communityRating",
        "providerIds",
        "trackNumber",
        "trackTotal",
        "discNumber",
        "discTotal",
        "tags",
        "chapters",
        "audioFiles",
        "ebookFile",
        "publishedDate",
        "explicit",
        "ageRating",
        "publicationStatus",
        "fieldLocks",
        "videoStreams",
        "audioStreams",
        "subtitleStreams",
    ];
    for field in FIELDS {
        if let Some(value) = entry.get(*field).filter(|value| !value.is_null()) {
            base.insert((*field).to_string(), value.clone());
            field_sources.insert((*field).to_string(), source.to_string());
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
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let mut integrations = state.config.integrations.clone();
    let runtime_accounts = if state.config.provider_broker_base_url.is_some() {
        configured_provider_accounts(&state.config, &identity).await
    } else {
        BTreeSet::new()
    };
    integrations.push(crate::config::IntegrationCapability {
        id: "mkvmaker".to_string(),
        label: "DVD ISO converter".to_string(),
        available: state.config.mkvmaker_progress_file.is_file(),
        capabilities: vec!["conversion-progress".to_string()],
    });
    let opensubtitles_available = match state.config.provider_broker_base_url.as_deref() {
        Some(_) => runtime_accounts.contains("opensubtitles"),
        None => state
            .config
            .open_subtitles_credentials_file
            .as_ref()
            .is_some_and(|path| path.is_file()),
    };
    integrations.push(crate::config::IntegrationCapability {
        id: "opensubtitles".to_string(),
        label: "OpenSubtitles".to_string(),
        available: opensubtitles_available,
        capabilities: vec![
            "subtitle-search".to_string(),
            "subtitle-download".to_string(),
        ],
    });
    let mut musicbrainz_capabilities = vec!["musicbrainz-lookup".to_string()];
    let acoustid_available = match state.config.provider_broker_base_url.as_deref() {
        Some(_) => runtime_accounts.contains("acoustid"),
        None => state
            .config
            .acoustid_api_key_file
            .as_ref()
            .is_some_and(|path| path.is_file()),
    };
    if acoustid_available {
        musicbrainz_capabilities.push("musicbrainz-fingerprint".to_string());
    }
    integrations.push(crate::config::IntegrationCapability {
        id: "musicbrainz".to_string(),
        label: "MusicBrainz Picard".to_string(),
        available: true,
        capabilities: musicbrainz_capabilities,
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

async fn provider_account_configured(
    config: &AppConfig,
    identity: &Identity,
    provider_id: &str,
) -> bool {
    configured_provider_accounts(config, identity)
        .await
        .contains(provider_id)
}

async fn configured_provider_accounts(config: &AppConfig, identity: &Identity) -> BTreeSet<String> {
    let Some(base) = config.provider_broker_base_url.as_deref() else {
        return BTreeSet::new();
    };
    let Ok(mut url) = reqwest::Url::parse(base) else {
        return BTreeSet::new();
    };
    if url.scheme() != "http"
        || !url
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"))
    {
        return BTreeSet::new();
    }
    if !url.path().ends_with('/') {
        url.set_path(&format!("{}/", url.path()));
    }
    let Ok(url) = url.join("api/v1/provider-accounts") else {
        return BTreeSet::new();
    };
    let Ok(client) = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    else {
        return BTreeSet::new();
    };
    let Ok(response) = client
        .get(url)
        .header("x-forwarded-user", &identity.subject)
        .header("x-forwarded-preferred-username", &identity.username)
        .header("x-forwarded-groups", identity.groups.join(","))
        .send()
        .await
    else {
        return BTreeSet::new();
    };
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > 1024 * 1024)
    {
        return BTreeSet::new();
    }
    let Ok(bytes) = response.bytes().await else {
        return BTreeSet::new();
    };
    if bytes.len() > 1024 * 1024 {
        return BTreeSet::new();
    }
    serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|payload| payload.get("providers").and_then(Value::as_array).cloned())
        .map(|providers| {
            providers
                .into_iter()
                .filter(|provider| {
                    provider.pointer("/account/state").and_then(Value::as_str) == Some("configured")
                })
                .filter_map(|provider| {
                    provider
                        .get("id")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default()
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
    let scan_root_spec = ScanRoot {
        id: root.id.clone(),
        owner_username: owner.map(str::to_string),
        path: root.resolved_path.clone().into(),
        category: root.category.clone(),
    };
    let catalog_handle = state.catalog.clone();
    match tokio::task::spawn_blocking(move || rescan_root(&catalog_handle, &scan_root_spec)).await {
        Ok(Ok(result)) => {
            log_event(
                "catalog_root_reconciled",
                &request_id,
                json!({
                    "rootId": root.id,
                    "ownerUsername": owner,
                    "result": result,
                }),
            );
        }
        Ok(Err(error)) => {
            log_event(
                "catalog_auto_scan_failed",
                &request_id,
                json!({ "rootId": root.id, "error": error }),
            );
            return ApiError::new(
                StatusCode::BAD_GATEWAY,
                "scan_failed",
                "The selected media root could not be cataloged.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "catalog_auto_scan_task_failed",
                &request_id,
                json!({ "rootId": root.id, "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    }

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
    let items = match catalog.list_items(&root.id, owner, 200) {
        Ok(items) => items,
        Err(error) => {
            log_event(
                "catalog_query_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let root_path = FilePath::new(&root.resolved_path);
    let mut live_items = Vec::with_capacity(items.len());
    let mut stale_ids = Vec::new();
    for item in items {
        if root_path.join(&item.relative_path).exists() {
            live_items.push(item);
        } else {
            stale_ids.push(item.id);
        }
    }
    if !stale_ids.is_empty() {
        let count = stale_ids.len();
        if let Err(error) = catalog.remove_items(&stale_ids) {
            log_event(
                "catalog_prune_failed",
                &request_id,
                json!({ "rootId": root.id, "staleCount": count, "error": error.to_string() }),
            );
        } else {
            log_event(
                "catalog_items_pruned",
                &request_id,
                json!({ "rootId": root.id, "prunedCount": count }),
            );
        }
    }
    if query.include_video_probes {
        return items_with_video_probes(&state, &root, live_items, &request_id).await;
    }
    Json(json!({ "items": live_items, "nextCursor": null })).into_response()
}

async fn items_with_video_probes(
    state: &AppState,
    root: &VisibleRoot,
    items: Vec<CatalogItem>,
    request_id: &str,
) -> Response {
    let Some(ffprobe) = state.config.ffprobe_path.clone() else {
        return Json(json!({
            "items": items,
            "nextCursor": null,
            "probePending": false,
        }))
        .into_response();
    };
    let state_dir = state.config.state_dir.clone();
    let root_id = root.id.clone();
    let root_path = root.resolved_path.clone();
    let videos = items
        .iter()
        .filter(|item| item.media_kind == "video")
        .map(|item| (item.relative_path.clone(), item.fingerprint.clone()))
        .collect::<Vec<_>>();
    let videos_for_probe = videos.clone();
    let (cache, probe_error) = match tokio::task::spawn_blocking(move || {
        let mut cache = VideoProbeCache::open(&state_dir, &root_id);
        let error = refresh_root_probes(
            FilePath::new(&ffprobe),
            FilePath::new(&root_path),
            &mut cache,
            &videos_for_probe,
        )
        .err()
        .map(|error| format!("refresh video probes: {error}"));
        (cache, error)
    })
    .await
    {
        Ok(result) => result,
        Err(error) => {
            log_event(
                "video_probe_task_failed",
                request_id,
                json!({ "error": error.to_string(), "rootId": root.id }),
            );
            return ApiError::internal(request_id.to_string()).into_response();
        }
    };
    if let Some(error) = probe_error {
        log_event(
            "video_probe_refresh_failed",
            request_id,
            json!({ "error": error, "rootId": root.id }),
        );
    }
    let probe_pending = videos
        .iter()
        .any(|(path, fingerprint)| !cache.has_probe(path, fingerprint));
    let items = items
        .into_iter()
        .map(|item| {
            let mut value =
                serde_json::to_value(&item).unwrap_or_else(|_| json!({ "id": item.id }));
            if item.media_kind == "video" {
                value["videoProbe"] = cache
                    .probe_for(&item.relative_path, &item.fingerprint)
                    .and_then(|probe| serde_json::to_value(probe).ok())
                    .unwrap_or(Value::Null);
            }
            value
        })
        .collect::<Vec<_>>();
    Json(json!({
        "items": items,
        "nextCursor": null,
        "probePending": probe_pending,
    }))
    .into_response()
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

async fn conversions_inbox(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    let inbox = state.config.dvd_inbox_path();
    if !inbox.is_dir() {
        return Json(json!({
            "available": false,
            "pending": [],
            "processed": [],
            "failed": [],
            "requestId": request_id,
        }))
        .into_response();
    }
    let mut groups = Vec::with_capacity(3);
    let shared_root = state.config.shared_root.clone();
    for (key, directory) in [
        ("pending", inbox.clone()),
        ("processed", inbox.join("_Processed")),
        ("failed", inbox.join("_Failed")),
    ] {
        match list_iso_directory(&directory, key, &shared_root, &request_id).await {
            Ok(entries) => groups.push((key, entries)),
            Err(error) => {
                log_event(
                    "iso_inbox_read_failed",
                    &request_id,
                    json!({ "directory": key, "error": error }),
                );
                return ApiError::internal(request_id).into_response();
            }
        }
    }
    let mut body = json!({
        "available": true,
        "pending": groups[0].1,
        "processed": groups[1].1,
        "failed": groups[2].1,
        "requestId": request_id,
    });
    if let Some(ref base_url) = state.config.files_base_url {
        body["filesBaseUrl"] = json!(base_url);
    }
    Json(body).into_response()
}

async fn list_iso_directory(
    directory: &FilePath,
    context: &str,
    shared_root: &FilePath,
    request_id: &str,
) -> Result<Vec<Value>, String> {
    let mut entries = Vec::new();
    let mut read_dir = match tokio::fs::read_dir(directory).await {
        Ok(read_dir) => read_dir,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(entries),
        Err(error) => return Err(error.to_string()),
    };
    while let Some(entry) = read_dir
        .next_entry()
        .await
        .map_err(|error| error.to_string())?
    {
        let file_type = entry.file_type().await.map_err(|error| error.to_string())?;
        if !file_type.is_file() || file_type.is_symlink() {
            continue;
        }
        let name = match entry.file_name().into_string() {
            Ok(name)
                if name.len() <= 255
                    && !name.contains('/')
                    && name.to_ascii_lowercase().ends_with(".iso") =>
            {
                name
            }
            _ => continue,
        };
        let metadata = entry.metadata().await.map_err(|error| error.to_string())?;
        let modified_ns = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
            .unwrap_or(0);
        let volume_id = iso_volume_id(&entry.path(), request_id).await;
        let mut iso_entry = json!({
            "name": name,
            "volumeId": volume_id,
            "sizeBytes": metadata.len().min(i64::MAX as u64) as i64,
            "modifiedNs": modified_ns,
        });
        match context {
            "processed" => {
                let manifest_path = entry.path().with_extension("iso.output.json");
                if let Ok(content) = tokio::fs::read_to_string(&manifest_path).await {
                    if let Ok(manifest) = serde_json::from_str::<Value>(&content) {
                        let output_dir = manifest["outputDir"].as_str().unwrap_or_default();
                        let relative = output_dir
                            .strip_prefix(shared_root.to_string_lossy().as_ref())
                            .unwrap_or(output_dir)
                            .trim_start_matches('/');
                        iso_entry["outputDir"] = json!(relative);
                    }
                }
            }
            "failed" => {
                let error_path = entry.path().with_extension("iso.error.txt");
                if error_path.exists() {
                    iso_entry["hasErrorLog"] = json!(true);
                }
            }
            _ => {}
        }
        entries.push(iso_entry);
        if entries.len() >= MAX_INBOX_ENTRIES {
            break;
        }
    }
    entries.sort_by(|left, right| {
        left["name"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["name"].as_str().unwrap_or_default())
    });
    Ok(entries)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InboxErrorQuery {
    name: String,
}

async fn conversions_inbox_error(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<InboxErrorQuery>,
) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    if query.name.contains('/') || query.name.contains("..") || query.name.is_empty() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_name",
            "The file name is not valid.",
            request_id,
        )
        .into_response();
    }
    let error_path = state
        .config
        .dvd_inbox_path()
        .join("_Failed")
        .join(&query.name)
        .with_extension("iso.error.txt");
    if !error_path.exists() {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "error_log_missing",
            "No error log was found.",
            request_id,
        )
        .into_response();
    }
    match tokio::fs::read_to_string(&error_path).await {
        Ok(content) => Json(json!({ "content": content, "requestId": request_id })).into_response(),
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

async fn iso_volume_id(path: &FilePath, request_id: &str) -> Option<String> {
    const SECTOR_SIZE: u64 = 2048;
    const PRIMARY_VOLUME_SECTOR: u64 = 16;
    let mut file = tokio::fs::File::open(path).await.ok()?;
    if file.metadata().await.ok()?.len() < (PRIMARY_VOLUME_SECTOR + 1) * SECTOR_SIZE {
        return None;
    }
    file.seek(std::io::SeekFrom::Start(
        PRIMARY_VOLUME_SECTOR * SECTOR_SIZE,
    ))
    .await
    .ok()?;
    let mut sector = [0u8; SECTOR_SIZE as usize];
    file.read_exact(&mut sector).await.ok()?;
    if sector[0] != 1 || &sector[1..6] != b"CD001" || sector[6] != 1 {
        return None;
    }
    let volume_id: String = sector[40..72]
        .iter()
        .map(|byte| {
            if byte.is_ascii_graphic() || *byte == b' ' {
                *byte as char
            } else {
                ' '
            }
        })
        .collect::<String>()
        .trim()
        .to_string();
    if volume_id.is_empty() {
        log_event(
            "iso_volume_id_missing",
            request_id,
            json!({ "path": path.display().to_string() }),
        );
        return None;
    }
    Some(volume_id)
}

async fn read_jellyfin_api_key(api_key_file: &FilePath) -> Option<String> {
    let bytes = tokio::fs::read(api_key_file).await.ok()?;
    let key = String::from_utf8_lossy(&bytes).trim().to_string();
    if key.is_empty() || key.len() > 512 {
        return None;
    }
    if !key
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'~' | b'-'))
    {
        return None;
    }
    Some(key)
}

fn valid_jellyfin_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn valid_image_tag(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

fn try_image_tag_from_tags<'a>(image_tags: &'a Value, image_type: &str) -> Option<&'a str> {
    image_tags
        .get(image_type)
        .or_else(|| {
            let mut lower = image_type.to_string();
            lower[..1].make_ascii_lowercase();
            image_tags.get(&lower)
        })
        .and_then(Value::as_str)
}

async fn fetch_jellyfin_image(
    state: &Arc<AppState>,
    base_url: &str,
    api_key: &str,
    jellyfin_item_id: &str,
    image_type: &str,
    image_tag: &str,
) -> Option<Response> {
    let cache_key = format!("{}:{}:{}", jellyfin_item_id, image_type, image_tag);
    if let Some((cached_data, cached_ct)) = state.jellyfin_image_cache.get(&cache_key) {
        return Some(
            (
                StatusCode::OK,
                [
                    (CONTENT_TYPE, cached_ct),
                    (CACHE_CONTROL, "private, max-age=300".to_string()),
                ],
                cached_data,
            )
                .into_response(),
        );
    }
    let url = format!(
        "{}/Items/{}/Images/{}?tag={}",
        base_url.trim_end_matches('/'),
        jellyfin_item_id,
        image_type,
        image_tag
    );
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .build()
        .ok()?;
    let response = client
        .get(&url)
        .header("X-Emby-Token", api_key)
        .send()
        .await
        .ok()?;
    if response.status() != StatusCode::OK {
        return None;
    }
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .filter(|v| {
            let lower = v.to_lowercase();
            lower.starts_with("image/") && lower.len() < 128
        })
        .unwrap_or("image/jpeg")
        .to_string();
    let data = response.bytes().await.ok()?;
    if data.len() > 32 * 1024 * 1024 {
        return None;
    }
    state
        .jellyfin_image_cache
        .insert(cache_key, data.to_vec(), content_type.clone());
    Some(
        (
            StatusCode::OK,
            [
                (CONTENT_TYPE, content_type),
                (CACHE_CONTROL, "private, max-age=300".to_string()),
            ],
            data,
        )
            .into_response(),
    )
}

async fn try_jellyfin_image_fallback(
    state: &Arc<AppState>,
    item: &CatalogItem,
    request_id: &str,
) -> Option<Response> {
    let Some(cache_file) = &state.config.jellyfin_metadata_cache_file else {
        log_event(
            "jellyfin_fallback_no_cache_config",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    };
    let Some(base_url) = &state.config.jellyfin_base_url else {
        log_event(
            "jellyfin_fallback_no_base_url",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    };
    let Some(api_key_file) = &state.config.jellyfin_api_key_file else {
        log_event(
            "jellyfin_fallback_no_api_key_file",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    };
    let Some(api_key) = read_jellyfin_api_key(api_key_file).await else {
        log_event(
            "jellyfin_fallback_api_key_read_failed",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    };
    let Some(entry) = cached_application_metadata(cache_file, item, false).await else {
        log_event(
            "jellyfin_fallback_cache_miss",
            request_id,
            json!({
                "itemId": item.id,
                "rootId": item.root_id,
                "relativePath": item.relative_path,
                "ownerUsername": item.owner_username,
            }),
        );
        return None;
    };
    let Some(jellyfin_item_id) = entry.get("itemId").and_then(Value::as_str) else {
        log_event(
            "jellyfin_fallback_no_jellyfin_id",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    };
    if !valid_jellyfin_id(jellyfin_item_id) {
        log_event(
            "jellyfin_fallback_invalid_id",
            request_id,
            json!({ "itemId": item.id }),
        );
        return None;
    }
    let Some(image_tags) = entry.get("imageTags") else {
        log_event(
            "jellyfin_fallback_no_image_tags",
            request_id,
            json!({ "itemId": item.id, "jellyfinItemId": jellyfin_item_id }),
        );
        return None;
    };
    let image_types = ["Primary", "Backdrop", "Banner", "Logo", "Thumb"];
    for image_type in image_types {
        let Some(image_tag) = try_image_tag_from_tags(image_tags, image_type) else {
            continue;
        };
        if !valid_image_tag(image_tag) {
            continue;
        }
        if let Some(response) = fetch_jellyfin_image(
            state,
            base_url,
            &api_key,
            jellyfin_item_id,
            image_type,
            image_tag,
        )
        .await
        {
            return Some(response);
        }
    }
    log_event(
        "jellyfin_fallback_no_image",
        request_id,
        json!({
            "itemId": item.id,
            "jellyfinItemId": jellyfin_item_id,
            "availableTags": image_tags,
        }),
    );
    None
}

async fn item_image(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
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
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let artwork = if item.media_kind == "artwork" {
        Some(item.clone())
    } else {
        let owner = item.owner_username.as_deref();
        let artwork_items = match catalog.list_artwork(&item.root_id, owner) {
            Ok(items) => items,
            Err(error) => {
                log_event(
                    "catalog_query_failed",
                    &request_id,
                    json!({ "error": error.to_string() }),
                );
                return ApiError::internal(request_id).into_response();
            }
        };
        preferred_artwork(&artwork_items, &item.relative_path)
    };
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let root_path = root.resolved_path.clone();
    let artwork_path = artwork.map(|candidate| candidate.relative_path);
    let item_path = item.relative_path.clone();
    let item_kind = item.media_kind.clone();
    let item_id_for_logs = item.id.clone();
    let item_dir = item_path
        .rsplit_once('/')
        .map(|(parent, _)| parent)
        .unwrap_or("");
    let siblings = if artwork_path.is_none() && is_embedded_artwork_capable(&item_kind) {
        match catalog.list_media_in_directory(
            &item.root_id,
            item.owner_username.as_deref(),
            item_dir,
        ) {
            Ok(items) => items
                .into_iter()
                .filter(|sibling| sibling.relative_path != item_path)
                .filter(|sibling| is_embedded_artwork_capable(&sibling.media_kind))
                .map(|sibling| sibling.relative_path)
                .collect::<Vec<_>>(),
            Err(error) => {
                log_event(
                    "sibling_media_query_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "itemId": item_id_for_logs }),
                );
                Vec::new()
            }
        }
    } else {
        Vec::new()
    };
    let body = match tokio::task::spawn_blocking(move || {
        if let Some(relative_path) = artwork_path {
            return read_artwork_file(FilePath::new(&root_path), &relative_path).map(Some);
        }
        if let Ok(Some(body)) = read_embedded_artwork(FilePath::new(&root_path), &item_path) {
            return Ok(Some(body));
        }
        for sibling_path in &siblings {
            if let Ok(Some(body)) = read_embedded_artwork(FilePath::new(&root_path), sibling_path) {
                return Ok(Some(body));
            }
        }
        Ok::<Option<ArtworkBody>, String>(None)
    })
    .await
    {
        Ok(Ok(Some(body))) => body,
        Ok(Ok(None)) => {
            if let Some(jellyfin_response) =
                try_jellyfin_image_fallback(&state, &item, &request_id).await
            {
                return jellyfin_response;
            }
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "artwork_not_found",
                "No nearby or embedded cover artwork was found for this item.",
                request_id,
            )
            .into_response();
        }
        Ok(Err(error)) => {
            log_event(
                "artwork_read_failed",
                &request_id,
                json!({ "error": error, "itemId": item_id }),
            );
            if let Some(jellyfin_response) =
                try_jellyfin_image_fallback(&state, &item, &request_id).await
            {
                return jellyfin_response;
            }
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "artwork_not_found",
                "Artwork for this item can no longer be read safely.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "artwork_read_task_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item_id }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    (
        StatusCode::OK,
        [
            (CONTENT_TYPE, body.content_type),
            (CACHE_CONTROL, "private, max-age=300".to_string()),
        ],
        body.bytes,
    )
        .into_response()
}

async fn preview_artwork_replacement(
    State(state): State<Arc<AppState>>,
    Path(item_id): Path<String>,
    Query(query): Query<ArtworkReplacementQuery>,
    request: Request,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, request.headers(), &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "artwork" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "artwork_item_required",
                "Cover replacement requires a cataloged image file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    drop(catalog);
    let body = match to_bytes(request.into_body(), MAX_ARTWORK_UPLOAD_BYTES).await {
        Ok(body) => body,
        Err(_) => {
            return ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "artwork_size_invalid",
                "Cover artwork must be no larger than 32 MiB.",
                request_id,
            )
            .into_response()
        }
    };
    let upload_format = query.format;
    let validation_body = body.clone();
    let extension = match tokio::task::spawn_blocking(move || {
        validate_artwork_upload(&upload_format, &validation_body)
    })
    .await
    {
        Ok(Ok(extension)) => extension,
        Ok(Err(error)) => return error.with_request_id(request_id).into_response(),
        Err(error) => {
            log_event(
                "artwork_validation_task_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let (parent, filename) = item
        .relative_path
        .rsplit_once('/')
        .unwrap_or(("", &item.relative_path));
    let (stem, original_extension) = filename.rsplit_once('.').unwrap_or((filename, "jpg"));
    let destination_relative_path = join_relative(parent, &format!("{stem}.{extension}"));
    let archived_relative_path = join_relative(
        parent,
        &format!("superseded/{stem}-{request_id}.{original_extension}"),
    );
    let staged = match stage_sidecar(&state.config, extension, &body, &request_id).await {
        Ok(staged) => staged,
        Err(error) => return error.into_response(),
    };
    let action = ReplaceArtworkAction {
        staging_filename: staged.filename,
        root_id: item.root_id.clone(),
        source_relative_path: item.relative_path.clone(),
        archived_relative_path: archived_relative_path.clone(),
        replacement_relative_path: destination_relative_path.clone(),
        expected_source: item.fingerprint.clone(),
        expected_replacement: staged.expected,
    };
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => {
            let _ = tokio::fs::remove_file(&staged.path).await;
            return ApiError::internal(request_id).into_response();
        }
    };
    match create_artwork_replacement_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(staged.path).await;
            error.into_response()
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
    let scan_result =
        tokio::task::spawn_blocking(move || rescan_root(&catalog_handle, &scan_root_spec)).await;
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

async fn plan_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(plan_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !valid_object_id(&plan_id) {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_plan_id",
            "The mutation plan ID is invalid.",
            request_id,
        )
        .into_response();
    }
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    match catalog.mutation_plan_status_for_owner(&plan_id, &identity.username) {
        Ok(Some(status)) => Json(json!({
            "id": plan_id,
            "state": status.state,
            "error": status.error,
            "requestId": request_id,
        }))
        .into_response(),
        Ok(None) => ApiError::new(
            StatusCode::NOT_FOUND,
            "plan_not_found",
            "The mutation plan does not exist for this identity.",
            request_id,
        )
        .into_response(),
        Err(_) => ApiError::internal(request_id).into_response(),
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
    Identity::try_from_forwarded_headers(headers).map_err(|_| {
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

struct VisibleMediaFolder {
    root_id: String,
    relative_path: String,
    category: String,
    has_direct_media: bool,
    has_season_directory: bool,
}

fn visible_media_folder(
    config: &AppConfig,
    identity: &Identity,
    query: &FolderMetadataQuery,
) -> Result<VisibleMediaFolder, ApiError> {
    if query.relative_path.is_empty() || query.relative_path.len() > 4096 {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "folder_path_invalid",
            "The selected folder path is invalid.",
        ));
    }
    let root = config
        .resolve_visible_root(identity, &query.root_id)
        .filter(|root| {
            ["videos", "music", "audiobooks", "podcasts", "books"].contains(&root.category.as_str())
        })
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::FORBIDDEN,
                "folder_not_visible",
                "The selected folder is outside the caller's visible media roots.",
            )
        })?;
    let directory =
        open_directory_beneath(FilePath::new(&root.resolved_path), &query.relative_path).map_err(
            |_| {
                ApiError::without_request_id(
                    StatusCode::CONFLICT,
                    "folder_missing",
                    "The selected folder is no longer present in the media library.",
                )
            },
        )?;
    let (has_direct_media, has_season_directory) = inspect_media_folder(&directory, &root.category)
        .map_err(|_| {
            ApiError::without_request_id(
                StatusCode::CONFLICT,
                "folder_missing",
                "The selected folder is no longer present in the media library.",
            )
        })?;
    Ok(VisibleMediaFolder {
        root_id: root.id,
        relative_path: query.relative_path.clone(),
        category: root.category,
        has_direct_media,
        has_season_directory,
    })
}

fn inspect_media_folder(
    directory: &std::fs::File,
    category: &str,
) -> std::io::Result<(bool, bool)> {
    let mut has_direct_media = false;
    let mut has_season_directory = false;
    let directory_path = format!("/proc/self/fd/{}", directory.as_raw_fd());
    for (index, entry) in std::fs::read_dir(directory_path)?.enumerate() {
        if index >= 10_000 {
            break;
        }
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            let name = entry.file_name();
            if season_number_from_name(&name.to_string_lossy()).is_some() {
                has_season_directory = true;
            }
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        let extension = entry
            .path()
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if scanned_media_kind(category, &extension)
            .is_some_and(|kind| !matches!(kind, "artwork" | "subtitle"))
        {
            has_direct_media = true;
        }
    }
    Ok((has_direct_media, has_season_directory))
}

fn folder_media_type(folder: &VisibleMediaFolder) -> &'static str {
    if season_number_from_folder(&folder.relative_path).is_some() {
        return "season";
    }
    match folder.category.as_str() {
        "videos" if folder.has_season_directory => "series",
        "videos" if folder.has_direct_media => "movie",
        "music" if folder.has_direct_media => "music",
        "audiobooks" if folder.has_direct_media => "audiobook",
        "podcasts" if folder.has_direct_media => "podcast",
        "books" if folder.has_direct_media => "book",
        _ => "collection",
    }
}

fn season_number_from_folder(relative_path: &str) -> Option<u32> {
    season_number_from_name(relative_path.rsplit('/').next()?)
}

fn season_number_from_name(name: &str) -> Option<u32> {
    if name.eq_ignore_ascii_case("specials") {
        return Some(0);
    }
    let (prefix, number) = name.trim().split_once(' ')?;
    if !prefix.eq_ignore_ascii_case("season") {
        return None;
    }
    number.trim().parse().ok()
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

enum SubtitleProviderClient {
    Broker {
        base: reqwest::Url,
        client: reqwest::Client,
        identity: Identity,
    },
    Legacy(OpenSubtitlesClient),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerSubtitleSearchResponse {
    match_method: String,
    results: Vec<SubtitleMatch>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerAcoustidResponse {
    release_group_ids: Vec<String>,
}

impl SubtitleProviderClient {
    async fn search_by_query(
        &self,
        query: &str,
        languages: &str,
    ) -> Result<Vec<SubtitleMatch>, String> {
        match self {
            Self::Legacy(client) => client
                .search_by_query(query, languages)
                .await
                .map_err(|error| error.to_string()),
            Self::Broker {
                base,
                client,
                identity,
            } => {
                let response = broker_provider_request(
                    base,
                    client,
                    identity,
                    "opensubtitles/search",
                    json!({ "query": query, "languages": languages }),
                )
                .await?;
                let payload = bounded_broker_json(response).await?;
                Ok(payload.results)
            }
        }
    }

    async fn search_by_hash(
        &self,
        movie_hash: &crate::subtitles::MovieHash,
        languages: &str,
    ) -> Result<Vec<SubtitleMatch>, String> {
        match self {
            Self::Legacy(client) => client
                .search_by_hash(movie_hash, languages)
                .await
                .map_err(|error| error.to_string()),
            Self::Broker {
                base,
                client,
                identity,
            } => {
                let response = broker_provider_request(
                    base,
                    client,
                    identity,
                    "opensubtitles/search",
                    json!({
                        "movieHash": movie_hash.value,
                        "movieByteSize": movie_hash.byte_size,
                        "query": "local movie hash",
                        "languages": languages,
                    }),
                )
                .await?;
                let payload = bounded_broker_json(response).await?;
                if payload.match_method != "movie-hash" {
                    return Ok(Vec::new());
                }
                Ok(payload.results)
            }
        }
    }

    async fn download(&self, file_id: i64) -> Result<Vec<u8>, String> {
        match self {
            Self::Legacy(client) => client
                .download(file_id)
                .await
                .map_err(|error| error.to_string()),
            Self::Broker {
                base,
                client,
                identity,
            } => {
                let mut response = broker_provider_request(
                    base,
                    client,
                    identity,
                    "opensubtitles/download",
                    json!({ "fileId": file_id }),
                )
                .await?;
                if response
                    .content_length()
                    .is_some_and(|length| length > MAX_SUBTITLE_BYTES as u64)
                {
                    return Err("provider subtitle exceeded the size limit".to_string());
                }
                let mut bytes = Vec::new();
                while let Some(chunk) = response
                    .chunk()
                    .await
                    .map_err(|_| "provider broker response could not be read safely".to_string())?
                {
                    if bytes.len().saturating_add(chunk.len()) > MAX_SUBTITLE_BYTES {
                        return Err("provider subtitle exceeded the size limit".to_string());
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(bytes)
            }
        }
    }
}

async fn broker_provider_request(
    base: &reqwest::Url,
    client: &reqwest::Client,
    identity: &Identity,
    operation: &str,
    body: Value,
) -> Result<reqwest::Response, String> {
    let url = base
        .join(&format!("api/v1/provider-lookups/{operation}"))
        .map_err(|_| "provider broker URL is invalid".to_string())?;
    let response = client
        .post(url)
        .header("x-forwarded-user", &identity.subject)
        .header("x-forwarded-preferred-username", &identity.username)
        .header("x-forwarded-groups", identity.groups.join(","))
        .json(&body)
        .send()
        .await
        .map_err(|_| "provider broker is unavailable".to_string())?;
    if response.status().is_success() {
        return Ok(response);
    }
    let message = match response.status() {
        reqwest::StatusCode::PRECONDITION_REQUIRED => "configure this provider from Accounts",
        reqwest::StatusCode::TOO_MANY_REQUESTS => "provider rate limit reached",
        _ => "provider broker rejected the operation",
    };
    Err(message.to_string())
}

async fn broker_acoustid_lookup(
    config: &AppConfig,
    identity: &Identity,
    fingerprint: &str,
    duration: u32,
) -> Result<Vec<String>, String> {
    let base = config
        .provider_broker_base_url
        .as_deref()
        .ok_or_else(|| "provider broker is unavailable".to_string())?;
    let mut base =
        reqwest::Url::parse(base).map_err(|_| "provider broker address is invalid".to_string())?;
    if base.scheme() != "http"
        || !base
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"))
    {
        return Err("provider broker address is not loopback".to_string());
    }
    if !base.path().ends_with('/') {
        base.set_path(&format!("{}/", base.path()));
    }
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(35))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "provider broker client could not be created".to_string())?;
    let response = broker_provider_request(
        &base,
        &client,
        identity,
        "acoustid/lookup",
        json!({ "fingerprint": fingerprint, "duration": duration }),
    )
    .await?;
    if response
        .content_length()
        .is_some_and(|length| length > 256 * 1024)
    {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| "provider broker response could not be read".to_string())?;
    if bytes.len() > 256 * 1024 {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    let payload = serde_json::from_slice::<BrokerAcoustidResponse>(&bytes)
        .map_err(|_| "provider broker returned an invalid response".to_string())?;
    Ok(payload.release_group_ids)
}

async fn bounded_broker_json(
    response: reqwest::Response,
) -> Result<BrokerSubtitleSearchResponse, String> {
    const MAX_BROKER_JSON_BYTES: usize = 2 * 1024 * 1024;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_BROKER_JSON_BYTES as u64)
    {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| "provider broker response could not be read".to_string())?;
    if bytes.len() > MAX_BROKER_JSON_BYTES {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    serde_json::from_slice(&bytes)
        .map_err(|_| "provider broker returned an invalid response".to_string())
}

fn open_subtitles_client(
    config: &AppConfig,
    identity: &Identity,
    request_id: &str,
) -> Result<SubtitleProviderClient, ApiError> {
    if let Some(base) = config.provider_broker_base_url.as_deref() {
        let mut base = reqwest::Url::parse(base).map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_broker_unavailable",
                "The provider broker address is invalid.",
                request_id.to_string(),
            )
        })?;
        let trusted_loopback = base.scheme() == "http"
            && base
                .host_str()
                .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"));
        if !trusted_loopback {
            return Err(ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_broker_unavailable",
                "The provider broker must use a loopback HTTP address.",
                request_id.to_string(),
            ));
        }
        if !base.path().ends_with('/') {
            base.set_path(&format!("{}/", base.path()));
        }
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(35))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| ApiError::internal(request_id.to_string()))?;
        return Ok(SubtitleProviderClient::Broker {
            base,
            client,
            identity: identity.clone(),
        });
    }
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
    OpenSubtitlesClient::new(credentials)
        .map(SubtitleProviderClient::Legacy)
        .map_err(|error| {
            log_event(
                "subtitle_provider_client_failed",
                request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.to_string())
        })
}

fn musicbrainz_client(config: &AppConfig, request_id: &str) -> Result<MusicBrainzClient, ApiError> {
    let acoustid_api_key = match config
        .acoustid_api_key_file
        .as_deref()
        .filter(|path| path.is_file())
    {
        Some(path) => match AcoustidCredentials::from_file(path) {
            Ok(credentials) => Some(credentials.acoustid_api_key),
            Err(error) => {
                log_event(
                    "musicbrainz_credentials_invalid",
                    request_id,
                    json!({ "error": error.to_string() }),
                );
                return Err(ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "musicbrainz_lookup_unconfigured",
                    "The AcoustID API key is not valid on this server.",
                    request_id.to_string(),
                ));
            }
        },
        None => None,
    };
    let fpcalc_path = config
        .fpcalc_path
        .clone()
        .unwrap_or_else(|| std::path::PathBuf::from("fpcalc"));
    let client_config = MusicBrainzClientConfig {
        acoustid_api_key,
        fpcalc_path,
        musicbrainz_api_base: config
            .musicbrainz_api_base
            .clone()
            .unwrap_or_else(|| MUSICBRAINZ_API_BASE.to_string()),
        acoustid_api_base: config
            .acoustid_api_base
            .clone()
            .unwrap_or_else(|| ACOUSTID_API_BASE.to_string()),
        request_gap: std::time::Duration::from_millis(config.musicbrainz_request_gap_ms),
        user_agent: "NixHomeServer Media Manager/0.1 (home server; music metadata lookup)"
            .to_string(),
    };
    MusicBrainzClient::new(client_config).map_err(|error| {
        log_event(
            "musicbrainz_client_failed",
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

fn validate_artwork_upload(format: &str, bytes: &[u8]) -> Result<&'static str, ApiError> {
    if bytes.is_empty() || bytes.len() > MAX_ARTWORK_UPLOAD_BYTES {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "artwork_size_invalid",
            "Cover artwork must be a non-empty image no larger than 32 MiB.",
        ));
    }
    let format = format.trim().to_ascii_lowercase();
    let (extension, image_format) = match format.as_str() {
        "jpg" | "jpeg" => ("jpg", image::ImageFormat::Jpeg),
        "png" => ("png", image::ImageFormat::Png),
        "gif" => ("gif", image::ImageFormat::Gif),
        "webp" => ("webp", image::ImageFormat::WebP),
        _ => {
            return Err(ApiError::without_request_id(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "artwork_format_unsupported",
                "Upload a JPEG, PNG, GIF, or WebP image.",
            ))
        }
    };
    let mut reader = image::ImageReader::with_format(Cursor::new(bytes), image_format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    if reader.decode().is_err() {
        return Err(ApiError::without_request_id(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "artwork_format_unsupported",
            "Upload a complete JPEG, PNG, GIF, or WebP image whose contents match its file type and dimensions do not exceed 8192 pixels.",
        ));
    }
    Ok(extension)
}

fn join_relative(parent: &str, child: &str) -> String {
    if parent.is_empty() {
        child.to_string()
    } else {
        format!("{parent}/{child}")
    }
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
    if request.media_type.as_deref().is_some_and(|media_type| {
        ![
            "movie",
            "series",
            "season",
            "episode",
            "music",
            "audiobook",
            "book",
        ]
        .contains(&media_type)
    }) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_type_invalid",
            "Choose a supported metadata type.",
        ));
    }
    if request.media_type.as_deref() == Some("episode")
        && (request.series.as_deref().is_none_or(str::is_empty)
            || request.season.is_none()
            || request.episode.is_none())
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_episode_fields_required",
            "TV episodes require series, season, and episode values.",
        ));
    }
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
        (request.episode_title.as_deref(), 500usize),
        (request.premiere_date.as_deref(), 10usize),
        (request.official_rating.as_deref(), 64usize),
    ];
    if scalar_fields
        .iter()
        .any(|(value, maximum)| value.is_some_and(|value| !valid_metadata_value(value, *maximum)))
        || request.authors.len() > 32
        || request.narrators.len() > 32
        || request.genres.len() > 64
        || request.writers.len() > 64
        || request.provider_ids.len() > 32
        || request
            .authors
            .iter()
            .chain(&request.narrators)
            .chain(&request.genres)
            .chain(&request.writers)
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
    if request
        .runtime_minutes
        .is_some_and(|runtime| runtime == 0 || runtime > 100_000)
        || request
            .community_rating
            .is_some_and(|rating| !rating.is_finite() || !(0.0..=10.0).contains(&rating))
        || request.season.is_some_and(|season| season > 10_000)
        || request
            .episode
            .is_some_and(|episode| episode == 0 || episode > 100_000)
        || request
            .provider_ids
            .iter()
            .any(|(key, value)| !valid_metadata_value(key, 64) || !valid_metadata_value(value, 256))
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_fields_invalid",
            "One or more typed metadata fields are outside the supported range.",
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
    let media_type = request
        .media_type
        .as_deref()
        .unwrap_or(match item.media_kind.as_str() {
            "music" => "music",
            "audiobook" => "audiobook",
            "book" => "book",
            _ => "movie",
        });
    let stem = item
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&item.relative_path);
    if item.media_kind == "video" || item.media_kind == "music" {
        let root = if item.media_kind == "video" {
            if media_type == "episode" {
                "episodedetails"
            } else {
                "movie"
            }
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
        xml.push_str(&xml_element(
            "title",
            request.episode_title.as_deref().or(Some(&request.title)),
        ));
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
        if media_type == "episode" {
            xml.push_str(&xml_element("showtitle", request.series.as_deref()));
            if let Some(season) = request.season {
                xml.push_str(&format!("  <season>{season}</season>\n"));
            }
            if let Some(episode) = request.episode {
                xml.push_str(&format!("  <episode>{episode}</episode>\n"));
            }
        }
        xml.push_str(&xml_element("premiered", request.premiere_date.as_deref()));
        xml.push_str(&xml_element("mpaa", request.official_rating.as_deref()));
        if let Some(runtime) = request.runtime_minutes {
            xml.push_str(&format!("  <runtime>{runtime}</runtime>\n"));
        }
        if let Some(rating) = request.community_rating {
            xml.push_str(&format!("  <rating>{rating}</rating>\n"));
        }
        for author in &request.authors {
            xml.push_str(&xml_element("artist", Some(author)));
        }
        for genre in &request.genres {
            xml.push_str(&xml_element("genre", Some(genre)));
        }
        for writer in &request.writers {
            xml.push_str(&xml_element("writer", Some(writer)));
        }
        for (provider, id) in &request.provider_ids {
            xml.push_str(&format!(
                "  <uniqueid type=\"{}\">{}</uniqueid>\n",
                xml_text(provider),
                xml_text(id)
            ));
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

fn comicinfo_sidecar(request: &MetadataSidecarRequest) -> String {
    let mut xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n".to_string();
    xml.push_str(&xml_element("Title", Some(&request.title)));
    xml.push_str(&xml_element("Series", request.series.as_deref()));
    xml.push_str(&xml_element("Number", request.volume_number.as_deref()));
    xml.push_str(&xml_element("Summary", request.description.as_deref()));
    if let Some(year) = request.year {
        xml.push_str(&format!("  <Year>{year}</Year>\n"));
    }
    let writers = if request.writers.is_empty() {
        &request.authors
    } else {
        &request.writers
    };
    if !writers.is_empty() {
        xml.push_str(&xml_element("Writer", Some(&writers.join(", "))));
    }
    xml.push_str(&xml_element("Publisher", request.publisher.as_deref()));
    if !request.genres.is_empty() {
        xml.push_str(&xml_element("Genre", Some(&request.genres.join(", "))));
    }
    xml.push_str(&xml_element("LanguageISO", request.language.as_deref()));
    if let Some(web) = request
        .provider_ids
        .get("web")
        .or_else(|| request.provider_ids.get("comicVine"))
    {
        xml.push_str(&xml_element("Web", Some(web)));
    }
    xml.push_str("</ComicInfo>\n");
    xml
}

fn folder_metadata_sidecar(
    folder: &VisibleMediaFolder,
    request: &MetadataSidecarRequest,
) -> (String, &'static str, String) {
    let media_type = request
        .media_type
        .as_deref()
        .unwrap_or_else(|| folder_media_type(folder));
    if matches!(media_type, "series" | "season") {
        let root_tag = if media_type == "series" {
            "tvshow"
        } else {
            "season"
        };
        let filename = if media_type == "series" {
            "tvshow.nfo"
        } else {
            "season.nfo"
        };
        let mut xml = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{root_tag}>\n");
        xml.push_str(&xml_element("title", Some(&request.title)));
        xml.push_str(&xml_element("sorttitle", request.sort_title.as_deref()));
        if let Some(year) = request.year {
            xml.push_str(&format!("  <year>{year}</year>\n"));
        }
        xml.push_str(&xml_element("plot", request.description.as_deref()));
        xml.push_str(&xml_element("studio", request.publisher.as_deref()));
        xml.push_str(&xml_element("language", request.language.as_deref()));
        xml.push_str(&xml_element("premiered", request.premiere_date.as_deref()));
        xml.push_str(&xml_element("mpaa", request.official_rating.as_deref()));
        if let Some(rating) = request.community_rating {
            xml.push_str(&format!("  <rating>{rating}</rating>\n"));
        }
        for genre in &request.genres {
            xml.push_str(&xml_element("genre", Some(genre)));
        }
        for writer in &request.writers {
            xml.push_str(&xml_element("writer", Some(writer)));
        }
        for (provider, id) in &request.provider_ids {
            xml.push_str(&format!(
                "  <uniqueid type=\"{}\">{}</uniqueid>\n",
                xml_text(provider),
                xml_text(id)
            ));
        }
        xml.push_str(&format!("</{root_tag}>\n"));
        return (format!("{}/{filename}", folder.relative_path), "nfo", xml);
    }

    let (media_kind, placeholder) = match folder.category.as_str() {
        "music" => ("music", "album-track.mp3"),
        "audiobooks" => ("audiobook", "book.m4b"),
        "books" => ("audiobook", "book.epub"),
        _ => ("video", "movie.mkv"),
    };
    let pseudo_item = CatalogItem {
        id: String::new(),
        root_id: folder.root_id.clone(),
        owner_username: None,
        relative_path: format!("{}/{placeholder}", folder.relative_path),
        media_kind: media_kind.to_string(),
        size_bytes: 0,
        modified_ns: 0,
        fingerprint: String::new(),
    };
    metadata_sidecar(&pseudo_item, request)
}

struct StagedSidecar {
    filename: String,
    expected: String,
    path: std::path::PathBuf,
}

fn create_artwork_replacement_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    action: ReplaceArtworkAction,
    request_id: String,
) -> Result<Response, ApiError> {
    let archived_relative_path = action.archived_relative_path.clone();
    let destination_relative_path = action.replacement_relative_path.clone();
    let actions = vec![BrokerAction::ReplaceArtwork(action)];
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let canonical = serde_json::to_vec(&json!({
        "actor": identity.username,
        "itemId": item.id,
        "actions": actions,
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
            request_json: json!({
                "kind": "replace_artwork",
                "itemId": item.id,
                "archivedRelativePath": archived_relative_path,
                "destinationRelativePath": destination_relative_path,
            })
            .to_string(),
            expires_at,
            actions: actions.clone(),
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
            "artwork_replacement_previewed",
            Some(&plan_id),
            &json!({
                "digest": digest,
                "itemId": item.id,
                "archivedRelativePath": archived_relative_path,
                "destinationRelativePath": destination_relative_path,
            })
            .to_string(),
        )
        .map_err(|error| {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;
    let mut warnings = vec![
        "The current image will be moved into its superseded subfolder before the replacement is installed.",
        "The staged replacement is fingerprint-bound and will never overwrite another destination.",
    ];
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "actions": actions,
            "expiresAt": expires_at,
            "mutationMode": state.config.mutation_mode,
            "warnings": warnings,
            "requestId": request_id,
        })),
    )
        .into_response())
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

struct PreparedMetadataAction {
    action: BrokerAction,
    staging_path: std::path::PathBuf,
}

async fn prepare_embedded_metadata_action(
    config: &AppConfig,
    identity: &Identity,
    item: &CatalogItem,
    extension: &str,
    generated: &str,
    request_id: &str,
) -> Result<PreparedMetadataAction, ApiError> {
    const MAX_EDITABLE_CONTAINER_BYTES: u64 = 512 * 1024 * 1024;
    let root = config
        .resolve_visible_root(identity, &item.root_id)
        .ok_or_else(|| ApiError::internal(request_id.to_string()))?;
    let source = open_regular_file_beneath(FilePath::new(&root.resolved_path), &item.relative_path)
        .map_err(|_| {
            ApiError::new(
                StatusCode::CONFLICT,
                "unsafe_embedded_metadata_source",
                "The book container could not be opened safely.",
                request_id.to_string(),
            )
        })?;
    let metadata = source
        .metadata()
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    if metadata.len() > MAX_EDITABLE_CONTAINER_BYTES {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "book_container_too_large",
            "The book container exceeds the 512 MiB safe rewrite limit.",
            request_id.to_string(),
        ));
    }
    let expected_source =
        opened_file_fingerprint(&source).map_err(|_| ApiError::internal(request_id.to_string()))?;
    let staging_directory = config.state_dir.join("provider-staging");
    tokio::fs::create_dir_all(&staging_directory)
        .await
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    let staging_filename = format!("embedded-{request_id}.{extension}");
    let staging_path = staging_directory.join(&staging_filename);
    let output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o660)
        .open(&staging_path)
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    let generated = generated.to_string();
    let extension_owned = extension.to_string();
    let rewrite = tokio::task::spawn_blocking(move || {
        rewrite_embedded_metadata(source, output, &extension_owned, &generated)
    })
    .await;
    if let Err(message) = rewrite
        .map_err(|_| "embedded metadata rewrite did not complete".to_string())
        .and_then(|result| result)
    {
        let _ = tokio::fs::remove_file(&staging_path).await;
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "embedded_metadata_rewrite_failed",
            message,
            request_id.to_string(),
        ));
    }
    let source_path = FilePath::new(&root.resolved_path).join(&item.relative_path);
    let final_source = file_fingerprint(&source_path).map_err(|_| {
        ApiError::new(
            StatusCode::CONFLICT,
            "book_container_changed",
            "The book container changed while the preview was being prepared.",
            request_id.to_string(),
        )
    })?;
    if final_source != expected_source {
        let _ = tokio::fs::remove_file(&staging_path).await;
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "book_container_changed",
            "The book container changed while the preview was being prepared.",
            request_id.to_string(),
        ));
    }
    let expected_replacement =
        file_fingerprint(&staging_path).map_err(|_| ApiError::internal(request_id.to_string()))?;
    let (parent, filename) = item
        .relative_path
        .rsplit_once('/')
        .unwrap_or(("", item.relative_path.as_str()));
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let archived_relative_path = join_relative(
        parent,
        &format!("superseded/{stem}-{request_id}.{extension}"),
    );
    Ok(PreparedMetadataAction {
        action: BrokerAction::ReplaceEmbeddedMetadata(ReplaceEmbeddedMetadataAction {
            staging_filename,
            root_id: item.root_id.clone(),
            source_relative_path: item.relative_path.clone(),
            archived_relative_path,
            replacement_relative_path: item.relative_path.clone(),
            expected_source,
            expected_replacement,
        }),
        staging_path,
    })
}

async fn prepare_metadata_action(
    config: &AppConfig,
    identity: &Identity,
    root_id: &str,
    destination_relative_path: String,
    extension: &str,
    generated: &str,
    request_id: &str,
) -> Result<PreparedMetadataAction, ApiError> {
    const MAX_EDITABLE_SIDECAR_BYTES: u64 = 1024 * 1024;
    let root = config
        .resolve_visible_root(identity, root_id)
        .ok_or_else(|| ApiError::internal(request_id.to_string()))?;
    let destination_path = FilePath::new(&root.resolved_path).join(&destination_relative_path);
    let existing = match std::fs::symlink_metadata(&destination_path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "unsafe_metadata_destination",
                    "The existing metadata destination is not a regular contained file.",
                    request_id.to_string(),
                ));
            }
            if metadata.len() > MAX_EDITABLE_SIDECAR_BYTES {
                return Err(ApiError::new(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "metadata_sidecar_too_large",
                    "The existing metadata sidecar is too large for a safe in-app edit.",
                    request_id.to_string(),
                ));
            }
            let mut file = open_regular_file_beneath(
                FilePath::new(&root.resolved_path),
                &destination_relative_path,
            )
            .map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "unsafe_metadata_destination",
                    "The existing metadata sidecar could not be opened safely.",
                    request_id.to_string(),
                )
            })?;
            let initial_fingerprint = opened_file_fingerprint(&file)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let mut bytes = Vec::with_capacity(metadata.len() as usize);
            file.by_ref()
                .take(MAX_EDITABLE_SIDECAR_BYTES + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let text = String::from_utf8(bytes).map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_not_utf8",
                    "The existing metadata sidecar is not UTF-8 XML and cannot be edited safely.",
                    request_id.to_string(),
                )
            })?;
            let final_fingerprint = opened_file_fingerprint(&file)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let path_fingerprint = file_fingerprint(&destination_path).map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_changed",
                    "The metadata sidecar changed while the preview was being prepared. Reload it and try again.",
                    request_id.to_string(),
                )
            })?;
            if initial_fingerprint != final_fingerprint || final_fingerprint != path_fingerprint {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_changed",
                    "The metadata sidecar changed while the preview was being prepared. Reload it and try again.",
                    request_id.to_string(),
                ));
            }
            Some((text, final_fingerprint))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(ApiError::internal(request_id.to_string())),
    };
    let contents = match existing.as_ref() {
        Some((existing, _)) => merge_managed_sidecar(existing, generated).map_err(|message| {
            ApiError::new(
                StatusCode::CONFLICT,
                "metadata_sidecar_merge_failed",
                message,
                request_id.to_string(),
            )
        })?,
        None => generated.to_string(),
    };
    let staged = stage_sidecar(config, extension, contents.as_bytes(), request_id).await?;
    let action = if let Some((_, expected_source)) = existing {
        let (parent, filename) = destination_relative_path
            .rsplit_once('/')
            .unwrap_or(("", destination_relative_path.as_str()));
        let stem = filename
            .rsplit_once('.')
            .map(|(stem, _)| stem)
            .unwrap_or(filename);
        let archived_relative_path = join_relative(
            parent,
            &format!("superseded/{stem}-{request_id}.{extension}"),
        );
        BrokerAction::ReplaceMetadataSidecar(ReplaceMetadataSidecarAction {
            staging_filename: staged.filename,
            root_id: root_id.to_string(),
            source_relative_path: destination_relative_path.clone(),
            archived_relative_path,
            replacement_relative_path: destination_relative_path,
            expected_source,
            expected_replacement: staged.expected,
        })
    } else {
        BrokerAction::InstallMetadataSidecar(InstallMetadataSidecarAction {
            staging_filename: staged.filename,
            destination_root_id: root_id.to_string(),
            destination_relative_path,
            expected: staged.expected,
        })
    };
    Ok(PreparedMetadataAction {
        action,
        staging_path: staged.path,
    })
}

fn create_metadata_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    request: &MetadataSidecarRequest,
    broker_action: BrokerAction,
    request_id: String,
) -> Result<Response, ApiError> {
    let expires_at = unix_timestamp().saturating_add(30 * 60);
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

    let embedded = matches!(&broker_action, BrokerAction::ReplaceEmbeddedMetadata(_));
    let replacing = matches!(&broker_action, BrokerAction::ReplaceMetadataSidecar(_));
    let mut warnings = if embedded {
        vec![
            "The staged EPUB or CBZ was rebuilt and parsed before this preview was created.",
            "The original book will be archived in its superseded subfolder before the replacement is installed.",
            "All non-metadata ZIP entries are copied verbatim; unknown XML elements in the metadata document are retained.",
        ]
    } else {
        vec![
            "Metadata is written as an application-compatible NFO or OPF sidecar; media streams are not re-encoded.",
            if replacing {
                "The current sidecar will be archived in its superseded subfolder before the XML-preserving replacement is installed."
            } else {
                "The sidecar is installed with no-overwrite filesystem semantics."
            },
            "Unknown XML elements and attributes from an existing sidecar are retained in the staged replacement.",
        ]
    };
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    let consumer_kind = match request.media_type.as_deref() {
        Some("audiobook") => "audiobook",
        Some("book") => "book",
        Some("music") => "music",
        Some("movie" | "episode" | "series" | "season") => "video",
        _ => item.media_kind.as_str(),
    };
    let affected_consumers = consumer_effects(&state.config, consumer_kind);
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
            "affectedConsumers": affected_consumers,
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
        Some("tombstone") => validate_operation_fields(&plan.operation, &["kind"])?,
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
            Some("tombstone") => (
                item.root_id.clone(),
                tombstone_destination(&item.relative_path)?,
            ),
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

fn tombstone_destination(relative_path: &str) -> Result<String, ApiError> {
    if relative_path.split('/').next() == Some(TOMBSTONE_FOLDER) {
        return Err(ApiError::without_request_id(
            StatusCode::CONFLICT,
            "already_tombstoned",
            "The selected item is already in the library tombstone folder.",
        ));
    }
    Ok(format!("{TOMBSTONE_FOLDER}/{relative_path}"))
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaybackPositionBody {
    position: f64,
}

async fn get_playback_position(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
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
    let _item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id.clone()).into_response(),
    };
    let position = catalog
        .get_playback_position(&item_id, &identity.username)
        .unwrap_or(None);
    Json(json!({ "position": position })).into_response()
}

async fn put_playback_position(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    body: Bytes,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
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
    let body: PlaybackPositionBody = match serde_json::from_slice(&body) {
        Ok(body) => body,
        Err(_) => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_request_body",
                "The request body must contain a position in seconds.",
                request_id,
            )
            .into_response();
        }
    };
    if body.position < 0.0 || !body.position.is_finite() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_position",
            "The playback position must be a non-negative finite number.",
            request_id,
        )
        .into_response();
    }
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
    let _item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id.clone()).into_response(),
    };
    if let Err(error) = catalog.save_playback_position(&item_id, &identity.username, body.position)
    {
        log_event(
            "playback_save_failed",
            &request_id,
            json!({ "error": error.to_string(), "itemId": item_id }),
        );
        return ApiError::internal(request_id).into_response();
    }
    Json(json!({ "saved": true })).into_response()
}

async fn item_stream(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    request: Request,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
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
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id.clone()).into_response(),
    };
    if !matches!(item.media_kind.as_str(), "music" | "audiobook") {
        return ApiError::new(
            StatusCode::CONFLICT,
            "audio_item_required",
            "Streaming requires a cataloged music or audiobook item.",
            request_id,
        )
        .into_response();
    }
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let root_path = root.resolved_path.clone();
    let relative_path = item.relative_path.clone();
    let content_type = audio_content_type(&relative_path);

    let file_size = match tokio::task::spawn_blocking({
        let root_path = root_path.clone();
        let relative_path = relative_path.clone();
        move || {
            use crate::broker::open_regular_file_beneath;
            let file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
                .map_err(|error| error.to_string())?;
            Ok::<u64, String>(file.metadata().map_err(|e| e.to_string())?.len())
        }
    })
    .await
    {
        Ok(Ok(size)) => size,
        Ok(Err(error)) => {
            log_event(
                "audio_read_failed",
                &request_id,
                json!({ "error": error, "itemId": item_id }),
            );
            return ApiError::internal(request_id).into_response();
        }
        Err(_) => return ApiError::internal(request_id).into_response(),
    };

    let range_header = request
        .headers()
        .get("range")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("bytes="));

    if let Some(range) = range_header {
        let mut parts = range.split('-');
        let first = parts.next().unwrap_or("");
        let second = parts.next().unwrap_or("");
        let (start, end) = if first.is_empty() {
            match second.parse::<u64>().ok() {
                Some(suffix) if suffix > 0 && file_size > 0 => {
                    let start = file_size.saturating_sub(suffix);
                    (start, file_size - 1)
                }
                _ => {
                    return (
                        StatusCode::RANGE_NOT_SATISFIABLE,
                        [(CONTENT_TYPE, content_type)],
                        [("Content-Range", format!("bytes */{file_size}"))],
                        Vec::<u8>::new(),
                    )
                        .into_response();
                }
            }
        } else {
            let start = match first.parse::<u64>().ok() {
                Some(start) => start,
                None => {
                    return (
                        StatusCode::RANGE_NOT_SATISFIABLE,
                        [(CONTENT_TYPE, content_type)],
                        [("Content-Range", format!("bytes */{file_size}"))],
                        Vec::<u8>::new(),
                    )
                        .into_response();
                }
            };
            let end = if second.is_empty() {
                file_size.saturating_sub(1)
            } else {
                second.parse::<u64>().ok().unwrap_or(start)
            };
            (start, end.min(file_size.saturating_sub(1)))
        };
        if start > end || start >= file_size {
            return (
                StatusCode::RANGE_NOT_SATISFIABLE,
                [(CONTENT_TYPE, content_type)],
                [("Content-Range", format!("bytes */{file_size}"))],
                Vec::<u8>::new(),
            )
                .into_response();
        }
        let length = end - start + 1;

        let body = match tokio::task::spawn_blocking({
            let root_path = root_path.clone();
            let relative_path = relative_path.clone();
            move || {
                use crate::broker::open_regular_file_beneath;
                let mut file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
                    .map_err(|error| error.to_string())?;
                use std::io::{Read, Seek, SeekFrom};
                file.seek(SeekFrom::Start(start))
                    .map_err(|error| error.to_string())?;
                let mut buffer = vec![0u8; length as usize];
                file.read_exact(&mut buffer)
                    .map_err(|error| error.to_string())?;
                Ok::<Vec<u8>, String>(buffer)
            }
        })
        .await
        {
            Ok(Ok(data)) => data,
            Ok(Err(error)) => {
                log_event(
                    "audio_read_failed",
                    &request_id,
                    json!({ "error": error, "itemId": item_id }),
                );
                return ApiError::internal(request_id).into_response();
            }
            Err(_) => return ApiError::internal(request_id).into_response(),
        };

        return (
            StatusCode::PARTIAL_CONTENT,
            [
                (CONTENT_TYPE, content_type.to_string()),
                (
                    HeaderName::from_static("accept-ranges"),
                    "bytes".to_string(),
                ),
                (
                    HeaderName::from_static("content-range"),
                    format!("bytes {start}-{end}/{file_size}"),
                ),
                (
                    HeaderName::from_static("content-length"),
                    length.to_string(),
                ),
            ],
            body,
        )
            .into_response();
    }

    let body = match tokio::task::spawn_blocking({
        let root_path = root_path.clone();
        let relative_path = relative_path.clone();
        move || {
            use crate::broker::open_regular_file_beneath;
            let mut file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
                .map_err(|error| error.to_string())?;
            use std::io::Read;
            let mut buffer = Vec::with_capacity(file_size as usize);
            file.read_to_end(&mut buffer)
                .map_err(|error| error.to_string())?;
            Ok::<Vec<u8>, String>(buffer)
        }
    })
    .await
    {
        Ok(Ok(data)) => data,
        Ok(Err(error)) => {
            log_event(
                "audio_read_failed",
                &request_id,
                json!({ "error": error, "itemId": item_id }),
            );
            return ApiError::internal(request_id).into_response();
        }
        Err(_) => return ApiError::internal(request_id).into_response(),
    };

    (
        StatusCode::OK,
        [
            (CONTENT_TYPE, content_type.to_string()),
            (
                HeaderName::from_static("accept-ranges"),
                "bytes".to_string(),
            ),
        ],
        body,
    )
        .into_response()
}

fn audio_content_type(path: &str) -> &'static str {
    match path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_lowercase())
        .as_deref()
    {
        Some("mp3") => "audio/mpeg",
        Some("flac") => "audio/flac",
        Some("ogg") | Some("oga") => "audio/ogg",
        Some("wav") => "audio/wav",
        Some("m4a") | Some("aac") => "audio/mp4",
        Some("opus") => "audio/opus",
        Some("wma") => "audio/x-ms-wma",
        Some("aiff") | Some("aif") => "audio/aiff",
        Some("webm") => "audio/webm",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::subtitle_fps_compatible;

    #[test]
    fn subtitle_fps_within_half_a_frame_is_compatible() {
        assert_eq!(
            subtitle_fps_compatible(Some(23.976), Some(24.0)),
            Some(true)
        );
        assert_eq!(subtitle_fps_compatible(Some(25.0), Some(25.0)), Some(true));
        assert_eq!(
            subtitle_fps_compatible(Some(29.97), Some(29.97)),
            Some(true)
        );
    }

    #[test]
    fn subtitle_fps_mismatch_is_reported_as_incompatible() {
        assert_eq!(
            subtitle_fps_compatible(Some(25.0), Some(23.976)),
            Some(false)
        );
        assert_eq!(
            subtitle_fps_compatible(Some(23.976), Some(25.0)),
            Some(false)
        );
    }

    #[test]
    fn unknown_fps_on_either_side_is_neutral() {
        assert_eq!(subtitle_fps_compatible(None, Some(24.0)), None);
        assert_eq!(subtitle_fps_compatible(Some(24.0), None), None);
        assert_eq!(subtitle_fps_compatible(None, None), None);
    }
}
