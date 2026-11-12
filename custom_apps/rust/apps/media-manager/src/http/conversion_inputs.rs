use super::*;
use crate::{
    conversion_jobs::{self as intake, Job, Options},
    transcription::fs::Dir,
};
use futures_util::StreamExt;

fn submitter(config: &AppConfig, headers: &HeaderMap, id: &str) -> Result<Identity, ApiError> {
    let identity = editor_identity(config, headers, id)?;
    if config.mutation_mode != MutationMode::Enabled {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "read_only",
            "Changes are disabled.",
            id.to_string(),
        ));
    }
    Ok(identity)
}
fn invalid(message: impl Into<String>, id: &str) -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        "invalid_conversion_input",
        message,
        id.to_string(),
    )
}
fn roots(config: &AppConfig, identity: &Identity) -> Vec<Value> {
    let mut roots: Vec<Value> = config
        .visible_roots(identity)
        .into_iter()
        .filter(|r| r.available && r.category != crate::media::LibraryCategory::Books)
        .map(|r| json!({"id":r.id,"label":r.label,"path":r.resolved_path,"category":r.category}))
        .collect();
    if config.dvd_inbox_path().is_dir() {
        roots.push(json!({"id":"dvd-inbox","label":"Shared DVD inbox","path":config.dvd_inbox_path(),"category":"iso"}));
    }
    let transcribe = config
        .users_root
        .join(&identity.username)
        .join("_Transcribe");
    if transcribe.is_dir() {
        roots.push(json!({"id":"transcription-inbox","label":"My transcription inbox","path":transcribe,"category":"transcription"}));
    }
    roots
}
pub(super) async fn jobs(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let id = request_id();
    let identity = match identity_from_headers(&headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let config = state.config.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        let jobs = intake::jobs(&config, &identity.username)?;
        Ok(json!({"jobs":jobs.iter().take(200).map(Job::view).collect::<Vec<_>>(),"roots":roots(&config, &identity),"canSubmit":identity.can_edit(&config.editor_group) && config.mutation_mode == MutationMode::Enabled,"maxUploadBytes":intake::MAX_INPUT_BYTES}))
    }).await;
    match result {
        Ok(Ok(value)) => Json(value).into_response(),
        _ => ApiError::internal(id).into_response(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Browse {
    root_id: String,
    #[serde(default)]
    path: String,
}
pub(super) async fn files(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<Browse>,
) -> Response {
    let id = request_id();
    let identity = match submitter(&state.config, &headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let Some(root) = roots(&state.config, &identity)
        .into_iter()
        .find(|r| r["id"] == query.root_id)
    else {
        return invalid("Choose an available source folder.", &id).into_response();
    };
    if intake::validate_folder(&query.path).is_err() {
        return invalid("Choose a relative folder path.", &id).into_response();
    }
    let result = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        let mut dir = Dir::open(FilePath::new(root["path"].as_str().ok_or("Invalid root")?))?;
        for component in query.path.split('/').filter(|p| !p.is_empty()) {
            dir = dir.child(component)?;
        }
        let mut entries = Vec::new();
        let mut truncated = false;
        for name in dir.names()? {
            let directory = dir.child(&name).is_ok();
            if !directory
                && crate::transcription::media_stem(&name).is_none()
                && !name.to_ascii_lowercase().ends_with(".iso")
            {
                continue;
            }
            if !directory && dir.file(&name).is_err() {
                continue;
            }
            if entries.len() == 200 {
                truncated = true;
                break;
            }
            entries.push(json!({"name":name,"directory":directory}));
        }
        entries.sort_by_key(|v| {
            (
                !v["directory"].as_bool().unwrap_or(false),
                v["name"].as_str().unwrap_or_default().to_lowercase(),
            )
        });
        Ok(json!({"entries":entries,"truncated":truncated}))
    })
    .await;
    match result {
        Ok(Ok(value)) => Json(value).into_response(),
        _ => invalid(
            "This folder cannot be read. Check its path and permissions.",
            &id,
        )
        .into_response(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ServerInput {
    server_path: String,
    options: Options,
}

fn source(config: &AppConfig, identity: &Identity, path: &str) -> Result<std::fs::File, String> {
    let path = FilePath::new(path);
    for root in roots(config, identity) {
        let base = FilePath::new(root["path"].as_str().ok_or("Invalid root")?);
        if let Ok(relative) = path.strip_prefix(base) {
            let relative = relative.to_str().ok_or("Invalid file path")?;
            return open_regular_file_beneath(base, relative).map_err(|_| "Choose a regular file within your accessible server folders (symlinks are not followed).".into());
        }
    }
    Err("Choose a file in a listed shared library, your own library, or an input inbox.".into())
}
fn prepare(
    config: &AppConfig,
    identity: &Identity,
    options: &Options,
) -> Result<tempfile::NamedTempFile, String> {
    options.validate(config, identity)?;
    let active = intake::jobs(config, &identity.username)?
        .iter()
        .filter(|j| !matches!(j.state.as_str(), "completed" | "failed"))
        .count();
    if active >= 8 {
        return Err("Eight files are already waiting. Let a job finish before adding more.".into());
    }
    intake::staging_dir(config, &identity.username)?;
    tempfile::Builder::new()
        .prefix(".upload-")
        .tempfile_in(intake::staging_path(config, &identity.username))
        .map_err(|e| e.to_string())
}
fn publish(
    config: &AppConfig,
    identity: Identity,
    options: Options,
    staged: tempfile::NamedTempFile,
) -> Result<Value, String> {
    if staged
        .as_file()
        .metadata()
        .map_err(|e| e.to_string())?
        .len()
        == 0
    {
        return Err("The input file is empty.".into());
    }
    staged
        .as_file()
        .set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o660))
        .map_err(|e| e.to_string())?;
    staged.as_file().sync_all().map_err(|e| e.to_string())?;
    let job = Job::new(identity.username, options);
    let destination = intake::staging_path(config, &job.owner).join(format!("{}.source", job.id));
    staged
        .persist_noclobber(&destination)
        .map_err(|e| e.to_string())?;
    if let Err(error) = job.save(config) {
        let _ = std::fs::remove_file(destination);
        return Err(error);
    }
    Ok(json!({"job":job.view()}))
}
pub(super) async fn server_file(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    payload: Result<Json<ServerInput>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let id = request_id();
    let identity = match submitter(&state.config, &headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => {
            return invalid("Supply a server file path and processing options.", &id)
                .into_response()
        }
    };
    let config = state.config.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        let mut file = source(&config, &identity, &request.server_path)?;
        // The name is derived from the selected source, not a client rename.
        let mut options = request.options;
        options.name = FilePath::new(&request.server_path)
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Invalid file name")?
            .into();
        let before = opened_file_fingerprint(&file).map_err(|e| e.to_string())?;
        let size = file.metadata().map_err(|e| e.to_string())?.len();
        if size > intake::MAX_INPUT_BYTES {
            return Err("Files must be no larger than 64 GiB.".into());
        }
        let mut staged = prepare(&config, &identity, &options)?;
        let copied = std::io::copy(
            &mut (&mut file).take(intake::MAX_INPUT_BYTES + 1),
            staged.as_file_mut(),
        )
        .map_err(|e| e.to_string())?;
        if copied > intake::MAX_INPUT_BYTES
            || opened_file_fingerprint(&file).map_err(|e| e.to_string())? != before
        {
            return Err(
                "The source changed while it was being copied. Wait until it is complete.".into(),
            );
        }
        publish(&config, identity, options, staged)
    })
    .await;
    match result {
        Ok(Ok(body)) => (StatusCode::ACCEPTED, Json(body)).into_response(),
        Ok(Err(error)) => invalid(error, &id).into_response(),
        Err(_) => ApiError::internal(id).into_response(),
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Upload {
    options: String,
}
pub(super) async fn upload(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<Upload>,
    body: Body,
) -> Response {
    let id = request_id();
    let identity = match submitter(&state.config, &headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let options: Options = match serde_json::from_str(&query.options) {
        Ok(o) => o,
        Err(_) => return invalid("Choose file processing options.", &id).into_response(),
    };
    if headers
        .get(axum::http::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .is_some_and(|v| v > intake::MAX_INPUT_BYTES)
    {
        return ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "file_too_large",
            "Files must be no larger than 64 GiB.",
            id,
        )
        .into_response();
    }
    let staged = match prepare(&state.config, &identity, &options) {
        Ok(s) => s,
        Err(e) => return invalid(e, &id).into_response(),
    };
    let mut file = match staged.reopen() {
        Ok(f) => tokio::fs::File::from_std(f),
        Err(_) => return ApiError::internal(id).into_response(),
    };
    let mut stream = body.into_data_stream();
    let mut size = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(_) => {
                return invalid(
                    "The upload was interrupted. Select the file and try again.",
                    &id,
                )
                .into_response()
            }
        };
        size += chunk.len() as u64;
        if size > intake::MAX_INPUT_BYTES {
            return ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "file_too_large",
                "Files must be no larger than 64 GiB.",
                id,
            )
            .into_response();
        }
        if file.write_all(&chunk).await.is_err() {
            return invalid(
                "The upload could not be stored. Check server free space.",
                &id,
            )
            .into_response();
        }
    }
    if file.sync_all().await.is_err() {
        return ApiError::internal(id).into_response();
    }
    drop(file);
    match publish(&state.config, identity, options, staged) {
        Ok(body) => (StatusCode::ACCEPTED, Json(body)).into_response(),
        Err(error) => invalid(error, &id).into_response(),
    }
}

#[cfg(test)]
mod safety_tests {
    use super::*;
    use std::os::unix::fs::symlink;

    // New server-file reads could disclose another user's private data. Keep
    // explicit coverage of the containment boundary, including directory links.
    #[test]
    fn conversion_source_rejects_other_owners_and_symlink_escapes() {
        let temp = tempfile::tempdir().unwrap();
        let shared = temp.path().join("shared");
        let users = temp.path().join("users");
        std::fs::create_dir_all(shared.join("_Videos")).unwrap();
        std::fs::create_dir_all(users.join("alice/_Music")).unwrap();
        std::fs::create_dir_all(users.join("bob/_Music")).unwrap();
        let private = users.join("bob/_Music/private.mp3");
        std::fs::write(&private, b"private recording").unwrap();
        let own = users.join("alice/_Music/own.mp3");
        std::fs::write(&own, b"own recording").unwrap();
        symlink(&private, shared.join("_Videos/link.mp4")).unwrap();
        symlink(users.join("bob/_Music"), users.join("alice/_Music/linked")).unwrap();
        let config = AppConfig::for_test(shared.to_str().unwrap(), users.to_str().unwrap());
        let alice = Identity::try_new("alice", ["users"]).unwrap();
        assert!(source(&config, &alice, own.to_str().unwrap()).is_ok());
        for path in [
            private,
            shared.join("_Videos/link.mp4"),
            users.join("alice/_Music/linked/private.mp3"),
            users.join("alice/_Music/../../bob/_Music/private.mp3"),
        ] {
            assert!(
                source(&config, &alice, path.to_str().unwrap()).is_err(),
                "{}",
                path.display()
            );
        }
    }
}
