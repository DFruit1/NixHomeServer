//! Operations API: alert acknowledgement and policies, level limits,
//! notification rules, provisioning (enroll, edit, retire, viewers, audit),
//! per-device MQTT credentials, installation datums, exports, gap reports and
//! `/metrics`. Shapes are documented in `frontend/README.md` ("Operations
//! API"). Device routes are scoped exactly like the revision 1/2 routes;
//! every write needs the operator role (also enforced by `api::boundary`)
//! and leaves a `device_audit` row.
#![allow(
    clippy::result_large_err,
    reason = "Return the existing Axum error response directly at the HTTP boundary"
)]

use crate::api::{authorize, bad, database, error, operator, ApiResult, AppState};
use crate::config::OpsSettings;
use crate::ingest::LiveEvent;
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use tokio_postgres::{Client, GenericClient};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/alerts/{alert_id}/acknowledge", post(acknowledge))
        .route("/api/alerts/{alert_id}/resolve", post(resolve))
        .route(
            "/api/alert-policies",
            get(policies).put(put_policy).delete(delete_policy),
        )
        .route("/api/devices/{device_id}/alert-policy", get(device_policy))
        .route(
            "/api/devices/{device_id}/limits",
            axum::routing::put(put_limits),
        )
        .route("/api/notifications", get(notifications))
        .route("/api/notifications/rules", get(rules))
        .route(
            "/api/notifications/rules/{kind}",
            axum::routing::put(put_rule),
        )
        .route("/api/notifications/test", post(test_notification))
        .route("/api/devices/{device_id}/retire", post(retire))
        .route("/api/devices/{device_id}/reinstate", post(reinstate))
        .route("/api/devices/{device_id}/bindings", get(bindings))
        .route(
            "/api/devices/{device_id}/permissions",
            get(permissions).post(grant),
        )
        .route(
            "/api/devices/{device_id}/permissions/{username}",
            delete(revoke_permission),
        )
        .route("/api/devices/{device_id}/audit", get(device_audit))
        .route("/api/audit", get(fleet_audit))
        .route(
            "/api/devices/{device_id}/mqtt-credentials",
            get(credentials)
                .post(generate_credentials)
                .delete(delete_credentials),
        )
        .route(
            "/api/devices/{device_id}/mqtt-credentials/mode",
            post(credentials_mode),
        )
        .route(
            "/api/devices/{device_id}/datums",
            get(datums).post(add_datum),
        )
        .route(
            "/api/devices/{device_id}/datums/{datum_id}",
            delete(delete_datum),
        )
        .route("/api/devices/{device_id}/events/export", get(export_events))
        .route(
            "/api/devices/{device_id}/positions/export",
            get(export_positions),
        )
        .route("/api/gaps/report", get(fleet_gap_report))
        .route(
            "/api/devices/{device_id}/gaps/report",
            get(device_gap_report),
        )
}

// ---------------------------------------------------------------- helpers

fn db_err(e: tokio_postgres::Error) -> Response {
    if let Some(code) = e.code() {
        if *code == tokio_postgres::error::SqlState::UNIQUE_VIOLATION {
            return error(StatusCode::CONFLICT, "that record already exists");
        }
        if *code == tokio_postgres::error::SqlState::CHECK_VIOLATION {
            return bad("a value is outside its allowed range");
        }
    }
    database(e.to_string())
}

async fn json_rows<C: GenericClient + Sync>(
    db: &C,
    sql: &str,
    params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
) -> Result<Vec<Value>, Response> {
    db.query(sql, params)
        .await
        .map(|rows| rows.iter().map(|r| r.get::<_, Value>(0)).collect())
        .map_err(db_err)
}

/// Records an operator action. Part of the caller's transaction when given one.
pub async fn audit<C: GenericClient + Sync>(
    db: &C,
    device: Option<&str>,
    actor: &str,
    action: &str,
    detail: Value,
) -> Result<(), Response> {
    db.execute(
        "INSERT INTO device_audit(device_id,actor,action,detail) VALUES($1,$2,$3,$4)",
        &[&device, &actor, &action, &detail],
    )
    .await
    .map(|_| ())
    .map_err(db_err)
}

/// A dedicated connection for a multi-statement transaction; the shared
/// HTTP connection is used concurrently and cannot hold one open.
async fn connect_tx(s: &AppState) -> Result<Client, Response> {
    crate::db::connect(&s.settings.database_url)
        .await
        .map_err(database)
}

async fn device_json(s: &AppState, device: &str) -> Result<Value, Response> {
    let db = s.db.get().await.map_err(database)?;
    let summary = crate::db::scoped_devices(&db, &[device.to_owned()])
        .await
        .map_err(database)?
        .into_iter()
        .next()
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "device not found"))?;
    Ok(json!(summary))
}

fn default_margin_min() -> i32 {
    (crate::config::rev2_policy().stale_margin_seconds / 60).clamp(5, 10_080) as i32
}

/// Printable single-line text within a byte budget.
fn line(value: &str, key: &str, max: usize) -> Result<String, String> {
    let value = value.trim();
    if value.len() > max {
        return Err(format!("{key} is limited to {max} bytes"));
    }
    if value.chars().any(char::is_control) {
        return Err(format!(
            "{key} must be a single line without control characters"
        ));
    }
    Ok(value.to_owned())
}

pub fn valid_username(name: &str) -> bool {
    (1..=128).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'@' | b'-'))
}

/// Tells open browser tabs that a device's administrative state changed.
fn refresh_tabs(s: &AppState, device: &str) {
    s.bus.emit(LiveEvent::Presence {
        device_id: device.to_owned(),
    });
}

// ---------------------------------------------------------------- alerts

const ALERT_JSON: &str = "jsonb_build_object('id',a.id,'device_id',a.device_id,'display_name',d.display_name,
    'kind',a.kind,'severity',groundwater_alert_severity(a.kind),'state',a.state,'trigger_value',a.trigger_value,
    'opened_at',a.opened_at,'resolved_at',a.resolved_at,'acknowledged_at',a.acknowledged_at,
    'acknowledged_by',a.acknowledged_by,'ack_note',a.ack_note,'resolved_by',a.resolved_by,
    'resolve_note',a.resolve_note,'detail',a.detail)";

#[derive(Deserialize)]
pub struct AlertQuery {
    device: Option<String>,
    state: Option<String>,
    kind: Option<String>,
    limit: Option<i64>,
}

pub async fn alerts(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<AlertQuery>,
) -> ApiResult {
    let device = match &q.device {
        Some(d) => Some(authorize(&s, &h, d).await?),
        None => None,
    };
    let state = match q.state.as_deref() {
        None | Some("all") => None,
        Some(state @ ("open" | "resolved")) => Some(state),
        Some(_) => return Err(bad("state must be open, resolved or all")),
    };
    let visible = visible(&s, &h).await?;
    let db = s.db.get().await.map_err(database)?;
    let alerts = json_rows(
        &*db,
        &format!(
            "SELECT {ALERT_JSON} FROM alerts a JOIN devices d ON d.device_id=a.device_id
             WHERE NOT a.superseded AND a.device_id=ANY($1) AND ($2::text IS NULL OR a.device_id=$2)
               AND ($3::text IS NULL OR a.state=$3) AND ($4::text IS NULL OR a.kind=$4)
             ORDER BY a.opened_at DESC,a.id DESC LIMIT $5"
        ),
        &[
            &visible,
            &device,
            &state,
            &q.kind,
            &q.limit.unwrap_or(1000).clamp(1, 5000),
        ],
    )
    .await?;
    Ok(Json(json!({"alerts":alerts})).into_response())
}

async fn visible(s: &AppState, h: &HeaderMap) -> Result<Vec<String>, Response> {
    let identity = crate::identity::Identity::from_headers(h)
        .map_err(|_| error(StatusCode::UNAUTHORIZED, "not signed in"))?;
    let role = crate::identity::role_for(&identity)
        .ok_or_else(|| error(StatusCode::FORBIDDEN, "no access"))?;
    let db = s.db.get().await.map_err(database)?;
    crate::platform::visible_ids(
        &db,
        &identity.username,
        role == crate::identity::Role::Operator,
    )
    .await
    .map_err(database)
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct NoteRequest {
    note: Option<String>,
}

async fn alert_action(
    s: AppState,
    h: HeaderMap,
    id: i64,
    note: Option<String>,
    resolve: bool,
) -> ApiResult {
    let user = operator(&h)?;
    let note = note
        .map(|n| line(&n, "note", 500))
        .transpose()
        .map_err(|e| bad(&e))?
        .filter(|n| !n.is_empty());
    let db = s.db.get().await.map_err(database)?;
    let device: String = db
        .query_opt(
            "SELECT device_id FROM alerts WHERE id=$1 AND NOT superseded",
            &[&id],
        )
        .await
        .map_err(db_err)?
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "alert not found"))?
        .get(0);
    authorize(&s, &h, &device).await?;
    let changed = if resolve {
        db.execute(
            "UPDATE alerts SET state='resolved',resolved_at=now(),resolved_by=$2,resolve_note=$3
             WHERE id=$1 AND state='open' AND NOT superseded",
            &[&id, &user.username, &note],
        )
        .await
    } else {
        db.execute(
            "UPDATE alerts SET acknowledged_at=now(),acknowledged_by=$2,ack_note=$3 WHERE id=$1 AND NOT superseded",
            &[&id, &user.username, &note],
        )
        .await
    }
    .map_err(db_err)?;
    if changed == 0 {
        return Err(error(StatusCode::CONFLICT, "the alert is no longer open"));
    }
    audit(
        &*db,
        Some(&device),
        &user.username,
        if resolve {
            "alert_resolved"
        } else {
            "alert_acknowledged"
        },
        json!({"alert_id":id,"note":note}),
    )
    .await?;
    s.bus.emit(LiveEvent::Alert {
        device_id: device.clone(),
    });
    let alert = json_rows(
        &*db,
        &format!("SELECT {ALERT_JSON} FROM alerts a JOIN devices d ON d.device_id=a.device_id WHERE a.id=$1"),
        &[&id],
    )
    .await?;
    Ok(Json(json!({"alert":alert.into_iter().next()})).into_response())
}

async fn acknowledge(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(id): Path<i64>,
    body: Option<Json<NoteRequest>>,
) -> ApiResult {
    let note = body.and_then(|Json(b)| b.note);
    alert_action(s, h, id, note, false).await
}

async fn resolve(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(id): Path<i64>,
    body: Option<Json<NoteRequest>>,
) -> ApiResult {
    let note = body.and_then(|Json(b)| b.note);
    alert_action(s, h, id, note, true).await
}

// ---------------------------------------------------------------- alert policies

pub const POLICY_FIELDS: [&str; 6] = [
    "battery_low_mv",
    "battery_hys_mv",
    "solar_low_mv",
    "solar_samples",
    "stale_enabled",
    "stale_margin_min",
];

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PolicyValues {
    pub battery_low_mv: Option<i32>,
    pub battery_hys_mv: Option<i32>,
    pub solar_low_mv: Option<i32>,
    pub solar_samples: Option<i32>,
    pub stale_enabled: Option<bool>,
    pub stale_margin_min: Option<i32>,
}

impl PolicyValues {
    pub fn validate(&self) -> Result<(), String> {
        let check = |value: Option<i32>, key: &str, min: i32, max: i32| match value {
            Some(v) if !(min..=max).contains(&v) => Err(format!("{key} must be {min}..{max}")),
            _ => Ok(()),
        };
        check(self.battery_low_mv, "battery_low_mv", 3000, 9000)?;
        check(self.battery_hys_mv, "battery_hys_mv", 0, 2000)?;
        check(self.solar_low_mv, "solar_low_mv", 0, 30000)?;
        check(self.solar_samples, "solar_samples", 1, 10)?;
        check(self.stale_margin_min, "stale_margin_min", 5, 10080)
    }

    pub fn builtin(margin_min: i32) -> Self {
        Self {
            battery_low_mv: Some(7000),
            battery_hys_mv: Some(200),
            solar_low_mv: Some(1000),
            solar_samples: Some(3),
            stale_enabled: Some(true),
            stale_margin_min: Some(margin_min),
        }
    }

    fn json(&self) -> Value {
        json!({"battery_low_mv":self.battery_low_mv,"battery_hys_mv":self.battery_hys_mv,
            "solar_low_mv":self.solar_low_mv,"solar_samples":self.solar_samples,
            "stale_enabled":self.stale_enabled,"stale_margin_min":self.stale_margin_min})
    }
}

/// Field-by-field resolution device → project → fleet → default, with the
/// level each effective value came from.
pub fn resolve_policy(
    device: Option<&PolicyValues>,
    project: Option<&PolicyValues>,
    fleet: Option<&PolicyValues>,
    defaults: &PolicyValues,
) -> (Value, Map<String, Value>) {
    let levels = [
        ("device", device.map(PolicyValues::json)),
        ("project", project.map(PolicyValues::json)),
        ("fleet", fleet.map(PolicyValues::json)),
        ("default", Some(defaults.json())),
    ];
    let mut effective = Map::new();
    let mut sources = Map::new();
    for field in POLICY_FIELDS {
        for (name, values) in &levels {
            if let Some(value) = values
                .as_ref()
                .and_then(|v| v.get(field))
                .filter(|v| !v.is_null())
            {
                effective.insert(field.into(), value.clone());
                sources.insert(field.into(), json!(name));
                break;
            }
        }
    }
    (Value::Object(effective), sources)
}

fn policy_from_row(row: &tokio_postgres::Row) -> PolicyValues {
    PolicyValues {
        battery_low_mv: row.get("battery_low_mv"),
        battery_hys_mv: row.get("battery_hys_mv"),
        solar_low_mv: row.get("solar_low_mv"),
        solar_samples: row.get("solar_samples"),
        stale_enabled: row.get("stale_enabled"),
        stale_margin_min: row.get("stale_margin_min"),
    }
}

async fn policy_row(
    db: &Client,
    scope: &str,
    target: &str,
) -> Result<Option<PolicyValues>, Response> {
    db.query_opt(
        "SELECT * FROM alert_policies WHERE scope=$1 AND target=$2",
        &[&scope, &target],
    )
    .await
    .map(|row| row.as_ref().map(policy_from_row))
    .map_err(db_err)
}

async fn policies(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    operator(&h)?;
    let db = s.db.get().await.map_err(database)?;
    let policies = json_rows(
        &*db,
        "SELECT jsonb_build_object('scope',scope,'target',NULLIF(target,''),'battery_low_mv',battery_low_mv,
            'battery_hys_mv',battery_hys_mv,'solar_low_mv',solar_low_mv,'solar_samples',solar_samples,
            'stale_enabled',stale_enabled,'stale_margin_min',stale_margin_min,'updated_by',updated_by,
            'updated_at',updated_at)
         FROM alert_policies ORDER BY CASE scope WHEN 'fleet' THEN 0 WHEN 'project' THEN 1 ELSE 2 END,target",
        &[],
    )
    .await?;
    Ok(Json(
        json!({"policies":policies,"defaults":PolicyValues::builtin(default_margin_min()).json()}),
    )
    .into_response())
}

async fn device_policy(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let project: String = db
        .query_one("SELECT project FROM devices WHERE device_id=$1", &[&device])
        .await
        .map_err(db_err)?
        .get(0);
    let device_level = policy_row(&db, "device", &device).await?;
    let project_level = if project.is_empty() {
        None
    } else {
        policy_row(&db, "project", &project).await?
    };
    let fleet_level = policy_row(&db, "fleet", "").await?;
    let defaults = PolicyValues::builtin(default_margin_min());
    let (effective, sources) = resolve_policy(
        device_level.as_ref(),
        project_level.as_ref(),
        fleet_level.as_ref(),
        &defaults,
    );
    Ok(Json(json!({"effective":effective,"sources":sources,
        "levels":{"device":device_level.map(|p|p.json()),"project":project_level.map(|p|p.json()),
            "fleet":fleet_level.map(|p|p.json())},
        "project":project,"defaults":defaults.json()}))
    .into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyRequest {
    scope: String,
    target: Option<String>,
    battery_low_mv: Option<i32>,
    battery_hys_mv: Option<i32>,
    solar_low_mv: Option<i32>,
    solar_samples: Option<i32>,
    stale_enabled: Option<bool>,
    stale_margin_min: Option<i32>,
}

/// Validates a policy scope; returns the stored target ('' for the fleet)
/// and the device it audits against.
async fn policy_target(
    s: &AppState,
    h: &HeaderMap,
    scope: &str,
    target: Option<&str>,
) -> Result<(String, Option<String>), Response> {
    match (scope, target.map(str::trim).filter(|t| !t.is_empty())) {
        ("fleet", None) => Ok((String::new(), None)),
        ("fleet", Some(_)) => Err(bad("the fleet policy has no target")),
        ("project", Some(project)) => {
            Ok((line(project, "project", 64).map_err(|e| bad(&e))?, None))
        }
        ("device", Some(device)) => {
            let device = authorize(s, h, device).await?;
            Ok((device.clone(), Some(device)))
        }
        ("project" | "device", None) => Err(bad("target names the project or device")),
        _ => Err(bad("scope must be fleet, project or device")),
    }
}

/// Re-evaluates battery/solar alerts after a threshold change.
async fn reevaluate_power(
    s: &AppState,
    db: &Client,
    scope: &str,
    target: &str,
) -> Result<(), Response> {
    let rows = db
        .query(
            "SELECT device_id,groundwater_power_alerts(device_id)::text FROM devices
             WHERE revoked_at IS NULL AND ($1='fleet' OR ($1='project' AND project=$2) OR ($1='device' AND device_id=$2))",
            &[&scope, &target],
        )
        .await
        .map_err(db_err)?;
    for row in rows {
        s.bus.emit(LiveEvent::Alert {
            device_id: row.get(0),
        });
    }
    Ok(())
}

async fn put_policy(
    State(s): State<AppState>,
    h: HeaderMap,
    Json(q): Json<PolicyRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let values = PolicyValues {
        battery_low_mv: q.battery_low_mv,
        battery_hys_mv: q.battery_hys_mv,
        solar_low_mv: q.solar_low_mv,
        solar_samples: q.solar_samples,
        stale_enabled: q.stale_enabled,
        stale_margin_min: q.stale_margin_min,
    };
    values.validate().map_err(|e| bad(&e))?;
    let (target, device) = policy_target(&s, &h, &q.scope, q.target.as_deref()).await?;
    let db = s.db.get().await.map_err(database)?;
    db.execute(
        "INSERT INTO alert_policies(scope,target,battery_low_mv,battery_hys_mv,solar_low_mv,solar_samples,
            stale_enabled,stale_margin_min,updated_by,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,now())
         ON CONFLICT(scope,target) DO UPDATE SET battery_low_mv=EXCLUDED.battery_low_mv,
            battery_hys_mv=EXCLUDED.battery_hys_mv,solar_low_mv=EXCLUDED.solar_low_mv,
            solar_samples=EXCLUDED.solar_samples,stale_enabled=EXCLUDED.stale_enabled,
            stale_margin_min=EXCLUDED.stale_margin_min,updated_by=EXCLUDED.updated_by,updated_at=now()",
        &[
            &q.scope,
            &target,
            &values.battery_low_mv,
            &values.battery_hys_mv,
            &values.solar_low_mv,
            &values.solar_samples,
            &values.stale_enabled,
            &values.stale_margin_min,
            &user.username,
        ],
    )
    .await
    .map_err(db_err)?;
    audit(
        &*db,
        device.as_deref(),
        &user.username,
        "alert_policy_changed",
        json!({"scope":q.scope,"target":NonEmpty(&target).get(),"values":values.json()}),
    )
    .await?;
    reevaluate_power(&s, &db, &q.scope, &target).await?;
    let mut policy = values.json();
    policy["scope"] = json!(q.scope);
    policy["target"] = json!(NonEmpty(&target).get());
    policy["updated_by"] = json!(user.username);
    Ok(Json(json!({"policy":policy})).into_response())
}

struct NonEmpty<'a>(&'a str);
impl NonEmpty<'_> {
    fn get(&self) -> Option<&str> {
        (!self.0.is_empty()).then_some(self.0)
    }
}

#[derive(Deserialize)]
pub struct PolicyKey {
    scope: String,
    target: Option<String>,
}

async fn delete_policy(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<PolicyKey>,
) -> ApiResult {
    let user = operator(&h)?;
    let (target, device) = policy_target(&s, &h, &q.scope, q.target.as_deref()).await?;
    let db = s.db.get().await.map_err(database)?;
    let deleted = db
        .execute(
            "DELETE FROM alert_policies WHERE scope=$1 AND target=$2",
            &[&q.scope, &target],
        )
        .await
        .map_err(db_err)?;
    if deleted > 0 {
        audit(
            &*db,
            device.as_deref(),
            &user.username,
            "alert_policy_removed",
            json!({"scope":q.scope,"target":NonEmpty(&target).get()}),
        )
        .await?;
        reevaluate_power(&s, &db, &q.scope, &target).await?;
    }
    Ok(Json(json!({"deleted":deleted > 0})).into_response())
}

// ---------------------------------------------------------------- level limits

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LimitsRequest {
    pub min_limit: Option<f64>,
    pub max_limit: Option<f64>,
    pub min_hysteresis: Option<f64>,
    pub max_hysteresis: Option<f64>,
    pub expires_in_s: Option<i64>,
}

impl LimitsRequest {
    pub fn validate(&self) -> Result<(), String> {
        let limit = crate::telemetry::GWL_ABS_LIMIT_M;
        for (key, value) in [("min_limit", self.min_limit), ("max_limit", self.max_limit)] {
            if value.is_some_and(|v| !v.is_finite() || v.abs() > limit) {
                return Err(format!("{key} must be a finite level within ±{limit} m"));
            }
        }
        for (key, value) in [
            ("min_hysteresis", self.min_hysteresis),
            ("max_hysteresis", self.max_hysteresis),
        ] {
            if value.is_some_and(|v| !v.is_finite() || !(0.0..=100.0).contains(&v)) {
                return Err(format!("{key} must be 0..100 m"));
            }
        }
        if let (Some(min), Some(max)) = (self.min_limit, self.max_limit)
            && min >= max
        {
            return Err("min_limit must be below max_limit".into());
        }
        Ok(())
    }

    /// The `config/set` arguments mirroring these limits on a V22 logger.
    pub fn settings_args(&self) -> Value {
        let mut args = json!({"lo":self.min_limit,"hi":self.max_limit});
        if let Some(v) = self.min_hysteresis {
            args["lo_hys"] = json!(v);
        }
        if let Some(v) = self.max_hysteresis {
            args["hi_hys"] = json!(v);
        }
        args
    }
}

async fn put_limits(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<LimitsRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    q.validate().map_err(|e| bad(&e))?;
    let db = s.db.get().await.map_err(database)?;
    let row = db
        .query_one(
            "SELECT groundwater_profile_id(source_profile),revoked_at IS NOT NULL FROM devices WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    if row.get::<_, bool>(1) {
        return Err(error(StatusCode::CONFLICT, "this enrollment is retired"));
    }
    let detail = json!({"min_limit":q.min_limit,"max_limit":q.max_limit,
        "min_hysteresis":q.min_hysteresis,"max_hysteresis":q.max_hysteresis});
    if row.get::<_, Option<String>>(0).as_deref() == Some("V22") {
        // The logger raises its own level alarms from lo/hi: change them
        // there; the server limits follow the acknowledged settings.
        let response = crate::api_rev2::queue_command(
            &s,
            &db,
            &device,
            &user.username,
            crate::api_rev2::Rev2Request {
                op: "settings",
                args: q.settings_args(),
                confirm: None,
                auto_confirm: false,
                expires_in_s: q.expires_in_s,
                replace: false,
            },
        )
        .await?;
        audit(
            &*db,
            Some(&device),
            &user.username,
            "limits_requested",
            detail,
        )
        .await?;
        return Ok(response);
    }
    db.execute(
        "UPDATE devices SET min_limit=$2,max_limit=$3,min_hysteresis=$4,max_hysteresis=$5 WHERE device_id=$1",
        &[&device, &q.min_limit, &q.max_limit, &q.min_hysteresis, &q.max_hysteresis],
    )
    .await
    .map_err(db_err)?;
    audit(
        &*db,
        Some(&device),
        &user.username,
        "limits_changed",
        detail,
    )
    .await?;
    s.bus.emit(LiveEvent::Alert {
        device_id: device.clone(),
    });
    Ok(Json(json!({"device":device_json(&s, &device).await?})).into_response())
}

// ---------------------------------------------------------------- notifications

fn delivery(ops: &OpsSettings) -> Value {
    json!({"configured":ops.ntfy.is_some(),"server":ops.ntfy.as_ref().map(|t|t.server.clone()),
        "topic":ops.ntfy.as_ref().map(|t|t.topic.clone()),"public_url":ops.public_url,
        "max_per_hour":ops.notify_max_per_hour})
}

async fn rules(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    operator(&h)?;
    let db = s.db.get().await.map_err(database)?;
    let rows = db
        .query(
            "SELECT kind,enabled,min_severity,priority,cooldown_min,notify_resolved,topic,updated_by,updated_at
             FROM notification_rules",
            &[],
        )
        .await
        .map_err(db_err)?;
    let rules: Vec<Value> = crate::notify::KINDS
        .iter()
        .filter_map(|(kind, label, source, severities)| {
            let row = rows.iter().find(|r| r.get::<_, String>(0) == *kind)?;
            Some(
                json!({"kind":kind,"label":label,"source":source,"severities":severities,
                "enabled":row.get::<_,bool>(1),"min_severity":row.get::<_,String>(2),
                "priority":row.get::<_,i16>(3),"cooldown_min":row.get::<_,i32>(4),
                "notify_resolved":row.get::<_,bool>(5),"topic":row.get::<_,Option<String>>(6),
                "updated_by":row.get::<_,Option<String>>(7),
                "updated_at":row.get::<_,Option<DateTime<Utc>>>(8)}),
            )
        })
        .collect();
    Ok(Json(json!({"rules":rules,"delivery":delivery(&s.settings.ops)})).into_response())
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuleRequest {
    enabled: Option<bool>,
    min_severity: Option<String>,
    priority: Option<i16>,
    cooldown_min: Option<i32>,
    notify_resolved: Option<bool>,
    #[serde(default, deserialize_with = "explicit_null")]
    topic: Option<Option<String>>,
}

/// Distinguishes `"topic":null` (clear) from an absent key (keep).
fn explicit_null<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(d).map(Some)
}

async fn put_rule(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(kind): Path<String>,
    Json(q): Json<RuleRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    if !crate::notify::known_kind(&kind) {
        return Err(error(StatusCode::NOT_FOUND, "unknown notification kind"));
    }
    if q.min_severity
        .as_deref()
        .is_some_and(|v| crate::notify::Severity::parse(v).is_none())
    {
        return Err(bad("min_severity must be info, warning or critical"));
    }
    if q.priority.is_some_and(|p| !(1..=5).contains(&p)) {
        return Err(bad("priority must be 1..5 (ntfy)"));
    }
    if q.cooldown_min.is_some_and(|c| !(0..=10_080).contains(&c)) {
        return Err(bad("cooldown_min must be 0..10080"));
    }
    let topic = q
        .topic
        .clone()
        .map(|t| t.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty()));
    if let Some(Some(topic)) = &topic
        && !crate::config::valid_topic(topic)
    {
        return Err(bad("topic must match [A-Za-z0-9_-]{1,64}"));
    }
    let db = s.db.get().await.map_err(database)?;
    db.execute(
        "UPDATE notification_rules SET enabled=COALESCE($2,enabled),min_severity=COALESCE($3,min_severity),
            priority=COALESCE($4,priority),cooldown_min=COALESCE($5,cooldown_min),
            notify_resolved=COALESCE($6,notify_resolved),topic=CASE WHEN $7 THEN $8 ELSE topic END,
            updated_by=$9,updated_at=now() WHERE kind=$1",
        &[
            &kind,
            &q.enabled,
            &q.min_severity,
            &q.priority,
            &q.cooldown_min,
            &q.notify_resolved,
            &topic.is_some(),
            &topic.clone().flatten(),
            &user.username,
        ],
    )
    .await
    .map_err(db_err)?;
    audit(
        &*db,
        None,
        &user.username,
        "notification_rule_changed",
        json!({"kind":kind,"enabled":q.enabled,"min_severity":q.min_severity,"priority":q.priority,
            "cooldown_min":q.cooldown_min,"notify_resolved":q.notify_resolved,"topic":topic}),
    )
    .await?;
    let response = rules(State(s), h).await?;
    Ok(response)
}

#[derive(Deserialize)]
pub struct NotificationQuery {
    device: Option<String>,
    limit: Option<i64>,
}

async fn notifications(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<NotificationQuery>,
) -> ApiResult {
    operator(&h)?;
    let device = q.device.as_deref().map(crate::adapter::canonical_device_id);
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        "SELECT jsonb_build_object('id',o.id,'device_id',o.device_id,'display_name',d.display_name,'kind',o.kind,
            'severity',o.severity,'transition',o.transition,'event',o.event,'title',o.title,'message',o.message,
            'state',o.state,'reason',o.reason,'error',o.error,'attempts',o.attempts,'alert_id',o.alert_id,
            'event_id',o.event_id,'suppressed_count',o.suppressed_count,'occurred_at',o.occurred_at,
            'created_at',o.created_at,'sent_at',o.sent_at)
         FROM notification_outbox o JOIN devices d ON d.device_id=o.device_id
         WHERE ($1::text IS NULL OR o.device_id=$1) ORDER BY o.id DESC LIMIT $2",
        &[&device, &q.limit.unwrap_or(200).clamp(1, 2000)],
    )
    .await?;
    Ok(Json(json!({"notifications":rows})).into_response())
}

async fn test_notification(State(s): State<AppState>, h: HeaderMap) -> ApiResult {
    let user = operator(&h)?;
    match crate::notify::send_test(&s.settings.ops, &user.username).await {
        Ok(()) => Ok(Json(json!({"sent":true})).into_response()),
        Err(e) if s.settings.ops.ntfy.is_none() => Err(error(StatusCode::CONFLICT, &e)),
        Err(e) => Err(error(StatusCode::BAD_GATEWAY, &e)),
    }
}

// ---------------------------------------------------------------- provisioning

/// Channels of the per-device `gwl/v1` enrollment template (operations
/// guide): both protocol revisions, so a 2.1 → 2.2 reflash needs no change.
pub const V1_CHANNELS: [&str; 18] = [
    "status",
    "info",
    "health",
    "data/stream",
    "data/file",
    "alerts",
    "test/result",
    "reading",
    "gps",
    "config/applied",
    "cmd/ack",
    "config/set",
    "cmd/basic",
    "cmd/danger",
    "storage",
    "motion",
    "config/desired",
    "cmd/test",
];

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnrollRequest {
    pub device_id: String,
    #[serde(default)]
    pub display_name: String,
    pub profile: String,
    pub clock_policy: Option<String>,
    pub local_offset_min: Option<i32>,
    #[serde(default)]
    pub location_id: String,
    #[serde(default)]
    pub sensor_id: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub notes: String,
    pub bindings: Option<String>,
    #[serde(default)]
    pub viewers: Vec<String>,
}

/// A validated enrollment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Enrollment {
    pub device_id: String,
    pub display_name: String,
    pub profile: &'static str,
    pub clock_policy: &'static str,
    pub local_offset_min: Option<i32>,
    pub location_id: Option<String>,
    pub sensor_id: Option<String>,
    pub project: String,
    pub notes: String,
    pub bind_v1: bool,
    pub viewers: Vec<String>,
}

fn optional(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

pub fn validate_enrollment(q: &EnrollRequest) -> Result<Enrollment, String> {
    let device_id = q.device_id.trim().to_ascii_uppercase();
    if !crate::mqtt_auth::valid_username(&device_id) {
        return Err("device_id must be the unit's 24-character hexadecimal DeviceID".into());
    }
    let profile = match q.profile.trim().to_ascii_uppercase().as_str() {
        "V22" => "V22",
        "V21" => "V21",
        "V20" | "ML" => {
            return Err("V20 and MQTT-Logger units use shared legacy topics; enroll them with the SQL procedure in the operations guide".into())
        }
        _ => return Err("profile must be V22 or V21".into()),
    };
    let (clock_policy, offset) =
        match (
            profile,
            q.clock_policy
                .as_deref()
                .unwrap_or(if profile == "V22" { "utc" } else { "" }),
        ) {
            ("V22", "utc") => ("utc", None),
            ("V22", _) => return Err(
                "firmware 2.2 sends UTC with an explicit validity flag: its clock policy is utc"
                    .into(),
            ),
            (_, "utc") => ("utc", None),
            (_, "unknown") => ("unknown", None),
            (_, "local-offset") => match q.local_offset_min {
                Some(offset) if (-720..=840).contains(&offset) => ("local-offset", Some(offset)),
                _ => return Err("local-offset needs local_offset_min in -720..840".into()),
            },
            _ => return Err("clock_policy must be utc, local-offset or unknown".into()),
        };
    if clock_policy != "local-offset" && q.local_offset_min.is_some() {
        return Err("local_offset_min applies only to the local-offset clock policy".into());
    }
    let bind_v1 = match q.bindings.as_deref().unwrap_or("gwl/v1") {
        "gwl/v1" => true,
        "none" => false,
        _ => return Err("bindings must be gwl/v1 or none".into()),
    };
    let mut viewers = Vec::new();
    for viewer in &q.viewers {
        let viewer = viewer.trim();
        if !valid_username(viewer) {
            return Err(format!("viewer {viewer:?} is not a valid account name"));
        }
        if !viewers.iter().any(|v| v == viewer) {
            viewers.push(viewer.to_owned());
        }
    }
    Ok(Enrollment {
        device_id,
        display_name: line(&q.display_name, "display_name", 80)?,
        profile,
        clock_policy,
        local_offset_min: offset,
        location_id: optional(line(&q.location_id, "location_id", 32)?),
        sensor_id: optional(line(&q.sensor_id, "sensor_id", 32)?),
        project: line(&q.project, "project", 64)?,
        notes: notes(&q.notes)?,
        bind_v1,
        viewers,
    })
}

fn notes(text: &str) -> Result<String, String> {
    let text = text.trim();
    if text.len() > 2000 {
        return Err("notes are limited to 2000 bytes".into());
    }
    if text.chars().any(|c| c.is_control() && c != '\n') {
        return Err("notes must not contain control characters".into());
    }
    Ok(text.to_owned())
}

async fn insert_bindings<C: GenericClient + Sync>(
    tx: &C,
    device: &str,
    profile: &str,
) -> Result<(), Response> {
    for channel in V1_CHANNELS {
        tx.execute(
            "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$3,$4)",
            &[
                &format!("v1-{device}-{channel}"),
                &device,
                &format!("gwl/v1/{device}/{channel}"),
                &profile,
            ],
        )
        .await
        .map_err(db_err)?;
    }
    Ok(())
}

pub async fn enroll(
    State(s): State<AppState>,
    h: HeaderMap,
    Json(q): Json<EnrollRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let e = validate_enrollment(&q).map_err(|e| bad(&e))?;
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let inserted = tx
        .execute(
            "INSERT INTO devices(device_id,display_name,source_profile,clock_policy,local_offset_min,location_id,
                sensor_id,project,notes) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT DO NOTHING",
            &[
                &e.device_id,
                &e.display_name,
                &e.profile,
                &e.clock_policy,
                &e.local_offset_min,
                &e.location_id,
                &e.sensor_id,
                &e.project,
                &e.notes,
            ],
        )
        .await
        .map_err(db_err)?;
    if inserted == 0 {
        return Err(error(
            StatusCode::CONFLICT,
            "this DeviceID is already enrolled (reinstate a retired unit instead)",
        ));
    }
    if e.bind_v1 {
        insert_bindings(&tx, &e.device_id, e.profile).await?;
    }
    for viewer in &e.viewers {
        tx.execute(
            "INSERT INTO device_permissions(device_id,username,granted_at,granted_by) VALUES($1,$2,now(),$3)",
            &[&e.device_id, viewer, &user.username],
        )
        .await
        .map_err(db_err)?;
    }
    audit(
        &tx,
        Some(&e.device_id),
        &user.username,
        "enrolled",
        json!({"display_name":e.display_name,"profile":e.profile,"clock_policy":e.clock_policy,
            "local_offset_min":e.local_offset_min,"location_id":e.location_id,"sensor_id":e.sensor_id,
            "project":e.project,"bindings":if e.bind_v1 {"gwl/v1"} else {"none"},"viewers":e.viewers}),
    )
    .await?;
    tx.commit().await.map_err(db_err)?;
    s.registry_changed.notify_one();
    s.bus.emit(LiveEvent::Presence {
        device_id: e.device_id.clone(),
    });
    Ok((
        StatusCode::CREATED,
        Json(json!({"device":device_json(&s, &e.device_id).await?})),
    )
        .into_response())
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateRequest {
    display_name: Option<String>,
    location_id: Option<String>,
    sensor_id: Option<String>,
    project: Option<String>,
    notes: Option<String>,
}

pub async fn update_device(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<UpdateRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let check = |value: &Option<String>, key: &str, max: usize| {
        value
            .as_deref()
            .map(|v| line(v, key, max))
            .transpose()
            .map_err(|e| bad(&e))
    };
    let display_name = check(&q.display_name, "display_name", 80)?;
    let location_id = check(&q.location_id, "location_id", 32)?;
    let sensor_id = check(&q.sensor_id, "sensor_id", 32)?;
    let project = check(&q.project, "project", 64)?;
    let notes = q
        .notes
        .as_deref()
        .map(notes)
        .transpose()
        .map_err(|e| bad(&e))?;
    let db = s.db.get().await.map_err(database)?;
    let before = db
        .query_one(
            "SELECT jsonb_build_object('display_name',display_name,'location_id',location_id,'sensor_id',sensor_id,
                'project',project,'notes',notes) FROM devices WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?
        .get::<_, Value>(0);
    db.execute(
        "UPDATE devices SET display_name=COALESCE($2,display_name),
            location_id=CASE WHEN $3::text IS NULL THEN location_id ELSE NULLIF($3,'') END,
            sensor_id=CASE WHEN $4::text IS NULL THEN sensor_id ELSE NULLIF($4,'') END,
            project=COALESCE($5,project),notes=COALESCE($6,notes) WHERE device_id=$1",
        &[
            &device,
            &display_name,
            &location_id,
            &sensor_id,
            &project,
            &notes,
        ],
    )
    .await
    .map_err(db_err)?;
    let after = json!({"display_name":display_name,"location_id":location_id,"sensor_id":sensor_id,
        "project":project,"notes":notes});
    let changes: Map<String, Value> = after
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(key, value)| {
            let new = value.as_str()?;
            let old = before.get(key).and_then(Value::as_str).unwrap_or("");
            (old != new).then(|| (key.clone(), json!({"from":old,"to":new})))
        })
        .collect();
    if !changes.is_empty() {
        audit(
            &*db,
            Some(&device),
            &user.username,
            "updated",
            Value::Object(changes),
        )
        .await?;
    }
    s.bus.emit(LiveEvent::Presence {
        device_id: device.clone(),
    });
    Ok(Json(json!({"device":device_json(&s, &device).await?})).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RetireRequest {
    confirm: Option<String>,
    reason: Option<String>,
}

async fn retire(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<RetireRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    if q.confirm.as_deref() != Some("RETIRE") {
        return Err(bad("type RETIRE to retire this enrollment"));
    }
    let reason = q
        .reason
        .as_deref()
        .map(|r| line(r, "reason", 300))
        .transpose()
        .map_err(|e| bad(&e))?
        .unwrap_or_default();
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let retired = tx
        .execute(
            "UPDATE devices SET revoked_at=now(),revoked_by=$2,revoke_reason=NULLIF($3,'')
             WHERE device_id=$1 AND revoked_at IS NULL",
            &[&device, &user.username, &reason],
        )
        .await
        .map_err(db_err)?;
    if retired == 0 {
        return Err(error(
            StatusCode::CONFLICT,
            "this enrollment is already retired",
        ));
    }
    let bindings = tx
        .execute(
            "UPDATE device_bindings SET revoked_at=now() WHERE device_id=$1 AND revoked_at IS NULL",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    let cancelled = tx
        .query(
            "WITH changed AS (UPDATE commands SET state='cancelled',cancelled_at=now(),cancelled_by=$2
                WHERE device_id=$1 AND (state IN ('queued','sent') OR (protocol=2 AND state='challenge'))
                  AND active_publish_attempt IS NULL RETURNING id),
             audit AS (INSERT INTO command_events(command_id,event,actor) SELECT id,'cancelled',$2 FROM changed)
             SELECT id FROM changed",
            &[&device, &user.username],
        )
        .await
        .map_err(db_err)?
        .len();
    tx.execute(
        "UPDATE file_downloads SET state='cancelled',error='enrollment retired',updated_at=now()
         WHERE device_id=$1 AND state='active'",
        &[&device],
    )
    .await
    .map_err(db_err)?;
    let resolved = tx
        .execute(
            "UPDATE alerts SET state='resolved',resolved_at=now(),resolved_by=$2,resolve_note='enrollment retired'
             WHERE device_id=$1 AND state='open' AND NOT superseded",
            &[&device, &user.username],
        )
        .await
        .map_err(db_err)?;
    let had_credentials = tx
        .execute(
            "DELETE FROM device_mqtt_credentials WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?
        > 0;
    if had_credentials && let Some(dir) = &s.settings.ops.mqtt_auth_dir {
        crate::mqtt_auth::publish(&tx, dir)
            .await
            .map_err(database)?;
    }
    audit(
        &tx,
        Some(&device),
        &user.username,
        "retired",
        json!({"reason":reason,"bindings_revoked":bindings,"commands_cancelled":cancelled,
            "alerts_resolved":resolved,"mqtt_credentials_removed":had_credentials}),
    )
    .await?;
    tx.commit().await.map_err(db_err)?;
    s.registry_changed.notify_one();
    s.bus.emit(LiveEvent::Command {
        device_id: device.clone(),
    });
    Ok(Json(json!({"device":device_json(&s, &device).await?})).into_response())
}

async fn reinstate(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let row = tx
        .query_opt(
            "UPDATE devices SET revoked_at=NULL,revoked_by=NULL,revoke_reason=NULL
             WHERE device_id=$1 AND revoked_at IS NOT NULL RETURNING source_profile",
            &[&device],
        )
        .await
        .map_err(db_err)?
        .ok_or_else(|| error(StatusCode::CONFLICT, "this enrollment is not retired"))?;
    let profile: String = row.get(0);
    // Revive the unit's own gwl/v1 bindings; legacy shared topics stay
    // revoked (re-binding those is an SQL decision, see the guide).
    let revived = tx
        .execute(
            "UPDATE device_bindings b SET revoked_at=NULL,established_at=now()
             WHERE b.device_id=$1 AND b.topic LIKE 'gwl/v1/'||$1||'/%' AND b.revoked_at IS NOT NULL
               AND b.revoked_at=(SELECT max(revoked_at) FROM device_bindings x WHERE x.topic=b.topic)",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    audit(
        &tx,
        Some(&device),
        &user.username,
        "reinstated",
        json!({"bindings_revived":revived,"profile":profile}),
    )
    .await?;
    tx.commit().await.map_err(db_err)?;
    s.registry_changed.notify_one();
    s.bus.emit(LiveEvent::Presence {
        device_id: device.clone(),
    });
    Ok(Json(json!({"device":device_json(&s, &device).await?})).into_response())
}

async fn bindings(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        "SELECT jsonb_build_object('binding_key',binding_key,'topic',topic,'source_profile',source_profile,
            'established_at',established_at,'revoked_at',revoked_at)
         FROM device_bindings WHERE device_id=$1 ORDER BY revoked_at IS NOT NULL,topic",
        &[&device],
    )
    .await?;
    Ok(Json(json!({"bindings":rows})).into_response())
}

const PERMISSION_JSON: &str =
    "jsonb_build_object('username',username,'granted_at',granted_at,'granted_by',granted_by)";

async fn permissions(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!(
            "SELECT {PERMISSION_JSON} FROM device_permissions WHERE device_id=$1 ORDER BY username"
        ),
        &[&device],
    )
    .await?;
    Ok(Json(json!({"permissions":rows})).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantRequest {
    username: String,
}

async fn grant(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<GrantRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let username = q.username.trim();
    if !valid_username(username) {
        return Err(bad("username must match [A-Za-z0-9._@-]{1,128}"));
    }
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!(
            "INSERT INTO device_permissions(device_id,username,granted_at,granted_by) VALUES($1,$2,now(),$3)
             ON CONFLICT DO NOTHING RETURNING {PERMISSION_JSON}"
        ),
        &[&device, &username, &user.username],
    )
    .await?;
    let Some(permission) = rows.into_iter().next() else {
        return Err(error(
            StatusCode::CONFLICT,
            "that account can already view this device",
        ));
    };
    audit(
        &*db,
        Some(&device),
        &user.username,
        "permission_granted",
        json!({"username":username}),
    )
    .await?;
    refresh_tabs(&s, &device);
    Ok((StatusCode::CREATED, Json(json!({"permission":permission}))).into_response())
}

async fn revoke_permission(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, username)): Path<(String, String)>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let deleted = db
        .execute(
            "DELETE FROM device_permissions WHERE device_id=$1 AND username=$2",
            &[&device, &username],
        )
        .await
        .map_err(db_err)?;
    if deleted == 0 {
        return Err(error(StatusCode::NOT_FOUND, "no such viewer permission"));
    }
    audit(
        &*db,
        Some(&device),
        &user.username,
        "permission_revoked",
        json!({"username":username}),
    )
    .await?;
    refresh_tabs(&s, &device);
    Ok(Json(json!({"deleted":true})).into_response())
}

const AUDIT_JSON: &str =
    "jsonb_build_object('id',id,'device_id',device_id,'actor',actor,'action',action,
    'detail',detail,'created_at',created_at)";

#[derive(Deserialize)]
pub struct LimitQuery {
    limit: Option<i64>,
}

async fn device_audit(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<LimitQuery>,
) -> ApiResult {
    operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!(
            "SELECT {AUDIT_JSON} FROM device_audit WHERE device_id=$1 ORDER BY id DESC LIMIT $2"
        ),
        &[&device, &q.limit.unwrap_or(200).clamp(1, 2000)],
    )
    .await?;
    Ok(Json(json!({"audit":rows})).into_response())
}

async fn fleet_audit(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<LimitQuery>,
) -> ApiResult {
    operator(&h)?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!("SELECT {AUDIT_JSON} FROM device_audit ORDER BY id DESC LIMIT $1"),
        &[&q.limit.unwrap_or(200).clamp(1, 2000)],
    )
    .await?;
    Ok(Json(json!({"audit":rows})).into_response())
}

// ---------------------------------------------------------------- MQTT credentials

async fn credentials_json(s: &AppState, db: &Client, device: &str) -> Result<Value, Response> {
    let row = db
        .query_opt(
            "SELECT mode,created_at,created_by,rotated_at,mode_changed_at,published_at
             FROM device_mqtt_credentials WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    let available = s.settings.ops.mqtt_auth_dir.is_some();
    Ok(match row {
        Some(r) => json!({"available":available,"mode":r.get::<_,String>(0),"username":device,
            "created_at":r.get::<_,DateTime<Utc>>(1),"created_by":r.get::<_,String>(2),
            "rotated_at":r.get::<_,Option<DateTime<Utc>>>(3),
            "mode_changed_at":r.get::<_,Option<DateTime<Utc>>>(4),
            "published_at":r.get::<_,Option<DateTime<Utc>>>(5)}),
        None => json!({"available":available,"mode":"shared","username":device,"created_at":null,
            "created_by":null,"rotated_at":null,"mode_changed_at":null,"published_at":null}),
    })
}

async fn credentials(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
) -> ApiResult {
    operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    Ok(Json(credentials_json(&s, &db, &device).await?).into_response())
}

fn auth_dir(s: &AppState) -> Result<std::path::PathBuf, Response> {
    s.settings.ops.mqtt_auth_dir.clone().ok_or_else(|| {
        error(
            StatusCode::CONFLICT,
            "per-device MQTT credentials are not enabled on this server (repo.groundwaterLogger.deviceCredentials.enable)",
        )
    })
}

/// Typed confirmation for credential changes that can strand a unit.
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct CredentialConfirm {
    confirm: Option<String>,
}

async fn generate_credentials(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    body: Option<Json<CredentialConfirm>>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let dir = auth_dir(&s)?;
    let check = s.db.get().await.map_err(database)?;
    let row = check
        .query_one(
            "SELECT revoked_at IS NOT NULL,EXISTS(SELECT 1 FROM device_bindings b WHERE b.device_id=d.device_id
                AND b.revoked_at IS NULL AND b.topic='gwl/v1/'||d.device_id||'/status'),
                EXISTS(SELECT 1 FROM device_mqtt_credentials c WHERE c.device_id=d.device_id)
             FROM devices d WHERE d.device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    if row.get::<_, bool>(0) {
        return Err(error(StatusCode::CONFLICT, "this enrollment is retired"));
    }
    // A unit flashed with its own password cannot connect after a rotation
    // until it is reflashed: the firmware has no remote credential change.
    let rotating = row.get::<_, bool>(2);
    if rotating && body.and_then(|Json(b)| b.confirm).as_deref() != Some("ROTATE") {
        return Err(bad(
            "type ROTATE to replace this unit's password; a unit already using its own account stays offline until reflashed",
        ));
    }
    if !row.get::<_, bool>(1) {
        return Err(bad(
            "own MQTT accounts are limited to gwl/v1/<DeviceID>/ topics; bind this unit's gwl/v1 topics first",
        ));
    }
    let password = crate::mqtt_auth::generate_password();
    let secret = password.clone();
    let hash = tokio::task::spawn_blocking(move || crate::mqtt_auth::hash_password(&secret))
        .await
        .map_err(|e| database(e.to_string()))?;
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let rotated: bool = tx
        .query_one(
            "INSERT INTO device_mqtt_credentials(device_id,password_hash,mode,created_by) VALUES($1,$2,'dual',$3)
             ON CONFLICT(device_id) DO UPDATE SET password_hash=EXCLUDED.password_hash,rotated_at=now()
             RETURNING rotated_at IS NOT NULL",
            &[&device, &hash, &user.username],
        )
        .await
        .map_err(db_err)?
        .get(0);
    crate::mqtt_auth::publish(&tx, &dir)
        .await
        .map_err(database)?;
    audit(
        &tx,
        Some(&device),
        &user.username,
        if rotated {
            "mqtt_credentials_rotated"
        } else {
            "mqtt_credentials_generated"
        },
        json!({"username":device}),
    )
    .await?;
    tx.commit().await.map_err(db_err)?;
    refresh_tabs(&s, &device);
    let shared = s.db.get().await.map_err(database)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"username":device,"password":password,
            "credentials":credentials_json(&s, &shared, &device).await?})),
    )
        .into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModeRequest {
    mode: String,
    confirm: Option<String>,
}

async fn credentials_mode(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<ModeRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let dir = auth_dir(&s)?;
    match q.mode.as_str() {
        "dual" => {}
        "device" if q.confirm.as_deref() == Some("DEVICE") => {}
        "device" => {
            return Err(bad(
                "type DEVICE to deny the shared logger account on this unit's topics",
            ))
        }
        _ => return Err(bad("mode must be dual or device")),
    }
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let changed = tx
        .execute(
            "UPDATE device_mqtt_credentials SET mode=$2,mode_changed_at=now() WHERE device_id=$1 AND mode<>$2",
            &[&device, &q.mode],
        )
        .await
        .map_err(db_err)?;
    if changed == 0 {
        let exists = tx
            .query_opt(
                "SELECT 1 FROM device_mqtt_credentials WHERE device_id=$1",
                &[&device],
            )
            .await
            .map_err(db_err)?
            .is_some();
        if !exists {
            return Err(error(
                StatusCode::CONFLICT,
                "generate this unit's credentials first",
            ));
        }
    } else {
        crate::mqtt_auth::publish(&tx, &dir)
            .await
            .map_err(database)?;
        audit(
            &tx,
            Some(&device),
            &user.username,
            "mqtt_mode_changed",
            json!({"mode":q.mode}),
        )
        .await?;
    }
    tx.commit().await.map_err(db_err)?;
    refresh_tabs(&s, &device);
    let shared = s.db.get().await.map_err(database)?;
    Ok(Json(credentials_json(&s, &shared, &device).await?).into_response())
}

async fn delete_credentials(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    body: Option<Json<CredentialConfirm>>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let dir = auth_dir(&s)?;
    // A unit flashed with its own account cannot fall back to the shared one.
    if body.and_then(|Json(b)| b.confirm).as_deref() != Some("REMOVE") {
        return Err(bad(
            "type REMOVE to delete this unit's own account; a unit flashed with it stays offline until reflashed with the shared account",
        ));
    }
    let mut db = connect_tx(&s).await?;
    let tx = db.transaction().await.map_err(db_err)?;
    let deleted = tx
        .execute(
            "DELETE FROM device_mqtt_credentials WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(db_err)?;
    if deleted == 0 {
        return Err(error(
            StatusCode::NOT_FOUND,
            "this unit uses the shared account",
        ));
    }
    crate::mqtt_auth::publish(&tx, &dir)
        .await
        .map_err(database)?;
    audit(
        &tx,
        Some(&device),
        &user.username,
        "mqtt_credentials_revoked",
        json!({}),
    )
    .await?;
    tx.commit().await.map_err(db_err)?;
    refresh_tabs(&s, &device);
    let shared = s.db.get().await.map_err(database)?;
    Ok(Json(credentials_json(&s, &shared, &device).await?).into_response())
}

// ---------------------------------------------------------------- datums

const DATUM_JSON: &str = "jsonb_build_object('id',id,'effective_from',effective_from,'sensor_depth_m',sensor_depth_m,
    'casing_height_m',casing_height_m,'ground_elevation_m',ground_elevation_m,'note',note,'created_by',created_by,
    'created_at',created_at)";

async fn datums(State(s): State<AppState>, h: HeaderMap, Path(device): Path<String>) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!("SELECT {DATUM_JSON} FROM device_datums WHERE device_id=$1 ORDER BY effective_from DESC"),
        &[&device],
    )
    .await?;
    Ok(Json(json!({"datums":rows})).into_response())
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DatumRequest {
    pub effective_from: DateTime<Utc>,
    pub sensor_depth_m: f64,
    #[serde(default)]
    pub casing_height_m: f64,
    pub ground_elevation_m: Option<f64>,
    #[serde(default)]
    pub note: String,
}

impl DatumRequest {
    pub fn validate(&self) -> Result<(), String> {
        let range = |v: f64, key: &str, min: f64, max: f64| {
            if v.is_finite() && (min..=max).contains(&v) {
                Ok(())
            } else {
                Err(format!("{key} must be {min}..{max} m"))
            }
        };
        range(self.sensor_depth_m, "sensor_depth_m", -100.0, 2000.0)?;
        range(self.casing_height_m, "casing_height_m", -50.0, 50.0)?;
        if let Some(ground) = self.ground_elevation_m {
            range(ground, "ground_elevation_m", -500.0, 9000.0)?;
        }
        line(&self.note, "note", 300)?;
        Ok(())
    }
}

async fn add_datum(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Json(q): Json<DatumRequest>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    q.validate().map_err(|e| bad(&e))?;
    let note = q.note.trim().to_owned();
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!(
            "INSERT INTO device_datums(device_id,effective_from,sensor_depth_m,casing_height_m,ground_elevation_m,note,
                created_by) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING {DATUM_JSON}"
        ),
        &[
            &device,
            &q.effective_from,
            &q.sensor_depth_m,
            &q.casing_height_m,
            &q.ground_elevation_m,
            &note,
            &user.username,
        ],
    )
    .await?;
    let datum = rows.into_iter().next().unwrap_or(Value::Null);
    audit(
        &*db,
        Some(&device),
        &user.username,
        "datum_added",
        datum.clone(),
    )
    .await?;
    refresh_tabs(&s, &device);
    Ok((StatusCode::CREATED, Json(json!({"datum":datum}))).into_response())
}

async fn delete_datum(
    State(s): State<AppState>,
    h: HeaderMap,
    Path((device, id)): Path<(String, i64)>,
) -> ApiResult {
    let user = operator(&h)?;
    let device = authorize(&s, &h, &device).await?;
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(
        &*db,
        &format!("DELETE FROM device_datums WHERE device_id=$1 AND id=$2 RETURNING {DATUM_JSON}"),
        &[&device, &id],
    )
    .await?;
    let Some(datum) = rows.into_iter().next() else {
        return Err(error(StatusCode::NOT_FOUND, "datum not found"));
    };
    audit(&*db, Some(&device), &user.username, "datum_removed", datum).await?;
    refresh_tabs(&s, &device);
    Ok(Json(json!({"deleted":true})).into_response())
}

// ---------------------------------------------------------------- exports

#[derive(Deserialize, Default)]
pub struct ExportQuery {
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
    format: Option<String>,
}

impl ExportQuery {
    fn bounds(&self) -> (DateTime<Utc>, DateTime<Utc>) {
        (
            self.from.unwrap_or(DateTime::UNIX_EPOCH),
            self.to
                .unwrap_or_else(|| Utc::now() + chrono::Duration::days(3650)),
        )
    }
}

/// JSON exports are built in memory, so they are capped: 20,000 rows (a
/// few MB of JSON, tens of MB while serialising) keep several concurrent
/// exports well inside the unit's `MemoryMax`. One extra row is fetched so
/// `truncated` is exact; the window narrows a bigger history.
const EXPORT_LIMIT: i64 = 20_000;

/// Drops the extra row fetched to detect truncation.
fn cap_export(rows: &mut Vec<Value>) -> bool {
    let truncated = rows.len() as i64 > EXPORT_LIMIT;
    rows.truncate(EXPORT_LIMIT as usize);
    truncated
}

fn attachment(name: &str, content_type: &str, body: String) -> Response {
    (
        [
            (header::CONTENT_TYPE, content_type.to_owned()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{name}\""),
            ),
        ],
        body,
    )
        .into_response()
}

async fn export_events(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<ExportQuery>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let (from, to) = q.bounds();
    let db = s.db.get().await.map_err(database)?;
    let mut events = json_rows(
        &*db,
        "SELECT jsonb_build_object('id',e.id,'source',e.source,'event',e.event,'log_id',e.log_id,'seq',e.seq,
            'record_type',e.record_type,'recorded_at',e.recorded_at,'time_valid',e.time_valid,'time_rel_s',e.time_rel_s,
            'time_source',e.time_source,'received_at',e.received_at,'details',e.details)
         FROM device_events e WHERE e.device_id=$1 AND COALESCE(e.recorded_at,e.received_at) BETWEEN $2 AND $3
         ORDER BY COALESCE(e.recorded_at,e.received_at),e.id LIMIT $4",
        &[&device, &from, &to, &(EXPORT_LIMIT + 1)],
    )
    .await?;
    let truncated = cap_export(&mut events);
    let body = json!({"device_id":device,"exported_at":Utc::now(),"from":q.from,"to":q.to,
        "truncated":truncated,"limit":EXPORT_LIMIT,"events":events});
    Ok(attachment(
        &format!("{device}-events.json"),
        "application/json",
        body.to_string(),
    ))
}

/// GeoJSON Feature for one position row (`[lon, lat, alt]`).
pub fn position_feature(row: &Value) -> Option<Value> {
    let lat = row.get("lat")?.as_f64()?;
    let lon = row.get("lon")?.as_f64()?;
    let mut coordinates = vec![json!(lon), json!(lat)];
    if let Some(alt) = row.get("alt_m").and_then(Value::as_f64) {
        coordinates.push(json!(alt));
    }
    let mut properties = row.clone();
    if let Some(map) = properties.as_object_mut() {
        map.remove("lat");
        map.remove("lon");
    }
    Some(
        json!({"type":"Feature","geometry":{"type":"Point","coordinates":coordinates},"properties":properties}),
    )
}

async fn export_positions(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<ExportQuery>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let geojson = match q.format.as_deref().unwrap_or("json") {
        "json" => false,
        "geojson" => true,
        _ => return Err(bad("format must be json or geojson")),
    };
    let (from, to) = q.bounds();
    let db = s.db.get().await.map_err(database)?;
    let mut positions = json_rows(
        &*db,
        "SELECT jsonb_build_object('id',id,'source',source,'log_id',log_id,'seq',seq,'recorded_at',recorded_at,
            'time_valid',time_valid,'time_source',time_source,'received_at',received_at,'settings_gen',settings_gen,
            'reason',reason,'fix',fix,'lat',lat,'lon',lon,'alt_m',alt_m,'hdop',hdop,'satellites',satellites)
         FROM device_positions WHERE device_id=$1 AND COALESCE(recorded_at,received_at) BETWEEN $2 AND $3
         ORDER BY COALESCE(recorded_at,received_at),id LIMIT $4",
        &[&device, &from, &to, &(EXPORT_LIMIT + 1)],
    )
    .await?;
    let truncated = cap_export(&mut positions);
    if geojson {
        let features: Vec<Value> = positions.iter().filter_map(position_feature).collect();
        let body = json!({"type":"FeatureCollection","features":features,
            "properties":{"device_id":device,"exported_at":Utc::now(),"truncated":truncated,"limit":EXPORT_LIMIT}});
        return Ok(attachment(
            &format!("{device}-positions.geojson"),
            "application/geo+json",
            body.to_string(),
        ));
    }
    let body = json!({"device_id":device,"exported_at":Utc::now(),"from":q.from,"to":q.to,
        "truncated":truncated,"limit":EXPORT_LIMIT,"positions":positions});
    Ok(attachment(
        &format!("{device}-positions.json"),
        "application/json",
        body.to_string(),
    ))
}

// ---------------------------------------------------------------- gap report

/// Open/requested gaps are current state; filled/unrecoverable gaps, frames
/// and logger `data_gap` records count inside the window.
const GAP_REPORT: &str = "SELECT jsonb_build_object('device_id',d.device_id,'display_name',d.display_name,
        'protocol_rev',d.protocol_rev,
        'logs',(SELECT count(*) FROM stream_logs l WHERE l.device_id=d.device_id),
        'frames',(SELECT count(*) FROM stream_frames f WHERE f.device_id=d.device_id AND f.received_at BETWEEN $2 AND $3),
        'open',COALESCE(cur.open,0),'requested',COALESCE(cur.requested,0),
        'unrecoverable',COALESCE(win.unrecoverable,0),'filled',COALESCE(win.filled,0),
        'missing_open',COALESCE(cur.missing,0),'missing_unrecoverable',COALESCE(win.missing_unrecoverable,0),
        'oldest_open_at',cur.oldest,'last_gap_at',win.last_gap,
        'data_gap_events',(SELECT count(*) FROM device_events e WHERE e.device_id=d.device_id AND e.event='data_gap'
            AND e.source='record' AND COALESCE(e.recorded_at,e.received_at) BETWEEN $2 AND $3),
        'last_stream_at',(SELECT max(received_at) FROM stream_batches b WHERE b.device_id=d.device_id))
    FROM devices d
    LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE state='open') AS open,
            count(*) FILTER (WHERE state='requested') AS requested,
            sum(to_seq-from_seq+1) AS missing,min(detected_at) AS oldest
        FROM stream_gaps g WHERE g.device_id=d.device_id AND g.state IN ('open','requested')) cur ON true
    LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE state='unrecoverable') AS unrecoverable,
            count(*) FILTER (WHERE state='filled') AS filled,
            sum(to_seq-from_seq+1) FILTER (WHERE state='unrecoverable') AS missing_unrecoverable,
            max(detected_at) AS last_gap
        FROM stream_gaps g WHERE g.device_id=d.device_id AND g.detected_at BETWEEN $2 AND $3) win ON true
    WHERE d.device_id=ANY($1)
    ORDER BY COALESCE(cur.open,0)+COALESCE(cur.requested,0) DESC,COALESCE(win.unrecoverable,0) DESC,d.display_name,d.device_id";

pub const GAP_COUNTERS: [&str; 9] = [
    "logs",
    "frames",
    "open",
    "requested",
    "unrecoverable",
    "filled",
    "missing_open",
    "missing_unrecoverable",
    "data_gap_events",
];

pub fn gap_totals(rows: &[Value]) -> Value {
    let mut totals = Map::new();
    for key in GAP_COUNTERS {
        let sum: i64 = rows
            .iter()
            .map(|r| {
                r.get(key)
                    .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
                    .unwrap_or(0)
            })
            .sum();
        totals.insert(key.into(), json!(sum));
    }
    totals.insert("devices".into(), json!(rows.len()));
    Value::Object(totals)
}

async fn fleet_gap_report(
    State(s): State<AppState>,
    h: HeaderMap,
    Query(q): Query<ExportQuery>,
) -> ApiResult {
    let ids = visible(&s, &h).await?;
    let (from, to) = q.bounds();
    let db = s.db.get().await.map_err(database)?;
    let rows = json_rows(&*db, GAP_REPORT, &[&ids, &from, &to]).await?;
    let totals = gap_totals(&rows);
    Ok(Json(json!({"from":q.from,"to":q.to,"devices":rows,"totals":totals})).into_response())
}

async fn device_gap_report(
    State(s): State<AppState>,
    h: HeaderMap,
    Path(device): Path<String>,
    Query(q): Query<ExportQuery>,
) -> ApiResult {
    let device = authorize(&s, &h, &device).await?;
    let (from, to) = q.bounds();
    let db = s.db.get().await.map_err(database)?;
    let report = json_rows(&*db, GAP_REPORT, &[&vec![device.clone()], &from, &to])
        .await?
        .into_iter()
        .next();
    let gaps = json_rows(
        &*db,
        "SELECT jsonb_build_object('id',id,'log_id',log_id,'from_seq',from_seq,'to_seq',to_seq,'state',state,
            'attempts',attempts,'command_id',command_id,'detected_at',detected_at,'resolved_at',resolved_at,
            'last_requested_at',last_requested_at)
         FROM stream_gaps WHERE device_id=$1 AND (state IN ('open','requested') OR detected_at BETWEEN $2 AND $3)
         ORDER BY (state IN ('open','requested')) DESC,detected_at DESC LIMIT 1000",
        &[&device, &from, &to],
    )
    .await?;
    Ok(Json(json!({"report":report,"gaps":gaps})).into_response())
}

// ---------------------------------------------------------------- metrics

/// Constant-time comparison of the scraper's bearer token.
pub fn metrics_token_ok(ops: &OpsSettings, headers: &HeaderMap) -> bool {
    let Some(expected) = ops.metrics_token.as_deref() else {
        return false;
    };
    let Some(given) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    let (a, b) = (expected.as_bytes(), given.trim().as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub async fn metrics(State(s): State<AppState>) -> ApiResult {
    // `api::boundary` admitted an operator or a valid scraper token.
    let db = s.db.get().await.map_err(database)?;
    let ids: Vec<String> = db
        .query("SELECT device_id FROM devices", &[])
        .await
        .map_err(db_err)?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let devices = crate::db::scoped_devices(&db, &ids)
        .await
        .map_err(database)?;
    let mut out = crate::metrics::Exposition::default();
    crate::metrics::devices(&mut out, &devices, Utc::now());
    crate::metrics::ingest(&mut out, &*s.stats.lock().await);
    crate::metrics::database(&mut out, &db)
        .await
        .map_err(database)?;
    Ok((
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        out.finish(),
    )
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(value: Value) -> EnrollRequest {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn enrollment_validation_mirrors_the_contract() {
        let ok = validate_enrollment(&request(json!({
            "device_id":"6a1b2c3d4e5f60718293a4b5","display_name":" Bore 7 ","profile":"v22",
            "location_id":"A7","project":"North","viewers":["alice","alice","bob@example.org"]
        })))
        .unwrap();
        assert_eq!(ok.device_id, "6A1B2C3D4E5F60718293A4B5");
        assert_eq!(ok.display_name, "Bore 7");
        assert_eq!((ok.profile, ok.clock_policy), ("V22", "utc"));
        assert!(ok.bind_v1);
        assert_eq!(ok.viewers, ["alice", "bob@example.org"]);
        assert_eq!(ok.sensor_id, None);
        let v21 = validate_enrollment(&request(json!({
            "device_id":"8F3A21C04B9E77A1D25C01FE","profile":"V21","clock_policy":"local-offset",
            "local_offset_min":300,"bindings":"none"
        })))
        .unwrap();
        assert_eq!(v21.local_offset_min, Some(300));
        assert!(!v21.bind_v1);
        for (bad, fragment) in [
            (json!({"device_id":"XYZ","profile":"V22"}), "24-character"),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V20"}),
                "SQL procedure",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V22","clock_policy":"local-offset","local_offset_min":60}),
                "utc",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V21","clock_policy":"local-offset"}),
                "local_offset_min",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V21","clock_policy":"utc","local_offset_min":0}),
                "applies only",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V21","clock_policy":"utc","bindings":"legacy"}),
                "bindings",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V22","viewers":["no spaces"]}),
                "viewer",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V22","location_id":"x".repeat(33)}),
                "location_id",
            ),
            (
                json!({"device_id":"6A1B2C3D4E5F60718293A4B5","profile":"V22","display_name":"a\nb"}),
                "single line",
            ),
        ] {
            let error = validate_enrollment(&request(bad.clone())).expect_err(&bad.to_string());
            assert!(error.contains(fragment), "{bad}: {error}");
        }
    }

    #[test]
    fn policies_resolve_field_by_field_with_their_source() {
        let device = PolicyValues {
            battery_low_mv: Some(6800),
            ..Default::default()
        };
        let project = PolicyValues {
            battery_low_mv: Some(6900),
            stale_margin_min: Some(120),
            ..Default::default()
        };
        let fleet = PolicyValues {
            stale_enabled: Some(false),
            stale_margin_min: Some(60),
            ..Default::default()
        };
        let (effective, sources) = resolve_policy(
            Some(&device),
            Some(&project),
            Some(&fleet),
            &PolicyValues::builtin(30),
        );
        assert_eq!(effective["battery_low_mv"], 6800);
        assert_eq!(sources["battery_low_mv"], "device");
        assert_eq!(effective["stale_margin_min"], 120);
        assert_eq!(sources["stale_margin_min"], "project");
        assert_eq!(effective["stale_enabled"], false);
        assert_eq!(sources["stale_enabled"], "fleet");
        assert_eq!(effective["solar_samples"], 3);
        assert_eq!(sources["solar_samples"], "default");
        assert!(PolicyValues {
            battery_low_mv: Some(2000),
            ..Default::default()
        }
        .validate()
        .is_err());
        assert!(PolicyValues {
            stale_margin_min: Some(4),
            ..Default::default()
        }
        .validate()
        .is_err());
        assert!(PolicyValues::builtin(30).validate().is_ok());
    }

    #[test]
    fn limits_validate_and_mirror_firmware_keys() {
        let limits: LimitsRequest = serde_json::from_value(json!({
            "min_limit":1.5,"max_limit":9.0,"min_hysteresis":0.2,"max_hysteresis":null
        }))
        .unwrap();
        assert!(limits.validate().is_ok());
        assert_eq!(
            limits.settings_args(),
            json!({"lo":1.5,"hi":9.0,"lo_hys":0.2})
        );
        assert!(crate::settings::validate(&limits.settings_args(), 0).is_ok());
        let unset: LimitsRequest =
            serde_json::from_value(json!({"min_limit":null,"max_limit":null})).unwrap();
        assert_eq!(unset.settings_args(), json!({"lo":null,"hi":null}));
        for bad in [
            json!({"min_limit":5,"max_limit":5}),
            json!({"min_limit":-2000}),
            json!({"max_hysteresis":-0.1}),
        ] {
            let limits: LimitsRequest = serde_json::from_value(bad.clone()).unwrap();
            assert!(limits.validate().is_err(), "{bad}");
        }
    }

    #[test]
    fn gap_totals_sum_every_counter() {
        let rows = [
            json!({"logs":1,"frames":10,"open":1,"requested":0,"unrecoverable":0,"filled":2,
                "missing_open":3,"missing_unrecoverable":0,"data_gap_events":1}),
            json!({"logs":2,"frames":5,"open":0,"requested":1,"unrecoverable":1,"filled":0,
                "missing_open":2,"missing_unrecoverable":4,"data_gap_events":0}),
        ];
        let totals = gap_totals(&rows);
        assert_eq!(totals["frames"], 15);
        assert_eq!(totals["missing_open"], 5);
        assert_eq!(totals["devices"], 2);
    }

    #[test]
    fn positions_export_as_geojson_points() {
        let feature =
            position_feature(&json!({"lat":-33.86,"lon":151.2,"alt_m":12,"seq":4})).unwrap();
        assert_eq!(
            feature["geometry"]["coordinates"],
            json!([151.2, -33.86, 12.0])
        );
        assert_eq!(feature["properties"], json!({"alt_m":12,"seq":4}));
        assert!(position_feature(&json!({"lat":null,"lon":151.2})).is_none());
    }

    #[test]
    fn metrics_tokens_compare_exactly() {
        let ops = OpsSettings {
            metrics_token: Some("0123456789abcdef0123".into()),
            ..Default::default()
        };
        let mut headers = HeaderMap::new();
        assert!(!metrics_token_ok(&ops, &headers));
        headers.insert(
            header::AUTHORIZATION,
            "Bearer 0123456789abcdef0123".parse().unwrap(),
        );
        assert!(metrics_token_ok(&ops, &headers));
        headers.insert(
            header::AUTHORIZATION,
            "Bearer 0123456789abcdef0124".parse().unwrap(),
        );
        assert!(!metrics_token_ok(&ops, &headers));
        assert!(!metrics_token_ok(&OpsSettings::default(), &headers));
    }
}
