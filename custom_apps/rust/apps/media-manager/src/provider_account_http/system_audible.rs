//! Audible catalogue search for host system jobs (system socket only).
//!
//! The audio CD importer names the title and author it read from a set of
//! discs and compares the editions returned here: an edition whose runtime
//! matches the discs settles which recording they are (abridged or not) and
//! supplies its narrator, series and description.
//!
//! This is the keyless catalogue endpoint that Audiobookshelf's own Audible
//! provider searches. It is public data, so there is no account and one
//! cached answer serves every caller. Audible does not document it, so any
//! unexpected answer is reported as `provider_error` for the caller to retry.
//!
//! `cover` fetches the artwork of an edition returned by `search`, because
//! the importer itself has no route to the internet.

use super::{provider_test_url, ProviderBrokerState};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::{header::CONTENT_TYPE, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::Engine;
use homelab_common::{request_id, sha256_hex};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

const CACHE_SCOPE: &str = "system-audible-search";
const MAX_PRODUCTS: usize = 10;
const MAX_FIELD_CHARS: usize = 200;
const MAX_DESCRIPTION_CHARS: usize = 4000;
/// Where the catalogue's `product_images` live; nothing else is fetched.
const IMAGE_PREFIX: &str = "https://m.media-amazon.com/images/";
/// The base64 answer must stay under the system clients' 4 MiB read limit.
const MAX_COVER_BYTES: usize = 2 * 1024 * 1024;
const RESPONSE_GROUPS: &str =
    "contributors,product_desc,product_extended_attrs,product_attrs,media,series";

/// One upstream request a second across all callers, like the other keyless
/// sources.
static NEXT_REQUEST: Mutex<Option<Instant>> = Mutex::const_new(None);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SearchRequest {
    title: String,
    #[serde(default)]
    author: Option<String>,
}

fn clean(value: &str) -> Option<String> {
    if value.chars().any(char::is_control) {
        return None;
    }
    let text = value.split_whitespace().collect::<Vec<_>>().join(" ");
    (1..=MAX_FIELD_CHARS)
        .contains(&text.chars().count())
        .then_some(text)
}

fn validated(request: SearchRequest) -> Option<(String, Option<String>)> {
    let title = clean(&request.title)?;
    let author = match request.author.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(author) => Some(clean(author)?),
    };
    Some((title, author))
}

pub(super) async fn search(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<SearchRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let Some((title, author)) = payload.ok().and_then(|Json(request)| validated(request)) else {
        return outcome(&request_id, "", StatusCode::BAD_REQUEST, "invalid_request");
    };
    let cache_key = sha256_hex(
        format!(
            "{CACHE_SCOPE}:v1\0{}\0{}",
            title.to_lowercase(),
            author.as_deref().unwrap_or_default().to_lowercase()
        )
        .as_bytes(),
    );
    if let Some(mut cached) = state.lookup_cache.get(&cache_key).await
        && cached["products"].is_array()
    {
        log(&request_id, &title, "cache_hit");
        cached["cached"] = json!(true);
        return Json(cached).into_response();
    }
    let Some(url) = state
        .endpoints
        .additional_api_bases
        .get("audible")
        .and_then(|base| provider_test_url(base, "catalog/products").ok())
    else {
        return outcome(
            &request_id,
            &title,
            StatusCode::BAD_GATEWAY,
            "provider_error",
        );
    };
    let mut query = vec![
        ("num_results", MAX_PRODUCTS.to_string()),
        ("products_sort_by", "Relevance".to_string()),
        ("response_groups", RESPONSE_GROUPS.to_string()),
        ("title", title.clone()),
    ];
    if let Some(author) = &author {
        query.push(("author", author.clone()));
    }
    wait_for_turn().await;
    let response = match state.client.get(url).query(&query).send().await {
        Ok(response) => response,
        Err(_) => {
            return outcome(
                &request_id,
                &title,
                StatusCode::BAD_GATEWAY,
                "provider_error",
            )
        }
    };
    if response.status() == StatusCode::TOO_MANY_REQUESTS {
        return outcome(
            &request_id,
            &title,
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
        );
    }
    let products = match response.error_for_status() {
        Ok(response) => response.json::<Value>().await.ok(),
        Err(_) => None,
    }
    .and_then(|body| body.get("products").and_then(Value::as_array).cloned());
    let Some(products) = products else {
        return outcome(
            &request_id,
            &title,
            StatusCode::BAD_GATEWAY,
            "provider_error",
        );
    };
    let products: Vec<Value> = products
        .iter()
        .filter_map(product)
        .take(MAX_PRODUCTS)
        .collect();
    let mut body = json!({ "products": products });
    state
        .lookup_cache
        .put(cache_key, CACHE_SCOPE, "system", body.clone())
        .await;
    log(&request_id, &title, "fetched");
    body["cached"] = json!(false);
    Json(body).into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CoverRequest {
    image: String,
}

pub(super) async fn cover(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<CoverRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let url = payload
        .ok()
        .map(|Json(request)| request.image)
        .filter(|image| {
            image.starts_with(IMAGE_PREFIX)
                && image.len() <= 300
                && image.bytes().all(|byte| byte.is_ascii_graphic())
                && !image.contains("..")
        })
        .and_then(|image| reqwest::Url::parse(&image).ok());
    let Some(url) = url else {
        return outcome(
            &request_id,
            "cover",
            StatusCode::BAD_REQUEST,
            "invalid_request",
        );
    };
    wait_for_turn().await;
    let response = match state.client.get(url).send().await {
        Ok(response) if response.status().is_success() => response,
        _ => {
            return outcome(
                &request_id,
                "cover",
                StatusCode::BAD_GATEWAY,
                "provider_error",
            )
        }
    };
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();
    let too_large = response
        .content_length()
        .is_some_and(|length| length > MAX_COVER_BYTES as u64);
    if content_type != "image/jpeg" || too_large {
        return outcome(
            &request_id,
            "cover",
            StatusCode::BAD_GATEWAY,
            "provider_error",
        );
    }
    match response.bytes().await {
        Ok(bytes) if !bytes.is_empty() && bytes.len() <= MAX_COVER_BYTES => {
            log(&request_id, "cover", "fetched");
            Json(json!({
                "contentType": content_type,
                "base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
            }))
            .into_response()
        }
        _ => outcome(
            &request_id,
            "cover",
            StatusCode::BAD_GATEWAY,
            "provider_error",
        ),
    }
}

async fn wait_for_turn() {
    let wait = {
        let mut next = NEXT_REQUEST.lock().await;
        let now = Instant::now();
        let scheduled = next.map_or(now, |at| at.max(now));
        *next = Some(scheduled + Duration::from_secs(1));
        scheduled.saturating_duration_since(now)
    };
    tokio::time::sleep(wait).await;
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
        .unwrap_or_default()
        .chars()
        .take(MAX_FIELD_CHARS * 2)
        .collect()
}

fn names(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|person| text(person, "name"))
        .filter(|name| !name.is_empty())
        .take(20)
        .collect()
}

/// The fields the importer compares and publishes; nothing else leaves here.
fn product(value: &Value) -> Option<Value> {
    let asin = text(value, "asin");
    let title = text(value, "title");
    let asin_valid = asin.len() == 10 && asin.bytes().all(|byte| byte.is_ascii_alphanumeric());
    if !asin_valid || title.is_empty() {
        return None;
    }
    let abridged = match text(value, "format_type").to_ascii_lowercase().as_str() {
        "abridged" => json!(true),
        "unabridged" => json!(false),
        _ => Value::Null,
    };
    let description = value
        .get("publisher_summary")
        .and_then(Value::as_str)
        .and_then(|html| html2text::from_read(html.as_bytes(), 100).ok())
        .map(|plain| {
            plain
                .replace("**", "")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(MAX_DESCRIPTION_CHARS)
                .collect::<String>()
        })
        .unwrap_or_default();
    let series: Vec<Value> = value
        .get("series")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|series| !text(series, "title").is_empty())
        .take(4)
        .map(|series| json!({ "title": text(series, "title"), "sequence": text(series, "sequence") }))
        .collect();
    let image = value
        .get("product_images")
        .and_then(Value::as_object)
        .and_then(|images| {
            images
                .iter()
                .filter_map(|(size, url)| Some((size.parse::<u32>().ok()?, url.as_str()?)))
                .filter(|(_, url)| url.starts_with("https://"))
                .max_by_key(|(size, _)| *size)
                .map(|(_, url)| url.to_string())
        })
        .unwrap_or_default();
    Some(json!({
        "asin": asin,
        "title": title,
        "subtitle": text(value, "subtitle"),
        "authors": names(value, "authors"),
        "narrators": names(value, "narrators"),
        "runtimeMinutes": value.get("runtime_length_min").and_then(Value::as_u64),
        "abridged": abridged,
        "language": text(value, "language").to_ascii_lowercase(),
        "releaseDate": text(value, "release_date"),
        "publisher": text(value, "publisher_name"),
        "description": description,
        "series": series,
        "image": image,
    }))
}

fn outcome(request_id: &str, title: &str, status: StatusCode, error: &'static str) -> Response {
    log(request_id, title, error);
    (status, Json(json!({ "error": error }))).into_response()
}

fn log(request_id: &str, title: &str, outcome: &str) {
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "media-manager-provider-broker",
            "event": "system_audible_search",
            "requestId": request_id,
            "title": title,
            "outcome": outcome,
        })
    );
}
