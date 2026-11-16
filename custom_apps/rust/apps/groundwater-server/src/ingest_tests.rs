//! Ingest regressions against a real PostgreSQL (round 3 review). The caller
//! supplies a disposable database in GROUNDWATER_TEST_DATABASE_URL; run with
//! `--include-ignored --test-threads=1` (the database tests share tables).
use crate::{
    db,
    ingest::{EventBus, IngestStats},
    topics::TopicMap,
};
use chrono::Utc;
use std::sync::Arc;
use tokio_postgres::Client;

const D: &str = "7A1B2C3D4E5F60718293A4B6";

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
                 stream_logs,stream_gaps,device_events,device_health,commands,file_downloads,
                 file_download_chunks RESTART IDENTITY CASCADE",
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

    async fn publish(&mut self, channel: &str, payload: &[u8]) -> Result<(), String> {
        self.publish_at(channel, payload, Utc::now()).await
    }

    async fn publish_at(
        &mut self,
        channel: &str,
        payload: &[u8],
        at: chrono::DateTime<Utc>,
    ) -> Result<(), String> {
        crate::ingest::handle_publish(
            &format!("gwl/v1/{D}/{channel}"),
            payload,
            1,
            false,
            at,
            &TopicMap::default(),
            &mut self.client,
            &self.registry,
            &self.bus,
            &self.stats,
        )
        .await
    }

    async fn scalar<T: for<'a> tokio_postgres::types::FromSql<'a>>(&self, sql: &str) -> T {
        self.client.query_one(sql, &[]).await.unwrap().get(0)
    }
}

// persist_publish retries an Err forever and never acks the message: a
// payload PostgreSQL refuses for its content (here a NUL escape, which
// JSONB and TEXT cannot hold) would stall the whole MQTT session, and with
// it every logger's uploads. It must be kept as a rejected delivery instead.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_payload_the_database_refuses_is_rejected_not_retried_forever() {
    let mut h = Harness::new().await;
    for (channel, payload) in [
        (
            "info",
            r#"{"v":2,"fw":"2.2.0\u0000","proto":2,"stream":"bin"}"#,
        ),
        ("health", r#"{"v":2,"t":1763300000,"tv":1,"sd":"o\u0000k"}"#),
        (
            "alerts",
            r#"{"v":2,"t":1763300000,"tv":1,"ev":"impact","peak_mg":900,"x":"\u0000"}"#,
        ),
    ] {
        h.publish(channel, payload.as_bytes())
            .await
            .unwrap_or_else(|e| panic!("{channel}: {e}"));
    }
    let rejected: i64 = h
        .scalar(
            "SELECT count(*) FROM deliveries WHERE state='quarantined' AND reason='rev2-invalid'",
        )
        .await;
    assert_eq!(rejected, 3);
    // Nothing half-stored, and the next message goes through.
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_health").await,
        0
    );
    h.publish(
        "health",
        br#"{"v":2,"t":1763300000,"tv":1,"sd":"ok","bat_mv":7400}"#,
    )
    .await
    .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_health").await,
        1
    );
}

fn routine(seq: u32, index: u16) -> Vec<u8> {
    let mut payload = index.to_le_bytes().to_vec();
    payload.extend_from_slice(&1200u16.to_le_bytes());
    payload.extend_from_slice(&5000i32.to_le_bytes());
    payload.push(0);
    crate::stream::encode::frame(0, seq, &payload)
}

// A gap whose resend request expired (logger out of coverage, ack lost)
// stayed 'requested' for ever: never asked again, never closed, and still
// blocking Type 0 readings after it from their anchor.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn an_expired_gap_request_is_asked_again_and_finally_closed() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    let start = Utc::now();
    let first = [routine(1, 1), routine(2, 2)];
    h.publish_at("data/stream", &batch(9, 0, 0, &first), start)
        .await
        .unwrap();
    // Frames 3 and 4 (32 bytes) never arrived.
    h.publish_at("data/stream", &batch(9, 64, 0, &[routine(5, 5)]), start)
        .await
        .unwrap();
    let ready = br#"{"v":2,"state":"ready","win":60}"#;
    let policy = crate::config::rev2_policy();
    let attempts = policy.max_gap_attempts;
    for attempt in 1..=attempts {
        let at = start
            + chrono::Duration::seconds(
                i64::from(attempt) * (policy.gap_request_interval_seconds + 60),
            );
        h.publish_at("status", ready, at).await.unwrap();
        assert_eq!(
            h.scalar::<i64>("SELECT count(*) FROM commands WHERE op='flush_mqtt'")
                .await,
            i64::from(attempt),
            "attempt {attempt}"
        );
        h.client
            .execute(
                "UPDATE commands SET state='expired' WHERE op='flush_mqtt'",
                &[],
            )
            .await
            .unwrap();
    }
    let at = start
        + chrono::Duration::seconds(
            i64::from(attempts + 1) * (policy.gap_request_interval_seconds + 60),
        );
    h.publish_at("status", ready, at).await.unwrap();
    assert_eq!(
        h.scalar::<String>("SELECT state FROM stream_gaps").await,
        "unrecoverable"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM commands WHERE op='flush_mqtt'")
            .await,
        i64::from(attempts)
    );
}

// A file_chunk command is answered by one chunk at the requested offset.
// Chunks at other offsets were stored too, so a logger account could fill
// the disk under a single command.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_file_chunk_must_answer_the_offset_it_was_asked_for() {
    use crate::stream::encode::file_chunk;
    let mut h = Harness::new().await;
    let policy = crate::config::rev2_policy();
    let command = crate::rev2_commands::queue(
        &h.client,
        D,
        "file_chunk",
        &serde_json::json!({"path":"/GWL/A.CSV","off":0,"len":4}),
        &crate::rev2_commands::QueueOptions::new(&policy, Utc::now()),
    )
    .await
    .unwrap()
    .unwrap() as u32;
    for offset in [4096, 1 << 30] {
        h.publish("data/file", &file_chunk(command, offset, 1 << 31, b"junk"))
            .await
            .unwrap();
    }
    h.publish("data/file", &file_chunk(command, 0, 4, b"toolong"))
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM file_download_chunks")
            .await,
        0
    );
    h.publish("data/file", &file_chunk(command, 0, 4, b"data"))
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<String>("SELECT state FROM file_downloads").await,
        "complete"
    );
}

fn anchor(seq: u32, rel: u32, reason: u8) -> Vec<u8> {
    let mut p = rel.to_le_bytes().to_vec();
    p.push(0); // seconds since boot
    p.extend_from_slice(&1u32.to_le_bytes());
    p.extend_from_slice(&[reason, 1]);
    p.extend_from_slice(&900u32.to_le_bytes());
    p.extend_from_slice(&1200u16.to_le_bytes());
    p.extend_from_slice(&5000i32.to_le_bytes());
    p.push(0);
    crate::stream::encode::frame(1, seq, &p)
}

// A boot that died within seconds (a brownout loop with no clock) left
// relative times no later than the next boot's anchor. The next boot's
// clock set then converted the dead boot's records too, dating them to the
// wrong boot. Boots resume numbering at the reserved block end, so a
// sequence skip marks the boot boundary.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_clock_set_converts_only_its_own_boot() {
    let mut h = Harness::new().await;
    let set_at: u32 = 1_763_300_000;
    let mut clock = 30u32.to_le_bytes().to_vec();
    clock.push(0);
    clock.extend_from_slice(&set_at.to_le_bytes());
    clock.push(0x07);
    clock.extend_from_slice(&30u32.to_le_bytes());
    let frames = [
        anchor(1, 2, 1),  // earlier boot, died at 2 s
        anchor(65, 5, 2), // this boot's anchor at 5 s
        crate::stream::encode::frame(15, 66, &clock),
    ];
    h.publish(
        "data/stream",
        &crate::stream::encode::batch(3, 0, 0, &frames),
    )
    .await
    .unwrap();
    let at = |seq: i64| {
        let client = &h.client;
        async move {
            client
                .query_one(
                    "SELECT recorded_at FROM observations WHERE device_id=$1 AND seq=$2",
                    &[&D, &seq],
                )
                .await
                .unwrap()
                .get::<_, Option<chrono::DateTime<Utc>>>(0)
        }
    };
    assert_eq!(
        at(65).await,
        Some(crate::rev2_store::utc(i64::from(set_at) - 25))
    );
    assert_eq!(at(1).await, None, "the earlier boot has no clock");
}
