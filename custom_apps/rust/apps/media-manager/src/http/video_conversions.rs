//! Conversions page: videos browsers cannot play, the owner's conversion jobs,
//! and queuing or cancelling conversions. See `crate::video_conversion`.
use super::*;
use crate::media::LibraryCategory;
use crate::video_conversion::{self as conversion, Format, Job};

const MAX_LISTED_PER_ROOT: usize = 20_000;
const MAX_QUEUED_PER_REQUEST: usize = 500;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ListQuery {
    item_id: Option<String>,
    /// The editor only needs the caller's jobs; skip the library-wide scan.
    #[serde(default)]
    jobs_only: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct QueueRequest {
    item_ids: Vec<String>,
    format: String,
    destination_root_id: Option<String>,
    /// `replace` (default) or `copy`; copy jobs leave the original untouched.
    mode: Option<String>,
    /// New leaf name for a copy job; defaults to "<name> (edited).<ext>".
    output_name: Option<String>,
    trim_start_seconds: Option<f64>,
    trim_end_seconds: Option<f64>,
}

fn available(config: &AppConfig) -> bool {
    config.mutation_mode == MutationMode::Enabled && config.ffprobe_path.is_some()
}

fn image_subtitles(probe: &VideoProbe) -> bool {
    probe.subtitle_streams.iter().any(|stream| {
        matches!(
            stream.codec.as_str(),
            "hdmv_pgs_subtitle" | "dvd_subtitle" | "dvb_subtitle" | "xsub"
        )
    })
}

fn candidate(root: &VisibleRoot, item: &CatalogItem, probe: Option<&VideoProbe>) -> Value {
    json!({
        "itemId": item.id,
        "rootId": item.root_id,
        "rootLabel": root.label,
        "relativePath": item.relative_path,
        "sizeBytes": item.size_bytes,
        "reasons": probe.map(|probe| conversion::browser_issues(&item.relative_path, probe)).unwrap_or_default(),
        "videoCodec": probe.and_then(|probe| probe.codec.clone()),
        "audioCodecs": probe.map(|probe| probe.audio_codecs.clone()).unwrap_or_default(),
        "imageSubtitles": probe.is_some_and(image_subtitles),
    })
}

/// Videos needing conversion in every visible video library, plus the caller's
/// jobs. `itemId` also returns that one video even when it plays already.
pub(super) async fn list(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let config = state.config.clone();
    let catalog = state.catalog.clone();
    let lookup_identity = identity.clone();
    let selected_id = query.item_id.filter(|id| valid_object_id(id));
    let jobs_only = query.jobs_only;
    let listed = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        let identity = lookup_identity;
        if jobs_only {
            let jobs = conversion::jobs(&config, &identity.username)?
                .iter()
                .map(Job::view)
                .collect::<Vec<_>>();
            return Ok(json!({
                "available": available(&config),
                "canConvert": identity.can_edit(&config.editor_group),
                "formats": conversion::formats_view(),
                "candidates": [],
                "selected": null,
                "jobs": jobs,
                "probePending": 0,
                "truncated": false,
            }));
        }
        let catalog = catalog.open().map_err(|error| error.to_string())?;
        let active = conversion::all_jobs(&config)?
            .into_iter()
            .filter(Job::is_active)
            .map(|job| (job.root_id, job.relative_path))
            .collect::<BTreeSet<_>>();
        let mut candidates = Vec::new();
        let mut selected = Value::Null;
        let mut truncated = false;
        let mut probe_pending = 0usize;
        for root in config.visible_roots(&identity) {
            if root.category != LibraryCategory::Videos || !root.available {
                continue;
            }
            let owner = (root.scope == RootScope::Personal).then_some(identity.username.as_str());
            let items = catalog
                .list_items_after(&root.id, owner, None, MAX_LISTED_PER_ROOT)
                .map_err(|error| error.to_string())?;
            truncated |= items.len() >= MAX_LISTED_PER_ROOT;
            let videos = items
                .into_iter()
                .filter(|item| item.media_kind == MediaKind::Video)
                .collect::<Vec<_>>();
            let cache = VideoProbeCache::open_for_root(
                &config.state_dir,
                &root.id,
                FilePath::new(&root.resolved_path),
            );
            let mut missing = Vec::new();
            for item in &videos {
                let probe = cache.probe_for(&item.relative_path, &item.fingerprint);
                if probe.is_none() && !cache.has_probe(&item.relative_path, &item.fingerprint) {
                    missing.push((item.relative_path.clone(), item.fingerprint.clone()));
                }
                if selected_id.as_deref() == Some(item.id.as_str()) {
                    selected = candidate(&root, item, probe.as_ref());
                }
                let Some(probe) = probe else { continue };
                if active.contains(&(item.root_id.clone(), item.relative_path.clone()))
                    || conversion::browser_issues(&item.relative_path, &probe).is_empty()
                {
                    continue;
                }
                candidates.push(candidate(&root, item, Some(&probe)));
            }
            probe_pending += missing.len();
            if !missing.is_empty()
                && let (Some(ffprobe), Ok(permit)) = (
                    config.ffprobe_path.clone(),
                    crate::video_probe::PROBE_LIMIT.try_acquire(),
                )
            {
                // Same bounded background fill as the Videos page.
                let state_dir = config.state_dir.clone();
                let root_id = root.id.clone();
                let root_path = root.resolved_path.clone();
                std::thread::spawn(move || {
                    let _permit = permit;
                    let mut cache = VideoProbeCache::open_for_root(
                        &state_dir,
                        &root_id,
                        FilePath::new(&root_path),
                    );
                    let _ = refresh_root_probes(
                        FilePath::new(&ffprobe),
                        FilePath::new(&root_path),
                        &mut cache,
                        &missing,
                    );
                });
            }
        }
        let jobs = conversion::jobs(&config, &identity.username)?
            .iter()
            .map(Job::view)
            .collect::<Vec<_>>();
        Ok(json!({
            "available": available(&config),
            "canConvert": identity.can_edit(&config.editor_group),
            "formats": conversion::formats_view(),
            "candidates": candidates,
            "selected": selected,
            "jobs": jobs,
            "probePending": probe_pending,
            "truncated": truncated,
        }))
    })
    .await;
    match listed {
        Ok(Ok(body)) => Json(body).into_response(),
        Ok(Err(error)) => {
            log_event(
                "video_conversion_list_failed",
                &request_id,
                json!({ "error": error }),
            );
            ApiError::internal(request_id).into_response()
        }
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

fn unavailable(request_id: String) -> Response {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "video_conversion_unavailable",
        "Video conversion is not available on this server.",
        request_id,
    )
    .into_response()
}

/// Queue one job per video. Videos already converting, gone, or not videos are
/// reported back instead of failing the whole request.
pub(super) async fn queue(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<QueueRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !available(&state.config) {
        return unavailable(request_id);
    }
    let Some(format) = Format::parse(&request.format) else {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_format",
            "Choose one of the offered formats.",
            request_id,
        )
        .into_response();
    };
    let audio = format == Format::AudioMp3;
    let mode = request
        .mode
        .clone()
        .unwrap_or_else(|| conversion::MODE_REPLACE.to_string());
    if !matches!(
        mode.as_str(),
        conversion::MODE_REPLACE | conversion::MODE_COPY
    ) {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_mode",
            "Choose whether to replace the original or save a copy.",
            request_id,
        )
        .into_response();
    }
    let copy = mode == conversion::MODE_COPY;
    if copy
        && (audio
            || request.item_ids.len() != 1
            || request.destination_root_id.is_some()
            || request
                .output_name
                .as_deref()
                .is_some_and(|name| !conversion::valid_copy_name(name, format)))
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_copy",
            "Save a copy for one video at a time, using a file name with the chosen format's extension beside the original.",
            request_id,
        )
        .into_response();
    }
    if !copy
        && (request.output_name.is_some()
            || request.trim_start_seconds.is_some()
            || request.trim_end_seconds.is_some())
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_edit",
            "A replacement conversion cannot take an edit name or trim range.",
            request_id,
        )
        .into_response();
    }
    if copy
        && (request.trim_start_seconds.is_some() != request.trim_end_seconds.is_some()
            || request
                .trim_start_seconds
                .is_some_and(|start| !start.is_finite() || start < 0.0)
            || request.trim_end_seconds.is_some_and(|end| !end.is_finite())
            || matches!(
                (request.trim_start_seconds, request.trim_end_seconds),
                (Some(start), Some(end)) if end - start < 1.0
            ))
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_trim",
            "Choose a start and end at least one second apart, or leave both empty.",
            request_id,
        )
        .into_response();
    }
    let destination = request
        .destination_root_id
        .as_deref()
        .and_then(|id| state.config.resolve_visible_root(&identity, id));
    if (audio
        && !destination.as_ref().is_some_and(|root| {
            root.available
                && matches!(
                    root.category,
                    LibraryCategory::Music
                        | LibraryCategory::Podcasts
                        | LibraryCategory::Audiobooks
                )
        }))
        || (!audio && request.destination_root_id.is_some())
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_audio_destination",
            "Choose an available music, podcast or audiobook library for an audio copy.",
            request_id,
        )
        .into_response();
    }
    if request.item_ids.is_empty() || request.item_ids.len() > MAX_QUEUED_PER_REQUEST {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_video_selection",
            format!("Choose between 1 and {MAX_QUEUED_PER_REQUEST} videos."),
            request_id,
        )
        .into_response();
    }
    let config = state.config.clone();
    let catalog = state.catalog.clone();
    let actor = identity.clone();
    let queued = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        let identity = actor;
        let catalog = catalog.open().map_err(|error| error.to_string())?;
        let mut active = conversion::all_jobs(&config)?
            .into_iter()
            .filter(Job::is_active)
            .map(|job| (job.root_id, job.relative_path))
            .collect::<BTreeSet<_>>();
        let mut jobs = Vec::new();
        let mut skipped = Vec::new();
        let mut created_at = conversion::now();
        for item_id in request.item_ids.iter().collect::<BTreeSet<_>>() {
            let reject = |reason: &str| json!({ "itemId": item_id, "reason": reason });
            let Ok(item) = visible_catalog_item(&config, &identity, &catalog, item_id) else {
                skipped.push(reject("This video is no longer in a library you can see."));
                continue;
            };
            let Some(root) = config
                .resolve_visible_root(&identity, &item.root_id)
                .filter(|root| root.category == LibraryCategory::Videos && root.available)
            else {
                skipped.push(reject("This video's library is unavailable."));
                continue;
            };
            if item.media_kind != MediaKind::Video {
                skipped.push(reject("Only videos can be converted."));
                continue;
            }
            if !active.insert((item.root_id.clone(), item.relative_path.clone())) {
                skipped.push(reject("This video is already being converted."));
                continue;
            }
            let expected_source = match open_regular_file_beneath(
                FilePath::new(&root.resolved_path),
                &item.relative_path,
            )
            .and_then(|file| opened_file_fingerprint(&file))
            {
                Ok(fingerprint) => fingerprint,
                Err(_) => {
                    skipped.push(reject("The video could not be opened. Rescan the library."));
                    continue;
                }
            };
            let output_name = copy.then(|| {
                request
                    .output_name
                    .clone()
                    .unwrap_or_else(|| conversion::default_copy_name(&item.relative_path, format))
            });
            if let Some(name) = &output_name {
                let path = match item.relative_path.rsplit_once('/') {
                    Some((folder, _)) => format!("{folder}/{name}"),
                    None => name.clone(),
                };
                if std::fs::symlink_metadata(std::path::Path::new(&root.resolved_path).join(&path))
                    .is_ok()
                {
                    skipped.push(reject(
                        "A file with that name already exists beside this video. Choose another name.",
                    ));
                    continue;
                }
            }
            let job = Job {
                id: homelab_common::random_hex(12),
                owner: identity.username.clone(),
                item_id: item.id.clone(),
                root_id: item.root_id.clone(),
                root_label: root.label.clone(),
                relative_path: item.relative_path.clone(),
                format: format.id().to_string(),
                destination_root_id: request.destination_root_id.clone(),
                mode: mode.clone(),
                output_name,
                trim_start_seconds: request.trim_start_seconds,
                trim_end_seconds: request.trim_end_seconds,
                expected_source,
                source_bytes: u64::try_from(item.size_bytes).unwrap_or(0),
                state: "queued".into(),
                // Distinct timestamps keep the requested order in the queue.
                created_at,
                started_at: None,
                finished_at: None,
                progress: None,
                error: None,
                plan_id: None,
                staging_filename: None,
                output_relative_path: None,
                output_bytes: None,
                dropped_subtitles: 0,
            };
            created_at += 1;
            job.save(&config)?;
            jobs.push(job.view());
        }
        if !jobs.is_empty() {
            conversion::wake_worker(&config)?;
        }
        Ok(json!({ "jobs": jobs, "skipped": skipped }))
    })
    .await;
    match queued {
        Ok(Ok(body)) => {
            if let Ok(catalog) = state.catalog.open() {
                let _ = catalog.insert_audit_event(
                    &request_id,
                    &identity.username,
                    "video_conversions_queued",
                    None,
                    &json!({ "format": request_format_id(&body), "count": body["jobs"].as_array().map_or(0, Vec::len) })
                        .to_string(),
                );
            }
            (StatusCode::ACCEPTED, Json(body)).into_response()
        }
        Ok(Err(error)) => {
            log_event(
                "video_conversion_queue_failed",
                &request_id,
                json!({ "error": error }),
            );
            ApiError::internal(request_id).into_response()
        }
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

fn request_format_id(body: &Value) -> Option<String> {
    body["jobs"][0]["format"].as_str().map(str::to_string)
}

pub(super) async fn cancel(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(job_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !valid_object_id(&job_id) {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "video_conversion_missing",
            "That conversion was not found.",
            request_id,
        )
        .into_response();
    }
    let config = state.config.clone();
    let username = identity.username.clone();
    match tokio::task::spawn_blocking(move || {
        conversion::request_cancel(&config, &username, &job_id)
    })
    .await
    {
        Ok(Ok(job)) => Json(json!({ "job": job.view() })).into_response(),
        Ok(Err(message)) => ApiError::new(
            StatusCode::CONFLICT,
            "video_conversion_not_cancellable",
            message,
            request_id,
        )
        .into_response(),
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

/// Library health warning for a video browsers cannot play as it is.
pub(super) fn playback_issue(
    item: &CatalogItem,
    probe: &VideoProbe,
) -> Option<MetadataHealthIssue> {
    let reasons = conversion::browser_issues(&item.relative_path, probe);
    if reasons.is_empty() {
        return None;
    }
    Some(MetadataHealthIssue {
        code: "video-needs-conversion".to_string(),
        severity: "warning".to_string(),
        field: None,
        title: "Browsers cannot play this video directly".to_string(),
        message: format!(
            "{} The player has to convert it every time it is first played. Converting it once makes it load faster and play on more devices.",
            reasons.join(" ")
        ),
        sources: Vec::new(),
        current_value: None,
        current_sources: Vec::new(),
        proposed_values: Vec::new(),
        affected_files: Vec::new(),
        affected_file_count: None,
    })
}
