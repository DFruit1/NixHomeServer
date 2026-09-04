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
        opened_file_fingerprint, BrokerAction, InstallArtworkAction, InstallMetadataSidecarAction,
        InstallSubtitleAction, MoveAction, ReplaceArtworkAction, ReplaceEmbeddedMetadataAction,
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
mod artwork_http;
pub use artwork_http::JellyfinImageCache;
mod conversions;
mod metadata;
mod metadata_lookups;
mod plans;
mod playback;
mod refresh;
mod subtitles;

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
struct MetadataIssuesQuery {
    root_id: String,
    cursor: Option<String>,
    page_size: Option<usize>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderMetadataQuery {
    root_id: String,
    relative_path: String,
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
pub(super) struct MetadataSidecarRequest {
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
pub(super) struct MusicLookupRequest {
    mode: Option<String>,
    artist: Option<String>,
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TmdbSearchRequest {
    query: String,
    year: Option<u16>,
    media_type: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TmdbDetailsRequest {
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
        .route("/api/v1/items/{item_id}", get(item_details))
        .route(
            "/api/v1/items/{item_id}/image",
            get(artwork_http::item_image),
        )
        .route(
            "/api/v1/items/{item_id}/image/replacement",
            post(artwork_http::preview_artwork_replacement),
        )
        .route("/api/v1/items/{item_id}/stream", get(playback::item_stream))
        .route(
            "/api/v1/items/{item_id}/playback",
            get(playback::get_playback_position).put(playback::put_playback_position),
        )
        .route(
            "/api/v1/items/{item_id}/metadata",
            get(metadata::item_metadata),
        )
        .route("/api/v1/metadata/issues", get(metadata::metadata_issues))
        .route("/api/v1/folders/metadata", get(metadata::folder_metadata))
        .route("/api/v1/conversions", get(conversions::conversions))
        .route(
            "/api/v1/conversions/inbox",
            get(conversions::conversions_inbox),
        )
        .route(
            "/api/v1/conversions/inbox/error",
            get(conversions::conversions_inbox_error),
        )
        .route("/api/v1/scans", post(plans::scan))
        .route(
            "/api/v1/items/{item_id}/subtitles/upload",
            post(subtitles::upload_subtitle),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles",
            get(subtitles::installed_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/installed/{subtitle_id}/content",
            get(subtitles::installed_subtitle_content),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/search",
            get(subtitles::search_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/provider",
            post(subtitles::install_provider_subtitle),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/provider/{file_id}/content",
            get(subtitles::subtitle_provider_content),
        )
        .route(
            "/api/v1/items/{item_id}/subtitles/adjust",
            post(subtitles::adjust_subtitle_timing),
        )
        .route(
            "/api/v1/subtitles/batch-search",
            post(subtitles::batch_search_subtitles),
        )
        .route(
            "/api/v1/items/{item_id}/metadata/sidecar",
            post(metadata::preview_metadata_sidecar),
        )
        .route(
            "/api/v1/folders/metadata/sidecar",
            post(metadata::preview_folder_metadata_sidecar),
        )
        .route(
            "/api/v1/items/{item_id}/metadata/lookup",
            post(metadata_lookups::lookup_music_metadata),
        )
        .route(
            "/api/v1/metadata/tmdb/search",
            post(metadata_lookups::search_tmdb_metadata),
        )
        .route(
            "/api/v1/metadata/tmdb/details",
            post(metadata_lookups::get_tmdb_details),
        )
        .route(
            "/api/v1/integrations/{integration_id}/refresh",
            get(refresh::integration_refresh_status).post(refresh::queue_integration_refresh),
        )
        .route("/api/v1/plans", post(plans::preview_plan))
        .route("/api/v1/plans/{plan_id}", get(plans::plan_status))
        .route("/api/v1/plans/{plan_id}/confirm", post(plans::confirm_plan))
        .layer(axum::extract::DefaultBodyLimit::max(
            MAX_SUBTITLE_BYTES + 1024,
        ))
        .fallback(not_found)
        .with_state(Arc::new(state))
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

async fn item_details(
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
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let mut response = Json(item).into_response();
    response.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    response
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
