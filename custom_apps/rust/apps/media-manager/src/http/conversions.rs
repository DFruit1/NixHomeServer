use super::*;

pub(super) async fn conversions(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    match tokio::fs::read(&state.config.mkvmaker_progress_file).await {
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
            Ok(progress) => {
                Json(json!({ "available": true, "progress": progress })).into_response()
            }
            Err(error) => {
                log_event(
                    "mkvmaker_progress_invalid",
                    &request_id,
                    json!({ "error": error.to_string() }),
                );
                ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "integration_payload_invalid",
                    "MKVMaker reported invalid progress data.",
                    request_id,
                )
                .into_response()
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Json(json!({
            "available": false,
            "progress": { "schemaVersion": 1, "state": "unavailable", "conversions": [] },
        }))
        .into_response(),
        Err(error) => {
            log_event(
                "mkvmaker_progress_read_failed",
                &request_id,
                json!({ "errorKind": error.kind().to_string() }),
            );
            ApiError::internal(request_id).into_response()
        }
    }
}

pub(super) async fn conversions_inbox(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    let inbox = state.config.dvd_inbox_path();
    if !inbox.is_dir() {
        return Json(json!({
            "available": false,
            "pending": [],
            "processed": [],
            "failed": [],
            "requestId": request_id,
        }))
        .into_response();
    }
    let mut groups = Vec::with_capacity(3);
    let shared_root = state.config.shared_root.clone();
    for (key, directory) in [
        ("pending", inbox.clone()),
        ("processed", inbox.join("_Processed")),
        ("failed", inbox.join("_Failed")),
    ] {
        match list_iso_directory(&directory, key, &shared_root, &request_id).await {
            Ok(entries) => groups.push((key, entries)),
            Err(error) => {
                log_event(
                    "iso_inbox_read_failed",
                    &request_id,
                    json!({ "directory": key, "error": error }),
                );
                return ApiError::internal(request_id).into_response();
            }
        }
    }
    let mut body = json!({
        "available": true,
        "pending": groups[0].1,
        "processed": groups[1].1,
        "failed": groups[2].1,
        "requestId": request_id,
    });
    if let Some(ref base_url) = state.config.files_base_url {
        body["filesBaseUrl"] = json!(base_url);
    }
    Json(body).into_response()
}

async fn list_iso_directory(
    directory: &FilePath,
    context: &str,
    shared_root: &FilePath,
    request_id: &str,
) -> Result<Vec<Value>, String> {
    let mut entries = Vec::new();
    let mut read_dir = match tokio::fs::read_dir(directory).await {
        Ok(read_dir) => read_dir,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(entries),
        Err(error) => return Err(error.to_string()),
    };
    while let Some(entry) = read_dir
        .next_entry()
        .await
        .map_err(|error| error.to_string())?
    {
        let file_type = entry.file_type().await.map_err(|error| error.to_string())?;
        if !file_type.is_file() || file_type.is_symlink() {
            continue;
        }
        let name = match entry.file_name().into_string() {
            Ok(name)
                if name.len() <= 255
                    && !name.contains('/')
                    && name.to_ascii_lowercase().ends_with(".iso") =>
            {
                name
            }
            _ => continue,
        };
        let metadata = entry.metadata().await.map_err(|error| error.to_string())?;
        let modified_ns = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
            .unwrap_or(0);
        let volume_id = iso_volume_id(&entry.path(), request_id).await;
        let mut iso_entry = json!({
            "name": name,
            "volumeId": volume_id,
            "sizeBytes": metadata.len().min(i64::MAX as u64) as i64,
            "modifiedNs": modified_ns,
        });
        match context {
            "processed" => {
                let manifest_path = entry.path().with_extension("iso.output.json");
                if let Ok(content) = tokio::fs::read_to_string(&manifest_path).await {
                    if let Ok(manifest) = serde_json::from_str::<Value>(&content) {
                        let output_dir = manifest["outputDir"].as_str().unwrap_or_default();
                        let relative = output_dir
                            .strip_prefix(shared_root.to_string_lossy().as_ref())
                            .unwrap_or(output_dir)
                            .trim_start_matches('/');
                        iso_entry["outputDir"] = json!(relative);
                    }
                }
            }
            "failed" => {
                let error_path = entry.path().with_extension("iso.error.txt");
                if error_path.exists() {
                    iso_entry["hasErrorLog"] = json!(true);
                }
            }
            _ => {}
        }
        entries.push(iso_entry);
        if entries.len() >= MAX_INBOX_ENTRIES {
            break;
        }
    }
    entries.sort_by(|left, right| {
        left["name"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["name"].as_str().unwrap_or_default())
    });
    Ok(entries)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct InboxErrorQuery {
    name: String,
}

pub(super) async fn conversions_inbox_error(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<InboxErrorQuery>,
) -> Response {
    let request_id = request_id();
    if let Err(error) = identity_from_headers(&headers, &request_id) {
        return error.into_response();
    }
    if query.name.contains('/') || query.name.contains("..") || query.name.is_empty() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_name",
            "The file name is not valid.",
            request_id,
        )
        .into_response();
    }
    let error_path = state
        .config
        .dvd_inbox_path()
        .join("_Failed")
        .join(&query.name)
        .with_extension("iso.error.txt");
    if !error_path.exists() {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "error_log_missing",
            "No error log was found.",
            request_id,
        )
        .into_response();
    }
    match tokio::fs::read_to_string(&error_path).await {
        Ok(content) => Json(json!({ "content": content, "requestId": request_id })).into_response(),
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

async fn iso_volume_id(path: &FilePath, request_id: &str) -> Option<String> {
    const SECTOR_SIZE: u64 = 2048;
    const PRIMARY_VOLUME_SECTOR: u64 = 16;
    let mut file = tokio::fs::File::open(path).await.ok()?;
    if file.metadata().await.ok()?.len() < (PRIMARY_VOLUME_SECTOR + 1) * SECTOR_SIZE {
        return None;
    }
    file.seek(std::io::SeekFrom::Start(
        PRIMARY_VOLUME_SECTOR * SECTOR_SIZE,
    ))
    .await
    .ok()?;
    let mut sector = [0u8; SECTOR_SIZE as usize];
    file.read_exact(&mut sector).await.ok()?;
    if sector[0] != 1 || &sector[1..6] != b"CD001" || sector[6] != 1 {
        return None;
    }
    let volume_id: String = sector[40..72]
        .iter()
        .map(|byte| {
            if byte.is_ascii_graphic() || *byte == b' ' {
                *byte as char
            } else {
                ' '
            }
        })
        .collect::<String>()
        .trim()
        .to_string();
    if volume_id.is_empty() {
        log_event(
            "iso_volume_id_missing",
            request_id,
            json!({ "path": path.display().to_string() }),
        );
        return None;
    }
    Some(volume_id)
}
