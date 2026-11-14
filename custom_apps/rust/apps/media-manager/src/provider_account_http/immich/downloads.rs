//! Authenticated original downloads. No public share links or Immich writes.
//! Upstream contract: https://api.immich.app/endpoints/download/downloadArchive
use super::*;
use axum::body::Body;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DownloadQuery {
    asset_ids: String,
}

/// Return a single ZIP through the browser's download manager, without buffering
/// the collection in either the broker or the phone's JavaScript heap.
pub(crate) async fn download(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Query(query): Query<DownloadQuery>,
) -> Result<Response, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let ids: Vec<&str> = query.asset_ids.split(',').collect();
    if ids.is_empty() || ids.len() > 200 || ids.iter().any(|id| !valid_mbid(id)) {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "immich_download_invalid",
            "Select between 1 and 200 photos to download.",
            &id,
        ));
    }
    // Check current upstream visibility/type for every photo, just as previews do.
    for asset_id in &ids {
        account.asset(&state, asset_id, &id).await?;
    }
    // Immich rechecks asset.download permission for every ID when building the ZIP.
    let response = account
        .send(
            &state,
            Method::POST,
            "download/archive",
            Some(json!({ "assetIds": ids, "edited": false })),
            &id,
        )
        .await?;
    stream_download(response, "application/zip", "photos.zip", &id)
}

pub(crate) async fn original(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Response, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let asset = account.asset(&state, &asset_id, &id).await?;
    let response = account
        .send(
            &state,
            Method::GET,
            &format!("assets/{asset_id}/original"),
            None,
            &id,
        )
        .await?;
    let mime = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.starts_with("image/"))
        .unwrap_or("application/octet-stream")
        .to_owned();
    stream_download(response, &mime, &asset.original_file_name, &id)
}

fn stream_download(
    response: reqwest::Response,
    mime: &str,
    filename: &str,
    id: &str,
) -> Result<Response, ApiError> {
    // Keep directory components out of attachments; RFC 5987 encoding keeps
    // quotes, non-ASCII names and control bytes out of raw header syntax.
    let filename = filename.rsplit(['/', '\\']).next().unwrap_or("photo");
    let filename: String = filename
        .bytes()
        .map(|byte| format!("%{byte:02X}"))
        .collect();
    let disposition = HeaderValue::from_str(&format!("attachment; filename*=UTF-8''{filename}"))
        .map_err(|_| upstream_error(id))?;
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).map_err(|_| upstream_error(id))?,
    );
    headers.insert(header::CONTENT_DISPOSITION, disposition);
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    if let Some(length) = response.headers().get(header::CONTENT_LENGTH) {
        headers.insert(header::CONTENT_LENGTH, length.clone());
    }
    let stream = futures_util::stream::try_unfold(response, |mut response| async move {
        response
            .chunk()
            .await
            .map(|chunk| chunk.map(|bytes| (bytes, response)))
    });
    Ok((headers, Body::from_stream(stream)).into_response())
}
