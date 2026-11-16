//! Operations features against a real PostgreSQL. The caller supplies a
//! disposable database in GROUNDWATER_TEST_DATABASE_URL; run with
//! `--include-ignored --test-threads=1` (the database tests share tables).
//!
//! Covered because each guards a concrete risk: enrollment/retirement change
//! who may publish as a device, credentials files are read by an
//! internet-facing broker listener, and notifications must neither be lost
//! nor spam an operator's phone.
use crate::{api, config::OpsSettings, db, ingest::EventBus, topics::TopicMap};
use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio_postgres::Client;
use tower::ServiceExt;

const D: &str = "6A1B2C3D4E5F60718293A4B5";
const L: &str = "8F3A21C04B9E77A1D25C01FE";

const ALL_TABLES: &str = "TRUNCATE devices,device_bindings,observations,deliveries,commands,command_events,
    command_publish_attempts,alerts,device_permissions,stream_batches,stream_frames,stream_logs,stream_gaps,
    device_events,device_positions,device_tilt,device_tests,device_health,settings_fragments,
    device_settings_history,device_file_lists,file_downloads,file_download_chunks,device_audit,alert_policies,
    notification_rules,notification_outbox,device_datums,device_mqtt_credentials RESTART IDENTITY CASCADE";

async fn setup() -> (String, Client) {
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let client = db::connect(&url).await.unwrap();
    db::migrate(&client).await.unwrap();
    client.batch_execute(ALL_TABLES).await.unwrap();
    // Restores the default notification rules.
    db::migrate(&client).await.unwrap();
    (url, client)
}

async fn app(url: &str, ops: OpsSettings) -> axum::Router {
    let settings = crate::config::Settings {
        database_url: url.to_owned(),
        address: "127.0.0.1".into(),
        port: 0,
        topics: TopicMap::default(),
        mqtt: None,
        retention_days: 90,
        rev2: Default::default(),
        ops,
    };
    api::router(api::AppState {
        settings: Arc::new(settings),
        db: Arc::new(db::Database::new(
            url.to_owned(),
            db::connect(url).await.unwrap(),
        )),
        bus: EventBus::new(),
        stats: Default::default(),
        registry_changed: Default::default(),
    })
}

/// `user` "operator" is an app-admin; any other name is a groundwater-user.
async fn call(
    app: &axum::Router,
    method: &str,
    path: &str,
    user: &str,
    body: Value,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if user != "anonymous" {
        request = request
            .header("x-auth-request-preferred-username", user)
            .header(
                "x-auth-request-groups",
                if user == "operator" {
                    "app-admin"
                } else {
                    "groundwater-user"
                },
            );
    }
    let response = app
        .clone()
        .oneshot(
            request
                .body(if body.is_null() {
                    Body::empty()
                } else {
                    Body::from(body.to_string())
                })
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    let value = serde_json::from_slice(&bytes)
        .unwrap_or_else(|_| json!({"text":String::from_utf8_lossy(&bytes)}));
    (status, value)
}

async fn scalar<T: for<'a> tokio_postgres::types::FromSql<'a>>(client: &Client, sql: &str) -> T {
    client.query_one(sql, &[]).await.unwrap().get(0)
}

async fn enroll_v22(app: &axum::Router) {
    let (status, value) = call(
        app,
        "POST",
        "/api/devices",
        "operator",
        json!({"device_id":D.to_lowercase(),"display_name":"Bore 7","profile":"V22","location_id":"A7",
            "project":"North","viewers":["viewer"]}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn provisioning_enrolls_edits_retires_and_audits() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    // Viewers cannot enroll; the boundary refuses before validation.
    let (status, _) = call(
        &app,
        "POST",
        "/api/devices",
        "viewer",
        json!({"device_id":D,"profile":"V22"}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    enroll_v22(&app).await;
    let (status, _) = call(
        &app,
        "POST",
        "/api/devices",
        "operator",
        json!({"device_id":D,"profile":"V22"}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, value) = call(
        &app,
        "POST",
        "/api/devices",
        "operator",
        json!({"device_id":L,"profile":"V20"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(value["error"].as_str().unwrap().contains("SQL"));

    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM device_bindings WHERE revoked_at IS NULL"
        )
        .await,
        18
    );
    let device: (String, String, String) = {
        let row = client
            .query_one(
                "SELECT source_profile,clock_policy,project FROM devices WHERE device_id=$1",
                &[&D],
            )
            .await
            .unwrap();
        (row.get(0), row.get(1), row.get(2))
    };
    assert_eq!(device, ("V22".into(), "utc".into(), "North".into()));
    // The named viewer sees it; another viewer does not.
    let (_, devices) = call(&app, "GET", "/api/devices", "viewer", Value::Null).await;
    assert_eq!(devices["devices"][0]["device_id"], D);
    assert_eq!(devices["devices"][0]["project"], "North");
    assert_eq!(devices["devices"][0]["mqtt_auth"], "shared");
    let (_, other) = call(&app, "GET", "/api/devices", "someone", Value::Null).await;
    assert_eq!(other["devices"], json!([]));
    // The registry the ingest loop loads accepts the new bindings.
    let registry = db::load_registry(&client).await.unwrap();
    assert!(registry
        .binding_for_topic(&format!("gwl/v1/{D}/data/stream"))
        .is_some());

    let (status, value) = call(
        &app,
        "PATCH",
        &format!("/api/devices/{D}"),
        "operator",
        json!({"display_name":"Bore 7 (north)","sensor_id":"S-12","location_id":""}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["device"]["display_name"], "Bore 7 (north)");
    assert_eq!(value["device"]["location_id"], Value::Null);
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/permissions"),
        "operator",
        json!({"username":"alice"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/devices/{D}/permissions/viewer"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, permissions) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/permissions"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(permissions["permissions"][0]["username"], "alice");
    assert_eq!(permissions["permissions"][0]["granted_by"], "operator");

    // Retiring cancels pending work and revokes every binding.
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/commands"),
        "operator",
        json!({"op":"get_status"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    client
        .execute(
            "INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at) VALUES($1,'battery_low','open',6.8,now())",
            &[&D],
        )
        .await
        .unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/retire"),
        "operator",
        json!({"confirm":"retire"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/retire"),
        "operator",
        json!({"confirm":"RETIRE","reason":"bore decommissioned"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["device"]["status"], "revoked");
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM device_bindings WHERE revoked_at IS NULL"
        )
        .await,
        0
    );
    assert_eq!(
        scalar::<String>(&client, "SELECT state FROM commands").await,
        "cancelled"
    );
    assert_eq!(
        scalar::<String>(&client, "SELECT resolved_by FROM alerts").await,
        "operator"
    );
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/reinstate"),
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM device_bindings WHERE revoked_at IS NULL"
        )
        .await,
        18
    );
    let (_, audit) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/audit"),
        "operator",
        Value::Null,
    )
    .await;
    let actions: Vec<&str> = audit["audit"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["action"].as_str().unwrap())
        .collect();
    assert_eq!(
        actions,
        [
            "reinstated",
            "retired",
            "permission_revoked",
            "permission_granted",
            "updated",
            "enrolled"
        ]
    );
    assert_eq!(audit["audit"][4]["detail"]["sensor_id"]["to"], "S-12");
    let (status, _) = call(&app, "GET", "/api/audit", "viewer", Value::Null).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn alert_policies_drive_power_alerts_and_acknowledgement() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    enroll_v22(&app).await;
    let health = |mv: i32, sol: i32, minutes: i64| {
        let client = &client;
        async move {
            client
                .execute(
                    "INSERT INTO device_health(device_id,recorded_at,time_source,received_at,bat_mv,sol_mv,payload)
                     VALUES($1,now()-make_interval(mins=>$4::int),'device',now(),$2,$3,'{}')",
                    &[&D, &mv, &sol, &(minutes as i32)],
                )
                .await
                .unwrap();
            client
                .execute("SELECT groundwater_power_alerts($1)", &[&D])
                .await
                .unwrap();
        }
    };
    // 6950 mV is low under the built-in 7000 mV threshold ...
    health(6950, 5000, 30).await;
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='open'"
        )
        .await,
        1
    );
    // ... the project lowers it to 6900, which also re-evaluates the fleet.
    let (status, value) = call(
        &app,
        "PUT",
        "/api/alert-policies",
        "operator",
        json!({"scope":"project","target":"North","battery_low_mv":6900,"battery_hys_mv":100,
            "solar_samples":2}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    // Still open: the clear level is now 6900 + 100 = 7000.
    health(6990, 5000, 20).await;
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='open'"
        )
        .await,
        1
    );
    health(7000, 500, 10).await;
    assert_eq!(
        scalar::<String>(&client, "SELECT state FROM alerts WHERE kind='battery_low'").await,
        "resolved"
    );
    // Two dark samples are enough for this project.
    health(7400, 400, 5).await;
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM alerts WHERE kind='solar_low' AND state='open'"
        )
        .await,
        1
    );
    // A device override wins over the project, field by field.
    let (status, _) = call(
        &app,
        "PUT",
        "/api/alert-policies",
        "operator",
        json!({"scope":"device","target":D,"solar_samples":5,"stale_margin_min":90}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, policy) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/alert-policy"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(policy["effective"]["battery_low_mv"], 6900);
    assert_eq!(policy["sources"]["battery_low_mv"], "project");
    assert_eq!(policy["effective"]["solar_samples"], 5);
    assert_eq!(policy["sources"]["solar_samples"], "device");
    assert_eq!(policy["sources"]["battery_hys_mv"], "project");
    assert_eq!(policy["sources"]["stale_enabled"], "default");
    let (status, _) = call(
        &app,
        "PUT",
        "/api/alert-policies",
        "operator",
        json!({"scope":"fleet","target":"x","battery_low_mv":6000}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = call(
        &app,
        "PUT",
        "/api/alert-policies",
        "operator",
        json!({"scope":"fleet","battery_low_mv":100}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Acknowledge keeps it open; resolve closes it with who and why.
    let id: i64 = scalar(&client, "SELECT id FROM alerts WHERE kind='solar_low'").await;
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/alerts/{id}/acknowledge"),
        "operator",
        json!({"note":"panel shaded"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["alert"]["state"], "open");
    assert_eq!(value["alert"]["acknowledged_by"], "operator");
    assert_eq!(value["alert"]["severity"], "info");
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/alerts/{id}/resolve"),
        "viewer",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/alerts/{id}/resolve"),
        "operator",
        json!({"note":"cleaned"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["alert"]["resolved_by"], "operator");
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/alerts/{id}/resolve"),
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (_, listed) = call(
        &app,
        "GET",
        &format!("/api/alerts?device={D}&state=all&kind=solar_low"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(listed["alerts"][0]["resolve_note"], "cleaned");
    assert_eq!(listed["alerts"][0]["display_name"], "Bore 7");
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn level_limits_and_hand_resolution_survive_replay() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    // A revision 1 unit: the server limits are edited directly.
    client
        .execute(
            "INSERT INTO devices(device_id,display_name,source_profile,clock_policy) VALUES($1,'Legacy','V21','utc')",
            &[&L],
        )
        .await
        .unwrap();
    let (status, value) = call(
        &app,
        "PUT",
        &format!("/api/devices/{L}/limits"),
        "operator",
        json!({"min_limit":1.0,"max_limit":5.0,"min_hysteresis":0.2,"max_hysteresis":0.3}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["device"]["max_hysteresis"], 0.3);
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/devices/{L}/limits"),
        "operator",
        json!({"min_limit":5.0,"max_limit":1.0}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let base = Utc::now() - Duration::hours(3);
    for (minutes, level) in [(0, 4.0), (10, 6.0), (20, 6.5), (30, 4.8), (40, 4.0)] {
        client
            .execute(
                "INSERT INTO observations(device_id,kind,payload_digest,recorded_at,received_at,time_quality,
                    time_reason,zone_source,interpretation_version,gwl,gwl_text,battery_truncated,solar_truncated,
                    duplicate_outcome,duplicate_reason,payload)
                 VALUES($1,'water',$4,$2,now(),'plausible','test','payload','test',$3,$5,false,false,
                    'new','test','{}')",
                &[&L, &(base + Duration::minutes(minutes)), &level, &format!("d{minutes}"), &level.to_string()],
            )
            .await
            .unwrap();
    }
    crate::platform::refresh_alerts(&client).await.unwrap();
    // 4.8 is inside the 0.3 m hysteresis band below 5.0; 4.0 resolves.
    let row = client
        .query_one(
            "SELECT id,state,resolved_at FROM alerts WHERE kind='above_max'",
            &[],
        )
        .await
        .unwrap();
    let id: i64 = row.get(0);
    assert_eq!(row.get::<_, String>(1), "resolved");
    assert_eq!(
        row.get::<_, Option<DateTime<Utc>>>(2)
            .map(|t| t.timestamp()),
        Some((base + Duration::minutes(40)).timestamp())
    );
    // Hand-resolve an episode that is still open, then force a full replay.
    client
        .execute(
            "UPDATE alerts SET state='open',resolved_at=NULL WHERE id=$1",
            &[&id],
        )
        .await
        .unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/alerts/{id}/resolve"),
        "operator",
        json!({"note":"sensor recalibrated"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    client
        .execute(
            "UPDATE devices SET alerts_dirty=true,alerts_replay_all=true WHERE device_id=$1",
            &[&L],
        )
        .await
        .unwrap();
    crate::platform::refresh_alerts(&client).await.unwrap();
    let row = client
        .query_one(
            "SELECT state,resolved_by,resolve_note FROM alerts WHERE id=$1",
            &[&id],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "resolved");
    assert_eq!(row.get::<_, Option<String>>(1).as_deref(), Some("operator"));
    assert_eq!(
        row.get::<_, Option<String>>(2).as_deref(),
        Some("sensor recalibrated")
    );

    // A V22 unit's limits live in the logger: a settings command is queued.
    enroll_v22(&app).await;
    let (status, value) = call(
        &app,
        "PUT",
        &format!("/api/devices/{D}/limits"),
        "operator",
        json!({"min_limit":null,"max_limit":10.5,"max_hysteresis":0.2}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
    assert_eq!(value["command"]["op"], "settings");
    assert_eq!(
        value["command"]["args"],
        json!({"lo":null,"hi":10.5,"hi_hys":0.2})
    );
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn missed_connections_open_and_close_stale_alerts() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    enroll_v22(&app).await;
    let now = Utc::now();
    // Asleep, announced next connection 2 h ago; margin 30 min → stale.
    client
        .execute(
            "UPDATE devices SET last_seen=$2,link_state='sleep',link_state_at=$2,next_contact_at=$3 WHERE device_id=$1",
            &[&D, &(now - Duration::hours(26)), &(now - Duration::hours(2))],
        )
        .await
        .unwrap();
    let changed = crate::alerting::evaluate_stale(&client, now, 30)
        .await
        .unwrap();
    assert_eq!(changed, [D]);
    let row = client
        .query_one(
            "SELECT state,trigger_value,opened_at,detail FROM alerts WHERE kind='stale'",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "open");
    assert!((row.get::<_, f64>(1) - 2.0).abs() < 0.05);
    assert_eq!(
        row.get::<_, DateTime<Utc>>(2).timestamp(),
        (now - Duration::minutes(90)).timestamp()
    );
    assert_eq!(row.get::<_, Value>(3)["margin_min"], 30);
    // Idempotent while still stale.
    assert!(crate::alerting::evaluate_stale(&client, now, 30)
        .await
        .unwrap()
        .is_empty());
    // A wider device margin (policy) means it is not stale yet ...
    client.execute("DELETE FROM alerts", &[]).await.unwrap();
    client
        .execute(
            "INSERT INTO alert_policies(scope,target,stale_margin_min,updated_by) VALUES('device',$1,180,'test')",
            &[&D],
        )
        .await
        .unwrap();
    assert!(crate::alerting::evaluate_stale(&client, now, 30)
        .await
        .unwrap()
        .is_empty());
    let (_, device) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(device["device"]["status"], "asleep");
    client
        .execute("DELETE FROM alert_policies", &[])
        .await
        .unwrap();
    crate::alerting::evaluate_stale(&client, now, 30)
        .await
        .unwrap();
    // ... and the next connection ends the episode at its contact time.
    let contact = now - Duration::minutes(1);
    client
        .execute(
            "UPDATE devices SET last_seen=$2,link_state='sleep',link_state_at=$2,next_contact_at=$3 WHERE device_id=$1",
            &[&D, &contact, &(now + Duration::hours(23))],
        )
        .await
        .unwrap();
    crate::alerting::evaluate_stale(&client, now, 30)
        .await
        .unwrap();
    let row = client
        .query_one(
            "SELECT state,resolved_at,detail->>'resolution' FROM alerts WHERE kind='stale'",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "resolved");
    assert_eq!(
        row.get::<_, DateTime<Utc>>(1).timestamp(),
        contact.timestamp()
    );
    assert_eq!(row.get::<_, String>(2), "contact");
}

/// A stand-in ntfy server that records JSON publishes.
async fn fake_ntfy(fail: bool) -> (String, Arc<tokio::sync::Mutex<Vec<Value>>>) {
    let seen = Arc::new(tokio::sync::Mutex::new(Vec::new()));
    let state = seen.clone();
    let router = axum::Router::new().route(
        "/",
        axum::routing::post(move |axum::Json(body): axum::Json<Value>| {
            let state = state.clone();
            async move {
                state.lock().await.push(body);
                if fail {
                    StatusCode::INTERNAL_SERVER_ERROR
                } else {
                    StatusCode::OK
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (format!("http://{address}"), seen)
}

fn ops_for(server: &str) -> OpsSettings {
    OpsSettings {
        ntfy: Some(crate::config::NtfyTarget::parse(&format!("{server}/gw")).unwrap()),
        public_url: Some("https://groundwater.example".into()),
        notify_max_per_hour: 30,
        ..Default::default()
    }
}

async fn outbox(client: &Client) -> Vec<(String, String, String, Option<String>)> {
    client
        .query(
            "SELECT kind,transition,state,reason FROM notification_outbox ORDER BY id",
            &[],
        )
        .await
        .unwrap()
        .iter()
        .map(|r| (r.get(0), r.get(1), r.get(2), r.get(3)))
        .collect()
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn notifications_deliver_dedupe_and_rate_limit() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    enroll_v22(&app).await;
    let (server, seen) = fake_ntfy(false).await;
    let ops = ops_for(&server);
    let http = crate::notify::http_client();
    let open = |kind: &'static str, minutes: i64| {
        let client = &client;
        async move {
            client
                .query_one(
                    "INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at)
                     VALUES($1,$2,'open',6.91,now()-make_interval(mins=>$3::int)) RETURNING id",
                    &[&D, &kind, &(minutes as i32)],
                )
                .await
                .unwrap()
                .get::<_, i64>(0)
        }
    };
    let resolve = |id: i64| {
        let client = &client;
        async move {
            client
                .execute(
                    "UPDATE alerts SET state='resolved',resolved_at=now() WHERE id=$1",
                    &[&id],
                )
                .await
                .unwrap();
        }
    };
    // A flapping battery: open, resolve, open, resolve within the cooldown.
    let first = open("battery_low", 30).await;
    crate::notify::process(&client, &ops, &http).await.unwrap();
    resolve(first).await;
    let second = open("battery_low", 10).await;
    crate::notify::process(&client, &ops, &http).await.unwrap();
    resolve(second).await;
    let third = open("battery_low", 1).await;
    crate::notify::process(&client, &ops, &http).await.unwrap();
    assert_eq!(
        outbox(&client).await,
        [
            ("battery_low".into(), "open".into(), "sent".into(), None),
            ("battery_low".into(), "resolved".into(), "sent".into(), None),
            (
                "battery_low".into(),
                "open".into(),
                "suppressed".into(),
                Some("cooldown".into())
            ),
            (
                "battery_low".into(),
                "resolved".into(),
                "skipped".into(),
                Some("resolved-unsent".into())
            ),
            (
                "battery_low".into(),
                "open".into(),
                "suppressed".into(),
                Some("cooldown".into())
            ),
        ]
    );
    let messages = seen.lock().await.clone();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["topic"], "gw");
    assert_eq!(messages[0]["title"], "Bore 7: battery low (6.91 V)");
    assert!(messages[0]["message"]
        .as_str()
        .unwrap()
        .contains("Location: A7 · Project: North"));
    assert_eq!(
        messages[0]["click"],
        format!("https://groundwater.example/#device={D}&view=alerts")
    );
    assert_eq!(messages[1]["title"], "Bore 7: battery recovered");
    // After the cooldown, the next opening reports what was suppressed.
    client
        .execute(
            "UPDATE notification_outbox SET sent_at=sent_at-interval '13 hours' WHERE state='sent'",
            &[],
        )
        .await
        .unwrap();
    client
        .execute(
            "UPDATE notification_outbox SET created_at=created_at-interval '12 hours' WHERE state='suppressed'",
            &[],
        )
        .await
        .unwrap();
    resolve(third).await;
    open("battery_low", 0).await;
    crate::notify::process(&client, &ops, &http).await.unwrap();
    let messages = seen.lock().await.clone();
    assert_eq!(messages.len(), 3);
    assert!(messages[2]["message"]
        .as_str()
        .unwrap()
        .contains("2 similar notifications suppressed"));

    // A logger alert copy and its ring record notify once; old events never.
    for (source, seq) in [("alert", 41), ("record", 41)] {
        client
            .execute(
                "INSERT INTO device_events(device_id,source,event,seq,log_id,recorded_at,received_at,details)
                 VALUES($1,$2,'power_critical',$3,CASE WHEN $2='record' THEN 1 END,now(),now(),
                    '{\"state\":\"enter\",\"bat_mv\":6550}')",
                &[&D, &source, &(seq as i64)],
            )
            .await
            .unwrap();
    }
    client
        .execute(
            "INSERT INTO device_events(device_id,source,event,seq,recorded_at,received_at,details)
             VALUES($1,'record','impact',7,now()-interval '3 days',now(),'{\"peak_mg\":1500}'),
                   ($1,'server','link_lost',NULL,now(),now(),'{}')",
            &[&D],
        )
        .await
        .unwrap();
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM notification_outbox WHERE kind='power_critical'"
        )
        .await,
        1
    );
    assert_eq!(
        scalar::<i64>(
            &client,
            "SELECT count(*) FROM notification_outbox WHERE kind='tamper'"
        )
        .await,
        0
    );
    // The fleet cap holds back warnings but never critical messages.
    client
        .execute(
            "INSERT INTO notification_outbox(device_id,kind,severity,transition,event,occurred_at,state,sent_at)
             SELECT $1,'tamper','warning','event','impact',now(),'sent',now() FROM generate_series(1,40)",
            &[&D],
        )
        .await
        .unwrap();
    client
        .execute(
            "INSERT INTO device_events(device_id,source,event,seq,recorded_at,received_at,details)
             VALUES($1,'alert','sensor_fault',50,now(),now(),'{\"state\":\"enter\"}')",
            &[&D],
        )
        .await
        .unwrap();
    crate::notify::process(&client, &ops, &http).await.unwrap();
    let states: Vec<(String, String, Option<String>)> = client
        .query(
            "SELECT kind,state,reason FROM notification_outbox WHERE kind IN ('power_critical','sensor_fault') ORDER BY id",
            &[],
        )
        .await
        .unwrap()
        .iter()
        .map(|r| (r.get(0), r.get(1), r.get(2)))
        .collect();
    assert_eq!(
        states,
        [
            ("power_critical".into(), "sent".into(), None),
            (
                "sensor_fault".into(),
                "suppressed".into(),
                Some("rate-limit".into())
            ),
        ]
    );
    let last = seen.lock().await.last().cloned().unwrap();
    assert_eq!(last["priority"], 5);
    assert_eq!(last["tags"], json!(["rotating_light"]));
    assert_eq!(
        last["click"],
        format!("https://groundwater.example/#device={D}&view=events")
    );

    // Rules: disabling a kind skips it; the API validates and audits.
    let (status, value) = call(
        &app,
        "PUT",
        "/api/notifications/rules/stale",
        "operator",
        json!({"enabled":false,"topic":"bore-alerts"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    let rule = value["rules"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["kind"] == "stale")
        .unwrap()
        .clone();
    assert_eq!(rule["enabled"], false);
    assert_eq!(rule["topic"], "bore-alerts");
    assert_eq!(rule["updated_by"], "operator");
    for bad in [
        json!({"priority":9}),
        json!({"min_severity":"loud"}),
        json!({"topic":"no spaces"}),
    ] {
        let (status, _) = call(
            &app,
            "PUT",
            "/api/notifications/rules/stale",
            "operator",
            bad,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    open("stale", 0).await;
    crate::notify::process(&client, &ops, &http).await.unwrap();
    assert_eq!(
        scalar::<String>(
            &client,
            "SELECT reason FROM notification_outbox WHERE kind='stale'"
        )
        .await,
        "disabled"
    );
    let (_, listed) = call(
        &app,
        "GET",
        "/api/notifications?limit=5",
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(listed["notifications"].as_array().unwrap().len(), 5);
    let (status, _) = call(&app, "GET", "/api/notifications", "viewer", Value::Null).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn notification_delivery_retries_and_test_messages() {
    let (url, client) = setup().await;
    let (server, seen) = fake_ntfy(true).await;
    let ops = ops_for(&server);
    let app = app(&url, ops.clone()).await;
    enroll_v22(&app).await;
    client
        .execute(
            "INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at) VALUES($1,'above_max','open',9.9,now())",
            &[&D],
        )
        .await
        .unwrap();
    let http = crate::notify::http_client();
    crate::notify::process(&client, &ops, &http).await.unwrap();
    let row = client
        .query_one(
            "SELECT state,attempts,error,next_attempt_at>now() FROM notification_outbox",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "pending");
    assert_eq!(row.get::<_, i32>(1), 1);
    assert!(row.get::<_, String>(2).contains("500"));
    assert!(row.get::<_, bool>(3));
    let (status, value) = call(
        &app,
        "POST",
        "/api/notifications/test",
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{value}");
    assert_eq!(seen.lock().await.len(), 2);
    // Without ntfy, rows are recorded and skipped, never left pending.
    let unconfigured = app_unconfigured(&url).await;
    let (status, _) = call(
        &unconfigured,
        "POST",
        "/api/notifications/test",
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    client
        .execute("UPDATE notification_outbox SET next_attempt_at=now()", &[])
        .await
        .unwrap();
    crate::notify::process(&client, &OpsSettings::default(), &http)
        .await
        .unwrap();
    assert_eq!(
        scalar::<String>(&client, "SELECT reason FROM notification_outbox").await,
        "not-configured"
    );
    let (_, rules) = call(
        &unconfigured,
        "GET",
        "/api/notifications/rules",
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(rules["delivery"]["configured"], false);
    assert_eq!(rules["rules"].as_array().unwrap().len(), 10);
}

async fn app_unconfigured(url: &str) -> axum::Router {
    app(url, OpsSettings::default()).await
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn per_device_credentials_write_broker_files() {
    let (url, client) = setup().await;
    let dir = tempfile::tempdir().unwrap();
    let ops = OpsSettings {
        mqtt_auth_dir: Some(dir.path().to_owned()),
        ..Default::default()
    };
    let app = app(&url, ops).await;
    let disabled = app_unconfigured(&url).await;
    enroll_v22(&app).await;
    let (status, value) = call(
        &disabled,
        "POST",
        &format!("/api/devices/{D}/mqtt-credentials"),
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{value}");
    let (_, value) = call(
        &disabled,
        "GET",
        &format!("/api/devices/{D}/mqtt-credentials"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(value["available"], false);

    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/mqtt-credentials"),
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
    let password = value["password"].as_str().unwrap().to_owned();
    assert_eq!(value["username"], D);
    assert_eq!(value["credentials"]["mode"], "dual");
    assert!(value["credentials"]["published_at"].is_string());
    let passwd = std::fs::read_to_string(dir.path().join("devices.passwd")).unwrap();
    let (user, hash) = passwd.trim().split_once(':').unwrap();
    assert_eq!(user, D);
    assert!(crate::mqtt_auth::verify(&password, hash));
    // Only the hash is stored.
    assert_eq!(
        scalar::<String>(&client, "SELECT password_hash FROM device_mqtt_credentials").await,
        hash
    );
    assert_eq!(
        std::fs::read_to_string(dir.path().join("devices.deny")).unwrap(),
        ""
    );
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/mqtt-credentials/mode"),
        "operator",
        json!({"mode":"device"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/mqtt-credentials/mode"),
        "operator",
        json!({"mode":"device","confirm":"DEVICE"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["mode"], "device");
    assert_eq!(
        std::fs::read_to_string(dir.path().join("devices.deny")).unwrap(),
        format!("{D}\n")
    );
    let (_, device) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(device["device"]["mqtt_auth"], "device");
    // Rotation replaces the hash; the old password stops working.
    let (_, rotated) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/mqtt-credentials"),
        "operator",
        json!({}),
    )
    .await;
    let passwd = std::fs::read_to_string(dir.path().join("devices.passwd")).unwrap();
    let hash = passwd.trim().split_once(':').unwrap().1.to_owned();
    assert!(!crate::mqtt_auth::verify(&password, &hash));
    assert!(crate::mqtt_auth::verify(
        rotated["password"].as_str().unwrap(),
        &hash
    ));
    assert_eq!(rotated["credentials"]["mode"], "device");
    // Retiring removes the account from the broker files.
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/retire"),
        "operator",
        json!({"confirm":"RETIRE"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        std::fs::read_to_string(dir.path().join("devices.passwd")).unwrap(),
        ""
    );
    // A unit without its own gwl/v1 topics cannot get an own account.
    client
        .execute(
            "INSERT INTO devices(device_id,source_profile,clock_policy) VALUES($1,'V21','utc')",
            &[&L],
        )
        .await
        .unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{L}/mqtt-credentials"),
        "operator",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, audit) = call(&app, "GET", "/api/audit?limit=20", "operator", Value::Null).await;
    let actions: Vec<&str> = audit["audit"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["action"].as_str().unwrap())
        .collect();
    assert_eq!(
        actions,
        [
            "retired",
            "mqtt_credentials_rotated",
            "mqtt_mode_changed",
            "mqtt_credentials_generated",
            "enrolled"
        ]
    );
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn datums_convert_series_exports_and_reports() {
    let (url, client) = setup().await;
    let app = app(&url, OpsSettings::default()).await;
    enroll_v22(&app).await;
    let base = Utc::now() - Duration::hours(10);
    for hour in 0..6 {
        client
            .execute(
                "INSERT INTO observations(device_id,kind,payload_digest,recorded_at,received_at,time_quality,
                    time_reason,zone_source,interpretation_version,gwl,gwl_text,battery_v,solar_v,battery_truncated,
                    solar_truncated,duplicate_outcome,duplicate_reason,payload,source,log_id,seq,record_type,sensor_mv,
                    sensor_status,settings_gen,csq,time_source)
                 VALUES($1,'water',$5,$2,now(),'plausible','test','payload','test',$3,$6,7.4,5.1,
                    false,false,'new','test','{}','stream',1,$4,0,1200,0,4,21,'anchor')",
                &[&D, &(base + Duration::hours(hour)), &(10.0 + hour as f64), &(hour + 1),
                    &format!("d{hour}"), &(10.0 + hour as f64).to_string()],
            )
            .await
            .unwrap();
    }
    client
        .execute(
            "UPDATE devices SET min_limit=11.0,max_limit=14.0 WHERE device_id=$1",
            &[&D],
        )
        .await
        .unwrap();
    // The datum takes effect from the third reading.
    let (status, value) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/datums"),
        "operator",
        json!({"effective_from":(base + Duration::hours(2)).to_rfc3339(),"sensor_depth_m":42.0,
            "casing_height_m":0.5,"ground_elevation_m":120.0,"note":"surveyed"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/datums"),
        "operator",
        json!({"effective_from":"not a time","sensor_depth_m":1.0}),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/datums"),
        "operator",
        json!({"effective_from":base.to_rfc3339(),"sensor_depth_m":5000.0}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let range = format!(
        "device={D}&from={}&to={}",
        (base - Duration::hours(1)).to_rfc3339().replace('+', "%2B"),
        Utc::now().to_rfc3339().replace('+', "%2B")
    );
    let (status, value) = call(
        &app,
        "GET",
        &format!("/api/series?{range}&datum=dtw_bgl"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    let series = &value["series"];
    assert_eq!(series["datum"], "dtw_bgl");
    assert_eq!(series["inverted"], true);
    assert_eq!(series["unconverted"], 2);
    let points = series["points"].as_array().unwrap();
    assert_eq!(points.len(), 4);
    // 42.0 − 0.5 − 12.0 = 29.5 m below ground for the 12.0 m reading.
    assert_eq!(points[0]["gwl"], 29.5);
    assert_eq!(points[0]["raw_gwl"], 12.0);
    assert_eq!(points[0]["solar_v"], 5.1);
    assert_eq!(points[0]["csq"], 21.0);
    // Limits 11/14 m of water → 30.5/27.5 m bgl, sorted.
    assert_eq!(series["limits"], json!({"min":27.5,"max":30.5}));
    let (_, value) = call(
        &app,
        "GET",
        &format!("/api/series?{range}&datum=rl_ahd&bucket=120"),
        "viewer",
        Value::Null,
    )
    .await;
    let points = value["series"]["points"].as_array().unwrap();
    assert!(points.iter().all(|p| p["gwl"].as_f64().unwrap() > 80.0));
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/series?{range}&datum=feet"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, csv) = call(
        &app,
        "GET",
        &format!("/api/export?{range}&format=csv"),
        "viewer",
        Value::Null,
    )
    .await;
    let csv = csv["text"].as_str().unwrap();
    let mut lines = csv.lines();
    assert_eq!(lines.next().unwrap(), api::EXPORT_COLUMNS.join(","));
    let first: Vec<&str> = lines.next().unwrap().split(',').collect();
    assert_eq!(first[9], "\"stream\"");
    assert_eq!(first[11], "\"1\"");
    assert_eq!(first[13], "\"1200\"");
    assert_eq!(first[16], "\"21\"");
    assert_eq!(first[18], "\"\"");
    let third: Vec<&str> = csv.lines().nth(3).unwrap().split(',').collect();
    assert_eq!(third[18], "\"29.5000\"");
    assert_eq!(third[19], "\"90.5000\"");

    // Gap report: an open gap counts now, a filled one inside the window.
    client
        .execute(
            "INSERT INTO stream_gaps(device_id,log_id,from_seq,to_seq,state,detected_at) VALUES
                ($1,1,7,9,'open',now()-interval '40 days'),($1,1,20,20,'filled',now()-interval '1 hour'),
                ($1,1,30,33,'unrecoverable',now()-interval '40 days')",
            &[&D],
        )
        .await
        .unwrap();
    let from = (Utc::now() - Duration::days(7))
        .to_rfc3339()
        .replace('+', "%2B");
    let (_, report) = call(
        &app,
        "GET",
        &format!("/api/gaps/report?from={from}"),
        "viewer",
        Value::Null,
    )
    .await;
    let row = &report["devices"][0];
    assert_eq!(row["open"], 1);
    assert_eq!(row["missing_open"], 3);
    assert_eq!(row["filled"], 1);
    assert_eq!(row["unrecoverable"], 0);
    assert_eq!(row["frames"], 0);
    assert_eq!(report["totals"]["missing_open"], 3);
    let (_, report) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/gaps/report?from={from}"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(report["gaps"].as_array().unwrap().len(), 2);
    let (_, other) = call(&app, "GET", "/api/gaps/report", "someone", Value::Null).await;
    assert_eq!(other["devices"], json!([]));

    // JSON exports of events and positions.
    client
        .execute(
            "INSERT INTO device_positions(device_id,source,recorded_at,received_at,fix,lat,lon,alt_m)
             VALUES($1,'json',now(),now(),3,-33.8688,151.2093,12)",
            &[&D],
        )
        .await
        .unwrap();
    let (_, geo) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/positions/export?format=geojson"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(geo["type"], "FeatureCollection");
    assert_eq!(
        geo["features"][0]["geometry"]["coordinates"],
        json!([151.2093, -33.8688, 12.0])
    );
    let (_, events) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/events/export"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(events["device_id"], D);
    assert!(events["events"].is_array());
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/events/export"),
        "someone",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let id: i64 = scalar(&client, "SELECT id FROM device_datums").await;
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/devices/{D}/datums/{id}"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/devices/{D}/datums/{id}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn metrics_need_an_operator_or_the_scraper_token() {
    let (url, _client) = setup().await;
    let token = "scraper-token-0123456789";
    let app = app(
        &url,
        OpsSettings {
            metrics_token: Some(token.into()),
            ..Default::default()
        },
    )
    .await;
    enroll_v22(&app).await;
    let (status, _) = call(&app, "GET", "/metrics", "anonymous", Value::Null).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = call(&app, "GET", "/metrics", "viewer", Value::Null).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, body) = call(&app, "GET", "/metrics", "operator", Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    let text = body["text"].as_str().unwrap();
    assert!(text.contains("groundwater_devices{status=\"never\"} 1\n"));
    assert!(text.contains("# TYPE groundwater_ingest_deliveries_total counter\n"));
    assert!(text.contains("groundwater_commands"));
    let scrape = |auth: &'static str| {
        let app = app.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .uri("/metrics")
                    .header("authorization", auth)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
        }
    };
    assert_eq!(
        scrape("Bearer scraper-token-0123456789").await,
        StatusCode::OK
    );
    assert_eq!(scrape("Bearer wrong").await, StatusCode::UNAUTHORIZED);
}
