use serde::Serialize;
use tauri::AppHandle;

use crate::auth;
use crate::queue;

/// Only send the bearer token to the configured server origin, so a request to
/// any other host cannot exfiltrate it.
fn same_origin(candidate: &str, base: &str) -> bool {
    match (url::Url::parse(candidate), url::Url::parse(base)) {
        (Ok(candidate), Ok(base)) => {
            candidate.scheme() == base.scheme()
                && candidate.host_str() == base.host_str()
                && candidate.port_or_known_default() == base.port_or_known_default()
        }
        _ => false,
    }
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub status: u16,
    pub body: String,
    pub headers: Vec<(String, String)>,
}

/// Perform an API request from the Rust side so the webview never handles the
/// bearer token and the request is not subject to webview CORS rules.
#[tauri::command]
pub async fn api_request(
    app: AppHandle,
    method: String,
    url: String,
    headers: Option<Vec<(String, String)>>,
    body: Option<String>,
) -> Result<ApiResponse, String> {
    let client = reqwest::Client::builder()
        .build()
        .map_err(|error| error.to_string())?;
    let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|error| error.to_string())?;
    let mut request = client.request(method, &url);
    for (name, value) in headers.unwrap_or_default() {
        request = request.header(name, value);
    }
    let trusted = queue::server_base_url(&app)
        .map(|base| same_origin(&url, &base))
        .unwrap_or(false);
    if trusted {
        if let Some(token) = auth::access_token(&app).await? {
            request = request.bearer_auth(token);
        }
    }
    if let Some(body) = body {
        request = request.body(body);
    }
    let response = request.send().await.map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    let response_headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| value.to_str().ok().map(|value| (name.to_string(), value.to_string())))
        .collect();
    let body = response.text().await.map_err(|error| error.to_string())?;
    Ok(ApiResponse {
        status,
        body,
        headers: response_headers,
    })
}
