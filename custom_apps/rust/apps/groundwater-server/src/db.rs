//! PostgreSQL storage.
//!
//! Plain PostgreSQL: no TimescaleDB, no extension, no migration of any
//! existing database (`GWAPP-20261023-slice1` §1, §3). The schema separates
//! four things that earlier drafts collapsed into one "readings" table:
//!
//! - **deliveries** — every message that arrived, attributed or not, with its
//!   digest, provenance and quarantine reason. This is an accounting record,
//!   never a water measurement.
//! - **devices** — the enrollment: which profile is permitted, what is known
//!   about the clock, whether it is revoked.
//! - **device_bindings** — the trusted ingress binding that says which exact
//!   topic carries which device. Unique per live topic, because two claims on
//!   one topic are ambiguous, not a tie to break.
//! - **observations** — water measurements produced by
//!   [`crate::adapter`], with the interpretation version, quality reasons and
//!   duplicate/conflict decision preserved.
//!
//! Two timestamps are stored on every observation on purpose. `recorded_at` is
//! the device's own clock normalised to UTC (absent when the clock is
//! uninterpretable), and is what charts use; `received_at` is this host's
//! clock and is always present. Backlog replay makes the two diverge by days,
//! and the divergence is evidence, not noise.
//!
//! Pruning removes raw *deliveries* only. Observations are never pruned (a
//! device adds roughly 175 000 rows a year), so `observations.delivery_id` is
//! nullable and cleared rather than cascading a delete into the measurements.

use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio_postgres::{Client, NoTls, Row};

use crate::adapter::{
    canonical_device_id, Binding, DuplicateDecision, Enrollment, EnrollmentRegistry, Intake,
    IntakeOutcome, Observation, PriorObservation,
};
use crate::clock::{ClockPolicy, TimeQuality};
use crate::config::STALE_AFTER_MINUTES;
use crate::profiles::ProfileId;

/// Formats a database error with its SQLSTATE and detail.
///
/// `tokio_postgres::Error` prints only "db error" for a server-side rejection;
/// without the detail, a failed statement is undiagnosable from a log line and
/// from the status endpoint.
fn describe(err: &tokio_postgres::Error) -> String {
    let Some(db) = err.as_db_error() else {
        return err.to_string();
    };
    let mut text = format!("{} [{}]", db.message(), db.code().code());
    if let Some(detail) = db.detail() {
        text.push_str(&format!(": {detail}"));
    }
    if let Some(hint) = db.hint() {
        text.push_str(&format!(" (hint: {hint})"));
    }
    text
}

fn db_context(label: &str, err: tokio_postgres::Error) -> String {
    format!("{label}: {}", describe(&err))
}

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
    let (client, connection) = config
        .connect(NoTls)
        .await
        .map_err(|err| format!("failed to connect to the groundwater database: {err}"))?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("groundwater database connection error: {err}");
        }
    });
    Ok(client)
}

/// Creates the schema if absent.
///
/// Idempotent and additive: an existing database from an earlier scaffold is
/// left untouched rather than migrated (the slice has no deployed data), and
/// re-running adds only what is missing.
pub async fn migrate(client: &Client) -> Result<(), String> {
    client
        .batch_execute(
            "
            CREATE TABLE IF NOT EXISTS devices (
                device_id          TEXT PRIMARY KEY,
                display_name       TEXT NOT NULL DEFAULT '',
                source_profile     TEXT NOT NULL,
                clock_policy       TEXT NOT NULL,
                local_offset_min   INTEGER,
                enrolled_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
                revoked_at         TIMESTAMPTZ
            );

            CREATE TABLE IF NOT EXISTS device_bindings (
                binding_key        TEXT PRIMARY KEY,
                device_id          TEXT NOT NULL REFERENCES devices (device_id),
                topic              TEXT NOT NULL,
                source_profile     TEXT NOT NULL,
                established_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
                revoked_at         TIMESTAMPTZ
            );

            -- One live binding per topic: a second one is ambiguous provenance,
            -- and the intake pipeline refuses to pick.
            CREATE UNIQUE INDEX IF NOT EXISTS device_bindings_live_topic_idx
                ON device_bindings (topic)
                WHERE revoked_at IS NULL;

            CREATE TABLE IF NOT EXISTS deliveries (
                id                 BIGSERIAL PRIMARY KEY,
                received_at        TIMESTAMPTZ NOT NULL,
                topic              TEXT NOT NULL,
                kind               TEXT NOT NULL,
                qos                SMALLINT NOT NULL,
                payload            TEXT NOT NULL,
                payload_size       INTEGER NOT NULL,
                payload_digest     TEXT NOT NULL,
                payload_json       JSONB,
                source_profile     TEXT,
                binding_key        TEXT,
                device_id          TEXT,
                claimed_device_id  TEXT,
                state              TEXT NOT NULL,
                reason             TEXT,
                detail             TEXT,
                time_quality       TEXT,
                duplicate_outcome  TEXT,
                duplicate_reason   TEXT
            );

            CREATE TABLE IF NOT EXISTS observations (
                id                         BIGSERIAL PRIMARY KEY,
                -- Nullable and SET NULL on prune: raw-log retention must never
                -- delete a measurement.
                delivery_id                BIGINT REFERENCES deliveries (id) ON DELETE SET NULL,
                device_id                  TEXT NOT NULL REFERENCES devices (device_id),
                kind                       TEXT NOT NULL,
                -- Kept on the observation itself so duplicate detection still
                -- works after the raw delivery row is pruned.
                payload_digest             TEXT NOT NULL,
                recorded_at                TIMESTAMPTZ,
                received_at                TIMESTAMPTZ NOT NULL,
                device_time_text           TEXT,
                time_quality               TEXT NOT NULL,
                time_reason                TEXT NOT NULL,
                offset_applied_min         INTEGER,
                zone_source                TEXT NOT NULL,
                lag_seconds                BIGINT,
                interpretation_version     TEXT NOT NULL,
                quality_reasons            TEXT[] NOT NULL DEFAULT '{}',
                gwl                        DOUBLE PRECISION NOT NULL,
                gwl_text                   TEXT NOT NULL,
                rssi                       SMALLINT,
                rssi_text                  TEXT,
                battery_v                  DOUBLE PRECISION,
                battery_text               TEXT,
                battery_truncated          BOOLEAN NOT NULL,
                solar_v                    DOUBLE PRECISION,
                solar_text                 TEXT,
                solar_truncated            BOOLEAN NOT NULL,
                duplicate_outcome          TEXT NOT NULL,
                duplicate_reason           TEXT NOT NULL,
                payload                    JSONB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS observations_device_recorded_idx
                ON observations (device_id, recorded_at DESC NULLS LAST);
            CREATE INDEX IF NOT EXISTS observations_device_received_idx
                ON observations (device_id, received_at DESC);
            -- Duplicate/conflict lookup: same device at the same device time.
            CREATE INDEX IF NOT EXISTS observations_device_time_idx
                ON observations (device_id, recorded_at);
            CREATE INDEX IF NOT EXISTS deliveries_received_idx
                ON deliveries (received_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS deliveries_device_idx
                ON deliveries (device_id, received_at DESC)
                WHERE device_id IS NOT NULL;
            CREATE INDEX IF NOT EXISTS deliveries_state_idx
                ON deliveries (state, received_at DESC);
            ",
        )
        .await
        .map_err(|err| db_context("schema creation failed", err))?;
    Ok(())
}

/// Loads the enrollment and binding registry the intake pipeline trusts.
pub async fn load_registry(client: &Client) -> Result<EnrollmentRegistry, String> {
    let mut registry = EnrollmentRegistry::new();

    let device_rows = client
        .query(
            "SELECT device_id, display_name, source_profile, clock_policy, local_offset_min, revoked_at IS NOT NULL
             FROM devices
             ORDER BY device_id",
            &[],
        )
        .await
        .map_err(|err| db_context("enrollment load failed", err))?;

    for row in device_rows {
        let device_id: String = row.get(0);
        let display_name: String = row.get(1);
        let profile_text: String = row.get(2);
        let Some(profile) = ProfileId::parse(&profile_text) else {
            // An unknown profile is a configuration error. Skipping the device
            // means its traffic is quarantined as unenrolled, which fails
            // closed and is visible in the log.
            eprintln!(
                "groundwater: enrollment {device_id} has unknown profile {profile_text:?}; skipping"
            );
            continue;
        };
        let policy_text: String = row.get(3);
        let offset: Option<i32> = row.get(4);
        let revoked: bool = row.get(5);
        let clock = match policy_text.as_str() {
            "utc" => ClockPolicy::Utc,
            "local-offset" => match offset {
                Some(offset_minutes) => ClockPolicy::LocalOffset { offset_minutes },
                None => ClockPolicy::Unknown,
            },
            _ => ClockPolicy::Unknown,
        };
        registry.enroll(Enrollment {
            device_id,
            display_name,
            profile,
            clock,
            revoked,
        });
    }

    let binding_rows = client
        .query(
            "SELECT binding_key, topic, device_id, source_profile
             FROM device_bindings
             WHERE revoked_at IS NULL
             ORDER BY binding_key",
            &[],
        )
        .await
        .map_err(|err| db_context("binding load failed", err))?;

    for row in binding_rows {
        let key: String = row.get(0);
        let topic: String = row.get(1);
        let device_id: String = row.get(2);
        let profile_text: String = row.get(3);
        let Some(profile) = ProfileId::parse(&profile_text) else {
            eprintln!("groundwater: binding {key} has unknown profile {profile_text:?}; skipping");
            continue;
        };
        registry.bind(Binding {
            key,
            topic,
            device_id,
            profile,
        });
    }

    Ok(registry)
}

/// Stores a delivery (and its observation, when one was produced).
///
/// Returns the delivery id. The two inserts are intentionally not wrapped in a
/// transaction: a failed observation insert leaves the delivery visible, which
/// is the failure direction that preserves evidence rather than hiding it.
pub async fn record_intake(client: &Client, intake: &Intake) -> Result<i64, String> {
    let record = &intake.record;
    let kind = record.kind.as_str();
    let profile = record.profile.map(ProfileId::as_str);
    let state = record.state.as_str();
    let reason = record.quarantine_reason.map(|reason| reason.code());
    let time_quality = record.time_quality.map(TimeQuality::as_str);
    let (duplicate_outcome, duplicate_reason) = match &record.duplicate {
        Some(decision) => (
            Some(decision.outcome.as_str()),
            Some(decision.reason.as_str()),
        ),
        None => (None, None),
    };

    let row = client
        .query_one(
            "INSERT INTO deliveries
                (received_at, topic, kind, qos, payload, payload_size, payload_digest,
                 payload_json, source_profile, binding_key, device_id, claimed_device_id,
                 state, reason, detail, time_quality, duplicate_outcome, duplicate_reason)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
             RETURNING id",
            &[
                &record.received_at,
                &record.topic,
                &kind,
                &record.qos,
                &record.payload_text,
                &(record.payload_size as i32),
                &record.payload_digest,
                &record.payload_json,
                &profile,
                &record.binding_key,
                &record.device_id,
                &record.claimed_device_id,
                &state,
                &reason,
                &record.quarantine_detail,
                &time_quality,
                &duplicate_outcome,
                &duplicate_reason,
            ],
        )
        .await
        .map_err(|err| db_context("delivery insert failed", err))?;
    let delivery_id: i64 = row.get(0);

    if let IntakeOutcome::Accepted {
        observation: Some(observation),
        duplicate,
    } = &intake.outcome
    {
        insert_observation(client, delivery_id, observation, duplicate).await?;
    }

    Ok(delivery_id)
}

/// Stores one observation, keeping the interpretation and duplicate decision.
async fn insert_observation(
    client: &Client,
    delivery_id: i64,
    observation: &Observation,
    duplicate: &DuplicateDecision,
) -> Result<(), String> {
    let time_quality = observation.time_quality.as_str();
    let zone_source = observation.zone_source.as_str();
    let duplicate_outcome = duplicate.outcome.as_str();
    client
        .execute(
            "INSERT INTO observations
                (delivery_id, device_id, kind, payload_digest, recorded_at, received_at,
                 device_time_text, time_quality, time_reason, offset_applied_min, zone_source,
                 lag_seconds, interpretation_version, quality_reasons, gwl, gwl_text, rssi,
                 rssi_text, battery_v, battery_text, battery_truncated, solar_v, solar_text,
                 solar_truncated, duplicate_outcome, duplicate_reason, payload)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16,
                     $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27)",
            &[
                &delivery_id,
                &observation.device_id,
                &observation.kind,
                &observation.payload_digest,
                &observation.recorded_at,
                &observation.received_at,
                &observation.device_time_text,
                &time_quality,
                &observation.time_reason,
                &observation.offset_applied_minutes,
                &zone_source,
                &observation.lag_seconds,
                &observation.interpretation_version,
                &observation.quality_reasons,
                &observation.gwl,
                &observation.gwl_text,
                &observation.rssi,
                &observation.rssi_text,
                &observation.battery_v,
                &observation.battery_text,
                &observation.battery_truncated,
                &observation.solar_v,
                &observation.solar_text,
                &observation.solar_truncated,
                &duplicate_outcome,
                &duplicate.reason,
                &observation.payload,
            ],
        )
        .await
        .map_err(|err| db_context("observation insert failed", err))?;
    Ok(())
}

/// Prior observations for one device at one derived device time.
///
/// Over-fetches a day so the adapter can apply its own bounded window and
/// explain an out-of-window match instead of silently ignoring it.
pub async fn prior_observations(
    client: &Client,
    device_id: &str,
    recorded_at: Option<DateTime<Utc>>,
    received_at: DateTime<Utc>,
) -> Result<Vec<PriorObservation>, String> {
    let Some(recorded_at) = recorded_at else {
        return Ok(Vec::new());
    };
    let rows = client
        .query(
            "SELECT device_id, recorded_at, received_at, payload_digest, gwl
             FROM observations
             WHERE device_id = $1 AND recorded_at = $2
               AND received_at >= $3::TIMESTAMPTZ - INTERVAL '1 day'",
            &[&canonical_device_id(device_id), &recorded_at, &received_at],
        )
        .await
        .map_err(|err| db_context("duplicate lookup failed", err))?;
    Ok(rows
        .into_iter()
        .map(|row| PriorObservation {
            device_id: row.get(0),
            recorded_at: Some(recorded_at),
            received_at: row.get(2),
            payload_digest: row.get(3),
            gwl: row.get(4),
        })
        .collect())
}

/// A measurement as presented to the API and the inspection page.
#[derive(Debug, Clone, Serialize)]
pub struct ObservationSummary {
    pub recorded_at: Option<DateTime<Utc>>,
    pub received_at: DateTime<Utc>,
    pub gwl: f64,
    pub gwl_text: String,
    pub rssi: Option<i16>,
    pub battery_v: Option<f64>,
    pub solar_v: Option<f64>,
    pub time_quality: String,
    pub time_reason: String,
    pub quality_reasons: Vec<String>,
    pub duplicate_outcome: String,
    pub interpretation_version: String,
}

/// Column list shared by the latest-observation queries.
const OBSERVATION_COLUMNS: &str = "recorded_at, received_at, gwl, gwl_text, rssi, battery_v, \
     solar_v, time_quality, time_reason, quality_reasons, duplicate_outcome, \
     interpretation_version";

fn observation_summary(row: &Row) -> ObservationSummary {
    ObservationSummary {
        recorded_at: row.get(0),
        received_at: row.get(1),
        gwl: row.get(2),
        gwl_text: row.get(3),
        rssi: row.get(4),
        battery_v: row.get(5),
        solar_v: row.get(6),
        time_quality: row.get(7),
        time_reason: row.get(8),
        quality_reasons: row.get(9),
        duplicate_outcome: row.get(10),
        interpretation_version: row.get(11),
    }
}

/// A device row as presented to the UI.
#[derive(Debug, Clone, Serialize)]
pub struct DeviceSummary {
    pub device_id: String,
    pub display_name: String,
    pub profile: String,
    pub clock_policy: String,
    pub revoked: bool,
    /// Derived availability. Slice 1 has no attributed device-status traffic,
    /// so this is "are readings arriving", not "is the device awake".
    pub status: String,
    pub status_reason: String,
    pub last_received_at: Option<DateTime<Utc>>,
    pub observation_count: i64,
    pub conflict_count: i64,
    pub quarantined_deliveries: i64,
    /// Most recently *received* observation, whatever its event time.
    pub latest_received: Option<ObservationSummary>,
    /// Most recent observation whose event time is plausible.
    pub latest_plausible: Option<ObservationSummary>,
}

impl DeviceSummary {
    /// The observation a dashboard should headline: plausible event time when
    /// one exists, otherwise the latest receipt with its caveats attached.
    pub fn headline(&self) -> Option<&ObservationSummary> {
        self.latest_plausible
            .as_ref()
            .or(self.latest_received.as_ref())
    }
}

/// Lists every enrolled device with counts and both "latest" views.
pub async fn list_devices(client: &Client) -> Result<Vec<DeviceSummary>, String> {
    let rows = client
        .query(
            "SELECT device_id, display_name, source_profile, clock_policy, revoked_at IS NOT NULL
             FROM devices
             ORDER BY device_id",
            &[],
        )
        .await
        .map_err(|err| db_context("device listing failed", err))?;

    let mut devices = Vec::with_capacity(rows.len());
    for row in rows {
        let device_id: String = row.get(0);
        let display_name: String = row.get(1);
        let profile: String = row.get(2);
        let clock_policy: String = row.get(3);
        let revoked: bool = row.get(4);

        let counts = client
            .query_one(
                "SELECT
                    (SELECT count(*) FROM observations WHERE device_id = $1),
                    (SELECT count(*) FROM observations WHERE device_id = $1 AND duplicate_outcome = 'conflict'),
                    (SELECT count(*) FROM deliveries WHERE device_id = $1 AND state = 'quarantined'),
                    (SELECT max(received_at) FROM observations WHERE device_id = $1)",
                &[&device_id],
            )
            .await
            .map_err(|err| db_context("device counters failed", err))?;

        let latest_received = latest_observation(client, &device_id, Latest::Received).await?;
        let latest_plausible =
            latest_observation(client, &device_id, Latest::PlausibleEvent).await?;
        let last_received_at: Option<DateTime<Utc>> = counts.get(3);

        let (status, status_reason) = availability(last_received_at, revoked);
        devices.push(DeviceSummary {
            device_id,
            display_name,
            profile,
            clock_policy,
            revoked,
            status,
            status_reason,
            last_received_at,
            observation_count: counts.get(0),
            conflict_count: counts.get(1),
            quarantined_deliveries: counts.get(2),
            latest_received,
            latest_plausible,
        });
    }
    Ok(devices)
}

/// Which "latest" view to read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Latest {
    /// Newest receipt, regardless of event time.
    Received,
    /// Newest plausible event time.
    PlausibleEvent,
}

async fn latest_observation(
    client: &Client,
    device_id: &str,
    which: Latest,
) -> Result<Option<ObservationSummary>, String> {
    let (filter, order) = match which {
        Latest::Received => ("TRUE", "received_at DESC, id DESC"),
        Latest::PlausibleEvent => ("time_quality = 'plausible'", "recorded_at DESC, id DESC"),
    };
    let sql = format!(
        "SELECT {OBSERVATION_COLUMNS} FROM observations
         WHERE device_id = $1 AND {filter}
         ORDER BY {order}
         LIMIT 1"
    );
    let rows = client
        .query(&sql, &[&device_id])
        .await
        .map_err(|err| db_context("latest observation query failed", err))?;
    Ok(rows.first().map(observation_summary))
}

/// Availability derived from reading arrivals.
///
/// Slice 1 does not attribute `device-status`, so the platform cannot honestly
/// claim "awake"/"asleep"; it can only say whether measurements are arriving.
fn availability(last_received_at: Option<DateTime<Utc>>, revoked: bool) -> (String, String) {
    if revoked {
        return (
            "revoked".to_string(),
            "enrollment revoked; new traffic is quarantined".to_string(),
        );
    }
    let Some(last) = last_received_at else {
        return (
            "never".to_string(),
            "no accepted observation yet".to_string(),
        );
    };
    let silent = (Utc::now() - last).num_minutes();
    if silent > STALE_AFTER_MINUTES {
        (
            "stale".to_string(),
            format!(
                "no accepted reading for {silent} min (threshold {STALE_AFTER_MINUTES} min); wake state needs device-status, which is not attributed in this slice"
            ),
        )
    } else {
        (
            "receiving".to_string(),
            "readings arriving; wake state needs device-status, which is not attributed in this slice"
                .to_string(),
        )
    }
}

/// A recent delivery (raw log) row.
#[derive(Debug, Clone, Serialize)]
pub struct DeliveryRow {
    pub received_at: DateTime<Utc>,
    pub topic: String,
    pub kind: String,
    pub device_id: Option<String>,
    pub claimed_device_id: Option<String>,
    pub qos: i16,
    pub payload: String,
    pub state: String,
    pub reason: Option<String>,
    pub detail: Option<String>,
    pub time_quality: Option<String>,
    pub duplicate_outcome: Option<String>,
    pub source_profile: Option<String>,
    pub binding_key: Option<String>,
}

/// Reads the delivery log, newest first.
///
/// `device_id` of `None` returns every delivery, including the quarantined
/// ones that have no device — those are the ones an operator needs to see.
pub async fn list_deliveries(
    client: &Client,
    device_id: Option<&str>,
    limit: i64,
) -> Result<Vec<DeliveryRow>, String> {
    let rows = client
        .query(
            "SELECT received_at, topic, kind, device_id, claimed_device_id, qos, payload,
                    state, reason, detail, time_quality, duplicate_outcome,
                    source_profile, binding_key
             FROM deliveries
             WHERE ($1::TEXT IS NULL OR device_id = $1)
             ORDER BY received_at DESC, id DESC
             LIMIT $2",
            &[&device_id, &limit],
        )
        .await
        .map_err(|err| db_context("delivery listing failed", err))?;

    Ok(rows
        .into_iter()
        .map(|row| DeliveryRow {
            received_at: row.get(0),
            topic: row.get(1),
            kind: row.get(2),
            device_id: row.get(3),
            claimed_device_id: row.get(4),
            qos: row.get(5),
            payload: row.get(6),
            state: row.get(7),
            reason: row.get(8),
            detail: row.get(9),
            time_quality: row.get(10),
            duplicate_outcome: row.get(11),
            source_profile: row.get(12),
            binding_key: row.get(13),
        })
        .collect())
}

/// One point on a chart series.
#[derive(Debug, Clone, Serialize)]
pub struct SeriesPoint {
    pub recorded_at: DateTime<Utc>,
    pub gwl: f64,
    /// Firmware text for a raw point; absent on an averaged bucket.
    pub gwl_text: Option<String>,
    pub battery_v: Option<f64>,
    pub rssi: Option<i16>,
    pub sample_count: i64,
    /// True when any sample in the bucket was a same-time conflict.
    pub conflict: bool,
}

/// A chart series plus the window it covers.
#[derive(Debug, Clone, Serialize)]
pub struct Series {
    pub device_id: String,
    pub points: Vec<SeriesPoint>,
    pub min_gwl: Option<f64>,
    pub max_gwl: Option<f64>,
    /// Bucket width in minutes; `0` for raw points.
    pub bucket_minutes: i64,
    /// True when the cap truncated the oldest points.
    pub truncated: bool,
}

/// Query bounds, clamped by the API before they reach here.
#[derive(Debug, Clone, Copy)]
pub struct SeriesQuery {
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    /// Downsampling bucket in minutes. `0` returns raw rows.
    pub bucket_minutes: i64,
}

/// Default chart window when the caller does not supply one.
pub const DEFAULT_WINDOW_HOURS: i64 = 24;

/// Upper bound on returned points, so a wide window with a fine bucket cannot
/// return an unbounded payload to the browser.
pub const MAX_SERIES_POINTS: usize = 2000;

/// Returns chart data for one device.
///
/// On plain PostgreSQL the bucket is `to_timestamp(floor(epoch / width) *
/// width)`: no `time_bucket`, no extension. Averaged buckets keep the sample
/// count and a conflict flag, so downsampling cannot hide a same-time
/// value disagreement.
pub async fn device_series(
    client: &Client,
    device_id: &str,
    query: SeriesQuery,
) -> Result<Series, String> {
    let device_id = canonical_device_id(device_id);
    let bucket_minutes = query.bucket_minutes.max(0);
    let limit = (MAX_SERIES_POINTS + 1) as i64;

    let rows = if bucket_minutes == 0 {
        client
            .query(
                "SELECT recorded_at, gwl, gwl_text, battery_v, rssi, 1::BIGINT AS sample_count,
                        duplicate_outcome = 'conflict' AS conflict
                 FROM observations
                 WHERE device_id = $1 AND kind = 'water' AND recorded_at IS NOT NULL
                   AND recorded_at >= $2 AND recorded_at <= $3
                 ORDER BY recorded_at DESC
                 LIMIT $4",
                &[&device_id, &query.from, &query.to, &limit],
            )
            .await
    } else {
        let width_seconds = (bucket_minutes * 60) as f64;
        client
            .query(
                "SELECT to_timestamp(floor(extract(epoch FROM recorded_at) / $4::DOUBLE PRECISION)
                                    * $4::DOUBLE PRECISION) AS bucket,
                        AVG(gwl) AS gwl,
                        NULL::TEXT AS gwl_text,
                        AVG(battery_v) AS battery_v,
                        AVG(rssi)::SMALLINT AS rssi,
                        count(*)::BIGINT AS sample_count,
                        bool_or(duplicate_outcome = 'conflict') AS conflict
                 FROM observations
                 WHERE device_id = $1 AND kind = 'water' AND recorded_at IS NOT NULL
                   AND recorded_at >= $2 AND recorded_at <= $3
                 GROUP BY bucket
                 ORDER BY bucket DESC
                 LIMIT $5",
                &[&device_id, &query.from, &query.to, &width_seconds, &limit],
            )
            .await
    }
    .map_err(|err| db_context("series query failed", err))?;

    let mut truncated = rows.len() > MAX_SERIES_POINTS;
    let mut points: Vec<SeriesPoint> = Vec::with_capacity(rows.len().min(MAX_SERIES_POINTS));
    for row in rows {
        points.push(SeriesPoint {
            recorded_at: row.get(0),
            gwl: row.get(1),
            gwl_text: row.get(2),
            battery_v: row.get(3),
            rssi: row.get(4),
            sample_count: row.get(5),
            conflict: row.get(6),
        });
    }
    // The query returned newest-first so the cap keeps the newest end.
    if points.len() > MAX_SERIES_POINTS {
        points.truncate(MAX_SERIES_POINTS);
        truncated = true;
    }
    points.reverse();

    let mut min_gwl: Option<f64> = None;
    let mut max_gwl: Option<f64> = None;
    for point in &points {
        min_gwl = Some(min_gwl.map_or(point.gwl, |current: f64| current.min(point.gwl)));
        max_gwl = Some(max_gwl.map_or(point.gwl, |current: f64| current.max(point.gwl)));
    }

    Ok(Series {
        device_id,
        points,
        min_gwl,
        max_gwl,
        bucket_minutes,
        truncated,
    })
}

/// Deletes raw delivery rows older than `retention_days`.
///
/// Observations are never pruned: their `delivery_id` is cleared by the
/// foreign key's `ON DELETE SET NULL`, so the measurement survives the log.
pub async fn prune_deliveries(client: &Client, retention_days: i64) -> Result<u64, String> {
    let removed = client
        .execute(
            "DELETE FROM deliveries WHERE received_at < now() - ($1::BIGINT * INTERVAL '1 day')",
            &[&retention_days],
        )
        .await
        .map_err(|err| db_context("delivery prune failed", err))?;
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn availability_never_claims_wake_state() {
        let now = Utc::now();
        let (status, reason) = availability(Some(now), false);
        assert_eq!(status, "receiving");
        assert!(reason.contains("wake state needs device-status"));

        let (status, _) = availability(
            Some(now - chrono::Duration::minutes(STALE_AFTER_MINUTES + 1)),
            false,
        );
        assert_eq!(status, "stale");

        let (status, reason) = availability(None, false);
        assert_eq!(status, "never");
        assert!(reason.contains("no accepted observation"));

        let (status, _) = availability(Some(now), true);
        assert_eq!(status, "revoked");
    }

    /// Round-trips the schema against a real PostgreSQL.
    ///
    /// Ignored by default because the lean gate has no database; run with
    /// `GROUNDWATER_TEST_DATABASE_URL=postgres://... cargo test -p
    /// groundwater-server -- --ignored`. The synthetic slice's SQL is otherwise
    /// only type-checked, and this is the one place it executes.
    #[tokio::test]
    #[ignore = "requires GROUNDWATER_TEST_DATABASE_URL"]
    async fn schema_and_round_trip_against_postgres() {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL")
            .expect("GROUNDWATER_TEST_DATABASE_URL must be set for this test");
        let client = connect(&url).await.expect("connect");
        migrate(&client).await.expect("migrate");
        // This test owns a throwaway database; reset it so a rerun starts clean.
        client
            .batch_execute(
                "TRUNCATE observations, deliveries, device_bindings, devices RESTART IDENTITY CASCADE",
            )
            .await
            .expect("reset");

        let device = format!("{:024X}", 0xABCDEF);
        let name: &str = "Round trip bore";
        let profile: &str = "V21";
        let policy: &str = "local-offset";
        let offset: i32 = 300;
        client
            .execute(
                "INSERT INTO devices (device_id, display_name, source_profile, clock_policy, local_offset_min)
                 VALUES ($1, $2, $3, $4, $5)",
                &[&device, &name, &profile, &policy, &offset],
            )
            .await
            .expect("seed device");
        let binding_key: &str = "rt-binding";
        let topic: &str = "gwl/rt/gwl-string";
        client
            .execute(
                "INSERT INTO device_bindings (binding_key, device_id, topic, source_profile)
                 VALUES ($1, $2, $3, $4)",
                &[&binding_key, &device, &topic, &profile],
            )
            .await
            .expect("seed binding");

        let registry = load_registry(&client).await.expect("load registry");
        assert!(registry.enrollment(&device).is_some());
        assert!(registry.binding_for_topic("gwl/rt/gwl-string").is_some());

        let payload = crate::fixtures::v21_payload_for(&device);
        let delivery = crate::adapter::Delivery {
            topic: "gwl/rt/gwl-string",
            payload: payload.as_bytes(),
            qos: 1,
            received_at: Utc::now(),
        };
        let intake = crate::adapter::intake(
            &delivery,
            &registry,
            &crate::topics::TopicMap::firmware_defaults(),
        );
        assert!(matches!(
            intake.outcome,
            IntakeOutcome::Accepted {
                observation: Some(_),
                ..
            }
        ));
        record_intake(&client, &intake).await.expect("record");

        let (recorded_at, payload_digest) = match &intake.outcome {
            IntakeOutcome::Accepted {
                observation: Some(observation),
                ..
            } => (
                observation
                    .recorded_at
                    .expect("fixture carries device time"),
                observation.payload_digest.clone(),
            ),
            _ => panic!("expected an accepted observation"),
        };

        let prior = prior_observations(&client, &device, Some(recorded_at), Utc::now())
            .await
            .expect("prior");
        assert_eq!(prior.len(), 1);
        assert_eq!(prior[0].payload_digest, payload_digest);
        assert_eq!(
            prior[0].device_id, device,
            "prior observation must be keyed by the canonical device id"
        );

        let devices = list_devices(&client).await.expect("list devices");
        let summary = devices
            .iter()
            .find(|summary| summary.device_id == device)
            .expect("device listed");
        assert_eq!(summary.observation_count, 1);
        assert!(summary.latest_received.is_some());
        assert!(summary.headline().is_some());
        assert_eq!(
            summary.latest_received.as_ref().expect("latest").gwl_text,
            "01.25"
        );

        let series = device_series(
            &client,
            &device,
            SeriesQuery {
                from: recorded_at - chrono::Duration::days(1),
                to: recorded_at + chrono::Duration::days(1),
                bucket_minutes: 0,
            },
        )
        .await
        .expect("series");
        assert_eq!(series.points.len(), 1);
        assert_eq!(series.points[0].recorded_at, recorded_at);
        assert_eq!(series.points[0].gwl_text.as_deref(), Some("01.25"));

        let bucketed = device_series(
            &client,
            &device,
            SeriesQuery {
                from: recorded_at - chrono::Duration::days(1),
                to: recorded_at + chrono::Duration::days(1),
                bucket_minutes: 60,
            },
        )
        .await
        .expect("bucketed series");
        assert_eq!(bucketed.points.len(), 1);
        assert_eq!(bucketed.points[0].sample_count, 1);
        assert!(!bucketed.points[0].conflict);

        let deliveries = list_deliveries(&client, Some(&device), 10)
            .await
            .expect("deliveries");
        assert_eq!(deliveries.len(), 1);
        assert_eq!(deliveries[0].state, "accepted");
        assert_eq!(deliveries[0].duplicate_outcome.as_deref(), Some("new"));

        // Pruning the raw log must not delete the measurement.
        prune_deliveries(&client, -1).await.expect("prune");
        let rows = client
            .query(
                "SELECT count(*), count(delivery_id) FROM observations WHERE device_id = $1",
                &[&device],
            )
            .await
            .expect("count");
        let total: i64 = rows[0].get(0);
        let with_delivery: i64 = rows[0].get(1);
        assert_eq!(total, 1);
        assert_eq!(with_delivery, 0);
    }
}
