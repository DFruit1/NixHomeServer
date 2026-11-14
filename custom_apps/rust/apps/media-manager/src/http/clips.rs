//! Generate a short animated GIF from the video the caller is watching and
//! hand it to the provider broker, which is the only component that can reach
//! the user's Immich account. The clip is archived in Immich and only appears
//! in the album the caller chose.
use super::*;
use std::process::{Command, Stdio};
use std::sync::LazyLock;

const MAX_CLIP_SECONDS: u32 = 30;
const DEFAULT_ALBUM: &str = "GIF";
const MAX_CLIP_BYTES: usize = 64 * 1024 * 1024;
const CLIP_WIDTH: u32 = 480;
const CLIP_FPS: u32 = 12;
// The broker upload is a server-to-server call; generated clips are bounded,
// so a total timeout is enough to recover from a stalled connection.
static UPLOAD_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(300))
        .build()
        .expect("clip upload client")
});

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ClipRequest {
    start_seconds: f64,
    duration_seconds: u32,
    #[serde(default)]
    album_id: Option<String>,
    #[serde(default)]
    album_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadedClip {
    asset_id: String,
    album_id: String,
    album_name: String,
}

pub(super) async fn create_clip(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    payload: Result<Json<ClipRequest>, axum::extract::rejection::JsonRejection>,
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
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "clip_request_invalid",
                "Choose a start position and a clip length.",
                request_id,
            )
            .into_response();
        }
    };
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
        Err(error) => return error.with_request_id(request_id.clone()).into_response(),
    };
    if item.media_kind != MediaKind::Video {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "clip_video_required",
            "Clips can only be created from a video.",
            request_id,
        )
        .into_response();
    }
    let Some(root) = state.config.resolve_visible_root(&identity, &item.root_id) else {
        return ApiError::internal(request_id).into_response();
    };
    let Some(ffprobe_path) = state.config.ffprobe_path.clone() else {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "clip_generation_unavailable",
            "Clip generation is not configured on this server.",
            request_id,
        )
        .into_response();
    };
    let (start_seconds, duration_seconds) = match validated_clip_range(&request) {
        Ok(range) => range,
        Err(message) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "clip_request_invalid",
                message,
                request_id,
            )
            .into_response();
        }
    };
    let album_name = request.album_name.trim();
    let album_name = if album_name.is_empty() {
        DEFAULT_ALBUM
    } else {
        album_name
    };
    if album_name.len() > 128 || album_name.chars().any(char::is_control) {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "clip_album_invalid",
            "Choose an album name between 1 and 128 characters.",
            request_id,
        )
        .into_response();
    }
    let album_id = match request.album_id.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(album_id) if valid_uuid(album_id) => Some(album_id.to_owned()),
        Some(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "clip_album_invalid",
                "Choose a valid Immich album.",
                request_id,
            )
            .into_response();
        }
    };
    let ffmpeg_path = ffprobe_path.with_file_name("ffmpeg");
    let filename = clip_filename(&item.relative_path, start_seconds, duration_seconds);
    let root_path = FilePath::new(&root.resolved_path).to_path_buf();
    let relative_path = item.relative_path.clone();
    let output_dir = state.config.state_dir.join("clip-exports");
    let permit = match super::playback::VIDEO_TRANSCODE_LIMIT.try_acquire() {
        Ok(permit) => permit,
        Err(_) => {
            return ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "clip_busy",
                "A video conversion is already running. Try again in a moment.",
                request_id,
            )
            .into_response();
        }
    };
    let rendered = tokio::task::spawn_blocking(move || {
        // The permit is released only after the encoder exits.
        let _permit = permit;
        render_clip(
            &ffmpeg_path,
            &root_path,
            &relative_path,
            start_seconds,
            duration_seconds,
            &output_dir,
        )
    })
    .await;
    let bytes = match rendered {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(kind)) => {
            log_event(
                "clip_generation_failed",
                &request_id,
                json!({ "kind": kind }),
            );
            return ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "clip_generation_failed",
                "The GIF could not be created from this video. Try a different position or a shorter clip.",
                request_id,
            )
            .into_response();
        }
        Err(_) => {
            log_event(
                "clip_generation_failed",
                &request_id,
                json!({ "kind": "task" }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let uploaded = match upload_to_immich(
        &state.config,
        &identity,
        &filename,
        album_id.as_deref(),
        album_name,
        bytes,
        &request_id,
    )
    .await
    {
        Ok(uploaded) => uploaded,
        Err(error) => return error.into_response(),
    };
    (
        StatusCode::CREATED,
        Json(json!({
            "assetId": uploaded.asset_id,
            "albumId": uploaded.album_id,
            "albumName": uploaded.album_name,
            "filename": filename,
            "startSeconds": start_seconds,
            "durationSeconds": duration_seconds,
            "requestId": request_id,
        })),
    )
        .into_response()
}

fn validated_clip_range(request: &ClipRequest) -> Result<(f64, u32), &'static str> {
    if !request.start_seconds.is_finite() || !(0.0..=86_400.0).contains(&request.start_seconds) {
        return Err("Start the clip at a valid position in the video.");
    }
    if !(1..=MAX_CLIP_SECONDS).contains(&request.duration_seconds) {
        return Err("Choose a clip length between 1 and 30 seconds.");
    }
    Ok((
        (request.start_seconds * 1000.0).round() / 1000.0,
        request.duration_seconds,
    ))
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn clip_filename(relative_path: &str, start_seconds: f64, duration_seconds: u32) -> String {
    let name = relative_path.rsplit('/').next().unwrap_or(relative_path);
    let stem = name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(name);
    let mut safe = stem
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    safe.truncate(80);
    let safe = safe.trim_matches(['-', '.']);
    let safe = if safe.is_empty() { "clip" } else { safe };
    format!("{safe}-{start_seconds:.1}s-{duration_seconds}s.gif")
}

/// Run the encoder against the contained catalog file. Success returns the GIF
/// bytes; failures return a fixed kind so logs never carry container details.
fn render_clip(
    ffmpeg: &FilePath,
    root_path: &FilePath,
    relative_path: &str,
    start_seconds: f64,
    duration_seconds: u32,
    output_dir: &FilePath,
) -> Result<Vec<u8>, &'static str> {
    std::fs::create_dir_all(output_dir).map_err(|_| "output_directory")?;
    let temp = output_dir.join(format!(
        "clip-{}-{}.gif",
        std::process::id(),
        homelab_common::random_hex(8)
    ));
    let input = open_regular_file_beneath(root_path, relative_path).map_err(|_| "open_input")?;
    let filter = format!(
        "fps={CLIP_FPS},scale='min({CLIP_WIDTH},iw)':-2:flags=lanczos,\
         split[s0][s1];[s0]palettegen=stats_mode=diff[p];\
         [s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
    );
    let mut child = Command::new(ffmpeg)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            &format!("{start_seconds:.3}"),
            "-i",
            "/proc/self/fd/0",
            "-t",
            &duration_seconds.to_string(),
            "-vf",
            &filter,
            "-an",
            "-f",
            "gif",
        ])
        .arg(&temp)
        .stdin(Stdio::from(input))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "start_encoder")?;
    let started = Instant::now();
    let mut changed = started;
    let mut previous = 0;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&temp);
                return Err("wait_encoder");
            }
        }
        let size = std::fs::metadata(&temp).map(|meta| meta.len()).unwrap_or(0);
        if size != previous {
            previous = size;
            changed = Instant::now();
        }
        if size as usize > MAX_CLIP_BYTES
            || started.elapsed() > Duration::from_secs(180)
            || changed.elapsed() > Duration::from_secs(45)
        {
            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&temp);
            return Err("encoder_deadline");
        }
        std::thread::sleep(Duration::from_millis(150));
    };
    if !status.success() {
        let _ = std::fs::remove_file(&temp);
        return Err("encoder_status");
    }
    let size = std::fs::metadata(&temp)
        .map_err(|_| "output_missing")?
        .len();
    if size == 0 || size as usize > MAX_CLIP_BYTES {
        let _ = std::fs::remove_file(&temp);
        return Err("output_size");
    }
    let bytes = std::fs::read(&temp).map_err(|_| "read_output")?;
    let _ = std::fs::remove_file(&temp);
    Ok(bytes)
}

async fn upload_to_immich(
    config: &AppConfig,
    identity: &Identity,
    filename: &str,
    album_id: Option<&str>,
    album_name: &str,
    bytes: Vec<u8>,
    request_id: &str,
) -> Result<UploadedClip, ApiError> {
    let Some(base) = config.provider_broker_base_url.as_deref() else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "clip_upload_unavailable",
            "The Immich provider broker is not configured.",
            request_id.to_owned(),
        ));
    };
    let base = reqwest::Url::parse(base).map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "clip_upload_unavailable",
            "The Immich provider broker address is invalid.",
            request_id.to_owned(),
        )
    })?;
    if !(base.scheme() == "http"
        && base
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1")))
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "clip_upload_unavailable",
            "The Immich provider broker must use a loopback HTTP address.",
            request_id.to_owned(),
        ));
    }
    let origin = base.origin().ascii_serialization();
    let mut url = base
        .join("api/v1/provider-lookups/immich/clips")
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "clip_upload_unavailable",
                "The Immich provider broker address is invalid.",
                request_id.to_owned(),
            )
        })?;
    url.query_pairs_mut()
        .append_pair("albumName", album_name)
        .append_pair("filename", filename);
    if let Some(album_id) = album_id {
        url.query_pairs_mut().append_pair("albumId", album_id);
    }
    let response = UPLOAD_CLIENT
        .post(url)
        .header("origin", origin)
        .header("content-type", "image/gif")
        .header("x-forwarded-user", &identity.subject)
        .header("x-forwarded-preferred-username", &identity.username)
        .header("x-forwarded-groups", identity.groups.join(","))
        .body(bytes)
        .send()
        .await
        .map_err(|_| {
            ApiError::new(
                StatusCode::BAD_GATEWAY,
                "clip_upload_failed",
                "The clip could not be sent to Photos.",
                request_id.to_owned(),
            )
        })?;
    let status = response.status();
    let bytes = response.bytes().await.map_err(|_| {
        ApiError::new(
            StatusCode::BAD_GATEWAY,
            "clip_upload_failed",
            "The clip upload reply could not be read.",
            request_id.to_owned(),
        )
    })?;
    if !status.is_success() || bytes.len() > 2 * 1024 * 1024 {
        let message = serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|value| {
                value
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .filter(|message| {
                !message.is_empty()
                    && message.len() <= 500
                    && !message.chars().any(char::is_control)
            })
            .unwrap_or_else(|| "The clip could not be saved to Photos.".into());
        let status = if status.is_success() || status.is_server_error() {
            StatusCode::BAD_GATEWAY
        } else {
            status
        };
        return Err(ApiError::new(
            status,
            "clip_upload_failed",
            message,
            request_id.to_owned(),
        ));
    }
    let uploaded: UploadedClip = serde_json::from_slice(&bytes).map_err(|_| {
        ApiError::new(
            StatusCode::BAD_GATEWAY,
            "clip_upload_failed",
            "Photos returned an invalid upload reply.",
            request_id.to_owned(),
        )
    })?;
    if !valid_uuid(&uploaded.asset_id) || !valid_uuid(&uploaded.album_id) {
        return Err(ApiError::new(
            StatusCode::BAD_GATEWAY,
            "clip_upload_failed",
            "Photos returned an invalid upload reply.",
            request_id.to_owned(),
        ));
    }
    Ok(uploaded)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(start: f64, duration: u32) -> ClipRequest {
        ClipRequest {
            start_seconds: start,
            duration_seconds: duration,
            album_id: None,
            album_name: String::new(),
        }
    }

    #[test]
    fn clip_range_is_bounded_to_one_encoder_deadline() {
        assert!(validated_clip_range(&request(0.0, 1)).is_ok());
        assert!(validated_clip_range(&request(12.3456, 30)).is_ok());
        assert_eq!(
            validated_clip_range(&request(-1.0, 5)),
            Err("Start the clip at a valid position in the video.")
        );
        assert_eq!(
            validated_clip_range(&request(f64::NAN, 5)),
            Err("Start the clip at a valid position in the video.")
        );
        assert_eq!(
            validated_clip_range(&request(4.0, 31)),
            Err("Choose a clip length between 1 and 30 seconds.")
        );
    }

    #[test]
    fn clip_names_stay_safe_and_identifiable() {
        assert_eq!(
            clip_filename("_Videos/Family Day #2.2024.mkv", 12.34, 5),
            "Family-Day--2.2024-12.3s-5s.gif"
        );
        assert_eq!(
            clip_filename("_Videos/日本.mkv", 0.0, 1),
            "clip-0.0s-1s.gif"
        );
    }

    #[test]
    fn only_uuid_albums_are_accepted() {
        assert!(valid_uuid("0b8f7c6e-1a2b-4c3d-8e4f-5a6b7c8d9e0f"));
        assert!(!valid_uuid("gif"));
        assert!(!valid_uuid("0b8f7c6e1a2b4c3d8e4f5a6b7c8d9e0f"));
    }
}
