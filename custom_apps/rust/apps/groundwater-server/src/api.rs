//! HTTP API and static frontend hosting.
//!
//! Bound to loopback and reached only through the auth gateway, which
//! authenticates the caller and forwards identity headers. Every route
//! re-checks the role locally because the gateway's group check is
//! host-level, not per-route.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::broadcast::error::RecvError;

use crate::config::Settings;
use crate::db;
use crate::identity::{role_for, Identity, Role};
use crate::telemetry;
use crate::ingest::{EventBus, IngestStats};

/// Hard cap on message-log rows a single request may return.
const MAX_LOG_ROWS: i64 = 500;

/// Heartbeat interval for the event stream, so proxies do not drop an idle
/// connection.
const EVENT_HEARTBEAT_SECONDS: u64 = 15;

#[derive(Clone)]
pub struct AppState {
    pub settings: Arc<Settings>,
    pub db: Arc<tokio_postgres::Client>,
    pub bus: EventBus,
    pub stats: Arc<tokio::sync::Mutex<IngestStats>>,
}

pub async fn serve(state: AppState, frontend_dir: Option<PathBuf>) -> Result<(), String> {
    let address = state.settings.address.clone();
    let port = state.settings.port;

    let mut router = Router::new()
        .route("/healthz", get(health))
        .route("/api/status", get(api_status))
        .route("/api/devices", get(api_devices))
        .route("/api/series", get(api_series))
        .route("/api/messages", get(api_messages))
        .route("/api/events", get(api_events));

    // The frontend is a single-page client app, so anything that is not an API
    // route and not a real asset falls back to index.html and the client-side
    // router resolves the view.
    router = match frontend_dir {
        Some(dir) => router.fallback(get(static_shell).with_state(dir)),
        None => router.fallback(|| async { (StatusCode::NOT_FOUND, "not found") }),
    };

    let app = router
        .with_state(state)
        .layer(axum::middleware::from_fn(security_headers));

    let listener = tokio::net::TcpListener::bind((address.as_str(), port))
        .await
        .map_err(|err| format!("failed to bind {address}:{port}: {err}"))?;
    homelab_common::log_server_started("groundwater-server", &format!("{address}:{port}"));
    axum::serve(listener, app)
        .with_graceful_shutdown(homelab_common::shutdown_signal())
        .await
        .map_err(|err| format!("server error: {err}"))
}

/// Baseline security headers applied to every response.
async fn security_headers(request: axum::extract::Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    response
}

async fn health() -> &'static str {
    "ok"
}

/// The caller's role, or the response to send instead.
type GateResult = Result<Role, Response>;

fn gate(headers: &HeaderMap) -> GateResult {
    let identity = Identity::from_headers(headers).map_err(|_| {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "not signed in" })),
        )
            .into_response()
    })?;
    role_for(&identity).ok_or_else(|| {
        (
            StatusCode::FORBIDDEN,
            Json(json!({
                "error": "your account is not a member of this app's access groups"
            })),
        )
            .into_response()
    })
}

async fn api_status(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, Response> {
    gate(&headers)?;
    let stats = state.stats.lock().await.clone();
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    Ok(Json(json!({
        "service": "groundwater-server",
        "broker": {
            "configured": state.settings.mqtt.is_some(),
            "endpoint": state
                .settings
                .mqtt
                .as_ref()
                .map(|mqtt| format!("{}:{}", mqtt.host, mqtt.port)),
            "connected": stats.connected,
            "lastError": stats.last_error,
        },
        "ingest": {
            "readingsAccepted": stats.readings_accepted,
            "readingsDuplicate": stats.readings_duplicate,
            "readingsRejected": stats.readings_rejected,
            "otherMessages": stats.other_messages,
        },
        "topics": {
            "reading": state.settings.topics.reading,
            "deviceStatus": state.settings.topics.device_status,
        },
        "devices": devices.len(),
        "retentionDays": state.settings.retention_days,
    }))
    .into_response())
}

async fn api_devices(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, Response> {
    gate(&headers)?;
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    Ok(Json(json!({ "devices": devices })).into_response())
}

#[derive(Debug, Deserialize)]
struct SeriesParams {
    device: String,
    hours: Option<i64>,
    bucket: Option<i64>,
}

async fn api_series(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SeriesParams>,
) -> Result<Response, Response> {
    gate(&headers)?;
    let device = params.device.trim();
    if device.is_empty() {
        return Err(bad_request("device is required"));
    }
    // Clamp so a wide window or a tiny bucket cannot materialise an unbounded
    // result set for the browser.
    let hours = params
        .hours
        .unwrap_or(db::DEFAULT_WINDOW_HOURS)
        .clamp(1, 24 * 365);
    let bucket = params.bucket.unwrap_or(0).clamp(0, 24 * 60);
    // A logger's clock comes from GPS and can sit ahead of this host's clock,
    // so the upper bound is padded. Without this the most recent readings — the
    // ones an operator is looking at — would be filtered out. The tolerance
    // matches the plausibility check so the chart can never hide a reading the
    // ingest side accepted.
    let to = chrono::Utc::now()
        + chrono::Duration::days(telemetry::MAX_QUERY_FUTURE_SKEW_DAYS);
    let from = to - chrono::Duration::hours(hours);
    let series = db::device_series(
        &state.db,
        device,
        db::SeriesQuery {
            from,
            to,
            bucket_minutes: bucket,
        },
    )
    .await
    .map_err(db_error)?;
    Ok(Json(json!({ "series": series })).into_response())
}

#[derive(Debug, Deserialize)]
struct MessageParams {
    device: Option<String>,
    limit: Option<i64>,
}

async fn api_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<MessageParams>,
) -> Result<Response, Response> {
    gate(&headers)?;
    let limit = params.limit.unwrap_or(100).clamp(1, MAX_LOG_ROWS);
    let messages = db::list_messages(
        &state.db,
        params
            .device
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty()),
        limit,
    )
    .await
    .map_err(db_error)?;
    Ok(Json(json!({ "messages": messages })).into_response())
}

/// Server-sent events stream of live ingest and presence updates.
async fn api_events(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, Response> {
    gate(&headers)?;
    let receiver = state.bus.subscribe();

    let stream = futures_util::stream::unfold(
        (receiver, tokio::time::interval(Duration::from_secs(EVENT_HEARTBEAT_SECONDS))),
        move |(mut receiver, mut heartbeat)| async move {
            tokio::select! {
                event = receiver.recv() => match event {
                    Ok(event) => {
                        let payload = serde_json::to_string(&event).unwrap_or_default();
                        Some((Ok::<_, std::convert::Infallible>(format!("data: {payload}\n\n")), (receiver, heartbeat)))
                    }
                    // Sender dropped: the service is shutting down.
                    Err(RecvError::Closed) => None,
                    // A lagging receiver missed events; ask the client to
                    // resync rather than silently dropping the gap.
                    Err(RecvError::Lagged(missed)) => {
                        Some((Ok(format!("event: resync\ndata: {{\"type\":\"resync\",\"missed\":{missed}}}\n\n")), (receiver, heartbeat)))
                    }
                },
                _ = heartbeat.tick() => {
                    Some((Ok(": keepalive\n\n".to_string()), (receiver, heartbeat)))
                }
            }
        },
    );

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(header::CONNECTION, "keep-alive")
        .body(axum::body::Body::from_stream(stream))
        .expect("static response builder is valid"))
}

/// Serves the SPA shell for any non-API path.
async fn static_shell(
    State(dir): State<PathBuf>,
    axum::extract::OriginalUri(uri): axum::extract::OriginalUri,
) -> Response {
    serve_asset(&dir, uri.path()).await
}

/// Serves a built asset, falling back to the SPA shell when the path does not
/// exist so the client router can resolve it.
async fn serve_asset(dir: &Path, relative: &str) -> Response {
    if let Some(decoded) = homelab_common::decode_relative_path(relative) {
        if !decoded.as_os_str().is_empty() {
            match homelab_common::read_static_file(dir, &decoded).await {
                Ok(body) => {
                    let content_type =
                        homelab_common::content_type_for_path(&decoded);
                    let cache_control = homelab_common::cache_control_for_path(&decoded);
                    return (
                        StatusCode::OK,
                        [
                            (header::CONTENT_TYPE, content_type.to_string()),
                            (header::CACHE_CONTROL, cache_control.to_string()),
                        ],
                        body,
                    )
                        .into_response();
                }
                Err(homelab_common::StaticFileError::NotFound)
                | Err(homelab_common::StaticFileError::EscapesRoot) => {}
                Err(homelab_common::StaticFileError::Io(err)) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("frontend asset read failed: {err}"),
                    )
                        .into_response();
                }
            }
        }
    }

    match homelab_common::read_static_file(dir, Path::new("index.html")).await {
        Ok(body) => (
            StatusCode::OK,
            [
                // The shell must revalidate so a new deploy is picked up.
                (header::CONTENT_TYPE, "text/html; charset=utf-8".to_string()),
                (header::CACHE_CONTROL, "no-cache".to_string()),
            ],
            body,
        )
            .into_response(),
        Err(err) => (
            StatusCode::NOT_FOUND,
            format!("frontend asset unavailable: {err}"),
        )
            .into_response(),
    }
}

fn db_error(err: String) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": err })),
    )
        .into_response()
}

fn bad_request(message: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(json!({ "error": message })),
    )
        .into_response()
}