//! Backend follow-ups of the round 3 review, against a real PostgreSQL. The
//! caller supplies a disposable database in GROUNDWATER_TEST_DATABASE_URL;
//! run with `--include-ignored --test-threads=1` (the tests share tables).
use crate::{
    db,
    ingest::{EventBus, IngestStats},
    topics::TopicMap,
};
use chrono::Utc;
use serde_json::{json, Value};
use std::sync::Arc;
use tokio_postgres::Client;

const D: &str = "7A1B2C3D4E5F60718293A4B7";

struct Harness {
    client: Client,
    registry: Arc<tokio::sync::RwLock<crate::adapter::EnrollmentRegistry>>,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
}

impl Harness {
    async fn new() -> Self {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
        let client = db::connect(&url).await.unwrap();
        db::migrate(&client).await.unwrap();
        client
            .batch_execute(
                "TRUNCATE devices,device_bindings,observations,deliveries,stream_batches,stream_frames,
                 stream_logs,stream_gaps,device_events,device_health,device_tests,device_settings_history,
                 commands,alerts RESTART IDENTITY CASCADE",
            )
            .await
            .unwrap();
        client
            .execute(
                "INSERT INTO devices(device_id,display_name,source_profile,clock_policy) VALUES($1,'bore','V22','utc')",
                &[&D],
            )
            .await
            .unwrap();
        for channel in crate::rev2::UPLINK_CHANNELS {
            let topic = format!("gwl/v1/{D}/{channel}");
            client
                .execute(
                    "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V22')",
                    &[&topic, &D],
                )
                .await
                .unwrap();
        }
        Self {
            registry: Arc::new(tokio::sync::RwLock::new(
                db::load_registry(&client).await.unwrap(),
            )),
            client,
            bus: EventBus::new(),
            stats: Arc::new(tokio::sync::Mutex::new(IngestStats::default())),
        }
    }

    async fn publish(&mut self, channel: &str, payload: Value) {
        crate::ingest::handle_publish(
            &format!("gwl/v1/{D}/{channel}"),
            payload.to_string().as_bytes(),
            1,
            false,
            Utc::now(),
            &TopicMap::default(),
            &mut self.client,
            &self.registry,
            &self.bus,
            &self.stats,
        )
        .await
        .unwrap();
    }

    async fn health(&mut self, mram: &str, err: i64) {
        let t = Utc::now().timestamp();
        self.publish(
            "health",
            json!({"v":2,"t":t,"tv":1,"up":40,"csq":18,"bat_mv":7400,"sol_mv":0,"sd":"ok","sd_free_mb":100,
                "mram":mram,"unsaved":0,"usable":120000,"log":"on","gen":7,"next":t+86400,"err":err}),
        )
        .await;
    }

    async fn scalar<T: for<'a> tokio_postgres::types::FromSql<'a>>(&self, sql: &str) -> T {
        self.client.query_one(sql, &[]).await.unwrap().get(0)
    }

    async fn restores(&self) -> i64 {
        self.scalar("SELECT count(*) FROM commands WHERE origin='auto-restore'")
            .await
    }

    async fn open_settings_lost(&self) -> i64 {
        self.scalar("SELECT count(*) FROM alerts WHERE kind='settings_lost' AND state='open'")
            .await
    }
}

// A firmware 2.2 logger that loses both settings slots with no snapshot
// stops logging (health mram "recovery", err 4) and waits for settings.
// Rev2 relies on a retained cfg/desired the contract no longer has, so
// without the server it stays silent in the field for good.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn lost_settings_are_restored_once_per_episode() {
    let mut h = Harness::new().await;

    // No acknowledged settings: nothing to send, the operator is asked.
    h.health("recovery", 4).await;
    assert_eq!(h.restores().await, 0);
    assert_eq!(h.open_settings_lost().await, 1);
    h.health("ok", 4).await;
    assert_eq!(h.open_settings_lost().await, 0);

    // The logger acknowledged full settings earlier (a past delayed start).
    let settings = json!({"read_s":900,"send_s":86400,"gps_mode":2,"gps_val":3600,"tilt_mode":2,"tilt_val":3600,
        "start":1_700_000_000,"fac":[1.25e-3,1.0,2.5,-0.25],"tap":1,"tap_sens":5,"gps_sens":5,"lo":null,"hi":10.5,
        "lo_hys":0.25,"hi_hys":0.25,"loc":"B7","proj":"North","text":"Bore 7","partial":0,"utc_off":600,"led":1,
        "attempts":3,"listen_s":120});
    h.client
        .execute(
            "INSERT INTO device_settings_history(device_id,settings_gen,source,settings,received_at)
             VALUES($1,7,'ack',$2,now()-interval '1 day')",
            &[&D, &settings],
        )
        .await
        .unwrap();
    h.health("recovery", 4).await;
    assert_eq!(h.restores().await, 1);
    let row = h
        .client
        .query_one(
            "SELECT op,replace_settings,args,state,requested_by FROM commands WHERE origin='auto-restore'",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "settings");
    assert!(row.get::<_, bool>(1), "a restore replaces, never merges");
    let mut expected = settings.clone();
    expected["start"] = json!(0);
    assert_eq!(row.get::<_, Value>(2), expected);
    assert_eq!(row.get::<_, String>(4), "auto-restore");
    assert_eq!(h.open_settings_lost().await, 0, "a restore is on its way");

    // The logger keeps reporting the state: never a second restore.
    h.health("recovery", 4).await;
    h.health("recovery", 0).await;
    assert_eq!(h.restores().await, 1);
    // The restore ended without the logger leaving the state: ask the operator.
    h.client
        .execute(
            "UPDATE commands SET state='expired' WHERE origin='auto-restore'",
            &[],
        )
        .await
        .unwrap();
    h.health("recovery", 4).await;
    assert_eq!(h.restores().await, 1);
    assert_eq!(h.open_settings_lost().await, 1);

    // Settings applied: the episode ends; a later loss is a new episode.
    h.health("ok", 4).await;
    assert_eq!(h.open_settings_lost().await, 0);
    h.health("recovery", 4).await;
    assert_eq!(h.restores().await, 2);

    // Read-only metadata RECOVERY (err 3) refuses settings: no restore.
    h.health("ok", 0).await;
    h.health("recovery", 3).await;
    assert_eq!(h.restores().await, 2);
}

// bat_mv 65535 is the firmware's "ADC not read" marker. Stored as a value,
// the battery alert read it as a full pack and a dying logger never alerted.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn not_read_markers_never_count_as_readings() {
    let mut h = Harness::new().await;
    let t = Utc::now().timestamp();
    h.publish(
        "health",
        json!({"v":2,"t":t-60,"tv":1,"up":40,"csq":18,"bat_mv":6500,"sol_mv":0,"sd":"ok","sd_free_mb":100,
            "mram":"ok","unsaved":0,"usable":120000,"log":"on","gen":7,"err":0}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='open'")
            .await,
        1
    );
    h.publish(
        "health",
        json!({"v":2,"t":t,"tv":1,"up":40,"csq":99,"bat_mv":65535,"sol_mv":65535,"sd":"missing","sd_free_mb":100,
            "mram":"ok","unsaved":0,"usable":120000,"log":"on","gen":7,"err":0}),
    )
    .await;
    let row = h
        .client
        .query_one(
            "SELECT bat_mv,sol_mv,csq,sd_free_mb FROM device_health ORDER BY id DESC LIMIT 1",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, Option<i32>>(0), None);
    assert_eq!(row.get::<_, Option<i32>>(1), None);
    assert_eq!(row.get::<_, Option<i16>>(2), None);
    assert_eq!(row.get::<_, Option<i32>>(3), None);
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='open'")
            .await,
        1,
        "an unread battery is not a recovered battery"
    );
}

// V6 (second independent review): the automatic restore was queued after
// an operator's settings command still waiting for the logger, got a
// higher id, was published after it, and its replace-all reverted the
// operator's change. An operator's queued or in-flight settings command
// supersedes the restore; a newer one withdraws a restore not yet sent.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn an_operator_settings_command_supersedes_the_automatic_restore() {
    use crate::rev2_commands::next_publish;
    let mut h = Harness::new().await;
    let settings = json!({"read_s":900,"send_s":86400,"gps_mode":2,"gps_val":3600,"tilt_mode":2,"tilt_val":3600,
        "start":0,"fac":[1.25e-3,1.0,2.5,-0.25],"tap":1,"tap_sens":5,"gps_sens":5,"lo":null,"hi":10.5,
        "lo_hys":0.25,"hi_hys":0.25,"loc":"B7","proj":"North","text":"Bore 7","partial":0,"utc_off":600,"led":1,
        "attempts":3,"listen_s":120});
    h.client
        .execute(
            "INSERT INTO device_settings_history(device_id,settings_gen,source,settings,received_at)
             VALUES($1,7,'ack',$2,now()-interval '1 day')",
            &[&D, &settings],
        )
        .await
        .unwrap();
    let policy = crate::config::rev2_policy();
    // 1. Queued before the logger reports RECOVERY: no restore.
    let first = operator_settings(&h.client).await;
    h.health("recovery", 4).await;
    assert_eq!(
        h.restores().await,
        0,
        "the restore would revert the operator's change"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT settings_restore_command_id FROM devices")
            .await,
        first
    );
    // 2. Queued after the restore: the restore is withdrawn.
    h.client
        .batch_execute(
            "UPDATE commands SET state='cancelled'; UPDATE devices SET settings_lost_since=NULL,settings_restore_command_id=NULL",
        )
        .await
        .unwrap();
    h.health("recovery", 4).await;
    assert_eq!(h.restores().await, 1);
    let second = operator_settings(&h.client).await;
    assert_eq!(
        h.scalar::<String>("SELECT state FROM commands WHERE origin='auto-restore'")
            .await,
        "cancelled"
    );
    for channel in crate::rev2::DOWNLINK_CHANNELS {
        let topic = format!("gwl/v1/{D}/{channel}");
        h.client
            .execute(
                "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V22')",
                &[&topic, &D],
            )
            .await
            .unwrap();
    }
    let next = next_publish(&h.client, policy).await.unwrap();
    let wire: Value = serde_json::from_str(&next.expect("a command to publish").wire).unwrap();
    assert_eq!(wire["id"].as_i64(), Some(second));
}

async fn operator_settings(client: &Client) -> i64 {
    use crate::rev2_commands::{queue, QueueOptions};
    queue(
        client,
        D,
        "settings",
        &json!({"hi":12.0}),
        &QueueOptions::for_op("settings", crate::config::rev2_policy(), Utc::now()),
    )
    .await
    .unwrap()
    .unwrap()
}
