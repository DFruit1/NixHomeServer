//! Additive platform state. Enrollment and observations remain the source of
//! trust; ACLs never grant enrollment and command topics require exact bindings.
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use tokio_postgres::{Client, Row};

pub const WAKE_SECONDS: i64 = 8 * 60;

pub async fn migrate(client: &Client) -> Result<(), String> {
    client
        .batch_execute(include_str!("platform.sql"))
        .await
        .map_err(|e| format!("platform migration: {e:?}"))?;
    client
        .batch_execute(include_str!("rev2.sql"))
        .await
        .map_err(|e| format!("protocol revision 2 migration: {e:?}"))?;
    client
        .batch_execute(include_str!("ops.sql"))
        .await
        .map_err(|e| format!("operations migration: {e:?}"))
}

pub async fn allowed(
    client: &Client,
    username: &str,
    device: &str,
    operator: bool,
) -> Result<bool, String> {
    client.query_one("SELECT EXISTS(SELECT 1 FROM devices d WHERE d.device_id=$2 AND ($3 OR EXISTS(SELECT 1 FROM device_permissions p WHERE p.device_id=d.device_id AND p.username=$1)))", &[&username, &device, &operator]).await.map(|r|r.get(0)).map_err(|e|e.to_string())
}

pub async fn visible_ids(
    client: &Client,
    username: &str,
    operator: bool,
) -> Result<Vec<String>, String> {
    client.query("SELECT device_id FROM devices d WHERE $2 OR EXISTS(SELECT 1 FROM device_permissions p WHERE p.device_id=d.device_id AND p.username=$1)", &[&username,&operator]).await.map(|rows|rows.iter().map(|r|r.get(0)).collect()).map_err(|e|e.to_string())
}

#[derive(Debug, Clone, Serialize)]
pub struct Command {
    pub id: i64,
    pub device_id: String,
    pub kind: String,
    pub payload: Value,
    pub state: String,
    pub requested_by: String,
    pub created_at: DateTime<Utc>,
    pub sent_at: Option<DateTime<Utc>>,
    pub acked_at: Option<DateTime<Utc>>,
    pub ack_payload: Option<Value>,
    pub attempts: i32,
    pub broker_acked_at: Option<DateTime<Utc>>,
    pub firmware_ack_expected: bool,
    pub cancelled_at: Option<DateTime<Utc>>,
    pub cancelled_by: Option<String>,
    pub supported: Option<bool>,
    /// 1 = legacy payloads, 2 = `{v,id,exp,op,args}` envelopes.
    pub protocol: i16,
    pub op: Option<String>,
    pub args: Option<Value>,
    pub expires_at: Option<DateTime<Utc>>,
    pub publish_count: i32,
    pub last_published_at: Option<DateTime<Utc>>,
    /// Revision 2 ack status: ok, partial, failed, rejected, expired, duplicate.
    pub final_status: Option<String>,
    pub status_reason: Option<String>,
    pub hold_until_sleep: bool,
    pub parent_id: Option<i64>,
    pub preconfirmed: bool,
    /// `{nonce,nexp,unsaved_frames,unsaved_bytes,received_at}` of a danger challenge.
    pub challenge: Option<Value>,
    pub challenge_expires_at: Option<DateTime<Utc>>,
    pub origin: String,
    pub download_id: Option<i64>,
}
fn command(row: Row) -> Command {
    Command {
        id: row.get("id"),
        device_id: row.get("device_id"),
        kind: row.get("kind"),
        payload: row.get("payload"),
        state: row.get("state"),
        requested_by: row.get("requested_by"),
        created_at: row.get("created_at"),
        sent_at: row.get("sent_at"),
        acked_at: row.get("acked_at"),
        ack_payload: row.get("ack_payload"),
        attempts: row.get("attempts"),
        broker_acked_at: row.get("broker_acked_at"),
        firmware_ack_expected: row.get("firmware_ack_expected"),
        cancelled_at: row.get("cancelled_at"),
        cancelled_by: row.get("cancelled_by"),
        supported: row.try_get("supported").ok(),
        protocol: row.try_get("protocol").unwrap_or(1),
        op: row.try_get("op").unwrap_or_default(),
        args: row.try_get("args").unwrap_or_default(),
        expires_at: row.try_get("expires_at").unwrap_or_default(),
        publish_count: row.try_get("publish_count").unwrap_or_default(),
        last_published_at: row.try_get("last_published_at").unwrap_or_default(),
        final_status: row.try_get("final_status").unwrap_or_default(),
        status_reason: row.try_get("status_reason").unwrap_or_default(),
        hold_until_sleep: row.try_get("hold_until_sleep").unwrap_or_default(),
        parent_id: row.try_get("parent_id").unwrap_or_default(),
        preconfirmed: row.try_get("preconfirmed").unwrap_or_default(),
        challenge: row.try_get("challenge").unwrap_or_default(),
        challenge_expires_at: row.try_get("challenge_expires_at").unwrap_or_default(),
        origin: row.try_get("origin").unwrap_or_else(|_| "operator".into()),
        download_id: row.try_get("download_id").unwrap_or_default(),
    }
}

/// One revision 2 command by id, for API responses.
pub async fn command_by_id(
    client: &Client,
    device: &str,
    id: i64,
) -> Result<Option<Command>, String> {
    client
        .query_opt(
            "SELECT c.*,true AS supported FROM commands c WHERE c.id=$1 AND c.device_id=$2",
            &[&id, &device],
        )
        .await
        .map(|row| row.map(command))
        .map_err(|e| e.to_string())
}
pub async fn queue(
    client: &Client,
    device: &str,
    kind: &str,
    payload: Value,
    wire: &str,
    username: &str,
) -> Result<Command, String> {
    client.query_one("WITH queued AS (INSERT INTO commands(device_id,kind,payload,wire_payload,requested_by,firmware_ack_expected) SELECT d.device_id,$2,$3,$4,$5,groundwater_firmware_ack_expected(EXISTS(SELECT 1 FROM device_bindings b WHERE b.device_id=d.device_id AND b.revoked_at IS NULL AND b.topic LIKE 'gwl/v1/%'),$2,$3) FROM devices d WHERE d.device_id=$1 AND d.revoked_at IS NULL RETURNING *), desired AS (UPDATE devices d SET desired_config=COALESCE(d.desired_config,'{}'::jsonb)||q.payload FROM queued q WHERE d.device_id=q.device_id AND q.kind='cfg') SELECT * FROM queued", &[&device,&kind,&payload,&wire,&username]).await.map(command).map_err(|e|format!("queue: {e:?}"))
}
pub async fn commands(
    client: &Client,
    ids: &[String],
    device: Option<&str>,
) -> Result<Vec<Command>, String> {
    client.query("SELECT c.*,groundwater_command_supported(d.source_profile,c.kind,c.payload,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE AS supported FROM commands c JOIN devices d ON d.device_id=c.device_id WHERE c.device_id=ANY($1) AND ($2::text IS NULL OR c.device_id=$2) ORDER BY c.id DESC LIMIT 500", &[&ids,&device]).await.map(|r|r.into_iter().map(command).collect()).map_err(|e|e.to_string())
}

pub async fn command_supported(
    client: &Client,
    device: &str,
    kind: &str,
    payload: &Value,
) -> Result<bool, String> {
    client.query_one("SELECT groundwater_command_supported(source_profile,$2,$3,clock_policy,local_offset_min,clock_change_unverified) IS TRUE FROM devices WHERE device_id=$1", &[&device,&kind,&payload])
        .await.map(|row| row.get(0)).map_err(|e| e.to_string())
}
pub async fn cancel(
    client: &Client,
    device: &str,
    id: i64,
    username: &str,
) -> Result<Option<Command>, String> {
    // Single SQL statement serializes against the publisher's reservation.
    client.query_opt("WITH changed AS (UPDATE commands SET state='cancelled',cancelled_at=now(),cancelled_by=$3 WHERE id=$2 AND device_id=$1 AND (state IN ('queued','sent') OR (protocol=2 AND state='challenge')) AND active_publish_attempt IS NULL RETURNING *), audit AS (INSERT INTO command_events(command_id,event,actor) SELECT id,'cancelled',$3 FROM changed) SELECT * FROM changed", &[&device,&id,&username]).await.map(|r|r.map(command)).map_err(|e|e.to_string())
}
/// Level alert rows as the revision 1 tests read them.
#[cfg(test)]
pub async fn alerts(
    client: &Client,
    ids: &[String],
    device: Option<&str>,
    state: Option<&str>,
) -> Result<Vec<Value>, String> {
    client.query("SELECT id,device_id,kind,state,trigger_value,opened_at,resolved_at FROM alerts WHERE NOT superseded AND device_id=ANY($1) AND ($2::text IS NULL OR device_id=$2) AND ($3::text IS NULL OR state=$3) ORDER BY opened_at DESC,id DESC LIMIT 1000", &[&ids,&device,&state]).await.map(|rows| rows.iter().map(|r|serde_json::json!({"id":r.get::<_,i64>(0),"device_id":r.get::<_,String>(1),"kind":r.get::<_,String>(2),"state":r.get::<_,String>(3),"trigger_value":r.get::<_,f64>(4),"opened_at":r.get::<_,DateTime<Utc>>(5),"resolved_at":r.get::<_,Option<DateTime<Utc>>>(6)})).collect()).map_err(|e|e.to_string())
}

/// A late sample dirties the historical replay; normal samples use the same
/// replay in a coalesced background batch, never once per backlog packet.
pub async fn refresh_alerts(client: &Client) -> Result<Vec<String>, String> {
    client.query("SELECT device_id, groundwater_replay_alerts(device_id) FROM devices WHERE alerts_dirty", &[]).await.map(|r|r.iter().map(|r|r.get(0)).collect()).map_err(|e|format!("alert replay: {e:?}"))
}

pub fn awake(now: DateTime<Utc>, ready: Option<DateTime<Utc>>, status: &str) -> bool {
    status == "awake"
        && ready.is_some_and(|r| now >= r && now < r + chrono::Duration::seconds(WAKE_SECONDS))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sleep_and_expired_ready_close_the_command_window() {
        let now = Utc::now();
        assert!(awake(now, Some(now), "awake"));
        assert!(!awake(now, Some(now), "asleep"));
        assert!(!awake(
            now,
            Some(now - chrono::Duration::seconds(480)),
            "awake"
        ));
        assert!(!awake(now, None, "awake"));
    }
}
