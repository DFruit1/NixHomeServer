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

// A namespace mismatch must never reset another physical logger.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn versioned_topics_isolate_device_commands() {
    let mut client = db::connect(&std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap())
        .await
        .unwrap();
    db::migrate(&client).await.unwrap();
    client
        .batch_execute(
            "TRUNCATE devices,device_bindings,observations,deliveries RESTART IDENTITY CASCADE",
        )
        .await
        .unwrap();
    for device in [A, B] {
        client
            .execute(
                "INSERT INTO devices(device_id,source_profile,clock_policy) VALUES($1,'V21','utc')",
                &[&device],
            )
            .await
            .unwrap();
        for channel in ["status", "cmd/danger"] {
            let topic = format!("gwl/v1/{device}/{channel}");
            client.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V21')", &[&topic,&device]).await.unwrap();
        }
        platform::queue(
            &client,
            device,
            "danger",
            json!({"Reboot":"1"}),
            "{\"Reboot\":\"1\"}",
            "operator",
        )
        .await
        .unwrap();
    }
    let registry = Arc::new(tokio::sync::RwLock::new(
        db::load_registry(&client).await.unwrap(),
    ));
    let bus = EventBus::new();
    let stats = Arc::new(tokio::sync::Mutex::new(IngestStats::default()));
    crate::ingest::handle_publish(
        &format!("gwl/v1/{A}/status"),
        b"Ready",
        1,
        false,
        Utc::now(),
        &TopicMap::default(),
        &mut client,
        &registry,
        &bus,
        &stats,
    )
    .await
    .unwrap();
    let (mqtt, _events) = rumqttc::AsyncClient::new(
        rumqttc::MqttOptions::new("topic-safety", "127.0.0.1", 1),
        10,
    );
    let mut publisher = Publisher::default();
    publisher.connected = true;
    scheduler::tick(&mut client, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    let attempts = client
        .query(
            "SELECT device_id,attempts FROM commands ORDER BY device_id",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(
        attempts
            .iter()
            .find(|r| r.get::<_, String>(0) == A)
            .unwrap()
            .get::<_, i32>(1),
        1
    );
    assert_eq!(
        attempts
            .iter()
            .find(|r| r.get::<_, String>(0) == B)
            .unwrap()
            .get::<_, i32>(1),
        0
    );
    assert_eq!(
        client
            .query_one("SELECT topic FROM command_publish_attempts", &[])
            .await
            .unwrap()
            .get::<_, String>(0),
        format!("gwl/v1/{A}/cmd/danger")
    );

    // Profile aliases must not split Rust and SQL cohort decisions.
    client.execute("UPDATE device_bindings SET source_profile='2.1' WHERE device_id=$1 AND topic LIKE '%/status'", &[&A]).await.unwrap();
    // Mixed migration: v1-only A must not suppress the sole legacy unit B.
    client.execute("UPDATE device_bindings SET topic=CASE WHEN topic LIKE '%/status' THEN 'azman1/feeds/device-status' ELSE 'cmd/danger' END WHERE device_id=$1", &[&B]).await.unwrap();
    client
        .execute(
            "UPDATE commands SET state='cancelled' WHERE device_id=$1",
            &[&A],
        )
        .await
        .unwrap();
    let c = "000000000000000000000003";
    client
        .execute(
            "INSERT INTO devices(device_id,source_profile,clock_policy) VALUES($1,'V21','utc')",
            &[&c],
        )
        .await
        .unwrap();
    *registry.write().await = db::load_registry(&client).await.unwrap();
    crate::ingest::handle_publish(
        "azman1/feeds/device-status",
        b"Ready",
        1,
        false,
        Utc::now(),
        &TopicMap::default(),
        &mut client,
        &registry,
        &bus,
        &stats,
    )
    .await
    .unwrap();
    assert!(client
        .query_one(
            "SELECT last_ready_at FROM devices WHERE device_id=$1",
            &[&B]
        )
        .await
        .unwrap()
        .get::<_, Option<chrono::DateTime<Utc>>>(0)
        .is_none());
    client
        .execute(
            "UPDATE devices SET revoked_at=now() WHERE device_id=$1",
            &[&c],
        )
        .await
        .unwrap();
    *registry.write().await = db::load_registry(&client).await.unwrap();
    crate::ingest::handle_publish(
        "azman1/feeds/device-status",
        b"Ready",
        1,
        false,
        Utc::now(),
        &TopicMap::default(),
        &mut client,
        &registry,
        &bus,
        &stats,
    )
    .await
    .unwrap();
    // Invalid profile evidence remains conservative even though the typed
    // registry deliberately skips that binding.
    client.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('invalid-legacy',$1,'legacy/reading','invalid')", &[&A]).await.unwrap();
    let contaminated = db::load_registry(&client).await.unwrap();
    assert!(scheduler::attributed(&contaminated, "azman1/feeds/device-status").is_none());
    assert_eq!(
        client
            .query_one("SELECT groundwater_legacy_device_count()", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        2
    );
    client
        .execute(
            "DELETE FROM device_bindings WHERE binding_key='invalid-legacy'",
            &[],
        )
        .await
        .unwrap();
    *registry.write().await = db::load_registry(&client).await.unwrap();
    publisher.disconnected();
    publisher.reconcile(&mut client, &bus).await.unwrap();
    publisher.connected = true;
    scheduler::tick(&mut client, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        client
            .query_one("SELECT attempts FROM commands WHERE device_id=$1", &[&B])
            .await
            .unwrap()
            .get::<_, i32>(0),
        1
    );
    assert_eq!(client.query_one("SELECT a.topic FROM command_publish_attempts a JOIN commands c ON c.id=a.command_id WHERE c.device_id=$1", &[&B]).await.unwrap().get::<_,String>(0),"cmd/danger");
}

// Clock-changing flash writes and stale wake authorization can issue commands
// against the wrong device state or permanently misinterpret field samples.
// These hardware/data-preservation risks justify focused safety coverage.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn firmware_clock_and_atomic_presence_safety() {
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let mut db = db::connect(&url).await.unwrap();
    db::migrate(&db).await.unwrap();
    db.batch_execute(
        "TRUNCATE devices,device_bindings,observations,deliveries RESTART IDENTITY CASCADE",
    )
    .await
    .unwrap();
    db.execute("INSERT INTO devices(device_id,source_profile,clock_policy,presence_status,last_ready_at) VALUES($1,'V21','utc','awake',now())", &[&A]).await.unwrap();
    for topic in [
        "requesttesta",
        "cfg/desired",
        "cmd/danger",
        "azman1/feeds/device-status",
        "azman1/feeds/project-settings-slash-configuration",
    ] {
        db.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V21')", &[&topic,&A]).await.unwrap();
    }
    assert!(
        !platform::command_supported(&db, A, "cfg", &json!({"Get_Status":"1"}))
            .await
            .unwrap()
    );
    assert!(
        !platform::command_supported(&db, A, "danger", &json!({"Wipe_sd":"1"}))
            .await
            .unwrap()
    );
    assert!(
        platform::command_supported(&db, A, "danger", &json!({"Reboot":"1"}))
            .await
            .unwrap()
    );
    let config = json!({"NA":"3","l":"A1","id":"B1","lf":"0:3","sf":"0:9","fac":"1.00,1.00,0.00,0.00","fst":"2026-10-01T00:00:00","mG":"0","MG":"9","S":"0101","ltost":"5:0"});
    assert!(
        !platform::command_supported(&db, A, "project-settings", &config)
            .await
            .unwrap()
    );
    let old = platform::queue(&db, A, "cfg", json!({"Get_Status":"1"}), "{}", "operator")
        .await
        .unwrap();
    db.execute("UPDATE commands SET state='sent',sent_at=now(),broker_acked_at=now(),last_ready_at=now() WHERE id=$1", &[&old.id]).await.unwrap();
    let offset_change = platform::queue(
        &db,
        A,
        "project-settings",
        config.clone(),
        &crate::commands::project_payload(&config).unwrap(),
        "operator",
    )
    .await
    .unwrap();
    let supported = platform::queue(&db, A, "test", json!({}), "test", "operator")
        .await
        .unwrap();
    let (mqtt, _events) = rumqttc::AsyncClient::new(
        rumqttc::MqttOptions::new("capability-safety", "127.0.0.1", 1),
        10,
    );
    let bus = EventBus::new();
    let mut publisher = Publisher::default();
    publisher.connected = true;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    let commands = platform::commands(&db, &[A.into()], None).await.unwrap();
    assert_eq!(
        commands
            .iter()
            .find(|c| c.id == supported.id)
            .unwrap()
            .attempts,
        1
    );
    for id in [old.id, offset_change.id] {
        let c = commands.iter().find(|c| c.id == id).unwrap();
        assert_eq!(c.attempts, 0);
        assert_eq!(c.supported, Some(false));
    }
    scheduler::invalidate_ready(&db).await.unwrap();
    assert!(db
        .query_one(
            "SELECT last_ready_at FROM devices WHERE device_id=$1",
            &[&A]
        )
        .await
        .unwrap()
        .get::<_, Option<chrono::DateTime<Utc>>>(0)
        .is_none());

    let registry = Arc::new(tokio::sync::RwLock::new(
        db::load_registry(&db).await.unwrap(),
    ));
    let stats = Arc::new(tokio::sync::Mutex::new(IngestStats::default()));
    db.batch_execute("ALTER TABLE deliveries ADD CONSTRAINT fixture_reject_presence CHECK(kind<>'device-status')").await.unwrap();
    let now = Utc::now();
    assert!(crate::ingest::handle_publish(
        "azman1/feeds/device-status",
        b"Ready",
        1,
        false,
        now,
        &TopicMap::default(),
        &mut db,
        &registry,
        &bus,
        &stats
    )
    .await
    .is_err());
    assert!(db
        .query_one(
            "SELECT last_ready_at FROM devices WHERE device_id=$1",
            &[&A]
        )
        .await
        .unwrap()
        .get::<_, Option<chrono::DateTime<Utc>>>(0)
        .is_none());
    db.batch_execute("ALTER TABLE deliveries DROP CONSTRAINT fixture_reject_presence")
        .await
        .unwrap();
    crate::ingest::handle_publish(
        "azman1/feeds/device-status",
        b"Ready",
        1,
        false,
        now,
        &TopicMap::default(),
        &mut db,
        &registry,
        &bus,
        &stats,
    )
    .await
    .unwrap();
    crate::ingest::handle_publish(
        "azman1/feeds/device-status",
        b"Ready",
        1,
        false,
        now,
        &TopicMap::default(),
        &mut db,
        &registry,
        &bus,
        &stats,
    )
    .await
    .unwrap();
    assert_eq!(
        db.query_one("SELECT count(*) FROM deliveries", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        1
    );
    for payload in [b"bad\0text".as_slice(), br#"{"x":"\u0000"}"#] {
        crate::ingest::handle_publish(
            "unknown/topic",
            payload,
            1,
            false,
            Utc::now(),
            &TopicMap::default(),
            &mut db,
            &registry,
            &bus,
            &stats,
        )
        .await
        .unwrap();
    }
    assert_eq!(
        db.query_one(
            "SELECT count(*) FROM deliveries WHERE state='quarantined'",
            &[]
        )
        .await
        .unwrap()
        .get::<_, i64>(0),
        2
    );

    let state = api::AppState {
        settings: Arc::new(crate::config::Settings {
            database_url: url.clone(),
            address: "127.0.0.1".into(),
            port: 0,
            topics: TopicMap::default(),
            mqtt: None,
            retention_days: 90,
        }),
        db: Arc::new(db::Database::new(
            url.clone(),
            db::connect(&url).await.unwrap(),
        )),
        bus,
        stats,
    };
    let app = api::router(state);
    let command_path = format!("/api/devices/{A}/commands");
    for body in [
        json!({"kind":"cfg","payload":{"Get_Status":"1"}}),
        json!({"kind":"danger","payload":"Wipe_sd","confirm":"DANGER"}),
    ] {
        assert_eq!(
            request(
                app.clone(),
                "POST",
                &command_path,
                "operator",
                &body.to_string()
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
    }
    let config_path = format!("/api/devices/{A}/config");
    assert_eq!(
        request(
            app.clone(),
            "POST",
            &config_path,
            "operator",
            &json!({"config":config}).to_string()
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let mut matching = config.clone();
    matching["ltost"] = json!("0:0");
    assert_eq!(
        request(
            app,
            "POST",
            &config_path,
            "operator",
            &json!({"config":matching}).to_string()
        )
        .await
        .0,
        StatusCode::CREATED
    );
    // A historical uncertain offset attempt remains unknown across restart.
    db.execute(
        "UPDATE commands SET attempts=1 WHERE id=$1",
        &[&offset_change.id],
    )
    .await
    .unwrap();
    db::migrate(&db).await.unwrap();
    assert_eq!(
        db::load_registry(&db)
            .await
            .unwrap()
            .enrollment(A)
            .unwrap()
            .clock,
        ClockPolicy::Unknown
    );
}

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
    db: &mut tokio_postgres::Client,
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
    sample(&mut db, &registry, old + Duration::minutes(3), 11.).await;
    platform::refresh_alerts(&db).await.unwrap();
    sample(&mut db, &registry, old + Duration::minutes(9), 9.5).await;
    sample(&mut db, &registry, old, -1.).await;
    sample(&mut db, &registry, old + Duration::minutes(6), 9.75).await;
    // A reset clock stays stored but never opens an alert.
    sample(
        &mut db,
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
    crate::fixtures::implemented_handlers_for_protocol_fixture(&db).await;
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
        &mut db,
        &shared,
        &bus,
        &Arc::new(tokio::sync::Mutex::new(IngestStats::default())),
    )
    .await
    .unwrap();
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
    // Restore the production capability contract before exercising HTTP.
    db::migrate(&db).await.unwrap();
    // API ACLs, framework extraction errors, unknown routes and role gates.
    let state = api::AppState {
        settings: Arc::new(crate::config::Settings {
            database_url: url.clone(),
            address: "127.0.0.1".into(),
            port: 0,
            topics: TopicMap::default(),
            mqtt: None,
            retention_days: 90,
        }),
        db: Arc::new(db::Database::new(url.clone(), db)),
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
        .get()
        .await
        .unwrap()
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
    let config = json!({"NA":"3","l":"A1","id":"B1","lf":"0:3","sf":"0:9","fac":"1.00,1.00,0.00,0.00","fst":"2026-10-01T00:00:00","mG":"0","MG":"9","S":"0101","ltost":"0:0"});
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
            "SELECT project_config,min_limit FROM devices WHERE device_id=$1",
            &[&A],
        )
        .await
        .unwrap();
    assert!(row.get::<_, Option<Value>>(0).is_none());
    assert!(row.get::<_, Option<f64>>(1).is_none());
}
