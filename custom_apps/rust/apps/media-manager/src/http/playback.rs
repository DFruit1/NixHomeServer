use super::*;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaybackPositionBody {
    position: f64,
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
