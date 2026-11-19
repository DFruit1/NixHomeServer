//! Immich videos for the Videos page. Listing, thumbnails and playback stay
//! behind the caller's own API key; originals are never exposed by path.
use super::*;
use axum::{body::Body, extract::Request, response::IntoResponse};

pub(crate) async fn list(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    query: Result<Query<ListQuery>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let Query(query) = validated_list_query(query, &id)?;
    let account = account(&state, &identity, &id)?;
    let mut body = json!({
        "type": "VIDEO",
        "visibility": "timeline",
        "page": query.page,
        "size": PAGE_SIZE,
        "withExif": false,
        "withPeople": false
    });
    if !query.query.trim().is_empty() {
        body["originalFileName"] = json!(query.query.trim());
    }
    let response: SearchResponse = account
        .json(&state, Method::POST, "search/metadata", Some(body), &id)
        .await?;
    if response.assets.items.len() > PAGE_SIZE
        || response.assets.items.iter().any(|asset| !asset.valid())
    {
        return Err(upstream_error(&id));
    }
    let next_page = response
        .assets
        .next_page
        .map(|page| page.parse::<u32>())
        .transpose()
        .map_err(|_| upstream_error(&id))?;
    if next_page.is_some_and(|page| page <= query.page || page > 100_000) {
        return Err(upstream_error(&id));
    }
    let items = response
        .assets
        .items
        .into_iter()
        .filter(|asset| {
            asset.kind == "VIDEO" && !asset.is_trashed && asset.visibility == "timeline"
        })
        .map(Asset::video_public)
        .collect::<Vec<_>>();
    Ok(Json(
        json!({ "items": items, "nextPage": next_page, "requestId": id }),
    ))
}

pub(crate) async fn thumbnail(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
    Query(query): Query<ThumbnailQuery>,
) -> Result<Response, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    account.video(&state, &asset_id, &id).await?;
    let size = query.snapped();
    let rendition = if size.is_some_and(|size| size <= 160) {
        "thumbnail"
    } else {
        "preview"
    };
    let (bytes, mime) = account.rendition(&state, &asset_id, rendition, &id).await?;
    let (bytes, mime) = thumbnail::sized(bytes, mime, size)
        .await
        .ok_or_else(|| upstream_error(&id))?;
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_string()),
            (header::CACHE_CONTROL, "private, max-age=300".to_string()),
        ],
        bytes,
    )
        .into_response())
}

pub(crate) async fn playback(
    State(state): State<ProviderBrokerState>,
    Path(asset_id): Path<String>,
    request: Request,
) -> Result<Response, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(request.headers(), &id)?;
    let account = account(&state, &identity, &id)?;
    account.video(&state, &asset_id, &id).await?;
    let range = request
        .headers()
        .get(header::RANGE)
        .map(|value| {
            value.to_str().map_err(|_| {
                error(
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    "immich_range_invalid",
                    "The requested video range is not valid.",
                    &id,
                )
            })
        })
        .transpose()?
        .filter(|value| value.len() <= 128 && value.starts_with("bytes="))
        .map(str::to_owned);
    let response = account
        .video_playback(&asset_id, range.as_deref(), &id)
        .await?;
    if response.status() == reqwest::StatusCode::RANGE_NOT_SATISFIABLE {
        let mut headers = HeaderMap::new();
        if let Some(value) = response.headers().get(header::CONTENT_RANGE) {
            headers.insert(header::CONTENT_RANGE, value.clone());
        }
        return Ok((StatusCode::RANGE_NOT_SATISFIABLE, headers).into_response());
    }
    Ok(stream_playback(response))
}

/// Pass Immich's playable rendition through unchanged. Seeking relies on the
/// upstream 206 status and Content-Range, so neither is recomputed here.
fn stream_playback(response: reqwest::Response) -> Response {
    let status = StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::OK);
    let mut headers = HeaderMap::new();
    for name in [
        header::CONTENT_TYPE,
        header::CONTENT_LENGTH,
        header::CONTENT_RANGE,
        header::LAST_MODIFIED,
        header::ETAG,
    ] {
        if let Some(value) = response.headers().get(&name) {
            headers.insert(name, value.clone());
        }
    }
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store, max-age=0"),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    let mime_is_video = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("video/"));
    if !mime_is_video {
        headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("video/mp4"));
    }
    let stream = futures_util::stream::try_unfold(response, |mut response| async move {
        response
            .chunk()
            .await
            .map(|chunk| chunk.map(|bytes| (bytes, response)))
    });
    (status, headers, Body::from_stream(stream)).into_response()
}
