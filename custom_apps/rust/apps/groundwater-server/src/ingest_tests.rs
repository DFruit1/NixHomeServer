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
        // Fault-injection triggers a failed test left behind.
        client
            .batch_execute(
                "DO $$ DECLARE t RECORD; BEGIN
                     FOR t IN SELECT tgname,tgrelid::regclass AS rel FROM pg_trigger WHERE tgname LIKE 'gw_probe_%' LOOP
                         EXECUTE format('DROP TRIGGER %I ON %s',t.tgname,t.rel);
                     END LOOP; END $$",
            )
            .await
            .unwrap();
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
        &crate::rev2_commands::QueueOptions::new(policy, Utc::now()),
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

fn damaged_anchor(seq: u32, t: u32, interval: u32) -> Vec<u8> {
    let mut p = t.to_le_bytes().to_vec();
    p.push(0x03); // valid UTC
    p.extend_from_slice(&1u32.to_le_bytes());
    p.extend_from_slice(&[3, 1]);
    p.extend_from_slice(&interval.to_le_bytes());
    p.extend_from_slice(&1200u16.to_le_bytes());
    p.extend_from_slice(&5000i32.to_le_bytes());
    p.push(0);
    crate::stream::encode::frame(1, seq, &p)
}

// R1 (independent review): one CRC-8-valid but damaged anchor
// (interval_s 0xEE000384) made time resolution overflow for every later
// batch that paired readings with it. The SQL error was classed "content":
// the batch was rolled back (raw bytes included), quarantined and acked,
// so the logger freed it from MRAM. Now the raw rows are always stored,
// and an impossible time leaves the reading unresolved with the reason.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_damaged_anchor_never_costs_later_batches() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    let b1 = [damaged_anchor(1, 1_763_300_000, 0xEE00_0384), routine(2, 1)];
    h.publish("data/stream", &batch(4, 0, 0, &b1))
        .await
        .unwrap();
    let start = b1.iter().map(Vec::len).sum::<usize>() as u32;
    let b2: Vec<Vec<u8>> = (3..43).map(|s| routine(s, (s * 70) as u16)).collect();
    h.publish("data/stream", &batch(4, start, 0, &b2))
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE state='quarantined'")
            .await,
        0
    );
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM stream_batches WHERE first_seq=3 AND raw IS NOT NULL"
        )
        .await,
        1
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames").await,
        42
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        42
    );
    // seq 2 (index 1) is representable; seq 42 (index 2940) is not.
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM observations WHERE seq=42 AND recorded_at IS NULL
                AND time_reason LIKE '%outside 1970-2200%'"
        )
        .await,
        1
    );
}

fn reading_mv(seq: u32, index: u16, mv: u16) -> Vec<u8> {
    let mut payload = index.to_le_bytes().to_vec();
    payload.extend_from_slice(&mv.to_le_bytes());
    payload.extend_from_slice(&5000i32.to_le_bytes());
    payload.push(0);
    crate::stream::encode::frame(0, seq, &payload)
}

// R1: any failure in derived work (here a database error raised while
// storing one reading's observation) must keep the raw batch and frames,
// record the failure where an operator sees it, acknowledge the message
// and leave the frame flagged so the derivation re-runs at the next start.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_failed_derivation_keeps_the_raw_frames_and_reruns() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    // Fires only for the magic sensor value used here.
    h.client
        .batch_execute(
            "CREATE OR REPLACE FUNCTION gw_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
             BEGIN IF NEW.sensor_mv=4242 AND current_setting('gw.test_fail',true)='on' THEN
                 RAISE EXCEPTION 'test failure' USING ERRCODE='P0001'; END IF; RETURN NEW; END $$;
             DROP TRIGGER IF EXISTS gw_test_fail ON observations;
             CREATE TRIGGER gw_test_fail BEFORE INSERT ON observations FOR EACH ROW EXECUTE FUNCTION gw_test_fail();
             SET gw.test_fail='on';",
        )
        .await
        .unwrap();
    let frames = [
        damaged_anchor(1, 1_763_300_000, 900),
        reading_mv(2, 1, 4242),
        routine(3, 2),
    ];
    let result = h.publish("data/stream", &batch(5, 0, 0, &frames)).await;
    h.client
        .batch_execute("SET gw.test_fail='off'")
        .await
        .unwrap();
    result.unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames").await,
        3
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        2
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames WHERE derive_pending AND seq=2")
            .await,
        1
    );
    assert!(
        h.scalar::<String>("SELECT detail FROM deliveries")
            .await
            .contains("test failure"),
        "the delivery says what failed"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_batches WHERE derive_error IS NOT NULL")
            .await,
        1
    );
    // The reading after the failed one waits instead of pairing across it.
    let rerun = crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    h.client
        .batch_execute("DROP TRIGGER gw_test_fail ON observations; DROP FUNCTION gw_test_fail()")
        .await
        .unwrap();
    assert_eq!(rerun, (1, 0));
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE recorded_at IS NOT NULL")
            .await,
        3
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames WHERE derive_pending")
            .await,
        0
    );
}

// ---- second independent review (V1-V6) ----
// Injects a database error with SQLSTATE `code` on writes to `table` that
// match `cond`, while `gw.test_fail` is on for the session.
async fn fail_on(h: &Harness, table: &str, cond: &str, code: &str) {
    h.client
        .batch_execute(&format!(
            "CREATE OR REPLACE FUNCTION gw_probe_fail() RETURNS trigger LANGUAGE plpgsql AS $$
             BEGIN IF current_setting('gw.test_fail',true)='on' AND ({cond}) THEN
                 RAISE EXCEPTION 'probe failure' USING ERRCODE='{code}'; END IF; RETURN NEW; END $$;
             DROP TRIGGER IF EXISTS gw_probe_fail ON {table};
             CREATE TRIGGER gw_probe_fail BEFORE INSERT OR UPDATE ON {table} FOR EACH ROW EXECUTE FUNCTION gw_probe_fail();"
        ))
        .await
        .unwrap();
}
async fn set_fail(h: &Harness, on: bool) {
    h.client
        .batch_execute(if on {
            "SET gw.test_fail='on'"
        } else {
            "SET gw.test_fail='off'"
        })
        .await
        .unwrap();
}
async fn drop_fail(h: &Harness, table: &str) {
    h.client
        .batch_execute(&format!("DROP TRIGGER IF EXISTS gw_probe_fail ON {table}"))
        .await
        .unwrap();
}

async fn log_flags(h: &Harness, log: i64) -> (bool, bool, Option<String>) {
    let r = h
        .client
        .query_one(
            "SELECT resolve_pending,gaps_pending,resolve_error FROM stream_logs WHERE device_id=$1 AND log_id=$2",
            &[&D, &log],
        )
        .await
        .unwrap();
    (r.get(0), r.get(1), r.get(2))
}

async fn anchor_of(h: &Harness, log: i64, seq: i64) -> Option<i64> {
    h.client
        .query_one(
            "SELECT anchor_seq FROM observations WHERE device_id=$1 AND log_id=$2 AND seq=$3",
            &[&D, &log, &seq],
        )
        .await
        .unwrap()
        .get(0)
}

// V2: a batch whose gap scan failed was flagged, and the next batch's
// success cleared the flag without redoing that scan. The gap before seq 3
// was never recorded or requested, and seq 3 was dated from anchor 1 for
// good although the missing seq 2 may be its real anchor.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_failed_gap_scan_is_redone_by_the_rerun_not_cleared_by_the_next_batch() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    fail_on(&h, "stream_gaps", "true", "P0001").await;
    let a1 = damaged_anchor(1, 1_763_300_000, 900);
    let alen = a1.len() as u32;
    h.publish("data/stream", &batch(7, 0, 0, &[a1]))
        .await
        .unwrap();
    // seq 2 (an anchor of the same size) is lost in transit.
    set_fail(&h, true).await;
    let r3 = routine(3, 0);
    let rlen = r3.len() as u32;
    h.publish("data/stream", &batch(7, 2 * alen, 0, &[r3]))
        .await
        .unwrap();
    set_fail(&h, false).await;
    h.publish(
        "data/stream",
        &batch(7, 2 * alen + rlen, 0, &[routine(4, 1)]),
    )
    .await
    .unwrap();
    drop_fail(&h, "stream_gaps").await;
    let (pending, gaps_pending, _) = log_flags(&h, 7).await;
    assert!(pending && gaps_pending, "the next batch cleared the flag");
    assert_eq!(
        anchor_of(&h, 7, 3).await,
        None,
        "paired across an unscanned range"
    );
    assert_eq!(anchor_of(&h, 7, 4).await, None);
    let rerun = crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    assert_eq!(rerun, (1, 0));
    assert_eq!(
        h.scalar::<String>("SELECT from_seq||'-'||to_seq||' '||state FROM stream_gaps")
            .await,
        "2-2 open"
    );
    assert_eq!(log_flags(&h, 7).await, (false, false, None));
    assert_eq!(anchor_of(&h, 7, 3).await, None, "seq 2 may be its anchor");
}

fn nul_snapshot(seq: u32, generation: u32) -> Vec<u8> {
    let data = vec![0x0E, 3, b'a', 0, b'b']; // loc "a\0b": valid UTF-8, refused by JSONB
    let mut p = generation.to_le_bytes().to_vec();
    p.extend_from_slice(&[1, 0, 1, 0]);
    p.extend_from_slice(&(data.len() as u16).to_le_bytes());
    p.extend_from_slice(&crate::crc::crc32(&data).to_le_bytes());
    p.extend_from_slice(&data);
    crate::stream::encode::frame(3, seq, &p)
}

// V2 with real content: a settings snapshot JSONB refuses (22P05) rolled
// back the batch's gap scan and times with it, and the next batch cleared
// the flag. The settings failure must cost neither, and stay flagged.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_refused_settings_snapshot_costs_neither_the_gap_nor_the_times() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    let a1 = damaged_anchor(1, 1_763_300_000, 900);
    let alen = a1.len() as u32;
    h.publish("data/stream", &batch(7, 0, 0, &[a1, routine(2, 1)]))
        .await
        .unwrap();
    let rlen = routine(2, 1).len() as u32;
    // seq 3 (an anchor) is missing; seq 4 a reading, seq 5 the bad snapshot.
    let b1 = [routine(4, 0), nul_snapshot(5, 5)];
    let b1len: u32 = b1.iter().map(|f| f.len() as u32).sum();
    h.publish("data/stream", &batch(7, 2 * alen + rlen, 0, &b1))
        .await
        .unwrap();
    let (pending, gaps_pending, error) = log_flags(&h, 7).await;
    assert!(pending && !gaps_pending);
    assert!(error.unwrap_or_default().contains("22P05"));
    assert_eq!(
        h.scalar::<String>("SELECT from_seq||'-'||to_seq FROM stream_gaps")
            .await,
        "3-3"
    );
    assert_eq!(anchor_of(&h, 7, 2).await, Some(1));
    assert_eq!(anchor_of(&h, 7, 4).await, None);
    h.publish(
        "data/stream",
        &batch(7, 2 * alen + rlen + b1len, 0, &[routine(6, 1)]),
    )
    .await
    .unwrap();
    assert!(log_flags(&h, 7).await.0, "the next batch cleared the flag");
    let rerun = crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    assert_eq!(rerun, (0, 1), "the snapshot still fails and stays flagged");
    assert!(log_flags(&h, 7).await.0);
}

// V4: a frame of any type whose derivation failed for good blocked the
// dating of every later reading up to the next anchor, although only a
// Type 1 record can be an anchor.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn only_a_pending_type_1_frame_blocks_later_readings() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    fail_on(&h, "observations", "NEW.sensor_mv=4242", "P0001").await;
    set_fail(&h, true).await;
    let frames: Vec<Vec<u8>> = std::iter::once(damaged_anchor(1, 1_763_300_000, 900))
        .chain(std::iter::once(reading_mv(2, 1, 4242)))
        .chain((3..50).map(|s| routine(s, (s - 1) as u16)))
        .collect();
    h.publish("data/stream", &batch(8, 0, 0, &frames))
        .await
        .unwrap();
    crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    set_fail(&h, false).await;
    drop_fail(&h, "observations").await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames WHERE derive_pending AND seq=2")
            .await,
        1
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE recorded_at IS NULL")
            .await,
        0
    );
    assert_eq!(anchor_of(&h, 8, 49).await, Some(1));
}

// Stores readings 0..=last of log `log` directly (anchor at seq 0, 60 s
// interval, all unpaired), with their raw frames, as a long backlog would.
async fn backlog(h: &Harness, log: i64, last: i64, skip: i64) {
    h.client
        .batch_execute(&format!(
            "SET session_replication_role=replica;
             INSERT INTO observations(device_id,kind,payload_digest,received_at,recorded_at,time_quality,time_reason,zone_source,
                interpretation_version,battery_truncated,solar_truncated,duplicate_outcome,duplicate_reason,payload,source,log_id,seq,
                record_type,anchor,interval_s,time_valid,sample_index,time_rel_s)
             SELECT '{D}','reading','x',now(),CASE WHEN g=0 THEN now() END,'plausible','r','utc','2','f','f','new','','{{}}','record',{log},g,
                CASE WHEN g=0 THEN 1 ELSE 0 END,g=0,60,true,g,0 FROM generate_series(0,{last}) g WHERE g<>{skip};
             INSERT INTO stream_frames(device_id,log_id,seq,record_type,size,raw,payload_schema,received_at,pos)
                SELECT '{D}',{log},g,0,18,'\\x00'::bytea,1,now(),g*18 FROM generate_series(0,{last}) g WHERE g<>{skip};
             INSERT INTO stream_logs(device_id,log_id,first_received_at,last_received_at) VALUES('{D}',{log},now(),now());
             RESET session_replication_role; ANALYZE observations;"
        ))
        .await
        .unwrap();
}

// V1: readings waiting behind a gap the logger can no longer fill were
// re-examined by every batch, each walking back to its anchor row by row.
// Past the statement timeout (30 s at about 20k waiting readings; 3 s
// here at 10k) every batch of the log failed as transient and was retried
// for ever, stalling the shared MQTT session for every logger.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn readings_behind_an_unrecoverable_gap_cost_a_batch_nothing() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    backlog(&h, 20, 10_000, 3).await;
    h.client
        .batch_execute(&format!(
            "INSERT INTO stream_gaps(device_id,log_id,from_seq,to_seq,state) VALUES('{D}',20,3,3,'unrecoverable');
             SET statement_timeout='3s'"
        ))
        .await
        .unwrap();
    let started = std::time::Instant::now();
    h.publish(
        "data/stream",
        &batch(20, 10_001 * 18, 0, &[routine(10_001, 10_001)]),
    )
    .await
    .unwrap();
    let took = started.elapsed();
    h.client
        .batch_execute("RESET statement_timeout")
        .await
        .unwrap();
    assert!(
        took < std::time::Duration::from_secs(1),
        "batch took {took:?}"
    );
    assert_eq!(anchor_of(&h, 20, 2).await, Some(0));
    assert_eq!(anchor_of(&h, 20, 4).await, None);
    assert_eq!(
        h.scalar::<String>("SELECT state FROM deliveries").await,
        "accepted"
    );
}

// V1 (b): the dating work one batch does is bounded; the rest is left
// flagged for the re-run instead of being done inline.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_batch_dates_a_bounded_number_of_readings_and_the_rerun_the_rest() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    backlog(&h, 21, 30_000, -1).await;
    h.publish(
        "data/stream",
        &batch(21, 30_001 * 18, 0, &[routine(30_001, 30_001)]),
    )
    .await
    .unwrap();
    let paired: i64 = h
        .scalar("SELECT count(*) FROM observations WHERE log_id=21 AND anchor_seq IS NOT NULL")
        .await;
    assert!(
        paired > 0 && paired < 30_001,
        "{paired} paired in one batch"
    );
    assert!(log_flags(&h, 21).await.0);
    crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE log_id=21 AND record_type=0 AND anchor_seq IS NULL")
            .await,
        0
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE log_id=21 AND seq=30001 AND recorded_at IS NOT NULL")
            .await,
        1
    );
    assert!(!log_flags(&h, 21).await.0);
}

// V1 (c): a statement timeout (or deadlock, lock timeout) in a batch's
// derived work was classed transient: the whole message was retried every
// second for ever and nothing behind it on the session was stored. The raw
// rows are already stored; the step is flagged for the re-run and the
// message acknowledged.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_timeout_in_derived_work_keeps_the_raw_rows_and_acknowledges() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    fail_on(&h, "stream_gaps", "true", "57014").await;
    h.client
        .batch_execute(
            "CREATE OR REPLACE FUNCTION gw_probe_fail2() RETURNS trigger LANGUAGE plpgsql AS $$
             BEGIN IF current_setting('gw.test_fail',true)='on' AND NEW.seq=3 THEN
                 RAISE EXCEPTION 'probe failure' USING ERRCODE='57014'; END IF; RETURN NEW; END $$;
             DROP TRIGGER IF EXISTS gw_probe_fail2 ON observations;
             CREATE TRIGGER gw_probe_fail2 BEFORE INSERT ON observations FOR EACH ROW EXECUTE FUNCTION gw_probe_fail2();",
        )
        .await
        .unwrap();
    set_fail(&h, true).await;
    let a1 = damaged_anchor(1, 1_763_300_000, 900);
    let alen = a1.len() as u32;
    // seq 2 missing: the gap scan runs and times out.
    let result = h.publish("data/stream", &batch(5, 0, 0, &[a1])).await.and(
        h.publish(
            "data/stream",
            &batch(5, 2 * alen, 0, &[routine(3, 0), routine(4, 1)]),
        )
        .await,
    );
    set_fail(&h, false).await;
    drop_fail(&h, "stream_gaps").await;
    h.client
        .batch_execute("DROP TRIGGER gw_probe_fail2 ON observations")
        .await
        .unwrap();
    result.unwrap();
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE state='accepted'")
            .await,
        2
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames").await,
        3
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames WHERE derive_pending")
            .await,
        1
    );
    let (pending, gaps_pending, _) = log_flags(&h, 5).await;
    assert!(pending && gaps_pending);
    assert_eq!(
        anchor_of(&h, 5, 4).await,
        None,
        "paired across an unscanned range"
    );
    crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    assert_eq!(log_flags(&h, 5).await, (false, false, None));
    assert_eq!(
        h.scalar::<String>("SELECT from_seq||'-'||to_seq FROM stream_gaps")
            .await,
        "2-2"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE log_id=5")
            .await,
        3
    );
}

// V1 (c): derived work runs under a time budget (a third of the session's
// statement timeout, at most 10 s); what is left is flagged for the re-run.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_batch_s_derived_work_stops_at_its_time_budget() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    h.client
        .batch_execute(
            "CREATE OR REPLACE FUNCTION gw_probe_slow() RETURNS trigger LANGUAGE plpgsql AS $$
             BEGIN PERFORM pg_sleep(0.05); RETURN NEW; END $$;
             DROP TRIGGER IF EXISTS gw_probe_slow ON observations;
             CREATE TRIGGER gw_probe_slow BEFORE INSERT ON observations FOR EACH ROW EXECUTE FUNCTION gw_probe_slow();
             SET statement_timeout='600ms'",
        )
        .await
        .unwrap();
    let frames: Vec<Vec<u8>> = std::iter::once(damaged_anchor(1, 1_763_300_000, 900))
        .chain((2..41).map(|s| routine(s, (s - 1) as u16)))
        .collect();
    let started = std::time::Instant::now();
    let result = h.publish("data/stream", &batch(6, 0, 0, &frames)).await;
    let took = started.elapsed();
    h.client
        .batch_execute("RESET statement_timeout; DROP TRIGGER gw_probe_slow ON observations")
        .await
        .unwrap();
    result.unwrap();
    assert!(
        took < std::time::Duration::from_millis(600),
        "batch took {took:?}"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_frames").await,
        40
    );
    let deferred: i64 = h
        .scalar("SELECT count(*) FROM stream_frames WHERE derive_pending AND derive_error LIKE 'deferred%'")
        .await;
    assert!(deferred > 0);
    crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy())
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM observations WHERE log_id=6 AND recorded_at IS NOT NULL"
        )
        .await,
        40
    );
}

// V1 (c): a delivery whose raw rows cannot be stored (a transient error)
// was retried every second in place, so nothing behind it on the session
// was stored. It is now held with back-off; the same logger's later
// messages queue behind it, other loggers' messages are stored meanwhile.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_held_delivery_blocks_only_its_own_logger() {
    use rumqttc::{AsyncClient, MqttOptions, Publish, QoS};
    let mut h = Harness::new().await;
    const D2: &str = "8A1B2C3D4E5F60718293A4B6";
    h.client
        .execute(
            "INSERT INTO devices(device_id,display_name,source_profile,clock_policy) VALUES($1,'b','V22','utc')",
            &[&D2],
        )
        .await
        .unwrap();
    for (device, channel) in [(D2, "health"), (D2, "info")] {
        let topic = format!("gwl/v1/{device}/{channel}");
        h.client
            .execute(
                "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,'V22')",
                &[&topic, &device],
            )
            .await
            .unwrap();
    }
    *h.registry.write().await = db::load_registry(&h.client).await.unwrap();
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let settings = crate::config::Settings {
        database_url: url,
        address: "127.0.0.1".into(),
        port: 0,
        topics: TopicMap::default(),
        mqtt: None,
        retention_days: 90,
        rev2: Default::default(),
        ops: Default::default(),
    };
    let (mqtt, _events) = AsyncClient::new(MqttOptions::new("t", "127.0.0.1", 1), 10);
    let message = |device: &str, channel: &str, body: &str, id: u16| {
        let mut p = Publish::new(
            format!("gwl/v1/{device}/{channel}"),
            QoS::AtLeastOnce,
            body.to_owned(),
        );
        p.pkid = id;
        p
    };
    fail_on(&h, "deliveries", &format!("NEW.device_id='{D}'"), "40P01").await;
    set_fail(&h, true).await;
    let mut backlog = crate::ingest::Backlog::default();
    let health = r#"{"v":2,"t":1763300000,"tv":1,"bat_mv":7400}"#;
    let info = r#"{"v":2,"fw":"2.2.0","proto":2,"stream":"bin"}"#;
    for (device, channel, body, id) in [
        (D, "health", health, 1),
        (D, "info", info, 2),
        (D2, "health", health, 3),
    ] {
        backlog
            .intake(
                message(device, channel, body, id),
                &settings,
                &mut h.client,
                &h.registry,
                &h.bus,
                &h.stats,
                &mqtt,
            )
            .await;
    }
    assert_eq!(backlog.len(), 2);
    assert_eq!(
        h.scalar::<i64>(&format!(
            "SELECT count(*) FROM deliveries WHERE device_id='{D2}'"
        ))
        .await,
        1,
        "another logger's message waited behind the failing one"
    );
    set_fail(&h, false).await;
    drop_fail(&h, "deliveries").await;
    tokio::time::sleep(std::time::Duration::from_millis(2100)).await;
    backlog
        .retry(
            &settings,
            &mut h.client,
            &h.registry,
            &h.bus,
            &h.stats,
            &mqtt,
        )
        .await;
    assert_eq!(backlog.len(), 0);
    let order: Vec<String> = h
        .client
        .query(
            &format!("SELECT topic FROM deliveries WHERE device_id='{D}' ORDER BY id"),
            &[],
        )
        .await
        .unwrap()
        .iter()
        .map(|r| r.get(0))
        .collect();
    assert_eq!(
        order,
        [format!("gwl/v1/{D}/health"), format!("gwl/v1/{D}/info")]
    );
}

// E2E-06: operator commands expired exactly 7 days after queueing, and the
// automatic extension needed an announced next connection still ahead. A
// logger with send_s 14 days received the command already expired.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_default_command_lifetime_covers_the_next_connection() {
    use crate::rev2_commands::{queue, QueueOptions};
    let h = Harness::new().await;
    h.client
        .execute(
            "UPDATE devices SET settings='{\"send_s\":1209600}',next_contact_at=now()-interval '1 day' WHERE device_id=$1",
            &[&D],
        )
        .await
        .unwrap();
    let policy = crate::config::rev2_policy();
    let now = Utc::now();
    let lifetime = |id: i64| {
        let client = &h.client;
        async move {
            client
                .query_one(
                    "SELECT extract(epoch FROM expires_at-created_at)::bigint FROM commands WHERE id=$1",
                    &[&id],
                )
                .await
                .unwrap()
                .get::<_, i64>(0)
        }
    };
    for op in ["get_status", "reboot"] {
        let id = queue(
            &h.client,
            D,
            op,
            &serde_json::json!({}),
            &QueueOptions::for_op(op, policy, now),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(
            lifetime(id).await >= 14 * 86_400,
            "{op} expires before the next connection"
        );
    }
    // An operator's explicit lifetime is kept exactly.
    let mut options = QueueOptions::for_op("get_status", policy, now);
    options.expires_at = now + chrono::Duration::hours(1);
    options.cover_next_contact = false;
    let id = queue(&h.client, D, "get_status", &serde_json::json!({}), &options)
        .await
        .unwrap()
        .unwrap();
    assert!(lifetime(id).await <= 3_600);
}

// V3: the re-run stopped at the first error, so one log that kept failing
// (here a statement timeout) kept every later log from ever being re-run.
// Each log is now re-run on its own; a failure is recorded with its
// attempt count and retried after a back-off, not at full cost each pass.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn one_failing_log_does_not_stop_the_rerun_of_the_others() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    fail_on(&h, "observations", "NEW.sensor_mv=4242", "P0001").await;
    set_fail(&h, true).await;
    for log in [10u32, 11, 12, 13] {
        let frames = [
            damaged_anchor(1, 1_763_300_000, 900),
            reading_mv(2, 1, 4242),
            routine(3, 2),
        ];
        h.publish("data/stream", &batch(log, 0, 0, &frames))
            .await
            .unwrap();
    }
    fail_on(
        &h,
        "observations",
        "NEW.sensor_mv=4242 AND NEW.log_id=12",
        "57014",
    )
    .await;
    let rerun =
        crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy()).await;
    assert_eq!(rerun, Ok((3, 1)));
    assert_eq!(pending_logs(&h).await, [12]);
    let (attempts, error): (i32, Option<String>) = {
        let r = h
            .client
            .query_one(
                "SELECT rerun_attempts,resolve_error FROM stream_logs WHERE log_id=12",
                &[],
            )
            .await
            .unwrap();
        (r.get(0), r.get(1))
    };
    assert_eq!(attempts, 1);
    assert!(error.unwrap_or_default().contains("attempt 1"));
    // Backed off: the next pass does not retry it at once.
    assert_eq!(
        crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy()).await,
        Ok((0, 0))
    );
    set_fail(&h, false).await;
    drop_fail(&h, "observations").await;
    h.client
        .execute(
            "UPDATE stream_logs SET rerun_after=now() WHERE log_id=12",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(
        crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy()).await,
        Ok((1, 0))
    );
    assert!(pending_logs(&h).await.is_empty());
}

// V3: the re-run now runs in the background while ingest runs. A live
// batch of a log whose re-run is working leaves its log-level work to the
// re-run instead of waiting on (or racing) it.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_batch_leaves_log_work_to_a_running_rerun() {
    use crate::stream::encode::batch;
    let mut h = Harness::new().await;
    let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
    let rerun = db::connect(&url).await.unwrap();
    let a1 = damaged_anchor(1, 1_763_300_000, 900);
    let alen = a1.len() as u32;
    h.publish("data/stream", &batch(5, 0, 0, &[a1]))
        .await
        .unwrap();
    rerun
        .execute(
            "SELECT pg_advisory_lock(hashtextextended('groundwater-log/'||$1::text||'/'||$2::bigint::text,0))",
            &[&D, &5i64],
        )
        .await
        .unwrap();
    let started = std::time::Instant::now();
    h.publish("data/stream", &batch(5, 2 * alen, 0, &[routine(3, 0)]))
        .await
        .unwrap();
    assert!(started.elapsed() < std::time::Duration::from_secs(1));
    let (pending, gaps_pending, _) = log_flags(&h, 5).await;
    assert!(pending && gaps_pending);
    assert_eq!(anchor_of(&h, 5, 3).await, None);
    drop(rerun);
    assert_eq!(
        crate::rev2_store::rederive_pending(&mut h.client, crate::config::rev2_policy()).await,
        Ok((1, 0))
    );
    assert_eq!(
        h.scalar::<String>("SELECT from_seq||'-'||to_seq FROM stream_gaps")
            .await,
        "2-2"
    );
}

async fn pending_logs(h: &Harness) -> Vec<i64> {
    h.client
        .query(
            "SELECT DISTINCT log_id FROM stream_frames WHERE derive_pending ORDER BY 1",
            &[],
        )
        .await
        .unwrap()
        .iter()
        .map(|r| r.get::<_, i64>(0))
        .collect()
}

// E2E-02: during a slow backlog the control loop stalled, dropped its MQTT
// connection and with it the PUBACK of a flush_mqtt it had published. The
// attempt was abandoned and the command stayed queued, so it was published
// again in the same window: the logger answered `duplicate` (and `busy`
// once its queue was full) while the original `ok` was still behind the
// backlog. A published attempt counts as sent now, and the original ack
// that arrives after the `duplicate` is still applied with its data.
#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn a_lost_puback_is_not_republished_and_the_late_ack_is_recorded() {
    use crate::rev2_commands::{queue, QueueOptions};
    let mut h = Harness::new().await;
    let policy = crate::config::rev2_policy();
    let id = queue(
        &h.client,
        D,
        "flush_mqtt",
        &serde_json::json!({"log_id":7,"from_seq":17,"to_seq":1040}),
        &QueueOptions::new(policy, Utc::now()),
    )
    .await
    .unwrap()
    .unwrap();
    h.client
        .batch_execute(&format!(
            "WITH a AS (INSERT INTO command_publish_attempts(command_id,ready_at,topic,state,dispatched_at,mqtt_packet_id)
                VALUES({id},now(),'gwl/v1/{D}/cmd/basic','inflight',now(),7) RETURNING id)
             UPDATE commands SET active_publish_attempt=(SELECT id FROM a) WHERE id={id}"
        ))
        .await
        .unwrap();
    // The control connection is replaced before the PUBACK is processed.
    crate::publisher::recover(&h.client).await.unwrap();
    assert_eq!(
        h.scalar::<String>(&format!(
            "SELECT state||' '||publish_count FROM commands WHERE id={id}"
        ))
        .await,
        "sent 1",
        "a command that went out was left to be published again in the same window"
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
    // The sleep (control session) overtakes the ack (durable session,
    // behind the backlog): the command is not published again while the
    // logger sleeps, only at its next connection.
    h.publish("status", br#"{"v":2,"state":"sleep"}"#)
        .await
        .unwrap();
    assert_eq!(
        h.scalar::<String>(&format!("SELECT state FROM commands WHERE id={id}"))
            .await,
        "queued"
    );
    assert!(
        crate::rev2_commands::next_publish(&h.client, policy)
            .await
            .unwrap()
            .is_none(),
        "re-published while the ack from the closed window may still be on its way"
    );
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    h.publish("status", br#"{"v":2,"state":"online"}"#)
        .await
        .unwrap();
    let next = crate::rev2_commands::next_publish(&h.client, policy)
        .await
        .unwrap()
        .expect("re-published at the next connection");
    h.client
        .execute(
            "UPDATE command_publish_attempts SET state='abandoned' WHERE id=$1",
            &[&next.attempt_id],
        )
        .await
        .unwrap();
    h.client
        .execute("UPDATE commands SET active_publish_attempt=NULL", &[])
        .await
        .unwrap();
    let duplicate =
        format!(r#"{{"v":2,"id":{id},"op":"flush_mqtt","status":"duplicate","prev":"ok"}}"#);
    let ok = format!(
        r#"{{"v":2,"id":{id},"op":"flush_mqtt","status":"ok","data":{{"frames":1024,"batches":13,"first_seq":17,"last_seq":1040,"missing":0}}}}"#
    );
    h.publish("cmd/ack", duplicate.as_bytes()).await.unwrap();
    h.publish("cmd/ack", ok.as_bytes()).await.unwrap();
    assert_eq!(
        h.scalar::<String>(&format!(
            "SELECT state||' '||final_status||' '||(ack_payload->'data'->>'frames') FROM commands WHERE id={id}"
        ))
        .await,
        "acked ok 1024"
    );
}
