use super::*;
use crate::held_disc_rename::{self, Fingerprint, Refusal};

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
            "needsIdentification": [],
            "requestId": request_id,
        }))
        .into_response();
    }
    let mut groups = Vec::with_capacity(4);
    let shared_root = state.config.shared_root.clone();
    for (key, directory) in [
        ("pending", inbox.clone()),
        ("processed", inbox.join("_Processed")),
        ("failed", inbox.join("_Failed")),
        ("needsIdentification", inbox.join("_NeedsIdentification")),
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
    // Show each held disc's pending, refused or just-applied rename beside it.
    let config = state.config.clone();
    let renames = tokio::task::spawn_blocking(move || held_disc_rename::statuses(&config))
        .await
        .unwrap_or_default();
    for entry in groups[3].1.iter_mut() {
        let name = entry["name"].as_str().unwrap_or_default().to_owned();
        let latest = renames
            .iter()
            .rev()
            .find(|request| match request.state.as_str() {
                "applied" => request.to == name,
                _ => request.from == name,
            });
        if let Some(request) = latest {
            entry["rename"] = json!({
                "state": request.state,
                "name": request.to,
                "error": request.error,
            });
        }
    }
    let mut body = json!({
        "available": true,
        "pending": groups[0].1,
        "processed": groups[1].1,
        "failed": groups[2].1,
        "needsIdentification": groups[3].1,
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
                if let Ok(content) = tokio::fs::read_to_string(&manifest_path).await
                    && let Ok(manifest) = serde_json::from_str::<Value>(&content)
                {
                    // Newer manifests name the exact movie or season folder;
                    // older ones only record the library root.
                    let output_dir = manifest["mediaDir"]
                        .as_str()
                        .filter(|dir| !dir.is_empty())
                        .or_else(|| manifest["outputDir"].as_str())
                        .unwrap_or_default();
                    let relative = output_dir
                        .strip_prefix(shared_root.to_string_lossy().as_ref())
                        .unwrap_or(output_dir)
                        .trim_start_matches('/');
                    iso_entry["outputDir"] = json!(relative);
                    if let Some(finished) = file_modified_ns(&manifest_path).await {
                        iso_entry["finishedNs"] = json!(finished);
                    }
                }
            }
            "failed" => {
                let error_path = entry.path().with_extension("iso.error.txt");
                if error_path.exists() {
                    iso_entry["hasErrorLog"] = json!(true);
                    if let Some(finished) = file_modified_ns(&error_path).await {
                        iso_entry["finishedNs"] = json!(finished);
                    }
                }
                if let Some(report) = failure_report(&entry.path()).await {
                    iso_entry["failureSummary"] = json!(report.summary);
                    if let Some(hint) = report.hint {
                        iso_entry["failureHint"] = json!(hint);
                    }
                }
            }
            "needsIdentification" => {
                let sidecar_path = directory.join(format!("{name}.identify.json"));
                if let Some(report) = identification_report(&sidecar_path, shared_root).await {
                    for (key, value) in [
                        ("heldDir", report.held_dir),
                        ("summary", report.summary),
                        ("suggestedName", report.suggested_name),
                    ] {
                        if let Some(value) = value {
                            iso_entry[key] = json!(value);
                        }
                    }
                    if let Some(finished) = report.finished_ns {
                        iso_entry["finishedNs"] = json!(finished);
                    }
                }
            }
            _ => {}
        }
        entries.push(iso_entry);
        if entries.len() >= MAX_INBOX_ENTRIES {
            break;
        }
    }
    if context == "pending" {
        entries.sort_by(|left, right| {
            left["name"]
                .as_str()
                .unwrap_or_default()
                .cmp(right["name"].as_str().unwrap_or_default())
        });
    } else {
        // Finished work reads newest first so the latest result is at the top.
        let finished = |entry: &Value| {
            entry["finishedNs"]
                .as_i64()
                .unwrap_or_else(|| entry["modifiedNs"].as_i64().unwrap_or(0))
        };
        entries.sort_by_key(|entry| std::cmp::Reverse(finished(entry)));
    }
    Ok(entries)
}

async fn file_modified_ns(path: &FilePath) -> Option<i64> {
    let modified = tokio::fs::metadata(path).await.ok()?.modified().ok()?;
    let duration = modified.duration_since(UNIX_EPOCH).ok()?;
    Some(duration.as_nanos().min(i64::MAX as u128) as i64)
}

/// The importer's sidecar for a disc it encoded but could not match to
/// episodes. Every field is optional and bounded: the file sits in a
/// user-writable share, so it is display data and never a path to follow.
struct IdentificationReport {
    held_dir: Option<String>,
    summary: Option<String>,
    suggested_name: Option<String>,
    finished_ns: Option<i64>,
}

const MAX_IDENTIFY_SIDECAR_BYTES: u64 = 64 * 1024;

async fn identification_report(
    sidecar_path: &FilePath,
    shared_root: &FilePath,
) -> Option<IdentificationReport> {
    let metadata = tokio::fs::symlink_metadata(sidecar_path).await.ok()?;
    if !metadata.is_file() || metadata.len() > MAX_IDENTIFY_SIDECAR_BYTES {
        return None;
    }
    let content = tokio::fs::read(sidecar_path).await.ok()?;
    let report = serde_json::from_slice::<Value>(&content).ok()?;
    let finished_ns = match report["finishedAt"]
        .as_i64()
        .filter(|seconds| (1..=i64::MAX / 1_000_000_000).contains(seconds))
    {
        Some(seconds) => Some(seconds * 1_000_000_000),
        None => file_modified_ns(sidecar_path).await,
    };
    Some(parse_identification_report(
        &report,
        &shared_root.to_string_lossy(),
        finished_ns,
    ))
}

fn parse_identification_report(
    report: &Value,
    shared_root: &str,
    finished_ns: Option<i64>,
) -> IdentificationReport {
    let text = |value: &Value, limit: usize| {
        value
            .as_str()
            .map(|text| text.trim())
            .filter(|text| !text.is_empty() && text.len() <= limit && !text.contains('\0'))
            .map(str::to_owned)
    };
    // The schema records the folder relative to the shared root; accept an
    // absolute path under it too, as the processed manifests do.
    let held_dir = text(&report["heldDir"], 1024)
        .map(|dir| {
            dir.strip_prefix(shared_root.trim_end_matches('/'))
                .filter(|rest| rest.starts_with('/'))
                .unwrap_or(&dir)
                .trim_matches('/')
                .to_owned()
        })
        .filter(|dir| {
            !dir.is_empty()
                && dir
                    .split('/')
                    .all(|part| !part.is_empty() && part != "." && part != "..")
        });
    let suggested_name = text(&report["suggestion"]["isoName"], 255)
        .filter(|name| !name.contains('/') && name.to_ascii_lowercase().ends_with(".iso"));
    IdentificationReport {
        held_dir,
        summary: text(&report["summary"], 1000),
        suggested_name,
        finished_ns,
    }
}

struct FailureReport {
    summary: String,
    hint: Option<String>,
    details: Option<String>,
}

/// The worker's structured report, or a best-effort reading of older text logs.
async fn failure_report(iso_path: &FilePath) -> Option<FailureReport> {
    let structured = iso_path.with_extension("iso.error.json");
    if let Ok(content) = tokio::fs::read_to_string(&structured).await
        && let Ok(report) = serde_json::from_str::<Value>(&content)
        && let Some(summary) = report["summary"].as_str().filter(|s| !s.is_empty())
    {
        return Some(FailureReport {
            summary: summary.to_owned(),
            hint: report["hint"].as_str().map(str::to_owned),
            details: report["details"].as_str().map(str::to_owned),
        });
    }
    let log = tokio::fs::read_to_string(iso_path.with_extension("iso.error.txt"))
        .await
        .ok()?;
    Some(legacy_failure_report(&log))
}

fn legacy_failure_report(log: &str) -> FailureReport {
    let first = log.lines().map(str::trim).find(|line| !line.is_empty());
    match first {
        Some(line) if line.starts_with("Command '") && line.contains("returned non-zero exit") => {
            FailureReport {
                summary: "The converter stopped with an error.".to_owned(),
                hint: Some(
                    "This older failure did not save the converter's reason. Move the ISO \
                     from _ISO/_DVDs/_Failed back into _ISO/_DVDs to retry and record it."
                        .to_owned(),
                ),
                details: None,
            }
        }
        Some(line) => FailureReport {
            summary: line.chars().take(300).collect(),
            hint: None,
            details: None,
        },
        None => FailureReport {
            summary: "The conversion failed without a recorded reason.".to_owned(),
            hint: None,
            details: None,
        },
    }
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
    let iso_path = state
        .config
        .dvd_inbox_path()
        .join("_Failed")
        .join(&query.name);
    let error_path = iso_path.with_extension("iso.error.txt");
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
        Ok(content) => {
            // The list already shows the summary and next step; the dialog
            // needs only the converter's own output beneath them.
            let content = failure_report(&iso_path)
                .await
                .and_then(|report| report.details)
                .unwrap_or(content);
            Json(json!({ "content": content, "requestId": request_id })).into_response()
        }
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct IdentifyRequest {
    name: String,
    size_bytes: u64,
    modified_ns: i64,
    new_name: String,
}

/// Confirm a held TV disc by giving its ISO the episode name the importer
/// publishes from. The web service only checks and queues; the filesystem
/// broker repeats the checks and renames within _NeedsIdentification.
pub(super) async fn identify_held_disc(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    payload: Result<Json<IdentifyRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if state.config.mutation_mode != MutationMode::Enabled {
        return ApiError::new(
            StatusCode::FORBIDDEN,
            "read_only",
            "Changes are disabled.",
            request_id,
        )
        .into_response();
    }
    let Ok(Json(request)) = payload else {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_identify_name",
            "Supply the disc's current name, size, modification time and new name.",
            request_id,
        )
        .into_response();
    };
    let config = state.config.clone();
    let queued = tokio::task::spawn_blocking(move || {
        held_disc_rename::queue(
            &config,
            &identity,
            &request.name,
            &request.new_name,
            Fingerprint {
                size_bytes: request.size_bytes,
                modified_ns: request.modified_ns,
                inode: None,
            },
        )
    })
    .await;
    match queued {
        Ok(Ok(queued)) => {
            log_event(
                "held_disc_rename_queued",
                &request_id,
                json!({ "from": queued.from, "to": queued.to, "owner": queued.owner }),
            );
            (
                StatusCode::ACCEPTED,
                Json(json!({
                    "rename": { "state": queued.state, "name": queued.to, "error": null },
                    "requestId": request_id,
                })),
            )
                .into_response()
        }
        Ok(Err(refusal)) => {
            let (status, code) = match refusal {
                Refusal::Invalid(_) => (StatusCode::BAD_REQUEST, "invalid_identify_name"),
                Refusal::Conflict(_) => (StatusCode::CONFLICT, "held_disc_conflict"),
                Refusal::Missing(_) => (StatusCode::NOT_FOUND, "held_disc_missing"),
            };
            ApiError::new(status, code, refusal.message(), request_id).into_response()
        }
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

const MAX_AUDIOBOOK_STATUS_BYTES: u64 = 1024 * 1024;
const MAX_AUDIOBOOK_SETS: usize = 200;

/// Audiobook CD sets that wait for discs or for a person, from the audio CD
/// importer's status file. The file is written by another service, so every
/// field is bounded display data and never a path to follow. The shared
/// inbox is shown to everyone; a personal inbox only to its owner.
pub(super) async fn audiobook_inbox(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let unavailable = || Json(json!({ "available": false, "books": [] })).into_response();
    let status = match tokio::fs::metadata(&state.config.audiocd_status_file).await {
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAX_AUDIOBOOK_STATUS_BYTES => {
            match tokio::fs::read(&state.config.audiocd_status_file).await {
                Ok(bytes) => serde_json::from_slice::<Value>(&bytes).ok(),
                Err(_) => None,
            }
        }
        _ => None,
    };
    let Some(status) = status else {
        return unavailable();
    };
    let text = |value: &Value, limit: usize| {
        value
            .as_str()
            .map(str::trim)
            .filter(|text| !text.is_empty() && text.len() <= limit && !text.contains('\0'))
            .map(str::to_owned)
    };
    let visible = |inbox: &Value| match inbox.as_str() {
        Some("Shared") => Some(true),
        Some(owner) if owner == identity.username => Some(false),
        _ => None,
    };
    let config = state.config.clone();
    let renames = tokio::task::spawn_blocking(move || crate::held_book_rename::statuses(&config))
        .await
        .unwrap_or_default();
    let needs_folder = state
        .config
        .audio_inbox_path()
        .join(held_disc_rename::NEEDS_IDENTIFICATION);
    let mut books = Vec::new();
    for set in status["sets"].as_array().into_iter().flatten() {
        let (Some(shared), Some(folder), Some(set_state)) = (
            visible(&set["inbox"]),
            text(&set["folder"], 255).filter(|folder| !folder.contains('/')),
            text(&set["state"], 16),
        ) else {
            continue;
        };
        if !matches!(set_state.as_str(), "held" | "waiting" | "retrying") {
            continue;
        }
        let mut book = json!({
            "inbox": if shared { "shared" } else { "personal" },
            "folder": folder,
            "state": set_state,
            "message": text(&set["message"], 1000).unwrap_or_default(),
            "discs": set["discs"].as_u64().unwrap_or(0).min(99),
        });
        let missing: Vec<u64> = set["missingDiscs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_u64)
            .filter(|disc| (1..=99).contains(disc))
            .take(99)
            .collect();
        if !missing.is_empty() {
            book["missingDiscs"] = json!(missing);
        }
        if let Some(name) = text(&set["confirmWith"], 255).filter(|name| !name.contains('/')) {
            book["confirmWith"] = json!(name);
        }
        if shared && set_state == "held" {
            // The folder's inode lets the confirmation refuse a book that
            // was replaced after the page loaded.
            if let Ok(metadata) = tokio::fs::symlink_metadata(needs_folder.join(&folder)).await
                && metadata.is_dir()
            {
                use std::os::unix::fs::MetadataExt;
                book["folderId"] = json!(metadata.ino().to_string());
            }
            let latest = renames
                .iter()
                .rev()
                .find(|request| match request.state.as_str() {
                    "applied" => request.to == folder,
                    _ => request.from == folder,
                });
            if let Some(request) = latest {
                book["rename"] = json!({
                    "state": request.state,
                    "name": request.to,
                    "error": request.error,
                });
            }
        }
        books.push(book);
        if books.len() >= MAX_AUDIOBOOK_SETS {
            break;
        }
    }
    let order = |book: &Value| match book["state"].as_str() {
        Some("held") => 0,
        Some("waiting") => 1,
        _ => 2,
    };
    books.sort_by_key(order);
    let mut body = json!({ "available": true, "books": books, "requestId": request_id });
    let active = &status["active"];
    if visible(&active["inbox"]).is_some()
        && let Some(folder) = text(&active["folder"], 255)
    {
        body["active"] = json!({
            "folder": folder,
            "step": text(&active["step"], 80).unwrap_or_else(|| "Working".to_owned()),
            "percent": active["percent"].as_f64().map(|percent| percent.clamp(0.0, 100.0)),
        });
    }
    if let Some(ref base_url) = state.config.files_base_url {
        body["filesBaseUrl"] = json!(base_url);
    }
    Json(body).into_response()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ConfirmAudiobookRequest {
    folder: String,
    /// The folder's identity as listed; a replaced folder is refused.
    folder_id: String,
    name: String,
}

/// Confirm a held audiobook by giving its folder the name the importer
/// publishes from. The web service only checks and queues; the filesystem
/// broker repeats the checks and renames within _NeedsIdentification.
pub(super) async fn confirm_held_audiobook(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    payload: Result<Json<ConfirmAudiobookRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if state.config.mutation_mode != MutationMode::Enabled {
        return ApiError::new(
            StatusCode::FORBIDDEN,
            "read_only",
            "Changes are disabled.",
            request_id,
        )
        .into_response();
    }
    let request = payload.ok().and_then(|Json(request)| {
        let folder_id = request.folder_id.parse::<u64>().ok()?;
        Some((request.folder, request.name, folder_id))
    });
    let Some((folder, name, folder_id)) = request else {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_audiobook_name",
            "Supply the book's current folder, its listed identity and the new name.",
            request_id,
        )
        .into_response();
    };
    let config = state.config.clone();
    let queued = tokio::task::spawn_blocking(move || {
        crate::held_book_rename::queue(&config, &identity, &folder, &name, Some(folder_id))
    })
    .await;
    match queued {
        Ok(Ok(queued)) => {
            log_event(
                "held_book_rename_queued",
                &request_id,
                json!({ "from": queued.from, "to": queued.to, "owner": queued.owner }),
            );
            (
                StatusCode::ACCEPTED,
                Json(json!({
                    "rename": { "state": queued.state, "name": queued.to, "error": null },
                    "requestId": request_id,
                })),
            )
                .into_response()
        }
        Ok(Err(refusal)) => {
            let (status, code) = match refusal {
                Refusal::Invalid(_) => (StatusCode::BAD_REQUEST, "invalid_audiobook_name"),
                Refusal::Conflict(_) => (StatusCode::CONFLICT, "held_audiobook_conflict"),
                Refusal::Missing(_) => (StatusCode::NOT_FOUND, "held_audiobook_missing"),
            };
            ApiError::new(status, code, refusal.message(), request_id).into_response()
        }
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}
