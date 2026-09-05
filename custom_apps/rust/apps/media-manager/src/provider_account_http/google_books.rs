use super::*;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SearchRequest {
    query: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct VolumesResponse {
    total_items: u64,
    items: Vec<Volume>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Volume {
    id: String,
    volume_info: VolumeInfo,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct VolumeInfo {
    title: String,
    subtitle: Option<String>,
    authors: Vec<String>,
    publisher: Option<String>,
    published_date: Option<String>,
    description: Option<String>,
    industry_identifiers: Vec<IndustryIdentifier>,
    page_count: Option<u32>,
    categories: Vec<String>,
    language: Option<String>,
    average_rating: Option<f64>,
    ratings_count: Option<u64>,
    maturity_rating: Option<String>,
    print_type: Option<String>,
    image_links: Option<ImageLinks>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
struct IndustryIdentifier {
    #[serde(rename = "type")]
    identifier_type: String,
    identifier: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ImageLinks {
    small_thumbnail: Option<String>,
    thumbnail: Option<String>,
    small: Option<String>,
    medium: Option<String>,
    large: Option<String>,
    extra_large: Option<String>,
}

pub(super) async fn search(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<SearchRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    let query = request.query.trim();
    if !valid_search_query(query) {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "google_books_query_invalid",
            "Google Books search requires a query between 1 and 500 characters.",
            request_id,
        )
        .into_response();
    }
    let url = match provider_test_url(&state.endpoints.google_books_api_base, "volumes") {
        Ok(url) => url,
        Err(_) => return adapter_unavailable(request_id),
    };
    let mut credentials = match google_books_credentials(&state, &identity, &request_id) {
        Ok(credentials) => credentials,
        Err(error) => return error.into_response(),
    };
    let response = {
        let api_key = credentials
            .get("apiKey")
            .map(String::as_str)
            .unwrap_or_default();
        state
            .client
            .get(url)
            .query(&[
                ("q", query),
                ("maxResults", "12"),
                ("printType", "books"),
                ("key", api_key),
            ])
            .send()
            .await
    };
    zeroize_credentials(&mut credentials);
    let response = match response {
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("Google Books search", request_id),
    };
    let payload = match bounded_provider_json::<VolumesResponse>(response).await {
        Ok(payload) => payload,
        Err(_) => return provider_lookup_failed("Google Books search", request_id),
    };
    let results = payload
        .items
        .into_iter()
        .filter_map(normalize_volume)
        .take(12)
        .collect::<Vec<_>>();
    Json(json!({
        "provider": "google-books",
        "query": query,
        "totalItems": payload.total_items,
        "results": results,
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn cover(
    State(state): State<ProviderBrokerState>,
    Path(volume_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if !valid_volume_id(&volume_id) {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "google_books_volume_id_invalid",
            "Supply a valid Google Books volume ID.",
            request_id,
        )
        .into_response();
    }
    let url = match provider_test_url(
        &state.endpoints.google_books_api_base,
        &format!("volumes/{volume_id}"),
    ) {
        Ok(url) => url,
        Err(_) => return adapter_unavailable(request_id),
    };
    let api_host = url.host_str().map(str::to_string);
    let mut credentials = match google_books_credentials(&state, &identity, &request_id) {
        Ok(credentials) => credentials,
        Err(error) => return error.into_response(),
    };
    let response = {
        let api_key = credentials
            .get("apiKey")
            .map(String::as_str)
            .unwrap_or_default();
        state
            .client
            .get(url)
            .query(&[("key", api_key)])
            .send()
            .await
    };
    zeroize_credentials(&mut credentials);
    let response = match response {
        Ok(response) if response.status() == reqwest::StatusCode::NOT_FOUND => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "google_books_volume_not_found",
                "Google Books does not have that volume.",
                request_id,
            )
            .into_response()
        }
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("Google Books volume lookup", request_id),
    };
    let volume = match bounded_provider_json::<Volume>(response).await {
        Ok(volume) => volume,
        Err(_) => return provider_lookup_failed("Google Books volume lookup", request_id),
    };
    if volume.id != volume_id {
        return provider_lookup_failed("Google Books volume lookup", request_id);
    }
    let Some(mut image_url) =
        preferred_image_url(&volume.volume_info).and_then(|value| reqwest::Url::parse(value).ok())
    else {
        return no_cover(request_id);
    };
    let is_loopback = image_url
        .host_str()
        .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"));
    if image_url.scheme() == "http" && !is_loopback && image_url.set_scheme("https").is_err() {
        return provider_lookup_failed("Google Books cover lookup", request_id);
    }
    if !trusted_google_image(&image_url, api_host.as_deref()) {
        return provider_lookup_failed("Google Books cover lookup", request_id);
    }
    artwork_lookups::proxy_image_response(
        &state.client,
        image_url,
        "Google Books cover lookup",
        request_id,
        false,
    )
    .await
}

fn normalize_volume(volume: Volume) -> Option<Value> {
    if !valid_volume_id(&volume.id) {
        return None;
    }
    let info = volume.volume_info;
    let title = safe_text(Some(&info.title), 500)?;
    let cover_available = preferred_image_url(&info).is_some();
    let authors = safe_text_list(info.authors, 32, 500);
    let categories = safe_text_list(info.categories, 64, 500);
    let industry_identifiers = info
        .industry_identifiers
        .into_iter()
        .filter(|entry| {
            safe_text(Some(&entry.identifier_type), 32).is_some()
                && safe_text(Some(&entry.identifier), 64).is_some()
        })
        .take(32)
        .collect::<Vec<_>>();
    let year = info
        .published_date
        .as_deref()
        .and_then(|date| date.get(0..4))
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|year| (1..=2100).contains(year));
    let isbn = industry_identifiers
        .iter()
        .find_map(|entry| normalized_industry_isbn(entry, "ISBN_13", 13))
        .or_else(|| {
            industry_identifiers
                .iter()
                .find_map(|entry| normalized_industry_isbn(entry, "ISBN_10", 10))
        });
    Some(json!({
        "volumeId": volume.id,
        "title": title,
        "subtitle": safe_text(info.subtitle.as_deref(), 500),
        "authors": authors,
        "publisher": safe_text(info.publisher.as_deref(), 500),
        "publishedDate": safe_text(info.published_date.as_deref(), 32),
        "year": year,
        "description": safe_text(info.description.as_deref(), 20_000),
        "industryIdentifiers": industry_identifiers,
        "isbn": isbn,
        "pageCount": info.page_count,
        "categories": categories,
        "language": safe_text(info.language.as_deref(), 15),
        "averageRating": info.average_rating,
        "ratingsCount": info.ratings_count,
        "maturityRating": safe_text(info.maturity_rating.as_deref(), 64),
        "printType": safe_text(info.print_type.as_deref(), 64),
        "coverAvailable": cover_available,
    }))
}

fn safe_text(value: Option<&str>, maximum: usize) -> Option<String> {
    let value = value?.trim();
    (!value.is_empty()
        && value.chars().count() <= maximum
        && !value
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t')))
    .then(|| value.to_string())
}

fn normalized_industry_isbn(
    entry: &IndustryIdentifier,
    expected_type: &str,
    expected_length: usize,
) -> Option<String> {
    if entry.identifier_type != expected_type {
        return None;
    }
    open_library::normalized_isbn(&entry.identifier).filter(|isbn| isbn.len() == expected_length)
}

fn safe_text_list(values: Vec<String>, maximum_entries: usize, maximum: usize) -> Vec<String> {
    values
        .into_iter()
        .filter_map(|value| safe_text(Some(&value), maximum))
        .take(maximum_entries)
        .collect()
}

fn google_books_credentials(
    state: &ProviderBrokerState,
    identity: &Identity,
    request_id: &str,
) -> Result<BTreeMap<String, String>, ApiError> {
    let credentials = state
        .store
        .load_credentials(identity, "google-books")
        .map_err(|error| storage_failure(error, request_id))?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::PRECONDITION_REQUIRED,
                "provider_account_required",
                "Configure your Google Books API key before using this lookup.",
                request_id.to_string(),
            )
        })?;
    if credentials
        .get("apiKey")
        .is_none_or(|value| value.trim().is_empty())
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "provider_account_invalid",
            "Replace the saved Google Books account before using this lookup.",
            request_id.to_string(),
        ));
    }
    Ok(credentials)
}

fn preferred_image_url(info: &VolumeInfo) -> Option<&str> {
    let links = info.image_links.as_ref()?;
    [
        links.extra_large.as_deref(),
        links.large.as_deref(),
        links.medium.as_deref(),
        links.small.as_deref(),
        links.thumbnail.as_deref(),
        links.small_thumbnail.as_deref(),
    ]
    .into_iter()
    .flatten()
    .next()
}

fn valid_search_query(value: &str) -> bool {
    !value.is_empty()
        && value.chars().count() <= 500
        && !value
            .chars()
            .any(|character| character.is_control() && !character.is_whitespace())
}

fn valid_volume_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn trusted_google_image(url: &reqwest::Url, api_host: Option<&str>) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    if matches!(host, "localhost" | "127.0.0.1" | "::1") {
        return url.scheme() == "http" && api_host == Some(host);
    }
    url.scheme() == "https"
        && (host == "books.google.com"
            || host == "books.googleusercontent.com"
            || host.ends_with(".googleusercontent.com"))
}

fn no_cover(request_id: String) -> Response {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "google_books_cover_not_found",
        "Google Books does not have a cover for that volume.",
        request_id,
    )
    .into_response()
}

fn adapter_unavailable(request_id: String) -> Response {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "provider_adapter_unavailable",
        "The Google Books adapter could not be initialized.",
        request_id,
    )
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_ids_cannot_escape_the_api_path() {
        assert!(valid_volume_id("zyTCAlFPjgYC"));
        assert!(!valid_volume_id("../volumes/other"));
    }

    #[test]
    fn arbitrary_image_hosts_are_rejected() {
        assert!(trusted_google_image(
            &reqwest::Url::parse("https://books.googleusercontent.com/content.jpg").unwrap(),
            Some("www.googleapis.com")
        ));
        assert!(!trusted_google_image(
            &reqwest::Url::parse("https://example.com/content.jpg").unwrap(),
            Some("www.googleapis.com")
        ));
    }

    #[test]
    fn malformed_or_mistyped_isbns_are_not_exposed_as_editable_values() {
        for identifier in [
            IndustryIdentifier {
                identifier_type: "ISBN_13".to_string(),
                identifier: "9780441172718".to_string(),
            },
            IndustryIdentifier {
                identifier_type: "OTHER".to_string(),
                identifier: "9780441172719".to_string(),
            },
        ] {
            let normalized = normalize_volume(Volume {
                id: "zyTCAlFPjgYC".to_string(),
                volume_info: VolumeInfo {
                    title: "Dune".to_string(),
                    industry_identifiers: vec![identifier],
                    ..VolumeInfo::default()
                },
            })
            .expect("otherwise valid volume");
            assert!(normalized["isbn"].is_null());
        }
    }
}
