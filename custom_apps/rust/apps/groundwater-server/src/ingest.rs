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
        /// `None` for a fault reading.
        gwl: Option<f64>,
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
    /// A revision 2 heartbeat (`health`) was stored.
    Health {
        device_id: String,
    },
    /// A device event (record, `alerts` copy or server action) was stored.
    DeviceEvent {
        device_id: String,
        event: String,
    },
    /// A `data/stream` batch added new ring frames.
    Stream {
        device_id: String,
        new_frames: u32,
    },
    /// An SD listing or download changed.
    Download {
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
    pub telemetry_connected: bool,
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
    mut client: Client,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
    registry: SharedRegistry,
    registry_changed: Arc<tokio::sync::Notify>,
) -> Result<(), String> {
    let options = mqtt_options(&mqtt, false)?;
    // Wakes the telemetry session after every reload, so it subscribes a new
    // unit's durable channels from the registry this loop just loaded rather
    // than racing it on its own timer.
    let reloaded = Arc::new(tokio::sync::Notify::new());
    let telemetry_reloaded = reloaded.clone();
    let telemetry_settings = settings.clone();
    let telemetry_mqtt = mqtt.clone();
    let telemetry_bus = bus.clone();
    let telemetry_stats = stats.clone();
    let telemetry_registry = registry.clone();
    tokio::spawn(async move {
        if let Err(e) = telemetry_run(
            telemetry_settings,
            telemetry_mqtt,
            telemetry_bus,
            telemetry_stats.clone(),
            telemetry_registry,
            telemetry_reloaded,
        )
        .await
        {
            telemetry_stats.lock().await.last_error = Some(e);
        }
    });

    let (mut mqtt_client, mut event_loop) = AsyncClient::new(options.clone(), 10);
    // This task is the sole command producer and observer of packet IDs.
    // No volatile rumqttc request survives an unconfirmed process restart.
    let mut publisher_db = worker_database(&settings, &stats, true).await?;
    let mut publisher = crate::publisher::Publisher::default();
    let mut dispatch = tokio::time::interval(Duration::from_secs(1));
    let mut connected = false;
    let mut reset_ready = true;
    let mut refresh = tokio::time::interval(Duration::from_secs(REGISTRY_REFRESH_SECONDS));
    let mut resumed = tokio::time::Instant::now();
    let mut subscribed = std::collections::HashSet::new();

    loop {
        // A database stall can leave identity-free Ready packets buffered in
        // the socket/broker even with clean sessions. Discard that connection
        // before polling again so delayed packets cannot open a new window.
        if resumed.elapsed() > Duration::from_secs(5) {
            publisher.disconnected();
            (mqtt_client, event_loop) = AsyncClient::new(options.clone(), 10);
            reset_ready = true;
            connected = false;
            stats.lock().await.connected = false;
        }
        resumed = tokio::time::Instant::now();
        let event = tokio::select! {
            event = event_loop.poll() => event,
            _ = dispatch.tick() => {
                if publisher_db.is_closed() {
                    match db::connect(&settings.database_url).await {
                        Ok(db)=>publisher_db=db,
                        Err(e)=>{eprintln!("groundwater publisher reconnect: {e}");continue}
                    }
                }
                if reset_ready {
                    match crate::scheduler::invalidate_ready(&publisher_db).await {
                        Ok(()) => { reset_ready = false; publisher.connected = connected; },
                        Err(e) => { stats.lock().await.last_error = Some(e); continue; },
                    }
                }
                if let Err(e)=crate::scheduler::tick(&mut publisher_db,&mqtt_client,&bus,&mut publisher).await {
                    eprintln!("groundwater publisher: {e}");
                    stats.lock().await.last_error=Some(e);
                }
                continue;
            }
            // Provisioning changed the registry: reload now, not within 60 s.
            _ = async {
                tokio::select! {
                    _ = refresh.tick() => {},
                    _ = registry_changed.notified() => {},
                }
            } => {
                if client.is_closed()
                    && let Ok(db) = db::connect(&settings.database_url).await
                {
                    client = db;
                }
                match db::load_registry(&client).await {
                    Ok(loaded) => {
                        let enrollments = loaded.enrollments().count();
                        let bindings = loaded.bindings().len();
                        let topics = new_topics(&mut subscribed, session_topics(&settings, &loaded, false));
                        let subscriber=mqtt_client.clone();
                        tokio::spawn(async move {for topic in topics {if let Err(e)=subscriber.subscribe(topic,rumqttc::QoS::AtLeastOnce).await {eprintln!("groundwater subscription refresh: {e}");}}});
                        *registry.write().await = loaded;
                        reloaded.notify_one();
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
                // Clean session: every subscription is new again.
                subscribed.clear();
                reset_ready = crate::scheduler::invalidate_ready(&publisher_db)
                    .await
                    .is_err();
                publisher.connected = !reset_ready;
                {
                    let mut guard = stats.lock().await;
                    guard.connected = true;
                    guard.last_error = None;
                }
                // Subscription production must not await queue capacity while
                // this same task owns event_loop.poll().
                let subscriber = mqtt_client.clone();
                let subscriptions = new_topics(
                    &mut subscribed,
                    session_topics(&settings, &*registry.read().await, false),
                );
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
                    detail: "live control session connected".into(),
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
                // Durable channels belong to the persistent session; a stale
                // control subscription from an older release must not store
                // them twice.
                if !crate::topics::durable(&publish.topic, &settings.topics) {
                    persist_publish(&settings, &publish, &mut client, &registry, &bus, &stats)
                        .await?;
                }
                acknowledge(mqtt_client.clone(), publish);
            }
            Ok(_) => {}
            Err(err) => {
                // Explicitly discard the old session's volatile packets.
                // SQL owns recovery and wake-window/spacing checks; automatic
                // MQTT replay could otherwise publish after sleep or cancel.
                publisher.disconnected();
                reset_ready = true;
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

fn mqtt_options(mqtt: &MqttSettings, telemetry: bool) -> Result<MqttOptions, String> {
    let id = if telemetry {
        format!("{}-telemetry", mqtt.client_id)
    } else {
        mqtt.client_id.clone()
    };
    let mut options = MqttOptions::new(id, mqtt.host.clone(), mqtt.port);
    options.set_keep_alive(Duration::from_secs(mqtt.keep_alive_seconds));
    // Identity-free Ready/ack traffic must never survive an offline interval.
    options.set_clean_session(!telemetry);
    options.set_manual_acks(true);
    if let Some(username) = &mqtt.username {
        let password = match &mqtt.password_file {
            Some(path) => homelab_common::read_secret_file(path)?,
            None => String::new(),
        };
        options.set_credentials(username, password);
    }
    Ok(options)
}

fn session_topics(
    settings: &Settings,
    registry: &EnrollmentRegistry,
    telemetry: bool,
) -> Vec<String> {
    let mut topics = settings.topics.subscribe_topics();
    topics.extend(registry.bindings().iter().map(|b| b.topic.clone()));
    // The platform never subscribes to its own gwl/v1 downlink.
    topics.retain(|topic| {
        !crate::topics::downlink(topic)
            && crate::topics::durable(topic, &settings.topics) == telemetry
    });
    topics.sort();
    topics.dedup();
    topics
}

/// Topics not yet subscribed in this session. Re-subscribing an existing
/// filter makes the broker resend every retained message on it (MQTT 3.1.1
/// §3.8.4), so the registry refresh only subscribes what is new.
fn new_topics(
    subscribed: &mut std::collections::HashSet<String>,
    topics: Vec<String>,
) -> Vec<String> {
    topics
        .into_iter()
        .filter(|topic| subscribed.insert(topic.clone()))
        .collect()
}

fn acknowledge(client: AsyncClient, publish: rumqttc::Publish) {
    // This task must not await capacity on the queue it alone polls.
    tokio::spawn(async move {
        if let Err(e) = client.ack(&publish).await {
            eprintln!("groundwater committed delivery acknowledgment: {e}");
        }
    });
}

/// Only readings use a persistent session. In particular a queued Ready must
/// never be mistaken for evidence that a sleeping logger is currently awake.
async fn telemetry_run(
    settings: Arc<Settings>,
    mqtt: Arc<MqttSettings>,
    bus: EventBus,
    stats: Arc<tokio::sync::Mutex<IngestStats>>,
    registry: SharedRegistry,
    reloaded: Arc<tokio::sync::Notify>,
) -> Result<(), String> {
    let (subscriber, mut events) = AsyncClient::new(mqtt_options(&mqtt, true)?, 10);
    let mut client = worker_database(&settings, &stats, false).await?;
    let mut refresh = tokio::time::interval(Duration::from_secs(REGISTRY_REFRESH_SECONDS));
    let mut connected = false;
    let mut subscribed = std::collections::HashSet::new();
    loop {
        let event = tokio::select! {
            event = events.poll() => event,
            _ = async {
                tokio::select! {
                    _ = refresh.tick() => {},
                    _ = reloaded.notified() => {},
                }
            }, if connected => {
                let topics = new_topics(&mut subscribed, session_topics(&settings, &*registry.read().await, true));
                let sender = subscriber.clone();
                tokio::spawn(async move { for topic in topics {
                    if let Err(e) = sender.subscribe(topic, rumqttc::QoS::AtLeastOnce).await {
                        eprintln!("groundwater telemetry subscription: {e}");
                    }
                }});
                continue;
            },
            _ = homelab_common::shutdown_signal() => return Ok(()),
        };
        match event {
            Ok(Event::Incoming(Incoming::ConnAck(ack))) => {
                connected = true;
                stats.lock().await.telemetry_connected = true;
                if !ack.session_present {
                    subscribed.clear();
                }
                let topics = new_topics(
                    &mut subscribed,
                    session_topics(&settings, &*registry.read().await, true),
                );
                let sender = subscriber.clone();
                tokio::spawn(async move {
                    for topic in topics {
                        if let Err(e) = sender.subscribe(topic, rumqttc::QoS::AtLeastOnce).await {
                            eprintln!("groundwater telemetry subscription: {e}");
                        }
                    }
                });
                bus.emit(LiveEvent::Broker {
                    connected: true,
                    detail: "durable telemetry session connected".into(),
                });
            }
            Ok(Event::Incoming(Incoming::Publish(publish))) => {
                // Discard any pre-upgrade control subscription from a resumed
                // telemetry session rather than allowing it to open a window.
                if crate::topics::durable(&publish.topic, &settings.topics) {
                    persist_publish(&settings, &publish, &mut client, &registry, &bus, &stats)
                        .await?;
                }
                acknowledge(subscriber.clone(), publish);
            }
            Ok(_) => {}
            Err(e) => {
                connected = false;
                let mut state = stats.lock().await;
                state.telemetry_connected = false;
                state.last_error = Some(e.to_string());
                drop(state);
                bus.emit(LiveEvent::Broker {
                    connected: false,
                    detail: "telemetry disconnected".into(),
                });
                tokio::time::sleep(Duration::from_secs(RECONNECT_BACKOFF_SECONDS)).await;
            }
        }
    }
}

/// Worker startup races database restarts just like ordinary ingestion. Keep
/// trying instead of silently leaving HTTP alive with a terminated subscriber.
async fn worker_database(
    settings: &Settings,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
    recover_publishes: bool,
) -> Result<Client, String> {
    loop {
        let result = match db::connect(&settings.database_url).await {
            Ok(client) => {
                if recover_publishes {
                    crate::publisher::recover(&client).await.map(|()| client)
                } else {
                    Ok(client)
                }
            }
            Err(e) => Err(e),
        };
        match result {
            Ok(client) => return Ok(client),
            Err(e) => {
                eprintln!("groundwater worker database initialization: {e}");
                stats.lock().await.last_error = Some(e);
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {},
                    _ = homelab_common::shutdown_signal() => return Err("worker stopping before database initialization".into()),
                }
            }
        }
    }
}

async fn persist_publish(
    settings: &Settings,
    publish: &rumqttc::Publish,
    client: &mut Client,
    registry: &SharedRegistry,
    bus: &EventBus,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
) -> Result<(), String> {
    let received_at = chrono::Utc::now();
    let mut refresh_registry = client.is_closed();
    loop {
        let result = if client.is_closed() {
            refresh_registry = true;
            match db::connect(&settings.database_url).await {
                Ok(db) => {
                    *client = db;
                    Ok(())
                }
                Err(e) => Err(e),
            }
        } else {
            Ok(())
        };
        let result = if result.is_ok() && refresh_registry {
            match db::load_registry(client).await {
                Ok(loaded) => {
                    *registry.write().await = loaded;
                    refresh_registry = false;
                    Ok(())
                }
                Err(e) => Err(e),
            }
        } else {
            result
        };
        let result = match result {
            Ok(()) => {
                handle_publish(
                    &publish.topic,
                    &publish.payload,
                    publish.qos as i16,
                    publish.retain,
                    received_at,
                    &settings.topics,
                    client,
                    registry,
                    bus,
                    stats,
                )
                .await
            }
            Err(e) => Err(e),
        };
        match result {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("groundwater: retrying uncommitted delivery: {e}");
                stats.lock().await.last_error = Some(e);
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {},
                    _ = homelab_common::shutdown_signal() => return Err("ingest stopping with uncommitted delivery".into()),
                }
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
    client: &mut Client,
    registry: &SharedRegistry,
    bus: &EventBus,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
) -> Result<(), String> {
    let delivery = Delivery {
        topic,
        payload,
        qos,
        received_at,
    };
    let registry = registry.read().await.clone();
    if let Some(route) = rev2_route(topic, payload, &registry) {
        return handle_rev2(&delivery, retained, &route, topic_map, client, bus, stats).await;
    }
    let evaluation = adapter::evaluate(&delivery, &registry, topic_map);

    let tx = client.transaction().await.map_err(|e| e.to_string())?;
    let key = match &evaluation {
        adapter::Evaluation::Quarantined { record, .. }
        | adapter::Evaluation::Candidate { record, .. } => db::intake_key(record),
    };
    if db::existing_intake(&tx, &key).await?.is_some() {
        return Ok(());
    }
    let deferred_bus = EventBus::new();
    let mut deferred_events = deferred_bus.subscribe();
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
            // meaningful. Retry lookup failures with the transaction instead
            // of guessing that an existing measurement is new.
            let history = db::prior_observations(
                &tx,
                &observation.device_id,
                observation.recorded_at,
                observation.received_at,
            )
            .await?;
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

    if !retained
        && intake.record.quarantine_reason == Some(adapter::QuarantineReason::AncillaryChannel)
    {
        match crate::scheduler::ancillary(
            &tx,
            &registry,
            topic,
            payload,
            topic_map,
            received_at,
            &deferred_bus,
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
            Err(e) => return Err(e),
        }
    }

    db::record_intake_in(&tx, &intake).await?;
    tx.commit()
        .await
        .map_err(|e| format!("commit intake: {e}"))?;
    while let Ok(event) = deferred_events.try_recv() {
        bus.emit(event);
    }
    {
        let mut guard = stats.lock().await;
        guard.deliveries += 1;
        if let IntakeOutcome::Quarantined { reason, .. } = &intake.outcome {
            guard.quarantined += 1;
            guard.last_quarantine_reason = Some(reason.code().to_string());
        }
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
    Ok(())
}

/// A trusted `gwl/v1` delivery that carries protocol revision 2.
pub struct Rev2Route {
    pub device_id: String,
    pub channel: String,
    pub binding_key: String,
    pub profile: crate::profiles::ProfileId,
}

/// Selects the revision 2 path: an attributed `gwl/v1/<DEV>/<channel>`
/// binding (V21 or V22 enrollment) whose payload is revision 2. Everything
/// else, including untrusted or unbound revision 2 traffic, takes the
/// revision 1 adapter and is quarantined there with the usual reasons.
pub fn rev2_route(topic: &str, payload: &[u8], registry: &EnrollmentRegistry) -> Option<Rev2Route> {
    let (_, channel) = crate::topics::device_channel(topic)?;
    if !crate::rev2::UPLINK_CHANNELS.contains(&channel) {
        return None;
    }
    let binding = crate::scheduler::attributed(registry, topic)?;
    if !matches!(
        binding.profile,
        crate::profiles::ProfileId::V21 | crate::profiles::ProfileId::V22
    ) || !crate::rev2::is_rev2_payload(channel, payload)
    {
        return None;
    }
    Some(Rev2Route {
        device_id: binding.device_id.to_ascii_uppercase(),
        channel: channel.to_owned(),
        binding_key: binding.key.clone(),
        profile: binding.profile,
    })
}

#[allow(clippy::too_many_arguments)]
async fn handle_rev2(
    delivery: &Delivery<'_>,
    retained: bool,
    route: &Rev2Route,
    topic_map: &TopicMap,
    client: &mut Client,
    bus: &EventBus,
    stats: &Arc<tokio::sync::Mutex<IngestStats>>,
) -> Result<(), String> {
    let mut tx = client.transaction().await.map_err(|e| e.to_string())?;
    let binary = matches!(route.channel.as_str(), "data/stream" | "data/file");
    let text = std::str::from_utf8(delivery.payload).ok();
    let mut record = adapter::DeliveryRecord {
        received_at: delivery.received_at,
        topic: delivery.topic.to_string(),
        qos: delivery.qos,
        kind: crate::topics::classify(delivery.topic, topic_map),
        payload_text: match text {
            Some(text) if !binary => text.replace('\0', "\\u0000"),
            // The hex fallback is readable text; raw binary is not.
            Some(text) if text.trim_end().bytes().all(|b| b.is_ascii_hexdigit()) => text.to_owned(),
            _ => format!(
                "[binary {} payload, {} bytes; raw bytes in stream_batches]",
                route.channel,
                delivery.payload.len()
            ),
        },
        payload_size: delivery.payload.len(),
        payload_digest: adapter::sha256_hex(delivery.payload),
        payload_json: if binary {
            None
        } else {
            serde_json::from_slice(delivery.payload).ok()
        },
        profile: Some(route.profile),
        binding_key: Some(route.binding_key.clone()),
        device_id: Some(route.device_id.clone()),
        claimed_device_id: None,
        state: adapter::DeliveryState::Accepted,
        quarantine_reason: None,
        quarantine_detail: None,
        time_quality: None,
        duplicate: Some(adapter::DuplicateDecision::fresh("protocol revision 2")),
    };
    if record
        .payload_json
        .as_ref()
        .is_some_and(|v| v.to_string().contains("\\u0000"))
    {
        record.payload_json = None;
    }
    let key = db::intake_key(&record);
    if db::existing_intake(&tx, &key).await?.is_some() {
        return Ok(());
    }
    if retained
        && crate::rev2_store::retained_unchanged(
            &tx,
            &route.device_id,
            &route.channel,
            delivery.payload,
        )
        .await?
    {
        // A retained status/info re-sent on subscription that says nothing new.
        return Ok(());
    }
    let intake = adapter::Intake {
        outcome: IntakeOutcome::Accepted {
            observation: None,
            duplicate: adapter::DuplicateDecision::fresh("protocol revision 2"),
        },
        record,
    };
    let delivery_id = db::record_intake_in(&tx, &intake).await?;
    let context = crate::rev2_store::Context {
        device_id: &route.device_id,
        channel: &route.channel,
        received_at: delivery.received_at,
        retained,
        delivery_id: Some(delivery_id),
        policy: crate::config::rev2_policy(),
    };
    // A message PostgreSQL refuses for its content fails the same way on
    // every retry; persist_publish would retry it forever without acking,
    // stalling the session for every logger. Only transient failures are
    // retried. Derived work for data/stream and data/file runs in its own
    // savepoints inside rev2_store and never costs the raw rows; this outer
    // savepoint only catches what is left.
    let stored = tx
        .savepoint("rev2_store")
        .await
        .map_err(|e| format!("rev2 savepoint: {e}"))?;
    let mut failed = None;
    let outcome = match crate::rev2_store::store(&stored, &context, delivery.payload).await {
        Ok(outcome) => {
            stored
                .commit()
                .await
                .map_err(|e| format!("rev2 savepoint release: {e}"))?;
            outcome
        }
        Err(error) if crate::rev2_store::transient_error(&error) => return Err(error),
        Err(error) => {
            stored
                .rollback()
                .await
                .map_err(|e| format!("rev2 savepoint rollback: {e}"))?;
            if binary {
                // Whatever failed, the verified bytes the logger is about to
                // free are kept.
                tx.execute(
                    "INSERT INTO stream_batches(device_id,delivery_id,received_at,channel,encoding,raw,size,ok,error)
                     VALUES($1,$2,$3,$4,'raw',$5,$6,false,$7)",
                    &[
                        &route.device_id,
                        &delivery_id,
                        &delivery.received_at,
                        &route.channel,
                        &delivery.payload,
                        &(delivery.payload.len() as i32),
                        &format!("not stored: {error}"),
                    ],
                )
                .await
                .map_err(|e| format!("rev2 raw salvage: {e}"))?;
            }
            if content_error(&error) {
                crate::rev2_store::Outcome::rejected(format!("not storable: {error}"))
            } else {
                failed = Some(format!("storing failed: {error}"));
                crate::rev2_store::Outcome::default()
            }
        }
    };
    if let Some(reason) = &failed {
        // Not the message's fault: kept visible apart from invalid content.
        tx.execute(
            "UPDATE deliveries SET state='quarantined',reason='rev2-store-failed',detail=$2 WHERE id=$1",
            &[&delivery_id, reason],
        )
        .await
        .map_err(|e| format!("rev2 store failure: {e}"))?;
    } else if let Some(reason) = &outcome.rejected {
        tx.execute(
            "UPDATE deliveries SET state='quarantined',reason='rev2-invalid',detail=$2 WHERE id=$1",
            &[&delivery_id, reason],
        )
        .await
        .map_err(|e| format!("rev2 rejection: {e}"))?;
    } else if let Some(detail) = &outcome.detail {
        tx.execute(
            "UPDATE deliveries SET detail=$2 WHERE id=$1",
            &[&delivery_id, detail],
        )
        .await
        .map_err(|e| format!("rev2 detail: {e}"))?;
    }
    tx.commit()
        .await
        .map_err(|e| format!("commit rev2 intake: {e}"))?;
    {
        let mut guard = stats.lock().await;
        guard.deliveries += 1;
        if let Some(reason) = &failed {
            guard.quarantined += 1;
            guard.last_quarantine_reason = Some("rev2-store-failed".into());
            eprintln!(
                "groundwater: revision 2 {} from {} kept but not stored: {reason}",
                route.channel, route.device_id
            );
        }
        if let Some(reason) = &outcome.rejected {
            guard.quarantined += 1;
            guard.last_quarantine_reason = Some("rev2-invalid".into());
            eprintln!(
                "groundwater: rejected revision 2 {} from {}: {reason}",
                route.channel, route.device_id
            );
        }
        guard.observations += outcome
            .events
            .iter()
            .filter(|e| matches!(e, LiveEvent::Observation { .. }))
            .count() as u64;
    }
    for event in outcome.events {
        bus.emit(event);
    }
    Ok(())
}

/// Whether a storage error is caused by the message content itself, so the
/// message is invalid: text or JSON the database cannot hold (22021 a NUL
/// or bad encoding, 22P05 an untranslatable character) or a program limit
/// (54). Every other non-transient error (a value out of range computed
/// from stored state, a constraint) is a storing failure, not invalid
/// content: see `handle_rev2`.
fn content_error(error: &str) -> bool {
    crate::rev2_store::sqlstate(error)
        .is_some_and(|code| matches!(code, "22021" | "22P05") || code.starts_with("54"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_content_errors_are_permanent() {
        assert!(content_error(
            "info update: invalid byte sequence for encoding \"UTF8\": 0x00 [22021]"
        ));
        // Out of range is usually computed from stored state (R1): a
        // storing failure, not invalid content.
        assert!(!content_error("x: integer out of range [22003]"));
        assert!(!content_error("x: timestamp out of range [22008]"));
        assert!(!content_error("x: deadlock detected [40P01]"));
        assert!(!content_error("x: duplicate key [23505]"));
        assert!(!content_error("x: connection closed"));
        assert!(crate::rev2_store::transient_error(
            "x: deadlock detected [40P01]"
        ));
        assert!(crate::rev2_store::transient_error("x: connection closed"));
        assert!(!crate::rev2_store::transient_error(
            "x: timestamp out of range [22008]"
        ));
        assert!(!crate::rev2_store::transient_error(
            "x: duplicate key [23505]"
        ));
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
        bus.emit(LiveEvent::Observation {
            device_id: "ABC".to_string(),
            recorded_at: Some(chrono::Utc::now()),
            gwl: Some(1.0),
        });
        let event = receiver.try_recv().expect("event delivered");
        assert!(matches!(event, LiveEvent::Observation { .. }));
    }

    #[test]
    fn refresh_subscribes_only_new_topics() {
        let mut subscribed = std::collections::HashSet::new();
        assert_eq!(
            new_topics(&mut subscribed, vec!["a".into(), "b".into()]).len(),
            2
        );
        assert_eq!(
            new_topics(&mut subscribed, vec!["a".into(), "b".into(), "c".into()]),
            vec!["c".to_string()]
        );
        subscribed.clear();
        assert_eq!(new_topics(&mut subscribed, vec!["a".into()]).len(), 1);
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
