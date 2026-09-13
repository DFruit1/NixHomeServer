//! Public OpenCloud share-link gate.
//!
//! Cloudflare publishes `cloud.<domain>` (OpenCloud) and `office.<domain>`
//! (Collabora) to this loopback HTTP service through a dedicated Caddy edge.
//! A request is admitted only after it presents a signed cookie that was
//! issued when the visitor opened a valid public share link. The gate never
//! authorizes data access itself: OpenCloud and Collabora still enforce their
//! own share passwords, OIDC login, and WOPI tokens.
//!
//! Share validity is checked against OpenCloud's own unauthenticated
//! `tokeninfo/unprotected` OCS endpoint. A valid token answers with OCS
//! status code 200 even when a password is still required; an unknown or
//! expired token answers with a server error. Anything but a definitive
//! success is treated as invalid so the gate fails closed.

use axum::{
    body::Body,
    extract::State,
    http::{header, HeaderMap, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::{
    net::{IpAddr, SocketAddr},
    os::unix::fs::PermissionsExt,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const SERVICE: &str = "opencloud-share-gate";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
struct Settings {
    listen: String,
    opencloud_url: String,
    cookie_name: String,
    cookie_domain: String,
    cookie_ttl: Duration,
    upstream_timeout: Duration,
}

impl Settings {
    fn from_env() -> Result<Self, String> {
        let ttl_secs = parse_positive_u64("OPENCLOUD_SHARE_GATE_COOKIE_TTL_SECS", 12 * 60 * 60)?;
        let timeout_secs = parse_positive_u64("OPENCLOUD_SHARE_GATE_UPSTREAM_TIMEOUT_SECS", 10)?;
        Ok(Self {
            listen: homelab_common::env_or("OPENCLOUD_SHARE_GATE_LISTEN", "127.0.0.1:9201"),
            opencloud_url: homelab_common::env_or(
                "OPENCLOUD_SHARE_GATE_OPENCLOUD_URL",
                "http://127.0.0.1:9200",
            )
            .trim_end_matches('/')
            .to_string(),
            cookie_name: homelab_common::env_or(
                "OPENCLOUD_SHARE_GATE_COOKIE_NAME",
                "__Secure-ocshare",
            ),
            cookie_domain: homelab_common::optional_env("OPENCLOUD_SHARE_GATE_COOKIE_DOMAIN")
                .unwrap_or_default(),
            cookie_ttl: Duration::from_secs(ttl_secs),
            upstream_timeout: Duration::from_secs(timeout_secs),
        })
    }
}

fn parse_positive_u64(name: &str, default: u64) -> Result<u64, String> {
    match homelab_common::optional_env(name) {
        None => Ok(default),
        Some(raw) => raw
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| format!("{name} must be a positive integer, got {raw:?}")),
    }
}

struct AppState {
    settings: Settings,
    key: Vec<u8>,
    client: reqwest::Client,
}

/// Load the cookie signing key. The Nix module points this at a runtime file
/// that is generated on first start, so the key is provisioned automatically
/// and survives service restarts within a boot.
fn load_cookie_key() -> Vec<u8> {
    if let Some(raw) = homelab_common::optional_env("OPENCLOUD_SHARE_GATE_COOKIE_KEY") {
        return raw.into_bytes();
    }
    if let Some(path) = homelab_common::optional_env("OPENCLOUD_SHARE_GATE_COOKIE_KEY_FILE") {
        if let Ok(contents) = std::fs::read_to_string(&path) {
            let trimmed = contents.trim();
            if !trimmed.is_empty() {
                return trimmed.as_bytes().to_vec();
            }
        }
        let generated = homelab_common::random_hex(32);
        match std::fs::write(&path, format!("{generated}\n")) {
            Ok(()) => {
                let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
                return generated.into_bytes();
            }
            Err(error) => {
                homelab_common::log_event(
                    "warn",
                    SERVICE,
                    "cookie_key_persist_failed",
                    json!({ "path": path, "error": error.to_string() }),
                );
            }
        }
    }
    homelab_common::random_hex(32).into_bytes()
}

fn sign_hex(key: &[u8], message: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts keys of any size");
    mac.update(message.as_bytes());
    mac.finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn issue_cookie(state: &AppState) -> String {
    let expiry = unix_seconds() + state.settings.cookie_ttl.as_secs();
    let signature = sign_hex(&state.key, &format!("v1|{expiry}"));
    format!("{expiry}.{signature}")
}

fn cookie_is_valid(state: &AppState, value: &str) -> bool {
    let Some((expiry, signature)) = value.split_once('.') else {
        return false;
    };
    let Ok(expiry) = expiry.parse::<u64>() else {
        return false;
    };
    if expiry <= unix_seconds() {
        return false;
    }
    let expected = sign_hex(&state.key, &format!("v1|{expiry}"));
    constant_time_eq(expected.as_bytes(), signature.as_bytes())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (a, b) in left.iter().zip(right) {
        difference |= a ^ b;
    }
    difference == 0
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn read_cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    for part in raw.split(';') {
        let part = part.trim();
        if let Some(value) = part
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('='))
        {
            return Some(value.to_string());
        }
    }
    None
}

/// Extract the share token from `/s/<token>` or `/index.php/s/<token>`.
///
/// Only the first path segment after `/s/` is the token; any deeper segments
/// are client-side navigation and are preserved by the redirect.
fn share_token(path: &str) -> Option<String> {
    let path = path.strip_prefix("/index.php").unwrap_or(path);
    let token = path.strip_prefix("/s/")?.split('/').next().unwrap_or("");
    if token.is_empty() {
        return None;
    }
    let valid = token
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~'));
    valid.then(|| token.to_string())
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn verify(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    match read_cookie(&headers, &state.settings.cookie_name) {
        Some(value) if cookie_is_valid(&state, &value) => StatusCode::OK.into_response(),
        _ => StatusCode::UNAUTHORIZED.into_response(),
    }
}

async fn share_navigation(
    State(state): State<Arc<AppState>>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let Some(token) = share_token(uri.path()) else {
        return StatusCode::NOT_FOUND.into_response();
    };

    if let Some(value) = read_cookie(&headers, &state.settings.cookie_name) {
        if cookie_is_valid(&state, &value) {
            return redirect_to(&uri);
        }
    }

    match validate_share(&state, &token).await {
        Ok(true) => {
            let mut response = redirect_to(&uri);
            let cookie = set_cookie(&state, &issue_cookie(&state));
            if let Ok(header_value) = header::HeaderValue::from_str(&cookie) {
                response
                    .headers_mut()
                    .insert(header::SET_COOKIE, header_value);
            }
            response
        }
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(error) => {
            homelab_common::log_event(
                "error",
                SERVICE,
                "share_validation_failed",
                json!({ "error": error }),
            );
            StatusCode::BAD_GATEWAY.into_response()
        }
    }
}

async fn validate_share(state: &AppState, token: &str) -> Result<bool, String> {
    let url = format!(
        "{}/ocs/v2.php/apps/files_sharing/api/v1/tokeninfo/unprotected/{token}",
        state.settings.opencloud_url
    );
    let response = state
        .client
        .get(url)
        .query(&[("format", "json")])
        .header(header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if response.status() != StatusCode::OK {
        return Ok(false);
    }
    let body: Value = response.json().await.map_err(|error| error.to_string())?;
    Ok(body.pointer("/ocs/meta/statuscode").and_then(Value::as_u64) == Some(200))
}

fn redirect_to(uri: &Uri) -> Response {
    let target = uri
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/");
    Response::builder()
        .status(StatusCode::FOUND)
        .header(header::LOCATION, target)
        .body(Body::empty())
        .expect("static redirect response is valid")
}

fn set_cookie(state: &AppState, value: &str) -> String {
    let mut cookie = format!(
        "{}={value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={}",
        state.settings.cookie_name,
        state.settings.cookie_ttl.as_secs()
    );
    if !state.settings.cookie_domain.is_empty() {
        cookie.push_str(&format!("; Domain={}", state.settings.cookie_domain));
    }
    cookie
}

fn app(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/verify", get(verify))
        .fallback(share_navigation)
        .with_state(state)
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let settings = match Settings::from_env() {
        Ok(settings) => settings,
        Err(error) => {
            homelab_common::log_startup_failed(SERVICE, &error);
            return std::process::ExitCode::FAILURE;
        }
    };
    let address: SocketAddr = match settings.listen.parse() {
        Ok(address) => address,
        Err(error) => {
            homelab_common::log_startup_failed(
                SERVICE,
                &format!("invalid listen address: {error}"),
            );
            return std::process::ExitCode::FAILURE;
        }
    };
    if !matches!(address.ip(), IpAddr::V4(ip) if ip.is_loopback()) {
        homelab_common::log_startup_failed(
            SERVICE,
            "OPENCLOUD_SHARE_GATE_LISTEN must be a 127.x loopback address",
        );
        return std::process::ExitCode::FAILURE;
    }

    let client = match reqwest::Client::builder()
        .timeout(settings.upstream_timeout)
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            homelab_common::log_startup_failed(SERVICE, &format!("client build failed: {error}"));
            return std::process::ExitCode::FAILURE;
        }
    };

    let state = Arc::new(AppState {
        key: load_cookie_key(),
        settings,
        client,
    });

    let listener = match tokio::net::TcpListener::bind(address).await {
        Ok(listener) => listener,
        Err(error) => {
            homelab_common::log_startup_failed(SERVICE, &format!("bind failed: {error}"));
            return std::process::ExitCode::FAILURE;
        }
    };

    homelab_common::log_server_started(SERVICE, &address.to_string());

    if let Err(error) = axum::serve(listener, app(state))
        .with_graceful_shutdown(homelab_common::shutdown_signal())
        .await
    {
        homelab_common::log_event(
            "error",
            SERVICE,
            "server_failed",
            json!({ "error": error.to_string() }),
        );
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn test_state() -> AppState {
        AppState {
            settings: Settings {
                listen: "127.0.0.1:0".to_string(),
                opencloud_url: "http://127.0.0.1:9200".to_string(),
                cookie_name: "__Secure-ocshare".to_string(),
                cookie_domain: ".example.test".to_string(),
                cookie_ttl: Duration::from_secs(60),
                upstream_timeout: Duration::from_secs(5),
            },
            key: b"test-key".to_vec(),
            client: reqwest::Client::new(),
        }
    }

    #[test]
    fn extracts_share_tokens() {
        assert_eq!(share_token("/s/abc123").as_deref(), Some("abc123"));
        assert_eq!(share_token("/s/abc123/").as_deref(), Some("abc123"));
        assert_eq!(
            share_token("/index.php/s/abc-1.2_3~").as_deref(),
            Some("abc-1.2_3~")
        );
        assert_eq!(share_token("/s/abc/def").as_deref(), Some("abc"));
        assert_eq!(share_token("/s/"), None);
        assert_eq!(share_token("/index.php/apps/files"), None);
        assert_eq!(share_token("/s/bad%2Ftoken"), None);
    }

    #[test]
    fn cookies_round_trip_and_reject_tampering() {
        let state = test_state();
        let value = issue_cookie(&state);
        assert!(cookie_is_valid(&state, &value));

        let (expiry, signature) = value.split_once('.').unwrap();
        assert!(!cookie_is_valid(&state, &format!("0.{signature}"),));
        assert!(!cookie_is_valid(
            &state,
            &format!("{expiry}.{}", "0".repeat(signature.len())),
        ));
        assert!(!cookie_is_valid(&state, "garbage"));
    }

    #[test]
    fn cookie_header_is_scoped_and_secure() {
        let state = test_state();
        let header = set_cookie(&state, "value");
        assert!(header.contains("__Secure-ocshare=value"));
        assert!(header.contains("HttpOnly"));
        assert!(header.contains("Secure"));
        assert!(header.contains("SameSite=Lax"));
        assert!(header.contains("Domain=.example.test"));
    }

    #[test]
    fn reads_named_cookie() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            HeaderValue::from_static("other=1; __Secure-ocshare=value; tail=2"),
        );
        assert_eq!(
            read_cookie(&headers, "__Secure-ocshare").as_deref(),
            Some("value")
        );
        assert_eq!(read_cookie(&headers, "__Secure-ocshare-extra"), None);
    }
}
