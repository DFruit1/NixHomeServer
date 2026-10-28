//! MQTT ingest.
//!
//! The transport is deliberately thin: it subscribes, timestamps each message
//! on arrival, hands it to [`crate::adapter`] and stores whatever the adapter
//! decided. All interpretation — topic meaning, attribution, clock, health
//! fields, duplicates — lives in the adapter so it is testable without a
//! broker (`GWAPP-20261023-slice1` §1).
//!
//! The enrollment/binding registry is loaded from PostgreSQL and refreshed on a
//! timer. Two consequences are intentional:
//!
//! - a newly enrolled device starts being attributed within one refresh
//!   interval, without a restart;
//! - if the refresh fails the previous registry stays in force, so a database
//!   hiccup does not turn every reading into a quarantine.
//!
//! Delivery is at QoS 1, so a redelivery is expected; the adapter classifies it
//! as a candidate and the delivery log keeps it. Nothing here decides that a
//! repeat means "no new sample".

use std::sync::Arc;
use std::time::Duration;

use rumqttc::{AsyncClient, Event, Incoming, MqttOptions, Outgoing};
use tokio::sync::{broadcast, RwLock};
use tokio_postgres::Client;

use crate::adapter::{self, Delivery, DuplicateOutcome, EnrollmentRegistry, IntakeOutcome};
use crate::config::{MqttSettings, Settings};
use crate::db;
use crate::topics::TopicMap;

/// Broadcast channel capacity for live UI events.
///
/// Small on purpose: a slow browser tab must not grow an unbounded queue.
const EVENT_CHANNEL_CAPACITY: usize = 64;

/// How often the enrollment/binding registry is reloaded from PostgreSQL.
const REGISTRY_REFRESH_SECONDS: u64 = 60;

/// A live event pushed to connected browsers over SSE.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum LiveEvent {
    /// A water observation was stored.
    Observation {
        device_id: String,
        recorded_at: Option<chrono::DateTime<chrono::Utc>>,
        gwl: f64,
    },
    /// A delivery was identical to one already stored at the same device time.
    Redelivery {
        device_id: String,
    },
    /// A different value at a device time that already has one.
    Conflict {
        device_id: String,
    },
    Presence {
        device_id: String,
    },
    Alert {
        device_id: String,
    },
    Command {
        device_id: String,
    },
    /// Traffic that was recorded but not attributed to any device.
    Quarantine {
        topic: String,
        reason: String,
    },
    /// The broker connection state changed.
    Broker {
        connected: bool,
        detail: String,
    },
}

/// Handle shared with the HTTP layer to publish live events.
#[derive(Clone)]
pub struct EventBus(broadcast::Sender<LiveEvent>);

impl EventBus {
    pub fn new() -> Self {
        let (sender, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        Self(sender)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<LiveEvent> {
        self.0.subscribe()
    }

    pub fn emit(&self, event: LiveEvent) {
        // A send error only means nobody is listening, which is the common case.
        let _ = self.0.send(event);
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

/// Counters exposed by the status endpoint.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct IngestStats {
    pub connected: bool,
    /// Every message the loop received.
    pub deliveries: u64,
    /// Deliveries that became a stored water observation.
    pub observations: u64,
    /// Identical repeats suppressed as redelivery candidates.
    pub redelivery_candidates: u64,
    /// Same-time, different-value observations, stored and flagged.
    pub conflicts: u64,
    /// Deliveries recorded but not attributed or not a reading.
    pub quarantined: u64,
    /// Most recent quarantine reason code, for a quick look at the status page.
    pub last_quarantine_reason: Option<String>,
    pub last_error: Option<String>,
}

/// Shared, refreshable trust state.
pub type SharedRegistry = Arc<RwLock<EnrollmentRegistry>>;

/// Runs the ingest loop until shutdown.
///
/// `poll()` reconnects internally, so the only handling here is resubscribing
/// after each successful connect and reloading the registry on its timer.
pub async fn run(
    settings: Arc<Settings>,
    mqtt: Arc<MqttSettings>,
    client: Arc<Client>,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
    registry: SharedRegistry,
) -> Result<(), String> {
    let password = match &mqtt.password_file {
        Some(path) => Some(homelab_common::read_secret_file(path)?),
        None => None,
    };

    let mut options = MqttOptions::new(mqtt.client_id.clone(), mqtt.host.clone(), mqtt.port);
    options.set_keep_alive(Duration::from_secs(mqtt.keep_alive_seconds));
    options.set_clean_session(true);
    if let Some(username) = &mqtt.username {
        options.set_credentials(username, password.as_deref().unwrap_or_default());
    }

    let (mqtt_client, mut event_loop) = AsyncClient::new(options, 10);
    // This task is the sole command producer and observer of packet IDs.
    // No volatile rumqttc request survives an unconfirmed process restart.
    let mut publisher_db = db::connect(&settings.database_url).await?;
    crate::publisher::recover(&publisher_db).await?;
    let mut publisher = crate::publisher::Publisher::default();
    let mut dispatch = tokio::time::interval(Duration::from_secs(1));
    let subscribe_topics = settings.topics.subscribe_topics();
    let topic_map = Arc::new(settings.topics.clone());
    let mut connected = false;
    let mut refresh = tokio::time::interval(Duration::from_secs(REGISTRY_REFRESH_SECONDS));

    loop {
        let event = tokio::select! {
            event = event_loop.poll() => event,
            _ = dispatch.tick() => {
                if publisher_db.is_closed() {
                    match db::connect(&settings.database_url).await {
                        Ok(db)=>publisher_db=db,
                        Err(e)=>{eprintln!("groundwater publisher reconnect: {e}");continue}
                    }
                }
                if let Err(e)=crate::scheduler::tick(&mut publisher_db,&mqtt_client,&bus,&mut publisher).await {
                    eprintln!("groundwater publisher: {e}");
                    stats.lock().await.last_error=Some(e);
                }
                continue;
            }
            _ = refresh.tick() => {
                match db::load_registry(&client).await {
                    Ok(loaded) => {
                        let enrollments = loaded.enrollments().count();
                        let bindings = loaded.bindings().len();
                        let mut topics=settings.topics.subscribe_topics();
                        topics.extend(loaded.bindings().iter().map(|b|b.topic.clone()));topics.sort();topics.dedup();
                        let subscriber=mqtt_client.clone();
                        tokio::spawn(async move {for topic in topics {if let Err(e)=subscriber.subscribe(topic,rumqttc::QoS::AtLeastOnce).await {eprintln!("groundwater subscription refresh: {e}");}}});
                        *registry.write().await = loaded;
                        eprintln!(
                            "groundwater: registry refreshed ({enrollments} enrollment(s), {bindings} binding(s))"
                        );
                    }
                    Err(err) => eprintln!("groundwater: registry refresh failed, keeping previous: {err}"),
                }
                continue;
            }
            _ = homelab_common::shutdown_signal() => {
                bus.emit(LiveEvent::Broker {
                    connected: false,
                    detail: "shutting down".to_string(),
                });
                return Ok(());
            }
        };

        match event {
            Ok(Event::Incoming(Incoming::ConnAck(_))) => {
                connected = true;
                publisher.connected = true;
                {
                    let mut guard = stats.lock().await;
                    guard.connected = true;
                    guard.last_error = None;
                }
                // Subscription production must not await queue capacity while
                // this same task owns event_loop.poll().
                let subscriber = mqtt_client.clone();
                let mut subscriptions = subscribe_topics.clone();
                subscriptions.extend(
                    registry
                        .read()
                        .await
                        .bindings()
                        .iter()
                        .map(|b| b.topic.clone()),
                );
                subscriptions.sort();
                subscriptions.dedup();
                tokio::spawn(async move {
                    for topic in subscriptions {
                        if let Err(e) = subscriber.subscribe(topic, rumqttc::QoS::AtLeastOnce).await
                        {
                            eprintln!("groundwater subscribe: {e}");
                        }
                    }
                });
                bus.emit(LiveEvent::Broker {
                    connected: true,
                    detail: format!("subscribed to {} topics", subscribe_topics.len()),
                });
            }
            Ok(Event::Outgoing(Outgoing::Publish(packet_id))) => {
                if let Err(e) = publisher.outgoing(&mut publisher_db, packet_id, &bus).await {
                    eprintln!("groundwater outgoing confirmation: {e}");
                }
            }
            Ok(Event::Incoming(Incoming::PubAck(ack))) => {
                if let Err(e) = publisher.puback(&mut publisher_db, ack.pkid, &bus).await {
                    eprintln!("groundwater broker confirmation: {e}");
                }
            }
            Ok(Event::Incoming(Incoming::Publish(publish))) => {
                handle_publish(
                    &publish.topic,
                    &publish.payload,
                    publish.qos as i16,
                    publish.retain,
                    chrono::Utc::now(),
                    &topic_map,
                    &client,
                    &registry,
                    &bus,
                    &stats,
                )
                .await;
            }
            Ok(_) => {}
            Err(err) => {
                // Explicitly discard the old session's volatile packets.
                // SQL owns recovery and wake-window/spacing checks; automatic
                // MQTT replay could otherwise publish after sleep or cancel.
                publisher.disconnected();
                crate::publisher::discard_session(&mut event_loop);
                if let Err(e) = publisher.reconcile(&mut publisher_db, &bus).await {
                    eprintln!("groundwater publish recovery: {e}");
                }
                let message = err.to_string();
                let should_log = {
                    let mut guard = stats.lock().await;
                    let changed =
                        connected || guard.last_error.as_deref() != Some(message.as_str());
                    guard.connected = false;
                    guard.last_error = Some(message.clone());
                    changed
                };
                if should_log {
                    eprintln!("groundwater: MQTT connection error: {message}");
                    connected = false;
                    bus.emit(LiveEvent::Broker {
                        connected: false,
                        detail: message,
                    });
                }
                tokio::time::sleep(Duration::from_secs(RECONNECT_BACKOFF_SECONDS)).await;
            }
        }
    }
}

/// Pause between connection failures.
const RECONNECT_BACKOFF_SECONDS: u64 = 5;

/// Runs one delivery through the adapter and stores the result.
#[allow(clippy::too_many_arguments)]
pub async fn handle_publish(
    topic: &str,
    payload: &[u8],
    qos: i16,
    retained: bool,
    received_at: chrono::DateTime<chrono::Utc>,
    topic_map: &TopicMap,
    client: &Client,
    registry: &SharedRegistry,
    bus: &EventBus,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
) {
    let delivery = Delivery {
        topic,
        payload,
        qos,
        received_at,
    };
    let registry = registry.read().await.clone();
    let evaluation = adapter::evaluate(&delivery, &registry, topic_map);

    let mut intake = match evaluation {
        adapter::Evaluation::Quarantined {
            record,
            reason,
            detail,
        } => adapter::finalize(
            adapter::Evaluation::Quarantined {
                record,
                reason,
                detail,
            },
            adapter::DuplicateDecision::fresh("not evaluated (quarantined)"),
        ),
        adapter::Evaluation::Candidate {
            record,
            observation,
        } => {
            // Only now, with a derived device time, is a duplicate lookup
            // meaningful. A failure here must not drop the observation; it
            // degrades to "new" with the reason recorded.
            let history = match db::prior_observations(
                client,
                &observation.device_id,
                observation.recorded_at,
                observation.received_at,
            )
            .await
            {
                Ok(history) => history,
                Err(err) => {
                    eprintln!("groundwater: duplicate lookup failed: {err}");
                    stats.lock().await.last_error.replace(err.clone());
                    Vec::new()
                }
            };
            let decision = adapter::classify_duplicate(&observation, &history);
            adapter::finalize(
                adapter::Evaluation::Candidate {
                    record,
                    observation,
                },
                decision,
            )
        }
    };

    if !retained && intake.record.kind != crate::topics::MessageKind::Reading {
        match crate::scheduler::ancillary(
            client,
            &registry,
            topic,
            payload,
            topic_map,
            received_at,
            bus,
        )
        .await
        {
            Ok(Some(device)) => {
                intake.record.device_id = Some(device);
                intake.record.state = adapter::DeliveryState::Accepted;
                intake.record.quarantine_reason = None;
                intake.record.quarantine_detail = None;
                if let Some(binding) = crate::scheduler::attributed(&registry, topic) {
                    intake.record.binding_key = Some(binding.key.clone());
                    intake.record.profile = Some(binding.profile);
                }
                intake.outcome = IntakeOutcome::Accepted {
                    observation: None,
                    duplicate: adapter::DuplicateDecision::fresh("attributed ancillary message"),
                };
            }
            Ok(None) => {}
            Err(e) => eprintln!("groundwater ancillary: {e}"),
        }
    }

    {
        let mut guard = stats.lock().await;
        guard.deliveries += 1;
        if let IntakeOutcome::Quarantined { reason, .. } = &intake.outcome {
            guard.quarantined += 1;
            guard.last_quarantine_reason = Some(reason.code().to_string());
        }
    }

    if let Err(err) = db::record_intake(client, &intake).await {
        eprintln!("groundwater: {err}");
        stats.lock().await.last_error = Some(err);
        return;
    }

    match &intake.outcome {
        IntakeOutcome::Accepted {
            observation,
            duplicate,
        } => {
            let device_id = intake
                .record
                .device_id
                .clone()
                .unwrap_or_else(|| "unknown".to_string());
            match (&observation, duplicate.outcome) {
                (Some(observation), DuplicateOutcome::Conflict) => {
                    stats.lock().await.conflicts += 1;
                    bus.emit(LiveEvent::Conflict {
                        device_id: device_id.clone(),
                    });
                    stats.lock().await.observations += 1;
                    bus.emit(LiveEvent::Observation {
                        device_id,
                        recorded_at: observation.recorded_at,
                        gwl: observation.gwl,
                    });
                }
                (Some(observation), _) => {
                    stats.lock().await.observations += 1;
                    bus.emit(LiveEvent::Observation {
                        device_id,
                        recorded_at: observation.recorded_at,
                        gwl: observation.gwl,
                    });
                }
                (None, DuplicateOutcome::RedeliveryCandidate) => {
                    stats.lock().await.redelivery_candidates += 1;
                    bus.emit(LiveEvent::Redelivery { device_id });
                }
                (None, _) => {
                    // Accepted but suppressed for a reason the adapter will
                    // have recorded on the delivery; nothing to stream.
                }
            }
        }
        IntakeOutcome::Quarantined { reason, detail } => {
            eprintln!(
                "groundwater: quarantined {topic}: {} ({detail})",
                reason.code()
            );
            bus.emit(LiveEvent::Quarantine {
                topic: intake.record.topic.clone(),
                reason: reason.code().to_string(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_bus_delivers_to_subscribers_and_survives_no_listeners() {
        let bus = EventBus::new();
        // Emitting with no subscriber must not panic.
        bus.emit(LiveEvent::Broker {
            connected: false,
            detail: "no listeners".to_string(),
        });
        let mut receiver = bus.subscribe();
        bus.emit(LiveEvent::Observation {
            device_id: "ABC".to_string(),
            recorded_at: Some(chrono::Utc::now()),
            gwl: 1.0,
        });
        let event = receiver.try_recv().expect("event delivered");
        assert!(matches!(event, LiveEvent::Observation { .. }));
    }

    #[test]
    fn fresh_stats_start_at_zero_and_name_no_reason() {
        let stats = IngestStats::default();
        assert_eq!(stats.deliveries, 0);
        assert_eq!(stats.observations, 0);
        assert_eq!(stats.quarantined, 0);
        assert_eq!(stats.last_quarantine_reason, None);
    }
}
