use axum::{
    body::Bytes,
    extract::{Query, State},
    http::{header, HeaderMap, Method, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{any, get},
    Router,
};
use serde_json::json;
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::Semaphore;

#[derive(Debug, Clone)]
struct Settings {
    listen: String,
    upstream: String,
    max_inflight: usize,
    max_queued: usize,
    queue_timeout: Duration,
    upstream_timeout: Duration,
    max_body_bytes: usize,
}

#[derive(Debug)]
struct GateFull;

fn parse_usize(name: &str, default: usize) -> Result<usize, String> {
    match homelab_common::optional_env(name) {
        None => Ok(default),
        Some(raw) => raw
            .parse::<usize>()
            .map_err(|_| format!("{name} must be a positive integer, got {raw:?}")),
    }
}

fn parse_u64(name: &str, default: u64) -> Result<u64, String> {
    match homelab_common::optional_env(name) {
        None => Ok(default),
        Some(raw) => raw
            .parse::<u64>()
            .map_err(|_| format!("{name} must be a positive integer, got {raw:?}")),
    }
}

impl Settings {
    fn from_env() -> Result<Self, String> {
        let max_inflight = parse_usize("AI_GATE_MAX_INFLIGHT", 1)?;
        let max_queued = parse_usize("AI_GATE_MAX_QUEUED", 2)?;
        let queue_timeout_secs = parse_u64("AI_GATE_QUEUE_TIMEOUT_SECS", 60)?;
        let upstream_timeout_secs = parse_u64("AI_GATE_UPSTREAM_TIMEOUT_SECS", 600)?;
        let max_body_bytes = parse_usize("AI_GATE_MAX_BODY_BYTES", 15 * 1024 * 1024)?;
        if max_inflight == 0 {
            return Err("AI_GATE_MAX_INFLIGHT must be at least 1".to_string());
        }
        if queue_timeout_secs == 0 || upstream_timeout_secs == 0 || max_body_bytes == 0 {
            return Err("AI_GATE timeouts and body limit must be positive".to_string());
        }
        let upstream = homelab_common::env_or("AI_GATE_UPSTREAM", "http://127.0.0.1:8086")
            .trim_end_matches('/')
            .to_string();
        Ok(Self {
            listen: homelab_common::env_or("AI_GATE_LISTEN", "127.0.0.1:8094"),
            upstream,
            max_inflight,
            max_queued,
            queue_timeout: Duration::from_secs(queue_timeout_secs),
            upstream_timeout: Duration::from_secs(upstream_timeout_secs),
            max_body_bytes,
        })
    }
}

#[derive(Debug, Default)]
struct Counters {
    total: AtomicU64,
    rejected_full: AtomicU64,
    queue_timeouts: AtomicU64,
    upstream_errors: AtomicU64,
    upstream_ok: AtomicU64,
}

#[derive(Clone)]
struct AppState {
    settings: Settings,
    semaphore: Arc<Semaphore>,
    queued: Arc<AtomicUsize>,
    counters: Arc<Counters>,
    client: reqwest::Client,
}

fn decide_queue(
    inflight_permits: usize,
    queued: usize,
    max_queued: usize,
) -> Result<bool, GateFull> {
    // Returns true when the caller may wait for a permit, false when it holds
    // one already. Pure so unit tests cover the backpressure boundary.
    if inflight_permits > 0 {
        return Ok(false);
    }
    if queued >= max_queued {
        return Err(GateFull);
    }
    Ok(true)
}

async fn proxy_handler(
    State(state): State<AppState>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    body: Bytes,
) -> Response {
    state.counters.total.fetch_add(1, Ordering::Relaxed);
    if body.len() > state.settings.max_body_bytes {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            axum::Json(json!({"error": "request body exceeds ai-gate limit"})),
        )
            .into_response();
    }

    let immediate = state.semaphore.try_acquire();
    let _permit = match immediate {
        Ok(permit) => Some(permit),
        Err(_) => {
            let queued_now = state.queued.load(Ordering::SeqCst);
            match decide_queue(0, queued_now, state.settings.max_queued) {
                Err(_) => {
                    state.counters.rejected_full.fetch_add(1, Ordering::Relaxed);
                    return (
                        StatusCode::TOO_MANY_REQUESTS,
                        [(header::RETRY_AFTER, "15")],
                        axum::Json(
                            json!({"error": "local AI is busy; queue full", "retry_after_secs": 15}),
                        ),
                    )
                        .into_response();
                }
                Ok(_) => {
                    state.queued.fetch_add(1, Ordering::SeqCst);
                    let wait = tokio::time::timeout(
                        state.settings.queue_timeout,
                        state.semaphore.acquire(),
                    );
                    let permit = match wait.await {
                        Err(_) => {
                            state.queued.fetch_sub(1, Ordering::SeqCst);
                            state
                                .counters
                                .queue_timeouts
                                .fetch_add(1, Ordering::Relaxed);
                            return (
                                StatusCode::GATEWAY_TIMEOUT,
                                axum::Json(json!({
                                    "error": "local AI queue wait timed out; try again shortly",
                                })),
                            )
                                .into_response();
                        }
                        Ok(Err(_)) => {
                            state.queued.fetch_sub(1, Ordering::SeqCst);
                            return (
                                StatusCode::SERVICE_UNAVAILABLE,
                                axum::Json(json!({"error": "local AI gate is shutting down"})),
                            )
                                .into_response();
                        }
                        Ok(Ok(permit)) => permit,
                    };
                    state.queued.fetch_sub(1, Ordering::SeqCst);
                    Some(permit)
                }
            }
        }
    };

    let path = uri.path().to_string();
    let mut target = format!("{}{}", state.settings.upstream, path);
    if !query.is_empty() {
        let qs = serde_urlencoded::to_string(&query).unwrap_or_default();
        if !qs.is_empty() {
            target.push('?');
            target.push_str(&qs);
        }
    }

    let mut upstream_request = state
        .client
        .request(method.clone(), target)
        .body(body.to_vec());
    if let Some(content_type) = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
    {
        upstream_request = upstream_request.header(header::CONTENT_TYPE, content_type);
    }
    if let Some(accept) = headers.get(header::ACCEPT).and_then(|v| v.to_str().ok()) {
        upstream_request = upstream_request.header(header::ACCEPT, accept);
    }

    let upstream_response = match upstream_request.send().await {
        Ok(response) => response,
        Err(_) => {
            state
                .counters
                .upstream_errors
                .fetch_add(1, Ordering::Relaxed);
            return (
                StatusCode::BAD_GATEWAY,
                axum::Json(json!({"error": "local AI upstream is unavailable"})),
            )
                .into_response();
        }
    };
    let status = StatusCode::from_u16(upstream_response.status().as_u16())
        .unwrap_or(StatusCode::BAD_GATEWAY);
    let response_content_type = upstream_response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json")
        .to_string();
    let response_bytes = match upstream_response.bytes().await {
        Ok(bytes) => bytes,
        Err(_) => {
            state
                .counters
                .upstream_errors
                .fetch_add(1, Ordering::Relaxed);
            return (
                StatusCode::BAD_GATEWAY,
                axum::Json(json!({"error": "local AI upstream closed the response"})),
            )
                .into_response();
        }
    };
    if status.is_success() {
        state.counters.upstream_ok.fetch_add(1, Ordering::Relaxed);
    } else {
        state
            .counters
            .upstream_errors
            .fetch_add(1, Ordering::Relaxed);
    }
    (
        status,
        [(header::CONTENT_TYPE, response_content_type)],
        response_bytes.to_vec(),
    )
        .into_response()
}

async fn health_handler(State(state): State<AppState>) -> impl IntoResponse {
    let queued = state.queued.load(Ordering::SeqCst);
    let available = state.semaphore.available_permits();
    axum::Json(json!({
        "status": "ok",
        "service": "ai-gate",
        "upstream": state.settings.upstream,
        "max_inflight": state.settings.max_inflight,
        "max_queued": state.settings.max_queued,
        "queued": queued,
        "available_permits": available,
    }))
}

async fn metrics_handler(State(state): State<AppState>) -> impl IntoResponse {
    let body = format!(
        "# HELP ai_gate_requests_total Total proxied requests.\n\
         # TYPE ai_gate_requests_total counter\n\
         ai_gate_requests_total {}\n\
         # HELP ai_gate_rejected_full_total Requests rejected with 429 because the queue was full.\n\
         # TYPE ai_gate_rejected_full_total counter\n\
         ai_gate_rejected_full_total {}\n\
         # HELP ai_gate_queue_timeouts_total Requests that waited out the queue timeout.\n\
         # TYPE ai_gate_queue_timeouts_total counter\n\
         ai_gate_queue_timeouts_total {}\n\
         # HELP ai_gate_upstream_ok_total Upstream 2xx-3xx responses.\n\
         # TYPE ai_gate_upstream_ok_total counter\n\
         ai_gate_upstream_ok_total {}\n\
         # HELP ai_gate_upstream_errors_total Upstream failures and non-2xx responses.\n\
         # TYPE ai_gate_upstream_errors_total counter\n\
         ai_gate_upstream_errors_total {}\n\
         # HELP ai_gate_queued_current Currently waiting requests.\n\
         # TYPE ai_gate_queued_current gauge\n\
         ai_gate_queued_current {}\n\
         # HELP ai_gate_available_permits Currently free upstream slots.\n\
         # TYPE ai_gate_available_permits gauge\n\
         ai_gate_available_permits {}\n",
        state.counters.total.load(Ordering::Relaxed),
        state.counters.rejected_full.load(Ordering::Relaxed),
        state.counters.queue_timeouts.load(Ordering::Relaxed),
        state.counters.upstream_ok.load(Ordering::Relaxed),
        state.counters.upstream_errors.load(Ordering::Relaxed),
        state.queued.load(Ordering::SeqCst),
        state.semaphore.available_permits(),
    );
    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], body)
}

fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health_handler))
        .route("/metrics", get(metrics_handler))
        .route("/v1/{*path}", any(proxy_handler))
        .with_state(state)
}

// serde_urlencoded is not in the workspace; encode the small flat query map
// locally so no new dependency is needed.
mod serde_urlencoded {
    use std::collections::HashMap;

    pub fn to_string(query: &HashMap<String, String>) -> Result<String, String> {
        let mut parts = Vec::with_capacity(query.len());
        let mut keys: Vec<&String> = query.keys().collect();
        keys.sort();
        for key in keys {
            let value = &query[key];
            parts.push(format!("{}={}", encode(key), encode(value)));
        }
        Ok(parts.join("&"))
    }

    fn encode(input: &str) -> String {
        let mut out = String::with_capacity(input.len());
        for byte in input.bytes() {
            match byte {
                b'0'..=b'9' | b'A'..=b'Z' | b'a'..=b'z' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(byte as char);
                }
                _ => out.push_str(&format!("%{byte:02X}")),
            }
        }
        out
    }
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let settings = match Settings::from_env() {
        Ok(settings) => settings,
        Err(error) => {
            homelab_common::log_startup_failed("ai-gate", &error);
            return std::process::ExitCode::FAILURE;
        }
    };
    let address: SocketAddr = match settings.listen.parse() {
        Ok(address) => address,
        Err(error) => {
            homelab_common::log_startup_failed(
                "ai-gate",
                &format!("invalid listen address: {error}"),
            );
            return std::process::ExitCode::FAILURE;
        }
    };
    // Only loopback listeners are supported; the upstream has no auth.
    let is_loopback = matches!(address.ip(), std::net::IpAddr::V4(ip) if ip.is_loopback());
    if !is_loopback {
        homelab_common::log_startup_failed(
            "ai-gate",
            "AI_GATE_LISTEN must be a 127.x loopback address",
        );
        return std::process::ExitCode::FAILURE;
    }
    let state = AppState {
        semaphore: Arc::new(Semaphore::new(settings.max_inflight)),
        queued: Arc::new(AtomicUsize::new(0)),
        counters: Arc::new(Counters::default()),
        client: match reqwest::Client::builder()
            .timeout(settings.upstream_timeout + Duration::from_secs(5))
            .build()
        {
            Ok(client) => client,
            Err(error) => {
                homelab_common::log_startup_failed(
                    "ai-gate",
                    &format!("client build failed: {error}"),
                );
                return std::process::ExitCode::FAILURE;
            }
        },
        settings: settings.clone(),
    };
    let app = build_router(state);
    let listener = match tokio::net::TcpListener::bind(address).await {
        Ok(listener) => listener,
        Err(error) => {
            homelab_common::log_startup_failed("ai-gate", &format!("bind failed: {error}"));
            return std::process::ExitCode::FAILURE;
        }
    };
    homelab_common::log_server_started("ai-gate", &settings.listen);
    if let Err(error) = axum::serve(listener, app)
        .with_graceful_shutdown(homelab_common::shutdown_signal())
        .await
    {
        homelab_common::log_startup_failed("ai-gate", &format!("server error: {error}"));
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn immediate_permit_never_queues() {
        assert!(!decide_queue(1, 99, 0).unwrap());
    }

    #[test]
    fn full_queue_is_rejected() {
        assert!(decide_queue(0, 2, 2).is_err());
        assert!(decide_queue(0, 3, 2).is_err());
    }

    #[test]
    fn waiting_is_allowed_below_capacity() {
        assert!(decide_queue(0, 0, 2).unwrap());
        assert!(decide_queue(0, 1, 2).unwrap());
    }

    #[test]
    fn query_encoding_sorts_and_escapes() {
        let mut query = HashMap::new();
        query.insert("b key".to_string(), "a&b".to_string());
        query.insert("a".to_string(), "1".to_string());
        assert_eq!(
            serde_urlencoded::to_string(&query).unwrap(),
            "a=1&b%20key=a%26b"
        );
    }

    #[test]
    fn rejects_invalid_settings() {
        std::env::set_var("AI_GATE_MAX_INFLIGHT", "0");
        let result = Settings::from_env();
        std::env::remove_var("AI_GATE_MAX_INFLIGHT");
        assert!(result.is_err());
    }
}
