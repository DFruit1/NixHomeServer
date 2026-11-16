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
//! (the logger queues four); later commands wait behind one held by
//! `rejected`/`busy`, so the logger runs them in the order they were queued.
//! `sync_time` and nonce confirmations are only meaningful in the current
//! awake window, so they are never re-published. The first final ack wins:
//! repeated or `duplicate` acks for an acked command are only recorded.

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
    /// `auto-restore`, `auto-confirm`, `download`.
    pub origin: &'a str,
    pub expires_at: DateTime<Utc>,
    pub preconfirmed: bool,
    pub live_only: bool,
    pub parent_id: Option<i64>,
    pub download_id: Option<i64>,
    pub replace: bool,
    /// Extend `expires_at` past the device's next connection (plus its
    /// listen window and the stale margin): the one it announced when that
    /// is still ahead, and in any case one send interval (`send_s` of its
    /// effective settings) from now, so a logger reporting every 27 days
    /// never receives a command already expired. Every default lifetime
    /// uses it; an operator's explicit expiry and window-bound commands do
    /// not.
    pub cover_next_contact: bool,
}

impl<'a> QueueOptions<'a> {
    /// Defaults for server-issued commands: `basic_expiry_seconds`, at least
    /// until the device's next connection has passed.
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
            cover_next_contact: true,
        }
    }
    /// Operator defaults for `op`'s channel: basic/settings expire after
    /// `basic_expiry_seconds`, danger after `danger_expiry_seconds`, and in
    /// either case not before the device's next connection has passed. An
    /// operator who gives a lifetime gets exactly that (the API clears
    /// `cover_next_contact`).
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
    if rev2::UNSUPPORTED_BY_FIRMWARE.contains(&op) {
        return Err(format!(
            "{op} is not supported by firmware 2.2 (the logger answers rejected/unsupported)"
        ));
    }
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
    let margin = crate::config::rev2_policy().stale_margin_seconds as f64;
    let row = client
        .query_opt(
            "INSERT INTO commands(device_id,kind,payload,wire_payload,requested_by,firmware_ack_expected,protocol,op,args,
                replace_settings,expires_at,preconfirmed,live_only,origin,parent_id,download_id)
             SELECT d.device_id,$2,$3,'',$4,true,2,$5,$6,$7,
                CASE WHEN $14 THEN GREATEST($8::timestamptz,
                    CASE WHEN d.next_contact_at>now() THEN d.next_contact_at END
                        +make_interval(secs=>COALESCE(d.listen_window_s,60)+$15::double precision),
                    now()+make_interval(secs=>COALESCE(groundwater_send_interval(d.settings),0)
                        +COALESCE(d.listen_window_s,60)+$15::double precision))
                    ELSE $8::timestamptz END,
                $9,$10,$11,$12,$13 FROM devices d
             WHERE d.device_id=$1 AND d.revoked_at IS NULL
               AND groundwater_command_supported(d.source_profile,$2,$3,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE
             RETURNING id,expires_at",
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
                &options.cover_next_contact,
                &margin,
            ],
        )
        .await
        .map_err(dberr("command queue"))?;
    let Some(row) = row else { return Ok(None) };
    let id: i64 = row.get(0);
    let expires_at: DateTime<Utc> = row.get(1);
    if id > i64::from(u32::MAX) {
        // [22003]: a value out of range, kept visible (not retried for
        // ever by ingest) when it happens while storing a message.
        return Err("command id exceeds the protocol's u32 range [22003]".into());
    }
    client
        .execute(
            "UPDATE commands SET wire_payload=$2 WHERE id=$1",
            &[&id, &wire(id, expires_at, op, &args, options.replace, now)],
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
               -- A re-publish after a sleep waits for the logger's next
               -- connection: its ack from the window that closed may still
               -- be on the way behind a backlog on the durable session (the
               -- sleep travels on the control session and overtakes it).
               AND (c.republish_after IS NULL OR (d.link_state IN ('online','ready') AND NOT d.link_retained
                    AND d.link_state_at>c.republish_after))
               AND groundwater_command_supported(d.source_profile,c.kind,c.payload,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE
               AND (c.expires_at IS NULL OR c.expires_at>now())
               AND (NOT c.live_only OR (d.link_state IN ('online','ready') AND NOT d.link_retained
                    AND d.link_state_at>now()-make_interval(secs=>COALESCE(d.listen_window_s,60)+180)))
               -- A confirmation runs its parent's destructive op: never
               -- publish one for a parent no longer awaiting it (cancelled,
               -- expired, already acked).
               AND (c.op<>'confirm' OR EXISTS(SELECT 1 FROM commands p WHERE p.id=c.parent_id AND p.state='challenge'))
               AND (c.op='confirm' OR c.live_only OR NOT EXISTS(SELECT 1 FROM commands h WHERE h.device_id=c.device_id
                    AND h.protocol=2 AND h.state='queued' AND h.id<c.id AND (h.hold_until_sleep
                        OR (h.republish_after IS NOT NULL AND NOT (d.link_state IN ('online','ready')
                            AND NOT d.link_retained AND d.link_state_at>h.republish_after)))))
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
                status_reason='the logger slept right after this publish without acknowledging it',
                republish_after=d.link_state_at
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
                    ELSE 'no ack before the logger slept; re-publishing at its next connection' END,
                republish_after=$2
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
    let mut devices: Vec<String> = rows.iter().map(|row| row.get(0)).collect();
    // A gap request or download chunk whose command ended without an ack
    // (expired, given up after the re-publishes, cancelled) would otherwise
    // stay `requested`/`active` forever: nothing re-requests the gap and
    // nothing issues the next chunk.
    let released = client
        .query(
            "WITH gaps AS (
                UPDATE stream_gaps g SET state=CASE WHEN g.attempts>=$1 THEN 'unrecoverable' ELSE 'open' END,
                    resolved_at=CASE WHEN g.attempts>=$1 THEN now() ELSE NULL END
                FROM commands c WHERE g.command_id=c.id AND g.state='requested'
                    AND c.state IN ('expired','unacknowledged','cancelled')
                RETURNING g.device_id),
             downloads AS (
                UPDATE file_downloads f SET state='failed',error='chunk command '||c.state||' without data',updated_at=now()
                FROM commands c WHERE f.current_command_id=c.id AND f.state='active'
                    AND c.state IN ('expired','unacknowledged','cancelled')
                RETURNING f.device_id)
             SELECT device_id FROM gaps UNION SELECT device_id FROM downloads",
            &[&crate::config::rev2_policy().max_gap_attempts],
        )
        .await
        .map_err(dberr("gap and download release"))?;
    for row in released {
        let device: String = row.get(0);
        if !devices.contains(&device) {
            devices.push(device);
        }
    }
    Ok(devices)
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
    state: String,
    /// The challenged command's op, for a `confirm`.
    parent_op: Option<String>,
    final_status: Option<String>,
}

async fn load_command<C: GenericClient + Sync>(
    client: &C,
    device: &str,
    id: i64,
) -> Result<Option<CommandRow>, String> {
    let row = client
        .query_opt(
            "SELECT c.id,c.op,c.kind,c.parent_id,c.origin,c.download_id,c.args,c.preconfirmed,c.publish_count,c.state,p.op,
                c.final_status
             FROM commands c LEFT JOIN commands p ON p.id=c.parent_id
             WHERE c.id=$1 AND c.device_id=$2 AND c.protocol=2 FOR UPDATE OF c",
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
        state: row.get(9),
        parent_op: row.get(10),
        final_status: row.get(11),
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
    // The logger names the op it ran (a confirm's ack names the confirmed
    // op; a parse-time rejection may omit it). Another op under this id is
    // not about this command: an id from before a database restore, or a
    // forged ack. Applying it would show the wrong outcome.
    if !ack_op_matches(&command, &ack.op) {
        server_event(
            client,
            ctx.device_id,
            "unmatched_ack",
            ctx.received_at,
            json!({"id":ack.id,"op":ack.op,"status":ack.status.as_str(),"command_op":command.op}),
        )
        .await?;
        return Ok(Outcome::rejected(format!(
            "ack id {} names op {} but command {} is {}",
            ack.id, ack.op, command.id, command.op
        )));
    }
    // A final ack is final. A second ack for the same id is a QoS 1
    // redelivery, or the logger's `duplicate` answer to a copy re-published
    // after a `sleep` that overtook the ack (status and acks travel on
    // different MQTT sessions). It must not replace the outcome: a
    // `duplicate`/`challenge` after a confirmed wipe would otherwise show
    // the executed wipe as failed and invite the operator to run it again.
    // The one exception: the logger's `duplicate` answer to a re-published
    // copy was processed first, and the original ack (its result and data)
    // arrives after it, for example behind a slow backlog on the durable
    // session (E2E-02). The original is the outcome and is applied.
    let original_after_duplicate = command.final_status.as_deref() == Some("duplicate")
        && !matches!(ack.status, AckStatus::Duplicate | AckStatus::Challenge);
    if command.state == "acked" && !original_after_duplicate {
        server_event(
            client,
            ctx.device_id,
            "repeated_ack",
            ctx.received_at,
            json!({"command_id":command.id,"op":ack.op,"status":ack.status.as_str(),"prev":ack.prev}),
        )
        .await?;
        return Ok(Outcome {
            detail: Some(format!(
                "command {} already has its final ack; {} recorded only",
                command.id,
                ack.status.as_str()
            )),
            ..Outcome::default()
        });
    }
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

/// Whether an ack's `op` can belong to `command`.
fn ack_op_matches(command: &CommandRow, op: &str) -> bool {
    op.is_empty()
        || op == command.op
        || (command.op == "confirm" && command.parent_op.as_deref() == Some(op))
}

/// Final state for an ack status: `(state, final_status, hold_until_sleep)`.
/// `prev` is a `duplicate` ack's earlier status. The logger remembers a
/// danger challenge under its id, so re-sending that id after the challenge
/// lapsed answers `duplicate`/`challenge`: the command never ran and the id
/// is spent, so it fails rather than counting as done.
pub fn final_state(
    status: AckStatus,
    reason: Option<&str>,
    prev: Option<&str>,
) -> (&'static str, Option<&'static str>, bool) {
    match (status, reason) {
        (AckStatus::Duplicate, _) if prev == Some("challenge") => ("acked", Some("failed"), false),
        (AckStatus::Duplicate, _) if prev == Some("expired") => ("expired", Some("expired"), false),
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
    let (mut state, final_status, hold) =
        final_state(ack.status, ack.reason.as_deref(), ack.prev.as_deref());
    let reason = match ack.status {
        AckStatus::Duplicate if ack.prev.as_deref() == Some("challenge") => Some(
            "previously challenge: the challenge lapsed unconfirmed; queue the command again"
                .to_owned(),
        ),
        AckStatus::Duplicate => ack.prev.clone().map(|prev| format!("previously {prev}")),
        _ => ack.reason.clone(),
    };
    let mut hold = hold;
    let mut reason = reason;
    // The ack (telemetry session) and `sleep` (control session) are
    // processed in either order. A `busy` ack processed after a fresh sleep
    // came from the window that already ended: no later sleep in this cycle
    // would release the hold, and every command queued behind it would wait
    // a whole connection cycle. Re-send it in the next window instead. A
    // confirm keeps its hold: its nonce dies with the window.
    if hold && command.op != "confirm" && window_closed(client, ctx).await? {
        hold = false;
        reason = Some(format!(
            "{} in the window that has just closed; re-sent in the next window",
            reason.as_deref().unwrap_or("rejected")
        ));
    }
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
                // Also when the parent was already expired: the `sleep` that
                // closed the window can be processed before this ack (they
                // use different MQTT sessions), and the logger did run it.
                "UPDATE commands SET state=$2,final_status=$3,status_reason=$4,acked_at=$5,ack_payload=$6
                 WHERE id=$1 AND state<>'acked'",
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

/// Whether the device's last live status is a `sleep`/`offline` processed
/// at most one listen window (plus 3 minutes) before this message: the
/// message was produced in the window that status closed.
async fn window_closed<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
) -> Result<bool, String> {
    Ok(client
        .query_one(
            "SELECT COALESCE(bool_or(link_state IN ('sleep','offline') AND NOT link_retained AND link_state_at<=$2
                AND link_state_at>$2::timestamptz-make_interval(secs=>COALESCE(listen_window_s,60)+180)),false)
             FROM devices WHERE device_id=$1",
            &[&ctx.device_id, &ctx.received_at],
        )
        .await
        .map_err(dberr("window check"))?
        .get(0))
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
    // The confirm must carry the nonce back; one the contract cannot carry
    // would fail queue() with an error that is not the database's, and
    // ingest would retry this message for ever.
    if nonce.is_empty() || nonce.len() > 16 {
        outcome.rejected = Some(format!(
            "challenge nonce must be 1-16 characters, got {}",
            nonce.len()
        ));
        return Ok(());
    }
    // A cancelled or lapsed command reaches the logger anyway when it was
    // already in the persistent session. Its challenge is recorded but never
    // reopened, so nobody (and no auto-confirm) can confirm a destructive
    // op the operator withdrew; the nonce lapses on the logger by itself.
    if !matches!(command.state.as_str(), "queued" | "sent" | "challenge") {
        server_event(
            client,
            ctx.device_id,
            "challenge_ignored",
            ctx.received_at,
            json!({"command_id":command.id,"op":command.op,"state":command.state,"nexp":nexp}),
        )
        .await?;
        outcome.detail = Some(format!(
            "challenge for command {} ignored: it is {}",
            command.id, command.state
        ));
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
            cover_next_contact: false,
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
        "file_chunk" if success || ack.status == AckStatus::Duplicate => {
            let off = data
                .get("off")
                .or_else(|| command.args.get("off"))
                .and_then(Value::as_i64)
                .unwrap_or(0);
            // A duplicate re-sent nothing, so there is nothing to compare.
            let expected = success.then(|| {
                (
                    data.get("len").and_then(Value::as_i64),
                    data.get("crc32")
                        .and_then(Value::as_str)
                        .and_then(|h| u32::from_str_radix(h, 16).ok()),
                )
            });
            if let Some(download) = command.download_id
                && let Some(error) =
                    check_chunk_ack(client, download, command.id, off, expected).await?
            {
                fail_download(client, download, &error).await?;
                outcome.events.push(LiveEvent::Download {
                    device_id: ctx.device_id.to_owned(),
                });
            }
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
            // `data`: the clock afterwards and whether this command set it.
            // `"set":false`: the clock was already within 2 s, nothing was
            // stepped, so it is not a clock sync.
            let set = data.get("set").and_then(Value::as_bool) != Some(false);
            server_event(
                client,
                ctx.device_id,
                if set {
                    "clock_synced"
                } else {
                    "clock_sync_unchanged"
                },
                ctx.received_at,
                json!({"command_id":command.id,"t":data.get("t"),"tv":data.get("tv"),
                    "set":data.get("set")}),
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

/// Compares a `file_chunk` ack with the `data/file` chunk stored for it
/// (the logger publishes the chunk before the ack). Returns why the download
/// must fail: the chunk never arrived, or its length or CRC-32 differ from
/// what the logger read.
async fn check_chunk_ack<C: GenericClient + Sync>(
    client: &C,
    download: i64,
    command_id: i64,
    off: i64,
    expected: Option<(Option<i64>, Option<u32>)>,
) -> Result<Option<String>, String> {
    let len = expected
        .and_then(|(len, _)| len)
        .unwrap_or(0)
        .clamp(0, 65_536) as i32;
    let row = client
        .query_opt(
            "SELECT f.state,f.current_command_id,COALESCE(ch.data,CASE WHEN f.state='complete'
                    THEN substring(f.content FROM ($2::bigint+1)::int FOR $3::int) END)
             FROM file_downloads f LEFT JOIN file_download_chunks ch ON ch.download_id=f.id AND ch.offset_bytes=$2::bigint
             WHERE f.id=$1 FOR UPDATE OF f",
            &[&download, &off.clamp(0, i64::from(i32::MAX) - 1), &len],
        )
        .await
        .map_err(dberr("chunk ack check"))?;
    let Some(row) = row else { return Ok(None) };
    let state: String = row.get(0);
    let current: Option<i64> = row.get(1);
    let stored: Option<Vec<u8>> = row.get(2);
    match (state.as_str(), stored) {
        ("active" | "complete", Some(stored)) => {
            let Some((len, crc)) = expected else {
                return Ok(None);
            };
            let actual = crate::crc::crc32(&stored);
            if len.is_some_and(|len| len != stored.len() as i64)
                || crc.is_some_and(|crc| crc != actual)
            {
                return Ok(Some(format!(
                    "chunk at offset {off} does not match the logger's ack (len {}/{}, crc32 {:08x}/{})",
                    stored.len(),
                    len.map_or("?".into(), |l| l.to_string()),
                    actual,
                    crc.map_or("?".into(), |c| format!("{c:08x}"))
                )));
            }
            Ok(None)
        }
        ("active", None) if current == Some(command_id) => Ok(Some(format!(
            "the logger answered file_chunk at offset {off} but no data/file chunk arrived"
        ))),
        _ => Ok(None),
    }
}

async fn fail_download<C: GenericClient + Sync>(
    client: &C,
    download: i64,
    error: &str,
) -> Result<(), String> {
    client
        .execute(
            "UPDATE file_downloads SET state='failed',error=$2,current_command_id=NULL,updated_at=now()
             WHERE id=$1 AND state IN ('active','complete')",
            &[&download, &error],
        )
        .await
        .map_err(dberr("download failure"))?;
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
        cover_next_contact: false,
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

/// Whether a `health` reports settings-lost RECOVERY: `mram:"recovery"`
/// with any latched error but 3. The firmware (`gwl_ring.c` boot and
/// `recover_mram`) enters it when both settings slots are invalid and no
/// snapshot restores them (err 4), stops logging, and leaves it as soon as
/// a `config/set` is applied. err 3 is the read-only metadata RECOVERY,
/// which refuses settings and needs `recover_mram`/`wipe_mram` instead; an
/// operator's `clear_error_latch` can reset err to 0 while the state stays.
pub fn settings_lost(health: &rev2::Health) -> bool {
    health.mram.as_deref() == Some("recovery") && health.err != Some(3)
}

/// The arguments that restore acknowledged settings with `replace`. The
/// logger echoes every key; a delayed `start` that has already passed is
/// sent as 0 (none), which is the same schedule and passes validation.
pub fn restore_args(settings: &Value, now: DateTime<Utc>) -> Result<Value, String> {
    let mut args = settings
        .as_object()
        .cloned()
        .ok_or("acknowledged settings are not an object")?;
    if args
        .get("start")
        .and_then(Value::as_i64)
        .is_some_and(|start| start <= now.timestamp())
    {
        args.insert("start".into(), json!(0));
    }
    let args = Value::Object(args);
    prepare("settings", &args, true, now)
}

/// Settings-lost RECOVERY (contract §8): re-sends the device's last
/// acknowledged settings as `settings` with `replace`, once per episode
/// (the episode lasts until a `health` no longer reports the state, so a
/// logger that keeps reporting it is never sent them again). With no
/// acknowledged settings, or once that command has ended and the logger
/// still reports the state, the `settings_lost` alert asks the operator to
/// send settings.
pub async fn maybe_restore_settings<C: GenericClient + Sync>(
    client: &C,
    ctx: &Context<'_>,
    health: &rev2::Health,
) -> Result<bool, String> {
    let lost = settings_lost(health);
    let row = client
        .query_one(
            "SELECT settings_lost_since,settings_restore_command_id FROM devices WHERE device_id=$1 FOR UPDATE",
            &[&ctx.device_id],
        )
        .await
        .map_err(dberr("settings recovery state"))?;
    let since: Option<DateTime<Utc>> = row.get(0);
    let mut command: Option<i64> = row.get(1);
    let alert = |active: Option<bool>, detail: Value| async move {
        client
            .execute(
                "SELECT groundwater_condition_alert($1,'settings_lost',$2,$3,$4,$5)",
                &[
                    &ctx.device_id,
                    &active,
                    &(health.err.unwrap_or(0) as f64),
                    &ctx.received_at,
                    &detail,
                ],
            )
            .await
            .map_err(dberr("settings lost alert"))
    };
    if !lost {
        if since.is_some() {
            client
                .execute(
                    "UPDATE devices SET settings_lost_since=NULL,settings_restore_command_id=NULL WHERE device_id=$1",
                    &[&ctx.device_id],
                )
                .await
                .map_err(dberr("settings recovery end"))?;
            server_event(
                client,
                ctx.device_id,
                "settings_recovery_ended",
                ctx.received_at,
                json!({"since":since,"command_id":command,"gen":health.settings_gen}),
            )
            .await?;
            alert(Some(false), json!({})).await?;
        }
        return Ok(false);
    }
    let mut queued = false;
    if since.is_none() {
        let previous = client
            .query_opt(
                "SELECT settings_gen,settings,source,command_id,received_at FROM device_settings_history
                 WHERE device_id=$1 AND source IN ('ack','get_settings') AND settings_gen IS NOT NULL
                 ORDER BY received_at DESC,id DESC LIMIT 1",
                &[&ctx.device_id],
            )
            .await
            .map_err(dberr("acknowledged settings"))?;
        let mut why = "the server has no settings this logger acknowledged".to_owned();
        if let Some(previous) = &previous {
            let generation: i64 = previous.get(0);
            match restore_args(&previous.get(1), ctx.received_at) {
                Ok(args) => {
                    let options = QueueOptions {
                        requested_by: "auto-restore",
                        origin: "auto-restore",
                        replace: true,
                        ..QueueOptions::new(ctx.policy, ctx.received_at)
                    };
                    command = queue(client, ctx.device_id, "settings", &args, &options).await?;
                    match command {
                        Some(id) => {
                            queued = true;
                            server_event(
                                client,
                                ctx.device_id,
                                "settings_restore_requested",
                                ctx.received_at,
                                json!({"command_id":id,"gen":generation,"source":previous.get::<_, String>(2),
                                    "acknowledged_at":previous.get::<_, DateTime<Utc>>(4),"err":health.err}),
                            )
                            .await?;
                        }
                        None => why = "the logger does not take revision 2 commands".into(),
                    }
                }
                Err(error) => {
                    why = format!("the acknowledged settings (generation {generation}) are not valid now: {error}")
                }
            }
        }
        client
            .execute(
                "UPDATE devices SET settings_lost_since=$2,settings_restore_command_id=$3 WHERE device_id=$1",
                &[&ctx.device_id, &ctx.received_at, &command],
            )
            .await
            .map_err(dberr("settings recovery start"))?;
        if command.is_none() {
            server_event(
                client,
                ctx.device_id,
                "settings_restore_unavailable",
                ctx.received_at,
                json!({"reason":why,"err":health.err}),
            )
            .await?;
            alert(
                Some(true),
                json!({"reason":why,"err":health.err,"action":"send settings"}),
            )
            .await?;
        }
        return Ok(queued);
    }
    // A later health in the same episode: the restore is still on its way,
    // or it ended and the logger still has no settings.
    let pending = match command {
        Some(id) => client
            .query_opt(
                "SELECT state IN ('queued','sent','challenge'),state,final_status,status_reason FROM commands WHERE id=$1",
                &[&id],
            )
            .await
            .map_err(dberr("restore command"))?,
        None => None,
    };
    match pending {
        Some(row) if row.get::<_, bool>(0) => {}
        Some(row) => {
            alert(
                Some(true),
                json!({"reason":"the automatic settings restore ended and the logger still has no settings",
                    "command_id":command,"state":row.get::<_, String>(1),
                    "final_status":row.get::<_, Option<String>>(2),
                    "status_reason":row.get::<_, Option<String>>(3),"err":health.err,"action":"send settings"}),
            )
            .await?;
        }
        None => {
            alert(
                Some(true),
                json!({"reason":"the server has no settings this logger acknowledged","err":health.err,
                    "action":"send settings"}),
            )
            .await?;
        }
    }
    Ok(false)
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
    let first = download_request(path, now)?;
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

/// The first `file_chunk` of a download, validated (the path rules).
/// `Err` is a message for the operator, never a database error.
pub fn download_request(path: &str, now: DateTime<Utc>) -> Result<Value, String> {
    let first = json!({"path":path,"off":0,"len":stream_chunk_len()});
    prepare("file_chunk", &first, false, now)?;
    Ok(first)
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
            "SELECT state,current_command_id,path,chunk_len,size FROM file_downloads WHERE id=$1 FOR UPDATE",
            &[&download],
        )
        .await
        .map_err(dberr("download lookup"))?;
    let state: String = row.get(0);
    let current: Option<i64> = row.get(1);
    let path: String = row.get(2);
    let chunk_len: i32 = row.get(3);
    let known_size: Option<i64> = row.get(4);
    let size = i64::from(chunk.total_size);
    if state != "active" {
        outcome.detail = Some(format!("download {download} is {state}; chunk kept"));
        return Ok(outcome);
    }
    // The file changed while it was read (the archive appends to its open
    // segment): chunks from both versions must not be stitched into a file
    // that looks complete.
    if let Some(known) = known_size.filter(|&known| known != size) {
        fail_download(
            client,
            download,
            &format!("the file changed size during the download ({known} → {size} bytes); download it again"),
        )
        .await?;
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
        cover_next_contact: false,
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
            final_state(AckStatus::Ok, None, None),
            ("acked", Some("ok"), false)
        );
        assert_eq!(
            final_state(AckStatus::Partial, None, None),
            ("acked", Some("partial"), false)
        );
        assert_eq!(
            final_state(AckStatus::Rejected, Some("bad-args"), None),
            ("acked", Some("rejected"), false)
        );
        // busy: re-send after the next sleep; time-invalid: after a sync.
        assert_eq!(
            final_state(AckStatus::Rejected, Some("busy"), None),
            ("queued", None, true)
        );
        assert_eq!(
            final_state(AckStatus::Rejected, Some("time-invalid"), None),
            ("queued", None, true)
        );
        assert_eq!(
            final_state(AckStatus::Expired, None, None),
            ("expired", Some("expired"), false)
        );
        assert_eq!(
            final_state(AckStatus::Duplicate, None, Some("ok")),
            ("acked", Some("duplicate"), false)
        );
        // A lapsed danger challenge never ran; its id is spent.
        assert_eq!(
            final_state(AckStatus::Duplicate, None, Some("challenge")),
            ("acked", Some("failed"), false)
        );
        assert_eq!(
            final_state(AckStatus::Duplicate, None, Some("expired")),
            ("expired", Some("expired"), false)
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

    /// `tests/vectors/rev2-server-vectors.json` `commands`, written by the
    /// independent Python generator and parsed by the firmware's gwl_proto
    /// on the host: the server builds each wire byte for byte and refuses
    /// exactly the ones marked refused.
    #[test]
    fn server_command_vectors() {
        let vectors: Value =
            serde_json::from_str(include_str!("../tests/vectors/rev2-server-vectors.json"))
                .unwrap();
        let cases = vectors["commands"].as_array().unwrap();
        assert!(cases.len() >= 30);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let op = case["op"].as_str().unwrap();
            let replace = case["replace"] == true;
            let now = crate::rev2_store::utc(case["now"].as_i64().unwrap());
            let prepared = prepare(op, &case["args"], replace, now);
            if let Some(fragment) = case["refused"].as_str() {
                let error = prepared.expect_err(name);
                assert!(error.contains(fragment), "{name}: {error}");
                continue;
            }
            let args = prepared.unwrap_or_else(|e| panic!("{name}: {e}"));
            let publish = case["publish_t"]
                .as_i64()
                .map_or(now, crate::rev2_store::utc);
            let built = wire(
                case["id"].as_i64().unwrap(),
                crate::rev2_store::utc(case["exp"].as_i64().unwrap()),
                op,
                &args,
                replace,
                publish,
            );
            assert_eq!(built, case["wire"].as_str().unwrap(), "{name}");
            assert!(built.len() <= rev2::MAX_DOWNLINK_BYTES, "{name}");
            let channel = match rev2::kind_of(op).unwrap() {
                rev2::CommandKind::Config => "config/set",
                rev2::CommandKind::Basic => "cmd/basic",
                rev2::CommandKind::Danger => "cmd/danger",
            };
            assert_eq!(channel, case["channel"], "{name}");
        }
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

/// Database regressions for command delivery and the danger handshake
/// (round 3 review: an executed wipe shown as failed, a withdrawn wipe
/// auto-confirmed, gap requests stuck after their command lapsed).
#[cfg(test)]
mod db_tests {
    use super::*;
    use tokio_postgres::Client;

    const DEV: &str = "6A1B2C3D4E5F60718293C0DE";

    async fn setup() -> Client {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
        let client = crate::db::connect(&url).await.unwrap();
        crate::db::migrate(&client).await.unwrap();
        client
            .batch_execute(
                "TRUNCATE devices,device_bindings,commands,command_events,command_publish_attempts,
                    device_events,stream_gaps,file_downloads,file_download_chunks RESTART IDENTITY CASCADE",
            )
            .await
            .unwrap();
        client
            .execute(
                "INSERT INTO devices(device_id,display_name,source_profile,clock_policy) VALUES($1,'bore','V22','utc')",
                &[&DEV],
            )
            .await
            .unwrap();
        client
    }

    async fn ack(client: &Client, channel: &str, value: Value) -> Outcome {
        let policy = Rev2Policy::default();
        let ctx = Context {
            device_id: DEV,
            channel,
            received_at: Utc::now(),
            retained: false,
            delivery_id: Some(0),
            policy: &policy,
        };
        let object = rev2::object(value.to_string().as_bytes()).unwrap();
        handle_ack(client, &ctx, &object).await.unwrap()
    }

    async fn state(client: &Client, id: i64) -> (String, Option<String>) {
        let row = client
            .query_one(
                "SELECT state,final_status FROM commands WHERE id=$1",
                &[&id],
            )
            .await
            .unwrap();
        (row.get(0), row.get(1))
    }

    async fn confirms(client: &Client) -> i64 {
        client
            .query_one("SELECT count(*) FROM commands WHERE op='confirm'", &[])
            .await
            .unwrap()
            .get(0)
    }

    async fn queue_sent(client: &Client, op: &str, preconfirmed: bool) -> i64 {
        let policy = Rev2Policy::default();
        let options = QueueOptions {
            preconfirmed,
            ..QueueOptions::for_op(op, &policy, Utc::now())
        };
        let id = queue(client, DEV, op, &json!({}), &options)
            .await
            .unwrap()
            .unwrap();
        client
            .execute(
                "UPDATE commands SET state='sent',publish_count=1,last_published_at=now()-interval '1 minute' WHERE id=$1",
                &[&id],
            )
            .await
            .unwrap();
        id
    }

    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn repeated_acks_never_rewrite_an_executed_wipe() {
        let client = setup().await;
        let policy = Rev2Policy::default();
        let wipe = queue_sent(&client, "wipe_sd", false).await;
        let nexp = (Utc::now() + chrono::Duration::seconds(120)).timestamp();
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":wipe,"op":"wipe_sd","status":"challenge","nonce":"9F3A01C2","nexp":nexp}),
        )
        .await;
        let confirm_id = confirm(&client, DEV, wipe, None, "operator", &policy)
            .await
            .unwrap()
            .unwrap();
        client
            .execute(
                "UPDATE commands SET state='sent',publish_count=1,last_published_at=now()-interval '1 second' WHERE id=$1",
                &[&confirm_id],
            )
            .await
            .unwrap();
        // `sleep` (control session) overtakes the confirm's ack (telemetry
        // session): the window-close rule expires both first.
        on_status(
            &client,
            DEV,
            rev2::PresenceState::Sleep,
            Utc::now(),
            &policy,
        )
        .await
        .unwrap();
        assert_eq!(state(&client, wipe).await.0, "expired");
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":confirm_id,"op":"wipe_sd","ref":wipe,"status":"ok"}),
        )
        .await;
        let done = ("acked".to_owned(), Some("ok".to_owned()));
        assert_eq!(state(&client, wipe).await, done, "the wipe ran");
        assert_eq!(state(&client, confirm_id).await, done);
        // The re-published request copy is answered duplicate/challenge, a
        // redelivered confirm ack duplicate/ok: neither changes the outcome.
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":wipe,"op":"wipe_sd","status":"duplicate","prev":"challenge"}),
        )
        .await;
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":confirm_id,"op":"wipe_sd","status":"duplicate","prev":"ok"}),
        )
        .await;
        assert_eq!(state(&client, wipe).await, done);
        assert_eq!(state(&client, confirm_id).await, done);
        // An ack naming another op under this id is not applied.
        let status = queue_sent(&client, "get_status", false).await;
        let outcome = ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":status,"op":"wipe_mram","status":"ok"}),
        )
        .await;
        assert!(outcome.rejected.is_some());
        assert_eq!(state(&client, status).await.0, "sent");
    }

    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn withdrawn_danger_is_never_auto_confirmed() {
        let client = setup().await;
        let nexp = (Utc::now() + chrono::Duration::seconds(120)).timestamp();
        let challenge = |id: i64| json!({"v":2,"id":id,"op":"wipe_sd","status":"challenge","nonce":"0BADF00D","nexp":nexp});
        // Cancelled after it reached the broker: the logger still challenges.
        let withdrawn = queue_sent(&client, "wipe_sd", true).await;
        client
            .execute(
                "UPDATE commands SET state='cancelled' WHERE id=$1",
                &[&withdrawn],
            )
            .await
            .unwrap();
        ack(&client, "cmd/ack", challenge(withdrawn)).await;
        assert_eq!(state(&client, withdrawn).await.0, "cancelled");
        assert_eq!(
            confirms(&client).await,
            0,
            "a withdrawn wipe is never confirmed"
        );
        // The same request still pending is auto-confirmed as asked.
        let wanted = queue_sent(&client, "wipe_sd", true).await;
        ack(&client, "cmd/ack", challenge(wanted)).await;
        assert_eq!(state(&client, wanted).await.0, "challenge");
        assert_eq!(confirms(&client).await, 1);
    }

    // A challenge ack is logger input: a nonce the confirm cannot carry
    // (empty, or longer than 16 characters) made queue() fail with a
    // non-database error, which ingest retries for ever without acking,
    // stalling the shared MQTT session for every logger.
    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn a_malformed_challenge_nonce_is_rejected_not_retried() {
        let client = setup().await;
        let nexp = (Utc::now() + chrono::Duration::seconds(120)).timestamp();
        let wipe = queue_sent(&client, "wipe_sd", true).await;
        let outcome = ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":wipe,"op":"wipe_sd","status":"challenge",
            "nonce":"0123456789ABCDEF0","nexp":nexp}),
        )
        .await;
        assert!(outcome.rejected.is_some());
        assert_eq!(confirms(&client).await, 0);
    }

    // R5 (independent review): `sleep` (control session) processed before
    // the logger's busy ack (telemetry session) left the command held with
    // no sleep to release it, and every command behind it waited a whole
    // connection cycle (a week on a weekly logger).
    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn a_busy_ack_after_the_sleep_does_not_cost_a_cycle() {
        let client = setup().await;
        let policy = Rev2Policy::default();
        client.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('k1',$1,'gwl/v1/'||$1||'/cmd/basic','V22')", &[&DEV]).await.unwrap();
        let a = queue_sent(&client, "get_status", false).await;
        client
            .execute(
                "UPDATE devices SET link_state='sleep',link_state_at=now(),link_retained=false WHERE device_id=$1",
                &[&DEV],
            )
            .await
            .unwrap();
        on_status(
            &client,
            DEV,
            rev2::PresenceState::Sleep,
            Utc::now(),
            &policy,
        )
        .await
        .unwrap();
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":a,"op":"get_status","status":"rejected","reason":"busy"}),
        )
        .await;
        let held: bool = client
            .query_one("SELECT hold_until_sleep FROM commands WHERE id=$1", &[&a])
            .await
            .unwrap()
            .get(0);
        assert!(!held);
        client.execute("UPDATE devices SET link_state='online',link_state_at=now(),link_retained=false WHERE device_id=$1", &[&DEV]).await.unwrap();
        let next = next_publish(&client, &policy).await.unwrap();
        assert!(next.is_some_and(|p| p.wire.contains(&format!("\"id\":{a},"))));
        // A busy ack while the logger is awake still holds until its sleep.
        client
            .execute(
                "UPDATE commands SET active_publish_attempt=NULL,state='acked' WHERE id=$1",
                &[&a],
            )
            .await
            .unwrap();
        let b = queue_sent(&client, "get_status", false).await;
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":b,"op":"get_status","status":"rejected","reason":"busy"}),
        )
        .await;
        let held: bool = client
            .query_one("SELECT hold_until_sleep FROM commands WHERE id=$1", &[&b])
            .await
            .unwrap()
            .get(0);
        assert!(held);
    }

    // R2 (independent review): cancelling a challenged wipe left its queued
    // confirm, which the scheduler then published, so the logger ran the
    // wipe the operator withdrew. A cancel withdraws every confirm of the
    // command, warns when one was already sent, and no confirm is published
    // for a parent that is not awaiting it.
    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn a_cancelled_danger_command_never_publishes_its_confirm() {
        let client = setup().await;
        let policy = Rev2Policy::default();
        client.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('k2',$1,'gwl/v1/'||$1||'/cmd/danger','V22')", &[&DEV]).await.unwrap();
        let nexp = (Utc::now() + chrono::Duration::seconds(120)).timestamp();
        let challenge = |id: i64| json!({"v":2,"id":id,"op":"wipe_sd","status":"challenge","nonce":"0BADF00D","nexp":nexp});
        let confirm_of = |parent: i64| {
            let client = &client;
            async move {
                client
                    .query_one("SELECT id FROM commands WHERE parent_id=$1", &[&parent])
                    .await
                    .unwrap()
                    .get::<_, i64>(0)
            }
        };
        // Queued confirm: withdrawn with its wipe, nothing published.
        let wipe = queue_sent(&client, "wipe_sd", true).await;
        ack(&client, "cmd/ack", challenge(wipe)).await;
        let confirm = confirm_of(wipe).await;
        let (cancelled, warning) = crate::platform::cancel_command(&client, DEV, wipe, "operator")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cancelled.state, "cancelled");
        assert_eq!(warning, None);
        assert_eq!(state(&client, confirm).await.0, "cancelled");
        assert!(next_publish(&client, &policy).await.unwrap().is_none());

        // Already published confirm: withdrawn too, and the operator is told.
        let wipe = queue_sent(&client, "wipe_sd", true).await;
        ack(&client, "cmd/ack", challenge(wipe)).await;
        let confirm = confirm_of(wipe).await;
        client
            .execute(
                "UPDATE commands SET state='sent',publish_count=1,last_published_at=now() WHERE id=$1",
                &[&confirm],
            )
            .await
            .unwrap();
        let (_, warning) = crate::platform::cancel_command(&client, DEV, wipe, "operator")
            .await
            .unwrap()
            .unwrap();
        assert!(warning.is_some_and(|w| w.contains("already sent")));
        // If it ran anyway, its ack shows the truth on both rows.
        ack(
            &client,
            "cmd/ack",
            json!({"v":2,"id":confirm,"op":"wipe_sd","status":"ok"}),
        )
        .await;
        assert_eq!(
            state(&client, wipe).await,
            ("acked".into(), Some("ok".into()))
        );

        // A confirm whose parent stopped awaiting it is never published.
        let wipe = queue_sent(&client, "wipe_sd", true).await;
        ack(&client, "cmd/ack", challenge(wipe)).await;
        client
            .execute("UPDATE commands SET state='expired' WHERE id=$1", &[&wipe])
            .await
            .unwrap();
        assert!(next_publish(&client, &policy).await.unwrap().is_none());

        // Reverse: cancelling the confirm leaves the wipe awaiting a new one.
        let wipe = queue_sent(&client, "wipe_sd", true).await;
        ack(&client, "cmd/ack", challenge(wipe)).await;
        let confirm = confirm_of(wipe).await;
        let (_, warning) = crate::platform::cancel_command(&client, DEV, confirm, "operator")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(warning, None);
        assert_eq!(state(&client, wipe).await.0, "challenge");
        let again = super::confirm(&client, DEV, wipe, None, "operator", &policy)
            .await
            .unwrap();
        assert!(again.is_ok(), "{again:?}");
    }

    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn lapsed_gap_requests_are_asked_again() {
        let client = setup().await;
        let flush = queue_sent(&client, "flush_mqtt", false).await;
        client
            .execute(
                "INSERT INTO stream_gaps(device_id,log_id,from_seq,to_seq,state,attempts,command_id)
                 VALUES($1,7,10,19,'requested',1,$2),($1,7,30,39,'requested',3,$2)",
                &[&DEV, &flush],
            )
            .await
            .unwrap();
        client
            .execute(
                "UPDATE commands SET expires_at=now()-interval '1 second' WHERE id=$1",
                &[&flush],
            )
            .await
            .unwrap();
        expire(&client).await.unwrap();
        assert_eq!(state(&client, flush).await.0, "expired");
        let gaps: Vec<String> = client
            .query("SELECT state FROM stream_gaps ORDER BY from_seq", &[])
            .await
            .unwrap()
            .iter()
            .map(|r| r.get(0))
            .collect();
        assert_eq!(gaps, ["open", "unrecoverable"]);
    }
}
