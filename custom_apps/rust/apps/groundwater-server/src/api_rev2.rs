//! API for protocol revision 2 data and commands. Request/response shapes
//! are documented with examples in `frontend/README.md`
//! ("Protocol revision 2 API"). Every route is scoped by the caller's device
//! permissions exactly like the revision 1 routes; writes need the operator
//! role (enforced again by the `api::boundary` middleware).

use crate::api::{authorize, bad, database, error, operator, ApiResult, AppState};
use crate::ingest::LiveEvent;
use crate::rev2_commands::{self, ConfirmError, QueueOptions};
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio_postgres::{Client, Row};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/devices/{device_id}/health", get(health))
        .route("/api/devices/{device_id}/events", get(events))
        .route("/api/devices/{device_id}/positions", get(positions))
        .route("/api/devices/{device_id}/tilt", get(tilt))
        .route("/api/devices/{device_id}/tests", get(tests))
        .route(
            "/api/devices/{device_id}/settings",
            get(settings).post(change_settings),
        )
        .route("/api/devices/{device_id}/logs", get(logs))
        .route("/api/devices/{device_id}/gaps", get(gaps))
        .route("/api/devices/{device_id}/batches", get(batches))
        .route(
            "/api/devices/{device_id}/files",
            get(files).post(list_files),
        )
        .route(
            "/api/devices/{device_id}/files/downloads",
            get(downloads).post(start_download),
        )
        .route(
            "/api/devices/{device_id}/files/downloads/{download_id}",
            get(download),
        )
        .route(
            "/api/devices/{device_id}/files/downloads/{download_id}/content",
            get(download_content),
        )
        .route(
            "/api/devices/{device_id}/files/downloads/{download_id}/cancel",
            post(cancel_download),
        )
        .route(
            "/api/devices/{device_id}/commands/{command_id}/confirm",
            post(confirm),
        )
}

#[derive(Debug, Default, Deserialize)]
struct Window {
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
    limit: Option<i64>,
    event: Option<String>,
    source: Option<String>,
    state: Option<String>,
    path: Option<String>,
}

impl Window {
    /// Unbounded windows still have to fit PostgreSQL's timestamp range.
    fn from(&self) -> DateTime<Utc> {
        self.from.unwrap_or(DateTime::UNIX_EPOCH)
    }
    fn to(&self) -> DateTime<Utc> {
        self.to
            .unwrap_or_else(|| Utc::now() + chrono::Duration::days(3650))
    }
    fn limit(&self, default: i64) -> i64 {
        self.limit.unwrap_or(default).clamp(1, 5000)
    }
}

fn rows_json(rows: &[Row]) -> Vec<Value> {
    rows.iter().map(|row| row.get::<_, Value>(0)).collect()
}

async fn query_json(
    db: &Client,
    sql: &str,
    params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
) -> Result<Vec<Value>, Response> {
    db.query(sql, params)
        .await
        .map(|rows| rows_json(&rows))
        .map_err(|e| database(e.to_string()))
}

async fn health(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let health = query_json(
        &db,
        "SELECT jsonb_build_object('id',id,'source',source,'recorded_at',recorded_at,'time_source',time_source,
            'device_t',device_t,'time_valid',time_valid,'received_at',received_at,'uptime_s',uptime_s,'csq',csq,
            'bat_mv',bat_mv,'sol_mv',sol_mv,'sd',sd,'sd_free_mb',sd_free_mb,'mram',mram,'unsaved',unsaved,'usable',usable,
            'log',log,'settings_gen',settings_gen,'next_contact_at',next_contact_at,'err',err)
         FROM device_health WHERE device_id=$1 AND recorded_at>=$2 AND recorded_at<=$3
         ORDER BY recorded_at DESC,id DESC LIMIT $4",
        &[&device, &q.from(), &q.to(), &q.limit(500)],
    )
    .await?;
    Ok(Json(json!({"health":health})).into_response())
}

async fn events(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    if q.source
        .as_deref()
        .is_some_and(|v| !matches!(v, "record" | "alert" | "server"))
    {
        return Err(bad("source must be record, alert or server"));
    }
    let db = s.db.get().await.map_err(database)?;
    let events = query_json(
        &db,
        "SELECT jsonb_build_object('id',e.id,'source',e.source,'event',e.event,'log_id',e.log_id,'seq',e.seq,
            'record_type',e.record_type,'recorded_at',e.recorded_at,'time_valid',e.time_valid,'time_rel_s',e.time_rel_s,
            'time_source',e.time_source,'received_at',e.received_at,'details',e.details,
            'confirmed_by_record',CASE WHEN e.source='alert' AND e.seq IS NOT NULL THEN EXISTS(
                SELECT 1 FROM device_events r WHERE r.device_id=e.device_id AND r.source='record' AND r.seq=e.seq) END)
         FROM device_events e
         WHERE e.device_id=$1 AND COALESCE(e.recorded_at,e.received_at)>=$2 AND COALESCE(e.recorded_at,e.received_at)<=$3
           AND ($4::text IS NULL OR e.event=$4) AND ($5::text IS NULL OR e.source=$5)
         ORDER BY COALESCE(e.recorded_at,e.received_at) DESC,e.id DESC LIMIT $6",
        &[&device, &q.from(), &q.to(), &q.event, &q.source, &q.limit(500)],
    )
    .await?;
    Ok(Json(json!({"events":events})).into_response())
}

async fn positions(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let positions = query_json(
        &db,
        "SELECT jsonb_build_object('id',id,'source',source,'log_id',log_id,'seq',seq,'recorded_at',recorded_at,
            'time_valid',time_valid,'time_rel_s',time_rel_s,'time_source',time_source,'received_at',received_at,
            'settings_gen',settings_gen,'reason',reason,'fix',fix,'lat',lat,'lon',lon,'alt_m',alt_m,'hdop',hdop,
            'satellites',satellites,'accel_x_mg',accel_x_mg,'accel_y_mg',accel_y_mg,'accel_z_mg',accel_z_mg,
            'accel_status',accel_status)
         FROM device_positions WHERE device_id=$1 AND COALESCE(recorded_at,received_at)>=$2
           AND COALESCE(recorded_at,received_at)<=$3
         ORDER BY recorded_at DESC NULLS LAST,id DESC LIMIT $4",
        &[&device, &q.from(), &q.to(), &q.limit(500)],
    )
    .await?;
    Ok(Json(json!({"positions":positions})).into_response())
}

async fn tilt(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let tilt = query_json(
        &db,
        "SELECT jsonb_build_object('id',id,'log_id',log_id,'seq',seq,'recorded_at',recorded_at,'time_valid',time_valid,
            'time_rel_s',time_rel_s,'time_source',time_source,'received_at',received_at,'settings_gen',settings_gen,
            'reason',reason,'accel_x_mg',accel_x_mg,'accel_y_mg',accel_y_mg,'accel_z_mg',accel_z_mg,
            'pitch_deg',pitch_deg,'roll_deg',roll_deg,'accel_status',accel_status)
         FROM device_tilt WHERE device_id=$1 AND COALESCE(recorded_at,received_at)>=$2
           AND COALESCE(recorded_at,received_at)<=$3
         ORDER BY recorded_at DESC NULLS LAST,id DESC LIMIT $4",
        &[&device, &q.from(), &q.to(), &q.limit(500)],
    )
    .await?;
    Ok(Json(json!({"tilt":tilt})).into_response())
}

async fn tests(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let tests = query_json(
        &db,
        "SELECT jsonb_build_object('id',id,'source',source,'log_id',log_id,'seq',seq,'recorded_at',recorded_at,
            'time_valid',time_valid,'time_source',time_source,'received_at',received_at,'settings_gen',settings_gen,
            'trigger',trigger,'command_id',command_id,'battery_mv',battery_mv,'solar_mv',solar_mv,'csq',csq,
            'sensor_mv',sensor_mv,'sensor_ma',sensor_ma,'level',level,'sensor_status',sensor_status,
            'status_bits',status_bits,'ok',ok,'details',details)
         FROM device_tests WHERE device_id=$1 AND COALESCE(recorded_at,received_at)>=$2
           AND COALESCE(recorded_at,received_at)<=$3
         ORDER BY COALESCE(recorded_at,received_at) DESC,id DESC LIMIT $4",
        &[&device, &q.from(), &q.to(), &q.limit(100)],
    )
    .await?;
    Ok(Json(json!({"tests":tests})).into_response())
}

async fn settings(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let effective = db
        .query_one(
            "SELECT jsonb_build_object('settings_gen',settings_gen,'settings',settings,'settings_at',settings_at,
                'defaults',$2::jsonb) FROM devices WHERE device_id=$1",
            &[&device, &Value::Object(crate::settings::defaults())],
        )
        .await
        .map_err(|e| database(e.to_string()))?
        .get::<_, Value>(0);
    let history = query_json(
        &db,
        "SELECT jsonb_build_object('id',h.id,'settings_gen',h.settings_gen,'source',h.source,'settings',h.settings,
            'log_id',h.log_id,'seq',h.seq,'command_id',h.command_id,'received_at',h.received_at,'warnings',h.warnings,
            'activated',EXISTS(SELECT 1 FROM observations o WHERE o.device_id=h.device_id AND o.record_type=1 AND o.anchor
                AND o.reading_reason=3 AND o.settings_gen=h.settings_gen))
         FROM device_settings_history h WHERE h.device_id=$1 ORDER BY h.settings_gen DESC NULLS LAST,h.id DESC LIMIT 200",
        &[&device],
    )
    .await?;
    Ok(Json(json!({"effective":effective,"history":history})).into_response())
}

async fn logs(State(s): State<AppState>, h: HeaderMap, Path(device): Path<String>) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let logs = query_json(
        &db,
        "SELECT jsonb_build_object('log_id',l.log_id,'log_hex',upper(lpad(to_hex(l.log_id),8,'0')),
            'payload_schema',l.payload_schema,'first_received_at',l.first_received_at,'last_received_at',l.last_received_at,
            'previous_log_id',l.previous_log_id,'start_reason',l.start_reason,'started_at',l.started_at,
            'firmware_version',l.firmware_version,'mcu_uid',l.mcu_uid,
            'frames',f.frames,'min_seq',f.min_seq,'max_seq',f.max_seq,'decode_errors',f.decode_errors,
            'conflicting_copies',f.conflicting,'resent_copies',f.resent,
            'open_gaps',(SELECT count(*) FROM stream_gaps g WHERE g.device_id=l.device_id AND g.log_id=l.log_id AND g.state IN ('open','requested')),
            'unrecoverable_gaps',(SELECT count(*) FROM stream_gaps g WHERE g.device_id=l.device_id AND g.log_id=l.log_id AND g.state='unrecoverable'),
            'pending_readings',(SELECT count(*) FROM observations o WHERE o.device_id=l.device_id AND o.log_id=l.log_id AND o.recorded_at IS NULL))
         FROM stream_logs l
         CROSS JOIN LATERAL (SELECT count(*) AS frames,min(seq) AS min_seq,max(seq) AS max_seq,
             count(*) FILTER (WHERE decode_error IS NOT NULL) AS decode_errors,
             COALESCE(sum(conflicting_copies),0) AS conflicting,COALESCE(sum(copies-1),0) AS resent
             FROM stream_frames sf WHERE sf.device_id=l.device_id AND sf.log_id=l.log_id) f
         WHERE l.device_id=$1 ORDER BY l.last_received_at DESC",
        &[&device],
    )
    .await?;
    let gaps = gap_rows(&db, &device, None).await?;
    Ok(Json(json!({"logs":logs,"gaps":gaps})).into_response())
}

async fn gap_rows(db: &Client, device: &str, state: Option<&str>) -> Result<Vec<Value>, Response> {
    query_json(
        db,
        "SELECT jsonb_build_object('id',id,'log_id',log_id,'from_seq',from_seq,'to_seq',to_seq,'from_pos',from_pos,
            'to_pos',to_pos,'state',state,'detected_at',detected_at,'attempts',attempts,'last_requested_at',last_requested_at,
            'command_id',command_id,'resolved_at',resolved_at)
         FROM stream_gaps WHERE device_id=$1 AND ($2::text IS NULL OR state=$2)
         ORDER BY (state IN ('open','requested')) DESC,log_id DESC,from_seq LIMIT 500",
        &[&device, &state],
    )
    .await
}

async fn gaps(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    if q.state
        .as_deref()
        .is_some_and(|v| !matches!(v, "open" | "requested" | "unrecoverable" | "filled"))
    {
        return Err(bad(
            "state must be open, requested, unrecoverable or filled",
        ));
    }
    let db = s.db.get().await.map_err(database)?;
    Ok(Json(json!({"gaps":gap_rows(&db, &device, q.state.as_deref()).await?})).into_response())
}

async fn batches(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let batches = query_json(
        &db,
        "SELECT jsonb_build_object('id',id,'received_at',received_at,'channel',channel,'encoding',encoding,'size',size,
            'ok',ok,'error',error,'log_id',log_id,'payload_schema',payload_schema,'first_seq',first_seq,'last_seq',last_seq,
            'start_pos',start_pos,'end_pos',end_pos,'frame_count',frame_count,'flags',flags,
            'resend',(flags & 1)<>0,'gap_before',(flags & 2)<>0,'from_sd',(flags & 4)<>0,
            'frames_valid',frames_valid,'frames_new',frames_new,'frames_duplicate',frames_duplicate,
            'issues',issues,'warnings',warnings,'raw_retained',raw IS NOT NULL)
         FROM stream_batches WHERE device_id=$1 ORDER BY received_at DESC,id DESC LIMIT $2",
        &[&device, &q.limit(100)],
    )
    .await?;
    Ok(Json(json!({"batches":batches})).into_response())
}

async fn files(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<Window>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let listings = query_json(
        &db,
        "SELECT jsonb_build_object('path',path,'page',page,'files',files,'more',more,'command_id',command_id,
            'received_at',received_at)
         FROM device_file_lists WHERE device_id=$1 AND ($2::text IS NULL OR path=$2) ORDER BY path,page",
        &[&device, &q.path],
    )
    .await?;
    Ok(Json(json!({"listings":listings})).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListRequest {
    path: String,
    #[serde(default)]
    page: u16,
}

async fn list_files(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<ListRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    queue_command(
        &s,
        &db,
        &device,
        &user.username,
        Rev2Request {
            op: "file_list",
            args: json!({"path":q.path,"page":q.page}),
            confirm: None,
            auto_confirm: false,
            expires_in_s: None,
            replace: false,
        },
    )
    .await
}

const DOWNLOAD_COLUMNS: &str = "jsonb_build_object('id',id,'path',path,'requested_by',requested_by,'state',state,
    'size',size,'received_bytes',received_bytes,'next_offset',next_offset,'current_command_id',current_command_id,
    'crc32',CASE WHEN crc32 IS NULL THEN NULL ELSE upper(lpad(to_hex(crc32),8,'0')) END,'error',error,
    'created_at',created_at,'updated_at',updated_at,'completed_at',completed_at)";

async fn downloads(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let downloads = query_json(
        &db,
        &format!("SELECT {DOWNLOAD_COLUMNS} FROM file_downloads WHERE device_id=$1 ORDER BY id DESC LIMIT 200"),
        &[&device],
    )
    .await?;
    Ok(Json(json!({"downloads":downloads})).into_response())
}

async fn download(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, id)): Path<(String, i64)>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = query_json(
        &db,
        &format!("SELECT {DOWNLOAD_COLUMNS} FROM file_downloads WHERE device_id=$1 AND id=$2"),
        &[&device, &id],
    )
    .await?;
    let download = rows
        .into_iter()
        .next()
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "download not found"))?;
    Ok(Json(json!({"download":download})).into_response())
}

async fn download_content(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, id)): Path<(String, i64)>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let row = db
        .query_opt(
            "SELECT state,path,content FROM file_downloads WHERE device_id=$1 AND id=$2",
            &[&device, &id],
        )
        .await
        .map_err(|e| database(e.to_string()))?
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "download not found"))?;
    let state: String = row.get(0);
    if state != "complete" {
        return Err(error(StatusCode::CONFLICT, &format!("download is {state}")));
    }
    let path: String = row.get(1);
    let content: Vec<u8> = row.get(2);
    let name: String = path
        .rsplit('/')
        .next()
        .unwrap_or("download")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .collect();
    let name = if name.is_empty() {
        "download".into()
    } else {
        name
    };
    Ok((
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_owned()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{device}-{name}\""),
            ),
        ],
        content,
    )
        .into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DownloadRequest {
    path: String,
}

async fn start_download(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<DownloadRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let mut db = connect_tx(&s).await?;
    let tx = db
        .transaction()
        .await
        .map_err(|e| database(e.to_string()))?;
    let started =
        rev2_commands::start_download(&tx, &device, &q.path, &user.username, &s.settings.rev2)
            .await
            .map_err(|e| {
                if e.contains("path") {
                    bad(&e)
                } else {
                    database(e)
                }
            })?;
    let Some((download_id, command_id)) = started else {
        return Err(bad(
            "downloads need a firmware 2.2 (V22) unit with a live cmd/basic binding",
        ));
    };
    tx.commit().await.map_err(|e| database(e.to_string()))?;
    s.bus.emit(LiveEvent::Download {
        device_id: device.clone(),
    });
    s.bus.emit(LiveEvent::Command { device_id: device });
    Ok((
        StatusCode::CREATED,
        Json(json!({"download_id":download_id,"command_id":command_id})),
    )
        .into_response())
}

async fn cancel_download(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, id)): Path<(String, i64)>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let changed = db
        .execute(
            "WITH d AS (UPDATE file_downloads SET state='cancelled',error='cancelled by '||$3,updated_at=now()
                WHERE device_id=$1 AND id=$2 AND state='active' RETURNING current_command_id)
             UPDATE commands SET state='cancelled',cancelled_at=now(),cancelled_by=$3
             WHERE id IN (SELECT current_command_id FROM d) AND state='queued' AND active_publish_attempt IS NULL",
            &[&device, &id, &user.username],
        )
        .await
        .map_err(|e| database(e.to_string()))?;
    let _ = changed;
    s.bus.emit(LiveEvent::Download {
        device_id: device.clone(),
    });
    download(State(s), h, Path((device, id))).await
}

/// A dedicated connection for a multi-statement transaction; the shared
/// HTTP connection is used concurrently and cannot hold one open.
async fn connect_tx(s: &AppState) -> Result<Client, Response> {
    crate::db::connect(&s.settings.database_url)
        .await
        .map_err(database)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SettingsRequest {
    settings: Value,
    #[serde(default)]
    replace: bool,
    expires_in_s: Option<i64>,
}

async fn change_settings(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<SettingsRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    queue_command(
        &s,
        &db,
        &device,
        &user.username,
        Rev2Request {
            op: "settings",
            args: q.settings,
            confirm: None,
            auto_confirm: false,
            expires_in_s: q.expires_in_s,
            replace: q.replace,
        },
    )
    .await
}

/// A revision 2 command request from the API.
pub struct Rev2Request<'a> {
    pub op: &'a str,
    pub args: Value,
    /// Must be `DANGER` for `cmd/danger` operations.
    pub confirm: Option<&'a str>,
    /// Confirm the nonce challenge automatically when the logger reports
    /// no unsaved data.
    pub auto_confirm: bool,
    pub expires_in_s: Option<i64>,
    pub replace: bool,
}

/// Validates and queues a revision 2 command for `device`.
pub async fn queue_command(
    s: &AppState,
    db: &Client,
    device: &str,
    user: &str,
    request: Rev2Request<'_>,
) -> ApiResult {
    let now = Utc::now();
    let kind = crate::rev2::kind_of(request.op)
        .ok_or_else(|| bad(&format!("{} is not a contract operation", request.op)))?;
    if request.op == "confirm" {
        return Err(bad(
            "confirm is issued through /api/devices/{id}/commands/{command_id}/confirm",
        ));
    }
    let danger = kind == crate::rev2::CommandKind::Danger;
    if danger && request.confirm != Some("DANGER") {
        return Err(bad("type DANGER to confirm this command"));
    }
    if request.auto_confirm && !crate::rev2::needs_handshake(request.op) {
        return Err(bad(
            "auto_confirm applies only to nonce-handshake danger operations",
        ));
    }
    let args = rev2_commands::prepare(request.op, &request.args, request.replace, now)
        .map_err(|e| bad(&e))?;
    let mut options = QueueOptions::for_op(request.op, &s.settings.rev2, now);
    if let Some(seconds) = request.expires_in_s {
        if !(60..=30 * 86_400).contains(&seconds) {
            return Err(bad("expires_in_s must be 60 .. 2592000"));
        }
        options.expires_at = now + chrono::Duration::seconds(seconds);
    }
    options.requested_by = user;
    options.preconfirmed = request.auto_confirm;
    options.replace = request.replace;
    let id = rev2_commands::queue(db, device, request.op, &args, &options)
        .await
        .map_err(database)?
        .ok_or_else(|| {
            bad("revision 2 commands need an enrolled firmware 2.2 (V22) unit; this device's profile does not accept them")
        })?;
    s.bus.emit(LiveEvent::Command {
        device_id: device.to_owned(),
    });
    let command = crate::platform::command_by_id(db, device, id)
        .await
        .map_err(database)?;
    Ok((StatusCode::CREATED, Json(json!({"command":command}))).into_response())
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct ConfirmRequest {
    confirm_unsaved: Option<i64>,
}

async fn confirm(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, id)): Path<(String, i64)>,
    body: Option<Json<ConfirmRequest>>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let request = body.map(|Json(q)| q).unwrap_or_default();
    let mut db = connect_tx(&s).await?;
    let tx = db
        .transaction()
        .await
        .map_err(|e| database(e.to_string()))?;
    let result = rev2_commands::confirm(
        &tx,
        &device,
        id,
        request.confirm_unsaved,
        &user.username,
        &s.settings.rev2,
    )
    .await
    .map_err(database)?;
    let confirm_id = match result {
        Ok(confirm_id) => confirm_id,
        Err(ConfirmError::NotFound) => {
            return Err(error(StatusCode::NOT_FOUND, "command not found"))
        }
        Err(ConfirmError::Conflict(message)) => return Err(error(StatusCode::CONFLICT, &message)),
        Err(ConfirmError::Invalid(message)) => return Err(bad(&message)),
    };
    tx.commit().await.map_err(|e| database(e.to_string()))?;
    s.bus.emit(LiveEvent::Command {
        device_id: device.clone(),
    });
    let shared = s.db.get().await.map_err(database)?;
    let command = crate::platform::command_by_id(&shared, &device, confirm_id)
        .await
        .map_err(database)?;
    Ok((StatusCode::CREATED, Json(json!({"command":command}))).into_response())
}
