use super::*;

pub(super) async fn preview_sequence(
    state: &AppState,
    identity: &Identity,
    mut catalog: Catalog,
    request: &super::plans::PlanRequest,
    request_id: String,
) -> Response {
    if request.operation.as_object().is_none_or(|op| op.len() != 1) {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_sequence",
            "Track sequencing only accepts its operation kind.",
            request_id,
        )
        .into_response();
    }
    let unique: BTreeSet<_> = request.item_ids.iter().map(String::as_str).collect();
    let items = match catalog.catalog_items_by_id(&unique.iter().copied().collect::<Vec<_>>()) {
        Ok(items) => items,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    if unique.len() != request.item_ids.len() || items.len() != request.item_ids.len() {
        return ApiError::new(
            StatusCode::CONFLICT,
            "sequence_catalog_changed",
            "Tracks are missing or duplicated. Rescan and reload the album.",
            request_id,
        )
        .into_response();
    }
    let ordered: Vec<_> = request
        .item_ids
        .iter()
        .filter_map(|id| items.get(id).cloned())
        .collect();
    let config = state.config.clone();
    let owner = identity.clone();
    let id = request_id.clone();
    let mut prepared = match tokio::task::spawn_blocking(move || {
        crate::audio_sequence_plan::prepare_sequence(&config, &owner, &ordered, &id)
    })
    .await
    {
        Ok(Ok(prepared)) => prepared,
        Ok(Err(message)) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "sequence_preparation_failed",
                message,
                request_id,
            )
            .into_response()
        }
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let digest = sha256_hex(&serde_json::to_vec(&json!({"actor":identity.username,"request":request,"actions":prepared.actions,"expiresAt":expires_at})).expect("serializable sequence"));
    let plan_id = format!("plan-{request_id}");
    if catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json: serde_json::to_string(request).expect("serializable request"),
            expires_at,
            actions: prepared.actions.clone(),
        })
        .is_err()
    {
        return ApiError::internal(request_id).into_response();
    }
    prepared.persist();
    if catalog
        .insert_audit_event(
            &request_id,
            &identity.username,
            "track_sequence_previewed",
            Some(&plan_id),
            &json!({"digest":digest,"tracks":prepared.tracks.len()}).to_string(),
        )
        .is_err()
    {
        return ApiError::internal(request_id).into_response();
    }
    (StatusCode::CREATED,Json(json!({"id":plan_id,"digest":digest,"expiresAt":expires_at,"actions":prepared.actions,"trackSequence":prepared.tracks,"warnings":[
        "Writes track 1–N and track total N into every audio file; disc number and disc total become 1 so old disc tags cannot change this sequence.",
        "Matches filenames and M3U, M3U8, PLS, XSPF playlists to the chosen order; track-order.json records the same track/disc values. Existing ordering sidecars are archived and replaced.",
        "Original audio and replaced sidecars are retained in superseded. Audio is not re-encoded. An interrupted operation may be partial; use Activity to retry before rescanning.",
        "After completion, rescan Media Manager and refresh other players. Player libraries can retain cached order, manual queues or shuffle settings."
    ],"requestId":request_id}))).into_response()
}
