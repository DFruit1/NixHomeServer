//! Disposable-DB regression tests for the broker/firmware acknowledgment split.
use crate::{
    db,
    ingest::EventBus,
    platform,
    publisher::{self, Publisher},
    scheduler,
    topics::TopicMap,
};
use rumqttc::{AsyncClient, Event, EventLoop, Incoming, MqttOptions, Outgoing};
use serde_json::{json, Value};
use tokio_postgres::Client;
const DEVICE: &str = "8F3A21C04B9E77A1D25C01FE";
fn transport() -> (AsyncClient, EventLoop) {
    AsyncClient::new(MqttOptions::new("publish-regression", "127.0.0.1", 1), 10)
}
fn tracker() -> Publisher {
    let mut publisher = Publisher::default();
    publisher.connected = true;
    publisher
}
fn config() -> Value {
    json!({"NA":"3","l":"A1","id":"B1","lf":"0:3","sf":"0:9","fac":"1.00,1.00,0.00,0.00","fst":"2026-10-01T00:00:00","mG":"0","MG":"9","S":"0101","ltost":"5:0"})
}
async fn setup() -> Client {
    let db = db::connect(&std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap())
        .await
        .unwrap();
    db::migrate(&db).await.unwrap();
    db.batch_execute("TRUNCATE devices,device_bindings,observations,deliveries,alerts,commands,command_events,device_permissions RESTART IDENTITY CASCADE").await.unwrap();
    db.execute("INSERT INTO devices(device_id,source_profile,clock_policy,presence_status,last_ready_at) VALUES($1,'V21','utc','awake',now())",&[&DEVICE]).await.unwrap();
    for topic in [
        "azman1/feeds/project-settings-slash-configuration",
        "cmd/danger",
        "cfg/desired",
        "requesttesta",
        "cfg/desired/applied",
        "cfg/danger_ack",
        "azman1/feeds/device-status",
        "azman1/feeds/testresults",
    ] {
        db.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V21')",&[&topic,&DEVICE]).await.unwrap();
    }
    db
}
async fn queued(db: &Client, kind: &str, payload: Value) -> platform::Command {
    let (payload, wire) = if kind == "project-settings" {
        let wire = crate::commands::project_payload(&payload).unwrap();
        (payload, wire)
    } else {
        crate::commands::command_payload(kind, &payload, Some("DANGER")).unwrap()
    };
    platform::queue(db, DEVICE, kind, payload, &wire, "operator")
        .await
        .unwrap()
}
async fn command(db: &Client, id: i64) -> platform::Command {
    platform::commands(db, &[DEVICE.into()], None)
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.id == id)
        .unwrap()
}
async fn elapsed(db: &Client) {
    db.execute(
        "UPDATE devices SET last_downlink_at=now()-interval '6 seconds' WHERE device_id=$1",
        &[&DEVICE],
    )
    .await
    .unwrap();
}
async fn ready(db: &Client) {
    db.execute(
        "UPDATE devices SET presence_status='awake',last_ready_at=now() WHERE device_id=$1",
        &[&DEVICE],
    )
    .await
    .unwrap();
}
async fn ack(db: &Client, topic: &str, payload: &str) {
    let registry = db::load_registry(db).await.unwrap();
    scheduler::ancillary(
        db,
        &registry,
        topic,
        payload.as_bytes(),
        &TopicMap::default(),
        chrono::Utc::now(),
        &EventBus::new(),
    )
    .await
    .unwrap();
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn durable_attempts_recover_and_reboot_is_terminal_only_after_puback() {
    let mut db = setup().await;
    let bus = EventBus::new();
    let settings = queued(&db, "project-settings", config()).await;
    let reboot = queued(&db, "danger", json!({"Factory reset":"1","Reboot":"1"})).await;
    let test = queued(&db, "test", json!({})).await;
    let no_reboot = queued(&db, "danger", json!({"Wipe_sd":"1","Reboot":"0"})).await;
    assert!(!settings.firmware_ack_expected);
    assert!(!reboot.firmware_ack_expected);
    assert!(no_reboot.firmware_ack_expected);
    let single = queued(&db, "danger", json!("Reboot")).await;
    assert!(!single.firmware_ack_expected);
    platform::cancel(&db, DEVICE, single.id, "operator")
        .await
        .unwrap();
    let (mqtt, event_loop) = transport();
    let mut publisher = tracker();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(command(&db, settings.id).await.state, "queued");
    assert!(command(&db, settings.id).await.broker_acked_at.is_none());
    assert!(db
        .query_one(
            "SELECT desired_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .is_none());
    assert!(
        platform::cancel(&db, DEVICE, settings.id, "operator")
            .await
            .unwrap()
            .is_none(),
        "pending handoff cannot be withdrawn from rumqttc"
    );
    // Crash before poll: discard all process-local state, recover SQL intent.
    drop(publisher);
    drop(mqtt);
    drop(event_loop);
    publisher::recover(&db).await.unwrap();
    let (mqtt, mut event_loop) = transport();
    let mut publisher = tracker();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        command(&db, settings.id).await.attempts,
        1,
        "restart preserves pacing"
    );
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(command(&db, settings.id).await.attempts, 2);
    publisher.outgoing(&mut db, 41, &bus).await.unwrap();
    publisher.puback(&mut db, 99, &bus).await.unwrap();
    assert_eq!(
        command(&db, settings.id).await.state,
        "queued",
        "wrong packet id cannot confirm"
    );
    // A clean-session loss after dispatch still leaves the command durable.
    publisher.disconnected();
    publisher::discard_session(&mut event_loop);
    publisher.reconcile(&mut db, &bus).await.unwrap();
    assert!(!publisher.busy());
    assert_eq!(command(&db, settings.id).await.state, "queued");
    publisher.connected = true;
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    publisher.outgoing(&mut db, 42, &bus).await.unwrap();
    assert!(db
        .query_one(
            "SELECT desired_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .is_none());
    // Once received, PUBACK stays pending in the tracker until the SQL commit
    // succeeds. Exercise a deterministic database rejection, then recovery.
    db.batch_execute(
        "ALTER TABLE commands ADD CONSTRAINT fixture_reject_confirm CHECK(broker_acked_at IS NULL)",
    )
    .await
    .unwrap();
    assert!(publisher.puback(&mut db, 42, &bus).await.is_err());
    assert!(publisher.busy());
    assert_eq!(command(&db, settings.id).await.state, "queued");
    db.batch_execute("ALTER TABLE commands DROP CONSTRAINT fixture_reject_confirm")
        .await
        .unwrap();
    publisher.reconcile(&mut db, &bus).await.unwrap();
    let sent = command(&db, settings.id).await;
    assert_eq!(sent.state, "sent");
    assert!(sent.broker_acked_at.is_some());
    assert!(sent.acked_at.is_none());
    assert!(sent.ack_payload.is_none());
    let row=db.query_one("SELECT desired_config,min_limit,max_limit,applied_config FROM devices WHERE device_id=$1",&[&DEVICE]).await.unwrap();
    assert_eq!(row.get::<_, Value>(0), config());
    assert_eq!(row.get::<_, f64>(1), 0.);
    assert_eq!(row.get::<_, f64>(2), 9.);
    assert!(row.get::<_, Option<Value>>(3).is_none());
    // A terminal config does not block the following reboot. PUBACK alone
    // confirms its single send; neither an early nor late danger ACK can
    // manufacture a firmware acknowledgment for this command.
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        command(&db, reboot.id).await.attempts,
        0,
        "PUBACK preserves the five-second boundary"
    );
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    publisher.outgoing(&mut db, 43, &bus).await.unwrap();
    ack(&db, "cfg/danger_ack", "Danger Acknowledge").await;
    publisher.puback(&mut db, 43, &bus).await.unwrap();
    ack(&db, "cfg/danger_ack", "Danger Acknowledge").await;
    let sent = command(&db, reboot.id).await;
    assert_eq!(sent.state, "sent");
    assert!(sent.broker_acked_at.is_some());
    assert!(sent.acked_at.is_none());
    ready(&db).await;
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(command(&db, reboot.id).await.attempts, 1);
    assert_eq!(
        command(&db, test.id).await.attempts,
        1,
        "Reboot no longer blocks the queue"
    );
    // Test results can race the broker PUBACK. Buffer the firmware evidence
    // and apply it only when broker acceptance is independently confirmed.
    publisher.outgoing(&mut db, 44, &bus).await.unwrap();
    ack(&db, "azman1/feeds/testresults", "~ sensor OK").await;
    assert_eq!(command(&db, test.id).await.state, "queued");
    publisher.puback(&mut db, 44, &bus).await.unwrap();
    assert_eq!(command(&db, test.id).await.state, "acked");
    ack(&db, "azman1/feeds/testresults", "~ storage OK").await;
    assert_eq!(
        command(&db, test.id)
            .await
            .ack_payload
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    publisher.outgoing(&mut db, 45, &bus).await.unwrap();
    publisher.puback(&mut db, 45, &bus).await.unwrap();
    assert_eq!(command(&db, no_reboot.id).await.state, "sent");
    ready(&db).await;
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        command(&db, no_reboot.id).await.attempts,
        2,
        "Reboot=0 must retain normal danger retry behavior"
    );
    publisher.outgoing(&mut db, 46, &bus).await.unwrap();
    ack(&db, "cfg/danger_ack", "Danger Acknowledge").await;
    publisher.puback(&mut db, 46, &bus).await.unwrap();
    assert_eq!(command(&db, no_reboot.id).await.state, "acked");
    let cfg = queued(&db, "cfg", json!({"Get_Status":"1"})).await;
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    publisher.outgoing(&mut db, 47, &bus).await.unwrap();
    ack(&db, "cfg/desired/applied", r#"{"Get_Status":"0"}"#).await;
    ack(&db, "cfg/desired/applied", r#"{"Get_Status":"1"}"#).await;
    assert_eq!(command(&db, cfg.id).await.state, "queued");
    assert!(db
        .query_one(
            "SELECT applied_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .is_none());
    publisher.puback(&mut db, 47, &bus).await.unwrap();
    assert_eq!(command(&db, cfg.id).await.state, "acked");
    assert_eq!(
        db.query_one(
            "SELECT applied_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Value>(0),
        json!({"Get_Status":"1"})
    );
    assert_eq!(command(&db, reboot.id).await.attempts, 1);
}

struct Broker {
    child: std::process::Child,
    _scratch: tempfile::TempDir,
    port: u16,
}
impl Drop for Broker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn broker() -> Broker {
    let executable = std::env::var("GROUNDWATER_TEST_MOSQUITTO").unwrap_or_else(|_| {
        "/nix/store/k4r88y4x9081gx5kv1cgcqpyhmn8xih1-mosquitto-2.1.2/bin/mosquitto".into()
    });
    let scratch = tempfile::Builder::new()
        .prefix("groundwater-puback-")
        .tempdir()
        .unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let config = scratch.path().join("mosquitto.conf");
    std::fs::write(
        &config,
        format!("listener {port} 127.0.0.1\nallow_anonymous true\npersistence false\n"),
    )
    .unwrap();
    let log = std::fs::File::create(scratch.path().join("mosquitto.log")).unwrap();
    let child = std::process::Command::new(executable)
        .arg("-c")
        .arg(config)
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap();
    Broker {
        child,
        _scratch: scratch,
        port,
    }
}
async fn next_event(event_loop: &mut EventLoop) -> Event {
    tokio::time::timeout(std::time::Duration::from_secs(5), event_loop.poll())
        .await
        .unwrap()
        .unwrap()
}
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL and local Mosquitto binary"]
async fn real_mqtt_puback_correlates_after_crash_before_dispatch() {
    let mut db = setup().await;
    let bus = EventBus::new();
    let broker = broker();
    let command = queued(&db, "project-settings", config()).await;
    // A process can die immediately after a successful try_publish. Nothing
    // has left this unpolled client's channel; SQL must remain recoverable.
    {
        let (mqtt, _unpolled) = transport();
        let mut pending = tracker();
        scheduler::tick(&mut db, &mqtt, &bus, &mut pending)
            .await
            .unwrap();
    }
    publisher::recover(&db).await.unwrap();
    elapsed(&db).await;
    let (mqtt, mut event_loop) = AsyncClient::new(
        MqttOptions::new("groundwater-local-puback", "127.0.0.1", broker.port),
        10,
    );
    let mut publisher = tracker();
    // The broker process may still be starting. Failed connects are bounded
    // by this loop; every error clears stale transport events before retry.
    let mut connected = false;
    for _ in 0..30 {
        match tokio::time::timeout(std::time::Duration::from_secs(1), event_loop.poll()).await {
            Ok(Ok(Event::Incoming(Incoming::ConnAck(_)))) => {
                connected = true;
                break;
            }
            _ => {
                publisher::discard_session(&mut event_loop);
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        }
    }
    assert!(connected);
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    let packet = loop {
        if let Event::Outgoing(Outgoing::Publish(id)) = next_event(&mut event_loop).await {
            publisher.outgoing(&mut db, id, &bus).await.unwrap();
            break id;
        }
    };
    assert_eq!(self::command(&db, command.id).await.state, "queued");
    assert!(db
        .query_one(
            "SELECT desired_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .is_none());
    loop {
        if let Event::Incoming(Incoming::PubAck(ack)) = next_event(&mut event_loop).await {
            assert_eq!(ack.pkid, packet);
            publisher.puback(&mut db, ack.pkid, &bus).await.unwrap();
            break;
        }
    }
    let sent = self::command(&db, command.id).await;
    assert_eq!(sent.state, "sent");
    assert!(sent.broker_acked_at.is_some());
    assert!(sent.acked_at.is_none());
    assert_eq!(sent.attempts, 2);
    assert_eq!(
        db.query_one(
            "SELECT desired_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Value>(0),
        config()
    );
    ready(&db).await;
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert!(!publisher.busy());
    assert_eq!(
        self::command(&db, command.id).await.attempts,
        2,
        "broker-accepted settings never repeat"
    );
}

/// Reproduce the durable side of COMMIT succeeding but its response being
/// lost before enqueue. The publisher owner consequently has no Pending ID.
async fn reserve_without_tracker(db: &mut Client, command_id: i64, state: &str) -> i64 {
    let tx = db.transaction().await.unwrap();
    let attempt = tx
        .query_one(
            "INSERT INTO command_publish_attempts(command_id,ready_at,topic,state,dispatched_at)
         SELECT $1,last_ready_at,'requesttesta',$2::text,
                CASE WHEN $2::text='inflight' THEN now() ELSE NULL END
         FROM devices WHERE device_id=$3 RETURNING id",
            &[&command_id, &state, &DEVICE],
        )
        .await
        .unwrap()
        .get::<_, i64>(0);
    tx.execute(
        "UPDATE commands SET active_publish_attempt=$2,attempts=attempts+1 WHERE id=$1",
        &[&command_id, &attempt],
    )
    .await
    .unwrap();
    tx.execute(
        "UPDATE devices SET last_downlink_at=now() WHERE device_id=$1",
        &[&DEVICE],
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    attempt
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn owner_reconcile_recovers_untracked_reservations_after_database_reconnect() {
    let mut db = setup().await;
    let prepared = queued(&db, "test", json!({})).await;
    let inflight = queued(&db, "test", json!({})).await;
    let prepared_attempt = reserve_without_tracker(&mut db, prepared.id, "prepared").await;
    let inflight_attempt = reserve_without_tracker(&mut db, inflight.id, "inflight").await;
    assert!(platform::cancel(&db, DEVICE, prepared.id, "operator")
        .await
        .unwrap()
        .is_none());
    drop(db);
    let mut db = db::connect(&std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap())
        .await
        .unwrap();
    // Exercise the normal owner tick after replacing only its DB client;
    // there is no restart-time call to recover(). Even an offline broker
    // must not prevent clearing a stranded reservation for cancellation.
    let mut publisher = Publisher::default();
    let (mqtt, _event_loop) = transport();
    let bus = EventBus::new();
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    let rows=db.query("SELECT state,recovery_reason FROM command_publish_attempts WHERE id=ANY($1) ORDER BY id", &[&vec![prepared_attempt,inflight_attempt]]).await.unwrap();
    assert!(
        rows.iter().all(|r| r.get::<_, String>(0) == "abandoned"),
        "untracked reservations remain stranded after reconnect"
    );
    assert!(rows.iter().all(|r| r.get::<_, Option<String>>(1).is_some()));
    assert_eq!(
        platform::cancel(&db, DEVICE, prepared.id, "operator")
            .await
            .unwrap()
            .unwrap()
            .state,
        "cancelled"
    );
    assert_eq!(command(&db, inflight.id).await.state, "queued");
    publisher.connected = true;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert_eq!(
        command(&db, inflight.id).await.attempts,
        1,
        "reconciliation preserves the pacing boundary"
    );
    elapsed(&db).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    assert!(publisher.busy());
    assert_eq!(
        command(&db, inflight.id).await.attempts,
        2,
        "recovered intent is retryable without a process restart"
    );
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn owner_reconcile_preserves_tracked_inflight_and_puback_across_database_loss() {
    let mut db = setup().await;
    let bus = EventBus::new();
    let (mqtt, _event_loop) = transport();
    let mut publisher = tracker();
    let settings = queued(&db, "project-settings", config()).await;
    scheduler::tick(&mut db, &mqtt, &bus, &mut publisher)
        .await
        .unwrap();
    publisher.outgoing(&mut db, 77, &bus).await.unwrap();
    let attempt = db
        .query_one(
            "SELECT active_publish_attempt FROM commands WHERE id=$1",
            &[&settings.id],
        )
        .await
        .unwrap()
        .get::<_, i64>(0);
    drop(db);
    let mut db = db::connect(&std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap())
        .await
        .unwrap();
    publisher.reconcile(&mut db, &bus).await.unwrap();
    assert!(publisher.busy());
    assert_eq!(
        db.query_one(
            "SELECT state FROM command_publish_attempts WHERE id=$1",
            &[&attempt]
        )
        .await
        .unwrap()
        .get::<_, String>(0),
        "inflight",
        "live packet correlation must survive a DB reconnect"
    );
    // Lose this disposable client while the MQTT owner receives PUBACK.
    // The failed SQL write must leave the confirmation in Pending.
    assert!(db
        .simple_query("SELECT pg_terminate_backend(pg_backend_pid())")
        .await
        .is_err());
    assert!(publisher.puback(&mut db, 77, &bus).await.is_err());
    assert!(publisher.busy());
    drop(db);
    let mut db = db::connect(&std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap())
        .await
        .unwrap();
    publisher.reconcile(&mut db, &bus).await.unwrap();
    assert!(!publisher.busy());
    let sent = command(&db, settings.id).await;
    assert_eq!(sent.state, "sent");
    assert!(sent.broker_acked_at.is_some());
    assert!(sent.acked_at.is_none());
    assert_eq!(sent.attempts, 1);
    assert_eq!(
        db.query_one(
            "SELECT state,recovery_reason FROM command_publish_attempts WHERE id=$1",
            &[&attempt]
        )
        .await
        .unwrap()
        .get::<_, String>(0),
        "accepted"
    );
    assert_eq!(
        db.query_one(
            "SELECT desired_config FROM devices WHERE device_id=$1",
            &[&DEVICE]
        )
        .await
        .unwrap()
        .get::<_, Value>(0),
        config()
    );
}
