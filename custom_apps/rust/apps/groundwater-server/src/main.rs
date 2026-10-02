//! Groundwater level platform service.
//!
//! Ingests MQTT telemetry from the STM32 groundwater loggers, stores it in
//! PostgreSQL/TimescaleDB, and serves the multi-user web app behind the shared
//! authentication gateway.
//!
//! The firmware is still in development and its MQTT topic names are
//! compile-time constants that may change. Topic configuration therefore lives
//! in the environment rather than in code, and message classification falls
//! back to payload shape, so a topic rename does not require a new binary.

mod api;
mod config;
mod db;
mod identity;
mod ingest;
mod telemetry;
mod topics;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use config::Settings;
use ingest::{EventBus, IngestStats};

/// How often the raw message log is pruned.
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

    // Retention keeps the raw log bounded. Readings are never pruned: at the
    // firmware's cadence a device adds roughly 175_000 rows a year.
    let prune_client = client.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(PRUNE_INTERVAL).await;
            match db::prune_messages(&prune_client, retention_days).await {
                Ok(0) => {}
                Ok(removed) => eprintln!(
                    "groundwater: pruned {removed} raw message rows older than {retention_days} days"
                ),
                Err(err) => eprintln!("groundwater: message prune failed: {err}"),
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
        tokio::spawn(async move {
            if let Err(err) = ingest::run(
                ingest_settings,
                Arc::new(mqtt),
                ingest_client,
                ingest_bus.clone(),
                Arc::clone(&ingest_stats),
            )
            .await
            {
                eprintln!("groundwater: ingest loop stopped: {err}");
                ingest_stats.lock().await.last_error = Some(err);
            }
        });
    }

    let state = api::AppState {
        settings: settings.clone(),
        db: client,
        bus,
        stats,
    };
    api::serve(state, settings.frontend_dir.clone()).await
}