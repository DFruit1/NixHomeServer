use super::*;
use std::io::Read;

pub(super) async fn search_subtitles(
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

pub(super) async fn batch_search_subtitles(
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

pub(super) async fn install_provider_subtitle(
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

pub(super) async fn subtitle_provider_content(
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
                "Subtitle content requires a cataloged video item.",
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

pub(super) async fn adjust_subtitle_timing(
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

pub(super) async fn installed_subtitles(
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

pub(super) async fn installed_subtitle_content(
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

pub(super) async fn upload_subtitle(
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
