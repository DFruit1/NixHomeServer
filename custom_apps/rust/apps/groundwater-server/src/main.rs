//! Groundwater level platform service.
//!
//! Ingests MQTT telemetry from the STM32 groundwater loggers, interprets it
//! against explicit firmware profiles, stores it in plain PostgreSQL, and
//! serves the ACL-scoped API and packaged Qwik application behind the shared
//! authentication gateway. Durable commands use explicit topic bindings and
//! wake windows; alert history is replayed in recorded-time order. The
//! enrollment, clock, duplicate and quarantine safeguards remain in adapter.

mod adapter;
mod api;
mod clock;
mod commands;
mod config;
mod db;
#[cfg(test)]
mod fixtures;
mod identity;
mod ingest;
mod platform;
#[cfg(test)]
mod platform_tests;
mod profiles;
mod scheduler;
mod telemetry;
mod topics;
#[cfg(test)]
mod ui;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use config::Settings;
use ingest::{EventBus, IngestStats};

/// How often the raw delivery log is pruned.
const PRUNE_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            homelab_common::log_startup_failed("groundwater-server", &err.to_string());
            return ExitCode::FAILURE;
        }
    };

    match runtime.block_on(run()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            homelab_common::log_startup_failed("groundwater-server", &err);
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let settings = Arc::new(Settings::from_env()?);
    let client = Arc::new(db::connect(&settings.database_url).await?);
    db::migrate(&client).await?;

    // Trust state is loaded once so the first message is decided against real
    // enrollments; the ingest loop refreshes it on its own timer.
    let registry = db::load_registry(&client).await?;
    eprintln!(
        "groundwater: {} enrollment(s), {} binding(s) loaded",
        registry.enrollments().count(),
        registry.bindings().len()
    );
    let registry = Arc::new(tokio::sync::RwLock::new(registry));

    let retention_days = settings.retention_days;
    let bus = EventBus::new();
    let stats = Arc::new(tokio::sync::Mutex::new(IngestStats::default()));
    // Stored observations/configuration can need replay even without MQTT.
    let alert_db = client.clone();
    let alert_bus = bus.clone();
    tokio::spawn(async move {
        let mut timer = tokio::time::interval(Duration::from_secs(1));
        loop {
            timer.tick().await;
            match platform::refresh_alerts(&alert_db).await {
                Ok(ids) => {
                    for device_id in ids {
                        alert_bus.emit(ingest::LiveEvent::Alert { device_id });
                    }
                }
                Err(e) => eprintln!("groundwater alert engine: {e}"),
            }
        }
    });

    match &settings.mqtt {
        Some(mqtt) => eprintln!(
            "groundwater: ingesting from {} as client {:?} across {} topic(s)",
            mqtt.url,
            mqtt.client_id,
            settings.topics.subscribe_topics().len()
        ),
        None => eprintln!(
            "groundwater: GROUNDWATER_MQTT_URL is unset; serving stored data with no live ingest"
        ),
    }

    // Retention keeps the raw delivery log bounded. Observations are never
    // pruned, and pruning clears their delivery reference rather than deleting
    // them.
    let prune_client = client.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(PRUNE_INTERVAL).await;
            match db::prune_deliveries(&prune_client, retention_days).await {
                Ok(0) => {}
                Ok(removed) => eprintln!(
                    "groundwater: pruned {removed} raw delivery rows older than {retention_days} days"
                ),
                Err(err) => eprintln!("groundwater: delivery prune failed: {err}"),
            }
        }
    });

    // Live ingest, when a broker is configured. A broker outage must not take
    // the app down, so the task logs and the HTTP surface keeps serving stored
    // data.
    if let Some(mqtt) = settings.mqtt.clone() {
        let ingest_settings = settings.clone();
        let ingest_client = client.clone();
        let ingest_bus = bus.clone();
        let ingest_stats = Arc::clone(&stats);
        let ingest_registry = Arc::clone(&registry);
        tokio::spawn(async move {
            if let Err(err) = ingest::run(
                ingest_settings,
                Arc::new(mqtt),
                ingest_client,
                ingest_bus,
                Arc::clone(&ingest_stats),
                ingest_registry,
            )
            .await
            {
                eprintln!("groundwater: ingest loop stopped: {err}");
                ingest_stats.lock().await.last_error = Some(err);
            }
        });
    } else {
        // No broker: release the registry handle so nothing silently implies
        // live traffic is refreshing it.
        drop(registry);
    }

    let state = api::AppState {
        settings: settings.clone(),
        db: client,
        bus,
        stats,
    };
    api::serve(state).await
}
