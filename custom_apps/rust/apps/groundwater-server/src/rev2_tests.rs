//! Protocol revision 2 against a real PostgreSQL. The caller supplies a
//! disposable database in GROUNDWATER_TEST_DATABASE_URL; run with
//! `--include-ignored --test-threads=1` (the database tests share tables).
use crate::{
    api, db,
    ingest::{EventBus, IngestStats},
    publisher::Publisher,
    scheduler,
    stream::{self, encode},
    topics::TopicMap,
};
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
const OLD: &str = "0000000000000000000000C1";
const LOG: u32 = 0x6A00_0001;

const ALL_TABLES: &str = "TRUNCATE devices,device_bindings,observations,deliveries,commands,command_events,
    command_publish_attempts,alerts,device_permissions,stream_batches,stream_frames,stream_logs,stream_gaps,
    device_events,device_positions,device_tilt,device_tests,device_health,settings_fragments,
    device_settings_history,device_file_lists,file_downloads,file_download_chunks RESTART IDENTITY CASCADE";

struct Harness {
    url: String,
    client: Client,
    registry: Arc<tokio::sync::RwLock<crate::adapter::EnrollmentRegistry>>,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
    mqtt: rumqttc::AsyncClient,
    _events: rumqttc::EventLoop,
    publisher: Publisher,
    packet: u16,
}

impl Harness {
    async fn new() -> Self {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
        let client = db::connect(&url).await.unwrap();
        db::migrate(&client).await.unwrap();
        // A second migration run must be a no-op on populated tables.
        db::migrate(&client).await.unwrap();
        client.batch_execute(ALL_TABLES).await.unwrap();
        let (mqtt, events) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("rev2-tests", "127.0.0.1", 1),
            1000,
        );
        let mut publisher = Publisher::default();
        publisher.connected = true;
        Self {
            registry: Arc::new(tokio::sync::RwLock::new(
                db::load_registry(&client).await.unwrap(),
            )),
            url,
            client,
            bus: EventBus::new(),
            stats: Arc::new(tokio::sync::Mutex::new(IngestStats::default())),
            mqtt,
            _events: events,
            publisher,
            packet: 0,
        }
    }

    async fn enroll(&mut self, device: &str, profile: &str) {
        self.client
            .execute(
                "INSERT INTO devices(device_id,display_name,source_profile,clock_policy) VALUES($1,'Rev2 bore',$2,'utc')",
                &[&device, &profile],
            )
            .await
            .unwrap();
        for channel in crate::rev2::UPLINK_CHANNELS
            .iter()
            .chain(crate::rev2::DOWNLINK_CHANNELS.iter())
        {
            let topic = format!("gwl/v1/{device}/{channel}");
            self.client
                .execute(
                    "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES($1,$2,$1,$3)",
                    &[&topic, &device, &profile],
                )
                .await
                .unwrap();
        }
        self.reload().await;
    }

    async fn reload(&mut self) {
        *self.registry.write().await = db::load_registry(&self.client).await.unwrap();
    }

    async fn publish_at(
        &mut self,
        device: &str,
        channel: &str,
        payload: &[u8],
        retained: bool,
        at: DateTime<Utc>,
    ) {
        crate::ingest::handle_publish(
            &format!("gwl/v1/{device}/{channel}"),
            payload,
            1,
            retained,
            at,
            &TopicMap::default(),
            &mut self.client,
            &self.registry,
            &self.bus,
            &self.stats,
        )
        .await
        .unwrap();
    }

    async fn publish(&mut self, channel: &str, payload: &[u8]) {
        self.publish_at(D, channel, payload, false, Utc::now())
            .await;
    }

    async fn json(&mut self, channel: &str, value: Value) {
        self.publish(channel, value.to_string().as_bytes()).await;
    }

    /// One scheduler tick plus the MQTT confirmations a broker would send.
    async fn send_next(&mut self) -> Option<(String, Value)> {
        scheduler::tick(&mut self.client, &self.mqtt, &self.bus, &mut self.publisher)
            .await
            .unwrap();
        if !self.publisher.busy() {
            return None;
        }
        let row = self
            .client
            .query_one(
                "SELECT a.topic,c.wire_payload FROM command_publish_attempts a JOIN commands c ON c.id=a.command_id
                 WHERE a.state='prepared' ORDER BY a.id DESC LIMIT 1",
                &[],
            )
            .await
            .unwrap();
        self.packet += 1;
        self.publisher
            .outgoing(&mut self.client, self.packet, &self.bus)
            .await
            .unwrap();
        self.publisher
            .puback(&mut self.client, self.packet, &self.bus)
            .await
            .unwrap();
        let wire: String = row.get(1);
        Some((row.get(0), serde_json::from_str(&wire).unwrap()))
    }

    async fn scalar<T: for<'a> tokio_postgres::types::FromSql<'a>>(&self, sql: &str) -> T {
        self.client.query_one(sql, &[]).await.unwrap().get(0)
    }

    async fn command(&self, id: i64) -> crate::platform::Command {
        crate::platform::command_by_id(&self.client, D, id)
            .await
            .unwrap()
            .unwrap()
    }

    async fn app(&self) -> axum::Router {
        let settings = crate::config::Settings {
            database_url: self.url.clone(),
            address: "127.0.0.1".into(),
            port: 0,
            topics: TopicMap::default(),
            mqtt: None,
            retention_days: 90,
            rev2: Default::default(),
            ops: Default::default(),
        };
        api::router(api::AppState {
            settings: Arc::new(settings),
            db: Arc::new(db::Database::new(
                self.url.clone(),
                db::connect(&self.url).await.unwrap(),
            )),
            bus: self.bus.clone(),
            stats: self.stats.clone(),
            registry_changed: Default::default(),
        })
    }
}

async fn call(
    app: &axum::Router,
    method: &str,
    path: &str,
    role: &str,
    body: Value,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header("x-auth-request-preferred-username", role)
        .header(
            "x-auth-request-groups",
            if role == "operator" {
                "app-admin"
            } else {
                "groundwater-user"
            },
        )
        .body(if body.is_null() {
            Body::empty()
        } else {
            Body::from(body.to_string())
        })
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    let value = serde_json::from_slice(&bytes).unwrap_or_else(|_| json!({"raw":bytes.len()}));
    (status, value)
}

fn tb(t: u32, flags: u8) -> Vec<u8> {
    let mut out = t.to_le_bytes().to_vec();
    out.push(flags);
    out
}
fn sb(mv: u16, level: i32, status: u8) -> Vec<u8> {
    let mut out = mv.to_le_bytes().to_vec();
    out.extend_from_slice(&level.to_le_bytes());
    out.push(status);
    out
}
fn routine(seq: u32, index: u16, level: i32) -> Vec<u8> {
    encode::frame(
        0,
        seq,
        &[index.to_le_bytes().as_slice(), &sb(1200, level, 0)].concat(),
    )
}
fn anchor(seq: u32, t: u32, valid: bool, reason: u8, settings_gen: u32, interval: u32) -> Vec<u8> {
    let mut p = tb(t, if valid { 0x03 } else { 0 });
    p.extend_from_slice(&settings_gen.to_le_bytes());
    p.extend_from_slice(&[reason, 1]);
    p.extend_from_slice(&interval.to_le_bytes());
    p.extend_from_slice(&sb(1200, 5000, 0));
    encode::frame(1, seq, &p)
}
fn area_len(frames: &[Vec<u8>]) -> u32 {
    frames.iter().map(Vec::len).sum::<usize>() as u32
}

async fn observation(
    h: &Harness,
    seq: i64,
) -> (
    Option<DateTime<Utc>>,
    Option<i64>,
    Option<i64>,
    String,
    Option<f64>,
) {
    let row = h
        .client
        .query_one(
            "SELECT recorded_at,time_rel_s,anchor_seq,time_quality,gwl FROM observations WHERE device_id=$1 AND seq=$2",
            &[&D, &seq],
        )
        .await
        .unwrap();
    (row.get(0), row.get(1), row.get(2), row.get(3), row.get(4))
}

fn utc(t: u32) -> DateTime<Utc> {
    crate::rev2_store::utc(i64::from(t))
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn rev2_stream_time_reconstruction_dedupe_and_gaps() {
    let mut h = Harness::new().await;
    h.enroll(D, "V22").await;
    let t0 = (Utc::now() - Duration::hours(6)).timestamp() as u32;

    // Retained identity, replayed on every subscription, is stored once.
    let info = json!({"v":2,"fw":"2.2.0","build":"Nov 16 2026","hw":"V1.08","proto":2,"schema":1,
        "uid":"0102030405060708090A0B0C","imei":"864292046589220","iccid":"8961000000000000000",
        "modem":"EC21EFAR06A07M4G","net":"bench","stream":"hex","reset":"wdg"});
    for _ in 0..2 {
        h.publish_at(D, "info", info.to_string().as_bytes(), true, Utc::now())
            .await;
    }
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE topic LIKE '%/info'")
            .await,
        1
    );
    assert_eq!(
        h.scalar::<String>("SELECT stream_encoding FROM devices")
            .await,
        "hex"
    );
    assert_eq!(
        h.scalar::<String>("SELECT fw_version FROM devices").await,
        "2.2.0"
    );

    h.json(
        "status",
        json!({"v":2,"state":"online","t":t0,"tv":1,"up":30,"boot":3}),
    )
    .await;
    h.json(
        "health",
        json!({"v":2,"t":t0,"tv":1,"up":31,"csq":21,"bat_mv":7412,"sol_mv":5120,"sd":"ok",
            "sd_free_mb":7400,"mram":"ok","unsaved":1234,"usable":122368,"log":"on","gen":4,
            "next":t0+86400,"err":0}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_health").await,
        1
    );
    // Unknown effective settings for gen 4: the server asks for them.
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM commands WHERE op='get_settings' AND origin='auto-settings'"
        )
        .await,
        1
    );

    // Batch A, binary: a boot with an invalid clock.
    let mut log_start = tb(5, 0);
    log_start.extend_from_slice(&LOG.to_le_bytes());
    log_start.extend_from_slice(&0u32.to_le_bytes());
    log_start.extend_from_slice(&[1, 2, 2, 0, 1, 1]);
    log_start.extend_from_slice(&1u16.to_le_bytes());
    log_start.extend_from_slice(&4u32.to_le_bytes());
    log_start.extend_from_slice(&[0xAB; 12]);
    let a = vec![
        encode::frame(14, 1, &log_start),
        anchor(2, 10, false, 2, 4, 900),
        routine(3, 1, 5300),
        encode::frame(
            0,
            4,
            &[2u16.to_le_bytes().as_slice(), &sb(0xFFFF, i32::MIN, 1)].concat(),
        ),
    ];
    let batch_a = encode::batch(LOG, 0, 0, &a);
    h.publish("data/stream", &batch_a).await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        3
    );
    let (at, rel, anchor_seq, quality, _) = observation(&h, 3).await;
    assert_eq!(
        (at, rel, anchor_seq, quality.as_str()),
        (None, Some(910), Some(2), "ambiguous")
    );
    let (_, _, _, _, fault) = observation(&h, 4).await;
    assert_eq!(
        fault, None,
        "a sensor fault is a level-less reading, never zero"
    );

    // Batch B, hex form: the clock is set (Type 15) — this boot's relative
    // times become UTC; plus an alarm with a valid time.
    let mut clock = tb(2000, 0);
    clock.extend_from_slice(&t0.to_le_bytes());
    clock.push(0x07);
    clock.extend_from_slice(&2000u32.to_le_bytes());
    let mut alarm = tb(t0 + 60, 0x03);
    alarm.extend_from_slice(&4u32.to_le_bytes());
    alarm.push(1);
    alarm.extend_from_slice(&12_500i32.to_le_bytes());
    alarm.extend_from_slice(&10_500i32.to_le_bytes());
    let b = vec![encode::frame(15, 5, &clock), encode::frame(8, 6, &alarm)];
    let b_start = area_len(&a);
    let batch_b = encode::batch(LOG, b_start, 0, &b);
    h.publish("data/stream", stream::hex_encode(&batch_b).as_bytes())
        .await;
    assert_eq!(
        h.scalar::<String>("SELECT encoding FROM stream_batches ORDER BY id DESC LIMIT 1")
            .await,
        "hex"
    );
    let shift = i64::from(t0) - 2000;
    assert_eq!(
        observation(&h, 2).await.0,
        Some(crate::rev2_store::utc(shift + 10))
    );
    assert_eq!(
        observation(&h, 3).await.0,
        Some(crate::rev2_store::utc(shift + 910))
    );
    assert_eq!(observation(&h, 3).await.3, "plausible");
    assert_eq!(
        h.scalar::<Option<DateTime<Utc>>>(
            "SELECT recorded_at FROM device_events WHERE event='log_start'"
        )
        .await,
        Some(crate::rev2_store::utc(shift + 5))
    );
    assert_eq!(
        h.scalar::<String>(
            "SELECT details->>'limit' FROM device_events WHERE event='gwl_alarm_enter'"
        )
        .await,
        "high"
    );

    // A resend of batch A changes nothing: (device, log_id, seq) dedupe.
    h.publish("data/stream", &encode::batch(LOG, 0, 1, &a))
        .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations").await,
        3
    );
    assert_eq!(
        h.scalar::<i32>("SELECT frames_duplicate FROM stream_batches ORDER BY id DESC LIMIT 1")
            .await,
        4
    );
    assert_eq!(
        h.scalar::<i64>("SELECT sum(copies-1)::bigint FROM stream_frames")
            .await,
        4
    );

    // A corrupted batch is kept raw and rejected.
    let mut corrupt = batch_a.clone();
    corrupt[40] ^= 0x20;
    h.publish("data/stream", &corrupt).await;
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM stream_batches WHERE NOT ok AND error LIKE 'bad-crc32%'"
        )
        .await,
        1
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE reason='rev2-invalid'")
            .await,
        1
    );

    // Batch C arrives with a hole before it (seq 7..8 missing, positions not
    // contiguous). Its readings must not borrow the old anchor across the gap.
    let d = vec![
        encode::frame(
            19,
            7,
            &[
                tb(t0 + 3000, 3),
                vec![1],
                91_776u32.to_le_bytes().to_vec(),
                122_368u32.to_le_bytes().to_vec(),
            ]
            .concat(),
        ),
        anchor(8, t0 + 3600, true, 2, 4, 600),
    ];
    let c_start = b_start + area_len(&b) + area_len(&d);
    let c = vec![routine(9, 1, 5100), routine(10, 2, 5150)];
    h.publish("data/stream", &encode::batch(LOG, c_start, 0, &c))
        .await;
    assert_eq!(
        h.scalar::<String>("SELECT from_seq||'..'||to_seq||' '||state FROM stream_gaps")
            .await,
        "7..8 open"
    );
    assert_eq!(observation(&h, 9).await.2, None, "anchor may be in the gap");

    // The logger reports ready: the gap is requested once, bounded.
    h.json(
        "status",
        json!({"v":2,"state":"ready","t":t0+10,"tv":1,"up":40,"win":60,"next":t0+86400}),
    )
    .await;
    let flush = h
        .scalar::<i64>("SELECT id FROM commands WHERE op='flush_mqtt' AND origin='auto-gap'")
        .await;
    assert_eq!(
        h.command(flush).await.args,
        Some(json!({"log_id":LOG,"from_seq":7,"to_seq":8}))
    );
    assert_eq!(
        h.scalar::<String>("SELECT state FROM stream_gaps").await,
        "requested"
    );
    h.json(
        "status",
        json!({"v":2,"state":"ready","t":t0+11,"tv":1,"win":60}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM commands WHERE op='flush_mqtt'")
            .await,
        1,
        "an outstanding request is not repeated"
    );

    // The resend fills the gap; batch C's readings now have their anchor.
    h.publish(
        "data/stream",
        &encode::batch(LOG, b_start + area_len(&b), 0x05, &d),
    )
    .await;
    assert_eq!(
        h.scalar::<String>("SELECT state FROM stream_gaps").await,
        "filled"
    );
    let (at, _, anchor_seq, _, _) = observation(&h, 10).await;
    assert_eq!(anchor_seq, Some(8));
    assert_eq!(at, Some(utc(t0 + 3600 + 1200)));
    h.json(
        "cmd/ack",
        json!({"v":2,"id":flush,"op":"flush_mqtt","status":"ok",
            "data":{"frames":2,"batches":1,"first_seq":7,"last_seq":8,"missing":0}}),
    )
    .await;
    assert_eq!(h.command(flush).await.final_status.as_deref(), Some("ok"));

    // A sequence jump with contiguous positions is the firmware's reserved
    // number skip after a reboot, not a gap.
    let e_start = c_start + area_len(&c);
    let e = vec![routine(20, 3, 5200)];
    h.publish("data/stream", &encode::batch(LOG, e_start, 0, &e))
        .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM stream_gaps WHERE state<>'filled'")
            .await,
        0
    );
    assert_eq!(observation(&h, 20).await.0, Some(utc(t0 + 3600 + 1800)));

    // Settings snapshot (Type 3 + 4) activated by an anchor with reason 3.
    let tlv = [
        [0x01u8, 4].as_slice(),
        &600u32.to_le_bytes(),
        &[0x0B, 4],
        &4.5f32.to_le_bytes(),
        &[0x0D, 4],
        &0.25f32.to_le_bytes(),
    ]
    .concat();
    let snapshot = |backup: bool, seq: u32| {
        let mut p = 5u32.to_le_bytes().to_vec();
        p.extend_from_slice(&[1, 0, 1, 0]);
        p.extend_from_slice(&(tlv.len() as u16).to_le_bytes());
        p.extend_from_slice(&crate::crc::crc32(&tlv).to_le_bytes());
        p.extend_from_slice(&tlv);
        encode::frame(if backup { 4 } else { 3 }, seq, &p)
    };
    let mut position = tb(t0 + 7300, 3);
    position.extend_from_slice(&5u32.to_le_bytes());
    position.extend_from_slice(&[1, 2]);
    position.extend_from_slice(&(-338_688_197i32).to_le_bytes());
    position.extend_from_slice(&1_512_092_955i32.to_le_bytes());
    position.extend_from_slice(&12i16.to_le_bytes());
    position.extend_from_slice(&[11, 8]);
    for v in [15i16, -20, 1002] {
        position.extend_from_slice(&v.to_le_bytes());
    }
    position.push(0);
    let mut tilt = tb(t0 + 7301, 3);
    tilt.extend_from_slice(&5u32.to_le_bytes());
    tilt.push(1);
    for v in [15i16, -20, 1002, 12, -34] {
        tilt.extend_from_slice(&v.to_le_bytes());
    }
    tilt.push(0);
    let mut test = tb(t0 + 7302, 3);
    test.extend_from_slice(&5u32.to_le_bytes());
    test.push(1);
    test.extend_from_slice(&0u32.to_le_bytes());
    test.extend_from_slice(&6900u16.to_le_bytes());
    test.extend_from_slice(&5000u16.to_le_bytes());
    test.push(21);
    test.extend_from_slice(&sb(1200, 5000, 0));
    test.extend_from_slice(&1023u16.to_le_bytes());
    let f = vec![
        snapshot(false, 21),
        snapshot(true, 22),
        anchor(23, t0 + 7200, true, 3, 5, 600),
        encode::frame(2, 24, &position),
        encode::frame(21, 25, &tilt),
        encode::frame(5, 26, &test),
        encode::frame(99, 27, &[1, 2, 3]),
    ];
    h.publish(
        "data/stream",
        &encode::batch(LOG, e_start + area_len(&e), 0, &f),
    )
    .await;
    assert_eq!(h.scalar::<i64>("SELECT settings_gen FROM devices").await, 5);
    assert_eq!(h.scalar::<f64>("SELECT max_limit FROM devices").await, 4.5);
    assert_eq!(
        h.scalar::<f64>("SELECT max_hysteresis FROM devices").await,
        0.25
    );
    assert_eq!(
        h.scalar::<i64>("SELECT (settings->>'read_s')::bigint FROM device_settings_history WHERE source='snapshot'").await,
        600
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_positions WHERE source='record'")
            .await,
        1
    );
    assert_eq!(
        h.scalar::<f64>("SELECT roll_deg FROM device_tilt").await,
        -3.4
    );
    assert_eq!(
        h.scalar::<i32>("SELECT battery_mv FROM device_tests").await,
        6900
    );
    assert_eq!(
        h.scalar::<String>(
            "SELECT details->>'type_name' FROM device_events WHERE event='unknown_record'"
        )
        .await,
        "reserved"
    );
    // The low battery in the test record opens a server-side battery alert.
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='open'")
            .await,
        1
    );

    // JSON channels: alert copies dedupe, fallback readings dedupe.
    for _ in 0..2 {
        h.json(
            "alerts",
            json!({"v":2,"t":t0+60,"tv":1,"ev":"gwl_alarm","seq":6,"limit":"high","state":"enter","lvl":12.5,"thr":10.5}),
        )
        .await;
    }
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE source='alert'")
            .await,
        1
    );
    for _ in 0..2 {
        h.json(
            "reading",
            json!({"v":2,"t":t0+9000,"tv":1,"lvl":12.345,"mv":1234,"ss":0,"bat_mv":7412,"sol_mv":5120,"csq":21,"gen":5}),
        )
        .await;
    }
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM observations WHERE source='json'")
            .await,
        1
    );
    h.json(
        "gps",
        json!({"v":2,"t":t0+9000,"tv":1,"fix":3,"lat":-33.8688197,"lon":151.2092955,"alt":12,"hdop":1.1,"sats":8}),
    )
    .await;
    h.json(
        "test/result",
        json!({"v":2,"trigger":"button","t":t0+9100,"tv":1,"up":99,"mv":1234,"ma":8.23,"lvl":12.345,"ss":0,
            "bat_mv":7412,"sol_mv":5120,"csq":21,"status":1023,"ok":true,"sd":"ok","warn":[]}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_positions")
            .await,
        2
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_tests").await,
        2
    );
    // The newer, healthy battery resolves the battery alert.
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM alerts WHERE kind='battery_low' AND state='resolved'"
        )
        .await,
        1
    );

    // API surface for the frontend.
    let app = h.app().await;
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["device"]["protocol_rev"], 2);
    assert_eq!(body["device"]["info"]["hw"], "V1.08");
    assert_eq!(body["device"]["capabilities"]["protocol"], 2);
    assert_eq!(body["device"]["settings_gen"], 5);
    for (path, key, minimum) in [
        ("health", "health", 1),
        ("events", "events", 5),
        ("positions", "positions", 2),
        ("tilt", "tilt", 1),
        ("tests", "tests", 2),
        ("gaps", "gaps", 1),
        ("batches", "batches", 5),
    ] {
        let (status, body) = call(
            &app,
            "GET",
            &format!("/api/devices/{D}/{path}"),
            "operator",
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{path}");
        assert!(
            body[key].as_array().unwrap().len() >= minimum,
            "{path}: {body}"
        );
    }
    let (_, logs) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/logs"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(logs["logs"][0]["log_hex"], "6A000001");
    assert_eq!(logs["logs"][0]["start_reason"], "blank-mram-formatted");
    let (_, settings) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/settings"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(settings["effective"]["settings"]["hi"], 4.5);
    assert_eq!(settings["history"][0]["activated"], true);
    // Viewers without a grant see nothing.
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/events"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/batches"),
        "viewer",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn rev2_command_lifecycle_handshake_and_republish() {
    let mut h = Harness::new().await;
    h.enroll(D, "V22").await;
    h.enroll(OLD, "V21").await;
    let app = h.app().await;
    let path = format!("/api/devices/{D}/commands");

    // Revision 2 commands are refused for a revision 1 unit, and invalid
    // operations, arguments and unconfirmed danger never reach the queue.
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/devices/{OLD}/commands"),
        "operator",
        json!({"op":"get_status"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    for body in [
        json!({"op":"teleport"}),
        json!({"op":"flush_mqtt","args":{"from_seq":9,"to_seq":1,"log_id":1}}),
        json!({"op":"wipe_mram"}),
        json!({"op":"confirm","args":{"ref":1,"nonce":"x"},"confirm":"DANGER"}),
        json!({"op":"get_status","kind":"cfg"}),
    ] {
        let (status, _) = call(&app, "POST", &path, "operator", body.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    let (status, _) = call(&app, "POST", &path, "viewer", json!({"op":"get_status"})).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Published immediately (no Ready window) with the contract envelope.
    let (status, body) = call(&app, "POST", &path, "operator", json!({"op":"get_status"})).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let id = body["command"]["id"].as_i64().unwrap();
    assert_eq!(body["command"]["protocol"], 2);
    let (topic, wire) = h
        .send_next()
        .await
        .expect("published without a wake window");
    assert_eq!(topic, format!("gwl/v1/{D}/cmd/basic"));
    assert_eq!(wire["v"], 2);
    assert_eq!(wire["id"], id);
    assert_eq!(wire["op"], "get_status");
    let exp = wire["exp"].as_i64().unwrap();
    assert!((exp - (Utc::now() + Duration::days(7)).timestamp()).abs() < 60);
    assert_eq!(h.command(id).await.state, "sent");
    h.json("cmd/ack", json!({"v":2,"id":id,"op":"get_status","status":"ok","data":{"csq":20,"head":4096,"log_id":LOG}}))
        .await;
    let acked = h.command(id).await;
    assert_eq!(
        (acked.state.as_str(), acked.final_status.as_deref()),
        ("acked", Some("ok"))
    );
    assert_eq!(h.scalar::<i64>("SELECT (status_snapshot->>'head')::bigint FROM devices WHERE device_id='6A1B2C3D4E5F60718293A4B5'").await, 4096);

    // At most four unacknowledged commands in flight per device.
    let mut queued = Vec::new();
    for _ in 0..6 {
        let (_, body) = call(&app, "POST", &path, "operator", json!({"op":"get_debug"})).await;
        queued.push(body["command"]["id"].as_i64().unwrap());
    }
    let mut sent = 0;
    while h.send_next().await.is_some() {
        sent += 1;
    }
    assert_eq!(sent, 4);
    // rejected/busy waits for the next sleep; duplicate is final.
    h.json(
        "cmd/ack",
        json!({"v":2,"id":queued[0],"op":"get_debug","status":"rejected","reason":"busy"}),
    )
    .await;
    h.json(
        "cmd/ack",
        json!({"v":2,"id":queued[1],"op":"get_debug","status":"duplicate","prev":"ok"}),
    )
    .await;
    assert_eq!(h.command(queued[0]).await.state, "queued");
    assert!(h.command(queued[0]).await.hold_until_sleep);
    assert_eq!(
        h.command(queued[1]).await.final_status.as_deref(),
        Some("duplicate")
    );
    // Slots are free, but the later commands keep their order behind the
    // busy one, which waits for the next sleep.
    assert!(
        h.send_next().await.is_none(),
        "busy command waits for sleep, and the rest wait behind it"
    );

    // Sleep without a final ack: re-publish (at most three times).
    h.json(
        "status",
        json!({"v":2,"state":"sleep","next":(Utc::now()+Duration::days(1)).timestamp()}),
    )
    .await;
    let republished = h.command(queued[2]).await;
    assert_eq!(republished.state, "queued");
    assert_eq!(
        republished.status_reason.as_deref(),
        Some("no ack before the logger slept; re-publishing")
    );
    assert!(
        !h.command(queued[0]).await.hold_until_sleep,
        "busy released by sleep"
    );
    for round in 0..3 {
        while h.send_next().await.is_some() {}
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        h.json("status", json!({"v":2,"state":"sleep"})).await;
        let state = h.command(queued[2]).await.state;
        if round < 2 {
            assert_eq!(state, "queued", "round {round}");
        } else {
            assert_eq!(state, "unacknowledged", "round {round}");
        }
    }
    assert_eq!(h.command(queued[2]).await.publish_count, 4);

    // Expiry: exp passed without a final ack.
    h.client
        .execute(
            "UPDATE commands SET expires_at=now()-interval '1 second' WHERE id=$1",
            &[&queued[3]],
        )
        .await
        .unwrap();
    h.client
        .execute(
            "UPDATE commands SET state='sent' WHERE id=$1",
            &[&queued[3]],
        )
        .await
        .unwrap();
    crate::rev2_commands::expire(&h.client).await.unwrap();
    assert_eq!(h.command(queued[3]).await.state, "expired");
    h.client
        .execute("UPDATE commands SET state='cancelled' WHERE protocol=2 AND state IN ('queued','sent','unacknowledged')", &[])
        .await
        .unwrap();

    // Danger with the nonce handshake, held for the operator because the
    // logger reports unsaved data.
    let (status, body) = call(
        &app,
        "POST",
        &path,
        "operator",
        json!({"op":"wipe_mram","confirm":"DANGER"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let wipe = body["command"]["id"].as_i64().unwrap();
    let (topic, wire) = h.send_next().await.unwrap();
    assert_eq!(topic, format!("gwl/v1/{D}/cmd/danger"));
    // At least the danger default (24 h); longer when the device's next
    // connection is further away (E2E-06).
    assert!(wire["exp"].as_i64().unwrap() >= (Utc::now() + Duration::days(1)).timestamp() - 60);
    let nexp = (Utc::now() + Duration::seconds(120)).timestamp();
    h.json("status", json!({"v":2,"state":"ready","win":60}))
        .await;
    h.json(
        "cmd/ack",
        json!({"v":2,"id":wipe,"op":"wipe_mram","status":"challenge","nonce":"9F3A01C2","nexp":nexp,
            "unsaved":{"frames":12,"bytes":300}}),
    )
    .await;
    assert_eq!(h.command(wipe).await.state, "challenge");
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE event='challenge_held'")
            .await,
        1
    );
    let confirm_path = format!("/api/devices/{D}/commands/{wipe}/confirm");
    let (status, _) = call(
        &app,
        "POST",
        &confirm_path,
        "operator",
        json!({"confirm_unsaved":11}),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "the unsaved count must be echoed exactly"
    );
    let (status, _) = call(&app, "POST", &confirm_path, "operator", Value::Null).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, body) = call(
        &app,
        "POST",
        &confirm_path,
        "operator",
        json!({"confirm_unsaved":12}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let confirm = body["command"]["id"].as_i64().unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &confirm_path,
        "operator",
        json!({"confirm_unsaved":12}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "one confirmation at a time");
    let (_, wire) = h.send_next().await.unwrap();
    assert_eq!(wire["op"], "confirm");
    assert_eq!(wire["exp"], nexp);
    assert_eq!(
        wire["args"],
        json!({"ref":wipe,"nonce":"9F3A01C2","confirm_unsaved":12})
    );
    h.json(
        "cmd/ack",
        json!({"v":2,"id":confirm,"op":"wipe_mram","ref":wipe,"status":"ok"}),
    )
    .await;
    assert_eq!(h.command(wipe).await.final_status.as_deref(), Some("ok"));
    assert_eq!(h.command(confirm).await.state, "acked");

    // Pre-confirmed, no unsaved data: confirmed automatically.
    let (_, body) = call(
        &app,
        "POST",
        &path,
        "operator",
        json!({"op":"wipe_sd","confirm":"DANGER","auto_confirm":true}),
    )
    .await;
    let wipe_sd = body["command"]["id"].as_i64().unwrap();
    h.send_next().await.unwrap();
    h.json("cmd/ack", json!({"v":2,"id":wipe_sd,"op":"wipe_sd","status":"challenge","nonce":"0000BEEF","nexp":nexp})).await;
    let (_, wire) = h.send_next().await.expect("automatic confirmation");
    assert_eq!(wire["args"], json!({"ref":wipe_sd,"nonce":"0000BEEF"}));
    // A challenge nobody confirms expires with the awake window.
    let (_, body) = call(
        &app,
        "POST",
        &path,
        "operator",
        json!({"op":"disable_logging","confirm":"DANGER"}),
    )
    .await;
    let disable = body["command"]["id"].as_i64().unwrap();
    h.send_next().await.unwrap();
    h.json("cmd/ack", json!({"v":2,"id":disable,"op":"disable_logging","status":"challenge","nonce":"1","nexp":nexp})).await;
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    h.json("status", json!({"v":2,"state":"sleep"})).await;
    assert_eq!(h.command(disable).await.state, "expired");

    // Settings: validated, sent on config/set, effective settings stored.
    let settings_path = format!("/api/devices/{D}/settings");
    let (status, _) = call(
        &app,
        "POST",
        &settings_path,
        "operator",
        json!({"settings":{"read_s":5}}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, body) = call(
        &app,
        "POST",
        &settings_path,
        "operator",
        json!({"settings":{"read_s":900,"lo":1.0,"hi":5.0},"replace":true}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let change = body["command"]["id"].as_i64().unwrap();
    let (topic, wire) = h.send_next().await.unwrap();
    assert_eq!(topic, format!("gwl/v1/{D}/config/set"));
    assert_eq!(wire["replace"], true);
    assert_eq!(wire["args"]["read_s"], 900);
    let mut effective = Value::Object(crate::settings::defaults());
    effective["read_s"] = json!(900);
    effective["lo"] = json!(1.0);
    effective["hi"] = json!(5.0);
    effective["hi_hys"] = json!(0.2);
    h.json(
        "config/applied",
        json!({"v":2,"id":change,"op":"settings","status":"ok","gen":6,"settings":effective}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>(
            "SELECT settings_gen FROM devices WHERE device_id='6A1B2C3D4E5F60718293A4B5'"
        )
        .await,
        6
    );
    assert_eq!(
        h.scalar::<f64>("SELECT min_limit FROM devices WHERE device_id='6A1B2C3D4E5F60718293A4B5'")
            .await,
        1.0
    );
    assert_eq!(
        h.scalar::<f64>(
            "SELECT max_hysteresis FROM devices WHERE device_id='6A1B2C3D4E5F60718293A4B5'"
        )
        .await,
        0.2
    );
    assert_eq!(
        h.scalar::<i64>(
            "SELECT count(*) FROM device_settings_history WHERE source='ack' AND settings_gen=6"
        )
        .await,
        1
    );

    // An ack truncated to fit 1,024 bytes drops the settings object
    // (reason data-truncated): the server fetches them with get_settings.
    let (_, body) = call(
        &app,
        "POST",
        &settings_path,
        "operator",
        json!({"settings":{"listen_s":120}}),
    )
    .await;
    let truncated = body["command"]["id"].as_i64().unwrap();
    h.send_next().await.unwrap();
    h.json(
        "config/applied",
        json!({"v":2,"id":truncated,"op":"settings","status":"ok","reason":"data-truncated","gen":7}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM commands WHERE op='get_settings' AND state='queued'")
            .await,
        1
    );
    h.client
        .execute(
            "UPDATE commands SET state='cancelled' WHERE op='get_settings'",
            &[],
        )
        .await
        .unwrap();

    // An ack for an unknown id is evidence, not a state change.
    h.json(
        "cmd/ack",
        json!({"v":2,"id":999999,"op":"get_status","status":"ok"}),
    )
    .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE event='unmatched_ack'")
            .await,
        1
    );

    // Clock: a fresh health with tv=0 while awake triggers sync_time, whose
    // t is the publish instant.
    h.json("status", json!({"v":2,"state":"online","up":5}))
        .await;
    h.json(
        "health",
        json!({"v":2,"t":6,"tv":0,"up":6,"bat_mv":7400,"gen":6}),
    )
    .await;
    let (_, wire) = h.send_next().await.expect("sync_time");
    assert_eq!(wire["op"], "sync_time");
    assert!((wire["args"]["t"].as_i64().unwrap() - Utc::now().timestamp()).abs() < 5);
    h.json("health", json!({"v":2,"t":6,"tv":0,"up":7,"gen":6}))
        .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM commands WHERE op='sync_time'")
            .await,
        1,
        "rate-limited"
    );
    // Presence comes from status, staleness from the announced next.
    h.json(
        "status",
        json!({"v":2,"state":"sleep","next":(Utc::now()+Duration::days(7)).timestamp()}),
    )
    .await;
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(body["device"]["status"], "asleep");
    assert_eq!(body["device"]["link_state"], "sleep");
    h.json("status", json!({"v":2,"state":"offline","reason":"lwt"}))
        .await;
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(body["device"]["status"], "offline");
    // The bare-text Last Will (modems without willex) means the same.
    h.json("status", json!({"v":2,"state":"online"})).await;
    h.publish("status", b"offline").await;
    assert_eq!(
        h.scalar::<String>(
            "SELECT link_state FROM devices WHERE device_id='6A1B2C3D4E5F60718293A4B5'"
        )
        .await,
        "offline"
    );
    let before = h
        .scalar::<i64>("SELECT count(*) FROM deliveries WHERE topic LIKE '%/status'")
        .await;
    h.publish_at(D, "status", b"offline", true, Utc::now())
        .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE topic LIKE '%/status'")
            .await,
        before,
        "an unchanged retained Last Will is not stored again"
    );
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn rev2_sd_listing_and_download() {
    let mut h = Harness::new().await;
    h.enroll(D, "V22").await;
    let app = h.app().await;

    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/files"),
        "operator",
        json!({"path":"/GWL"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let list = body["command"]["id"].as_i64().unwrap();
    h.send_next().await.unwrap();
    h.json(
        "cmd/ack",
        json!({"v":2,"id":list,"op":"file_list","status":"ok",
            "data":{"path":"/GWL","files":[["6A000001/",0],["EXPORT.DAT",12]],"more":false}}),
    )
    .await;
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/files"),
        "viewer",
        Value::Null,
    )
    .await;
    assert!(body.get("error").is_some(), "viewer without a grant");
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/files"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(body["listings"][0]["files"][1][0], "EXPORT.DAT");

    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/devices/{D}/files/downloads"),
        "operator",
        json!({"path":"/GWL/6A000001/B0000001.BIN"}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let download = body["download_id"].as_i64().unwrap();
    let file: Vec<u8> = (0..1500u32).map(|i| (i * 7 % 251) as u8).collect();
    let mut offset = 0usize;
    while let Some((_, wire)) = h.send_next().await {
        assert_eq!(wire["op"], "file_chunk");
        assert_eq!(wire["args"]["off"], offset);
        let len = wire["args"]["len"].as_u64().unwrap() as usize;
        let chunk = &file[offset..offset + len];
        let id = wire["id"].as_u64().unwrap() as u32;
        let message = encode::file_chunk(id, offset as u32, file.len() as u32, chunk);
        // Alternate binary and hex forms.
        if offset == 0 {
            h.publish("data/file", &message).await;
        } else {
            h.publish("data/file", stream::hex_encode(&message).as_bytes())
                .await;
        }
        h.json(
            "cmd/ack",
            json!({"v":2,"id":id,"op":"file_chunk","status":"ok",
                "data":{"off":offset,"len":len,"size":file.len(),"crc32":format!("{:08X}",crate::crc::crc32(chunk))}}),
        )
        .await;
        offset += len;
    }
    assert_eq!(offset, file.len());
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/devices/{D}/files/downloads/{download}"),
        "operator",
        Value::Null,
    )
    .await;
    assert_eq!(body["download"]["state"], "complete");
    assert_eq!(
        body["download"]["crc32"],
        format!("{:08X}", crate::crc::crc32(&file))
    );
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/devices/{D}/files/downloads/{download}/content"
                ))
                .header("x-auth-request-preferred-username", "operator")
                .header("x-auth-request-groups", "app-admin")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        to_bytes(response.into_body(), 1 << 20)
            .await
            .unwrap()
            .as_ref(),
        file.as_slice()
    );
    // A chunk reply naming a command that is not a file_chunk is refused.
    h.publish("data/file", &encode::file_chunk(1, 0, 3, b"abc"))
        .await;
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM deliveries WHERE reason='rev2-invalid'")
            .await,
        1
    );
}

#[tokio::test]
#[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
async fn rev2_profile_detection_and_legacy_fault_readings() {
    let mut h = Harness::new().await;
    // A V21 enrollment on its own gwl/v1 topics that starts speaking rev2.
    h.enroll(D, "V21").await;
    let legacy = json!({"DeviceID":D,"GWL":"nan","TIME":Utc::now().format("%Y-%m-%dT%H:%M:%S").to_string(),
        "RSSI":"012","BL":"03.20","SOL":"3.000000"});
    h.publish("reading", legacy.to_string().as_bytes()).await;
    let row = h
        .client
        .query_one("SELECT gwl,gwl_text,battery_v,rssi FROM observations", &[])
        .await
        .unwrap();
    assert_eq!(row.get::<_, Option<f64>>(0), None);
    assert_eq!(row.get::<_, Option<String>>(1).as_deref(), Some("nan"));
    assert_eq!(row.get::<_, Option<f64>>(2), Some(3.2));
    assert_eq!(row.get::<_, Option<i16>>(3), Some(12));
    // Charts never plot a fault reading; the export keeps the row blank.
    let series = db::device_series(
        &h.client,
        D,
        db::SeriesQuery {
            from: Utc::now() - Duration::days(1),
            to: Utc::now() + Duration::days(1),
            bucket_minutes: 0,
            datum: Default::default(),
        },
    )
    .await
    .unwrap();
    assert!(series.points.is_empty());

    h.json(
        "info",
        json!({"v":2,"fw":"2.2.0","hw":"V1.08","proto":2,"schema":1}),
    )
    .await;
    assert_eq!(
        h.scalar::<String>("SELECT source_profile FROM devices")
            .await,
        "V22"
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_bindings WHERE source_profile<>'V22'")
            .await,
        0
    );
    assert_eq!(
        h.scalar::<i64>("SELECT count(*) FROM device_events WHERE event='profile_detected'")
            .await,
        1
    );
    h.reload().await;
    // Still attributed after the registry refresh.
    h.json("status", json!({"v":2,"state":"online"})).await;
    assert_eq!(
        h.scalar::<String>("SELECT link_state FROM devices").await,
        "online"
    );
    // A unit that still has legacy bindings is never promoted.
    h.enroll(OLD, "V21").await;
    h.client
        .execute(
            "INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('old-legacy',$1,'azman1/feeds/gwl-string','V21')",
            &[&OLD],
        )
        .await
        .unwrap();
    h.reload().await;
    h.publish_at(
        OLD,
        "info",
        json!({"v":2,"proto":2}).to_string().as_bytes(),
        false,
        Utc::now(),
    )
    .await;
    assert_eq!(
        h.scalar::<String>(
            "SELECT source_profile FROM devices WHERE device_id='0000000000000000000000C1'"
        )
        .await,
        "V21"
    );
}
