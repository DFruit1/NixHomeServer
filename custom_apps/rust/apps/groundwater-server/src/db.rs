//! PostgreSQL storage.
//!
//! Plain PostgreSQL with idempotent additive migrations. The schema separates
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

use std::{sync::Arc, time::Duration};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio_postgres::{Client, GenericClient, NoTls};

use crate::adapter::{
    canonical_device_id, Binding, DuplicateDecision, Enrollment, EnrollmentRegistry, Intake,
    IntakeOutcome, Observation, PriorObservation,
};
use crate::clock::{ClockPolicy, TimeQuality};
use crate::config::STALE_AFTER_MINUTES;
use crate::profiles::ProfileId;

/// Reconnect on the next operation without replaying an uncertain write.
/// Each long-running worker owns its own connection; HTTP readers share this
/// short-query connection rather than sharing alert replays or MQTT writes.
pub struct Database {
    url: String,
    client: tokio::sync::RwLock<Arc<Client>>,
}

impl Database {
    pub fn new(url: String, client: Client) -> Self {
        Self {
            url,
            client: tokio::sync::RwLock::new(Arc::new(client)),
        }
    }

    pub async fn get(&self) -> Result<Arc<Client>, String> {
        let client = self.client.read().await;
        if !client.is_closed() {
            return Ok(client.clone());
        }
        drop(client);
        let mut client = self.client.write().await;
        if client.is_closed() {
            *client = Arc::new(connect(&self.url).await?);
        }
        Ok(client.clone())
    }
}

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
    config.connect_timeout(Duration::from_secs(5));
    let options = format!(
        "{} -c statement_timeout=30000",
        config.get_options().unwrap_or_default()
    );
    config.options(&options);
    let (client, connection) = tokio::time::timeout(Duration::from_secs(5), config.connect(NoTls))
        .await
        .map_err(|_| "groundwater database connection timed out".to_owned())?
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
/// Idempotent and additive: existing enrollments, observations, clock evidence
/// and delivery provenance survive the platform migration.
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
    crate::platform::migrate(client).await?;
    Ok(())
}

/// Loads the enrollment and binding registry the intake pipeline trusts.
pub async fn load_registry(client: &Client) -> Result<EnrollmentRegistry, String> {
    let mut registry = EnrollmentRegistry::new();

    let device_rows = client
        .query(
            "SELECT device_id, display_name, source_profile, clock_policy, local_offset_min, revoked_at IS NOT NULL, clock_change_unverified
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
        let clock = if row.get::<_, bool>(6) {
            ClockPolicy::Unknown
        } else {
            match (policy_text.as_str(), offset) {
                ("local-offset", Some(offset_minutes)) => {
                    ClockPolicy::LocalOffset { offset_minutes }
                }
                _ => ClockPolicy::parse(&policy_text).unwrap_or(ClockPolicy::Unknown),
            }
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

    let count = client
        .query_one("SELECT groundwater_legacy_device_count()", &[])
        .await
        .map_err(|e| db_context("legacy topic cohort", e))?
        .get(0);
    registry.set_shared_legacy_count(count);
    Ok(registry)
}

/// Stores a delivery (and its observation, when one was produced).
///
/// A retry with the same received delivery must survive an uncertain COMMIT
/// without duplicating its observation or ancillary effects.
pub fn intake_key(record: &crate::adapter::DeliveryRecord) -> String {
    use sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    hash.update((record.topic.len() as u64).to_be_bytes());
    hash.update(record.topic.as_bytes());
    hash.update(record.payload_digest.as_bytes());
    hash.update(record.received_at.timestamp().to_be_bytes());
    hash.update(record.received_at.timestamp_subsec_nanos().to_be_bytes());
    format!("{:x}", hash.finalize())
}

pub async fn existing_intake<C: GenericClient + Sync>(
    client: &C,
    key: &str,
) -> Result<Option<i64>, String> {
    client
        .query_opt("SELECT id FROM deliveries WHERE ingest_key=$1", &[&key])
        .await
        .map(|row| row.map(|row| row.get(0)))
        .map_err(|e| db_context("delivery retry lookup failed", e))
}

#[cfg(test)]
pub async fn record_intake(client: &mut Client, intake: &Intake) -> Result<i64, String> {
    let tx = client
        .transaction()
        .await
        .map_err(|e| db_context("begin intake", e))?;
    let id = record_intake_in(&tx, intake).await?;
    tx.commit()
        .await
        .map_err(|e| db_context("commit intake", e))?;
    Ok(id)
}

pub async fn record_intake_in<C: GenericClient + Sync>(
    client: &C,
    intake: &Intake,
) -> Result<i64, String> {
    let record = &intake.record;
    let payload_text = record.payload_text.replace('\0', "\\u0000");
    let key = intake_key(record);
    if let Some(id) = existing_intake(client, &key).await? {
        return Ok(id);
    }
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
                 state, reason, detail, time_quality, duplicate_outcome, duplicate_reason, ingest_key)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)
             RETURNING id",
            &[
                &record.received_at,
                &record.topic,
                &kind,
                &record.qos,
                &payload_text,
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
                &key,
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
async fn insert_observation<C: GenericClient + Sync>(
    client: &C,
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
pub async fn prior_observations<C: GenericClient + Sync>(
    client: &C,
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
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
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

/// A device row as presented to the UI.
#[derive(Debug, Clone, Serialize)]
pub struct DeviceSummary {
    pub device_id: String,
    pub display_name: String,
    pub profile: String,
    pub clock_policy: String,
    pub revoked: bool,
    /// Presence from an explicit status binding; reading-only availability
    /// is retained when no status binding has supplied evidence.
    pub status: String,
    pub status_reason: String,
    pub last_received_at: Option<DateTime<Utc>>,
    pub observation_count: i64,
    pub conflict_count: i64,
    /// Most recently *received* observation, whatever its event time.
    pub latest_received: Option<ObservationSummary>,
    /// Most recent observation whose event time is plausible.
    pub latest_plausible: Option<ObservationSummary>,
    pub min_limit: Option<f64>,
    pub max_limit: Option<f64>,
    pub location_id: Option<String>,
    pub sensor_id: Option<String>,
    pub local_offset_min: Option<i32>,
    pub last_ready_at: Option<DateTime<Utc>>,
    pub desired_config: Option<serde_json::Value>,
    pub applied_config: Option<serde_json::Value>,
    pub project_config: Option<serde_json::Value>,
    pub clock_change_unverified: bool,
    pub capabilities: serde_json::Value,
    pub open_alert_count: i64,
}

impl DeviceSummary {
    /// The observation a dashboard should headline: plausible event time when
    /// one exists, otherwise the latest receipt with its caveats attached.
    #[cfg(test)]
    pub fn headline(&self) -> Option<&ObservationSummary> {
        self.latest_plausible
            .as_ref()
            .or(self.latest_received.as_ref())
    }
}

/// SQL scopes the work before loading measurements. A device page never
/// computes counters or latest rows for another device in the fleet.
#[cfg(test)]
pub async fn list_devices(client: &Client) -> Result<Vec<DeviceSummary>, String> {
    let ids = client
        .query("SELECT device_id FROM devices", &[])
        .await
        .map_err(|e| db_context("device ids", e))?
        .iter()
        .map(|row| row.get(0))
        .collect::<Vec<String>>();
    scoped_devices(client, &ids).await
}

pub async fn scoped_devices(client: &Client, ids: &[String]) -> Result<Vec<DeviceSummary>, String> {
    let columns = "recorded_at,received_at,gwl,gwl_text,rssi,battery_v,solar_v,time_quality,time_reason,quality_reasons,duplicate_outcome,interpretation_version";
    let sql = format!(
        "SELECT d.*,d.revoked_at IS NOT NULL AS revoked,
            (SELECT count(*) FROM alerts a WHERE a.device_id=d.device_id AND a.state='open' AND NOT a.superseded) AS open_alert_count,
            to_jsonb(received) AS latest_received,to_jsonb(plausible) AS latest_plausible
         FROM devices d
         LEFT JOIN LATERAL (SELECT {columns} FROM observations WHERE id=d.latest_received_id) received ON true
         LEFT JOIN LATERAL (SELECT {columns} FROM observations WHERE id=d.latest_plausible_id) plausible ON true
         WHERE d.device_id=ANY($1) ORDER BY d.device_id");
    let rows = client
        .query(&sql, &[&ids])
        .await
        .map_err(|e| db_context("device summaries", e))?;
    let mut devices = Vec::with_capacity(rows.len());
    for row in rows {
        let revoked: bool = row.get("revoked");
        let last_received_at: Option<DateTime<Utc>> = row.get("last_seen");
        let (mut status, mut status_reason) = availability(last_received_at, revoked);
        let presence: Option<String> = row.get("presence_status");
        let ready: Option<DateTime<Utc>> = row.get("last_ready_at");
        if !revoked {
            if crate::platform::awake(Utc::now(), ready, presence.as_deref().unwrap_or("")) {
                status = "awake".into();
                status_reason = "explicitly bound Ready; command window open".into();
            } else if presence.is_some() {
                status = "asleep".into();
                status_reason = "sleep received or Ready window expired".into();
            }
            if last_received_at
                .is_some_and(|t| Utc::now() - t > chrono::Duration::minutes(STALE_AFTER_MINUTES))
            {
                status = "stale".into();
                status_reason = "no attributed traffic within stale threshold".into();
            }
        }
        let summary = |column: &str| -> Result<Option<ObservationSummary>, String> {
            row.get::<_, Option<serde_json::Value>>(column)
                .map(serde_json::from_value)
                .transpose()
                .map_err(|e| format!("observation summary: {e}"))
        };
        devices.push(DeviceSummary {
            device_id: row.get("device_id"),
            display_name: row.get("display_name"),
            profile: row.get("source_profile"),
            clock_policy: row.get("clock_policy"),
            revoked,
            status,
            status_reason,
            last_received_at,
            observation_count: row.get("observation_count"),
            conflict_count: row.get("conflict_count"),
            latest_received: summary("latest_received")?,
            latest_plausible: summary("latest_plausible")?,
            min_limit: row.get("min_limit"),
            max_limit: row.get("max_limit"),
            location_id: row.get("location_id"),
            sensor_id: row.get("sensor_id"),
            local_offset_min: row.get("local_offset_min"),
            last_ready_at: ready,
            desired_config: row.get("desired_config"),
            applied_config: row.get("applied_config"),
            project_config: row.get("project_config"),
            clock_change_unverified: row.get("clock_change_unverified"),
            capabilities: crate::commands::capabilities(
                row.get("source_profile"),
                row.get("clock_policy"),
                row.get("local_offset_min"),
                row.get("clock_change_unverified"),
            ),
            open_alert_count: row.get("open_alert_count"),
        });
    }
    Ok(devices)
}

/// Traffic recency without an explicit Ready/sleep status. The caller overlays
/// the separately attributed wake state when one is available.
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
            "no accepted observation or other attributed traffic yet".to_string(),
        );
    };
    let silent = (Utc::now() - last).num_minutes();
    if silent > STALE_AFTER_MINUTES {
        (
            "stale".to_string(),
            format!("no attributed traffic for {silent} min (threshold {STALE_AFTER_MINUTES} min)"),
        )
    } else {
        (
            "receiving".to_string(),
            "attributed traffic arriving; wake state needs device-status".to_string(),
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
    pub direction: String,
}

/// Reads the delivery log, newest first.
///
/// `device_id` of `None` returns every delivery, including the quarantined
/// ones that have no device — those are the ones an operator needs to see.
#[cfg(test)]
pub async fn list_deliveries(
    client: &Client,
    device_id: Option<&str>,
    limit: i64,
) -> Result<Vec<DeliveryRow>, String> {
    filtered_deliveries(client, device_id, None, None, limit).await
}

pub async fn filtered_deliveries(
    client: &Client,
    device_id: Option<&str>,
    topic: Option<&str>,
    since: Option<DateTime<Utc>>,
    limit: i64,
) -> Result<Vec<DeliveryRow>, String> {
    let rows = client
        .query(
            "SELECT received_at, topic, kind, device_id, claimed_device_id, qos, payload,
                    state, reason, detail, time_quality, duplicate_outcome,
                    source_profile, binding_key, direction
             FROM deliveries
             WHERE ($1::TEXT IS NULL OR device_id = $1) AND ($3::text IS NULL OR topic=$3) AND ($4::timestamptz IS NULL OR received_at >= $4)
             ORDER BY received_at DESC, id DESC
             LIMIT $2",
            &[&device_id, &limit, &topic, &since],
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
            direction: row.get(14),
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
                 WHERE device_id = $1 AND kind = 'water' AND time_quality = 'plausible' AND recorded_at IS NOT NULL
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
                 WHERE device_id = $1 AND kind = 'water' AND time_quality = 'plausible' AND recorded_at IS NOT NULL
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

    // A partial intake or an acknowledgment before COMMIT permanently loses
    // field measurements. This concrete data-loss risk warrants coverage.
    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn reconnect_and_atomic_intake_preserve_measurements() {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
        let mut client = connect(&url).await.unwrap();
        migrate(&client).await.unwrap();
        client
            .batch_execute(
                "TRUNCATE devices,device_bindings,observations,deliveries RESTART IDENTITY CASCADE",
            )
            .await
            .unwrap();
        let device = "00000000000000000000000A";
        client
            .execute(
                "INSERT INTO devices(device_id,source_profile,clock_policy) VALUES($1,'V21','utc')",
                &[&device],
            )
            .await
            .unwrap();
        client.execute("INSERT INTO device_bindings(binding_key,device_id,topic,source_profile) VALUES('atomic',$1,'bore/atomic/gwl-string','V21')", &[&device]).await.unwrap();
        let registry = load_registry(&client).await.unwrap();
        let payload = crate::fixtures::v21_payload_for(device);
        let intake = crate::adapter::intake(
            &crate::adapter::Delivery {
                topic: "bore/atomic/gwl-string",
                payload: payload.as_bytes(),
                qos: 1,
                received_at: Utc::now(),
            },
            &registry,
            &crate::topics::TopicMap::default(),
        );
        client
            .batch_execute(
                "ALTER TABLE observations ADD CONSTRAINT fixture_reject_intake CHECK(gwl<0)",
            )
            .await
            .unwrap();
        assert!(record_intake(&mut client, &intake).await.is_err());
        assert_eq!(
            client
                .query_one("SELECT count(*) FROM deliveries", &[])
                .await
                .unwrap()
                .get::<_, i64>(0),
            0
        );
        client
            .batch_execute("ALTER TABLE observations DROP CONSTRAINT fixture_reject_intake")
            .await
            .unwrap();
        let id = record_intake(&mut client, &intake).await.unwrap();
        assert_eq!(record_intake(&mut client, &intake).await.unwrap(), id);
        assert_eq!(
            client
                .query_one("SELECT count(*) FROM observations", &[])
                .await
                .unwrap()
                .get::<_, i64>(0),
            1
        );

        let owned = connect(&url).await.unwrap();
        let pid: i32 = owned
            .query_one("SELECT pg_backend_pid()", &[])
            .await
            .unwrap()
            .get(0);
        let managed = Database::new(url, owned);
        client
            .execute("SELECT pg_terminate_backend($1)", &[&pid])
            .await
            .unwrap();
        for _ in 0..50 {
            if managed.client.read().await.is_closed() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let recovered = managed.get().await.unwrap();
        assert_ne!(
            recovered
                .query_one("SELECT pg_backend_pid()", &[])
                .await
                .unwrap()
                .get::<_, i32>(0),
            pid
        );
        assert_eq!(
            recovered
                .query_one("SELECT count(*) FROM observations", &[])
                .await
                .unwrap()
                .get::<_, i64>(0),
            1
        );
    }

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
        let mut client = connect(&url).await.expect("connect");
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
        record_intake(&mut client, &intake).await.expect("record");

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
