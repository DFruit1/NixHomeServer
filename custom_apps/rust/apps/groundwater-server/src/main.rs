//! Groundwater level platform service.
//!
//! Ingests MQTT telemetry from the STM32 groundwater loggers, interprets it
//! against explicit firmware profiles, stores it in plain PostgreSQL, and
//! serves an authenticated API plus a single-device inspection page behind the
//! shared authentication gateway.
//!
//! The pipeline is layered so each part is testable on its own:
//!
//! - [`telemetry`] parses the firmware's JSON payload, keeping its text;
//! - [`clock`] interprets the device timestamp from evidence, never a guess;
//! - [`topics`] classifies a topic by name only;
//! - [`adapter`] decides attribution, quarantine and duplicates;
//! - [`db`] stores deliveries, observations and trust state;
//! - [`ingest`] is the MQTT transport, and holds no policy.
//!
//! Slice 1 is server-side and synthetic-only: the crate builds and tests here,
//! but nothing is deployed and no broker is contacted by the test suite
//! (`GWAPP-20261023-slice1` §3). Enabling the application in NixOS stays
//! opt-in and off by default.

mod adapter;
mod api;
mod clock;
mod config;
mod db;
#[cfg(test)]
mod fixtures;
mod identity;
mod ingest;
mod profiles;
mod telemetry;
mod topics;
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
