//! Gateway-authenticated JSON API, ACL-scoped streams and packaged Qwik SPA.
use crate::{
    config::Settings,
    db,
    identity::{role_for, Identity, Role},
    ingest::{EventBus, IngestStats, LiveEvent},
    platform,
};
use axum::{
    extract::{Path as AxumPath, Query, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use futures_util::{StreamExt, TryStreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    path::{Component, Path},
    sync::Arc,
    time::Duration,
};
#[derive(Clone)]
pub struct AppState {
    pub settings: Arc<Settings>,
    pub db: Arc<tokio_postgres::Client>,
    pub bus: EventBus,
    pub stats: Arc<tokio::sync::Mutex<IngestStats>>,
}
type ApiResult = Result<Response, Response>;
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/status", get(status))
        .route("/api/devices", get(devices))
        .route("/api/devices/{device_id}", get(device))
        .route("/api/series", get(series))
        .route("/api/alerts", get(alerts))
        .route("/api/commands", get(commands))
        .route("/api/messages", get(deliveries))
        .route("/api/deliveries", get(deliveries))
        .route("/api/export", get(export))
        .route("/api/events", get(events))
        .route("/api/devices/{device_id}/config", post(configure))
        .route("/api/devices/{device_id}/commands", post(enqueue))
        .route(
            "/api/devices/{device_id}/commands/{command_id}/cancel",
            post(cancel),
        )
        .fallback(frontend)
        .with_state(state)
        .layer(axum::middleware::from_fn(boundary))
}
pub async fn serve(state: AppState) -> Result<(), String> {
    let endpoint = format!("{}:{}", state.settings.address, state.settings.port);
    let listener = tokio::net::TcpListener::bind(&endpoint)
        .await
        .map_err(|e| e.to_string())?;
    homelab_common::log_server_started("groundwater-server", &endpoint);
    axum::serve(listener, router(state))
        .with_graceful_shutdown(homelab_common::shutdown_signal())
        .await
        .map_err(|e| e.to_string())
}
fn error(code: StatusCode, message: &str) -> Response {
    (code, Json(json!({"error":message}))).into_response()
}
fn bad(message: &str) -> Response {
    error(StatusCode::BAD_REQUEST, message)
}
fn database(e: String) -> Response {
    eprintln!("groundwater API: {e}");
    error(StatusCode::INTERNAL_SERVER_ERROR, "database request failed")
}
fn gate(headers: &HeaderMap) -> Result<(Identity, Role), Response> {
    let identity = Identity::from_headers(headers)
        .map_err(|_| error(StatusCode::UNAUTHORIZED, "not signed in"))?;
    let role = role_for(&identity).ok_or_else(|| {
        error(
            StatusCode::FORBIDDEN,
            "your account is not a member of this app's access groups",
        )
    })?;
    Ok((identity, role))
}
fn operator(headers: &HeaderMap) -> Result<Identity, Response> {
    let (i, r) = gate(headers)?;
    if r != Role::Operator {
        return Err(error(StatusCode::FORBIDDEN, "operator role required"));
    }
    Ok(i)
}
async fn authorize(s: &AppState, h: &HeaderMap, device: &str) -> Result<String, Response> {
    let (i, r) = gate(h)?;
    let device = crate::adapter::canonical_device_id(device);
    if !platform::allowed(&s.db, &i.username, &device, r == Role::Operator)
        .await
        .map_err(database)?
    {
        return Err(error(StatusCode::NOT_FOUND, "device not found"));
    }
    Ok(device)
}
async fn ids(s: &AppState, h: &HeaderMap) -> Result<Vec<String>, Response> {
    let (i, r) = gate(h)?;
    platform::visible_ids(&s.db, &i.username, r == Role::Operator)
        .await
        .map_err(database)
}
/// Authenticate before extraction; normalize JSON/query/path/body-limit and
/// method rejections so every API failure is a JSON envelope.
async fn boundary(request: Request, next: Next) -> Response {
    let api = request.uri().path() == "/api" || request.uri().path().starts_with("/api/");
    if request.uri().path() != "/healthz" {
        if let Err(e) = gate(request.headers()) {
            return e;
        }
    }
    if api
        && !matches!(
            *request.method(),
            axum::http::Method::GET | axum::http::Method::HEAD | axum::http::Method::OPTIONS
        )
    {
        if let Err(e) = operator(request.headers()) {
            return e;
        }
    }
    let mut response = next.run(request).await;
    if api
        && (response.status().is_client_error() || response.status().is_server_error())
        && !response
            .headers()
            .get(header::CONTENT_TYPE)
            .is_some_and(|v| v.as_bytes().starts_with(b"application/json"))
    {
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), 64 * 1024)
            .await
            .unwrap_or_default();
        let text = std::str::from_utf8(&body).unwrap_or("invalid request");
        response = error(
            status,
            if text.is_empty() {
                status.canonical_reason().unwrap_or("request failed")
            } else {
                text
            },
        );
    }
    let h = response.headers_mut();
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    h.insert(header::CONTENT_SECURITY_POLICY,HeaderValue::from_static("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"));
    if api && !h.contains_key(header::CACHE_CONTROL) {
        h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    response
}
async fn status(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    let (i, r) = gate(&h)?;
    let stats = s.stats.lock().await.clone();
    let visible = ids(&s, &h).await?;
    Ok(Json(json!({"service":"groundwater-server","user":{"username":i.username,"role":if r==Role::Operator{"operator"}else{"viewer"}},"broker":{"configured":s.settings.mqtt.is_some(),"connected":stats.connected,"endpoint":s.settings.mqtt.as_ref().map(|m|format!("{}:{}",m.host,m.port)),"lastError":if r==Role::Operator{stats.last_error}else{None}},"ingest":{"deliveries":stats.deliveries,"observations":stats.observations,"redeliveryCandidates":stats.redelivery_candidates,"conflicts":stats.conflicts,"quarantined":stats.quarantined},"adapter":{"profiles":crate::profiles::ALL_PROFILES.iter().map(|p|json!({"id":p.as_str(),"label":p.label(),"carriesDeviceId":p.carries_device_id()})).collect::<Vec<_>>()},"devices":visible.len(),"retentionDays":s.settings.retention_days})).into_response())
}
async fn devices(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    let visible = ids(&s, &h).await?;
    let devices: Vec<_> = db::list_devices(&s.db)
        .await
        .map_err(database)?
        .into_iter()
        .filter(|d| visible.contains(&d.device_id))
        .collect();
    Ok(Json(json!({"devices":devices})).into_response())
}
async fn device(
    State(s): State<AppState>,
    h: HeaderMap,
    AxumPath(device): AxumPath<String>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let device = db::list_devices(&s.db)
        .await
        .map_err(database)?
        .into_iter()
        .find(|d| d.device_id == device)
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "device not found"))?;
    Ok(Json(json!({"device":device})).into_response())
}
#[derive(Debug, Default, Deserialize)]
struct Range {
    device: String,
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
    hours: Option<i64>,
    bucket: Option<i64>,
    format: Option<String>,
}
impl Range {
    fn bounds(&self) -> Result<(DateTime<Utc>, DateTime<Utc>), Response> {
        let now = Utc::now();
        let from = self.from.unwrap_or(
            now - chrono::Duration::hours(
                self.hours
                    .unwrap_or(db::DEFAULT_WINDOW_HOURS)
                    .clamp(1, 24 * 365),
            ),
        );
        let to = self
            .to
            .unwrap_or(now + chrono::Duration::hours(crate::clock::MAX_FUTURE_SKEW_HOURS));
        if from >= to {
            return Err(bad("from must be earlier than to"));
        }
        Ok((from, to))
    }
}
async fn series(State(s): State<AppState>, h: HeaderMap, Query(q): Query<Range>) -> ApiResult {
    let device = authorize(&s, &h, &q.device).await?;
    let (from, to) = q.bounds()?;
    let series = db::device_series(
        &s.db,
        &device,
        db::SeriesQuery {
            from,
            to,
            bucket_minutes: q.bucket.unwrap_or(0).clamp(0, 1440),
        },
    )
    .await
    .map_err(database)?;
    Ok(Json(json!({"series":series})).into_response())
}
#[derive(Deserialize)]
struct List {
    device: Option<String>,
    state: Option<String>,
}
async fn alerts(State(s): State<AppState>, h: HeaderMap, Query(q): Query<List>) -> ApiResult {
    let device = match &q.device {
        Some(d) => Some(authorize(&s, &h, d).await?),
        None => None,
    };
    if q.state
        .as_deref()
        .is_some_and(|v| v != "open" && v != "resolved")
    {
        return Err(bad("state must be open or resolved"));
    }
    let visible = ids(&s, &h).await?;
    Ok(Json(json!({"alerts":platform::alerts(&s.db,&visible,device.as_deref(),q.state.as_deref()).await.map_err(database)?})).into_response())
}
async fn commands(State(s): State<AppState>, h: HeaderMap, Query(q): Query<List>) -> ApiResult {
    let device = match &q.device {
        Some(d) => Some(authorize(&s, &h, d).await?),
        None => None,
    };
    let visible = ids(&s, &h).await?;
    Ok(Json(json!({"commands":platform::commands(&s.db,&visible,device.as_deref()).await.map_err(database)?})).into_response())
}
#[derive(Deserialize)]
struct DeliveryParams {
    device: Option<String>,
    topic: Option<String>,
    since: Option<DateTime<Utc>>,
    limit: Option<i64>,
}
async fn deliveries(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<DeliveryParams>,
) -> ApiResult {
    operator(&h)?;
    let device = q.device.as_deref().map(crate::adapter::canonical_device_id);
    let deliveries = db::filtered_deliveries(
        &s.db,
        device.as_deref(),
        q.topic.as_deref(),
        q.since,
        q.limit.unwrap_or(100).clamp(1, 500),
    )
    .await
    .map_err(database)?;
    Ok(Json(json!({"deliveries":deliveries})).into_response())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigRequest {
    config: Value,
}
async fn configure(
    State(s): State<AppState>,
    h: HeaderMap,
    AxumPath(device): AxumPath<String>,
    Json(q): Json<ConfigRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let wire = crate::commands::project_payload(&q.config).map_err(|e| bad(&e))?;
    let command = platform::queue(
        &s.db,
        &device,
        "project-settings",
        q.config,
        &wire,
        &user.username,
    )
    .await
    .map_err(database)?;
    s.bus.emit(LiveEvent::Command { device_id: device });
    Ok((StatusCode::CREATED, Json(json!({"command":command}))).into_response())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommandRequest {
    kind: String,
    #[serde(default = "empty_payload")]
    payload: Value,
    confirm: Option<String>,
}
fn empty_payload() -> Value {
    json!({})
}
async fn enqueue(
    State(s): State<AppState>,
    h: HeaderMap,
    AxumPath(device): AxumPath<String>,
    Json(q): Json<CommandRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let (payload, wire) =
        crate::commands::command_payload(&q.kind, &q.payload, q.confirm.as_deref())
            .map_err(|e| bad(&e))?;
    let command = platform::queue(&s.db, &device, &q.kind, payload, &wire, &user.username)
        .await
        .map_err(database)?;
    s.bus.emit(LiveEvent::Command { device_id: device });
    Ok((StatusCode::CREATED, Json(json!({"command":command}))).into_response())
}
async fn cancel(
    State(s): State<AppState>,
    h: HeaderMap,
    AxumPath((device, id)): AxumPath<(String, i64)>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let command = platform::cancel(&s.db, &device, id, &user.username)
        .await
        .map_err(database)?
        .ok_or_else(|| {
            error(
                StatusCode::CONFLICT,
                "command is absent or no longer cancellable",
            )
        })?;
    s.bus.emit(LiveEvent::Command { device_id: device });
    Ok(Json(json!({"command":command})).into_response())
}
async fn export(State(s): State<AppState>, h: HeaderMap, Query(q): Query<Range>) -> ApiResult {
    let device = authorize(&s, &h, &q.device).await?;
    let (from, to) = q.bounds()?;
    if q.format.as_deref().is_some_and(|f| f != "csv") {
        return Err(bad("format must be csv"));
    }
    let params: [&(dyn tokio_postgres::types::ToSql + Sync); 3] = [&device, &from, &to];
    let rows=s.db.query_raw("SELECT device_id,recorded_at,received_at,gwl,rssi,battery_v,solar_v,time_quality,duplicate_outcome FROM observations WHERE device_id=$1 AND recorded_at >= $2 AND recorded_at <= $3 ORDER BY recorded_at,id",params).await.map_err(|e|database(e.to_string()))?;
    let body=futures_util::stream::once(async{Ok::<_,std::io::Error>("device_id,recorded_at,received_at,gwl,rssi,battery_v,solar_v,time_quality,duplicate_outcome\r\n".to_owned())}).chain(rows.map_ok(|r|{
        let fields=vec![r.get::<_,String>(0),r.get::<_,DateTime<Utc>>(1).to_rfc3339(),r.get::<_,DateTime<Utc>>(2).to_rfc3339(),r.get::<_,f64>(3).to_string(),r.get::<_,Option<i16>>(4).map(|v|v.to_string()).unwrap_or_default(),r.get::<_,Option<f64>>(5).map(|v|v.to_string()).unwrap_or_default(),r.get::<_,Option<f64>>(6).map(|v|v.to_string()).unwrap_or_default(),r.get::<_,String>(7),r.get::<_,String>(8)];fields.iter().map(|v|csv_field(v)).collect::<Vec<_>>().join(",")+"\r\n"
    }).map_err(std::io::Error::other));
    Ok(Response::builder()
        .header(header::CONTENT_TYPE, "text/csv; charset=utf-8")
        .header(
            header::CONTENT_DISPOSITION,
            "attachment; filename=groundwater-observations.csv",
        )
        .body(axum::body::Body::from_stream(body))
        .unwrap())
}
fn csv_field(v: &str) -> String {
    format!("\"{}\"", v.replace('"', "\"\""))
}
fn event_device(e: &LiveEvent) -> Option<&str> {
    match e {
        LiveEvent::Observation { device_id, .. }
        | LiveEvent::Redelivery { device_id }
        | LiveEvent::Conflict { device_id }
        | LiveEvent::Presence { device_id }
        | LiveEvent::Alert { device_id }
        | LiveEvent::Command { device_id } => Some(device_id),
        _ => None,
    }
}
async fn events(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    let (identity, role) = gate(&h)?;
    let receiver = s.bus.subscribe();
    let db = s.db.clone();
    let stream = futures_util::stream::unfold(
        (
            receiver,
            tokio::time::interval(Duration::from_secs(15)),
            true,
            db,
            identity,
            role,
        ),
        |(mut rx, mut heartbeat, first, db, identity, role)| async move {
            if first {
                return Some((
                    Ok::<_, std::convert::Infallible>(
                        "event: resync\ndata: {\"type\":\"resync\"}\n\n".to_owned(),
                    ),
                    (rx, heartbeat, false, db, identity, role),
                ));
            }
            loop {
                let text = tokio::select! {event=rx.recv()=>match event{
                    Ok(event)=>{let allowed=if let Some(device)=event_device(&event){platform::allowed(&db,&identity.username,device,role==Role::Operator).await.unwrap_or(false)}else{role==Role::Operator};if !allowed{continue}format!("data: {}\n\n",serde_json::to_string(&event).unwrap())},
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_))=>"event: resync\ndata: {\"type\":\"resync\"}\n\n".into(),Err(tokio::sync::broadcast::error::RecvError::Closed)=>return None,
                },_=heartbeat.tick()=>": keepalive\n\n".into()};
                return Some((Ok(text), (rx, heartbeat, false, db, identity, role)));
            }
        },
    );
    Ok(Response::builder()
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("x-accel-buffering", "no")
        .body(axum::body::Body::from_stream(stream))
        .unwrap())
}
fn safe_path(p: &str) -> bool {
    !p.contains(['%', '\\', '\0'])
        && Path::new(p.trim_start_matches('/'))
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}
async fn frontend(State(_s): State<AppState>, request: Request) -> Response {
    if request.uri().path() == "/api" || request.uri().path().starts_with("/api/") {
        return error(StatusCode::NOT_FOUND, "API route not found");
    }
    if request.method() != axum::http::Method::GET && request.method() != axum::http::Method::HEAD {
        return error(StatusCode::METHOD_NOT_ALLOWED, "method not allowed");
    }
    let path = request.uri().path();
    if path != "/" && !safe_path(path) {
        return bad("invalid asset path");
    }
    let root = std::env::var("GROUNDWATER_FRONTEND_DIR").unwrap_or_else(|_| "frontend/dist".into());
    let Ok(root) = tokio::fs::canonicalize(root).await else {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "frontend assets are unavailable",
        );
    };
    let relative = path.trim_start_matches('/');
    let requested = root.join(if relative.is_empty() {
        "index.html"
    } else {
        relative
    });
    let resolved = match tokio::fs::canonicalize(&requested).await {
        Ok(p) => p,
        Err(_) => {
            if Path::new(relative).extension().is_some() {
                return error(StatusCode::NOT_FOUND, "asset not found");
            }
            match tokio::fs::canonicalize(root.join("index.html")).await {
                Ok(p) => p,
                Err(_) => return error(StatusCode::NOT_FOUND, "asset not found"),
            }
        }
    };
    if !resolved.starts_with(&root) {
        return bad("invalid asset path");
    }
    match tokio::fs::read(&resolved).await {
        Ok(bytes) => (
            [
                (
                    header::CONTENT_TYPE,
                    homelab_common::content_type_for_path(&resolved),
                ),
                (
                    header::CACHE_CONTROL,
                    homelab_common::cache_control_for_path(&resolved),
                ),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => error(StatusCode::NOT_FOUND, "asset not found"),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn asset_paths_do_not_escape_root() {
        for bad in [
            "/../etc/passwd",
            "/%2e%2e/secret",
            "/assets\\secret",
            "/a/../../b",
        ] {
            assert!(!safe_path(bad))
        }
        assert!(safe_path("/build/q-abc.js"));
    }
    #[test]
    fn csv_quotes_values() {
        assert_eq!(csv_field("a,\"b"), "\"a,\"\"b\"");
    }
    #[test]
    fn rejects_inverted_ranges() {
        let now = Utc::now();
        assert!(Range {
            device: "A".into(),
            from: Some(now),
            to: Some(now),
            ..Default::default()
        }
        .bounds()
        .is_err());
    }
    #[test]
    fn global_events_have_no_device() {
        assert_eq!(
            event_device(&LiveEvent::Quarantine {
                topic: "private".into(),
                reason: "invalid".into()
            }),
            None
        );
    }
    #[tokio::test]
    async fn auth_errors_are_json() {
        let e = gate(&HeaderMap::new()).unwrap_err();
        assert_eq!(e.status(), StatusCode::UNAUTHORIZED);
        let b = axum::body::to_bytes(e.into_body(), 1024).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&b).unwrap()["error"],
            "not signed in"
        );
    }
}
