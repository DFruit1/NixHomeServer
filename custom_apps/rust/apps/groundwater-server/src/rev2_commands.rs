//! Protocol revision 2 commands (`docs/gwl-v1-rev2.md` §5–§8).
//!
//! Lifecycle of a command row (`commands.protocol = 2`):
//!
//! ```text
//! queued ──publish+PUBACK──▶ sent ──ack──▶ acked (final_status ok/partial/failed/rejected/duplicate)
//!   ▲                          │  └─challenge──▶ challenge ──confirm acked──▶ acked
//!   │   sleep/offline, no ack  │                    └── nexp passed / slept ──▶ expired
//!   └──────────(≤ 3 re-publishes)┘── exhausted ──▶ unacknowledged
//! queued/sent ── exp passed ──▶ expired           rejected/busy ──▶ queued until the next sleep
//! ```
//!
//! The wire id is `commands.id`. Commands are published as soon as they are
//! queued: the logger's persistent session holds them while it sleeps. At
//! most `max_in_flight` unacknowledged commands per device are outstanding
//! (the logger queues four). `sync_time` and nonce confirmations are only
//! meaningful in the current awake window, so they are never re-published.

use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};
use tokio_postgres::GenericClient;

use crate::config::Rev2Policy;
use crate::ingest::LiveEvent;
use crate::rev2::{self, AckStatus};
use crate::rev2_store::{dberr, Context, Outcome};

/// Options for a queued command.
#[derive(Debug, Clone)]
pub struct QueueOptions<'a> {
    pub requested_by: &'a str,
    /// `operator`, `auto-gap`, `auto-clock`, `auto-settings`,
    /// `auto-confirm`, `download`.
    pub origin: &'a str,
    pub expires_at: DateTime<Utc>,
    pub preconfirmed: bool,
    pub live_only: bool,
    pub parent_id: Option<i64>,
    pub download_id: Option<i64>,
    pub replace: bool,
}

impl<'a> QueueOptions<'a> {
    /// Defaults for `op`'s channel: basic/settings expire after
    /// `basic_expiry_seconds`, danger after `danger_expiry_seconds`.
    pub fn new(policy: &Rev2Policy, now: DateTime<Utc>) -> Self {
        Self {
            requested_by: "server",
            origin: "operator",
            expires_at: now + chrono::Duration::seconds(policy.basic_expiry_seconds),
            preconfirmed: false,
            live_only: false,
            parent_id: None,
            download_id: None,
            replace: false,
        }
    }
    pub fn for_op(op: &str, policy: &Rev2Policy, now: DateTime<Utc>) -> Self {
        let mut options = Self::new(policy, now);
        if rev2::kind_of(op) == Some(rev2::CommandKind::Danger) {
            options.expires_at = now + chrono::Duration::seconds(policy.danger_expiry_seconds);
        }
        options
    }
}

/// Validates an operation and its arguments as the API would queue them,
/// including the 1,024-byte downlink limit.
pub fn prepare(op: &str, args: &Value, replace: bool, now: DateTime<Utc>) -> Result<Value, String> {
    let args = rev2::validate_args(op, args, now.timestamp())?;
    if replace && op != "settings" {
        return Err("replace applies only to settings".into());
    }
    let worst = rev2::envelope(
        u32::MAX,
        u32::MAX,
        op,
        &with_time(op, &args, u32::MAX),
        replace,
    );
    if worst.len() > rev2::MAX_DOWNLINK_BYTES {
        return Err(format!(
            "command is {} bytes; the logger accepts at most {}",
            worst.len(),
            rev2::MAX_DOWNLINK_BYTES
        ));
    }
    Ok(args)
}

/// `sync_time` carries the server's UTC at publish time, never queue time.
fn with_time(op: &str, args: &Value, now: u32) -> Value {
    if op == "sync_time" {
        json!({"t":now})
    } else {
        args.clone()
    }
}

/// The exact downlink payload for one publish.
pub fn wire(
    id: i64,
    expires_at: DateTime<Utc>,
    op: &str,
    args: &Value,
    replace: bool,
    now: DateTime<Utc>,
) -> String {
    let exp = u32::try_from(expires_at.timestamp().max(0)).unwrap_or(u32::MAX);
    let id = u32::try_from(id).unwrap_or(u32::MAX);
    let now = u32::try_from(now.timestamp().max(0)).unwrap_or(u32::MAX);
    rev2::envelope(id, exp, op, &with_time(op, args, now), replace)
}

/// Queues a revision 2 command. `None` when the device is revoked, not a
/// `V22` unit, or the operation is not allowed for it.
pub async fn queue<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    op: &str,
    args: &Value,
    options: &QueueOptions<'_>,
) -> Result<Option<i64>, String> {
    let now = Utc::now();
    let args = prepare(op, args, options.replace, now)?;
    let kind = rev2::kind_of(op).ok_or_else(|| format!("{op} is not a contract operation"))?;
    let payload = json!({"op":op,"args":args});
    let row = client
        .query_opt(
            "INSERT INTO commands(device_id,kind,payload,wire_payload,requested_by,firmware_ack_expected,protocol,op,args,
                replace_settings,expires_at,preconfirmed,live_only,origin,parent_id,download_id)
             SELECT d.device_id,$2,$3,'',$4,true,2,$5,$6,$7,$8,$9,$10,$11,$12,$13 FROM devices d
             WHERE d.device_id=$1 AND d.revoked_at IS NULL
               AND groundwater_command_supported(d.source_profile,$2,$3,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE
             RETURNING id",
            &[
                &device,
                &kind.as_str(),
                &payload,
                &options.requested_by,
                &op,
                &args,
                &options.replace,
                &options.expires_at,
                &options.preconfirmed,
                &options.live_only,
                &options.origin,
                &options.parent_id,
                &options.download_id,
            ],
        )
        .await
        .map_err(dberr("command queue"))?;
    let Some(row) = row else { return Ok(None) };
    let id: i64 = row.get(0);
    if id > i64::from(u32::MAX) {
        return Err("command id exceeds the protocol's u32 range".into());
    }
    client
        .execute(
            "UPDATE commands SET wire_payload=$2 WHERE id=$1",
            &[
                &id,
                &wire(id, options.expires_at, op, &args, options.replace, now),
            ],
        )
        .await
        .map_err(dberr("command wire"))?;
    Ok(Some(id))
}

/// A command ready to publish.
pub struct Prepared {
    pub attempt_id: i64,
    pub topic: String,
    pub wire: String,
}

/// Reserves the next revision 2 command for publishing, inside the
/// scheduler's transaction. Danger confirmations go first: their nonce only
/// lives for the current awake window.
pub async fn next_publish<C: GenericClient + Sync>(
    client: &C,
    policy: &Rev2Policy,
) -> Result<Option<Prepared>, String> {
    let row = client
        .query_opt(
            "SELECT c.id,c.device_id,c.op,c.args,c.expires_at,c.replace_settings,b.topic
             FROM commands c JOIN devices d ON d.device_id=c.device_id
             JOIN device_bindings b ON b.device_id=c.device_id AND b.revoked_at IS NULL
                AND groundwater_profile_id(b.source_profile)=groundwater_profile_id(d.source_profile)
                AND b.topic='gwl/v1/'||c.device_id||'/'||CASE c.kind WHEN 'config' THEN 'config/set'
                    WHEN 'basic' THEN 'cmd/basic' ELSE 'cmd/danger' END
             WHERE c.protocol=2 AND c.state='queued' AND c.active_publish_attempt IS NULL AND NOT c.hold_until_sleep
               AND d.revoked_at IS NULL
               AND groundwater_command_supported(d.source_profile,c.kind,c.payload,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE
               AND (c.expires_at IS NULL OR c.expires_at>now())
               AND (NOT c.live_only OR (d.link_state IN ('online','ready') AND NOT d.link_retained
                    AND d.link_state_at>now()-make_interval(secs=>COALESCE(d.listen_window_s,60)+180)))
               AND (c.op='confirm' OR (SELECT count(*) FROM commands o WHERE o.device_id=c.device_id AND o.protocol=2
                    AND o.op IS DISTINCT FROM 'confirm'
                    AND (o.state IN ('sent','challenge') OR o.active_publish_attempt IS NOT NULL))<$1)
             ORDER BY (c.op='confirm') DESC,c.id LIMIT 1 FOR UPDATE OF c SKIP LOCKED",
            &[&policy.max_in_flight],
        )
        .await
        .map_err(dberr("revision 2 selection"))?;
    let Some(row) = row else { return Ok(None) };
    let id: i64 = row.get(0);
    let op: String = row.get(2);
    let args: Option<Value> = row.get(3);
    let expires_at: Option<DateTime<Utc>> = row.get(4);
    let replace: bool = row.get(5);
    let topic: String = row.get(6);
    let now = Utc::now();
    let wire = wire(
        id,
        expires_at.unwrap_or(now + chrono::Duration::seconds(policy.basic_expiry_seconds)),
        &op,
        &args.unwrap_or_else(|| json!({})),
        replace,
        now,
    );
    let attempt: i64 = client
        .query_one(
            "INSERT INTO command_publish_attempts(command_id,ready_at,topic) VALUES($1,now(),$2) RETURNING id",
            &[&id, &topic],
        )
        .await
        .map_err(dberr("publish attempt"))?
        .get(0);
    client
        .execute(
            "UPDATE commands SET active_publish_attempt=$2,attempts=attempts+1,wire_payload=$3,firmware_ack_expected=true
             WHERE id=$1",
            &[&id, &attempt, &wire],
        )
        .await
        .map_err(dberr("publish reservation"))?;
    Ok(Some(Prepared {
        attempt_id: attempt,
        topic,
        wire,
    }))
}

/// Broker acceptance (PUBACK) of a revision 2 publish. An ack may already
/// have arrived; the state only moves forward.
pub async fn accepted<C: GenericClient + Sync>(
    client: &C,
    command_id: i64,
    dispatched: DateTime<Utc>,
    acked_at: DateTime<Utc>,
    policy: &Rev2Policy,
) -> Result<(), String> {
    client
        .execute(
            "UPDATE commands SET state=CASE WHEN state='queued' THEN 'sent' ELSE state END,
                sent_at=COALESCE(sent_at,$2),broker_acked_at=$3,last_published_at=$2,publish_count=publish_count+1,
                active_publish_attempt=NULL
             WHERE id=$1",
            &[&command_id, &dispatched, &acked_at],
        )
        .await
        .map_err(dberr("revision 2 acceptance"))?;
    // The logger slept between dispatch and this PUBACK: apply the sleep
    // rule now instead of waiting a whole send interval for the next one.
    client
        .execute(
            "UPDATE commands c SET state=CASE WHEN c.live_only OR c.op='confirm' THEN 'expired'
                    WHEN c.publish_count>$3 THEN 'unacknowledged' ELSE 'queued' END,
                final_status=CASE WHEN c.live_only OR c.op='confirm' THEN 'expired' ELSE c.final_status END,
                status_reason='the logger slept right after this publish without acknowledging it'
             FROM devices d WHERE c.id=$1 AND c.state='sent' AND d.device_id=c.device_id
               AND d.link_state IN ('sleep','offline') AND NOT d.link_retained AND d.link_state_at>$2",
            &[&command_id, &dispatched, &policy.max_republish],
        )
        .await
        .map_err(dberr("late sleep"))?;
    Ok(())
}

/// Applies a `status` transition to the device's commands. Returns whether
/// anything changed.
pub async fn on_status<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    state: rev2::PresenceState,
    at: DateTime<Utc>,
    policy: &Rev2Policy,
) -> Result<bool, String> {
    if !matches!(
        state,
        rev2::PresenceState::Sleep | rev2::PresenceState::Offline
    ) {
        return Ok(false);
    }
    let mut changed = 0;
    // Published before this sleep and never finally acknowledged.
    changed += client
        .execute(
            "UPDATE commands SET
                state=CASE WHEN expires_at<=$2 OR live_only OR op='confirm' THEN 'expired'
                    WHEN publish_count>$3 THEN 'unacknowledged' ELSE 'queued' END,
                final_status=CASE WHEN expires_at<=$2 OR live_only OR op='confirm' THEN 'expired' ELSE final_status END,
                status_reason=CASE WHEN expires_at<=$2 THEN 'exp passed without a final ack'
                    WHEN live_only OR op='confirm' THEN 'the awake window closed without an ack'
                    WHEN publish_count>$3 THEN 'no ack after '||publish_count||' publishes'
                    ELSE 'no ack before the logger slept; re-publishing' END
             WHERE device_id=$1 AND protocol=2 AND state='sent' AND active_publish_attempt IS NULL
               AND last_published_at<$2",
            &[&device, &at, &policy.max_republish],
        )
        .await
        .map_err(dberr("sleep re-publish"))?;
    // rejected/busy: re-send after this sleep.
    changed += client
        .execute(
            "UPDATE commands SET hold_until_sleep=false
             WHERE device_id=$1 AND protocol=2 AND state='queued' AND hold_until_sleep AND acked_at<$2",
            &[&device, &at],
        )
        .await
        .map_err(dberr("busy release"))?;
    // A nonce only lives in the window that issued it; a time-only command
    // (sync_time) that never reached the logger is stale now.
    changed += client
        .execute(
            "UPDATE commands SET state='expired',final_status='expired',
                status_reason=CASE WHEN state='challenge' THEN 'challenge was not confirmed before the logger slept'
                    ELSE 'the awake window closed before it was published' END
             WHERE device_id=$1 AND protocol=2 AND active_publish_attempt IS NULL
               AND ((state='challenge' AND acked_at<$2) OR (state='queued' AND (live_only OR op='confirm')))",
            &[&device, &at],
        )
        .await
        .map_err(dberr("window close"))?;
    Ok(changed > 0)
}

/// Expires commands whose `exp` (or challenge `nexp`) passed. Returns the
/// affected devices.
pub async fn expire<C: GenericClient + Sync>(client: &C) -> Result<Vec<String>, String> {
    let rows = client
        .query(
            "WITH expired AS (
                UPDATE commands SET state='expired',final_status='expired',
                    status_reason=CASE WHEN state='challenge' THEN 'challenge was not confirmed before nexp'
                        ELSE 'exp passed without a final ack' END
                WHERE protocol=2 AND active_publish_attempt IS NULL AND (
                    (state IN ('queued','sent') AND expires_at<=now())
                    OR (state='challenge' AND challenge_expires_at<now()-interval '10 seconds'
                        AND NOT EXISTS(SELECT 1 FROM commands k WHERE k.parent_id=commands.id AND k.state IN ('queued','sent'))))
                RETURNING device_id,download_id),
             failed AS (UPDATE file_downloads f SET state='failed',error='chunk command expired',updated_at=now()
                FROM expired e WHERE f.id=e.download_id AND f.state='active' RETURNING f.id)
             SELECT DISTINCT device_id FROM expired",
            &[],
        )
        .await
        .map_err(dberr("command expiry"))?;
    Ok(rows.iter().map(|row| row.get(0)).collect())
}

struct CommandRow {
    id: i64,
    op: String,
    kind: String,
    parent_id: Option<i64>,
    origin: String,
    download_id: Option<i64>,
    args: Value,
    preconfirmed: bool,
    publish_count: i32,
}

async fn load_command<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    id: i64,
) -> Result<Option<CommandRow>, String> {
    let row = client
        .query_opt(
            "SELECT id,op,kind,parent_id,origin,download_id,args,preconfirmed,publish_count
             FROM commands WHERE id=$1 AND device_id=$2 AND protocol=2 FOR UPDATE",
            &[&id, &device],
        )
        .await
        .map_err(dberr("command lookup"))?;
    Ok(row.map(|row| CommandRow {
        id: row.get(0),
        op: row.get::<_, Option<String>>(1).unwrap_or_default(),
        kind: row.get(2),
        parent_id: row.get(3),
        origin: row.get(4),
        download_id: row.get(5),
        args: row.get::<_, Option<Value>>(6).unwrap_or_else(|| json!({})),
        preconfirmed: row.get(7),
        publish_count: row.get(8),
    }))
}

/// Handles `config/applied` / `cmd/ack`.
pub async fn handle_ack<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    object: &Map<String, Value>,
) -> Result<Outcome, String> {
    let ack = match rev2::parse_ack(object) {
        Ok(ack) => ack,
        Err(error) => return Ok(Outcome::rejected(error)),
    };
    let Some(command) = load_command(client, ctx.device_id, i64::from(ack.id)).await? else {
        server_event(
            client,
            ctx.device_id,
            "unmatched_ack",
            ctx.received_at,
            json!({"id":ack.id,"op":ack.op,"status":ack.status.as_str()}),
        )
        .await?;
        return Ok(Outcome::rejected(format!(
            "ack id {} matches no revision 2 command of this device",
            ack.id
        )));
    };
    let mut outcome = Outcome::default();
    let expected_channel = if command.kind == "config" {
        "config/applied"
    } else {
        "cmd/ack"
    };
    if ctx.channel != expected_channel {
        outcome.detail = Some(format!(
            "ack for a {} command arrived on {}",
            command.kind, ctx.channel
        ));
    }
    let payload = Value::Object(object.clone());
    if ack.status == AckStatus::Challenge {
        handle_challenge(client, ctx, &command, &ack, &payload, &mut outcome).await?;
    } else {
        finalize(client, ctx, &command, &ack, &payload).await?;
        effects(client, ctx, &command, &ack, &mut outcome).await?;
    }
    outcome.events.push(LiveEvent::Command {
        device_id: ctx.device_id.to_owned(),
    });
    Ok(outcome)
}

/// Final state for an ack status: `(state, final_status, hold_until_sleep)`.
pub fn final_state(
    status: AckStatus,
    reason: Option<&str>,
) -> (&'static str, Option<&'static str>, bool) {
    match (status, reason) {
        (AckStatus::Rejected, Some("busy")) => ("queued", None, true),
        (AckStatus::Rejected, Some("time-invalid")) => ("queued", None, true),
        (AckStatus::Expired, _) => ("expired", Some("expired"), false),
        (AckStatus::Duplicate, _) => ("acked", Some("duplicate"), false),
        (AckStatus::Ok, _) => ("acked", Some("ok"), false),
        (AckStatus::Partial, _) => ("acked", Some("partial"), false),
        (AckStatus::Failed, _) => ("acked", Some("failed"), false),
        (AckStatus::Rejected, _) => ("acked", Some("rejected"), false),
        (AckStatus::Challenge, _) => ("challenge", None, false),
    }
}

async fn finalize<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    command: &CommandRow,
    ack: &rev2::Ack,
    payload: &Value,
) -> Result<(), String> {
    let (mut state, final_status, hold) = final_state(ack.status, ack.reason.as_deref());
    let reason = match ack.status {
        AckStatus::Duplicate => ack.prev.clone().map(|prev| format!("previously {prev}")),
        _ => ack.reason.clone(),
    };
    if hold && command.publish_count > ctx.policy.max_republish {
        state = "unacknowledged";
    }
    client
        .execute(
            "UPDATE commands SET state=$2,final_status=$3,status_reason=$4,hold_until_sleep=$5,acked_at=$6,ack_payload=$7
             WHERE id=$1",
            &[
                &command.id,
                &state,
                &final_status,
                &reason,
                &hold,
                &ctx.received_at,
                payload,
            ],
        )
        .await
        .map_err(dberr("ack final state"))?;
    if command.op == "confirm"
        && let Some(parent) = command.parent_id
    {
        client
            .execute(
                "UPDATE commands SET state=$2,final_status=$3,status_reason=$4,acked_at=$5,ack_payload=$6
                 WHERE id=$1 AND state IN ('challenge','sent','queued')",
                &[
                    &parent,
                    &if hold { "expired" } else { state },
                    &final_status.or(hold.then_some("rejected")),
                    &reason,
                    &ctx.received_at,
                    payload,
                ],
            )
            .await
            .map_err(dberr("challenged command"))?;
    }
    if ack.status == AckStatus::Rejected && ack.reason.as_deref() == Some("time-invalid") {
        queue_clock_sync(client, ctx, "rejected time-invalid").await?;
    }
    Ok(())
}

async fn handle_challenge<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    command: &CommandRow,
    ack: &rev2::Ack,
    payload: &Value,
    outcome: &mut Outcome,
) -> Result<(), String> {
    let (Some(nonce), Some(nexp)) = (ack.nonce.clone(), ack.nexp) else {
        outcome.rejected = Some("challenge without nonce or nexp".into());
        return Ok(());
    };
    if !rev2::needs_handshake(&command.op) {
        outcome.rejected = Some(format!("{} does not use the nonce handshake", command.op));
        return Ok(());
    }
    let nexp_at = crate::rev2_store::utc(i64::from(nexp));
    let challenge = json!({"nonce":nonce,"nexp":nexp,"unsaved_frames":ack.unsaved_frames,
        "unsaved_bytes":ack.unsaved_bytes,"received_at":ctx.received_at});
    client
        .execute(
            "UPDATE commands SET state='challenge',challenge=$2,challenge_expires_at=$3,acked_at=$4,ack_payload=$5,
                status_reason=NULL WHERE id=$1",
            &[&command.id, &challenge, &nexp_at, &ctx.received_at, payload],
        )
        .await
        .map_err(dberr("challenge"))?;
    let unsaved = ack.unsaved_frames.unwrap_or(0);
    if command.preconfirmed && unsaved == 0 && nexp_at > ctx.received_at {
        let options = QueueOptions {
            requested_by: "auto-confirm",
            origin: "auto-confirm",
            expires_at: nexp_at,
            parent_id: Some(command.id),
            ..QueueOptions::new(ctx.policy, ctx.received_at)
        };
        queue(
            client,
            ctx.device_id,
            "confirm",
            &json!({"ref":command.id,"nonce":nonce}),
            &options,
        )
        .await?;
    } else {
        server_event(
            client,
            ctx.device_id,
            "challenge_held",
            ctx.received_at,
            json!({"command_id":command.id,"op":command.op,"unsaved_frames":ack.unsaved_frames,
                "unsaved_bytes":ack.unsaved_bytes,"nexp":nexp,
                "why":if command.preconfirmed {"unsaved data needs an explicit count"} else {"operator confirmation required"}}),
        )
        .await?;
        outcome.events.push(LiveEvent::DeviceEvent {
            device_id: ctx.device_id.to_owned(),
            event: "challenge_held".into(),
        });
    }
    Ok(())
}

/// Operation-specific effects of a final ack.
async fn effects<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    command: &CommandRow,
    ack: &rev2::Ack,
    outcome: &mut Outcome,
) -> Result<(), String> {
    let success = matches!(ack.status, AckStatus::Ok | AckStatus::Partial);
    let data = ack.data.clone().unwrap_or(Value::Null);
    match command.op.as_str() {
        "settings" if success && ack.settings.is_none() => {
            // The logger drops the settings object when the ack would exceed
            // 1,024 bytes (reason data-truncated): fetch it explicitly.
            let open = client
                .query_opt(
                    "SELECT 1 FROM commands WHERE device_id=$1 AND protocol=2 AND op='get_settings'
                        AND state IN ('queued','sent')",
                    &[&ctx.device_id],
                )
                .await
                .map_err(dberr("open get_settings"))?
                .is_some();
            if !open {
                let options = QueueOptions {
                    requested_by: "auto-settings",
                    origin: "auto-settings",
                    ..QueueOptions::new(ctx.policy, ctx.received_at)
                };
                queue(client, ctx.device_id, "get_settings", &json!({}), &options).await?;
            }
        }
        "settings" if success => {
            if let (Some(generation), Some(settings)) = (ack.settings_gen, &ack.settings) {
                settings_history(client, ctx, generation, settings, "ack", command.id).await?;
                crate::rev2_store::apply_effective_settings(
                    client,
                    ctx.device_id,
                    generation,
                    settings,
                    ctx.received_at,
                )
                .await?;
            }
        }
        "get_settings" if success => {
            let generation = data.get("gen").and_then(Value::as_i64);
            if let (Some(generation), Some(settings)) =
                (generation, data.get("settings").filter(|s| s.is_object()))
            {
                settings_history(
                    client,
                    ctx,
                    generation,
                    settings,
                    "get_settings",
                    command.id,
                )
                .await?;
                crate::rev2_store::apply_effective_settings(
                    client,
                    ctx.device_id,
                    generation,
                    settings,
                    ctx.received_at,
                )
                .await?;
            }
        }
        "get_status" if success && data.is_object() => {
            client
                .execute(
                    "UPDATE devices SET status_snapshot=$2,status_snapshot_at=$3 WHERE device_id=$1",
                    &[&ctx.device_id, &data, &ctx.received_at],
                )
                .await
                .map_err(dberr("status snapshot"))?;
        }
        "get_debug" if success => {
            client
                .execute(
                    "UPDATE devices SET debug=$2,debug_at=$3 WHERE device_id=$1",
                    &[&ctx.device_id, &data, &ctx.received_at],
                )
                .await
                .map_err(dberr("debug snapshot"))?;
        }
        "file_list" if success => {
            let path = data
                .get("path")
                .and_then(Value::as_str)
                .or_else(|| command.args.get("path").and_then(Value::as_str))
                .unwrap_or("/")
                .to_owned();
            let page = command
                .args
                .get("page")
                .and_then(Value::as_i64)
                .unwrap_or(0) as i32;
            client
                .execute(
                    "INSERT INTO device_file_lists(device_id,path,page,files,more,command_id,received_at)
                     VALUES($1,$2,$3,$4,$5,$6,$7)
                     ON CONFLICT(device_id,path,page) DO UPDATE SET files=EXCLUDED.files,more=EXCLUDED.more,
                        command_id=EXCLUDED.command_id,received_at=EXCLUDED.received_at",
                    &[
                        &ctx.device_id,
                        &path,
                        &page,
                        &data.get("files").cloned().unwrap_or_else(|| json!([])),
                        &data.get("more").and_then(Value::as_bool).unwrap_or(false),
                        &command.id,
                        &ctx.received_at,
                    ],
                )
                .await
                .map_err(dberr("file list"))?;
            outcome.events.push(LiveEvent::Download {
                device_id: ctx.device_id.to_owned(),
            });
        }
        "file_chunk" if !success && ack.status != AckStatus::Duplicate => {
            if let Some(download) = command.download_id {
                client
                    .execute(
                        "UPDATE file_downloads SET state='failed',error=$2,updated_at=now() WHERE id=$1 AND state='active'",
                        &[
                            &download,
                            &format!(
                                "file_chunk {}{}",
                                ack.status.as_str(),
                                ack.reason
                                    .as_ref()
                                    .map(|r| format!(" ({r})"))
                                    .unwrap_or_default()
                            ),
                        ],
                    )
                    .await
                    .map_err(dberr("download failure"))?;
                outcome.events.push(LiveEvent::Download {
                    device_id: ctx.device_id.to_owned(),
                });
            }
        }
        "flush_mqtt" if command.args.get("from_seq").is_some() => {
            let missing = data.get("missing").and_then(Value::as_i64).unwrap_or(0);
            crate::rev2_store::settle_gap_request(
                client,
                ctx.device_id,
                command.id,
                success,
                missing,
                ctx.policy,
            )
            .await?;
        }
        "sync_time" if success => {
            server_event(
                client,
                ctx.device_id,
                "clock_synced",
                ctx.received_at,
                json!({"command_id":command.id}),
            )
            .await?;
        }
        op if success
            && rev2::kind_of(op) == Some(rev2::CommandKind::Danger)
            && op != "confirm" =>
        {
            server_event(
                client,
                ctx.device_id,
                "danger_executed",
                ctx.received_at,
                json!({"command_id":command.id,"op":op}),
            )
            .await?;
        }
        _ => {}
    }
    if command.op == "confirm" && success {
        let op = ack.op.clone();
        server_event(
            client,
            ctx.device_id,
            "danger_executed",
            ctx.received_at,
            json!({"command_id":command.parent_id,"confirm_id":command.id,"op":op}),
        )
        .await?;
    }
    let _ = &command.origin;
    Ok(())
}

async fn settings_history<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    generation: i64,
    settings: &Value,
    source: &str,
    command_id: i64,
) -> Result<(), String> {
    client
        .execute(
            "INSERT INTO device_settings_history(device_id,settings_gen,source,settings,command_id,received_at)
             VALUES($1,$2,$3,$4,$5,$6)
             ON CONFLICT(device_id,settings_gen,source) WHERE settings_gen IS NOT NULL
             DO UPDATE SET settings=EXCLUDED.settings,command_id=EXCLUDED.command_id,received_at=EXCLUDED.received_at",
            &[&ctx.device_id, &generation, &source, settings, &command_id, &ctx.received_at],
        )
        .await
        .map_err(dberr("settings history"))?;
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

/// Whether the device is in a live awake window right now (a fresh,
/// non-retained `online`/`ready`).
async fn awake_now<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    now: DateTime<Utc>,
) -> Result<bool, String> {
    Ok(client
        .query_one(
            "SELECT COALESCE(link_state IN ('online','ready') AND NOT link_retained
                AND link_state_at>$2::timestamptz-make_interval(secs=>COALESCE(listen_window_s,60)+180),false)
                AND groundwater_profile_id(source_profile)='V22' AND revoked_at IS NULL
             FROM devices WHERE device_id=$1",
            &[&device, &now],
        )
        .await
        .map_err(dberr("awake check"))?
        .get(0))
}

async fn queue_clock_sync<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    why: &str,
) -> Result<bool, String> {
    let open = client
        .query_opt(
            "SELECT 1 FROM commands WHERE device_id=$1 AND protocol=2 AND op='sync_time' AND state IN ('queued','sent')",
            &[&ctx.device_id],
        )
        .await
        .map_err(dberr("open sync_time"))?
        .is_some();
    if open || !awake_now(client, ctx.device_id, ctx.received_at).await? {
        return Ok(false);
    }
    let options = QueueOptions {
        requested_by: "auto-clock",
        origin: "auto-clock",
        live_only: true,
        expires_at: ctx.received_at + chrono::Duration::minutes(15),
        ..QueueOptions::new(ctx.policy, ctx.received_at)
    };
    let queued = queue(client, ctx.device_id, "sync_time", &json!({}), &options).await?;
    if let Some(id) = queued {
        client
            .execute(
                "UPDATE devices SET last_clock_request_at=$2 WHERE device_id=$1",
                &[&ctx.device_id, &ctx.received_at],
            )
            .await
            .map_err(dberr("clock request time"))?;
        server_event(
            client,
            ctx.device_id,
            "clock_sync_requested",
            ctx.received_at,
            json!({"command_id":id,"reason":why}),
        )
        .await?;
    }
    Ok(queued.is_some())
}

/// Queues `sync_time` when a fresh `health` shows the clock invalid or off
/// by more than the tolerance, at most once per interval. Only while the
/// logger is awake, so the time it receives is current.
pub async fn maybe_sync_clock<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    valid: bool,
    skew_seconds: Option<i64>,
) -> Result<bool, String> {
    let needed =
        !valid || skew_seconds.is_some_and(|s| s.abs() > ctx.policy.clock_tolerance_seconds);
    if !needed {
        return Ok(false);
    }
    let recent = client
        .query_one(
            "SELECT COALESCE(last_clock_request_at>$2::timestamptz-make_interval(secs=>$3::double precision),false)
             FROM devices WHERE device_id=$1",
            &[
                &ctx.device_id,
                &ctx.received_at,
                &(ctx.policy.clock_request_interval_seconds as f64),
            ],
        )
        .await
        .map_err(dberr("clock request spacing"))?
        .get::<_, bool>(0);
    if recent {
        return Ok(false);
    }
    let why = match skew_seconds {
        None => "device clock not valid (tv=0)".to_owned(),
        Some(skew) => format!("device clock off by {skew} s"),
    };
    queue_clock_sync(client, ctx, &why).await
}

/// Queues `get_settings` when `health` reports a generation the server has
/// no effective settings for (e.g. a factory reset, or settings changed
/// while the server was not listening).
pub async fn maybe_fetch_settings<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    generation: i64,
) -> Result<bool, String> {
    let wanted = client
        .query_one(
            "SELECT d.settings_gen IS DISTINCT FROM $2 AND groundwater_profile_id(d.source_profile)='V22'
                AND NOT EXISTS(SELECT 1 FROM commands c WHERE c.device_id=d.device_id AND c.protocol=2
                    AND c.op IN ('settings','get_settings') AND (c.state IN ('queued','sent')
                        OR (c.op='get_settings' AND c.created_at>$3::timestamptz-interval '1 hour')))
             FROM devices d WHERE d.device_id=$1",
            &[&ctx.device_id, &generation, &ctx.received_at],
        )
        .await
        .map_err(dberr("settings generation"))?
        .get::<_, bool>(0);
    if !wanted {
        return Ok(false);
    }
    let options = QueueOptions {
        requested_by: "auto-settings",
        origin: "auto-settings",
        ..QueueOptions::new(ctx.policy, ctx.received_at)
    };
    Ok(
        queue(client, ctx.device_id, "get_settings", &json!({}), &options)
            .await?
            .is_some(),
    )
}

/// Starts an SD download: one `file_chunk` at a time, the next issued as
/// soon as the previous `data/file` reply arrives.
pub async fn start_download<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    path: &str,
    user: &str,
    policy: &Rev2Policy,
) -> Result<Option<(i64, i64)>, String> {
    let now = Utc::now();
    let first = json!({"path":path,"off":0,"len":stream_chunk_len()});
    prepare("file_chunk", &first, false, now)?;
    let download: i64 = client
        .query_one(
            "INSERT INTO file_downloads(device_id,path,requested_by) VALUES($1,$2,$3) RETURNING id",
            &[&device, &path, &user],
        )
        .await
        .map_err(dberr("download insert"))?
        .get(0);
    let options = QueueOptions {
        requested_by: user,
        origin: "download",
        download_id: Some(download),
        ..QueueOptions::new(policy, now)
    };
    let Some(command) = queue(client, device, "file_chunk", &first, &options).await? else {
        return Ok(None);
    };
    client
        .execute(
            "UPDATE file_downloads SET current_command_id=$2 WHERE id=$1",
            &[&download, &command],
        )
        .await
        .map_err(dberr("download command"))?;
    Ok(Some((download, command)))
}

fn stream_chunk_len() -> i64 {
    crate::stream::MAX_FILE_CHUNK_DATA as i64
}

/// Stores a `data/file` chunk and advances its download.
pub async fn file_chunk_received<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    chunk: &crate::stream::FileChunk,
) -> Result<Outcome, String> {
    let Some(command) = load_command(client, ctx.device_id, i64::from(chunk.command_id)).await?
    else {
        return Ok(Outcome::rejected(format!(
            "data/file names command {} which is not a revision 2 command of this device",
            chunk.command_id
        )));
    };
    if command.op != "file_chunk" {
        return Ok(Outcome::rejected(format!(
            "data/file names command {} which is {}",
            command.id, command.op
        )));
    }
    let download = match command.download_id {
        Some(id) => id,
        None => {
            let path = command
                .args
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or("/")
                .to_owned();
            let id: i64 = client
                .query_one(
                    "INSERT INTO file_downloads(device_id,path,requested_by,current_command_id) VALUES($1,$2,'operator',$3) RETURNING id",
                    &[&ctx.device_id, &path, &command.id],
                )
                .await
                .map_err(dberr("ad hoc download"))?
                .get(0);
            client
                .execute(
                    "UPDATE commands SET download_id=$2 WHERE id=$1",
                    &[&command.id, &id],
                )
                .await
                .map_err(dberr("download link"))?;
            id
        }
    };
    let mut outcome = Outcome::default();
    outcome.events.push(LiveEvent::Download {
        device_id: ctx.device_id.to_owned(),
    });
    client
        .execute(
            "INSERT INTO file_download_chunks(download_id,offset_bytes,data,command_id,received_at)
             VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING",
            &[
                &download,
                &i64::from(chunk.offset),
                &chunk.data,
                &command.id,
                &ctx.received_at,
            ],
        )
        .await
        .map_err(dberr("chunk insert"))?;
    let row = client
        .query_one(
            "SELECT state,current_command_id,path,chunk_len FROM file_downloads WHERE id=$1 FOR UPDATE",
            &[&download],
        )
        .await
        .map_err(dberr("download lookup"))?;
    let state: String = row.get(0);
    let current: Option<i64> = row.get(1);
    let path: String = row.get(2);
    let chunk_len: i32 = row.get(3);
    let size = i64::from(chunk.total_size);
    if state != "active" {
        outcome.detail = Some(format!("download {download} is {state}; chunk kept"));
        return Ok(outcome);
    }
    if size > ctx.policy.max_download_bytes {
        client
            .execute(
                "UPDATE file_downloads SET state='failed',size=$2,error=$3,updated_at=now() WHERE id=$1",
                &[
                    &download,
                    &size,
                    &format!("file is {size} bytes; limit {}", ctx.policy.max_download_bytes),
                ],
            )
            .await
            .map_err(dberr("download limit"))?;
        return Ok(outcome);
    }
    let chunks = client
        .query(
            "SELECT offset_bytes,data FROM file_download_chunks WHERE download_id=$1 ORDER BY offset_bytes",
            &[&download],
        )
        .await
        .map_err(dberr("chunk list"))?;
    let mut contiguous: i64 = 0;
    let mut received: i64 = 0;
    for chunk_row in &chunks {
        let offset: i64 = chunk_row.get(0);
        let data: &[u8] = chunk_row.get(1);
        received += data.len() as i64;
        if offset <= contiguous {
            contiguous = contiguous.max(offset + data.len() as i64);
        }
    }
    if contiguous >= size {
        let mut content = vec![0u8; size as usize];
        for chunk_row in &chunks {
            let offset: i64 = chunk_row.get(0);
            let data: &[u8] = chunk_row.get(1);
            let start = offset.min(size) as usize;
            let end = (offset + data.len() as i64).min(size) as usize;
            content[start..end].copy_from_slice(&data[..end - start]);
        }
        let crc = i64::from(crate::crc::crc32(&content));
        client
            .execute(
                "UPDATE file_downloads SET state='complete',size=$2,received_bytes=$2,next_offset=$2,content=$3,crc32=$4,
                    current_command_id=NULL,completed_at=$5,updated_at=$5 WHERE id=$1",
                &[&download, &size, &content, &crc, &ctx.received_at],
            )
            .await
            .map_err(dberr("download complete"))?;
        client
            .execute(
                "DELETE FROM file_download_chunks WHERE download_id=$1",
                &[&download],
            )
            .await
            .map_err(dberr("chunk cleanup"))?;
        server_event(
            client,
            ctx.device_id,
            "file_downloaded",
            ctx.received_at,
            json!({"download_id":download,"path":path,"size":size,"crc32":format!("{crc:08X}")}),
        )
        .await?;
        return Ok(outcome);
    }
    client
        .execute(
            "UPDATE file_downloads SET size=$2,received_bytes=$3,next_offset=$4,updated_at=now() WHERE id=$1",
            &[&download, &size, &received, &contiguous],
        )
        .await
        .map_err(dberr("download progress"))?;
    if chunk.data.is_empty() {
        client
            .execute(
                "UPDATE file_downloads SET state='failed',error='the logger returned no data before the end of the file',
                    updated_at=now() WHERE id=$1",
                &[&download],
            )
            .await
            .map_err(dberr("download stall"))?;
        return Ok(outcome);
    }
    if current == Some(command.id) {
        let len = (size - contiguous).min(i64::from(chunk_len)).max(1);
        let args = json!({"path":path,"off":contiguous,"len":len});
        let options = QueueOptions {
            requested_by: "download",
            origin: "download",
            download_id: Some(download),
            ..QueueOptions::new(ctx.policy, ctx.received_at)
        };
        if let Some(next) = queue(client, ctx.device_id, "file_chunk", &args, &options).await? {
            client
                .execute(
                    "UPDATE file_downloads SET current_command_id=$2 WHERE id=$1",
                    &[&download, &next],
                )
                .await
                .map_err(dberr("download next"))?;
            outcome.events.push(LiveEvent::Command {
                device_id: ctx.device_id.to_owned(),
            });
        }
    }
    Ok(outcome)
}

/// Why an operator confirmation was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum ConfirmError {
    NotFound,
    Conflict(String),
    Invalid(String),
}

/// Operator confirmation of a held danger challenge (§7 step 3). When the
/// challenge reported unsaved frames, `confirm_unsaved` must echo the count.
pub async fn confirm<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    command_id: i64,
    confirm_unsaved: Option<i64>,
    user: &str,
    policy: &Rev2Policy,
) -> Result<Result<i64, ConfirmError>, String> {
    let now = Utc::now();
    let row = client
        .query_opt(
            "SELECT state,challenge,challenge_expires_at FROM commands
             WHERE id=$1 AND device_id=$2 AND protocol=2 FOR UPDATE",
            &[&command_id, &device],
        )
        .await
        .map_err(dberr("confirm lookup"))?;
    let Some(row) = row else {
        return Ok(Err(ConfirmError::NotFound));
    };
    let state: String = row.get(0);
    let challenge: Option<Value> = row.get(1);
    let expires: Option<DateTime<Utc>> = row.get(2);
    if state != "challenge" {
        return Ok(Err(ConfirmError::Conflict(format!(
            "command is {state}, not awaiting confirmation"
        ))));
    }
    let (Some(challenge), Some(expires)) = (challenge, expires) else {
        return Ok(Err(ConfirmError::Conflict("no challenge recorded".into())));
    };
    if expires <= now {
        return Ok(Err(ConfirmError::Conflict(
            "the challenge expired (nexp passed); queue the command again".into(),
        )));
    }
    let pending = client
        .query_opt(
            "SELECT 1 FROM commands WHERE parent_id=$1 AND state IN ('queued','sent')",
            &[&command_id],
        )
        .await
        .map_err(dberr("pending confirm"))?
        .is_some();
    if pending {
        return Ok(Err(ConfirmError::Conflict(
            "a confirmation is already pending".into(),
        )));
    }
    let frames = challenge.get("unsaved_frames").and_then(Value::as_i64);
    let mut args =
        json!({"ref":command_id,"nonce":challenge.get("nonce").cloned().unwrap_or(Value::Null)});
    match frames {
        Some(frames) if frames > 0 => {
            if confirm_unsaved != Some(frames) {
                return Ok(Err(ConfirmError::Invalid(format!(
                    "the logger reported {frames} unsaved frames; confirm_unsaved must equal {frames}"
                ))));
            }
            args["confirm_unsaved"] = json!(frames);
        }
        _ => {
            if confirm_unsaved.is_some_and(|n| n != 0) {
                return Ok(Err(ConfirmError::Invalid(
                    "the challenge reported no unsaved data".into(),
                )));
            }
        }
    }
    let options = QueueOptions {
        requested_by: user,
        origin: "operator",
        expires_at: expires,
        parent_id: Some(command_id),
        ..QueueOptions::new(policy, now)
    };
    match queue(client, device, "confirm", &args, &options).await? {
        Some(id) => Ok(Ok(id)),
        None => Ok(Err(ConfirmError::Conflict(
            "the device no longer accepts revision 2 commands".into(),
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ack_statuses_map_to_final_states() {
        assert_eq!(
            final_state(AckStatus::Ok, None),
            ("acked", Some("ok"), false)
        );
        assert_eq!(
            final_state(AckStatus::Partial, None),
            ("acked", Some("partial"), false)
        );
        assert_eq!(
            final_state(AckStatus::Rejected, Some("bad-args")),
            ("acked", Some("rejected"), false)
        );
        // busy: re-send after the next sleep; time-invalid: after a sync.
        assert_eq!(
            final_state(AckStatus::Rejected, Some("busy")),
            ("queued", None, true)
        );
        assert_eq!(
            final_state(AckStatus::Rejected, Some("time-invalid")),
            ("queued", None, true)
        );
        assert_eq!(
            final_state(AckStatus::Expired, None),
            ("expired", Some("expired"), false)
        );
        assert_eq!(
            final_state(AckStatus::Duplicate, None),
            ("acked", Some("duplicate"), false)
        );
    }

    #[test]
    fn wire_payloads_use_the_command_id_and_publish_time() {
        let now = crate::rev2_store::utc(1_763_300_000);
        let exp = now + chrono::Duration::days(7);
        assert_eq!(
            wire(42, exp, "get_status", &json!({}), false, now),
            r#"{"v":2,"id":42,"exp":1763904800,"op":"get_status"}"#
        );
        // sync_time's t is the publish instant, not the queue instant.
        let later = now + chrono::Duration::minutes(3);
        assert_eq!(
            wire(7, exp, "sync_time", &json!({}), false, later),
            r#"{"v":2,"id":7,"exp":1763904800,"op":"sync_time","args":{"t":1763300180}}"#
        );
    }

    #[test]
    fn prepare_enforces_contract_and_size() {
        let now = crate::rev2_store::utc(1_763_300_000);
        assert!(prepare("get_status", &json!({}), false, now).is_ok());
        assert!(prepare("get_status", &json!({}), true, now).is_err());
        assert!(prepare("settings", &json!({"read_s":900}), true, now).is_ok());
        let long = "x".repeat(64);
        // The largest valid settings request still fits in 1,024 bytes.
        assert!(prepare(
            "settings",
            &json!({"read_s":900,"send_s":86400,"gps_mode":2,"gps_val":3600,"tilt_mode":2,"tilt_val":3600,
                "start":0,"fac":[1.25e-3,1.0,2.5,-0.25],"tap":1,"tap_sens":5,"gps_sens":5,"lo":1.5,"hi":10.5,
                "lo_hys":0.25,"hi_hys":0.25,"loc":"x".repeat(32),"proj":"y".repeat(32),"text":long,
                "partial":0,"utc_off":600,"led":1,"attempts":3,"listen_s":120}),
            false,
            now
        )
        .is_ok());
        assert!(prepare("wipe_mram", &json!({}), false, now).is_ok());
        assert!(prepare("teleport", &json!({}), false, now).is_err());
    }

    #[test]
    fn danger_operations_get_the_shorter_default_expiry() {
        let policy = Rev2Policy::default();
        let now = crate::rev2_store::utc(1_763_300_000);
        assert_eq!(
            QueueOptions::for_op("wipe_sd", &policy, now).expires_at,
            now + chrono::Duration::days(1)
        );
        assert_eq!(
            QueueOptions::for_op("get_status", &policy, now).expires_at,
            now + chrono::Duration::days(7)
        );
    }
}
