use super::*;
use std::io::{Cursor, Read};

const MAX_DOWNLOAD: usize = 10 * 1024 * 1024;
const MAX_SUBTITLE: usize = 2 * 1024 * 1024;
pub(super) struct DownloadReference {
    pub owner: String,
    location: Location,
    pub expires: Instant,
}
enum Location {
    Api(String),
    Asset(reqwest::Url),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in crate::provider_account_http) struct DownloadRequest {
    id: String,
    entry: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadResult {
    files: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    format: Option<String>,
    cue_count: usize,
}

pub(super) async fn test(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
) -> Result<(), Failure> {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let body = json_request(
        state,
        identity,
        "subdl",
        state
            .client
            .get(url(state, "subdl", "me")?)
            .bearer_auth(key),
    )
    .await?;
    if !body.is_object() || body.get("error").is_some() {
        return Err(Failure::unavailable());
    }
    Ok(())
}

// https://subdl.com/developers -- deterministic title/ID search; no AI endpoints.
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let language = request.language.as_deref().unwrap_or("en");
    if language.len() > 15
        || !language
            .bytes()
            .all(|b| b.is_ascii_alphabetic() || b == b'-')
    {
        return Err(Failure::invalid());
    }
    let mut params = vec![
        ("languages", language.to_string()),
        ("unpack", "1".into()),
        ("subs_per_page", "20".into()),
        ("page", request.page.unwrap_or(1).max(1).to_string()),
    ];
    let reference = request.id.as_deref().unwrap_or(request.query.trim());
    if reference.starts_with("tt")
        && reference.len() > 2
        && reference[2..].bytes().all(|b| b.is_ascii_digit())
    {
        params.push(("imdb_id", reference.into()));
    } else if let Some(id) = reference.strip_prefix("tmdb:") {
        if !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        params.push(("tmdb_id", id.into()));
    } else {
        params.push(("film_name", reference.into()));
    }
    if let Some(kind) = &request.media_type {
        params.push(("type", if kind == "movie" { "movie" } else { "tv" }.into()));
    }
    if let Some(season) = request.season {
        params.push(("season", season.to_string()));
    }
    if let Some(episode) = request.episode {
        params.push(("episode", episode.to_string()));
    }
    let body = json_request(
        state,
        identity,
        "subdl",
        state
            .client
            .get(url(state, "subdl", "subtitles/search")?)
            .bearer_auth(key)
            .query(&params),
    )
    .await?;
    if body.get("status") == Some(&json!(false)) || body.get("error").is_some() {
        return Err(Failure::unavailable());
    }
    let values = body
        .get("subtitles")
        .and_then(Value::as_array)
        .ok_or_else(Failure::unavailable)?;
    let mut out = Vec::new();
    for value in values.iter().take(MAX_RESULTS) {
        let location = download_location(value).or_else(|| {
            let id = text(value, "nId");
            let id = if id.is_empty() {
                text(value, "n_id")
            } else {
                id
            };
            valid_id(id).then(|| Location::Api(format!("subtitles/{id}/download")))
        });
        let Some(location) = location else {
            continue;
        };
        let handle = rand::random::<[u8; 16]>()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let mut refs = state.additional.subtitles.lock().await;
        refs.retain(|_, r| r.expires > Instant::now());
        if refs.len() >= 512 {
            return Err(Failure::limited());
        }
        refs.insert(
            handle.clone(),
            DownloadReference {
                owner: identity.subject.clone(),
                location,
                expires: Instant::now() + Duration::from_secs(900),
            },
        );
        drop(refs);
        let name = if text(value, "release_name").is_empty() {
            text(value, "name")
        } else {
            text(value, "release_name")
        };
        let mut c = Candidate::new("subdl", handle, name);
        c.subtitle = format!("{} · {}", text(value, "lang"), text(value, "release_name"));
        c.evidence.insert(
            "Hearing impaired".into(),
            if value.get("hi") == Some(&json!(true)) {
                "Yes"
            } else {
                "No"
            }
            .into(),
        );
        c.evidence.insert("Language".into(), language.into());
        if let Some(fps) = value.get("fps") {
            c.evidence.insert("Frame rate".into(), fps.to_string());
        }
        out.push(c);
    }
    Ok(out)
}

fn trusted_download(url: &reqwest::Url) -> bool {
    url.scheme() == "https"
        && url.host_str() == Some("dl.subdl.com")
        && url.port().is_none_or(|p| p == 443)
        && url.username().is_empty()
        && url.password().is_none()
        && url.path().starts_with("/subtitle/")
}
fn download_location(value: &Value) -> Option<Location> {
    let source = text(value, "url");
    if source.is_empty() {
        return None;
    }
    let mut target = reqwest::Url::parse("https://dl.subdl.com/")
        .ok()?
        .join(source)
        .ok()?;
    if !trusted_download(&target) {
        return None;
    }
    target.set_query(None);
    target.set_fragment(None);
    Some(Location::Asset(target))
}

pub(in crate::provider_account_http) async fn download(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<DownloadRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(v) => v,
        Err(e) => return e.into_response(),
    };
    let request = match payload {
        Ok(Json(v)) => v,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    let saved = match credentials(&state, &identity, "subdl") {
        Ok(v) => v,
        Err(e) => return e.response(request_id),
    };
    let target = {
        let refs = state.additional.subtitles.lock().await;
        refs.get(&request.id)
            .filter(|r| r.owner == identity.subject && r.expires > Instant::now())
            .map(|r| match &r.location {
                Location::Asset(v) => Location::Asset(v.clone()),
                Location::Api(v) => Location::Api(v.clone()),
            })
    };
    let Some(target) = target else {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "subtitle_reference_expired",
            "Search again to refresh this subtitle reference.",
            request_id,
        )
        .into_response();
    };
    let call = match target {
        Location::Asset(target) => state.client.get(target),
        Location::Api(path) => match url(&state, "subdl", &path) {
            Ok(target) => state.client.get(target).bearer_auth(
                saved
                    .0
                    .get("apiKey")
                    .map(String::as_str)
                    .unwrap_or_default(),
            ),
            Err(e) => return e.response(request_id),
        },
    };
    let response = match call.send().await {
        Ok(v) if v.status().is_success() => v,
        Ok(v) if v.status() == StatusCode::TOO_MANY_REQUESTS => {
            return Failure::limited().response(request_id)
        }
        _ => return Failure::unavailable().response(request_id),
    };
    let filename = response
        .headers()
        .get("content-disposition")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split("filename=").nth(1))
        .map(|v| {
            v.trim_matches('"')
                .split(';')
                .next()
                .unwrap_or("")
                .to_string()
        });
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let bytes = match bounded_provider_bytes(response, MAX_DOWNLOAD).await {
        Ok(v) => v,
        Err(_) => return Failure::unavailable().response(request_id),
    };
    match tokio::task::spawn_blocking(move || {
        decode_download(bytes, filename, content_type, request.entry)
    })
    .await
    {
        Ok(Ok(result)) => Json(result).into_response(),
        Ok(Err(e)) => e.response(request_id),
        Err(_) => Failure::unavailable().response(request_id),
    }
}

fn decode_download(
    bytes: Vec<u8>,
    filename: Option<String>,
    content_type: String,
    entry: Option<String>,
) -> Result<DownloadResult, Failure> {
    let (name, data, files) = if bytes.starts_with(b"PK") {
        let mut archive =
            zip::ZipArchive::new(Cursor::new(&bytes)).map_err(|_| Failure::unavailable())?;
        if archive.len() > 128
            || archive
                .has_overlapping_files()
                .map_err(|_| Failure::unavailable())?
        {
            return Err(Failure::invalid());
        }
        let mut files = Vec::new();
        let mut total = 0u64;
        for index in 0..archive.len() {
            let file = archive
                .by_index(index)
                .map_err(|_| Failure::unavailable())?;
            let name = file.name();
            if name.starts_with('/')
                || name.contains(['\\', ':', '\0'])
                || name.split('/').any(|p| p == "..")
                || file.unix_mode().is_some_and(|m| {
                    m & 0o170000 != 0 && m & 0o170000 != 0o100000 && m & 0o170000 != 0o040000
                })
            {
                return Err(Failure::invalid());
            }
            total = total
                .checked_add(file.size())
                .ok_or_else(Failure::invalid)?;
            if total > 32 * 1024 * 1024 || file.size() > MAX_SUBTITLE as u64 {
                return Err(Failure::invalid());
            }
            if !file.is_dir() && subtitle_format(name).is_some() {
                files.push(name.to_string());
            }
        }
        let selected = entry.or_else(|| (files.len() == 1).then(|| files[0].clone()));
        let Some(selected) = selected else {
            return Ok(DownloadResult {
                files,
                content: None,
                format: None,
                cue_count: 0,
            });
        };
        if !files.contains(&selected) {
            return Err(Failure::invalid());
        }
        let file = archive.by_name(&selected).map_err(|_| Failure::invalid())?;
        let mut data = Vec::new();
        file.take(MAX_SUBTITLE as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|_| Failure::unavailable())?;
        (selected, data, files)
    } else {
        let name = filename.unwrap_or_else(|| {
            if content_type.contains("vtt") {
                "subtitle.vtt"
            } else if content_type.contains("ssa") {
                "subtitle.ass"
            } else {
                "subtitle.srt"
            }
            .into()
        });
        (name, bytes, vec![])
    };
    if data.len() > MAX_SUBTITLE {
        return Err(Failure::invalid());
    }
    let format = subtitle_format(&name).ok_or_else(Failure::invalid)?;
    let content = String::from_utf8(data).map_err(|_| Failure {
        status: StatusCode::UNPROCESSABLE_ENTITY,
        code: "subtitle_encoding_unsupported",
        message: "This subtitle is not UTF-8. Convert it before uploading.",
    })?;
    let cues =
        crate::subtitle_format::parse_subtitle(format, &content).map_err(|_| Failure::invalid())?;
    if cues.is_empty() {
        return Err(Failure::invalid());
    }
    Ok(DownloadResult {
        files,
        content: Some(content),
        format: Some(format.into()),
        cue_count: cues.len(),
    })
}
fn subtitle_format(name: &str) -> Option<&'static str> {
    match name.rsplit('.').next()?.to_ascii_lowercase().as_str() {
        "srt" => Some("srt"),
        "vtt" => Some("vtt"),
        "ass" | "ssa" => Some("ass"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    // Archive validation protects against traversal and unbounded expansion at
    // a download-to-filesystem boundary; this concrete risk permits new tests.
    #[test]
    fn subtitle_archives_reject_traversal_and_require_explicit_pack_selection() {
        for names in [vec!["../escape.srt"], vec!["one.srt", "two.srt"]] {
            let mut output = Cursor::new(Vec::new());
            {
                let mut zip = zip::ZipWriter::new(&mut output);
                for name in &names {
                    zip.start_file(*name, zip::write::SimpleFileOptions::default())
                        .unwrap();
                    zip.write_all(b"1\n00:00:01,000 --> 00:00:02,000\nExample\n")
                        .unwrap();
                }
                zip.finish().unwrap();
            }
            let result = decode_download(output.into_inner(), None, "application/zip".into(), None);
            if names.len() == 1 {
                assert!(result.is_err());
            } else {
                let result = result.unwrap_or_else(|_| panic!("valid bounded pack"));
                assert_eq!(result.files.len(), 2);
                assert!(result.content.is_none());
            }
        }
    }
}
