//! Groundwater level platform service.
//!
//! Ingests MQTT telemetry from the STM32 groundwater loggers, interprets it
//! against explicit firmware profiles, stores it in plain PostgreSQL, and
//! serves the ACL-scoped API and packaged Qwik application behind the shared
//! authentication gateway. Durable commands use explicit topic bindings and
//! wake windows; alert history is replayed in recorded-time order. The
//! enrollment, clock, duplicate and quarantine safeguards remain in adapter.

mod acks;
mod adapter;
mod alerting;
mod api;
mod api_rev2;
mod clock;
mod commands;
mod config;
mod crc;
mod db;
#[cfg(test)]
mod fixtures;
#[cfg(test)]
mod followups_tests;
mod identity;
mod ingest;
#[cfg(test)]
mod ingest_tests;
mod metrics;
mod mqtt_auth;
mod notify;
mod ops_api;
#[cfg(test)]
mod ops_tests;
mod platform;
#[cfg(test)]
mod platform_tests;
mod presence;
mod profiles;
mod publisher;
#[cfg(test)]
mod publisher_tests;
mod records;
mod rev2;
mod rev2_commands;
mod rev2_store;
#[cfg(test)]
mod rev2_tests;
mod scheduler;
mod settings;
mod stream;
mod telemetry;
mod topics;
#[cfg(test)]
mod ui;
#[cfg(test)]
mod vectors_tests;
#[cfg(test)]
mod wire_follow_tests;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use config::Settings;
use ingest::{EventBus, IngestStats};

/// How often the raw delivery log is pruned.
const PRUNE_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
/// The re-run of flagged derived work: time it may take before ingest
/// starts, how often it runs while the service is up, and how long one
/// background pass may take.
const RERUN_AT_START: Duration = Duration::from_secs(20);
const RERUN_INTERVAL: Duration = Duration::from_secs(5 * 60);
const RERUN_PASS: Duration = Duration::from_secs(4 * 60);

async fn rerun_pass(
    client: &mut tokio_postgres::Client,
    policy: &config::Rev2Policy,
    limit: Duration,
) {
    let deadline = std::time::Instant::now() + limit;
    match rev2_store::reingest_salvaged(client, policy, Some(deadline)).await {
        Ok(0) => {}
        Ok(stored) => eprintln!("groundwater: stored {stored} salvaged data/stream batch(es)"),
        Err(err) => eprintln!("groundwater: salvaged batches: {err}"),
    }
    match rev2_store::rederive_pending_until(client, policy, Some(deadline)).await {
        Ok((0, 0)) => {}
        Ok((done, failing)) => {
            eprintln!("groundwater: re-derived {done} stream log(s); {failing} still failing")
        }
        Err(err) => eprintln!("groundwater: re-derivation pass stopped: {err}"),
    }
}

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
    config::install_rev2_policy(settings.rev2.clone());
    let mut client = db::connect(&settings.database_url).await?;
    db::migrate(&client).await?;
    // Derived work that failed or was deferred (raw frames kept): at most
    // RERUN_AT_START before ingest starts, the rest in the background.
    rerun_pass(&mut client, &settings.rev2, RERUN_AT_START).await;
    let rerun_url = settings.database_url.clone();
    let rerun_policy = settings.rev2.clone();
    tokio::spawn(async move {
        let mut timer = tokio::time::interval(RERUN_INTERVAL);
        let mut db: Option<tokio_postgres::Client> = None;
        loop {
            tokio::select! {
                _ = timer.tick() => {}
                // A batch left work to the re-run: let its transaction
                // commit (and the rest of the upload arrive), then run.
                _ = rev2_store::RERUN_WAKE.notified() => {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            }
            if db.as_ref().is_none_or(tokio_postgres::Client::is_closed) {
                db = db::connect(&rerun_url).await.ok();
            }
            if let Some(db) = db.as_mut() {
                rerun_pass(db, &rerun_policy, RERUN_PASS).await;
                // Skipped (a batch held the log's lock) or cut short: again
                // in a moment, not at the next timed pass.
                if rev2_store::rerun_due(db).await.unwrap_or(false) {
                    rev2_store::RERUN_WAKE.notify_one();
                }
            }
        }
    });

    // Trust state is loaded once so the first message is decided against real
    // enrollments; the ingest loop refreshes it on its own timer.
    let registry = db::load_registry(&client).await?;
    eprintln!(
        "groundwater: {} enrollment(s), {} binding(s) loaded",
        registry.enrollments().count(),
        registry.bindings().len()
    );
    let registry = Arc::new(tokio::sync::RwLock::new(registry));
    // Provisioning API → ingest loop: reload enrollments and bindings now.
    let registry_changed = Arc::new(tokio::sync::Notify::new());

    let retention_days = settings.retention_days;
    let bus = EventBus::new();
    let stats = Arc::new(tokio::sync::Mutex::new(IngestStats::default()));
    // Stored observations/configuration can need replay even without MQTT.
    let alert_db = db::Database::new(
        settings.database_url.clone(),
        db::connect(&settings.database_url).await?,
    );
    let alert_bus = bus.clone();
    let stale_margin_min = (settings.rev2.stale_margin_seconds / 60).clamp(5, 10_080) as i32;
    tokio::spawn(async move {
        let mut timer = tokio::time::interval(Duration::from_secs(1));
        let mut tick: u64 = 0;
        loop {
            timer.tick().await;
            tick += 1;
            // Missed connections are a clock event: check once a minute.
            let stale = tick % 60 == 1;
            let result = match alert_db.get().await {
                Ok(db) => {
                    let mut changed = platform::refresh_alerts(&db).await;
                    if stale && let Ok(ids) = &mut changed {
                        match alerting::evaluate_stale(&db, chrono::Utc::now(), stale_margin_min)
                            .await
                        {
                            Ok(more) => ids.extend(more),
                            Err(e) => eprintln!("groundwater stale alerts: {e}"),
                        }
                    }
                    changed
                }
                Err(e) => Err(e),
            };
            match result {
                Ok(ids) => {
                    for device_id in ids {
                        alert_bus.emit(ingest::LiveEvent::Alert { device_id });
                    }
                }
                Err(e) => eprintln!("groundwater alert engine: {e}"),
            }
        }
    });

    // Notifications run whether or not ntfy is configured: without it the
    // outbox rows are marked skipped, so nothing accumulates as pending.
    tokio::spawn(notify::run(
        settings.database_url.clone(),
        settings.ops.clone(),
    ));
    match &settings.ops.ntfy {
        Some(target) => eprintln!("groundwater: notifications to {}", target.topic_url()),
        None => eprintln!(
            "groundwater: GROUNDWATER_NTFY_URL is unset; notifications are recorded, not sent"
        ),
    }
    // Per-device MQTT accounts: rewrite the broker's view from the database
    // on start, so a restored database and the files cannot disagree.
    if let Some(dir) = &settings.ops.mqtt_auth_dir {
        match mqtt_auth::publish(&client, dir).await {
            Ok(count) => eprintln!(
                "groundwater: {count} per-device MQTT account(s) published to {}",
                dir.display()
            ),
            Err(e) => eprintln!("groundwater: per-device MQTT accounts not published: {e}"),
        }
    }

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
    let prune_client = db::Database::new(
        settings.database_url.clone(),
        db::connect(&settings.database_url).await?,
    );
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(PRUNE_INTERVAL).await;
            let result = match prune_client.get().await {
                Ok(db) => {
                    // Delivered or skipped notifications are history, not
                    // audit; alerts and the device audit keep the facts.
                    if let Err(e) = db
                        .execute(
                            "DELETE FROM notification_outbox WHERE state<>'pending'
                             AND created_at < now() - ($1::BIGINT * INTERVAL '1 day')",
                            &[&retention_days],
                        )
                        .await
                    {
                        eprintln!("groundwater: notification prune failed: {e}");
                    }
                    db::prune_deliveries(&db, retention_days).await
                }
                Err(e) => Err(e),
            };
            match result {
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
        let ingest_client = db::connect(&settings.database_url).await?;
        let ingest_bus = bus.clone();
        let ingest_stats = Arc::clone(&stats);
        let ingest_registry = Arc::clone(&registry);
        let ingest_changed = Arc::clone(&registry_changed);
        tokio::spawn(async move {
            if let Err(err) = ingest::run(
                ingest_settings,
                Arc::new(mqtt),
                ingest_client,
                ingest_bus,
                Arc::clone(&ingest_stats),
                ingest_registry,
                ingest_changed,
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
        db: Arc::new(db::Database::new(settings.database_url.clone(), client)),
        bus,
        stats,
        registry_changed,
    };
    api::serve(state).await
}
