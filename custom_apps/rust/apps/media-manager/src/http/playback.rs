use super::*;
use crate::capabilities::MediaAction;
use std::process::{Command, Stdio};
use tokio::io::AsyncReadExt;
use tokio_util::io::ReaderStream;

static VIDEO_TRANSCODE_LIMIT: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaybackPositionBody {
    position: f64,
}

pub(super) async fn item_playback_targets(
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
        Err(error) => return error.with_request_id(request_id.clone()).into_response(),
    };
    let targets: Vec<serde_json::Value> = consumer_effects(&state.config, item.media_kind)
        .into_iter()
        .map(|effect| {
            json!({
                "id": effect.id,
                "label": effect.label,
                "available": effect.available,
                "url": effect.native_url,
            })
        })
        .collect();
    Json(json!({ "targets": targets })).into_response()
}

pub(super) async fn get_playback_position(
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

pub(super) async fn put_playback_position(
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

pub(super) async fn item_stream(
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
    if !item.media_kind.supports(MediaAction::PlayInline) {
        return ApiError::new(
            StatusCode::CONFLICT,
            "playable_item_required",
            "Streaming requires a cataloged video, music, or audiobook item.",
            request_id,
        )
        .into_response();
    }
    let transcode = request
        .uri()
        .query()
        .is_some_and(|query| query.split('&').any(|part| part == "transcode=1"));
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let mut root_path = root.resolved_path.clone();
    let mut relative_path = item.relative_path.clone();
    let content_type = if item.media_kind == crate::media::MediaKind::Video {
        if transcode {
            let Some(ffprobe_path) = state.config.ffprobe_path.clone() else {
                return ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "video_transcoding_unavailable",
                    "Video conversion is not configured on this server.",
                    request_id,
                )
                .into_response();
            };
            let ffmpeg_path = ffprobe_path.with_file_name("ffmpeg");
            let cache_root = state.config.state_dir.join("video-transcodes");
            let cache_name = format!(
                "{}-{}.mp4",
                item.id,
                homelab_common::sha256_hex(item.fingerprint.as_bytes())
            );
            let source_root = root_path.clone();
            let source_relative = relative_path.clone();
            let output = cache_root.join(&cache_name);
            let cache_root_for_worker = cache_root.clone();
            let temp_name = format!(
                "{}-{}.mp4",
                cache_name.trim_end_matches(".mp4"),
                &homelab_common::sha256_hex(request_id.as_bytes())[..12]
            );
            let temp = cache_root.join(temp_name);
            let permit = if output.is_file() {
                None
            } else {
                match VIDEO_TRANSCODE_LIMIT.acquire().await {
                    Ok(permit) => Some(permit),
                    Err(_) => return ApiError::internal(request_id).into_response(),
                }
            };
            let result = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                use crate::broker::open_regular_file_beneath;
                if output.is_file() {
                    return Ok::<(), String>(());
                }
                std::fs::create_dir_all(&cache_root_for_worker)
                    .map_err(|error| error.to_string())?;
                let input =
                    open_regular_file_beneath(FilePath::new(&source_root), &source_relative)
                        .map_err(|error| error.to_string())?;
                let status = Command::new(ffmpeg_path)
                    .args([
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-y",
                        "-i",
                        "pipe:0",
                        "-map",
                        "0:v:0",
                        "-map",
                        "0:a:0?",
                        "-c:v",
                        "libx264",
                        "-preset",
                        "veryfast",
                        "-crf",
                        "23",
                        "-c:a",
                        "aac",
                        "-movflags",
                        "+faststart",
                        "-f",
                        "mp4",
                    ])
                    .arg(&temp)
                    .stdin(Stdio::from(input))
                    .status()
                    .map_err(|error| format!("start ffmpeg: {error}"))?;
                if !status.success() {
                    let _ = std::fs::remove_file(&temp);
                    return Err(format!("ffmpeg exited with status {status}"));
                }
                if !output.is_file() {
                    std::fs::rename(&temp, &output).map_err(|error| error.to_string())?;
                } else {
                    let _ = std::fs::remove_file(&temp);
                }
                Ok(())
            })
            .await;
            match result {
                Ok(Ok(())) => {
                    root_path = cache_root.to_string_lossy().into_owned();
                    relative_path = cache_name;
                }
                Ok(Err(error)) => {
                    log_event(
                        "video_transcode_failed",
                        &request_id,
                        json!({ "error": error, "itemId": item_id }),
                    );
                    return ApiError::new(
                        StatusCode::UNSUPPORTED_MEDIA_TYPE,
                        "video_transcode_failed",
                        "The video could not be converted for browser playback.",
                        request_id,
                    )
                    .into_response();
                }
                Err(_) => return ApiError::internal(request_id).into_response(),
            }
            "video/mp4"
        } else {
            video_content_type(&relative_path)
        }
    } else {
        audio_content_type(&relative_path)
    };

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
        .and_then(|value| value.to_str().ok());

    if range_header.is_some() {
        let (start, end) = match homelab_common::parse_range(range_header, file_size) {
            Some((start, end)) => (start, end),
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
        let length = end - start + 1;

        let file = match tokio::task::spawn_blocking({
            let root_path = root_path.clone();
            let relative_path = relative_path.clone();
            move || {
                use crate::broker::open_regular_file_beneath;
                let mut file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
                    .map_err(|error| error.to_string())?;
                use std::io::{Seek, SeekFrom};
                file.seek(SeekFrom::Start(start))
                    .map_err(|error| error.to_string())?;
                Ok::<std::fs::File, String>(file)
            }
        })
        .await
        {
            Ok(Ok(file)) => file,
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

        let body = Body::from_stream(ReaderStream::new(
            tokio::fs::File::from_std(file).take(length),
        ));

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

    let file = match tokio::task::spawn_blocking({
        let root_path = root_path.clone();
        let relative_path = relative_path.clone();
        move || {
            use crate::broker::open_regular_file_beneath;
            let file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
                .map_err(|error| error.to_string())?;
            Ok::<std::fs::File, String>(file)
        }
    })
    .await
    {
        Ok(Ok(file)) => file,
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

    let body = Body::from_stream(ReaderStream::new(tokio::fs::File::from_std(file)));

    (
        StatusCode::OK,
        [
            (CONTENT_TYPE, content_type.to_string()),
            (
                HeaderName::from_static("accept-ranges"),
                "bytes".to_string(),
            ),
            (
                HeaderName::from_static("content-length"),
                file_size.to_string(),
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

fn video_content_type(path: &str) -> &'static str {
    match path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_lowercase())
        .as_deref()
    {
        Some("mp4") | Some("m4v") | Some("mov") => "video/mp4",
        Some("webm") => "video/webm",
        Some("ogv") => "video/ogg",
        Some("mkv") => "video/x-matroska",
        _ => "application/octet-stream",
    }
}
