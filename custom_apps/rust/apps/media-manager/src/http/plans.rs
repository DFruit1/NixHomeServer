use super::*;

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PlanRequest {
    operation: Value,
    item_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ScanRequest {
    root_id: String,
}

pub(super) async fn scan(
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

pub(super) async fn preview_plan(
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

pub(super) async fn confirm_plan(
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

pub(super) async fn plan_status(
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
