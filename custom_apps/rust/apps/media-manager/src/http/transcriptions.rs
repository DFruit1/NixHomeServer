use super::*;
use crate::transcription::{fs::Dir, worker::read_jobs};

#[cfg(test)]
mod boundary_tests {
    use super::*;
    // Root-run decoding and private transcripts create a concrete disclosure
    // risk. These cases must fail before any cross-owner file is returned.
    #[test]
    fn transcripts_reject_symlinks_and_cross_owner_artifacts() {
        use std::os::unix::fs::symlink;
        let temp = tempfile::Builder::new()
            .prefix("transcription-boundary-")
            .tempdir()
            .unwrap();
        let users = temp.path().join("users");
        let state = temp.path().join("state");
        std::fs::create_dir_all(users.join("alice/_Transcripts/output")).unwrap();
        std::fs::create_dir_all(state.join("users/alice")).unwrap();
        let secret = temp.path().join("secret");
        std::fs::write(&secret, "private outside file").unwrap();
        let job = "a".repeat(64);
        std::fs::write(state.join(format!("users/alice/{job}.json")), json!({"state":"completed", "outputDir":"_Transcripts/output", "artifacts":["transcript.txt"]}).to_string()).unwrap();
        symlink(
            &secret,
            users.join("alice/_Transcripts/output/transcript.txt"),
        )
        .unwrap();
        let mut config =
            AppConfig::for_test(temp.path().to_str().unwrap(), users.to_str().unwrap());
        config.transcribe_state_dir = Some(state.clone());
        config
            .integrations
            .push(crate::config::IntegrationCapability {
                id: "transcribe".into(),
                label: "Transcription".into(),
                available: true,
                capabilities: vec!["transcription".into()],
                url: None,
            });
        let alice = Identity::try_new("alice", ["users"]).unwrap();
        let bob = Identity::try_new("bob", ["users"]).unwrap();
        assert!(artifact(&config, &alice, &job, "transcript.txt", "test").is_err());
        assert!(artifact(&config, &bob, &job, "transcript.txt", "test").is_err());
        assert!(artifact(&config, &alice, "../alice", "transcript.txt", "test").is_err());
        let dir = Dir::open(&users)
            .unwrap()
            .child("alice")
            .unwrap()
            .child("_Transcripts")
            .unwrap()
            .child("output")
            .unwrap();
        // Atomic publication replaces a malicious destination symlink instead
        // of following it and overwriting an unrelated user's file.
        dir.write("transcript.txt", b"safe transcript").unwrap();
        assert_eq!(
            std::fs::read_to_string(&secret).unwrap(),
            "private outside file"
        );
        assert_eq!(
            artifact(&config, &alice, &job, "transcript.txt", "test")
                .unwrap_or_else(|_| panic!("own transcript must be readable")),
            b"safe transcript"
        );
        assert!(dir.child("..").is_err());
        assert!(dir.file("../secret").is_err());
        assert!(read_jobs(&state, "../alice").is_err());
        config.integrations.clear();
        assert_eq!(
            enabled(&config, "test").unwrap_err().status,
            StatusCode::SERVICE_UNAVAILABLE
        );
    }
}

fn enabled(config: &AppConfig, id: &str) -> Result<std::path::PathBuf, ApiError> {
    if config
        .integrations
        .iter()
        .any(|i| i.id == "transcribe" && i.available)
        && let Some(path) = &config.transcribe_state_dir
    {
        return Ok(path.clone());
    }
    Err(ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "transcription_unavailable",
        "Local transcription is unavailable.",
        id.to_string(),
    ))
}

pub(super) async fn jobs(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let id = request_id();
    let identity = match identity_from_headers(&headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let path = match enabled(&state.config, &id) {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };
    match tokio::task::spawn_blocking(move || read_jobs(&path, &identity.username)).await {
        Ok(Ok(jobs)) => {
            Json(json!({"available": true, "jobs": jobs, "requestId": id})).into_response()
        }
        _ => ApiError::internal(id).into_response(),
    }
}

fn artifact(
    config: &AppConfig,
    identity: &Identity,
    job: &str,
    name: &str,
    id: &str,
) -> Result<Vec<u8>, ApiError> {
    let state = enabled(config, id)?;
    if job.len() != 64
        || !job.bytes().all(|b| b.is_ascii_hexdigit())
        || !matches!(
            name,
            "transcript.txt" | "subtitles.srt" | "subtitles.vtt" | "diarized.srt" | "meta.json"
        )
    {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_artifact",
            "Select a transcript artifact.",
            id.to_string(),
        ));
    }
    // The caller can never select an owner or a server-inbox job. Resolve the
    // record and artifact under separate, descriptor-contained owner roots.
    let read = || -> Result<Vec<u8>, String> {
        let records = Dir::open(&state)?
            .child("users")?
            .child(&identity.username)?;
        let data: Value =
            serde_json::from_slice(&records.read(&format!("{job}.json"), 1024 * 1024)?)
                .map_err(|_| "invalid record")?;
        if data["state"] != "completed"
            || !data["artifacts"]
                .as_array()
                .is_some_and(|files| files.iter().any(|f| f == name) || name == "meta.json")
        {
            return Err("artifact unavailable".into());
        }
        let output = data["outputDir"]
            .as_str()
            .and_then(|p| p.strip_prefix("_Transcripts/"))
            .ok_or("invalid output")?;
        Dir::open(&config.users_root)?
            .child(&identity.username)?
            .child("_Transcripts")?
            .child(output)?
            .read(name, 16 * 1024 * 1024)
    };
    read().map_err(|_| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "transcript_not_found",
            "That transcript is unavailable.",
            id.to_string(),
        )
    })
}

pub(super) async fn download(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((job, name)): Path<(String, String)>,
) -> Response {
    let id = request_id();
    let identity = match identity_from_headers(&headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let config = state.config.clone();
    let request_id = id.clone();
    let filename = name.clone();
    match tokio::task::spawn_blocking(move || {
        artifact(&config, &identity, &job, &filename, &request_id)
    })
    .await
    {
        Ok(Ok(bytes)) => (
            [
                (CONTENT_TYPE, "application/octet-stream"),
                (CACHE_CONTROL, "no-store"),
                (axum::http::header::CONTENT_DISPOSITION, "attachment"),
            ],
            bytes,
        )
            .into_response(),
        Ok(Err(e)) => e.into_response(),
        _ => ApiError::internal(id).into_response(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Install {
    job_id: String,
    artifact: String,
    language: String,
}

pub(super) async fn install(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    payload: Result<Json<Install>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let id = request_id();
    let identity = match editor_identity(&state.config, &headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    if let Err(error) = enabled(&state.config, &id) {
        return error.into_response();
    }
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_json",
                "Supply a transcript job, artifact and language.",
                id,
            )
            .into_response()
        }
    };
    if state.config.mutation_mode != MutationMode::Enabled {
        return ApiError::new(
            StatusCode::FORBIDDEN,
            "read_only",
            "Mutations are disabled.",
            id,
        )
        .into_response();
    }
    let extension = match request.artifact.as_str() {
        "subtitles.srt" | "diarized.srt" => "srt",
        "subtitles.vtt" => "vtt",
        _ => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_artifact",
                "Choose SRT or VTT subtitles.",
                id,
            )
            .into_response()
        }
    };
    let Some(language) = normalized_subtitle_language(&request.language) else {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_language",
            "Choose a subtitle language.",
            id,
        )
        .into_response();
    };
    let mut catalog = match state.catalog.open() {
        Ok(c) => c,
        Err(_) => return ApiError::internal(id).into_response(),
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item)
            if item
                .media_kind
                .supports(crate::capabilities::MediaAction::ManageSubtitles) =>
        {
            item
        }
        _ => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "video_not_found",
                "Select a visible video.",
                id,
            )
            .into_response()
        }
    };
    let bytes = match artifact(
        &state.config,
        &identity,
        &request.job_id,
        &request.artifact,
        &id,
    ) {
        Ok(b) => b,
        Err(e) => return e.into_response(),
    };
    let text = match std::str::from_utf8(&bytes) {
        Ok(s) => s,
        Err(_) => return ApiError::internal(id).into_response(),
    };
    if parse_subtitle(extension, text).is_err() {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_subtitle",
            "This transcript contains no valid subtitle cues.",
            id,
        )
        .into_response();
    }
    let staged = match stage_sidecar(&state.config, "sidecar", extension, &bytes, &id).await {
        Ok(s) => s,
        Err(e) => return e.into_response(),
    };
    let action = InstallSubtitleAction {
        staging_filename: staged.filename,
        destination_root_id: item.root_id.clone(),
        destination_relative_path: subtitle_sidecar_path(
            &item.relative_path,
            &language,
            false,
            extension,
        ),
        expected: staged.expected,
    };
    match create_subtitle_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        action,
        "transcribe",
        id,
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(staged.path).await;
            error.into_response()
        }
    }
}
