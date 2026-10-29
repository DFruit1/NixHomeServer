//! Durable, conservative command delivery. A queue insertion never publishes.
//! The MQTT event loop keeps polling independently of the publisher, including
//! while the client's bounded request queue is full.
use crate::{
    adapter::EnrollmentRegistry,
    ingest::{EventBus, LiveEvent},
    publisher::Publisher,
};
use chrono::{DateTime, Utc};
use rumqttc::AsyncClient;
use tokio_postgres::Client;

/// A live control connection is required for every command window. Cached
/// readiness from before a disconnect is never evidence of current wake state.
pub async fn invalidate_ready(client: &Client) -> Result<(), String> {
    client.execute("UPDATE devices SET presence_status=NULL,last_ready_at=NULL WHERE presence_status='awake'", &[])
        .await.map_err(|e| e.to_string())?;
    Ok(())
}

pub fn attributed<'a>(
    registry: &'a EnrollmentRegistry,
    topic: &str,
) -> Option<&'a crate::adapter::Binding> {
    let binding = registry.binding_for_topic(topic)?;
    let enrolled = registry.enrollment(&binding.device_id)?;
    // A flat firmware channel carries no identity. Its binding is valid only
    // for a single active enrollment; two physical loggers remain ambiguous.
    let flat = crate::topics::TopicMap::default()
        .subscribe_topics()
        .iter()
        .any(|t| t == topic);
    let ambiguous = flat && registry.enrollments().filter(|e| !e.revoked).count() > 1;
    (!enrolled.revoked && enrolled.profile == binding.profile && !ambiguous).then_some(binding)
}

pub async fn ancillary<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    registry: &EnrollmentRegistry,
    topic: &str,
    payload: &[u8],
    map: &crate::topics::TopicMap,
    now: DateTime<Utc>,
    bus: &EventBus,
) -> Result<Option<String>, String> {
    let Some(binding) = attributed(registry, topic) else {
        return Ok(None);
    };
    let Ok(text) = std::str::from_utf8(payload) else {
        return Ok(None);
    };
    if payload.len() > crate::adapter::MAX_PAYLOAD_BYTES {
        return Ok(None);
    }
    let device = &binding.device_id;
    let text = text.trim();
    let kind = crate::topics::classify(topic, map);
    if kind == crate::topics::MessageKind::DeviceStatus {
        let status = match text {
            "Ready" => "awake",
            "sleep" => "asleep",
            _ => return Ok(None),
        };
        client.execute("UPDATE devices SET last_seen=GREATEST(last_seen,$2),presence_status=$3,last_ready_at=CASE WHEN $3='awake' THEN $2 ELSE last_ready_at END WHERE device_id=$1 AND revoked_at IS NULL", &[&device,&now,&status]).await.map_err(|e|e.to_string())?;
        bus.emit(LiveEvent::Presence {
            device_id: device.clone(),
        });
        return Ok(Some(device.clone()));
    }
    let ack_kind = if topic.ends_with("cfg/desired/applied") {
        "cfg"
    } else if topic.ends_with("cfg/danger_ack") && text == "Danger Acknowledge" {
        "danger"
    } else if kind == crate::topics::MessageKind::TestResult {
        "test"
    } else {
        if matches!(
            kind,
            crate::topics::MessageKind::Gps
                | crate::topics::MessageKind::Storage
                | crate::topics::MessageKind::Motion
                | crate::topics::MessageKind::Alert
        ) && !text.is_empty()
        {
            client
                .execute(
                    "UPDATE devices SET last_seen=GREATEST(last_seen,$2) WHERE device_id=$1 AND revoked_at IS NULL",
                    &[&device, &now],
                )
                .await
                .map_err(|e| e.to_string())?;
            return Ok(Some(device.clone()));
        }
        return Ok(None);
    };
    client
        .execute(
            "UPDATE devices SET last_seen=GREATEST(last_seen,$2) WHERE device_id=$1 AND revoked_at IS NULL",
            &[&device, &now],
        )
        .await
        .map_err(|e| e.to_string())?;
    let parsed =
        serde_json::from_str::<serde_json::Value>(text).unwrap_or_else(|_| serde_json::json!(text));
    // Match only a command actually attempted in this Ready window. Identical
    // cfg echoes are compared as JSON, not formatting or key order.
    let changed=client.query(
        "WITH candidate AS (
            SELECT c.id,a.id AS attempt_id FROM commands c JOIN devices d ON d.device_id=c.device_id
            LEFT JOIN command_publish_attempts a ON a.id=c.active_publish_attempt AND a.state='inflight'
            WHERE c.device_id=$1 AND c.kind=$2 AND c.firmware_ack_expected
              AND (c.state IN ('queued','sent') OR ($2='test' AND c.state='acked'))
              AND d.presence_status='awake' AND d.last_ready_at>$3::timestamptz-interval '8 minutes'
              AND ((a.dispatched_at<=$3::timestamptz AND a.ready_at=d.last_ready_at)
                  OR (a.id IS NULL AND c.state IN ('sent','acked') AND c.broker_acked_at IS NOT NULL AND c.sent_at<=$3::timestamptz AND c.last_ready_at=d.last_ready_at))
              AND ($2<>'cfg' OR c.payload=$4::jsonb)
            ORDER BY c.id DESC LIMIT 1
        ), buffered AS (
            UPDATE command_publish_attempts a SET firmware_acked_at=COALESCE(a.firmware_acked_at,$3::timestamptz),
                firmware_ack_payload=CASE WHEN $2='test' THEN COALESCE(a.firmware_ack_payload,'[]'::jsonb)||jsonb_build_array($4::jsonb) ELSE $4::jsonb END
            FROM candidate WHERE a.id=candidate.attempt_id
        ) UPDATE commands c SET
            state=CASE WHEN candidate.attempt_id IS NULL THEN 'acked' ELSE c.state END,
            acked_at=CASE WHEN candidate.attempt_id IS NULL THEN COALESCE(c.acked_at,$3::timestamptz) ELSE c.acked_at END,
            ack_payload=CASE WHEN candidate.attempt_id IS NOT NULL THEN c.ack_payload WHEN $2='test' THEN COALESCE(c.ack_payload,'[]'::jsonb)||jsonb_build_array($4::jsonb) ELSE $4::jsonb END
        FROM candidate WHERE c.id=candidate.id RETURNING c.id,candidate.attempt_id IS NULL AS finalized",
        &[&device,&ack_kind,&now,&parsed]).await.map_err(|e|format!("ack match: {e:?}"))?;
    if !changed.is_empty() {
        if ack_kind == "cfg" && changed.iter().any(|r| r.get::<_, bool>(1)) {
            client
                .execute(
                    "UPDATE devices SET applied_config=COALESCE(applied_config,'{}'::jsonb)||$2::jsonb,last_seen=GREATEST(last_seen,$3) WHERE device_id=$1",
                    &[&device, &parsed, &now],
                )
                .await
                .map_err(|e| e.to_string())?;
        }
        bus.emit(LiveEvent::Command {
            device_id: device.clone(),
        });
    }
    Ok(Some(device.clone()))
}

/// Called only by the MQTT event-loop owner. SQL reservation commits before
/// the request is enqueued; no scheduler task can race packet correlation.
pub async fn tick(
    db: &mut Client,
    mqtt: &AsyncClient,
    bus: &EventBus,
    publisher: &mut Publisher,
) -> Result<(), String> {
    publisher.reconcile(db, bus).await?;
    if !publisher.connected || publisher.busy() {
        return Ok(());
    }
    let tx = db.transaction().await.map_err(|e| e.to_string())?;
    let rows=tx.query(
        "SELECT c.id,c.device_id,c.kind,c.wire_payload,d.last_ready_at
         FROM commands c JOIN devices d ON d.device_id=c.device_id
         WHERE c.active_publish_attempt IS NULL
           AND (c.state='queued' OR (c.state='sent' AND (c.firmware_ack_expected OR c.broker_acked_at IS NULL)))
           AND d.revoked_at IS NULL AND d.presence_status='awake'
           AND groundwater_command_supported(d.source_profile,c.kind,c.payload,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE
           AND d.last_ready_at<=now() AND d.last_ready_at>now()-interval '8 minutes'
           AND (d.last_downlink_at IS NULL OR d.last_downlink_at<=now()-interval '5 seconds')
           AND (c.broker_acked_at IS NULL OR c.last_ready_at IS NULL OR c.last_ready_at<d.last_ready_at)
           AND NOT EXISTS(SELECT 1 FROM commands prior WHERE prior.device_id=c.device_id AND prior.id<c.id
               AND (prior.state='queued' OR (prior.state='sent' AND (prior.firmware_ack_expected OR prior.broker_acked_at IS NULL)))
               AND groundwater_command_supported(d.source_profile,prior.kind,prior.payload,d.clock_policy,d.local_offset_min,d.clock_change_unverified) IS TRUE)
         ORDER BY c.id LIMIT 32 FOR UPDATE OF c,d SKIP LOCKED", &[])
        .await.map_err(|e|format!("scheduler select: {e:?}"))?;
    let mut prepared = None;
    for row in &rows {
        let id: i64 = row.get(0);
        let device: String = row.get(1);
        let kind: String = row.get(2);
        let wire: String = row.get(3);
        let ready: DateTime<Utc> = row.get(4);
        let base = match kind.as_str() {
            "project-settings" => "azman1/feeds/project-settings-slash-configuration",
            "cfg" => "cfg/desired",
            "danger" => "cmd/danger",
            "test" => "requesttesta",
            _ => return Err("invalid persisted command kind".into()),
        };
        let bindings = tx
            .query(
                "SELECT b.topic FROM device_bindings b JOIN devices d ON d.device_id=b.device_id
             WHERE b.device_id=$1 AND b.source_profile=d.source_profile AND b.revoked_at IS NULL
               AND (b.topic=$2 OR right(b.topic,length($2)+1)='/'||$2) ORDER BY b.topic",
                &[&device, &base],
            )
            .await
            .map_err(|e| e.to_string())?;
        if bindings.len() != 1 {
            continue;
        }
        let topic: String = bindings[0].get(0);
        let count: i64 = tx
            .query_one("SELECT count(*) FROM devices WHERE revoked_at IS NULL", &[])
            .await
            .map_err(|e| e.to_string())?
            .get(0);
        if topic == base && count != 1 {
            continue;
        }
        let attempt:i64=tx.query_one(
            "INSERT INTO command_publish_attempts(command_id,ready_at,topic) VALUES($1,$2,$3) RETURNING id",
            &[&id,&ready,&topic]).await.map_err(|e|e.to_string())?.get(0);
        tx.execute(
            "UPDATE commands SET active_publish_attempt=$2,attempts=attempts+1 WHERE id=$1",
            &[&id, &attempt],
        )
        .await
        .map_err(|e| e.to_string())?;
        // Persist a conservative boundary before any possible packet leaves.
        // Outgoing::Publish and PUBACK advance it to observed dispatch times.
        tx.execute(
            "UPDATE devices SET last_downlink_at=now() WHERE device_id=$1",
            &[&device],
        )
        .await
        .map_err(|e| e.to_string())?;
        prepared = Some((attempt, topic, wire));
        break;
    }
    tx.commit().await.map_err(|e| e.to_string())?;
    if let Some((attempt, topic, wire)) = prepared {
        publisher.enqueue(attempt, mqtt, &topic, &wire);
        publisher.reconcile(db, bus).await?;
    }
    Ok(())
}
