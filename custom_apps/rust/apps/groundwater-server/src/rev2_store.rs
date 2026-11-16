//! Storage of protocol revision 2 device traffic (`docs/gwl-v1-rev2.md`).
//!
//! A `gwl/v1/<DEV>/<channel>` message reaches this module only when its
//! binding is trusted (the same attribution rules as revision 1) and its
//! payload is revision 2 (`"v":2` JSON, or a `GWB1`/`GWF1` batch). Every
//! function runs inside the caller's intake transaction, after the delivery
//! row exists, so a crash never leaves a half-stored message and an MQTT
//! redelivery of the same bytes is caught by the intake key.
//!
//! Time model. Ring records carry Rev2's time block: UTC when `VALID`, else
//! seconds since boot. Relative times are kept (`time_rel_s`) and converted
//! once a Type 15 clock-set record pairs uptime with UTC
//! (`groundwater_resolve_log`). Type 0 readings take `anchor + k ×
//! interval_s` from the anchor before them, and only across a stretch with no
//! open gap, so an anchor still missing in a gap is never skipped over.

use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};
use tokio_postgres::GenericClient;

use crate::config::Rev2Policy;
use crate::ingest::LiveEvent;
use crate::records::{self, Record, TimeBlock};
use crate::rev2::{self, PresenceState};
use crate::stream;

/// Interpretation tag stored on revision 2 observations.
pub const INTERPRETATION: &str = "gw-adapter/2+v22";

/// Readings one batch may date (pair with their anchor and time). Past
/// this the log is flagged and the re-run continues, so a batch's cost
/// never grows with a log's history or backlog.
const RESOLVE_BATCH_BUDGET: i32 = 5_000;
/// Readings one re-run call dates (the re-run repeats it until done).
const RESOLVE_RERUN_BUDGET: i32 = 50_000;

/// One attributed revision 2 delivery.
pub struct Context<'a> {
    pub device_id: &'a str,
    pub channel: &'a str,
    pub received_at: DateTime<Utc>,
    pub retained: bool,
    /// `None` only when derived work is re-run after the delivery row was
    /// pruned by retention.
    pub delivery_id: Option<i64>,
    pub policy: &'a Rev2Policy,
}

/// What storing a message produced.
#[derive(Debug, Default)]
pub struct Outcome {
    pub events: Vec<LiveEvent>,
    /// The content was refused (bad CRC, malformed JSON, unknown command);
    /// the delivery is kept with this reason.
    pub rejected: Option<String>,
    /// A note for the delivery log (counts, warnings).
    pub detail: Option<String>,
}

impl Outcome {
    pub fn rejected(reason: impl Into<String>) -> Self {
        Self {
            rejected: Some(reason.into()),
            ..Self::default()
        }
    }
}

pub(crate) fn dberr(label: &'static str) -> impl Fn(tokio_postgres::Error) -> String {
    move |e| match e.as_db_error() {
        Some(db) => format!("{label}: {} [{}]", db.message(), db.code().code()),
        None => format!("{label}: {e}"),
    }
}

/// The SQLSTATE that [`dberr`] appended to a storage error, if any.
pub(crate) fn sqlstate(error: &str) -> Option<&str> {
    error
        .rsplit_once('[')
        .and_then(|(_, code)| code.strip_suffix(']'))
        .filter(|code| code.len() == 5)
}

/// Whether a storage error says nothing about the data and the whole message
/// must be tried again (not acknowledged): no SQLSTATE (the connection
/// dropped), connection exceptions (08), transaction rollback (40:
/// serialization failure, deadlock), insufficient resources (53), object
/// state (55: lock not available), operator intervention (57: shutdown,
/// statement timeout) and system errors (58).
pub(crate) fn transient_error(error: &str) -> bool {
    sqlstate(error).is_none_or(|code| {
        ["08", "40", "53", "55", "57", "58"]
            .iter()
            .any(|class| code.starts_with(class))
    })
}

/// Runs `SAVEPOINT name`; [`end_savepoint`] releases or rolls it back.
async fn savepoint<C: GenericClient + Sync>(client: &C, name: &str) -> Result<(), String> {
    client
        .batch_execute(&format!("SAVEPOINT {name}"))
        .await
        .map_err(dberr("savepoint"))
}

/// Ends a [`savepoint`]: kept when `ok`, otherwise rolled back.
async fn end_savepoint<C: GenericClient + Sync>(
    client: &C,
    name: &str,
    ok: bool,
) -> Result<(), String> {
    let sql = if ok {
        format!("RELEASE SAVEPOINT {name}")
    } else {
        format!("ROLLBACK TO SAVEPOINT {name}; RELEASE SAVEPOINT {name}")
    };
    client
        .batch_execute(&sql)
        .await
        .map_err(dberr("savepoint end"))
}

pub fn utc(seconds: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(seconds, 0).unwrap_or(DateTime::UNIX_EPOCH)
}

/// Mirrors SQL `groundwater_time_quality`.
pub fn time_quality(at: Option<DateTime<Utc>>, received: DateTime<Utc>) -> &'static str {
    let Some(at) = at else {
        return "ambiguous";
    };
    if at.timestamp() < 1_704_067_200 {
        "reset"
    } else if at > received + chrono::Duration::hours(24) {
        "future"
    } else {
        "plausible"
    }
}

/// A placed device instant.
#[derive(Debug, Clone, PartialEq)]
pub struct Placed {
    pub recorded_at: Option<DateTime<Utc>>,
    pub valid: bool,
    pub rel: Option<i64>,
    pub source: String,
}

pub fn place(time: TimeBlock) -> Placed {
    if time.valid() {
        Placed {
            recorded_at: Some(utc(i64::from(time.time))),
            valid: true,
            rel: None,
            source: time.source_name().to_string(),
        }
    } else {
        Placed {
            recorded_at: None,
            valid: false,
            rel: Some(i64::from(time.time)),
            source: "relative".into(),
        }
    }
}

/// Places a JSON `t`/`tv` pair. A relative time sent in the current awake
/// connection is estimated from the uptime the logger reported in this
/// connection's `status`/`health` (`uptime_s` at `uptime_at`).
pub fn place_json(
    time: Option<rev2::DeviceTime>,
    received: DateTime<Utc>,
    uptime: Option<(i64, DateTime<Utc>)>,
) -> Placed {
    match time {
        Some(time) if time.valid => Placed {
            recorded_at: Some(utc(i64::from(time.t))),
            valid: true,
            rel: None,
            source: "device".into(),
        },
        Some(time) => {
            let estimate = uptime.and_then(|(up, at)| {
                let rel = i64::from(time.t);
                (rel <= up && received - at < chrono::Duration::minutes(15))
                    .then(|| at - chrono::Duration::seconds(up - rel))
            });
            Placed {
                recorded_at: estimate,
                valid: false,
                rel: Some(i64::from(time.t)),
                source: if estimate.is_some() {
                    "uptime-estimate".into()
                } else {
                    "relative".into()
                },
            }
        }
        None => Placed {
            recorded_at: Some(received),
            valid: false,
            rel: None,
            source: "receipt".into(),
        },
    }
}

fn digest(bytes: &[u8]) -> String {
    crate::adapter::sha256_hex(bytes)
}

/// Whether a retained `status`/`info` repeats what is already stored. A
/// retained message is re-sent on every new subscription; it is evidence
/// only when it differs.
pub async fn retained_unchanged<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    channel: &str,
    payload: &[u8],
) -> Result<bool, String> {
    let parsed = if channel == "status" {
        rev2::status_object(payload)
    } else {
        rev2::object(payload)
    };
    let Ok(object) = parsed else {
        return Ok(false);
    };
    match channel {
        "status" => {
            let Ok(status) = rev2::parse_status(&object) else {
                return Ok(false);
            };
            let row = client
                .query_opt(
                    "SELECT link_state,link_state_t FROM devices WHERE device_id=$1",
                    &[&device],
                )
                .await
                .map_err(dberr("retained status"))?;
            let Some(row) = row else { return Ok(false) };
            let state: Option<String> = row.get(0);
            let stored_t: Option<i64> = row.get(1);
            let t = status.time.filter(|t| t.valid).map(|t| i64::from(t.t));
            if let (Some(t), Some(stored)) = (t, stored_t)
                && t < stored
            {
                return Ok(true);
            }
            Ok(state.as_deref() == Some(status.state.as_str()) && t == stored_t)
        }
        "info" => {
            let stored: Option<Value> = client
                .query_opt("SELECT info FROM devices WHERE device_id=$1", &[&device])
                .await
                .map_err(dberr("retained info"))?
                .and_then(|row| row.get(0));
            Ok(stored.as_ref() == Some(&Value::Object(object)))
        }
        _ => Ok(false),
    }
}

/// Stores one revision 2 message.
pub async fn store<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    payload: &[u8],
) -> Result<Outcome, String> {
    match ctx.channel {
        "data/stream" => return store_stream(client, ctx, payload).await,
        "data/file" => return store_file_chunk(client, ctx, payload).await,
        _ => {}
    }
    let parsed = if ctx.channel == "status" {
        rev2::status_object(payload)
    } else {
        rev2::object(payload)
    };
    let object = match parsed {
        Ok(object) => object,
        Err(error) => return Ok(Outcome::rejected(error)),
    };
    let mut outcome = match ctx.channel {
        "status" => store_status(client, ctx, &object).await?,
        "info" => store_info(client, ctx, &object).await?,
        "health" => store_health(client, ctx, &object).await?,
        "alerts" => store_alert(client, ctx, &object, payload).await?,
        "test/result" => store_test(client, ctx, &object, payload).await?,
        "reading" => store_reading(client, ctx, &object, payload).await?,
        "gps" => store_gps(client, ctx, &object, payload).await?,
        "config/applied" | "cmd/ack" => {
            crate::rev2_commands::handle_ack(client, ctx, &object).await?
        }
        other => Outcome::rejected(format!("{other} is not a revision 2 uplink channel")),
    };
    if !ctx.retained && outcome.rejected.is_none() {
        client
            .execute(
                "UPDATE devices SET last_seen=GREATEST(last_seen,$2),protocol_rev=2 WHERE device_id=$1",
                &[&ctx.device_id, &ctx.received_at],
            )
            .await
            .map_err(dberr("last seen"))?;
    }
    if outcome.rejected.is_none() {
        detect_profile(client, ctx, &mut outcome).await?;
    }
    Ok(outcome)
}

/// A unit enrolled as `V21` whose `gwl/v1` traffic is revision 2 is running
/// firmware 2.2: switch its enrollment and bindings to `V22` together (the
/// pair must always agree, see adapter.rs). Only units bound exclusively to
/// their own `gwl/v1/<DEV>/` topics qualify; identity still comes from the
/// binding, the payload only selects the wire contract.
async fn detect_profile<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    outcome: &mut Outcome,
) -> Result<(), String> {
    let promoted = client
        .query_opt(
            "WITH promoted AS (
                UPDATE devices d SET source_profile='V22'
                WHERE d.device_id=$1 AND d.revoked_at IS NULL AND groundwater_profile_id(d.source_profile)='V21'
                  AND EXISTS(SELECT 1 FROM device_bindings b WHERE b.device_id=d.device_id AND b.revoked_at IS NULL)
                  AND NOT EXISTS(SELECT 1 FROM device_bindings b WHERE b.device_id=d.device_id AND b.revoked_at IS NULL
                      AND b.topic NOT LIKE 'gwl/v1/'||d.device_id||'/%')
                RETURNING d.device_id),
             rebound AS (UPDATE device_bindings b SET source_profile='V22' FROM promoted p
                WHERE b.device_id=p.device_id AND b.revoked_at IS NULL RETURNING b.binding_key)
             INSERT INTO device_events(device_id,source,event,received_at,details)
             SELECT device_id,'server','profile_detected',$2,
                jsonb_build_object('from','V21','to','V22','channel',$3::text,
                    'bindings',(SELECT count(*) FROM rebound))
             FROM promoted RETURNING device_id",
            &[&ctx.device_id, &ctx.received_at, &ctx.channel],
        )
        .await
        .map_err(dberr("profile detection"))?;
    if promoted.is_some() {
        outcome.events.push(LiveEvent::DeviceEvent {
            device_id: ctx.device_id.to_owned(),
            event: "profile_detected".into(),
        });
    }
    Ok(())
}

async fn server_event<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    event: &str,
    at: DateTime<Utc>,
    details: Value,
) -> Result<(), String> {
    client
        .execute(
            "INSERT INTO device_events(device_id,source,event,received_at,recorded_at,time_source,details)
             VALUES($1,'server',$2,$3,$3,'server',$4)",
            &[&device, &event, &at, &details],
        )
        .await
        .map_err(dberr("server event"))?;
    Ok(())
}

async fn store_status<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
) -> Result<Outcome, String> {
    let status = match rev2::parse_status(object) {
        Ok(status) => status,
        Err(error) => return Ok(Outcome::rejected(error)),
    };
    let device_t = status.time.filter(|t| t.valid).map(|t| i64::from(t.t));
    // A live status happened now. A retained one is old: only the device's
    // own valid clock dates it, and without one it changes presence but
    // never triggers command re-publishing.
    let effective = if ctx.retained {
        device_t.map(utc)
    } else {
        Some(ctx.received_at)
    };
    let next = status.next.map(|n| utc(i64::from(n)));
    let up = status.up.map(i64::from).filter(|_| !ctx.retained);
    client
        .execute(
            "UPDATE devices SET link_state=$2,link_state_at=$3,link_state_t=$4,link_reason=$5,link_retained=$6,
                boot_count=COALESCE($7,boot_count),
                uptime_s=COALESCE($8,uptime_s),uptime_at=CASE WHEN $8::bigint IS NULL THEN uptime_at ELSE $9 END,
                next_contact_at=COALESCE($10,next_contact_at),
                listen_window_s=CASE WHEN $2='ready' THEN COALESCE($11,listen_window_s) ELSE listen_window_s END
             WHERE device_id=$1",
            &[
                &ctx.device_id,
                &status.state.as_str(),
                &effective.unwrap_or(ctx.received_at),
                &device_t,
                &status.reason,
                &ctx.retained,
                &status.boot.map(i64::from),
                &up,
                &ctx.received_at,
                &next,
                &status.win.map(|w| w as i32),
            ],
        )
        .await
        .map_err(dberr("status update"))?;
    let mut outcome = Outcome::default();
    outcome.events.push(LiveEvent::Presence {
        device_id: ctx.device_id.to_owned(),
    });
    if status.state == PresenceState::Offline && !ctx.retained {
        server_event(
            client,
            ctx.device_id,
            "link_lost",
            ctx.received_at,
            json!({"reason":status.reason}),
        )
        .await?;
    }
    if let Some(at) = effective {
        let changed =
            crate::rev2_commands::on_status(client, ctx.device_id, status.state, at, ctx.policy)
                .await?;
        if changed {
            outcome.events.push(LiveEvent::Command {
                device_id: ctx.device_id.to_owned(),
            });
        }
        // The logger finished its upload: ask for anything still missing
        // while it listens (`ready`), or queue it for the next connection.
        if !ctx.retained
            && matches!(status.state, PresenceState::Ready | PresenceState::Sleep)
            && request_gaps(client, ctx.device_id, ctx.received_at, ctx.policy).await?
        {
            outcome.events.push(LiveEvent::Command {
                device_id: ctx.device_id.to_owned(),
            });
        }
    }
    Ok(outcome)
}

async fn store_info<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
) -> Result<Outcome, String> {
    let text = |key| rev2::str_field(object, key).map(str::to_owned);
    let previous: Option<String> = client
        .query_opt(
            "SELECT fw_version FROM devices WHERE device_id=$1",
            &[&ctx.device_id],
        )
        .await
        .map_err(dberr("info lookup"))?
        .and_then(|row| row.get(0));
    let proto = rev2::i64_field(object, "proto").map(|p| p as i16);
    let schema = rev2::i64_field(object, "schema").map(|s| s as i32);
    let info = Value::Object(object.clone());
    client
        .execute(
            "UPDATE devices SET fw_version=$2,fw_build=$3,hw_version=$4,protocol_rev=COALESCE($5,protocol_rev),
                payload_schema=COALESCE($6,payload_schema),mcu_uid=$7,imei=$8,iccid=$9,modem=$10,network_name=$11,
                stream_encoding=$12,reset_cause=$13,info=$14,info_at=$15
             WHERE device_id=$1",
            &[
                &ctx.device_id,
                &text("fw"),
                &text("build"),
                &text("hw"),
                &proto,
                &schema,
                &text("uid"),
                &text("imei"),
                &text("iccid"),
                &text("modem"),
                &text("net"),
                &text("stream"),
                &text("reset"),
                &info,
                &ctx.received_at,
            ],
        )
        .await
        .map_err(dberr("info update"))?;
    if !ctx.retained {
        server_event(
            client,
            ctx.device_id,
            "boot",
            ctx.received_at,
            json!({"reset":text("reset"),"fw":text("fw"),"hw":text("hw")}),
        )
        .await?;
    }
    if previous.is_some() && previous != text("fw") {
        server_event(
            client,
            ctx.device_id,
            "firmware_changed",
            ctx.received_at,
            json!({"from":previous,"to":text("fw")}),
        )
        .await?;
    }
    Ok(Outcome {
        events: vec![LiveEvent::Presence {
            device_id: ctx.device_id.to_owned(),
        }],
        ..Outcome::default()
    })
}

async fn current_uptime<C: GenericClient + Sync>(
    client: &C,
    device: &str,
) -> Result<Option<(i64, DateTime<Utc>)>, String> {
    let row = client
        .query_opt(
            "SELECT uptime_s,uptime_at FROM devices WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(dberr("uptime lookup"))?;
    Ok(row.and_then(|row| {
        let up: Option<i64> = row.get(0);
        let at: Option<DateTime<Utc>> = row.get(1);
        up.zip(at)
    }))
}

async fn store_health<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
) -> Result<Outcome, String> {
    let health = rev2::parse_health(object);
    let valid = health.time.is_some_and(|t| t.valid);
    let (recorded_at, time_source) = match health.time.filter(|t| t.valid) {
        Some(time) => (utc(i64::from(time.t)), "device"),
        None => (ctx.received_at, "receipt"),
    };
    let next = health.next.map(|n| utc(i64::from(n)));
    let small = |v: Option<i64>| v.and_then(|v| i16::try_from(v).ok());
    let int = |v: Option<i64>| v.and_then(|v| i32::try_from(v).ok());
    client
        .execute(
            "INSERT INTO device_health(device_id,source,recorded_at,time_source,device_t,time_valid,received_at,
                uptime_s,csq,bat_mv,sol_mv,sd,sd_free_mb,mram,unsaved,usable,log,settings_gen,next_contact_at,err,payload,delivery_id)
             VALUES($1,'health',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)",
            &[
                &ctx.device_id,
                &recorded_at,
                &time_source,
                &health.time.map(|t| i64::from(t.t)),
                &health.time.map(|t| t.valid),
                &ctx.received_at,
                &health.up.map(i64::from),
                &small(health.csq),
                &int(health.bat_mv),
                &int(health.sol_mv),
                &health.sd,
                &int(health.sd_free_mb),
                &health.mram,
                &health.unsaved,
                &health.usable,
                &health.log,
                &health.settings_gen,
                &next,
                &int(health.err),
                &Value::Object(object.clone()),
                &ctx.delivery_id,
            ],
        )
        .await
        .map_err(dberr("health insert"))?;
    client
        .execute(
            "UPDATE devices SET health=$2,health_at=$3,
                uptime_s=COALESCE($4,uptime_s),uptime_at=CASE WHEN $4::bigint IS NULL THEN uptime_at ELSE $3 END,
                next_contact_at=COALESCE($5,next_contact_at)
             WHERE device_id=$1",
            &[
                &ctx.device_id,
                &Value::Object(rev2::normalised_health(object)),
                &ctx.received_at,
                &health.up.map(i64::from),
                &next,
            ],
        )
        .await
        .map_err(dberr("health state"))?;
    client
        .execute("SELECT groundwater_power_alerts($1)", &[&ctx.device_id])
        .await
        .map_err(dberr("power alerts"))?;
    let mut outcome = Outcome::default();
    outcome.events.push(LiveEvent::Health {
        device_id: ctx.device_id.to_owned(),
    });
    outcome.events.push(LiveEvent::Alert {
        device_id: ctx.device_id.to_owned(),
    });
    let skew = health
        .time
        .filter(|t| t.valid)
        .map(|t| i64::from(t.t) - ctx.received_at.timestamp());
    if crate::rev2_commands::maybe_sync_clock(client, ctx, valid, skew).await? {
        outcome.events.push(LiveEvent::Command {
            device_id: ctx.device_id.to_owned(),
        });
    }
    if crate::rev2_commands::maybe_restore_settings(client, ctx, &health).await? {
        outcome.events.push(LiveEvent::Command {
            device_id: ctx.device_id.to_owned(),
        });
    }
    if let Some(generation) = health.settings_gen
        && !crate::rev2_commands::settings_lost(&health)
        && crate::rev2_commands::maybe_fetch_settings(client, ctx, generation).await?
    {
        outcome.events.push(LiveEvent::Command {
            device_id: ctx.device_id.to_owned(),
        });
    }
    Ok(outcome)
}

/// Maps an `alerts` payload to the stored event name.
pub fn alert_event_name(object: &Map<String, Value>) -> Option<String> {
    let ev = rev2::str_field(object, "ev")?;
    let base = rev2::alert_event(ev)?;
    let state = rev2::str_field(object, "state");
    Some(match (ev, state, rev2::str_field(object, "kind")) {
        ("gwl_alarm", Some("exit"), _) => "gwl_alarm_exit".into(),
        ("gwl_alarm", _, _) => "gwl_alarm_enter".into(),
        ("storage", _, Some("tail_lock")) => "tail_lock".into(),
        ("storage", _, Some("tail_unlocked")) => "tail_unlocked".into(),
        _ => base.into(),
    })
}

async fn store_alert<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let Some(event) = alert_event_name(object) else {
        return Ok(Outcome::rejected(format!(
            "alert ev {:?} is not a contract event",
            rev2::str_field(object, "ev")
        )));
    };
    let uptime = current_uptime(client, ctx.device_id).await?;
    let placed = place_json(rev2::DeviceTime::from(object), ctx.received_at, uptime);
    let mut details = object.clone();
    for key in ["v", "t", "tv", "ev", "seq"] {
        details.remove(key);
    }
    let inserted = client
        .execute(
            "INSERT INTO device_events(device_id,source,event,seq,recorded_at,time_valid,time_rel_s,time_source,
                received_at,details,dedupe_key,delivery_id)
             VALUES($1,'alert',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING",
            &[
                &ctx.device_id,
                &event,
                &rev2::u32_field(object, "seq").map(i64::from),
                &placed.recorded_at,
                &placed.valid,
                &placed.rel,
                &placed.source,
                &ctx.received_at,
                &Value::Object(details),
                &digest(payload),
                &ctx.delivery_id,
            ],
        )
        .await
        .map_err(dberr("alert insert"))?;
    let mut outcome = Outcome::default();
    if inserted == 1 {
        outcome.events.push(LiveEvent::DeviceEvent {
            device_id: ctx.device_id.to_owned(),
            event,
        });
    } else {
        outcome.detail = Some("identical alert already stored".into());
    }
    Ok(outcome)
}

fn trigger_name(trigger: u8) -> &'static str {
    match trigger {
        1 => "button",
        2 => "remote",
        3 => "power_on",
        _ => "other",
    }
}

async fn store_test<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let uptime = current_uptime(client, ctx.device_id).await?;
    let mut placed = place_json(rev2::DeviceTime::from(object), ctx.received_at, uptime);
    if placed.recorded_at.is_none() {
        // A self-test result is published in the connection that ran it.
        placed.recorded_at = Some(ctx.received_at);
        placed.source = "receipt".into();
    }
    let mut details = Map::new();
    for key in [
        "sd", "sim", "net", "mqtt", "gps", "epd", "acc", "mram", "warn", "up",
    ] {
        if let Some(value) = object.get(key) {
            details.insert(key.into(), value.clone());
        }
    }
    let int = |key| rev2::i64_field(object, key).and_then(|v| i32::try_from(v).ok());
    let mv = |key| rev2::mv_field(object, key).and_then(|v| i32::try_from(v).ok());
    let inserted = client
        .query_opt(
            "INSERT INTO device_tests(device_id,source,recorded_at,time_valid,time_rel_s,time_source,received_at,
                trigger,command_id,battery_mv,solar_mv,csq,sensor_mv,sensor_ma,level,sensor_status,status_bits,ok,
                details,dedupe_key,delivery_id)
             VALUES($1,'json',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)
             ON CONFLICT DO NOTHING RETURNING id",
            &[
                &ctx.device_id,
                &placed.recorded_at,
                &placed.valid,
                &placed.rel,
                &placed.source,
                &ctx.received_at,
                &rev2::str_field(object, "trigger"),
                &rev2::i64_field(object, "id"),
                &mv("bat_mv"),
                &mv("sol_mv"),
                &rev2::csq_field(object, "csq").and_then(|v| i16::try_from(v).ok()),
                &mv("mv"),
                // The firmware sends ma 0 when the shunt was not read.
                &rev2::f64_field(object, "ma").filter(|_| mv("mv").is_some()),
                &rev2::f64_field(object, "lvl"),
                &rev2::i64_field(object, "ss").and_then(|v| i16::try_from(v).ok()),
                &int("status"),
                &object.get("ok").and_then(Value::as_bool),
                &Value::Object(details),
                &digest(payload),
                &ctx.delivery_id,
            ],
        )
        .await
        .map_err(dberr("test result insert"))?
        .map(|row| row.get::<_, i64>(0));
    if let Some(id) = inserted {
        pair_test(client, id).await?;
    }
    client
        .execute("SELECT groundwater_power_alerts($1)", &[&ctx.device_id])
        .await
        .map_err(dberr("power alerts"))?;
    let mut outcome = Outcome::default();
    if inserted.is_some() {
        outcome.events.push(LiveEvent::DeviceEvent {
            device_id: ctx.device_id.to_owned(),
            event: "test_result".into(),
        });
        outcome.events.push(LiveEvent::Alert {
            device_id: ctx.device_id.to_owned(),
        });
    }
    Ok(outcome)
}

/// Links a test's `test/result` JSON and its Type 5 record
/// (`groundwater_pair_test`), whichever arrives second.
async fn pair_test<C: GenericClient + Sync>(client: &C, id: i64) -> Result<(), String> {
    client
        .execute("SELECT groundwater_pair_test($1)", &[&id])
        .await
        .map_err(dberr("test pairing"))?;
    Ok(())
}

/// Column values of one observation row.
#[derive(Debug, Clone)]
pub struct ObservationRow {
    pub source: &'static str,
    pub payload_digest: String,
    pub recorded_at: Option<DateTime<Utc>>,
    pub time_reason: String,
    pub quality_reasons: Vec<String>,
    pub gwl: Option<f64>,
    pub gwl_text: Option<String>,
    pub battery_v: Option<f64>,
    pub solar_v: Option<f64>,
    pub csq: Option<i16>,
    pub duplicate_outcome: &'static str,
    pub duplicate_reason: String,
    pub payload: Value,
    pub log_id: Option<i64>,
    pub seq: Option<i64>,
    pub record_type: Option<i16>,
    pub sensor_mv: Option<i32>,
    pub sensor_status: Option<i16>,
    pub settings_gen: Option<i64>,
    pub reading_reason: Option<i16>,
    pub anchor: bool,
    pub interval_s: Option<i64>,
    pub sample_index: Option<i32>,
    pub time_valid: Option<bool>,
    pub time_rel_s: Option<i64>,
    pub time_source: Option<String>,
    pub json_key: Option<String>,
    pub device_time_text: Option<String>,
}

impl ObservationRow {
    fn empty(source: &'static str, payload_digest: String, payload: Value) -> Self {
        Self {
            source,
            payload_digest,
            recorded_at: None,
            time_reason: String::new(),
            quality_reasons: Vec::new(),
            gwl: None,
            gwl_text: None,
            battery_v: None,
            solar_v: None,
            csq: None,
            duplicate_outcome: "new",
            duplicate_reason: "unique record identity".into(),
            payload,
            log_id: None,
            seq: None,
            record_type: None,
            sensor_mv: None,
            sensor_status: None,
            settings_gen: None,
            reading_reason: None,
            anchor: false,
            interval_s: None,
            sample_index: None,
            time_valid: None,
            time_rel_s: None,
            time_source: None,
            json_key: None,
            device_time_text: None,
        }
    }
}

/// Inserts an observation; `None` when its identity already exists.
pub async fn insert_observation<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    delivery_id: Option<i64>,
    received_at: DateTime<Utc>,
    row: &ObservationRow,
) -> Result<Option<i64>, String> {
    let quality = time_quality(row.recorded_at, received_at);
    let lag = row.recorded_at.map(|at| (received_at - at).num_seconds());
    client
        .query_opt(
            "INSERT INTO observations(delivery_id,device_id,kind,payload_digest,recorded_at,received_at,device_time_text,
                time_quality,time_reason,offset_applied_min,zone_source,lag_seconds,interpretation_version,quality_reasons,
                gwl,gwl_text,battery_v,battery_truncated,solar_v,solar_truncated,duplicate_outcome,duplicate_reason,payload,
                source,log_id,seq,record_type,sensor_mv,sensor_status,settings_gen,reading_reason,anchor,interval_s,
                sample_index,time_valid,time_rel_s,time_source,json_key,csq)
             VALUES($1,$2,'water',$3,$4,$5,$6,$7,$8,NULL,'payload',$9,$10,$11,$12,$13,$14,false,$15,false,$16,$17,$18,
                $19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34)
             ON CONFLICT DO NOTHING RETURNING id",
            &[
                &delivery_id,
                &device,
                &row.payload_digest,
                &row.recorded_at,
                &received_at,
                &row.device_time_text,
                &quality,
                &row.time_reason,
                &lag,
                &INTERPRETATION,
                &row.quality_reasons,
                &row.gwl,
                &row.gwl_text,
                &row.battery_v,
                &row.solar_v,
                &row.duplicate_outcome,
                &row.duplicate_reason,
                &row.payload,
                &row.source,
                &row.log_id,
                &row.seq,
                &row.record_type,
                &row.sensor_mv,
                &row.sensor_status,
                &row.settings_gen,
                &row.reading_reason,
                &row.anchor,
                &row.interval_s,
                &row.sample_index,
                &row.time_valid,
                &row.time_rel_s,
                &row.time_source,
                &row.json_key,
                &row.csq,
            ],
        )
        .await
        .map(|row| row.map(|row| row.get(0)))
        .map_err(dberr("observation insert"))
}

fn sensor_reasons(status: Option<i16>, level: Option<f64>, reasons: &mut Vec<String>) {
    if let Some(status) = status.filter(|s| *s != 0) {
        reasons.push(format!(
            "sensor-{}",
            records::sensor_status_name(status as u8)
        ));
    }
    if level.is_none() {
        reasons.push("level-not-available".into());
    }
}

/// Fallback `reading` (MRAM absent/faulted): JSON, no ring identity. An
/// identical repeat is a redelivery; a different value at the same device
/// time is a visible conflict, as for revision 1.
async fn store_reading<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let time = rev2::DeviceTime::from(object);
    let mut row = ObservationRow::empty("json", digest(payload), Value::Object(object.clone()));
    row.json_key = Some(digest(payload));
    match time {
        Some(time) if time.valid => {
            row.recorded_at = Some(utc(i64::from(time.t)));
            row.time_valid = Some(true);
            row.time_source = Some("device".into());
            row.time_reason = "fallback reading with valid UTC time".into();
        }
        Some(time) => {
            row.time_valid = Some(false);
            row.time_rel_s = Some(i64::from(time.t));
            row.time_source = Some("relative".into());
            row.time_reason =
                "seconds since boot; a fallback reading carries no boot identity to convert it"
                    .into();
        }
        None => row.time_reason = "fallback reading without t".into(),
    }
    row.device_time_text = time.map(|t| format!("t={};tv={}", t.t, u8::from(t.valid)));
    row.gwl = rev2::f64_field(object, "lvl");
    row.gwl_text = object
        .get("lvl")
        .filter(|v| v.is_number())
        .map(Value::to_string);
    row.sensor_mv = rev2::mv_field(object, "mv").and_then(|v| i32::try_from(v).ok());
    row.sensor_status = rev2::i64_field(object, "ss").and_then(|v| i16::try_from(v).ok());
    row.battery_v = rev2::mv_field(object, "bat_mv").map(|v| v as f64 / 1000.0);
    row.solar_v = rev2::mv_field(object, "sol_mv").map(|v| v as f64 / 1000.0);
    row.csq = rev2::csq_field(object, "csq").and_then(|v| i16::try_from(v).ok());
    row.settings_gen = rev2::i64_field(object, "gen");
    sensor_reasons(row.sensor_status, row.gwl, &mut row.quality_reasons);
    row.quality_reasons.push("fallback-json".into());
    if let Some(at) = row.recorded_at {
        let conflict = client
            .query_opt(
                "SELECT 1 FROM observations WHERE device_id=$1 AND source='json' AND recorded_at=$2 AND json_key<>$3 LIMIT 1",
                &[&ctx.device_id, &at, &row.json_key],
            )
            .await
            .map_err(dberr("fallback conflict"))?
            .is_some();
        if conflict {
            row.duplicate_outcome = "conflict";
            row.duplicate_reason = "a different fallback reading has the same device time".into();
        }
    }
    let id = insert_observation(
        client,
        ctx.device_id,
        ctx.delivery_id,
        ctx.received_at,
        &row,
    )
    .await?;
    let mut outcome = Outcome::default();
    match id {
        Some(_) => outcome.events.push(LiveEvent::Observation {
            device_id: ctx.device_id.to_owned(),
            recorded_at: row.recorded_at,
            gwl: row.gwl,
        }),
        None => {
            outcome.detail = Some("identical fallback reading already stored".into());
            outcome.events.push(LiveEvent::Redelivery {
                device_id: ctx.device_id.to_owned(),
            });
        }
    }
    Ok(outcome)
}

async fn store_gps<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let placed = place_json(rev2::DeviceTime::from(object), ctx.received_at, None);
    let placed = if placed.source == "receipt" {
        Placed {
            recorded_at: None,
            ..placed
        }
    } else {
        placed
    };
    let small = |key| rev2::i64_field(object, key).and_then(|v| i16::try_from(v).ok());
    // Not-available markers (INT32_MIN e-7 degrees, INT16_MIN metres, the
    // u16 HDOP marker) are never a place: keep the raw JSON, store NULL.
    let lat = rev2::f64_field(object, "lat");
    let lon = rev2::f64_field(object, "lon");
    let (lat, lon) = match (lat, lon) {
        (Some(lat), Some(lon)) if lat.abs() <= 90.0 && lon.abs() <= 180.0 => (Some(lat), Some(lon)),
        _ => (None, None),
    };
    let alt = rev2::i64_field(object, "alt")
        .filter(|&v| v != i64::from(i16::MIN))
        .and_then(|v| i32::try_from(v).ok());
    let hdop = rev2::f64_field(object, "hdop").filter(|v| (0.0..99.99).contains(v));
    // The JSON sends the ring record's fix + 1 (1 none, 2 2D, 3 3D); stored
    // on the record scale so every source reads alike (rev2.sql).
    let fix = small("fix").and_then(|v| (1..=3).contains(&v).then(|| v - 1));
    let inserted = client
        .execute(
            "INSERT INTO device_positions(device_id,source,recorded_at,time_valid,time_rel_s,time_source,received_at,
                fix,lat,lon,alt_m,hdop,satellites,dedupe_key,delivery_id)
             VALUES($1,'json',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) ON CONFLICT DO NOTHING",
            &[
                &ctx.device_id,
                &placed.recorded_at,
                &placed.valid,
                &placed.rel,
                &placed.source,
                &ctx.received_at,
                &fix,
                &lat,
                &lon,
                &alt,
                &hdop,
                &small("sats"),
                &digest(payload),
                &ctx.delivery_id,
            ],
        )
        .await
        .map_err(dberr("position insert"))?;
    let mut outcome = Outcome::default();
    if inserted == 1 {
        outcome.events.push(LiveEvent::DeviceEvent {
            device_id: ctx.device_id.to_owned(),
            event: "position".into(),
        });
    }
    Ok(outcome)
}

#[allow(clippy::too_many_arguments)]
async fn insert_batch_row<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    encoding: &str,
    raw: &[u8],
    error: Option<String>,
    header: Option<&stream::BatchHeader>,
    issues: Value,
    warnings: Value,
) -> Result<i64, String> {
    let h = header;
    client
        .query_one(
            "INSERT INTO stream_batches(device_id,delivery_id,received_at,channel,encoding,raw,size,ok,error,
                log_id,payload_schema,first_seq,last_seq,start_pos,end_pos,frame_count,flags,issues,warnings)
             VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19) RETURNING id",
            &[
                &ctx.device_id,
                &ctx.delivery_id,
                &ctx.received_at,
                &ctx.channel,
                &encoding,
                &raw,
                &(raw.len() as i32),
                &error.is_none(),
                &error,
                &h.map(|h| i64::from(h.log_id)),
                &h.map(|h| i32::from(h.payload_schema)),
                &h.map(|h| i64::from(h.first_seq)),
                &h.map(|h| i64::from(h.last_seq)),
                &h.map(|h| i64::from(h.start_pos)),
                &h.map(|h| i64::from(h.end_pos)),
                &h.map(|h| i32::from(h.frame_count)),
                &h.map(|h| i16::from(h.flags)),
                &issues,
                &warnings,
            ],
        )
        .await
        .map(|row| row.get(0))
        .map_err(dberr("batch insert"))
}

async fn store_stream<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let (bytes, encoding) = match stream::decode_payload(payload, stream::BATCH_MAGIC) {
        Ok(decoded) => decoded,
        Err(error) => {
            insert_batch_row(
                client,
                ctx,
                "unknown",
                payload,
                Some(format!("{}: {error}", error.code())),
                None,
                json!([]),
                json!([]),
            )
            .await?;
            return Ok(Outcome::rejected(format!("{}: {error}", error.code())));
        }
    };
    let batch = match stream::parse_batch(&bytes) {
        Ok(batch) => batch,
        Err(error) => {
            insert_batch_row(
                client,
                ctx,
                encoding.as_str(),
                &bytes,
                Some(format!("{}: {error}", error.code())),
                None,
                json!([]),
                json!([]),
            )
            .await?;
            return Ok(Outcome::rejected(format!("{}: {error}", error.code())));
        }
    };
    let header = batch.header;
    let mut warnings = batch.warnings.clone();
    let supported = header.envelope_version == stream::ENVELOPE_VERSION
        && stream::SUPPORTED_PAYLOAD_SCHEMAS.contains(&header.payload_schema);
    if !supported {
        warnings.push(format!(
            "envelope {} / payload schema {} has no decoder; frames kept raw",
            header.envelope_version, header.payload_schema
        ));
    }
    if header.gap_before() {
        warnings.push(
            "flag: the logger permanently missed frames before start_pos for this destination"
                .into(),
        );
    }
    let batch_id = insert_batch_row(
        client,
        ctx,
        encoding.as_str(),
        &bytes,
        None,
        Some(&header),
        serde_json::to_value(&batch.issues).unwrap_or_default(),
        json!(warnings),
    )
    .await?;
    let log_id = i64::from(header.log_id);
    client
        .execute(
            "INSERT INTO stream_logs(device_id,log_id,payload_schema,first_received_at,last_received_at)
             VALUES($1,$2,$3,$4,$4)
             ON CONFLICT(device_id,log_id) DO UPDATE SET last_received_at=GREATEST(stream_logs.last_received_at,EXCLUDED.last_received_at),
                payload_schema=COALESCE(stream_logs.payload_schema,EXCLUDED.payload_schema)",
            &[&ctx.device_id, &log_id, &i32::from(header.payload_schema), &ctx.received_at],
        )
        .await
        .map_err(dberr("log upsert"))?;
    let mut fresh = 0i32;
    let mut duplicates = 0i32;
    let mut conflicts = 0;
    let mut new_seqs: Vec<i64> = Vec::new();
    let mut positioned: Vec<i64> = Vec::new();
    let mut to_derive: Vec<&stream::Frame> = Vec::new();
    // Raw first: every CRC-valid frame is stored byte-exact before anything
    // is derived from it. The logger frees its MRAM once the broker has this
    // message, so nothing derived below may cost these rows.
    for frame in &batch.frames {
        let seq = i64::from(frame.seq);
        // The CTE reads the stored row before the upsert: a copy that brings
        // the first position for a frame stored without one changes gap
        // detection (a seq skip with contiguous positions is not a gap).
        let row = client
            .query_one(
                "WITH old AS (SELECT pos FROM stream_frames WHERE device_id=$1 AND log_id=$2 AND seq=$3)
                 INSERT INTO stream_frames(device_id,log_id,seq,record_type,pos,size,raw,payload_schema,batch_id,received_at)
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
                 ON CONFLICT(device_id,log_id,seq) DO UPDATE SET copies=stream_frames.copies+1,
                    conflicting_copies=stream_frames.conflicting_copies+CASE WHEN stream_frames.raw<>EXCLUDED.raw THEN 1 ELSE 0 END,
                    pos=COALESCE(stream_frames.pos,EXCLUDED.pos)
                 RETURNING xmax::text='0', raw=$7,
                    COALESCE((SELECT old.pos IS NULL FROM old),false) AND $5::bigint IS NOT NULL",
                &[
                    &ctx.device_id,
                    &log_id,
                    &seq,
                    &i16::from(frame.record_type),
                    &frame.pos.map(i64::from),
                    &(frame.size() as i32),
                    &frame.raw,
                    &i32::from(header.payload_schema),
                    &batch_id,
                    &ctx.received_at,
                ],
            )
            .await
            .map_err(dberr("frame upsert"))?;
        let inserted: bool = row.get(0);
        if !inserted && row.get::<_, bool>(2) {
            positioned.push(seq);
        }
        if !inserted {
            duplicates += 1;
            if !row.get::<_, bool>(1) {
                conflicts += 1;
            }
            continue;
        }
        fresh += 1;
        new_seqs.push(seq);
        if supported {
            to_derive.push(frame);
        }
    }
    if conflicts > 0 {
        warnings.push(format!(
            "{conflicts} frame(s) repeat a stored (log_id, seq) with different bytes; the first copy is kept"
        ));
    }
    client
        .execute(
            "UPDATE stream_batches SET frames_valid=$2,frames_new=$3,frames_duplicate=$4,warnings=$5 WHERE id=$1",
            &[
                &batch_id,
                &(batch.frames.len() as i32),
                &fresh,
                &duplicates,
                &json!(warnings),
            ],
        )
        .await
        .map_err(dberr("batch counts"))?;
    let mut outcome = Outcome {
        detail: Some(format!(
            "log {:08X} seq {}..{}: {} new, {} duplicate, {} damaged{}{}",
            header.log_id,
            header.first_seq,
            header.last_seq,
            fresh,
            duplicates,
            batch.issues.len(),
            if header.resend() { "; resend" } else { "" },
            if header.read_from_sd() {
                "; read from SD"
            } else {
                ""
            }
        )),
        ..Outcome::default()
    };
    let gap_seqs = new_seqs.iter().chain(&positioned);
    let gaps = gap_seqs.clone().min().copied().zip(gap_seqs.max().copied());
    if gaps.is_some() {
        let derived = derive_frames(client, ctx, log_id, &to_derive, false).await?;
        let log_error = derive_log(
            client,
            ctx,
            log_id,
            gaps,
            !new_seqs.is_empty(),
            &derived.generations,
            derived.tests,
            false,
        )
        .await?;
        let mut errors = derived.failures.clone();
        errors.extend(log_error.map(|e| format!("log: {e}")));
        if !errors.is_empty() {
            let text = format!(
                "derived data failed ({}); raw frames kept and flagged for re-derivation at the next start",
                errors.join("; ")
            );
            client
                .execute(
                    "UPDATE stream_batches SET derive_error=$2 WHERE id=$1",
                    &[&batch_id, &text],
                )
                .await
                .map_err(dberr("derive error"))?;
            if let Some(detail) = &mut outcome.detail {
                detail.push_str("; ");
                detail.push_str(&text);
            }
        }
        if new_seqs.is_empty() {
            return Ok(outcome);
        }
        if derived.tests {
            outcome.events.push(LiveEvent::Alert {
                device_id: ctx.device_id.to_owned(),
            });
        }
        outcome.events.push(LiveEvent::Stream {
            device_id: ctx.device_id.to_owned(),
            new_frames: fresh as u32,
        });
        for event in derived.events {
            outcome.events.push(LiveEvent::DeviceEvent {
                device_id: ctx.device_id.to_owned(),
                event,
            });
        }
    }
    Ok(outcome)
}

/// What deriving records from stored frames produced.
#[derive(Default)]
struct Derived {
    generations: Vec<i64>,
    tests: bool,
    events: Vec<String>,
    /// `seq N: error` for frames whose derived rows could not be stored.
    failures: Vec<String>,
}

/// Decodes stored frames into observations, events and the other record
/// tables, each in its own savepoint. A frame whose derived rows fail for a
/// reason in the data keeps its raw row, flagged `derive_pending` with the
/// error; a transient failure (connection, deadlock) fails the message so
/// it is retried. `rerun` clears the flag of frames that now succeed.
async fn derive_frames<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    log_id: i64,
    frames: &[&stream::Frame],
    rerun: bool,
) -> Result<Derived, String> {
    let mut derived = Derived::default();
    for frame in frames {
        let seq = i64::from(frame.seq);
        let record = match records::decode(frame.record_type, &frame.payload) {
            Ok(record) => record,
            Err(error) => {
                client
                    .execute(
                        "UPDATE stream_frames SET decode_error=$4,derive_pending=false WHERE device_id=$1 AND log_id=$2 AND seq=$3",
                        &[&ctx.device_id, &log_id, &seq, &error.to_string()],
                    )
                    .await
                    .map_err(dberr("decode error"))?;
                continue;
            }
        };
        savepoint(client, "rev2_frame").await?;
        let stored = store_record(client, ctx, log_id, frame, &record).await;
        match stored {
            Ok(kind) => {
                end_savepoint(client, "rev2_frame", true).await?;
                match kind {
                    Stored::SettingsFragment(generation) => derived.generations.push(generation),
                    Stored::Test => derived.tests = true,
                    Stored::Event(name) => derived.events.push(name),
                    Stored::Other => {}
                }
                if rerun {
                    client
                        .execute(
                            "UPDATE stream_frames SET derive_pending=false,derive_error=NULL
                             WHERE device_id=$1 AND log_id=$2 AND seq=$3",
                            &[&ctx.device_id, &log_id, &seq],
                        )
                        .await
                        .map_err(dberr("derive pending"))?;
                }
            }
            Err(error) if transient_error(&error) => return Err(error),
            Err(error) => {
                end_savepoint(client, "rev2_frame", false).await?;
                client
                    .execute(
                        "UPDATE stream_frames SET derive_pending=true,derive_error=$4
                         WHERE device_id=$1 AND log_id=$2 AND seq=$3",
                        &[&ctx.device_id, &log_id, &seq, &error],
                    )
                    .await
                    .map_err(dberr("derive pending"))?;
                derived.failures.push(format!("seq {seq}: {error}"));
            }
        }
    }
    derived.generations.sort_unstable();
    derived.generations.dedup();
    Ok(derived)
}

/// Log-level derived work: gaps around `gaps` (min, max seq of new or newly
/// positioned frames) and, when `resolve` (new frames), settings snapshots,
/// record times and power alerts. Gap detection runs in its own savepoint,
/// so a failure in the later steps never costs this range's gap scan.
/// Returns the error when a step failed for a reason in the data; the log is
/// then flagged `resolve_pending` (and `gaps_pending` when the gap scan
/// failed: no reading is paired until the whole log has been scanned).
///
/// Only a `whole` run (the re-run over the log's full seq range and every
/// settings generation) clears the flags: a later batch's success covers
/// its own range only, not the work the failed batch lost.
#[allow(clippy::too_many_arguments)]
async fn derive_log<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    log_id: i64,
    gaps: Option<(i64, i64)>,
    resolve: bool,
    generations: &[i64],
    tests: bool,
    whole: bool,
) -> Result<Option<String>, String> {
    let mut failed: Vec<String> = Vec::new();
    let mut gaps_scanned = gaps.is_some() || !whole;
    let mut deferred = false;
    if let Some((min, max)) = gaps {
        savepoint(client, "rev2_gaps").await?;
        let scanned = async {
            detect_gaps(client, ctx.device_id, log_id, min, max, ctx.received_at).await?;
            if whole {
                client
                    .execute(
                        "UPDATE stream_logs SET gaps_pending=false WHERE device_id=$1 AND log_id=$2 AND gaps_pending",
                        &[&ctx.device_id, &log_id],
                    )
                    .await
                    .map_err(dberr("gaps pending"))?;
            }
            Ok::<(), String>(())
        }
        .await;
        match scanned {
            Ok(()) => end_savepoint(client, "rev2_gaps", true).await?,
            Err(error) if transient_error(&error) => return Err(error),
            Err(error) => {
                end_savepoint(client, "rev2_gaps", false).await?;
                client
                    .execute(
                        "UPDATE stream_logs SET gaps_pending=true WHERE device_id=$1 AND log_id=$2",
                        &[&ctx.device_id, &log_id],
                    )
                    .await
                    .map_err(dberr("gaps pending"))?;
                gaps_scanned = false;
                failed.push(error);
            }
        }
    }
    if resolve {
        // Settings and times in separate savepoints: a snapshot the database
        // refuses (a NUL in a text setting) must not cost the times.
        savepoint(client, "rev2_settings").await?;
        let result = async {
            for generation in generations {
                assemble_settings(client, ctx, *generation).await?;
            }
            activate_snapshot_settings(client, ctx).await
        }
        .await;
        match result {
            Ok(()) => end_savepoint(client, "rev2_settings", true).await?,
            Err(error) if transient_error(&error) => return Err(error),
            Err(error) => {
                end_savepoint(client, "rev2_settings", false).await?;
                failed.push(error);
            }
        }
        savepoint(client, "rev2_log").await?;
        let result = async {
            // A batch dates the runs from its first new frame on; the
            // re-run the whole log, in steps, and every paired reading.
            let pair = if whole {
                gaps_scanned
            } else {
                gaps_scanned
                    && !client
                        .query_one(
                            "SELECT gaps_pending FROM stream_logs WHERE device_id=$1 AND log_id=$2",
                            &[&ctx.device_id, &log_id],
                        )
                        .await
                        .map_err(dberr("gaps pending"))?
                        .get::<_, bool>(0)
            };
            let scope = if whole {
                None
            } else {
                gaps.map(|(min, _)| min)
            };
            let budget = if whole {
                RESOLVE_RERUN_BUDGET
            } else {
                RESOLVE_BATCH_BUDGET
            };
            loop {
                let done: bool = client
                    .query_one(
                        "SELECT groundwater_resolve_log($1,$2,$3,$4,$5)",
                        &[&ctx.device_id, &log_id, &scope, &budget, &pair],
                    )
                    .await
                    .map_err(dberr("time resolution"))?
                    .get(0);
                if done {
                    break;
                }
                if !whole {
                    deferred = true;
                    break;
                }
            }
            if whole {
                let mut after: Option<i64> = Some(-1);
                while after.is_some() {
                    after = client
                        .query_one(
                            "SELECT groundwater_retime_log($1,$2,$3,$4)",
                            &[&ctx.device_id, &log_id, &after, &RESOLVE_RERUN_BUDGET],
                        )
                        .await
                        .map_err(dberr("retiming"))?
                        .get(0);
                }
            }
            if tests {
                client
                    .execute("SELECT groundwater_power_alerts($1)", &[&ctx.device_id])
                    .await
                    .map_err(dberr("power alerts"))?;
            }
            Ok::<(), String>(())
        }
        .await;
        match result {
            Ok(()) => end_savepoint(client, "rev2_log", true).await?,
            Err(error) if transient_error(&error) => return Err(error),
            Err(error) => {
                end_savepoint(client, "rev2_log", false).await?;
                failed.push(error);
            }
        }
    }
    if !failed.is_empty() {
        let error = failed.join("; ");
        client
            .execute(
                "UPDATE stream_logs SET resolve_pending=true,resolve_error=$3 WHERE device_id=$1 AND log_id=$2",
                &[&ctx.device_id, &log_id, &error],
            )
            .await
            .map_err(dberr("resolve pending"))?;
        return Ok(Some(error));
    }
    if deferred {
        // Not an error: the re-run dates the rest.
        client
            .execute(
                "UPDATE stream_logs SET resolve_pending=true WHERE device_id=$1 AND log_id=$2",
                &[&ctx.device_id, &log_id],
            )
            .await
            .map_err(dberr("resolve pending"))?;
    }
    if whole && resolve {
        client
            .execute(
                "UPDATE stream_logs SET resolve_pending=false,resolve_error=NULL
                 WHERE device_id=$1 AND log_id=$2 AND resolve_pending",
                &[&ctx.device_id, &log_id],
            )
            .await
            .map_err(dberr("resolve pending"))?;
    }
    Ok(None)
}

/// Re-runs derived work that failed for a reason in the data (frames
/// flagged `derive_pending`, logs flagged `resolve_pending`), one log per
/// transaction. Called at start, before ingest runs. Returns (logs
/// re-derived, logs that still fail).
pub async fn rederive_pending(
    client: &mut tokio_postgres::Client,
    policy: &Rev2Policy,
) -> Result<(usize, usize), String> {
    let logs = client
        .query(
            "SELECT device_id,log_id FROM stream_frames WHERE derive_pending
             UNION SELECT device_id,log_id FROM stream_logs WHERE resolve_pending",
            &[],
        )
        .await
        .map_err(dberr("pending derivations"))?;
    let (mut done, mut failing) = (0, 0);
    for row in logs {
        let device: String = row.get(0);
        let log_id: i64 = row.get(1);
        let tx = client
            .transaction()
            .await
            .map_err(dberr("re-derive transaction"))?;
        let frames = tx
            .query(
                "SELECT f.raw,f.received_at,b.delivery_id FROM stream_frames f
                 LEFT JOIN stream_batches b ON b.id=f.batch_id
                 WHERE f.device_id=$1 AND f.log_id=$2 AND f.derive_pending ORDER BY f.seq",
                &[&device, &log_id],
            )
            .await
            .map_err(dberr("pending frames"))?;
        let mut still = false;
        for frame_row in frames {
            let raw: Vec<u8> = frame_row.get(0);
            let ctx = Context {
                device_id: &device,
                channel: "data/stream",
                received_at: frame_row.get(1),
                retained: false,
                delivery_id: frame_row.get(2),
                policy,
            };
            let Some(frame) = stream::split_frames(&raw).0.into_iter().next() else {
                continue;
            };
            let derived = derive_frames(&tx, &ctx, log_id, &[&frame], true).await?;
            still |= !derived.failures.is_empty();
        }
        let bounds = tx
            .query_one(
                "SELECT min(seq),max(seq),ARRAY(SELECT DISTINCT settings_gen FROM settings_fragments
                    WHERE device_id=$1 AND log_id=$2 ORDER BY 1)
                 FROM stream_frames WHERE device_id=$1 AND log_id=$2",
                &[&device, &log_id],
            )
            .await
            .map_err(dberr("log bounds"))?;
        let (min, max): (Option<i64>, Option<i64>) = (bounds.get(0), bounds.get(1));
        let generations: Vec<i64> = bounds.get(2);
        if let (Some(min), Some(max)) = (min, max) {
            let ctx = Context {
                device_id: &device,
                channel: "data/stream",
                received_at: Utc::now(),
                retained: false,
                delivery_id: None,
                policy,
            };
            still |= derive_log(
                &tx,
                &ctx,
                log_id,
                Some((min, max)),
                true,
                &generations,
                true,
                true,
            )
            .await?
            .is_some();
        }
        tx.commit().await.map_err(dberr("re-derive commit"))?;
        if still {
            failing += 1;
        } else {
            done += 1;
        }
    }
    Ok((done, failing))
}

enum Stored {
    SettingsFragment(i64),
    Test,
    Event(String),
    Other,
}

async fn insert_event<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    log_id: i64,
    frame: &stream::Frame,
    event: &str,
    time: Option<TimeBlock>,
    details: Value,
) -> Result<(), String> {
    let placed = time.map(place);
    client
        .execute(
            "INSERT INTO device_events(device_id,source,event,log_id,seq,record_type,recorded_at,time_valid,time_rel_s,
                time_source,received_at,details,delivery_id)
             VALUES($1,'record',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) ON CONFLICT DO NOTHING",
            &[
                &ctx.device_id,
                &event,
                &log_id,
                &i64::from(frame.seq),
                &i16::from(frame.record_type),
                &placed.as_ref().and_then(|p| p.recorded_at),
                &placed.as_ref().map(|p| p.valid),
                &placed.as_ref().and_then(|p| p.rel),
                &placed.as_ref().map(|p| p.source.clone()),
                &ctx.received_at,
                &details,
                &ctx.delivery_id,
            ],
        )
        .await
        .map_err(dberr("event insert"))?;
    Ok(())
}

async fn store_record<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    log_id: i64,
    frame: &stream::Frame,
    record: &Record,
) -> Result<Stored, String> {
    let seq = i64::from(frame.seq);
    let record_json = serde_json::to_value(record).unwrap_or(Value::Null);
    match record {
        Record::Routine {
            sample_index,
            sensor,
        } => {
            let mut row = ObservationRow::empty("stream", digest(&frame.raw), record_json);
            row.log_id = Some(log_id);
            row.seq = Some(seq);
            row.record_type = Some(0);
            row.sample_index = Some(i32::from(*sample_index));
            row.gwl = sensor.level();
            row.gwl_text = sensor.level().map(|l| format!("{l:.3}"));
            row.sensor_mv = sensor.sensor_mv.map(i32::from);
            row.sensor_status = Some(i16::from(sensor.sensor_status));
            row.time_reason = "awaiting the anchor before this reading".into();
            sensor_reasons(row.sensor_status, row.gwl, &mut row.quality_reasons);
            insert_observation(
                client,
                ctx.device_id,
                ctx.delivery_id,
                ctx.received_at,
                &row,
            )
            .await?;
            Ok(Stored::Other)
        }
        Record::Timestamped {
            time,
            settings_gen,
            reason,
            flags,
            interval_s,
            sensor,
        } => {
            let placed = place(*time);
            let mut row = ObservationRow::empty("stream", digest(&frame.raw), record_json);
            row.log_id = Some(log_id);
            row.seq = Some(seq);
            row.record_type = Some(1);
            row.recorded_at = placed.recorded_at;
            row.time_valid = Some(placed.valid);
            row.time_rel_s = placed.rel;
            row.time_source = Some(placed.source.clone());
            row.time_reason = if placed.valid {
                format!("device UTC ({})", placed.source)
            } else {
                "seconds since boot; awaiting a clock-set record".into()
            };
            row.device_time_text = Some(format!("t={};tv={}", time.time, u8::from(placed.valid)));
            row.settings_gen = Some(i64::from(*settings_gen));
            row.reading_reason = Some(i16::from(*reason));
            row.anchor = flags & 1 != 0;
            row.interval_s = Some(i64::from(*interval_s));
            row.gwl = sensor.level();
            row.gwl_text = sensor.level().map(|l| format!("{l:.3}"));
            row.sensor_mv = sensor.sensor_mv.map(i32::from);
            row.sensor_status = Some(i16::from(sensor.sensor_status));
            sensor_reasons(row.sensor_status, row.gwl, &mut row.quality_reasons);
            insert_observation(
                client,
                ctx.device_id,
                ctx.delivery_id,
                ctx.received_at,
                &row,
            )
            .await?;
            Ok(Stored::Other)
        }
        Record::Position {
            time,
            settings_gen,
            reason,
            fix,
            lat,
            lon,
            alt_m,
            hdop,
            satellites,
            accel_x_mg,
            accel_y_mg,
            accel_z_mg,
            accel_status,
        } => {
            let placed = place(*time);
            client
                .execute(
                    "INSERT INTO device_positions(device_id,source,log_id,seq,recorded_at,time_valid,time_rel_s,time_source,
                        received_at,settings_gen,reason,fix,lat,lon,alt_m,hdop,satellites,accel_x_mg,accel_y_mg,accel_z_mg,
                        accel_status,delivery_id)
                     VALUES($1,'record',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)
                     ON CONFLICT DO NOTHING RETURNING id",
                    &[
                        &ctx.device_id,
                        &log_id,
                        &seq,
                        &placed.recorded_at,
                        &placed.valid,
                        &placed.rel,
                        &placed.source,
                        &ctx.received_at,
                        &i64::from(*settings_gen),
                        &i16::from(*reason),
                        &i16::from(*fix),
                        lat,
                        lon,
                        &alt_m.map(i32::from),
                        hdop,
                        &i16::from(*satellites),
                        &accel_x_mg.map(i32::from),
                        &accel_y_mg.map(i32::from),
                        &accel_z_mg.map(i32::from),
                        &i16::from(*accel_status),
                        &ctx.delivery_id,
                    ],
                )
                .await
                .map_err(dberr("position record"))?;
            Ok(Stored::Event("position".into()))
        }
        Record::Snapshot {
            backup,
            settings_gen,
            settings_schema,
            fragment_index,
            fragment_count,
            total_len,
            snapshot_crc32,
            data,
        } => {
            client
                .execute(
                    "INSERT INTO settings_fragments(device_id,log_id,seq,backup,settings_gen,settings_schema,fragment_index,
                        fragment_count,total_len,snapshot_crc32,data)
                     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING",
                    &[
                        &ctx.device_id,
                        &log_id,
                        &seq,
                        backup,
                        &i64::from(*settings_gen),
                        &i16::from(*settings_schema),
                        &i16::from(*fragment_index),
                        &i16::from(*fragment_count),
                        &i32::from(*total_len),
                        &i64::from(*snapshot_crc32),
                        data,
                    ],
                )
                .await
                .map_err(dberr("settings fragment"))?;
            Ok(Stored::SettingsFragment(i64::from(*settings_gen)))
        }
        Record::Test {
            time,
            settings_gen,
            trigger,
            req_id,
            battery_mv,
            solar_mv,
            csq,
            sensor,
            status,
        } => {
            let placed = place(*time);
            let ok = test_passed(*status);
            let inserted = client
                .query_opt(
                    "INSERT INTO device_tests(device_id,source,log_id,seq,recorded_at,time_valid,time_rel_s,time_source,
                        received_at,settings_gen,trigger,command_id,battery_mv,solar_mv,csq,sensor_mv,level,sensor_status,
                        status_bits,ok,details,delivery_id)
                     VALUES($1,'record',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)
                     ON CONFLICT DO NOTHING RETURNING id",
                    &[
                        &ctx.device_id,
                        &log_id,
                        &seq,
                        &placed.recorded_at,
                        &placed.valid,
                        &placed.rel,
                        &placed.source,
                        &ctx.received_at,
                        &i64::from(*settings_gen),
                        &trigger_name(*trigger),
                        &(*req_id != 0).then_some(i64::from(*req_id)),
                        &battery_mv.map(i32::from),
                        &solar_mv.map(i32::from),
                        &csq.map(i16::from),
                        &sensor.sensor_mv.map(i32::from),
                        &sensor.level(),
                        &i16::from(sensor.sensor_status),
                        &i32::from(*status),
                        &ok,
                        &json!({"status_flags":test_status_flags(*status)}),
                        &ctx.delivery_id,
                    ],
                )
                .await
                .map_err(dberr("test record"))?;
            if let Some(row) = inserted {
                pair_test(client, row.get(0)).await?;
            }
            Ok(Stored::Test)
        }
        Record::Tilt {
            time,
            settings_gen,
            reason,
            accel_x_mg,
            accel_y_mg,
            accel_z_mg,
            pitch_decideg,
            roll_decideg,
            accel_status,
        } => {
            let placed = place(*time);
            client
                .execute(
                    "INSERT INTO device_tilt(device_id,log_id,seq,recorded_at,time_valid,time_rel_s,time_source,received_at,
                        settings_gen,reason,accel_x_mg,accel_y_mg,accel_z_mg,pitch_deg,roll_deg,accel_status)
                     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16) ON CONFLICT DO NOTHING",
                    &[
                        &ctx.device_id,
                        &log_id,
                        &seq,
                        &placed.recorded_at,
                        &placed.valid,
                        &placed.rel,
                        &placed.source,
                        &ctx.received_at,
                        &i64::from(*settings_gen),
                        &i16::from(*reason),
                        &accel_x_mg.map(i32::from),
                        &accel_y_mg.map(i32::from),
                        &accel_z_mg.map(i32::from),
                        &pitch_decideg.map(|v| f64::from(v) / 10.0),
                        &roll_decideg.map(|v| f64::from(v) / 10.0),
                        &i16::from(*accel_status),
                    ],
                )
                .await
                .map_err(dberr("tilt record"))?;
            Ok(Stored::Event("tilt".into()))
        }
        Record::Reserved { record_type } | Record::BenchOnly { record_type } => {
            insert_event(
                client,
                ctx,
                log_id,
                frame,
                "unknown_record",
                None,
                json!({"record_type":record_type,"type_name":records::type_name(*record_type),
                    "payload_hex":stream::hex_encode(&frame.payload)}),
            )
            .await?;
            Ok(Stored::Other)
        }
        other => {
            let Some(code) = other.event_code() else {
                return Ok(Stored::Other);
            };
            let mut details = other.event_details();
            if let Value::Object(map) = &mut details {
                map.insert(
                    "type_name".into(),
                    json!(records::type_name(frame.record_type)),
                );
            }
            insert_event(client, ctx, log_id, frame, code, other.time(), details).await?;
            if let Record::LogStart {
                time,
                previous_log_id,
                firmware_version,
                mcu_uid,
                log_id: started,
                ..
            } = other
            {
                let placed = place(*time);
                client
                    .execute(
                        "UPDATE stream_logs SET previous_log_id=$3,start_reason=$4,started_at=$5,firmware_version=$6,mcu_uid=$7
                         WHERE device_id=$1 AND log_id=$2",
                        &[
                            &ctx.device_id,
                            &i64::from(*started),
                            &(*previous_log_id != 0).then_some(i64::from(*previous_log_id)),
                            &other.event_details()["reason"].as_str().map(str::to_owned),
                            &placed.recorded_at,
                            &records::firmware_version_text(*firmware_version),
                            mcu_uid,
                        ],
                    )
                    .await
                    .map_err(dberr("log start"))?;
            }
            Ok(Stored::Event(code.to_owned()))
        }
    }
}

/// Names of the Type 5 status bits that are set.
/// Status bits a self test must have for the firmware's `test/result`
/// `ok` (`app_core.c` `App_TestFinish` `need`): sensor, SD, SIM, network,
/// MQTT, display, accelerometer and MRAM. GNSS fix and solar only warn.
pub const TEST_REQUIRED_BITS: u16 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x40 | 0x80 | 0x100;

/// The pass/fail the logger itself reports for a Type 5 status bitfield.
pub fn test_passed(status: u16) -> bool {
    status & TEST_REQUIRED_BITS == TEST_REQUIRED_BITS
}

pub fn test_status_flags(status: u16) -> Vec<&'static str> {
    const NAMES: [&str; 10] = [
        "sensor",
        "sd",
        "sim",
        "network",
        "mqtt",
        "gnss_fix",
        "display",
        "accelerometer",
        "mram",
        "solar",
    ];
    NAMES
        .iter()
        .enumerate()
        .filter(|(bit, _)| status & (1 << bit) != 0)
        .map(|(_, name)| *name)
        .collect()
}

/// Recomputes the gaps around newly stored frames `[min, max]` of one log.
pub async fn detect_gaps<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    log_id: i64,
    min: i64,
    max: i64,
    now: DateTime<Utc>,
) -> Result<(), String> {
    let bounds = client
        .query_one(
            "SELECT COALESCE((SELECT max(seq) FROM stream_frames WHERE device_id=$1 AND log_id=$2 AND seq<$3),$3),
                    COALESCE((SELECT min(seq) FROM stream_frames WHERE device_id=$1 AND log_id=$2 AND seq>$4),$4)",
            &[&device, &log_id, &min, &max],
        )
        .await
        .map_err(dberr("gap bounds"))?;
    let (lo, hi): (i64, i64) = (bounds.get(0), bounds.get(1));
    let found = client
        .query(
            "WITH f AS (SELECT seq,pos,size,lag(seq) OVER w AS pseq,lag(pos) OVER w AS ppos,lag(size) OVER w AS psize
                FROM stream_frames WHERE device_id=$1 AND log_id=$2 AND seq BETWEEN $3 AND $4 WINDOW w AS (ORDER BY seq))
             SELECT pseq+1,seq-1,ppos+psize,pos FROM f
             WHERE pseq IS NOT NULL AND seq>pseq+1
               AND NOT (pos IS NOT NULL AND ppos IS NOT NULL AND pos=ppos+psize)",
            &[&device, &log_id, &lo, &hi],
        )
        .await
        .map_err(dberr("gap scan"))?;
    let fresh: Vec<(i64, i64, Option<i64>, Option<i64>)> = found
        .iter()
        .map(|row| (row.get(0), row.get(1), row.get(2), row.get(3)))
        .collect();
    let existing = client
        .query(
            "SELECT id,from_seq,to_seq,state,attempts FROM stream_gaps
             WHERE device_id=$1 AND log_id=$2 AND state<>'filled' AND to_seq>=$3 AND from_seq<=$4",
            &[&device, &log_id, &lo, &hi],
        )
        .await
        .map_err(dberr("gap lookup"))?;
    for row in &existing {
        let (id, from, to): (i64, i64, i64) = (row.get(0), row.get(1), row.get(2));
        if fresh.iter().any(|(f, t, _, _)| *f == from && *t == to) {
            continue;
        }
        let overlapping = fresh.iter().any(|(f, t, _, _)| *f <= to && *t >= from);
        if overlapping {
            client
                .execute("DELETE FROM stream_gaps WHERE id=$1", &[&id])
                .await
                .map_err(dberr("gap split"))?;
        } else {
            client
                .execute(
                    "UPDATE stream_gaps SET state='filled',resolved_at=$2 WHERE id=$1",
                    &[&id, &now],
                )
                .await
                .map_err(dberr("gap filled"))?;
        }
    }
    for (from, to, from_pos, to_pos) in fresh {
        if existing
            .iter()
            .any(|row| row.get::<_, i64>(1) == from && row.get::<_, i64>(2) == to)
        {
            continue;
        }
        // A part of an earlier gap inherits its request history.
        let inherited = existing
            .iter()
            .filter(|row| row.get::<_, i64>(1) <= to && row.get::<_, i64>(2) >= from);
        let attempts = inherited
            .clone()
            .map(|row| row.get::<_, i32>(4))
            .max()
            .unwrap_or(0);
        let unrecoverable = inherited
            .clone()
            .any(|row| row.get::<_, String>(3) == "unrecoverable");
        client
            .execute(
                "INSERT INTO stream_gaps(device_id,log_id,from_seq,to_seq,from_pos,to_pos,state,detected_at,attempts)
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
                 ON CONFLICT(device_id,log_id,from_seq,to_seq) DO UPDATE SET state=EXCLUDED.state,resolved_at=NULL",
                &[
                    &device,
                    &log_id,
                    &from,
                    &to,
                    &from_pos,
                    &to_pos,
                    &if unrecoverable { "unrecoverable" } else { "open" },
                    &now,
                    &attempts,
                ],
            )
            .await
            .map_err(dberr("gap insert"))?;
    }
    Ok(())
}

/// Queues one bounded `flush_mqtt` range for the oldest open gap, unless a
/// request is outstanding or one was made too recently.
pub async fn request_gaps<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    now: DateTime<Utc>,
    policy: &Rev2Policy,
) -> Result<bool, String> {
    // A request that ended without an ack (expired, cancelled, never
    // acknowledged) settles nothing: ask again, or close the gap once its
    // attempts are spent, instead of leaving it 'requested' for ever.
    client
        .execute(
            "UPDATE stream_gaps g SET state=CASE WHEN g.attempts>=$3 THEN 'unrecoverable' ELSE 'open' END,
                resolved_at=CASE WHEN g.attempts>=$3 THEN $2::timestamptz ELSE NULL END
             WHERE g.device_id=$1 AND g.state='requested'
               AND NOT EXISTS(SELECT 1 FROM commands c WHERE c.id=g.command_id AND c.state IN ('queued','sent'))",
            &[&device, &now, &policy.max_gap_attempts],
        )
        .await
        .map_err(dberr("stale gap requests"))?;
    let gap = client
        .query_opt(
            "SELECT g.id,g.log_id,g.from_seq,g.to_seq FROM stream_gaps g JOIN devices d ON d.device_id=g.device_id
             WHERE g.device_id=$1 AND g.state='open' AND g.attempts<$3 AND d.revoked_at IS NULL
               AND groundwater_profile_id(d.source_profile)='V22'
               AND (d.last_gap_request_at IS NULL OR d.last_gap_request_at<=$2::timestamptz-make_interval(secs=>$4::double precision))
               AND NOT EXISTS(SELECT 1 FROM commands c WHERE c.device_id=g.device_id AND c.origin='auto-gap'
                   AND c.state IN ('queued','sent'))
             ORDER BY g.log_id,g.from_seq LIMIT 1",
            &[
                &device,
                &now,
                &policy.max_gap_attempts,
                &(policy.gap_request_interval_seconds as f64),
            ],
        )
        .await
        .map_err(dberr("gap selection"))?;
    let Some(gap) = gap else {
        return Ok(false);
    };
    let (gap_id, log_id, from, to): (i64, i64, i64, i64) =
        (gap.get(0), gap.get(1), gap.get(2), gap.get(3));
    let to = to.min(from + policy.max_gap_range - 1);
    let args = json!({"log_id":log_id,"from_seq":from,"to_seq":to});
    let command = crate::rev2_commands::queue(
        client,
        device,
        "flush_mqtt",
        &args,
        &crate::rev2_commands::QueueOptions {
            requested_by: "auto-gap",
            origin: "auto-gap",
            ..crate::rev2_commands::QueueOptions::new(policy, now)
        },
    )
    .await?;
    let Some(command) = command else {
        return Ok(false);
    };
    client
        .execute(
            "UPDATE stream_gaps SET state='requested',attempts=attempts+1,last_requested_at=$2,command_id=$3
             WHERE device_id=$1 AND log_id=$4 AND state='open' AND from_seq>=$5 AND to_seq<=$6",
            &[&device, &now, &command, &log_id, &from, &to],
        )
        .await
        .map_err(dberr("gap request"))?;
    // The selected gap is always marked, even when capped mid-range.
    client
        .execute(
            "UPDATE stream_gaps SET state='requested',attempts=attempts+1,last_requested_at=$2,command_id=$3
             WHERE id=$1 AND state='open'",
            &[&gap_id, &now, &command],
        )
        .await
        .map_err(dberr("gap request"))?;
    client
        .execute(
            "UPDATE devices SET last_gap_request_at=$2 WHERE device_id=$1",
            &[&device, &now],
        )
        .await
        .map_err(dberr("gap request time"))?;
    server_event(
        client,
        device,
        "gap_requested",
        now,
        json!({"command_id":command,"log_id":log_id,"from_seq":from,"to_seq":to}),
    )
    .await?;
    Ok(true)
}

/// Settles the gaps a range `flush_mqtt` asked for once its ack arrives
/// (the resent batches precede the ack). `missing` > 0 means the logger
/// no longer holds some of them.
pub async fn settle_gap_request<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    command_id: i64,
    success: bool,
    missing: i64,
    policy: &Rev2Policy,
) -> Result<(), String> {
    client
        .execute(
            "UPDATE stream_gaps SET state=CASE WHEN ($3 AND $4::bigint>0) OR attempts>=$5 THEN 'unrecoverable' ELSE 'open' END,
                resolved_at=CASE WHEN ($3 AND $4::bigint>0) OR attempts>=$5 THEN now() ELSE NULL END
             WHERE device_id=$1 AND command_id=$2 AND state='requested'",
            &[&device, &command_id, &success, &missing, &policy.max_gap_attempts],
        )
        .await
        .map_err(dberr("gap settlement"))?;
    Ok(())
}

/// Assembles a settings generation from its Type 3 fragments, or from the
/// Type 4 backup when the primary set is incomplete (Rev2 "Settings
/// snapshots").
async fn assemble_settings<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    generation: i64,
) -> Result<(), String> {
    let rows = client
        .query(
            "SELECT backup,fragment_index,fragment_count,total_len,snapshot_crc32,data,log_id,seq
             FROM settings_fragments WHERE device_id=$1 AND settings_gen=$2 ORDER BY backup,fragment_index,seq",
            &[&ctx.device_id, &generation],
        )
        .await
        .map_err(dberr("fragment lookup"))?;
    for backup in [false, true] {
        let set: Vec<_> = rows
            .iter()
            .filter(|r| r.get::<_, bool>(0) == backup)
            .collect();
        let Some(first) = set.first() else { continue };
        let count: i16 = first.get(2);
        let total: i32 = first.get(3);
        let crc: i64 = first.get(4);
        let mut data = Vec::new();
        let mut complete = true;
        for index in 0..count {
            let Some(fragment) = set.iter().find(|r| {
                r.get::<_, i16>(1) == index
                    && r.get::<_, i16>(2) == count
                    && r.get::<_, i32>(3) == total
                    && r.get::<_, i64>(4) == crc
            }) else {
                complete = false;
                break;
            };
            data.extend_from_slice(fragment.get::<_, &[u8]>(5));
        }
        if !complete || data.len() != total as usize || i64::from(crate::crc::crc32(&data)) != crc {
            continue;
        }
        let decoded = crate::settings::decode_tlv(&data);
        client
            .execute(
                "INSERT INTO device_settings_history(device_id,settings_gen,source,settings,tlv,log_id,seq,received_at,warnings)
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT DO NOTHING",
                &[
                    &ctx.device_id,
                    &generation,
                    &if backup { "snapshot-backup" } else { "snapshot" },
                    &decoded.effective(),
                    &data,
                    &first.get::<_, i64>(6),
                    &first.get::<_, i64>(7),
                    &ctx.received_at,
                    &json!(decoded.warnings),
                ],
            )
            .await
            .map_err(dberr("snapshot history"))?;
        break;
    }
    Ok(())
}

/// A snapshot proves nothing until an anchor (Type 1 reason 3) shows its
/// generation in force; then it becomes the device's effective settings if
/// it is newer than what the server already knows.
async fn activate_snapshot_settings<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
) -> Result<(), String> {
    let row = client
        .query_opt(
            "SELECT h.settings_gen,h.settings FROM device_settings_history h JOIN devices d ON d.device_id=h.device_id
             WHERE h.device_id=$1 AND h.source IN ('snapshot','snapshot-backup')
               AND h.settings_gen>COALESCE(d.settings_gen,0)
               AND EXISTS(SELECT 1 FROM observations o WHERE o.device_id=h.device_id AND o.record_type=1 AND o.anchor
                   AND o.reading_reason=3 AND o.settings_gen=h.settings_gen)
             ORDER BY h.settings_gen DESC,h.source LIMIT 1",
            &[&ctx.device_id],
        )
        .await
        .map_err(dberr("snapshot activation"))?;
    if let Some(row) = row {
        apply_effective_settings(
            client,
            ctx.device_id,
            row.get(0),
            &row.get(1),
            ctx.received_at,
        )
        .await?;
    }
    Ok(())
}

/// Records the logger's effective settings and mirrors its alarm limits
/// into the server's level alerts (Rev2: the logger raises them itself; the
/// server keeps a consistent view for charts and its own alert history).
pub async fn apply_effective_settings<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    generation: i64,
    settings: &Value,
    at: DateTime<Utc>,
) -> Result<(), String> {
    let number = |key| settings.get(key).and_then(Value::as_f64);
    client
        .execute(
            "UPDATE devices SET settings_gen=$2,settings=$3,settings_at=$4,min_limit=$5,max_limit=$6,
                min_hysteresis=$7,max_hysteresis=$8,location_id=COALESCE(NULLIF($9,''),location_id)
             WHERE device_id=$1 AND (settings_gen IS NULL OR settings_gen<=$2)",
            &[
                &device,
                &generation,
                settings,
                &at,
                &number("lo"),
                &number("hi"),
                &number("lo_hys"),
                &number("hi_hys"),
                &settings.get("loc").and_then(Value::as_str),
            ],
        )
        .await
        .map_err(dberr("effective settings"))?;
    Ok(())
}

async fn store_file_chunk<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    payload: &[u8],
) -> Result<Outcome, String> {
    let decoded =
        stream::decode_payload(payload, stream::FILE_MAGIC).and_then(|(bytes, encoding)| {
            stream::parse_file_chunk(&bytes).map(|c| (c, bytes, encoding))
        });
    let (chunk, bytes, encoding) = match decoded {
        Ok(decoded) => decoded,
        Err(error) => {
            insert_batch_row(
                client,
                ctx,
                "unknown",
                payload,
                Some(format!("{}: {error}", error.code())),
                None,
                json!([]),
                json!([]),
            )
            .await?;
            return Ok(Outcome::rejected(format!("{}: {error}", error.code())));
        }
    };
    // The logger answers a file_chunk command with exactly one chunk at the
    // requested offset and at most the requested length (app_cmd.c
    // h_file_chunk). Anything else would let a logger account write
    // unbounded chunk rows under one command, so it is refused.
    let requested = client
        .query_opt(
            "SELECT args->>'off',args->>'len' FROM commands WHERE id=$1 AND device_id=$2 AND op='file_chunk'",
            &[&i64::from(chunk.command_id), &ctx.device_id],
        )
        .await
        .map_err(dberr("chunk request"))?;
    let mismatch = requested.and_then(|row| {
        let off = row.get::<_, Option<String>>(0)?.parse::<u64>().ok()?;
        let len = row.get::<_, Option<String>>(1)?.parse::<usize>().ok()?;
        (u64::from(chunk.offset) != off || chunk.data.len() > len).then(|| {
            format!(
                "data/file chunk at {} with {} bytes does not answer command {} (off {off}, len {len})",
                chunk.offset,
                chunk.data.len(),
                chunk.command_id
            )
        })
    });
    let batch_id = insert_batch_row(
        client,
        ctx,
        encoding.as_str(),
        &bytes,
        mismatch.clone(),
        None,
        json!([]),
        json!([]),
    )
    .await?;
    if let Some(reason) = mismatch {
        return Ok(Outcome::rejected(reason));
    }
    // The verified chunk stays stored whatever advancing the download does.
    savepoint(client, "rev2_chunk").await?;
    match crate::rev2_commands::file_chunk_received(client, ctx, &chunk).await {
        Ok(outcome) => {
            end_savepoint(client, "rev2_chunk", true).await?;
            Ok(outcome)
        }
        Err(error) if transient_error(&error) => Err(error),
        Err(error) => {
            end_savepoint(client, "rev2_chunk", false).await?;
            let text = format!("download not advanced: {error}; the chunk is kept raw");
            client
                .execute(
                    "UPDATE stream_batches SET derive_error=$2 WHERE id=$1",
                    &[&batch_id, &text],
                )
                .await
                .map_err(dberr("derive error"))?;
            client
                .execute(
                    "UPDATE file_downloads f SET state='failed',error=$3,updated_at=now() FROM commands c
                     WHERE c.id=$1 AND c.device_id=$2 AND f.id=c.download_id AND f.state='active'",
                    &[&i64::from(chunk.command_id), &ctx.device_id, &text],
                )
                .await
                .map_err(dberr("download failure"))?;
            Ok(Outcome {
                detail: Some(text),
                events: vec![LiveEvent::Download {
                    device_id: ctx.device_id.to_owned(),
                }],
                ..Outcome::default()
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_times_are_placed_without_guessing() {
        let received = utc(1_763_300_100);
        let valid = place_json(
            Some(rev2::DeviceTime {
                t: 1_763_300_000,
                valid: true,
            }),
            received,
            None,
        );
        assert_eq!(valid.recorded_at, Some(utc(1_763_300_000)));
        // Relative time in this connection: anchored on the reported uptime.
        let estimated = place_json(
            Some(rev2::DeviceTime {
                t: 400,
                valid: false,
            }),
            received,
            Some((500, received - chrono::Duration::seconds(10))),
        );
        assert_eq!(estimated.source, "uptime-estimate");
        assert_eq!(
            estimated.recorded_at,
            Some(received - chrono::Duration::seconds(110))
        );
        // Uptime from another connection (or a later boot) is not used.
        let stale = place_json(
            Some(rev2::DeviceTime {
                t: 400,
                valid: false,
            }),
            received,
            Some((500, received - chrono::Duration::hours(2))),
        );
        assert_eq!(stale.recorded_at, None);
        assert_eq!(stale.rel, Some(400));
        let later_boot = place_json(
            Some(rev2::DeviceTime {
                t: 900,
                valid: false,
            }),
            received,
            Some((500, received)),
        );
        assert_eq!(later_boot.recorded_at, None);
    }

    #[test]
    fn quality_mirrors_the_sql_classification() {
        let received = utc(1_763_300_000);
        assert_eq!(time_quality(None, received), "ambiguous");
        assert_eq!(time_quality(Some(utc(946_684_800)), received), "reset");
        assert_eq!(
            time_quality(Some(received + chrono::Duration::hours(25)), received),
            "future"
        );
        assert_eq!(time_quality(Some(received), received), "plausible");
    }

    #[test]
    fn alert_names_follow_the_record_events() {
        let name = |text: &str| {
            alert_event_name(&rev2::object(text.as_bytes()).unwrap()).map(|s| s.to_string())
        };
        assert_eq!(
            name(
                r#"{"v":2,"ev":"gwl_alarm","limit":"high","state":"enter","lvl":12.3,"thr":10.5}"#
            )
            .as_deref(),
            Some("gwl_alarm_enter")
        );
        assert_eq!(
            name(r#"{"v":2,"ev":"gwl_alarm","state":"exit"}"#).as_deref(),
            Some("gwl_alarm_exit")
        );
        assert_eq!(
            name(r#"{"v":2,"ev":"storage","kind":"tail_lock"}"#).as_deref(),
            Some("tail_lock")
        );
        assert_eq!(
            name(r#"{"v":2,"ev":"storage","kind":"sd_full"}"#).as_deref(),
            Some("storage_warning")
        );
        assert_eq!(name(r#"{"v":2,"ev":"meteor"}"#), None);
        assert_eq!(
            test_status_flags(0b10_0000_0011),
            vec!["sensor", "sd", "solar"]
        );
    }
}
