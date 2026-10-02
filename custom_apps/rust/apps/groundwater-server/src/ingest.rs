//! MQTT ingest.
//!
//! The firmware publishes at QoS 1, so the broker may redeliver; and its topic
//! names are compile-time constants that can change between firmware
//! revisions. The loop therefore does three things defensively:
//!
//! 1. It subscribes to the configured topic set, which an operator can override
//!    without a new binary.
//! 2. It re-subscribes on every reconnect, because the firmware re-subscribes
//!    after each wake cycle and the platform must not depend on session state.
//! 3. It classifies an unrecognised topic by payload shape, so a renamed
//!    telemetry topic still lands in `readings`.

use std::sync::Arc;
use std::time::Duration;

use rumqttc::{AsyncClient, Event, Incoming, MqttOptions};
use tokio::sync::broadcast;
use tokio_postgres::Client;

use crate::config::{MqttSettings, Settings};
use crate::db::{self, PresenceEvent};
use crate::telemetry;
use crate::topics::{self, MessageKind, TopicMap};

/// Broadcast channel capacity for live UI events.
///
/// Small on purpose: a slow browser tab must not grow an unbounded queue, and
/// the UI already falls back to polling.
const EVENT_CHANNEL_CAPACITY: usize = 64;

/// A live event pushed to connected browsers over SSE.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum LiveEvent {
    /// A reading was accepted and stored.
    Reading {
        device_id: String,
        recorded_at: chrono::DateTime<chrono::Utc>,
        gwl: f64,
    },
    /// A reading arrived but was a duplicate delivery.
    Duplicate { device_id: String },
    /// A device changed presence.
    Presence {
        device_id: String,
        status: String,
    },
    /// The broker connection state changed.
    Broker { connected: bool, detail: String },
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

    fn emit(&self, event: LiveEvent) {
        // A send error only means nobody is listening, which is the common case.
        let _ = self.0.send(event);
    }
}

/// Counters exposed by the status endpoint.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct IngestStats {
    pub connected: bool,
    pub readings_accepted: u64,
    pub readings_duplicate: u64,
    pub readings_rejected: u64,
    pub other_messages: u64,
    pub last_error: Option<String>,
}

/// Runs the ingest loop until shutdown.
///
/// The event loop is driven by rumqttc; `poll()` reconnects internally, so the
/// only handling here is resubscribing after each successful connect. Counters
/// are shared with the status endpoint through `stats`.
pub async fn run(
    settings: Arc<Settings>,
    mqtt: Arc<MqttSettings>,
    client: Arc<Client>,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
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
    let subscribe_topics = settings.topics.subscribe_topics();
    let topic_map = Arc::new(settings.topics.clone());
    let mut connected = false;

    loop {
        let event = tokio::select! {
            event = event_loop.poll() => event,
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
                {
                    let mut guard = stats.lock().await;
                    guard.connected = true;
                    guard.last_error = None;
                }
                for topic in &subscribe_topics {
                    if let Err(err) = mqtt_client
                        .subscribe(topic.clone(), rumqttc::QoS::AtLeastOnce)
                        .await
                    {
                        eprintln!("groundwater: subscribe to {topic} failed: {err}");
                    }
                }
                bus.emit(LiveEvent::Broker {
                    connected: true,
                    detail: format!("subscribed to {} topics", subscribe_topics.len()),
                });
            }
            Ok(Event::Incoming(Incoming::Publish(publish))) => {
                handle_publish(
                    &publish.topic,
                    &publish.payload,
                    publish.qos as i16,
                    &settings,
                    &topic_map,
                    &client,
                    &bus,
                    &stats,
                )
                .await;
            }
            Ok(_) => {}
            Err(err) => {
                // rumqttc retries internally; log and keep polling so a
                // transient broker outage does not kill the service.
                let message = err.to_string();
                let should_log = {
                    let mut guard = stats.lock().await;
                    let changed = connected || guard.last_error.as_deref() != Some(message.as_str());
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

#[allow(clippy::too_many_arguments)]
async fn handle_publish(
    topic: &str,
    payload: &[u8],
    qos: i16,
    settings: &Settings,
    topic_map: &TopicMap,
    client: &Client,
    bus: &EventBus,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
) {
    let text = String::from_utf8_lossy(payload);
    let mut kind = topics::classify(topic, topic_map);

    // Tolerance path: an unknown topic whose payload carries the telemetry
    // field set is still a reading.
    if kind == MessageKind::Other && topics::payload_looks_like_reading(&text) {
        eprintln!(
            "groundwater: unrecognised topic {topic} carried a telemetry payload; treating it as a reading"
        );
        kind = MessageKind::Reading;
    }

    match kind {
        MessageKind::Reading => {
            let offset = peek_device_id(&text)
                .map_or(telemetry::DEFAULT_LOCAL_OFFSET_MINUTES, |id| {
                    settings.local_offset_minutes(&id)
                });
            match telemetry::parse_reading(&text, offset) {
                Ok(reading) => {
                    if let Err(err) = db::upsert_device_presence(
                        client,
                        &reading.device_id,
                        offset,
                        PresenceEvent::Seen,
                    )
                    .await
                    {
                        eprintln!("groundwater: {err}");
                    }
                    match db::insert_reading(client, &reading).await {
                        Ok(true) => {
                            stats.lock().await.readings_accepted += 1;
                            bus.emit(LiveEvent::Reading {
                                device_id: reading.device_id.clone(),
                                recorded_at: reading.recorded_at,
                                gwl: reading.gwl,
                            });
                            bus.emit(LiveEvent::Presence {
                                device_id: reading.device_id.clone(),
                                status: "seen".to_string(),
                            });
                            let _ = db::insert_message(
                                client,
                                topic,
                                kind.as_str(),
                                Some(&reading.device_id),
                                qos,
                                &reading.raw,
                                None,
                            )
                            .await;
                        }
                        Ok(false) => {
                            // QoS 1 redelivery: already stored.
                            stats.lock().await.readings_duplicate += 1;
                            bus.emit(LiveEvent::Duplicate {
                                device_id: reading.device_id,
                            });
                        }
                        Err(err) => {
                            eprintln!("groundwater: {err}");
                            stats.lock().await.last_error = Some(err);
                        }
                    }
                }
                Err(err) => {
                    {
                        let mut guard = stats.lock().await;
                        guard.readings_rejected += 1;
                        guard.last_error = Some(err.to_string());
                    }
                    eprintln!("groundwater: rejected reading on {topic}: {err}");
                    // Keep the raw payload so a firmware change is diagnosable.
                    let _ = db::insert_message(
                        client,
                        topic,
                        kind.as_str(),
                        None,
                        qos,
                        text.trim(),
                        Some(&err.to_string()),
                    )
                    .await;
                }
            }
        }
        MessageKind::DeviceStatus => {
            let status = text.trim();
            let Some(device_id) = peek_device_id_from_status(status) else {
                // The firmware publishes `Ready`/`sleep` with no device id, so
                // with several devices sharing one broker the transition cannot
                // be attributed. Keep the raw message rather than guessing.
                let _ = db::insert_message(
                    client,
                    topic,
                    kind.as_str(),
                    None,
                    qos,
                    text.trim(),
                    Some("status message carries no device identity"),
                )
                .await;
                return;
            };
            let (event, label) = if status.eq_ignore_ascii_case("sleep") {
                (PresenceEvent::Asleep, "asleep")
            } else {
                (PresenceEvent::Awake, "awake")
            };
            let offset = settings.local_offset_minutes(&device_id);
            let _ = db::upsert_device_presence(client, &device_id, offset, event).await;
            bus.emit(LiveEvent::Presence {
                device_id,
                status: label.to_string(),
            });
            let _ = db::insert_message(client, topic, kind.as_str(), None, qos, text.trim(), None).await;
        }
        _ => {
            stats.lock().await.other_messages += 1;
            let _ = db::insert_message(
                client,
                topic,
                kind.as_str(),
                peek_device_id(&text).as_deref(),
                qos,
                text.trim(),
                None,
            )
            .await;
        }
    }
}

/// Best-effort device id extraction used before full parsing, so the correct
/// per-device time offset can be applied.
fn peek_device_id(payload: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(payload.trim()).ok()?;
    let object = value.as_object()?;
    for key in ["DeviceID", "deviceId", "device_id"] {
        if let Some(text) = object.get(key).and_then(|value| value.as_str()) {
            if !text.trim().is_empty() {
                return Some(text.trim().to_ascii_uppercase());
            }
        }
    }
    None
}

/// The firmware's device-status messages carry no identity. A future revision
/// may add one; this accepts `{"DeviceID":"..."}` shapes and returns `None` for
/// the current bare `Ready`/`sleep`, letting the caller record the raw message.
fn peek_device_id_from_status(status: &str) -> Option<String> {
    let trimmed = status.trim();
    if !trimmed.starts_with('{') {
        return None;
    }
    peek_device_id(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_device_id_before_full_parsing() {
        let payload = r#"{"DeviceID":"8f3a21c0","GWL":"01.25"}"#;
        assert_eq!(peek_device_id(payload).as_deref(), Some("8F3A21C0"));
        assert_eq!(peek_device_id(r#"{"other":"x"}"#), None);
        assert_eq!(peek_device_id("Ready"), None);
    }

    #[test]
    fn device_status_without_identity_is_unattributable() {
        // Current firmware: bare `Ready`/`sleep`.
        assert_eq!(peek_device_id_from_status("Ready"), None);
        assert_eq!(peek_device_id_from_status("sleep"), None);
        // A future revision that adds identity is accepted.
        assert_eq!(
            peek_device_id_from_status(r#"{"DeviceID":"abc","state":"Ready"}"#).as_deref(),
            Some("ABC")
        );
    }

    #[test]
    fn event_bus_delivers_to_subscribers_and_survives_no_listeners() {
        let bus = EventBus::new();
        // Emitting with no subscriber must not panic.
        bus.emit(LiveEvent::Broker {
            connected: false,
            detail: "no listeners".to_string(),
        });
        let mut receiver = bus.subscribe();
        bus.emit(LiveEvent::Reading {
            device_id: "ABC".to_string(),
            recorded_at: chrono::Utc::now(),
            gwl: 1.0,
        });
        let event = receiver.try_recv().expect("event delivered");
        assert!(matches!(event, LiveEvent::Reading { .. }));
    }
}