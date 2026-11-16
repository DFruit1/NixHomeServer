//! Firmware 2.2 round 3 wire changes the server follows, against a real
//! PostgreSQL. The caller supplies a disposable database in
//! GROUNDWATER_TEST_DATABASE_URL; run with `--include-ignored
//! --test-threads=1` (the tests share tables). Each test guards a
//! catastrophic outcome: a destructive command shown as done or run again,
//! RAM-only settings taken for the logger's settings, data decoded with a
//! guessed layout.
use crate::{
    db,
    ingest::{EventBus, IngestStats},
    rev2_commands::{self, QueueOptions},
    stream::encode,
    topics::TopicMap,
};
use chrono::{Duration, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio_postgres::Client;

const D: &str = "8A1B2C3D4E5F60718293A4B8";
const LOG: u32 = 0x6B00_0001;

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
        // The new constraints and columns must survive a second run.
        db::migrate(&client).await.unwrap();
        client
            .batch_execute(
                "TRUNCATE devices,device_bindings,observations,deliveries,stream_batches,stream_frames,
                 stream_logs,stream_gaps,device_events,device_health,device_tests,device_settings_history,
                 device_positions,commands,alerts RESTART IDENTITY CASCADE",
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

    async fn raw(&mut self, channel: &str, payload: &[u8]) {
        crate::ingest::handle_publish(
            &format!("gwl/v1/{D}/{channel}"),
            payload,
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

    async fn json(&mut self, channel: &str, payload: Value) {
        self.raw(channel, payload.to_string().as_bytes()).await;
    }

    async fn scalar<T: for<'a> tokio_postgres::types::FromSql<'a>>(&self, sql: &str) -> T {
        self.client.query_one(sql, &[]).await.unwrap().get(0)
    }

    /// Queues `op` and marks it published, as the scheduler would.
    async fn sent(&self, op: &str, args: Value, parent: Option<i64>) -> i64 {
        let policy = crate::config::rev2_policy();
        let options = QueueOptions {
            parent_id: parent,
            ..QueueOptions::new(policy, Utc::now())
        };
        let id = rev2_commands::queue(&self.client, D, op, &args, &options)
            .await
            .unwrap()
            .unwrap();
        self.client
            .execute(
                "UPDATE commands SET state='sent',sent_at=now(),last_published_at=now()-interval '1 second',
                    publish_count=1 WHERE id=$1",
                &[&id],
            )
            .await
            .unwrap();
        id
    }

    async fn state(&self, id: i64) -> (String, Option<String>, Option<String>) {
        let row = self
            .client
            .query_one(
                "SELECT state,final_status,status_reason FROM commands WHERE id=$1",
                &[&id],
            )
            .await
            .unwrap();
        (row.get(0), row.get(1), row.get(2))
    }

    async fn health(&mut self, mram: &str, usable: i64, generation: i64, err: i64) {
        let t = Utc::now().timestamp();
        self.json(
            "health",
            json!({"v":2,"t":t,"tv":1,"up":40,"csq":18,"bat_mv":7400,"sol_mv":0,"sd":"ok","sd_free_mb":100,
                "mram":mram,"unsaved":0,"usable":usable,"log":"on","gen":generation,"next":t+86400,"err":err}),
        )
        .await;
    }

    async fn sleep(&mut self) {
        self.json(
            "status",
            json!({"v":2,"state":"sleep","next":(Utc::now()+Duration::days(1)).timestamp()}),
        )
        .await;
    }
}

// A watchdog or fault reset that cuts a command's handler leaves its id
// recorded as failed (firmware `keep_before_run`); the re-sent copy is
// answered duplicate/"prev":"failed" and not run again. The handler may have
// done part or all of its work (contract §6.2): recorded as a success the
// operator would believe a cut wipe_mram had completed, recorded as failed
// they would be invited to wipe the fresh data again. It is "interrupted,
// outcome unknown", never re-sent.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_command_cut_by_a_reset_is_failed_with_its_effect_unknown() {
    let mut h = Harness::new().await;

    // A basic command whose original ack never arrived.
    let flush = h.sent("flush_sd", json!({}), None).await;
    h.json(
        "cmd/ack",
        json!({"v":2,"id":flush,"op":"flush_sd","status":"duplicate","prev":"failed"}),
    )
    .await;
    let (state, status, reason) = h.state(flush).await;
    assert_eq!(
        (state.as_str(), status.as_deref()),
        ("acked", Some("interrupted"))
    );
    assert!(reason.unwrap().contains("outcome unknown"));
    // Final: a sleep never re-sends it, a later copy's answer changes nothing.
    h.sleep().await;
    assert_eq!(h.state(flush).await.0, "acked");
    h.json(
        "cmd/ack",
        json!({"v":2,"id":flush,"op":"flush_sd","status":"duplicate","prev":"failed"}),
    )
    .await;
    assert_eq!(h.state(flush).await.1.as_deref(), Some("interrupted"));

    // A destructive operation: the confirm's id carries the wipe's op.
    let wipe = h.sent("wipe_mram", json!({}), None).await;
    h.client
        .execute(
            "UPDATE commands SET state='challenge',acked_at=now() WHERE id=$1",
            &[&wipe],
        )
        .await
        .unwrap();
    let confirm = h
        .sent(
            "confirm",
            json!({"ref":wipe,"nonce":"9F3A01C2"}),
            Some(wipe),
        )
        .await;
    h.json(
        "cmd/ack",
        json!({"v":2,"id":confirm,"op":"wipe_mram","status":"duplicate","prev":"failed"}),
    )
    .await;
    for id in [confirm, wipe] {
        let (state, status, reason) = h.state(id).await;
        assert_eq!(
            (state.as_str(), status.as_deref()),
            ("acked", Some("interrupted")),
            "#{id}"
        );
        let reason = reason.unwrap();
        assert!(reason.contains("may have run"), "{reason}");
        assert!(reason.contains("new log_id"), "{reason}");
        assert!(reason.contains("check before sending it again"), "{reason}");
    }
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE event='command_outcome_unknown'")
            .await,
        2
    );

    // A settings change cut by a reset may or may not have been committed:
    // the server reads the settings in force.
    let settings = h.sent("settings", json!({"read_s":900}), None).await;
    h.json(
        "config/applied",
        json!({"v":2,"id":settings,"op":"settings","status":"duplicate","prev":"failed"}),
    )
    .await;
    assert_eq!(h.state(settings).await.1.as_deref(), Some("interrupted"));
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM commands WHERE op='get_settings' AND origin='auto-settings'"
        )
        .await,
        1
    );
    // Nothing was put back in the queue.
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM commands WHERE state IN ('queued','sent') AND op<>'get_settings'"
        )
        .await,
        0
    );
}

// Fallback mode (MRAM absent or faulted at boot): settings live in RAM until
// the next reset, generations count from 1 per boot. Stored like ring
// settings, a RAM generation 1 would overwrite the history of the ring's
// generation 1 and be skipped as older than the ring's generation 7 (the
// server showing settings the logger no longer runs), and the automatic
// restore after a later settings loss would re-send RAM settings.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn ram_only_settings_never_pass_for_the_rings() {
    let mut h = Harness::new().await;
    let ring = json!({"read_s":900,"send_s":86400,"gps_mode":0,"gps_val":0,"tilt_mode":0,"tilt_val":0,
        "start":0,"fac":[0.0,1.0,1.0,0.0],"tap":1,"tap_sens":5,"gps_sens":5,"lo":1.0,"hi":5.0,
        "lo_hys":0.0,"hi_hys":0.0,"loc":"Bore 7","proj":"","text":"","partial":0,"utc_off":0,"led":0,
        "attempts":3,"listen_s":60});
    // The ring's acknowledged generation 1 and generation 7.
    for generation in [1, 7] {
        let id = h.sent("settings", json!({"read_s":900}), None).await;
        h.json(
            "config/applied",
            json!({"v":2,"id":id,"op":"settings","status":"ok","gen":generation,"settings":ring}),
        )
        .await;
    }
    h.health("ok", 122_368, 7, 0).await;
    assert_eq!(h.scalar::<i64>("SELECT settings_gen FROM devices").await, 7);

    // The logger boots into fallback mode: RAM generation 1, V2.1 page or
    // defaults. The server reads them and knows they are RAM-only.
    h.health("fault", 0, 1, 0).await;
    let fetch: i64 = h
        .scalar("SELECT max(id) FROM commands WHERE op='get_settings' AND state='queued'")
        .await;
    let mut ram = ring.clone();
    ram["read_s"] = json!(3600);
    ram["loc"] = json!("");
    h.json(
        "cmd/ack",
        json!({"v":2,"id":fetch,"op":"get_settings","status":"ok","data":{"gen":1,"settings":ram}}),
    )
    .await;
    let row = h
        .client
        .query_one(
            "SELECT settings_gen,settings_ram_only,settings->'read_s' FROM devices",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(
        (
            row.get::<_, i64>(0),
            row.get::<_, bool>(1),
            row.get::<_, Value>(2)
        ),
        (1, true, json!(3600)),
        "the RAM settings are in force, whatever their generation"
    );
    // An operator change in fallback mode: persist false, RAM generation 2.
    let change = h.sent("settings", json!({"read_s":1800}), None).await;
    let mut ram2 = ram.clone();
    ram2["read_s"] = json!(1800);
    h.json(
        "config/applied",
        json!({"v":2,"id":change,"op":"settings","status":"ok","gen":2,"persist":false,"settings":ram2}),
    )
    .await;
    assert_eq!(h.scalar::<i64>("SELECT settings_gen FROM devices").await, 2);
    assert!(
        h.scalar::<bool>("SELECT settings_ram_only FROM devices")
            .await
    );
    // The ring's history is intact; RAM generations have their own sources.
    assert_eq!(
        h.scalar::<Value>(
            "SELECT settings->'read_s' FROM device_settings_history WHERE source='ack' AND settings_gen=1"
        )
        .await,
        json!(900)
    );
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM device_settings_history WHERE source IN ('ack-ram','get_settings-ram')"
        )
        .await,
        2
    );

    // The ring comes back (clear_error_latch or the hourly retry) and its
    // settings replace the RAM ones without a config/applied: the next
    // health makes the server read them, even with an equal generation.
    h.client
        .execute(
            "UPDATE commands SET created_at=created_at-interval '2 hours' WHERE op='get_settings'",
            &[],
        )
        .await
        .unwrap();
    h.health("ok", 122_368, 2, 0).await;
    let fetch: i64 = h
        .scalar("SELECT max(id) FROM commands WHERE op='get_settings' AND state='queued'")
        .await;
    h.json(
        "cmd/ack",
        json!({"v":2,"id":fetch,"op":"get_settings","status":"ok","data":{"gen":7,"settings":ring}}),
    )
    .await;
    let row = h
        .client
        .query_one(
            "SELECT settings_gen,settings_ram_only,settings->'read_s' FROM devices",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(
        (
            row.get::<_, i64>(0),
            row.get::<_, bool>(1),
            row.get::<_, Value>(2)
        ),
        (7, false, json!(900))
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE event='settings_ram_replaced'")
            .await,
        1
    );

    // A later settings loss restores the ring's acknowledged settings, never
    // the RAM-only ones.
    h.health("recovery", 122_368, 0, 4).await;
    let restored: Value = h
        .scalar("SELECT args FROM commands WHERE origin='auto-restore'")
        .await;
    assert_eq!(restored["read_s"], 900);
    assert_eq!(restored["loc"], "Bore 7");
}

fn schema_batch(frames: &[Vec<u8>], schema: u16) -> Vec<u8> {
    let mut batch = encode::batch(LOG, 0, 0, frames);
    batch[6..8].copy_from_slice(&schema.to_le_bytes());
    let body = batch.len() - 4;
    let crc = crate::crc::crc32(&batch[..body]);
    batch[body..].copy_from_slice(&crc.to_le_bytes());
    batch
}

// Each batch is decoded by its own header's payload schema. Frames of a
// schema this server has no decoder for must never be decoded with the
// schema 1 layout (wrong levels, times and alarms): they stay raw, the
// operator is told a server update is needed, and a server that has the
// decoder derives them at its first start.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn frames_of_an_unknown_payload_schema_wait_raw_for_a_decoder() {
    let mut h = Harness::new().await;
    let t = Utc::now().timestamp() as u32 - 3600;
    let mut anchor = t.to_le_bytes().to_vec();
    anchor.push(0x03);
    anchor.extend_from_slice(&7u32.to_le_bytes());
    anchor.extend_from_slice(&[1, 1]);
    anchor.extend_from_slice(&900u32.to_le_bytes());
    anchor.extend_from_slice(&1200u16.to_le_bytes());
    anchor.extend_from_slice(&5000i32.to_le_bytes());
    anchor.push(0);
    let frames = vec![encode::frame(1, 1, &anchor)];
    h.raw("data/stream", &schema_batch(&frames, 2)).await;

    let row = h
        .client
        .query_one(
            "SELECT count(*),bool_and(derive_pending),bool_and(derive_error LIKE '%schema 2%') FROM stream_frames",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(
        (
            row.get::<_, i64>(0),
            row.get::<_, bool>(1),
            row.get::<_, bool>(2)
        ),
        (1, true, true)
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        0
    );
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM alerts WHERE kind='decoder_missing' AND state='open'"
        )
        .await,
        1
    );

    // A restart of this build leaves them alone: no guessing.
    let policy = crate::config::rev2_policy();
    crate::rev2_store::rederive_pending(&mut h.client, policy)
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        0
    );
    assert!(
        h.scalar::<bool>("SELECT derive_pending FROM stream_frames")
            .await
    );

    // A build whose decoder covers the frames' schema (simulated: these
    // bytes are a schema 1 anchor) derives them at its start and ends the
    // alert.
    h.client
        .execute("UPDATE stream_frames SET payload_schema=1", &[])
        .await
        .unwrap();
    crate::rev2_store::rederive_pending(&mut h.client, policy)
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        1
    );
    assert!(
        !h.scalar::<bool>("SELECT derive_pending FROM stream_frames")
            .await
    );
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM alerts WHERE kind='decoder_missing' AND state='open'"
        )
        .await,
        0
    );
}
