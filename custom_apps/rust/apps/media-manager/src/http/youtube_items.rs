//! YouTube downloads: what the downloader recorded about an item, and the
//! confirmable plans that split, join, re-cover or move it. See
//! `crate::youtube_item`.
use super::*;
use crate::youtube_item::{self, Change, Located, Tools};

pub(super) const OPERATION_KIND: &str = "youtube_item";

fn not_youtube(request_id: String) -> Response {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_a_youtube_download",
        "This item was not downloaded by the YouTube Downloader, or its manifest is missing.",
        request_id,
    )
    .into_response()
}

/// The item's manifest, found beside it in a library the caller can see.
fn locate_item(
    config: &AppConfig,
    identity: &Identity,
    catalog: &Catalog,
    item_id: &str,
) -> Result<Option<(CatalogItem, Located)>, ApiError> {
    let item = visible_catalog_item(config, identity, catalog, item_id)?;
    let Some(root) = config
        .resolve_visible_root(identity, &item.root_id)
        .filter(|root| root.available)
    else {
        return Ok(None);
    };
    match youtube_item::locate(&root, &item.relative_path) {
        Ok(Some(located)) => Ok(Some((item, located))),
        Ok(None) => Ok(None),
        Err(_) => Err(ApiError::internal(String::new())),
    }
}

pub(super) async fn details(
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
        return not_youtube(request_id);
    }
    let config = state.config.clone();
    let catalog = state.catalog.clone();
    let lookup = identity.clone();
    let found = tokio::task::spawn_blocking(move || -> Result<Option<Value>, ApiError> {
        let catalog = catalog
            .open()
            .map_err(|_| ApiError::internal(String::new()))?;
        let Some((item, located)) = locate_item(&config, &lookup, &catalog, &item_id)? else {
            return Ok(None);
        };
        let manifest = &located.manifest;
        let root_path = FilePath::new(&located.root.resolved_path);
        let files = manifest
            .files
            .iter()
            .map(|file| {
                json!({
                    "path": file.path,
                    "role": file.role,
                    "chapter": file.chapter,
                    "start": file.start,
                    "end": file.end,
                    "present": std::fs::symlink_metadata(
                        root_path.join(join_relative(&located.folder, &file.path))
                    )
                    .is_ok(),
                })
            })
            .collect::<Vec<_>>();
        let libraries = config
            .visible_roots(&lookup)
            .into_iter()
            .filter(|root| youtube_item::compatible_roots(&located.root, root))
            .map(|root| json!({ "id": root.id, "label": root.label, "category": root.category.as_str() }))
            .collect::<Vec<_>>();
        let layout = youtube_item::describe_layout(&located);
        Ok(Some(json!({
            "itemId": item.id,
            "rootId": located.root.id,
            "rootLabel": located.root.label,
            "folder": located.folder,
            "layout": layout["layout"],
            "collection": layout["collection"],
            "mediaType": manifest.media_type(),
            "source": {
                "title": manifest.source.title,
                "url": manifest.source.url,
                "id": manifest.source.id,
                "channel": manifest.source.channel.as_deref().or(manifest.source.uploader.as_deref()),
                "uploadDate": manifest.naming.date,
                "durationSeconds": manifest.source.duration_seconds,
            },
            "naming": { "title": manifest.naming.title, "channel": manifest.naming.channel },
            "chapters": manifest.chapters,
            "state": manifest.state,
            "lossless": manifest.original.is_some(),
            "exactRestore": located.exact_restore(),
            "files": files,
            "hasThumbnail": manifest.has_thumbnail,
            "downloadedAt": manifest.download["downloadedAt"],
            "downloadOptions": manifest.download["options"],
            "history": manifest.history,
            "changes": youtube_item::available_changes(&located, Tools::from_config(&config).is_some()),
            "libraries": libraries,
            "canEdit": lookup.can_edit(&config.editor_group)
                && config.mutation_mode == MutationMode::Enabled,
        })))
    })
    .await;
    match found {
        Ok(Ok(Some(body))) => Json(body).into_response(),
        Ok(Ok(None)) => not_youtube(request_id),
        Ok(Err(error)) => error.with_request_id(request_id).into_response(),
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

/// Preview one change to one YouTube download. Splits, joins and cover
/// changes are prepared and verified here, so the preview can take as long as
/// copying the item's media once or twice.
pub(super) async fn preview(
    state: &AppState,
    identity: &Identity,
    mut catalog: Catalog,
    request: &super::plans::PlanRequest,
    request_id: String,
) -> Response {
    let invalid = |message: &str| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_youtube_change",
            message.to_string(),
            request_id.clone(),
        )
        .into_response()
    };
    if request.item_ids.len() != 1 {
        return invalid("Change one YouTube download at a time.");
    }
    let mut operation = request.operation.clone();
    if let Some(object) = operation.as_object_mut() {
        object.remove("kind");
    }
    let Ok(change) = serde_json::from_value::<Change>(operation) else {
        return invalid("Choose split, join, embed-cover, remove-cover or move.");
    };
    let (_, located) = match locate_item(&state.config, identity, &catalog, &request.item_ids[0]) {
        Ok(Some(found)) => found,
        Ok(None) => return not_youtube(request_id),
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let destination_root = match &change {
        Change::Move {
            destination_root_id: Some(root_id),
            ..
        } => match state
            .config
            .resolve_visible_root(identity, root_id)
            .filter(|root| youtube_item::compatible_roots(&located.root, root))
        {
            Some(root) => Some(root),
            None => {
                return ApiError::new(
                    StatusCode::FORBIDDEN,
                    "destination_root_not_available",
                    "That library is not available for this item.",
                    request_id,
                )
                .into_response()
            }
        },
        _ => None,
    };
    let tools = Tools::from_config(&state.config);
    let prepared = match youtube_item::prepare(
        &state.config,
        tools.as_ref(),
        &located,
        &change,
        &identity.username,
        destination_root.as_ref(),
        &request_id,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(message) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "youtube_change_failed",
                message,
                request_id,
            )
            .into_response()
        }
    };
    let mut prepared = prepared;
    let mut warnings = prepared.warnings.clone();
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.".into());
    }
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let actions = prepared.actions.clone();
    let digest = sha256_hex(
        &serde_json::to_vec(&json!({
            "actor": identity.username,
            "request": request,
            "actions": actions,
            "expiresAt": expires_at,
        }))
        .expect("serializable YouTube item plan"),
    );
    let plan_id = format!("plan-{request_id}");
    let created = catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json: serde_json::to_string(request).expect("serializable request"),
            expires_at,
            actions: actions.clone(),
        })
        .and_then(|_| {
            catalog.insert_audit_event(
                &request_id,
                &identity.username,
                "youtube_item_change_previewed",
                Some(&plan_id),
                &json!({ "digest": digest, "itemId": request.item_ids[0], "change": prepared.summary["change"] })
                    .to_string(),
            )
        });
    if created.is_err() {
        return ApiError::internal(request_id).into_response();
    }
    // The plan journal owns the staged files from here; expiry discards them.
    prepared.staging.persist();
    (
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "expiresAt": expires_at,
            "actions": actions,
            "warnings": warnings,
            "youtubeItem": prepared.summary,
            "requestId": request_id,
        })),
    )
        .into_response()
}
