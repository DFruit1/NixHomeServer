use super::*;

pub(super) async fn queue_integration_refresh(
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

pub(super) async fn integration_refresh_status(
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
