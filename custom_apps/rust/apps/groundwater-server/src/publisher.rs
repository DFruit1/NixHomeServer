//! One QoS-1 command at a time makes rumqttc's Outgoing::Publish(packet_id)
//! unambiguous. Only the ingest owner touches this tracker or publishes. SQL
//! intent is committed before enqueue; only a matching PUBACK completes it.
use crate::ingest::{EventBus, LiveEvent};
use chrono::{DateTime, Utc};
use rumqttc::{AsyncClient, EventLoop, MqttState, QoS};
use tokio_postgres::Client;

#[derive(Default)]
pub struct Publisher {
    pub connected: bool,
    pending: Option<Pending>,
}
struct Pending {
    attempt_id: i64,
    packet_id: Option<u16>,
    dispatched_at: Option<DateTime<Utc>>,
    outgoing_saved: bool,
    broker_acked_at: Option<DateTime<Utc>>,
    lost: bool,
}

/// Clear requests, unacknowledged packets and already-buffered events together.
/// Leaving old Outgoing events would misattribute a reused packet ID after a
/// clean-session reconnect. SQL, rather than rumqttc replay, owns retry policy.
pub fn discard_session(event_loop: &mut EventLoop) {
    event_loop.clean();
    event_loop.pending.clear();
    event_loop.state = MqttState::new(
        event_loop.mqtt_options.inflight(),
        event_loop.mqtt_options.manual_acks(),
    );
}
impl Publisher {
    pub fn busy(&self) -> bool {
        self.pending.is_some()
    }
    pub fn disconnected(&mut self) {
        self.connected = false;
        if let Some(pending) = &mut self.pending {
            pending.lost = true;
        }
    }
    /// Called after the attempt transaction commits. A failed enqueue still
    /// has an auditable intent and is recovered through the same durable path.
    pub fn enqueue(&mut self, attempt_id: i64, mqtt: &AsyncClient, topic: &str, wire: &str) {
        assert!(
            self.pending.is_none(),
            "only one command publish may be outstanding"
        );
        let lost = mqtt
            .try_publish(topic, QoS::AtLeastOnce, false, wire.as_bytes())
            .is_err();
        self.pending = Some(Pending {
            attempt_id,
            packet_id: None,
            dispatched_at: None,
            outgoing_saved: false,
            broker_acked_at: None,
            lost,
        });
    }
    pub async fn outgoing(
        &mut self,
        db: &mut Client,
        packet_id: u16,
        bus: &EventBus,
    ) -> Result<(), String> {
        let pending = self
            .pending
            .as_mut()
            .ok_or("outgoing command has no durable attempt")?;
        if packet_id == 0 || pending.packet_id.is_some_and(|id| id != packet_id) {
            return Err("outgoing MQTT packet does not match the pending command".into());
        }
        pending.packet_id = Some(packet_id);
        pending.dispatched_at.get_or_insert_with(Utc::now);
        self.reconcile(db, bus).await
    }
    pub async fn puback(
        &mut self,
        db: &mut Client,
        packet_id: u16,
        bus: &EventBus,
    ) -> Result<(), String> {
        if let Some(pending) = &mut self.pending {
            if pending.packet_id == Some(packet_id) {
                pending.broker_acked_at.get_or_insert_with(Utc::now);
                // Keep the confirmation in memory until its SQL transaction
                // succeeds. A transient DB failure must not discard PUBACK.
                return self.reconcile(db, bus).await;
            }
        }
        Ok(())
    }
    pub async fn reconcile(&mut self, db: &mut Client, bus: &EventBus) -> Result<(), String> {
        let Some(pending) = &mut self.pending else {
            return Ok(());
        };
        if !pending.outgoing_saved {
            if let (Some(packet), Some(at)) = (pending.packet_id, pending.dispatched_at) {
                record_outgoing(db, pending.attempt_id, packet, at).await?;
                pending.outgoing_saved = true;
            }
        }
        if let Some(acked_at) = pending.broker_acked_at {
            let device = accept(db, pending.attempt_id, acked_at).await?;
            self.pending = None;
            if let Some(device_id) = device {
                bus.emit(LiveEvent::Command { device_id });
            }
        } else if pending.lost {
            abandon(db, pending.attempt_id, "transport lost or enqueue rejected").await?;
            self.pending = None;
        }
        Ok(())
    }
}

/// The old process's packet IDs and request queue cannot survive restart.
/// Leave command intent pending, preserve spacing, and audit recovery.
pub async fn recover(db: &Client) -> Result<(), String> {
    db.execute("WITH lost AS (UPDATE command_publish_attempts SET state='abandoned',recovery_reason='process restart before persisted PUBACK' WHERE state IN ('prepared','inflight') RETURNING id,command_id), cleared AS (UPDATE commands c SET active_publish_attempt=NULL FROM lost WHERE c.id=lost.command_id AND c.active_publish_attempt=lost.id) INSERT INTO command_events(command_id,event,detail) SELECT command_id,'publish-recovered',jsonb_build_object('attempt_id',id,'reason','process restart before persisted PUBACK') FROM lost",&[]).await.map_err(|e|format!("publish recovery: {e:?}"))?;
    Ok(())
}
async fn abandon(db: &Client, id: i64, reason: &str) -> Result<(), String> {
    db.execute("WITH lost AS (UPDATE command_publish_attempts SET state='abandoned',recovery_reason=$2 WHERE id=$1 AND state IN ('prepared','inflight') RETURNING id,command_id), cleared AS (UPDATE commands c SET active_publish_attempt=NULL FROM lost WHERE c.id=lost.command_id AND c.active_publish_attempt=lost.id) INSERT INTO command_events(command_id,event,detail) SELECT command_id,'publish-recovered',jsonb_build_object('attempt_id',$1::bigint,'reason',$2::text) FROM lost",&[&id,&reason]).await.map_err(|e|format!("publish abandonment: {e:?}"))?;
    Ok(())
}
async fn record_outgoing(
    db: &mut Client,
    id: i64,
    packet: u16,
    at: DateTime<Utc>,
) -> Result<(), String> {
    let tx = db.transaction().await.map_err(|e| e.to_string())?;
    let row=tx.query_one("SELECT a.state,c.device_id,a.topic,c.wire_payload FROM command_publish_attempts a JOIN commands c ON c.id=a.command_id WHERE a.id=$1 FOR UPDATE OF a",&[&id]).await.map_err(|e|format!("outgoing lookup: {e:?}"))?;
    let state: String = row.get(0);
    if state == "prepared" {
        let device: String = row.get(1);
        let topic: String = row.get(2);
        let wire: String = row.get(3);
        let delivery=tx.query_one("INSERT INTO deliveries(received_at,topic,kind,qos,payload,payload_size,payload_digest,device_id,state,direction) VALUES($1,$2,'command',1,$3,$4,'',$5,'published','out') RETURNING id",&[&at,&topic,&wire,&(wire.len() as i32),&device]).await.map_err(|e|format!("outgoing delivery: {e:?}"))?.get::<_,i64>(0);
        tx.execute("UPDATE command_publish_attempts SET state='inflight',mqtt_packet_id=$2,dispatched_at=$3,delivery_id=$4 WHERE id=$1",&[&id,&i32::from(packet),&at,&delivery]).await.map_err(|e|e.to_string())?;
        tx.execute(
            "UPDATE devices SET last_downlink_at=GREATEST(last_downlink_at,$2) WHERE device_id=$1",
            &[&device, &at],
        )
        .await
        .map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO command_events(command_id,event,detail) SELECT command_id,'mqtt-publish',jsonb_build_object('attempt_id',id,'packet_id',mqtt_packet_id) FROM command_publish_attempts WHERE id=$1",&[&id]).await.map_err(|e|e.to_string())?;
    }
    tx.commit().await.map_err(|e| e.to_string())
}
async fn accept(
    db: &mut Client,
    id: i64,
    acked_at: DateTime<Utc>,
) -> Result<Option<String>, String> {
    let tx = db.transaction().await.map_err(|e| e.to_string())?;
    let row=tx.query_one("SELECT a.state,c.id,c.device_id,c.kind,c.payload,c.firmware_ack_expected,a.ready_at,a.dispatched_at,a.firmware_acked_at,a.firmware_ack_payload,a.delivery_id,c.state FROM command_publish_attempts a JOIN commands c ON c.id=a.command_id WHERE a.id=$1 FOR UPDATE OF a,c",&[&id]).await.map_err(|e|format!("PUBACK lookup: {e:?}"))?;
    if row.get::<_, String>(0) == "accepted" {
        return Ok(None);
    }
    if row.get::<_, String>(0) != "inflight" {
        return Err("PUBACK has no dispatched attempt".into());
    }
    let command_id: i64 = row.get(1);
    let device: String = row.get(2);
    let kind: String = row.get(3);
    let payload: serde_json::Value = row.get(4);
    let expects_ack: bool = row.get(5);
    let ready: DateTime<Utc> = row.get(6);
    let dispatched: DateTime<Utc> = row.get(7);
    let firmware_at: Option<DateTime<Utc>> = row.get(8);
    let firmware_payload: Option<serde_json::Value> = row.get(9);
    let delivery: Option<i64> = row.get(10);
    tx.execute(
        "UPDATE command_publish_attempts SET state='accepted',broker_acked_at=$2 WHERE id=$1",
        &[&id, &acked_at],
    )
    .await
    .map_err(|e| e.to_string())?;
    if row.get::<_, String>(11) != "cancelled" {
        let state = if expects_ack && firmware_at.is_some() {
            "acked"
        } else {
            "sent"
        };
        tx.execute("UPDATE commands SET state=$2,sent_at=$3,broker_acked_at=$4,last_ready_at=$5,acked_at=$6,ack_payload=$7,active_publish_attempt=NULL WHERE id=$1",&[&command_id,&state,&dispatched,&acked_at,&ready,&firmware_at.filter(|_|expects_ack),&firmware_payload.filter(|_|expects_ack)]).await.map_err(|e|format!("broker acceptance: {e:?}"))?;
        // Preserve a conservative pacing boundary even when SQL confirmation
        // was delayed across a database outage.
        tx.execute(
            "UPDATE devices SET last_downlink_at=GREATEST(last_downlink_at,$2) WHERE device_id=$1",
            &[&device, &acked_at],
        )
        .await
        .map_err(|e| e.to_string())?;
        if kind == "project-settings" {
            let min = payload["mG"]
                .as_str()
                .and_then(|s| s.parse::<f64>().ok())
                .ok_or("invalid persisted minimum")?;
            let max = payload["MG"]
                .as_str()
                .and_then(|s| s.parse::<f64>().ok())
                .ok_or("invalid persisted maximum")?;
            tx.execute("UPDATE devices SET desired_config=$2::jsonb,min_limit=$3,max_limit=$4,location_id=$2::jsonb->>'l',sensor_id=$2::jsonb->>'id',alerts_dirty=true WHERE device_id=$1",&[&device,&payload,&min,&max]).await.map_err(|e|format!("accepted settings: {e:?}"))?;
        } else if kind == "cfg" && firmware_at.is_some() {
            tx.execute(
                "UPDATE devices SET applied_config=$2::jsonb WHERE device_id=$1",
                &[&device, &payload],
            )
            .await
            .map_err(|e| e.to_string())?;
        }
    }
    tx.execute(
        "UPDATE deliveries SET state='broker-accepted' WHERE id=$1",
        &[&delivery],
    )
    .await
    .map_err(|e| e.to_string())?;
    tx.execute("INSERT INTO command_events(command_id,event,detail) VALUES($1,'broker-accepted',jsonb_build_object('attempt_id',$2::bigint))",&[&command_id,&id]).await.map_err(|e|e.to_string())?;
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(Some(device))
}
