//! Durable, conservative command delivery. A queue insertion never publishes.
//! The MQTT event loop keeps polling independently of the publisher, including
//! while the client's bounded request queue is full.
use crate::{
    adapter::EnrollmentRegistry,
    ingest::{EventBus, IngestStats, LiveEvent},
};
use chrono::{DateTime, Utc};
use rumqttc::{AsyncClient, QoS};
use std::sync::Arc;
use tokio_postgres::Client;

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

pub async fn ancillary(
    client: &Client,
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
        client.execute("UPDATE devices SET last_seen=$2,presence_status=$3,last_ready_at=CASE WHEN $3='awake' THEN $2 ELSE last_ready_at END WHERE device_id=$1 AND revoked_at IS NULL", &[&device,&now,&status]).await.map_err(|e|e.to_string())?;
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
                    "UPDATE devices SET last_seen=$2 WHERE device_id=$1 AND revoked_at IS NULL",
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
            "UPDATE devices SET last_seen=$2 WHERE device_id=$1 AND revoked_at IS NULL",
            &[&device, &now],
        )
        .await
        .map_err(|e| e.to_string())?;
    let parsed =
        serde_json::from_str::<serde_json::Value>(text).unwrap_or_else(|_| serde_json::json!(text));
    // Match only a command actually attempted in this Ready window. Identical
    // cfg echoes are compared as JSON, not formatting or key order.
    let changed=client.query("WITH candidate AS (SELECT c.id FROM commands c JOIN devices d ON d.device_id=c.device_id WHERE c.device_id=$1 AND c.kind=$2 AND (c.state='sent' OR ($2='test' AND c.state='acked')) AND c.sent_at<=$3 AND c.last_ready_at=d.last_ready_at AND d.presence_status='awake' AND d.last_ready_at>$3-interval '8 minutes' AND ($2<>'cfg' OR c.payload=$4) ORDER BY c.id DESC LIMIT 1) UPDATE commands c SET state='acked',acked_at=COALESCE(c.acked_at,$3),ack_payload=CASE WHEN $2='test' THEN COALESCE(c.ack_payload,'[]'::jsonb)||jsonb_build_array($4::jsonb) ELSE $4 END FROM candidate WHERE c.id=candidate.id RETURNING c.id", &[&device,&ack_kind,&now,&parsed]).await.map_err(|e|format!("ack match: {e:?}"))?;
    if !changed.is_empty() {
        if ack_kind == "cfg" {
            client
                .execute(
                    "UPDATE devices SET applied_config=$2,last_seen=$3 WHERE device_id=$1",
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

pub async fn run(
    database_url: String,
    mqtt: AsyncClient,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
    bus: EventBus,
) {
    let mut timer = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        let mut db = match crate::db::connect(&database_url).await {
            Ok(db) => db,
            Err(e) => {
                eprintln!("groundwater scheduler: {e}");
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                continue;
            }
        };
        loop {
            timer.tick().await;
            if !stats.lock().await.connected {
                continue;
            }
            if let Err(e) = tick(&mut db, &mqtt, &bus).await {
                eprintln!("groundwater scheduler: {e}");
                if db.is_closed() {
                    break;
                }
            }
        }
    }
}

pub async fn tick(db: &mut Client, mqtt: &AsyncClient, bus: &EventBus) -> Result<(), String> {
    // Lock both rows through publication handoff and commit. Cancellation
    // serializes here, so a successfully cancelled command cannot later send.
    let tx = db.transaction().await.map_err(|e| e.to_string())?;
    let rows=tx.query("SELECT c.id,c.device_id,c.kind,c.payload,c.wire_payload,d.last_ready_at FROM commands c JOIN devices d ON d.device_id=c.device_id WHERE c.state IN ('queued','sent') AND NOT(c.kind='project-settings' AND c.state='sent') AND d.revoked_at IS NULL AND d.presence_status='awake' AND d.last_ready_at<=now() AND d.last_ready_at>now()-interval '8 minutes' AND (d.last_downlink_at IS NULL OR d.last_downlink_at<=now()-interval '5 seconds') AND (c.last_ready_at IS NULL OR c.last_ready_at<d.last_ready_at) AND NOT EXISTS(SELECT 1 FROM commands prior WHERE prior.device_id=c.device_id AND prior.id<c.id AND prior.state IN ('queued','sent') AND NOT(prior.kind='project-settings' AND prior.state='sent')) ORDER BY c.id LIMIT 32 FOR UPDATE OF c,d SKIP LOCKED", &[]).await.map_err(|e|format!("scheduler select: {e:?}"))?;
    for row in &rows {
        let id: i64 = row.get(0);
        let device: String = row.get(1);
        let kind: String = row.get(2);
        let payload: serde_json::Value = row.get(3);
        let wire: String = row.get(4);
        let ready: DateTime<Utc> = row.get(5);
        let base = match kind.as_str() {
            "project-settings" => "azman1/feeds/project-settings-slash-configuration",
            "cfg" => "cfg/desired",
            "danger" => "cmd/danger",
            "test" => "requesttesta",
            _ => return Err("invalid persisted command kind".into()),
        };
        let bindings=tx.query("SELECT b.topic FROM device_bindings b JOIN devices d ON d.device_id=b.device_id WHERE b.device_id=$1 AND b.source_profile=d.source_profile AND b.revoked_at IS NULL AND (b.topic=$2 OR right(b.topic,length($2)+1)='/'||$2) ORDER BY b.topic", &[&device,&base]).await.map_err(|e|e.to_string())?;
        // Exactly one explicit destination. Generic firmware downlinks are
        // broadcast to every logger, even with one topic binding: disable them
        // whenever more than one active device is enrolled.
        if bindings.len() == 1 {
            let topic: String = bindings[0].get(0);
            let count: i64 = tx
                .query_one("SELECT count(*) FROM devices WHERE revoked_at IS NULL", &[])
                .await
                .map_err(|e| e.to_string())?
                .get(0);
            if topic != base || count == 1 {
                // Nonblocking enqueue: this task never waits for the event
                // loop to make channel capacity, and retain is ALWAYS false.
                if mqtt
                    .try_publish(topic.clone(), QoS::AtLeastOnce, false, wire.as_bytes())
                    .is_ok()
                {
                    tx.execute("UPDATE commands SET state='sent',sent_at=now(),attempts=attempts+1,last_ready_at=$2 WHERE id=$1", &[&id,&ready]).await.map_err(|e|e.to_string())?;
                    tx.execute(
                        "UPDATE devices SET last_downlink_at=now() WHERE device_id=$1",
                        &[&device],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                    if kind == "project-settings" {
                        let min: f64 = payload["mG"].as_str().unwrap().parse().unwrap();
                        let max: f64 = payload["MG"].as_str().unwrap().parse().unwrap();
                        tx.execute("UPDATE devices SET desired_config=$2,min_limit=$3,max_limit=$4,location_id=$2->>'l',sensor_id=$2->>'id',alerts_dirty=true WHERE device_id=$1", &[&device,&payload,&min,&max]).await.map_err(|e|e.to_string())?;
                        // No firmware ACK exists. Keep sent, never manufacture
                        // an applied config or new clock policy from intent.
                    }
                    tx.execute("INSERT INTO deliveries(received_at,topic,kind,qos,payload,payload_size,payload_digest,device_id,state,direction) VALUES(now(),$1,'command',1,$2,$3,'',$4,'sent','out')", &[&topic,&wire,&(wire.len() as i32),&device]).await.map_err(|e|e.to_string())?;
                    bus.emit(LiveEvent::Command { device_id: device });
                }
            }
        }
    }
    tx.commit().await.map_err(|e| e.to_string())
}
