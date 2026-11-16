//! Prometheus text exposition for `/metrics`.
//!
//! Served on the app's existing loopback listener. Access needs an operator
//! session through the gateway, or `Authorization: Bearer <token>` with the
//! token from `GROUNDWATER_METRICS_TOKEN_FILE` for a scraper on the host
//! (`api::boundary`). Per-device series are labelled by DeviceID only; names
//! and locations stay out of the scrape.

use std::fmt::Write;

use chrono::{DateTime, Utc};
use tokio_postgres::Client;

use crate::{db::DeviceSummary, ingest::IngestStats};

/// Escapes a label value (backslash, quote, newline).
pub fn label(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

#[derive(Default)]
pub struct Exposition(String);

impl Exposition {
    pub fn family(&mut self, name: &str, kind: &str, help: &str) {
        let _ = writeln!(self.0, "# HELP {name} {help}\n# TYPE {name} {kind}");
    }
    pub fn sample(&mut self, name: &str, labels: &[(&str, &str)], value: f64) {
        let labels = if labels.is_empty() {
            String::new()
        } else {
            format!(
                "{{{}}}",
                labels
                    .iter()
                    .map(|(k, v)| format!("{k}=\"{}\"", label(v)))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        };
        let _ = writeln!(self.0, "{name}{labels} {value}");
    }
    pub fn finish(self) -> String {
        self.0
    }
}

/// Fleet presence counts and per-device ages from the device summaries.
pub fn devices(out: &mut Exposition, devices: &[DeviceSummary], now: DateTime<Utc>) {
    out.family(
        "groundwater_devices",
        "gauge",
        "Enrolled devices by presence status.",
    );
    let mut counts = std::collections::BTreeMap::<&str, u64>::new();
    for status in [
        "awake",
        "asleep",
        "offline",
        "stale",
        "receiving",
        "never",
        "revoked",
    ] {
        counts.insert(status, 0);
    }
    for device in devices {
        *counts.entry(device.status.as_str()).or_default() += 1;
    }
    for (status, count) in &counts {
        out.sample("groundwater_devices", &[("status", status)], *count as f64);
    }
    out.family(
        "groundwater_device_last_seen_age_seconds",
        "gauge",
        "Seconds since the device's last attributed traffic.",
    );
    for device in devices.iter().filter(|d| !d.revoked) {
        if let Some(seen) = device.last_received_at {
            out.sample(
                "groundwater_device_last_seen_age_seconds",
                &[("device_id", &device.device_id)],
                (now - seen).num_seconds().max(0) as f64,
            );
        }
    }
    out.family(
        "groundwater_device_next_contact_seconds",
        "gauge",
        "Seconds until the expected next connection (negative when overdue).",
    );
    for device in devices.iter().filter(|d| !d.revoked) {
        if let Some(expected) = device.expected_contact_at {
            out.sample(
                "groundwater_device_next_contact_seconds",
                &[("device_id", &device.device_id)],
                (expected - now).num_seconds() as f64,
            );
        }
    }
}

pub fn ingest(out: &mut Exposition, stats: &IngestStats) {
    out.family(
        "groundwater_broker_connected",
        "gauge",
        "1 when both MQTT sessions are connected.",
    );
    out.sample(
        "groundwater_broker_connected",
        &[],
        f64::from(u8::from(stats.connected && stats.telemetry_connected)),
    );
    for (name, help, value) in [
        (
            "groundwater_ingest_deliveries_total",
            "MQTT messages received since start.",
            stats.deliveries,
        ),
        (
            "groundwater_ingest_observations_total",
            "Observations stored since start.",
            stats.observations,
        ),
        (
            "groundwater_ingest_quarantined_total",
            "Deliveries quarantined since start.",
            stats.quarantined,
        ),
        (
            "groundwater_ingest_conflicts_total",
            "Conflicting observations since start.",
            stats.conflicts,
        ),
        (
            "groundwater_ingest_redelivery_candidates_total",
            "Redelivered identical observations since start.",
            stats.redelivery_candidates,
        ),
    ] {
        out.family(name, "counter", help);
        out.sample(name, &[], value as f64);
    }
}

/// Database-backed families.
pub async fn database(out: &mut Exposition, db: &Client) -> Result<(), String> {
    let q = |e: tokio_postgres::Error| format!("metrics: {e}");
    let row = db
        .query_one(
            "SELECT (SELECT count(*) FROM deliveries WHERE received_at>now()-interval '1 hour'),
                    (SELECT count(*) FROM stream_frames WHERE received_at>now()-interval '1 hour'),
                    (SELECT count(*) FROM observations WHERE received_at>now()-interval '1 hour')",
            &[],
        )
        .await
        .map_err(q)?;
    for (index, name, help) in [
        (
            0,
            "groundwater_deliveries_last_hour",
            "MQTT deliveries stored in the last hour.",
        ),
        (
            1,
            "groundwater_frames_last_hour",
            "New data/stream ring frames in the last hour.",
        ),
        (
            2,
            "groundwater_observations_last_hour",
            "Observations stored in the last hour.",
        ),
    ] {
        out.family(name, "gauge", help);
        out.sample(name, &[], row.get::<_, i64>(index) as f64);
    }
    let grouped: [(&str, &str, &str, &str); 4] = [
        (
            "groundwater_commands",
            "Commands by protocol revision and state.",
            "SELECT protocol::text,state,count(*) FROM commands GROUP BY 1,2 ORDER BY 1,2",
            "protocol,state",
        ),
        (
            "groundwater_alerts_open",
            "Open alerts by kind.",
            "SELECT kind,count(*) FROM alerts WHERE state='open' AND NOT superseded GROUP BY 1 ORDER BY 1",
            "kind",
        ),
        (
            "groundwater_stream_gaps",
            "Stream sequence gaps by state.",
            "SELECT state,count(*) FROM stream_gaps GROUP BY 1 ORDER BY 1",
            "state",
        ),
        (
            "groundwater_notifications_total",
            "Notification outbox rows by state.",
            "SELECT state,count(*) FROM notification_outbox GROUP BY 1 ORDER BY 1",
            "state",
        ),
    ];
    for (name, help, sql, labels) in grouped {
        out.family(name, "gauge", help);
        let names: Vec<&str> = labels.split(',').collect();
        for row in db.query(sql, &[]).await.map_err(q)? {
            let values: Vec<String> = (0..names.len()).map(|i| row.get::<_, String>(i)).collect();
            let pairs: Vec<(&str, &str)> = names
                .iter()
                .zip(values.iter())
                .map(|(k, v)| (*k, v.as_str()))
                .collect();
            out.sample(name, &pairs, row.get::<_, i64>(names.len()) as f64);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposition_escapes_labels_and_counts_every_status() {
        let mut out = Exposition::default();
        let now = Utc::now();
        let device = |id: &str, status: &str| DeviceSummary {
            device_id: id.into(),
            status: status.into(),
            last_received_at: Some(now - chrono::Duration::seconds(90)),
            expected_contact_at: Some(now - chrono::Duration::seconds(30)),
            ..Default::default()
        };
        devices(
            &mut out,
            &[
                device("A", "asleep"),
                device("B", "asleep"),
                device("C\"x", "stale"),
            ],
            now,
        );
        out.sample("x", &[("k", "a\\b\nc")], 1.0);
        let text = out.finish();
        assert!(text.contains("# TYPE groundwater_devices gauge\n"));
        assert!(text.contains("groundwater_devices{status=\"asleep\"} 2\n"));
        assert!(text.contains("groundwater_devices{status=\"awake\"} 0\n"));
        assert!(text.contains("groundwater_device_last_seen_age_seconds{device_id=\"A\"} 90\n"));
        assert!(
            text.contains("groundwater_device_next_contact_seconds{device_id=\"C\\\"x\"} -30\n")
        );
        assert!(text.contains("x{k=\"a\\\\b\\nc\"} 1\n"));
    }
}
