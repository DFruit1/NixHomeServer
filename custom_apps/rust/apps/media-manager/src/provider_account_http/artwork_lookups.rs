use super::*;
use crate::artwork::sniff_image_content_type;

const MAX_REMOTE_ARTWORK_BYTES: usize = 32 * 1024 * 1024;

pub(super) async fn tmdb_image(
    State(state): State<ProviderBrokerState>,
    Path((size, file_name)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if let Err(error) = tmdb_lookups::client_for(&state, &identity, &request_id) {
        return error.into_response();
    }
    if !matches!(size.as_str(), "w342" | "w500" | "w780" | "original")
        || !valid_image_file_name(&file_name)
    {
        return invalid_artwork_reference("tmdb_image_invalid", request_id);
    }
    let url = match provider_test_url(
        &state.endpoints.tmdb_images_base,
        &format!("{size}/{file_name}"),
    ) {
        Ok(url) => url,
        Err(_) => return unavailable(request_id),
    };
    proxy_image_response(&state.client, url, "TMDB artwork", request_id, false).await
}

pub(super) async fn cover_art_archive_front(
    State(state): State<ProviderBrokerState>,
    Path(release_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    if let Err(error) = authenticated_identity(&headers, &request_id) {
        return error.into_response();
    }
    if !valid_mbid(&release_id) {
        return invalid_artwork_reference("cover_art_release_id_invalid", request_id);
    }
    let url = match provider_test_url(
        &state.endpoints.cover_art_archive_base,
        &format!("release/{release_id}/front-1200"),
    ) {
        Ok(url) => url,
        Err(_) => return unavailable(request_id),
    };
    proxy_image_response(
        &state.client,
        url,
        "Cover Art Archive artwork",
        request_id,
        true,
    )
    .await
}

pub(super) async fn proxy_image_response(
    client: &reqwest::Client,
    url: reqwest::Url,
    operation: &'static str,
    request_id: String,
    allow_archive_redirect: bool,
) -> Response {
    let source_host = url.host_str().map(str::to_string);
    let mut response = match client.get(url).send().await {
        Ok(response) => response,
        Err(_) => return provider_lookup_failed(operation, request_id),
    };
    if response.status().is_redirection() && allow_archive_redirect {
        let target = response
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|location| response.url().join(location).ok());
        let Some(target) =
            target.filter(|url| trusted_artwork_redirect(url, source_host.as_deref()))
        else {
            return provider_lookup_failed(operation, request_id);
        };
        response = match client.get(target).send().await {
            Ok(response) => response,
            Err(_) => return provider_lookup_failed(operation, request_id),
        };
    }
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_artwork_not_found",
            "The provider does not have artwork for that item.",
            request_id,
        )
        .into_response();
    }
    if !response.status().is_success() {
        return provider_lookup_failed(operation, request_id);
    }
    let declared_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if !declared_type.starts_with("image/") {
        return provider_lookup_failed(operation, request_id);
    }
    let bytes = match bounded_provider_bytes(response, MAX_REMOTE_ARTWORK_BYTES).await {
        Ok(bytes) if !bytes.is_empty() => bytes,
        _ => return provider_lookup_failed(operation, request_id),
    };
    let Some(content_type) = sniff_image_content_type(&bytes) else {
        return provider_lookup_failed(operation, request_id);
    };
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, content_type),
            (
                header::HeaderName::from_static("x-content-type-options"),
                "nosniff".to_string(),
            ),
            (header::CACHE_CONTROL, "private, max-age=3600".to_string()),
        ],
        bytes,
    )
        .into_response()
}

fn valid_image_file_name(value: &str) -> bool {
    let Some((stem, extension)) = value.rsplit_once('.') else {
        return false;
    };
    !stem.is_empty()
        && value.len() <= 200
        && stem
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        && matches!(
            extension.to_ascii_lowercase().as_str(),
            "jpg" | "jpeg" | "png" | "webp"
        )
}

fn trusted_artwork_redirect(url: &reqwest::Url, source_host: Option<&str>) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    if url.scheme() == "http"
        && matches!(host, "localhost" | "127.0.0.1" | "::1")
        && source_host == Some(host)
    {
        return true;
    }
    url.scheme() == "https"
        && (host == "coverartarchive.org"
            || host.ends_with(".coverartarchive.org")
            || host == "archive.org"
            || host.ends_with(".archive.org"))
}

fn invalid_artwork_reference(code: &'static str, request_id: String) -> Response {
    ApiError::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        code,
        "Supply a valid provider artwork reference.",
        request_id,
    )
    .into_response()
}

fn unavailable(request_id: String) -> Response {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "provider_adapter_unavailable",
        "The provider artwork adapter could not be initialized.",
        request_id,
    )
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_file_names_cannot_escape_the_provider_path() {
        assert!(valid_image_file_name("poster_1.jpg"));
        assert!(!valid_image_file_name("../secret.jpg"));
        assert!(!valid_image_file_name("folder/poster.jpg"));
        assert!(!valid_image_file_name(".."));
        assert!(!valid_image_file_name("poster.html"));
    }

    #[test]
    fn archive_redirects_are_allowlisted() {
        assert!(trusted_artwork_redirect(
            &reqwest::Url::parse("https://ia801.example.archive.org/item/front.jpg").unwrap(),
            Some("coverartarchive.org")
        ));
        assert!(!trusted_artwork_redirect(
            &reqwest::Url::parse("https://example.com/front.jpg").unwrap(),
            Some("coverartarchive.org")
        ));
    }
}
