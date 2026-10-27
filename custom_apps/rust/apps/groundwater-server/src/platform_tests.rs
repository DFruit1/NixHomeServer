//! Real PostgreSQL regression coverage. The caller supplies a disposable DB;
//! no service, broker or data outside it is contacted.
use crate::{
    adapter, api,
    clock::ClockPolicy,
    db,
    ingest::{EventBus, IngestStats, LiveEvent},
    platform,
    profiles::ProfileId,
    publisher::Publisher,
    scheduler,
    topics::TopicMap,
};
use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use chrono::{Duration, Timelike, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;
const A: &str = "8F3A21C04B9E77A1D25C01FE";
const B: &str = "000000000000000000000002";

async fn request(
    app: axum::Router,
    method: &str,
    path: &str,
    role: &str,
    body: &str,
) -> (StatusCode, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if role != "anonymous" {
        req = req
            .header("x-auth-request-preferred-username", role)
            .header(
                "x-auth-request-groups",
                if role == "operator" {
                    "app-admin"
                } else {
                    "groundwater-user"
                },
            );
    }
    let response = app
        .oneshot(req.body(Body::from(body.to_owned())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}
async fn sample(
    db: &tokio_postgres::Client,
    registry: &adapter::EnrollmentRegistry,
    time: chrono::DateTime<Utc>,
    value: f64,
) {
    let payload=json!({"DeviceID":A,"TIME":time.to_rfc3339(),"GWL":format!("{value:.2}"),"RSSI":"50","BL":"3.1","SOL":"3"}).to_string();
    let delivery = adapter::Delivery {
        topic: "bore/a/gwl-string",
        payload: payload.as_bytes(),
        qos: 1,
        received_at: Utc::now(),
    };
    let intake = adapter::intake(&delivery, registry, &TopicMap::default());
    assert!(matches!(
        intake.outcome,
        adapter::IntakeOutcome::Accepted { .. }
    ));
    db::record_intake(db, &intake).await.unwrap();
}
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn platform_database_api_and_scheduler_regressions() {
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let mut db = db::connect(&url).await.unwrap();
    db::migrate(&db).await.unwrap();
    db.batch_execute("TRUNCATE devices,device_bindings,observations,deliveries,alerts,commands,command_events,device_permissions RESTART IDENTITY CASCADE").await.unwrap();
    db.execute("INSERT INTO devices(device_id,source_profile,clock_policy,min_limit,max_limit) VALUES($1,'V21','utc',0,10),($2,'V21','unknown',NULL,NULL)",&[&A,&B]).await.unwrap();
    db.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('data',$1,'bore/a/gwl-string','V21'),('ready',$1,'bore/a/device-status','V21'),('ack',$1,'bore/a/cfg/desired/applied','V21'),('out',$1,'cfg/desired','V21')",&[&A]).await.unwrap();
    db.execute(
        "INSERT INTO device_permissions(device_id,username) VALUES($1,'viewer')",
        &[&A],
    )
    .await
    .unwrap();
    assert!(platform::allowed(&db, "viewer", A, false).await.unwrap());
    assert!(!platform::allowed(&db, "viewer", B, false).await.unwrap());
    assert!(platform::allowed(&db, "operator", B, true).await.unwrap());
    let registry = db::load_registry(&db).await.unwrap();
    let now = Utc::now().with_nanosecond(0).unwrap();
    let old = now - Duration::days(5);
    // Arrival order is high, normal, low, boundary: event time is low ->
    // high -> hold-high -> normal, producing exactly two resolved episodes.
    sample(&db, &registry, old + Duration::minutes(3), 11.).await;
    platform::refresh_alerts(&db).await.unwrap();
    sample(&db, &registry, old + Duration::minutes(9), 9.5).await;
    sample(&db, &registry, old, -1.).await;
    sample(&db, &registry, old + Duration::minutes(6), 9.75).await;
    // A reset clock stays stored but never opens an alert.
    sample(
        &db,
        &registry,
        "2000-01-01T00:00:00Z".parse().unwrap(),
        999.,
    )
    .await;
    platform::refresh_alerts(&db).await.unwrap();
    let alerts = platform::alerts(&db, &[A.to_owned()], None, None)
        .await
        .unwrap();
    assert_eq!(alerts.len(), 2);
    assert!(alerts.iter().all(|a| a["state"] == "resolved"));
    assert!(
        alerts
            .iter()
            .any(|a| a["kind"] == "above_max"
                && a["resolved_at"] == json!(old + Duration::minutes(9)))
    );
    let count: i64 = db
        .query_one("SELECT count(*) FROM observations", &[])
        .await
        .unwrap()
        .get(0);
    db::migrate(&db).await.unwrap();
    assert_eq!(
        db.query_one("SELECT count(*) FROM observations", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        count
    );
    let bus = EventBus::new();
    let flags = json!({"Get_Status":"1"});
    let (_, wire) = crate::commands::command_payload("cfg", &flags, None).unwrap();
    let first = platform::queue(&db, A, "cfg", flags.clone(), &wire, "operator")
        .await
        .unwrap();
    let mut publisher = Publisher::default();
    publisher.connected = true;
    let (mqtt, _event_loop) =
        rumqttc::AsyncClient::new(rumqttc::MqttOptions::new("unit-test", "127.0.0.1", 1), 1);
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/device-status",
        b"Ready",
        &TopicMap::default(),
        now,
        &bus,
    )
    .await
    .unwrap();
    // A generic outbound binding cannot make a flat topic address a fleet.
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        0
    );
    db.execute(
        "UPDATE devices SET revoked_at=now() WHERE device_id=$1",
        &[&B],
    )
    .await
    .unwrap();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    let sent = platform::commands(&db, &[A.into()], None)
        .await
        .unwrap()
        .remove(0);
    assert_eq!(sent.state, "queued");
    assert!(sent.broker_acked_at.is_none());
    assert_eq!(sent.attempts, 1);
    publisher.outgoing(&mut db, 7, &bus).await.unwrap();
    publisher.puback(&mut db, 7, &bus).await.unwrap();
    // Same Ready never retries, even after the spacing period elapses.
    db.execute(
        "UPDATE devices SET last_downlink_at=now()-interval '10 seconds' WHERE device_id=$1",
        &[&A],
    )
    .await
    .unwrap();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        1
    );
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/cfg/desired/applied",
        br#"{"Get_Status":"0"}"#,
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].state,
        "sent"
    );
    scheduler::ancillary(
        &db,
        &registry,
        "unbound/cfg/desired/applied",
        wire.as_bytes(),
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].state,
        "sent"
    );
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/cfg/desired/applied",
        wire.as_bytes(),
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].state,
        "acked"
    );
    assert!(platform::cancel(&db, A, first.id, "operator")
        .await
        .unwrap()
        .is_none());
    // Cancellation persists and leaves an actor-attributed audit entry.
    let cancel = platform::queue(&db, A, "test", json!({}), "test", "operator")
        .await
        .unwrap();
    assert_eq!(
        platform::cancel(&db, A, cancel.id, "operator")
            .await
            .unwrap()
            .unwrap()
            .state,
        "cancelled"
    );
    assert!(db.query_one("SELECT count(*) FROM command_events WHERE command_id=$1 AND event='cancelled' AND actor='operator'",&[&cancel.id]).await.unwrap().get::<_,i64>(0)>0);
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/device-status",
        b"sleep",
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    let second = platform::queue(&db, A, "cfg", flags.clone(), &wire, "operator")
        .await
        .unwrap();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].state,
        "queued"
    );
    // Spacing survives Ready transitions and process restarts. A fresh
    // request channel simulates a restarted publisher without a broker.
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/device-status",
        b"Ready",
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    db.execute(
        "UPDATE devices SET last_downlink_at=now() WHERE device_id=$1",
        &[&A],
    )
    .await
    .unwrap();
    let (fresh_mqtt, _fresh_loop) =
        rumqttc::AsyncClient::new(rumqttc::MqttOptions::new("restarted", "127.0.0.1", 1), 1);
    scheduler::tick(&mut db, &fresh_mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        0
    );
    db.execute(
        "UPDATE devices SET last_downlink_at=now()-interval '6 seconds' WHERE device_id=$1",
        &[&A],
    )
    .await
    .unwrap();
    scheduler::tick(&mut db, &fresh_mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        1
    );
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/device-status",
        b"Ready",
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    db.execute(
        "UPDATE devices SET last_downlink_at=now()-interval '6 seconds' WHERE device_id=$1",
        &[&A],
    )
    .await
    .unwrap();
    crate::publisher::recover(&db).await.unwrap();
    publisher = Publisher::default();
    publisher.connected = true;
    // The bounded MQTT queue is full. A failed handoff is audited and stays
    // queued. It must return without waiting for an event-loop poll.
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        scheduler::tick(&mut db, &fresh_mqtt, &bus, &mut publisher),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        2
    );
    let (retry_mqtt, _retry_loop) =
        rumqttc::AsyncClient::new(rumqttc::MqttOptions::new("retry", "127.0.0.1", 1), 1);
    db.execute(
        "UPDATE devices SET last_downlink_at=now()-interval '6 seconds' WHERE device_id=$1",
        &[&A],
    )
    .await
    .unwrap();
    scheduler::tick(&mut db, &retry_mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        platform::commands(&db, &[A.into()], None).await.unwrap()[0].attempts,
        3
    );
    // Retained Ready is evidence in the raw log, never an awake transition.
    scheduler::ancillary(
        &db,
        &registry,
        "bore/a/device-status",
        b"sleep",
        &TopicMap::default(),
        Utc::now(),
        &bus,
    )
    .await
    .unwrap();
    let shared = Arc::new(tokio::sync::RwLock::new(registry.clone()));
    crate::ingest::handle_publish(
        "bore/a/device-status",
        b"Ready",
        1,
        true,
        Utc::now(),
        &TopicMap::default(),
        &db,
        &shared,
        &bus,
        &Arc::new(tokio::sync::Mutex::new(IngestStats::default())),
    )
    .await;
    assert_eq!(
        db.query_one(
            "SELECT presence_status FROM devices WHERE device_id=$1",
            &[&A]
        )
        .await
        .unwrap()
        .get::<_, String>(0),
        "asleep"
    );
    // Registry trust rules for flat presence, revoked enrollments and profiles.
    let mut trust = adapter::EnrollmentRegistry::new();
    trust.enroll(adapter::Enrollment::new(
        A,
        "A",
        ProfileId::V21,
        ClockPolicy::Utc,
    ));
    trust.enroll(adapter::Enrollment::new(
        B,
        "B",
        ProfileId::V21,
        ClockPolicy::Utc,
    ));
    trust.bind(adapter::Binding::new(
        "flat",
        "azman1/feeds/device-status",
        A,
        ProfileId::V21,
    ));
    assert!(scheduler::attributed(&trust, "azman1/feeds/device-status").is_none());
    // API ACLs, framework extraction errors, unknown routes and role gates.
    let state = api::AppState {
        settings: Arc::new(crate::config::Settings {
            database_url: url,
            address: "127.0.0.1".into(),
            port: 0,
            topics: TopicMap::default(),
            mqtt: None,
            retention_days: 90,
        }),
        db: Arc::new(db),
        bus: bus.clone(),
        stats: Arc::new(tokio::sync::Mutex::new(IngestStats::default())),
    };
    let app = api::router(state.clone());
    let (status, body) = request(app.clone(), "GET", "/api/status", "viewer", "").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["user"], json!({"username":"viewer","role":"viewer"}));
    for path in [
        format!("/api/devices/{B}"),
        format!("/api/series?device={B}"),
        format!("/api/alerts?device={B}"),
        format!("/api/commands?device={B}"),
        format!("/api/export?device={B}"),
    ] {
        assert_eq!(
            request(app.clone(), "GET", &path, "viewer", "").await.0,
            StatusCode::NOT_FOUND
        );
    }
    assert_eq!(
        request(app.clone(), "GET", "/api/devices", "unassigned", "")
            .await
            .1["devices"],
        json!([])
    );
    assert_eq!(
        request(app.clone(), "GET", "/api/devices", "anonymous", "")
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    for (method, path, body, expected) in [
        ("GET", "/api/series?bucket=invalid", "", 400),
        ("GET", "/api/missing", "", 404),
        ("POST", "/api/devices", "{}", 405),
        ("POST", "/api/devices/A/commands", "{", 400),
    ] {
        let (status, value) = request(app.clone(), method, path, "operator", body).await;
        assert_eq!(status.as_u16(), expected);
        assert!(value["error"].is_string());
    }
    assert_eq!(
        request(
            app.clone(),
            "POST",
            "/api/devices/A/commands",
            "viewer",
            "{"
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (_, logs) = request(
        app.clone(),
        "GET",
        "/api/messages?topic=bore%2Fa%2Fgwl-string",
        "operator",
        "",
    )
    .await;
    assert!(logs["deliveries"]
        .as_array()
        .unwrap()
        .iter()
        .all(|d| d["topic"] == "bore/a/gwl-string"));
    assert_eq!(
        request(app.clone(), "GET", "/api/messages", "viewer", "")
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    // Viewer SSE receives a reconnect resync and only its authorized devices;
    // ACL revocation takes effect without waiting for a new connection.
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/events")
                .header("x-auth-request-user", "viewer")
                .header("x-auth-request-groups", "groundwater-user")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let mut stream = response.into_body().into_data_stream();
    use futures_util::StreamExt;
    assert!(
        String::from_utf8(stream.next().await.unwrap().unwrap().to_vec())
            .unwrap()
            .contains("event: resync")
    );
    bus.emit(LiveEvent::Observation {
        device_id: B.into(),
        recorded_at: Some(now),
        gwl: 99.,
    });
    bus.emit(LiveEvent::Quarantine {
        topic: "secret".into(),
        reason: "invalid".into(),
    });
    bus.emit(LiveEvent::Observation {
        device_id: A.into(),
        recorded_at: Some(now),
        gwl: 1.,
    });
    let data = loop {
        let bytes = tokio::time::timeout(std::time::Duration::from_secs(2), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let text = String::from_utf8(bytes.to_vec()).unwrap();
        if text.starts_with("data:") {
            break text;
        }
    };
    assert!(data.contains(A));
    assert!(!data.contains(B));
    assert!(!data.contains("secret"));
    state
        .db
        .execute("DELETE FROM device_permissions WHERE device_id=$1", &[&A])
        .await
        .unwrap();
    bus.emit(LiveEvent::Command {
        device_id: A.into(),
    });
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(100), stream.next())
            .await
            .is_err()
    );
    assert_eq!(second.state, "queued");
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn publish_enqueue_does_not_claim_broker_acceptance() {
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let mut db = db::connect(&url).await.unwrap();
    db::migrate(&db).await.unwrap();
    db.batch_execute("TRUNCATE devices,device_bindings,observations,deliveries,alerts,commands,command_events,device_permissions RESTART IDENTITY CASCADE").await.unwrap();
    db.execute("INSERT INTO devices(device_id,source_profile,clock_policy,presence_status,last_ready_at) VALUES($1,'V21','utc','awake',now())",&[&A]).await.unwrap();
    db.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('settings',$1,'azman1/feeds/project-settings-slash-configuration','V21')",&[&A]).await.unwrap();
    let config = json!({"NA":"3","l":"A1","id":"B1","lf":"0:3","sf":"0:9","fac":"1.00,1.00,0.00,0.00","fst":"2026-10-01T00:00:00","mG":"0","MG":"9","S":"0101","ltost":"5:0"});
    let wire = crate::commands::project_payload(&config).unwrap();
    platform::queue(&db, A, "project-settings", config, &wire, "operator")
        .await
        .unwrap();
    let (mqtt, _event_loop) =
        rumqttc::AsyncClient::new(rumqttc::MqttOptions::new("unpolled", "127.0.0.1", 1), 1);
    let mut publisher = Publisher::default();
    publisher.connected = true;
    scheduler::tick(&mut db, &mqtt, &EventBus::new(), &mut publisher)
        .await
        .unwrap();
    let commands = platform::commands(&db, &[A.into()], None).await.unwrap();
    assert_eq!(
        commands[0].state, "queued",
        "in-memory enqueue is not a broker acknowledgment"
    );
    let row = db
        .query_one(
            "SELECT desired_config,min_limit FROM devices WHERE device_id=$1",
            &[&A],
        )
        .await
        .unwrap();
    assert!(row.get::<_, Option<Value>>(0).is_none());
    assert!(row.get::<_, Option<f64>>(1).is_none());
}
