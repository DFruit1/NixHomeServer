//! HTTP API and the inspection page.
//!
//! Bound to loopback and reached only through the auth gateway, which
//! authenticates the caller and forwards identity headers. Every route
//! re-checks the role locally because the gateway's group check is
//! host-level, not per-route (`GWAPP-20261023-slice1` §1).
//!
//! Read endpoints answer for the viewer group; the raw delivery log — which
//! contains unattributed payloads — requires the operator group.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path as AxumPath, Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::broadcast::error::RecvError;

use crate::adapter::{DUPLICATE_WINDOW_MINUTES, MAX_PAYLOAD_BYTES};
use crate::clock::MAX_FUTURE_SKEW_HOURS;
use crate::config::Settings;
use crate::db;
use crate::identity::{role_for, Identity, Role};
use crate::ingest::{EventBus, IngestStats};
use crate::profiles::ALL_PROFILES;
use crate::telemetry::GWL_ABS_LIMIT_M;
use crate::ui;

/// Hard cap on delivery-log rows a single request may return.
const MAX_LOG_ROWS: i64 = 500;

/// Heartbeat interval for the event stream, so proxies do not drop an idle
/// connection.
const EVENT_HEARTBEAT_SECONDS: u64 = 15;

/// Hours of history the inspection page shows by default.
const PAGE_HISTORY_HOURS: i64 = 24;

/// Bucket width the inspection page asks for.
const PAGE_BUCKET_MINUTES: i64 = 15;

#[derive(Clone)]
pub struct AppState {
    pub settings: Arc<Settings>,
    pub db: Arc<tokio_postgres::Client>,
    pub bus: EventBus,
    pub stats: Arc<tokio::sync::Mutex<IngestStats>>,
}

pub async fn serve(state: AppState) -> Result<(), String> {
    let address = state.settings.address.clone();
    let port = state.settings.port;

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/", get(page))
        .route("/api/status", get(api_status))
        .route("/api/devices", get(api_devices))
        .route("/api/devices/{device_id}", get(api_device))
        .route("/api/series", get(api_series))
        // The documented raw-log name, plus its delivery-oriented alias.
        .route("/api/messages", get(api_deliveries))
        .route("/api/deliveries", get(api_deliveries))
        .route("/api/events", get(api_events))
        .fallback(not_found)
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
    // The page is a server-rendered document with no inline script; keep it
    // that way so a payload can never become executable content.
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'",
        ),
    );
    response
}

/// Liveness only: no identity, no data. The listener is loopback-bound.
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

/// The inspection page: latest plausible event plus history for one device.
#[derive(Debug, Deserialize)]
struct PageParams {
    device: Option<String>,
    hours: Option<i64>,
}

async fn page(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<PageParams>,
) -> Result<Response, Response> {
    gate(&headers)?;
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    let selected = params
        .device
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string())
        .or_else(|| devices.first().map(|device| device.device_id.clone()));

    let mut view = ui::FleetView::new(devices, selected.clone());
    if let Some(device_id) = selected.as_deref() {
        let hours = clamp_hours(params.hours.or(Some(PAGE_HISTORY_HOURS)));
        let to = chrono::Utc::now() + chrono::Duration::hours(MAX_FUTURE_SKEW_HOURS);
        let from = to - chrono::Duration::hours(hours);
        let series = db::device_series(
            &state.db,
            device_id,
            db::SeriesQuery {
                from,
                to,
                bucket_minutes: PAGE_BUCKET_MINUTES,
            },
        )
        .await
        .map_err(db_error)?;
        view.history = series.points;
        view.quarantine_note = view
            .selected()
            .map(|device| {
                format!(
                    "{} delivery/deliveries quarantined for this device; they are recorded in the delivery log and never joined to the history above",
                    device.quarantined_deliveries
                )
            });
    }

    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        ui::render(&view),
    )
        .into_response())
}

async fn api_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, Response> {
    gate(&headers)?;
    let stats = state.stats.lock().await.clone();
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    Ok(Json(json!({
        "service": "groundwater-server",
        "slice": "server-side-synthetic",
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
            "deliveries": stats.deliveries,
            "observations": stats.observations,
            "redeliveryCandidates": stats.redelivery_candidates,
            "conflicts": stats.conflicts,
            "quarantined": stats.quarantined,
            "lastQuarantineReason": stats.last_quarantine_reason,
        },
        "adapter": {
            "interpretationVersions": ALL_PROFILES
                .iter()
                .map(|profile| profile.interpretation_version())
                .collect::<Vec<_>>(),
            "duplicateWindowMinutes": DUPLICATE_WINDOW_MINUTES,
            "maxPayloadBytes": MAX_PAYLOAD_BYTES,
            "gwlAbsLimitM": GWL_ABS_LIMIT_M,
            "profiles": ALL_PROFILES
                .iter()
                .map(|profile| json!({
                    "id": profile.as_str(),
                    "label": profile.label(),
                    "carriesDeviceId": profile.carries_device_id(),
                }))
                .collect::<Vec<_>>(),
        },
        "devices": devices.len(),
        "retentionDays": state.settings.retention_days,
    }))
    .into_response())
}

async fn api_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, Response> {
    gate(&headers)?;
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    Ok(Json(json!({ "devices": devices })).into_response())
}

async fn api_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Response, Response> {
    gate(&headers)?;
    let device_id = device_id.trim().to_uppercase();
    let devices = db::list_devices(&state.db).await.map_err(db_error)?;
    match devices
        .into_iter()
        .find(|device| device.device_id == device_id)
    {
        Some(device) => Ok(Json(json!({ "device": device })).into_response()),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "unknown device" })),
        )
            .into_response()),
    }
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
    let hours = clamp_hours(params.hours);
    let bucket = clamp_bucket(params.bucket);
    // A logger's clock comes from GPS and can sit ahead of this host's clock,
    // so the upper bound is padded. Without this the most recent readings — the
    // ones an operator is looking at — would be filtered out.
    let to = chrono::Utc::now() + chrono::Duration::hours(MAX_FUTURE_SKEW_HOURS);
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
struct DeliveryParams {
    device: Option<String>,
    limit: Option<i64>,
}

/// The raw delivery log, including quarantined traffic.
///
/// Operator-only: it contains payloads that were deliberately not attributed to
/// any device, which a plain viewer should not be able to enumerate.
async fn api_deliveries(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<DeliveryParams>,
) -> Result<Response, Response> {
    let role = gate(&headers)?;
    if role != Role::Operator {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "the delivery log requires the operator role" })),
        )
            .into_response());
    }
    let limit = clamp_limit(params.limit);
    let deliveries = db::list_deliveries(
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
    Ok(Json(json!({ "deliveries": deliveries })).into_response())
}

/// Server-sent events stream of live ingest updates.
async fn api_events(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, Response> {
    gate(&headers)?;
    let receiver = state.bus.subscribe();

    let stream = futures_util::stream::unfold(
        (
            receiver,
            tokio::time::interval(Duration::from_secs(EVENT_HEARTBEAT_SECONDS)),
        ),
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

async fn not_found() -> Response {
    (StatusCode::NOT_FOUND, "not found").into_response()
}

/// Query window in hours, clamped so a wide request stays bounded.
fn clamp_hours(hours: Option<i64>) -> i64 {
    hours.unwrap_or(db::DEFAULT_WINDOW_HOURS).clamp(1, 24 * 365)
}

/// Downsampling bucket in minutes, clamped; `0` means raw points.
fn clamp_bucket(bucket: Option<i64>) -> i64 {
    bucket.unwrap_or(0).clamp(0, 24 * 60)
}

/// Raw-log row limit, clamped.
fn clamp_limit(limit: Option<i64>) -> i64 {
    limit.unwrap_or(100).clamp(1, MAX_LOG_ROWS)
}

fn db_error(err: String) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": err })),
    )
        .into_response()
}

fn bad_request(message: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": message }))).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_bounds_are_clamped_to_the_documented_limits() {
        assert_eq!(clamp_hours(None), db::DEFAULT_WINDOW_HOURS);
        assert_eq!(clamp_hours(Some(0)), 1);
        assert_eq!(clamp_hours(Some(-5)), 1);
        assert_eq!(clamp_hours(Some(1_000_000)), 24 * 365);

        assert_eq!(clamp_bucket(None), 0);
        assert_eq!(clamp_bucket(Some(-1)), 0);
        assert_eq!(clamp_bucket(Some(5)), 5);
        assert_eq!(clamp_bucket(Some(1_000_000)), 24 * 60);

        assert_eq!(clamp_limit(None), 100);
        assert_eq!(clamp_limit(Some(0)), 1);
        assert_eq!(clamp_limit(Some(-1)), 1);
        assert_eq!(clamp_limit(Some(1_000_000)), MAX_LOG_ROWS);
    }
}
