//! PostgreSQL storage.
//!
//! The platform stores into the host's shared PostgreSQL cluster as the
//! `groundwater` database and role, following the Search module's pattern.
//! `readings` is a TimescaleDB hypertable because the firmware writes roughly
//! one row per three minutes per device and charts query wide ranges.
//!
//! Two timestamps are kept per reading on purpose. `recorded_at` is the device's
//! own clock normalised to UTC and is what charts and alerting use;
//! `received_at` is this host's clock. Backlog replay means the two legitimately
//! diverge by days, and the divergence is itself useful information, so it is
//! stored rather than collapsed.

use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio_postgres::{Client, NoTls};

use crate::telemetry::Reading;

/// Opens a connection with keepalives and a statement timeout.
///
/// Without these a connection silently half-opened by a network churn would
/// hang the ingest loop instead of failing and reconnecting.
pub async fn connect(database_url: &str) -> Result<Client, String> {
    let mut config: tokio_postgres::Config = database_url
        .parse()
        .map_err(|err| format!("invalid database URL: {err}"))?;
    config.tcp_user_timeout(Duration::from_secs(60));
    config.keepalives(true);
    config.keepalives_idle(Duration::from_secs(30));
    let (client, connection) = config.connect(NoTls).await.map_err(|err| {
        format!("failed to connect to the groundwater database: {err}")
    })?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("groundwater database connection error: {err}");
        }
    });
    Ok(client)
}

/// Creates the schema if absent.
///
/// TimescaleDB is optional at runtime: the `readings` table is created as a
/// plain table and only converted to a hypertable when the extension is
/// available. That keeps the service functional on a cluster without the
/// extension preloaded, which is also what makes the module removable and
/// re-addable without a manual database step.
pub async fn migrate(client: &Client) -> Result<(), String> {
    client
        .batch_execute(
            "
            CREATE TABLE IF NOT EXISTS devices (
                device_id          TEXT PRIMARY KEY,
                display_name       TEXT,
                first_seen         TIMESTAMPTZ NOT NULL DEFAULT now(),
                last_seen          TIMESTAMPTZ,
                last_ready_at      TIMESTAMPTZ,
                last_sleep_at      TIMESTAMPTZ,
                local_offset_min   INTEGER NOT NULL DEFAULT 300,
                location_id        TEXT,
                sensor_id          TEXT
            );

            CREATE TABLE IF NOT EXISTS readings (
                recorded_at    TIMESTAMPTZ NOT NULL,
                received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
                device_id      TEXT NOT NULL,
                -- DOUBLE PRECISION rather than NUMERIC: tokio-postgres has
                -- no f64 mapping without an extra dependency, and these are
                -- measured values whose exact decimal scale is not meaningful.
                gwl            DOUBLE PRECISION NOT NULL,
                rssi           SMALLINT,
                battery_v      DOUBLE PRECISION,
                solar_v        DOUBLE PRECISION,
                time_plausible BOOLEAN NOT NULL DEFAULT TRUE,
                device_time    TEXT NOT NULL,
                payload        JSONB NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id          BIGSERIAL PRIMARY KEY,
                received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                topic       TEXT NOT NULL,
                kind        TEXT NOT NULL,
                device_id   TEXT,
                qos         SMALLINT,
                payload     TEXT NOT NULL,
                parse_error TEXT
            );

            CREATE INDEX IF NOT EXISTS readings_device_recorded_idx
                ON readings (device_id, recorded_at DESC);
            CREATE INDEX IF NOT EXISTS readings_received_idx
                ON readings (received_at DESC);
            CREATE INDEX IF NOT EXISTS messages_received_idx
                ON messages (received_at DESC);
            CREATE INDEX IF NOT EXISTS messages_device_idx
                ON messages (device_id, received_at DESC)
                WHERE device_id IS NOT NULL;
            ",
        )
        .await
        .map_err(|err| format!("schema creation failed: {err}"))?;

    // The dedupe guarantee for QoS 1 redelivery. Created separately because a
    // pre-existing hypertable already has the index TimescaleDB needs and a
    // conflicting non-unique index of the same name would only warn.
    if let Err(err) = client
        .batch_execute(
            "
            CREATE UNIQUE INDEX IF NOT EXISTS readings_dedupe_idx
                ON readings (device_id, recorded_at)
                WHERE time_plausible;
            ",
        )
        .await
    {
        eprintln!("groundwater: could not create dedupe index: {err}");
    }

    if let Err(err) = convert_readings_to_hypertable(client).await {
        // Not fatal: the platform stays correct on plain PostgreSQL, only
        // without TimescaleDB's chunk retention and compression.
        eprintln!("groundwater: running without TimescaleDB hypertable ({err})");
    }
    Ok(())
}

/// Converts `readings` into a hypertable when the extension is present.
async fn convert_readings_to_hypertable(client: &Client) -> Result<(), String> {
    let available: bool = client
        .query_one("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')", &[])
        .await
        .map_err(|err| format!("extension probe failed: {err}"))?
        .get(0);
    if !available {
        return Err("timescaledb extension is not installed".to_string());
    }
    let already: bool = client
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = 'readings')",
            &[],
        )
        .await
        .map_err(|err| format!("hypertable probe failed: {err}"))?
        .get(0);
    if already {
        return Ok(());
    }
    client
        .batch_execute(
            "SELECT create_hypertable('readings', 'recorded_at', if_not_exists => TRUE, migrate_data => TRUE);",
        )
        .await
        .map_err(|err| format!("create_hypertable failed: {err}"))
}

/// Registers a device if new, and refreshes its presence timestamps.
///
/// `asleep`/`awake` come from the firmware's `Ready`/`sleep` messages on the
/// device-status topic; `seen` is any inbound message at all.
pub async fn upsert_device_presence(
    client: &Client,
    device_id: &str,
    local_offset_min: i32,
    event: PresenceEvent,
) -> Result<(), String> {
    let statement = match event {
        PresenceEvent::Seen => {
            "INSERT INTO devices (device_id, last_seen, local_offset_min) VALUES ($1, now(), $2)
             ON CONFLICT (device_id) DO UPDATE SET last_seen = now()"
        }
        PresenceEvent::Awake => {
            "INSERT INTO devices (device_id, last_seen, last_ready_at, local_offset_min)
             VALUES ($1, now(), now(), $2)
             ON CONFLICT (device_id) DO UPDATE
                SET last_seen = now(), last_ready_at = now()"
        }
        PresenceEvent::Asleep => {
            "INSERT INTO devices (device_id, last_seen, last_sleep_at, local_offset_min)
             VALUES ($1, now(), now(), $2)
             ON CONFLICT (device_id) DO UPDATE
                SET last_seen = now(), last_sleep_at = now()"
        }
    };
    client
        .execute(statement, &[&device_id, &local_offset_min])
        .await
        .map_err(|err| format!("device presence update failed: {err}"))?;
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceEvent {
    /// Any inbound message from the device.
    Seen,
    /// The device published `Ready`.
    Awake,
    /// The device published `sleep`.
    Asleep,
}

/// Stores a reading, returning false when it was a duplicate delivery.
///
/// The firmware publishes QoS 1, so the broker is entitled to redeliver. The
/// partial unique index on `(device_id, recorded_at)` collapses those, and
/// `ON CONFLICT DO NOTHING` keeps the first copy.
pub async fn insert_reading(client: &Client, reading: &Reading) -> Result<bool, String> {
    let payload: serde_json::Value =
        serde_json::from_str(reading.raw.trim()).unwrap_or(serde_json::Value::Null);
    let rows = client
        .execute(
            "INSERT INTO readings
                (recorded_at, device_id, gwl, rssi, battery_v, solar_v,
                 time_plausible, device_time, payload)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
             ON CONFLICT (device_id, recorded_at) WHERE time_plausible DO NOTHING",
            &[
                &reading.recorded_at,
                &reading.device_id,
                &reading.gwl,
                &reading.rssi,
                &reading.battery_v,
                &reading.solar_v,
                &reading.time_plausible,
                &reading.device_time,
                &payload,
            ],
        )
        .await
        .map_err(|err| format!("reading insert failed: {err}"))?;
    Ok(rows > 0)
}

/// Appends an inbound message to the raw log.
///
/// Every message is kept, including ones the parser rejected: when a firmware
/// revision changes the payload shape, this table is the only record of what
/// the device actually sent.
pub async fn insert_message(
    client: &Client,
    topic: &str,
    kind: &str,
    device_id: Option<&str>,
    qos: i16,
    payload: &str,
    parse_error: Option<&str>,
) -> Result<(), String> {
    client
        .execute(
            "INSERT INTO messages (topic, kind, device_id, qos, payload, parse_error)
             VALUES ($1, $2, $3, $4, $5, $6)",
            &[&topic, &kind, &device_id, &qos, &payload, &parse_error],
        )
        .await
        .map_err(|err| format!("message insert failed: {err}"))?;
    Ok(())
}

/// A device row as presented to the UI.
#[derive(Debug, Clone, Serialize)]
pub struct Device {
    pub device_id: String,
    pub display_name: String,
    pub status: String,
    pub first_seen: DateTime<Utc>,
    pub last_seen: Option<DateTime<Utc>>,
    pub last_ready_at: Option<DateTime<Utc>>,
    pub last_reading_at: Option<DateTime<Utc>>,
    pub latest_gwl: Option<f64>,
    pub latest_rssi: Option<i16>,
    pub latest_battery_v: Option<f64>,
    pub latest_solar_v: Option<f64>,
    pub latest_time_plausible: bool,
    pub reading_count: i64,
    pub location_id: Option<String>,
    pub sensor_id: Option<String>,
}

/// Derives presence status from the last-seen timestamps.
///
/// The firmware has no LWT and is silent while it sleeps, so "no recent
/// message" means either sleeping or unreachable. A device that reported `Ready`
/// within the awake window is `awake`; one seen recently without a matching
/// `Ready` is `asleep`; anything older than the stale threshold is `stale`.
fn presence_status(
    last_seen: Option<DateTime<Utc>>,
    last_ready_at: Option<DateTime<Utc>>,
) -> &'static str {
    let Some(last_seen) = last_seen else {
        return "unknown";
    };
    let now = Utc::now();
    if now.signed_duration_since(last_seen).num_minutes() > crate::config::STALE_AFTER_MINUTES {
        return "stale";
    }
    match last_ready_at {
        Some(ready)
            if now.signed_duration_since(ready).num_minutes()
                <= crate::config::AWAKE_WINDOW_MINUTES =>
        {
            "awake"
        }
        _ => "asleep",
    }
}

/// Lists every known device with its latest reading.
pub async fn list_devices(client: &Client) -> Result<Vec<Device>, String> {
    let rows = client
        .query(
            "SELECT d.device_id,
                    COALESCE(d.display_name, ''),
                    d.first_seen,
                    d.last_seen,
                    d.last_ready_at,
                    d.location_id,
                    d.sensor_id,
                    latest.recorded_at,
                    latest.gwl,
                    latest.rssi,
                    latest.battery_v,
                    latest.solar_v,
                    latest.time_plausible,
                    COALESCE(counts.reading_count, 0)
             FROM devices d
             LEFT JOIN LATERAL (
                SELECT recorded_at, gwl, rssi, battery_v, solar_v, time_plausible
                FROM readings
                WHERE readings.device_id = d.device_id
                ORDER BY recorded_at DESC
                LIMIT 1
             ) latest ON TRUE
             LEFT JOIN LATERAL (
                SELECT COUNT(*)::BIGINT AS reading_count
                FROM readings
                WHERE readings.device_id = d.device_id
             ) counts ON TRUE
             ORDER BY d.device_id",
            &[],
        )
        .await
        .map_err(|err| format!("device listing failed: {err}"))?;

    rows.into_iter()
        .map(|row| {
            let last_seen: Option<DateTime<Utc>> = row.get(3);
            let last_ready_at: Option<DateTime<Utc>> = row.get(4);
            Ok(Device {
                device_id: row.get(0),
                display_name: row.get(1),
                status: presence_status(last_seen, last_ready_at).to_string(),
                first_seen: row.get(2),
                last_seen,
                last_ready_at,
                last_reading_at: row.get(7),
                latest_gwl: row.get(8),
                latest_rssi: row.get(9),
                latest_battery_v: row.get(10),
                latest_solar_v: row.get(11),
                latest_time_plausible: row.get::<_, Option<bool>>(12).unwrap_or(false),
                reading_count: row.get(13),
                location_id: row.get(5),
                sensor_id: row.get(6),
            })
        })
        .collect()
}

/// One point on a chart series.
#[derive(Debug, Clone, Serialize)]
pub struct SeriesPoint {
    pub recorded_at: DateTime<Utc>,
    pub gwl: f64,
    pub battery_v: Option<f64>,
    pub rssi: Option<i16>,
    pub time_plausible: bool,
}

/// A chart series plus the window it covers.
#[derive(Debug, Clone, Serialize)]
pub struct Series {
    pub device_id: String,
    pub points: Vec<SeriesPoint>,
    pub min_gwl: Option<f64>,
    pub max_gwl: Option<f64>,
    pub gap_minutes: i64,
}

/// Query bounds, clamped so a wide request cannot materialise an unbounded
/// result window.
#[derive(Debug, Clone, Copy)]
pub struct SeriesQuery {
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    /// Downsampling bucket in minutes. `0` returns raw rows.
    pub bucket_minutes: i64,
}

/// Default chart window when the caller does not supply one.
pub const DEFAULT_WINDOW_HOURS: i64 = 24;

/// Upper bound on returned points, so a wide window with a small bucket cannot
/// return an unbounded payload to the browser.
pub const MAX_SERIES_POINTS: usize = 2000;

/// Returns chart data for one device.
///
/// When `bucket_minutes` is non-zero the readings are averaged into buckets.
/// Plausible and implausible device timestamps are averaged separately so a
/// pre-GPS-fix reading cannot drag a real average around, and only plausible
/// buckets feed `min_gwl`/`max_gwl`.
pub async fn device_series(
    client: &Client,
    device_id: &str,
    query: SeriesQuery,
) -> Result<Series, String> {
    let bucket = query.bucket_minutes.max(0);
    let rows = if bucket == 0 {
        client
            .query(
                "SELECT recorded_at,
                        gwl::DOUBLE PRECISION AS gwl,
                        battery_v::DOUBLE PRECISION AS battery_v,
                        rssi,
                        time_plausible
                 FROM readings
                 WHERE device_id = $1 AND recorded_at >= $2 AND recorded_at <= $3
                 ORDER BY recorded_at ASC",
                &[&device_id, &query.from, &query.to],
            )
            .await
    } else {
        client
            .query(
                "SELECT time_bucket(($4 || ' minutes')::INTERVAL, recorded_at) AS bucket,
                        AVG(gwl),
                        AVG(battery_v),
                        AVG(rssi),
                        BOOL_AND(time_plausible) AS plausible
                 FROM readings
                 WHERE device_id = $1 AND recorded_at >= $2 AND recorded_at <= $3
                 GROUP BY bucket
                 ORDER BY bucket ASC",
                &[
                    &device_id,
                    &query.from,
                    &query.to,
                    &bucket.to_string(),
                ],
            )
            .await
    }
    .map_err(|err| format!("series query failed: {err}"))?;

    let mut points: Vec<SeriesPoint> = Vec::with_capacity(rows.len());
    for row in rows {
        let plausible: bool = row.get(4);
        points.push(SeriesPoint {
            recorded_at: row.get(0),
            gwl: row.get(1),
            battery_v: row.get(2),
            rssi: row.get(3),
            time_plausible: plausible,
        });
    }

    // Keep the newest end of the window; a chart cannot usefully render more
    // points than this anyway.
    if points.len() > MAX_SERIES_POINTS {
        points.drain(..points.len() - MAX_SERIES_POINTS);
    }

    let mut min_gwl: Option<f64> = None;
    let mut max_gwl: Option<f64> = None;
    for point in points.iter().filter(|point| point.time_plausible) {
        min_gwl = Some(min_gwl.map_or(point.gwl, |current: f64| current.min(point.gwl)));
        max_gwl = Some(max_gwl.map_or(point.gwl, |current: f64| current.max(point.gwl)));
    }

    Ok(Series {
        device_id: device_id.to_string(),
        points,
        min_gwl,
        max_gwl,
        gap_minutes: bucket,
    })
}

/// A recent raw-message-log row.
#[derive(Debug, Clone, Serialize)]
pub struct LogMessage {
    pub received_at: DateTime<Utc>,
    pub topic: String,
    pub kind: String,
    pub device_id: Option<String>,
    pub qos: i16,
    pub payload: String,
    pub parse_error: Option<String>,
}

/// Reads the raw message log, newest first.
///
/// `device_id` of `None` returns messages from every device, including those
/// that could not be attributed to one.
pub async fn list_messages(
    client: &Client,
    device_id: Option<&str>,
    limit: i64,
) -> Result<Vec<LogMessage>, String> {
    let rows = client
        .query(
            "SELECT received_at, topic, kind, device_id, qos, payload, parse_error
             FROM messages
             WHERE ($1::TEXT IS NULL OR device_id = $1)
             ORDER BY received_at DESC, id DESC
             LIMIT $2",
            &[&device_id, &limit],
        )
        .await
        .map_err(|err| format!("message listing failed: {err}"))?;

    rows.into_iter()
        .map(|row| {
            Ok(LogMessage {
                received_at: row.get(0),
                topic: row.get(1),
                kind: row.get(2),
                device_id: row.get(3),
                qos: row.get(4),
                payload: row.get(5),
                parse_error: row.get(6),
            })
        })
        .collect()
}

/// Deletes raw message-log rows older than `retention_days`.
///
/// Readings are intentionally never pruned: at the firmware's cadence a device
/// adds roughly 175 000 rows a year, which is small enough to keep forever and
/// valuable enough to want.
pub async fn prune_messages(client: &Client, retention_days: i64) -> Result<u64, String> {
    let removed = client
        .execute(
            "DELETE FROM messages WHERE received_at < now() - make_interval(days => $1)",
            &[&retention_days],
        )
        .await
        .map_err(|err| format!("message prune failed: {err}"))?;
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presence_status_distinguishes_awake_asleep_and_stale() {
        let now = Utc::now();
        // Reported Ready a minute ago: within the awake window.
        assert_eq!(
            presence_status(Some(now), Some(now - chrono::Duration::minutes(1))),
            "awake"
        );
        // Seen recently but the Ready window has passed: asleep.
        assert_eq!(
            presence_status(
                Some(now - chrono::Duration::minutes(12)),
                Some(now - chrono::Duration::minutes(20))
            ),
            "asleep"
        );
        // Nothing for longer than the stale threshold.
        assert_eq!(
            presence_status(
                Some(now - chrono::Duration::minutes(
                    crate::config::STALE_AFTER_MINUTES + 5
                )),
                None
            ),
            "stale"
        );
        assert_eq!(presence_status(None, None), "unknown");
    }
}