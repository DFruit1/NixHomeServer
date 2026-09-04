use super::*;

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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ArtworkReplacementQuery {
    format: String,
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

struct ArtworkPlanAction {
    broker_action: BrokerAction,
    archived_relative_path: Option<String>,
    destination_relative_path: String,
}

fn create_artwork_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    artwork_plan: ArtworkPlanAction,
    request_id: String,
) -> Result<Response, ApiError> {
    let replacing = matches!(artwork_plan.broker_action, BrokerAction::ReplaceArtwork(_));
    let archived_relative_path = artwork_plan.archived_relative_path;
    let destination_relative_path = artwork_plan.destination_relative_path;
    let actions = vec![artwork_plan.broker_action];
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
                "kind": if replacing { "replace_artwork" } else { "install_artwork" },
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
            if replacing {
                "artwork_replacement_previewed"
            } else {
                "artwork_install_previewed"
            },
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
    let mut warnings = if replacing {
        vec![
            "The current image will be moved into its superseded subfolder before the replacement is installed.",
            "The staged replacement is fingerprint-bound and will never overwrite another destination.",
        ]
    } else {
        vec![
            "A new cover image will be installed beside the selected media file.",
            "The staged cover is fingerprint-bound and will never overwrite an existing destination.",
        ]
    };
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
    let Some(entry) = metadata::cached_application_metadata(cache_file, item, false).await else {
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

pub(super) async fn item_image(
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

pub(super) async fn preview_artwork_replacement(
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
        Ok(item)
            if matches!(
                item.media_kind.as_str(),
                "artwork" | "video" | "music" | "audiobook" | "podcast" | "book"
            ) =>
        {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "artwork_item_required",
                "Cover artwork can only be changed for a media item or cataloged image file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let existing_artwork = if item.media_kind == "artwork" {
        Some(item.clone())
    } else {
        let parent = item
            .relative_path
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let same_directory =
            match catalog.list_artwork(&item.root_id, item.owner_username.as_deref()) {
                Ok(items) => items
                    .into_iter()
                    .filter(|candidate| {
                        candidate
                            .relative_path
                            .rsplit_once('/')
                            .map(|(candidate_parent, _)| candidate_parent)
                            .unwrap_or("")
                            == parent
                    })
                    .collect::<Vec<_>>(),
                Err(_) => return ApiError::internal(request_id).into_response(),
            };
        preferred_artwork(&same_directory, &item.relative_path)
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
    let staged = match stage_sidecar(&state.config, extension, &body, &request_id).await {
        Ok(staged) => staged,
        Err(error) => return error.into_response(),
    };
    let artwork_plan = if let Some(artwork) = existing_artwork {
        let (parent, filename) = artwork
            .relative_path
            .rsplit_once('/')
            .unwrap_or(("", &artwork.relative_path));
        let (stem, original_extension) = filename.rsplit_once('.').unwrap_or((filename, "jpg"));
        let destination_relative_path = join_relative(parent, &format!("{stem}.{extension}"));
        let archived_relative_path = join_relative(
            parent,
            &format!("superseded/{stem}-{request_id}.{original_extension}"),
        );
        ArtworkPlanAction {
            broker_action: BrokerAction::ReplaceArtwork(ReplaceArtworkAction {
                staging_filename: staged.filename,
                root_id: artwork.root_id,
                source_relative_path: artwork.relative_path,
                archived_relative_path: archived_relative_path.clone(),
                replacement_relative_path: destination_relative_path.clone(),
                expected_source: artwork.fingerprint,
                expected_replacement: staged.expected,
            }),
            archived_relative_path: Some(archived_relative_path),
            destination_relative_path,
        }
    } else {
        let parent = item
            .relative_path
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let destination_relative_path = join_relative(parent, &format!("cover.{extension}"));
        ArtworkPlanAction {
            broker_action: BrokerAction::InstallArtwork(InstallArtworkAction {
                staging_filename: staged.filename,
                destination_root_id: item.root_id.clone(),
                destination_relative_path: destination_relative_path.clone(),
                expected: staged.expected,
            }),
            archived_relative_path: None,
            destination_relative_path,
        }
    };
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => {
            let _ = tokio::fs::remove_file(&staged.path).await;
            return ApiError::internal(request_id).into_response();
        }
    };
    match create_artwork_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        artwork_plan,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(staged.path).await;
            error.into_response()
        }
    }
}
