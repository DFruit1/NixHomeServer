use super::*;
use crate::transcription::{fs::Dir, worker::read_jobs};

#[cfg(test)]
mod boundary_tests {
    use super::*;
    // Root-run decoding and private transcripts create a concrete disclosure
    // risk. These cases must fail before any cross-owner file is returned.
    // New direct reads must never disclose another owner or follow symlinks.
    #[test]
    fn personal_reader_contains_paths_and_preserves_timestamps() {
        use std::os::unix::fs::symlink;
        let temp = tempfile::tempdir().unwrap();
        let users = temp.path();
        std::fs::create_dir_all(users.join("alice/_Transcripts/output")).unwrap();
        std::fs::create_dir_all(users.join("bob/_Transcripts/private")).unwrap();
        std::fs::write(
            users.join("bob/_Transcripts/private/transcript.txt"),
            "private",
        )
        .unwrap();
        std::fs::write(
            users.join("alice/_Transcripts/output/transcript.txt"),
            "hello",
        )
        .unwrap();
        std::fs::write(
            users.join("alice/_Transcripts/output/subtitles.vtt"),
            "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n",
        )
        .unwrap();
        let read = |path| read_personal_transcript(users, "alice", path, "test");
        let result = read("_Transcripts/output/transcript.txt").unwrap();
        assert_eq!(result["cues"][0]["startMs"], 1000);
        assert_eq!(result["cues"][0]["text"], "hello");
        assert!(read("_Transcripts/../../bob/_Transcripts/private/transcript.txt").is_err());
        assert!(read("_Transcripts/private/transcript.txt").is_err());
        symlink(
            users.join("bob/_Transcripts/private"),
            users.join("alice/_Transcripts/linked"),
        )
        .unwrap();
        assert!(read("_Transcripts/linked/transcript.txt").is_err());
        symlink(
            users.join("bob/_Transcripts/private/transcript.txt"),
            users.join("alice/_Transcripts/output/leak.txt"),
        )
        .unwrap();
        std::fs::remove_file(users.join("alice/_Transcripts/output/subtitles.vtt")).unwrap();
        assert!(read("_Transcripts/output/leak.txt").is_err());
        assert_eq!(
            read("_Transcripts/output/transcript.txt").unwrap()["text"],
            "hello"
        );
    }

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
            "transcript.txt"
                | "subtitles.srt"
                | "subtitles.vtt"
                | "diarized.srt"
                | "meta.json"
                | "transcript.original.txt"
                | "words.original.json"
                | "words.cleaned.json"
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
            .traverse(&identity.username)?
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

/// Read complete timed dialogue for a visible audio/video file, without requiring
/// the transcription service or its private job history to remain enabled.
pub(super) async fn video_transcript(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let id = request_id();
    let identity = match identity_from_headers(&headers, &id) {
        Ok(i) => i,
        Err(e) => return e.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(c) => c,
        Err(_) => return ApiError::internal(id).into_response(),
    };
    let video = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item)
            if matches!(
                item.media_kind,
                MediaKind::Video | MediaKind::Music | MediaKind::Audiobook | MediaKind::Podcast
            ) =>
        {
            item
        }
        _ => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "video_not_found",
                "Select a visible audio or video file.",
                id,
            )
            .into_response()
        }
    };
    let Some(root) = state.config.resolve_visible_root(&identity, &video.root_id) else {
        return ApiError::internal(id).into_response();
    };
    let cached_subtitle = if let Some(cache) = &state.config.jellyfin_metadata_cache_file {
        metadata_handlers::cached_application_metadata(&state.metadata_memo, cache, &video, false)
            .await
            .and_then(|entry| {
                let item = entry.get("itemId")?.as_str()?;
                if item.is_empty() || !item.chars().all(|c| c.is_ascii_alphanumeric()) {
                    return None;
                }
                Some(
                    cache
                        .parent()?
                        .join("subtitles")
                        .join(format!("{item}.srt")),
                )
            })
    } else {
        None
    };
    let worker_id = id.clone();
    match tokio::task::spawn_blocking(move || -> Result<Value, String> {
        use std::io::Read;
        let (folder, leaf) = video
            .relative_path
            .rsplit_once('/')
            .unwrap_or(("", &video.relative_path));
        let mut directory = Dir::open(FilePath::new(&root.resolved_path))?;
        for part in folder.split('/').filter(|p| !p.is_empty()) {
            directory = directory.child(part)?;
        }
        let stem = leaf.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(leaf);
        let mut names = directory.names()?;
        names.sort();
        let mut candidates = vec![
            format!("{leaf}.transcript.vtt"),
            format!("{stem}.vtt"),
            format!("{stem}.srt"),
        ];
        // Match the subtitle inventory's stem + language/flag convention.
        // Prioritize generated and unqualified tracks, then use a stable order.
        candidates.extend(
            names
                .iter()
                .filter(|name| {
                    let Some((track_stem, extension)) = name.rsplit_once('.') else {
                        return false;
                    };
                    matches!(
                        extension.to_ascii_lowercase().as_str(),
                        "srt" | "vtt" | "ass" | "ssa"
                    ) && (track_stem == stem || track_stem.starts_with(&format!("{stem}.")))
                })
                .cloned(),
        );
        let (mut file, format) =
            if let Some(name) = candidates.iter().find(|name| names.contains(name)) {
                (
                    directory.file(name)?,
                    name.rsplit_once('.')
                        .map(|(_, extension)| extension)
                        .unwrap_or("vtt"),
                )
            } else if let Some(path) = cached_subtitle.filter(|path| path.is_file()) {
                let parent = Dir::open(path.parent().ok_or("Invalid subtitle path")?)?;
                (
                    parent.file(
                        path.file_name()
                            .and_then(|n| n.to_str())
                            .ok_or("Invalid subtitle name")?,
                    )?,
                    "srt",
                )
            } else {
                return Ok(json!({"cues": [], "requestId": worker_id}));
            };
        let mut bytes = Vec::new();
        file.by_ref()
            .take(MAX_SUBTITLE_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_SUBTITLE_BYTES {
            return Err("Transcript exceeds preview limit".into());
        }
        let text = std::str::from_utf8(&bytes).map_err(|_| "Invalid transcript encoding")?;
        let cues = parse_subtitle(format, text)?;
        Ok(json!({"cues": cues, "requestId": worker_id}))
    })
    .await
    {
        Ok(Ok(body)) => ([(CACHE_CONTROL, "no-store")], Json(body)).into_response(),
        _ => ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "transcript_unreadable",
            "The transcript could not be read.",
            id,
        )
        .into_response(),
    }
}

// Only the signed-in user's completed transcript directory is readable here.
// Descriptor traversal rejects symlinks and parent components at every level.
#[derive(Deserialize)]
pub(super) struct TranscriptFileQuery {
    path: String,
}

pub(super) async fn transcript_file(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<TranscriptFileQuery>,
) -> Response {
    let id = request_id();
    let identity = match identity_from_headers(&headers, &id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let config = state.config.clone();
    let worker_id = id.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<Value, String> {
        read_personal_transcript(
            &config.users_root,
            &identity.username,
            &query.path,
            &worker_id,
        )
    })
    .await;
    match result {
        Ok(Ok(body)) => ([(CACHE_CONTROL, "no-store")], Json(body)).into_response(),
        _ => ApiError::new(
            StatusCode::NOT_FOUND,
            "transcript_not_found",
            "That transcript is unavailable.",
            id,
        )
        .into_response(),
    }
}

fn read_personal_transcript(
    users_root: &FilePath,
    username: &str,
    path: &str,
    request_id: &str,
) -> Result<Value, String> {
    let path = path
        .strip_prefix("_Transcripts/")
        .ok_or("Invalid transcript path")?;
    if !path.rsplit_once('.').is_some_and(|(_, extension)| {
        matches!(
            extension.to_ascii_lowercase().as_str(),
            "txt" | "md" | "vtt" | "srt"
        )
    }) {
        return Err("Invalid transcript format".into());
    }
    let (folder, leaf) = path.rsplit_once('/').unwrap_or(("", path));
    let mut directory = Dir::open(users_root)?
        .traverse(username)?
        .child("_Transcripts")?;
    if !folder.is_empty() {
        for part in folder.split('/') {
            directory = directory.child(part)?;
        }
    }
    let names = directory.names()?;
    let selected = if matches!(
        leaf,
        "transcript.txt" | "subtitles.vtt" | "subtitles.srt" | "diarized.srt"
    ) {
        ["diarized.srt", "subtitles.vtt", "subtitles.srt"]
            .into_iter()
            .find(|name| names.iter().any(|entry| entry == name))
            .unwrap_or(leaf)
    } else {
        leaf
    };
    let bytes = directory.read(selected, MAX_SUBTITLE_BYTES as u64)?;
    let text = std::str::from_utf8(&bytes).map_err(|_| "Invalid transcript encoding")?;
    let format = selected
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default();
    let cues = if matches!(format.as_str(), "vtt" | "srt") {
        parse_subtitle(&format, text)?
    } else {
        Vec::new()
    };
    Ok(
        json!({"cues": cues, "text": if cues.is_empty() { text } else { "" }, "requestId": request_id}),
    )
}
