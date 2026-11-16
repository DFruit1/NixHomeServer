//! Missed-connection (`stale`) alerts.
//!
//! A device is stale when it missed its expected connection (the announced
//! `next`, else last contact + send interval) by more than the policy's
//! margin; see `presence.rs`. Opening and resolving those alerts is a clock
//! event, not an ingest event, so a minute timer evaluates every enrollment.
//! The alert's `opened_at` is the instant the device turned stale, which makes
//! each missed connection one episode: a hand-resolved episode is never
//! reopened, the next missed connection is a new alert.

use chrono::{DateTime, Utc};
use serde_json::json;
use tokio_postgres::Client;

use crate::presence::{self, PresenceInput};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaleAction {
    Open,
    /// Resolve the open alert, with the reason recorded in its detail.
    Resolve(&'static str),
    Keep,
}

pub fn stale_action(status: &str, enabled: bool, open: bool) -> StaleAction {
    match (status, enabled, open) {
        ("stale", true, false) => StaleAction::Open,
        ("stale", true, true) => StaleAction::Keep,
        (_, _, false) => StaleAction::Keep,
        ("revoked", _, true) => StaleAction::Resolve("retired"),
        ("stale", false, true) => StaleAction::Resolve("stale alerts disabled"),
        (_, _, true) => StaleAction::Resolve("contact"),
    }
}

/// Evaluates every enrollment; returns the devices whose alerts changed.
pub async fn evaluate_stale(
    db: &Client,
    now: DateTime<Utc>,
    default_margin_min: i32,
) -> Result<Vec<String>, String> {
    let rows = db
        .query(
            "SELECT d.device_id,d.revoked_at IS NOT NULL,d.last_seen,d.presence_status,d.last_ready_at,
                d.link_state,d.link_state_at,d.listen_window_s,d.next_contact_at,d.settings,d.project_config,
                p.stale_enabled,p.stale_margin_min,
                (SELECT a.id FROM alerts a WHERE a.device_id=d.device_id AND a.kind='stale' AND a.state='open'
                    AND NOT a.superseded ORDER BY a.id DESC LIMIT 1)
             FROM devices d CROSS JOIN LATERAL groundwater_alert_policy(d.device_id,$1) p",
            &[&default_margin_min],
        )
        .await
        .map_err(|e| format!("stale alerts: {e}"))?;
    let mut changed = Vec::new();
    for row in rows {
        let device: String = row.get(0);
        let last_seen: Option<DateTime<Utc>> = row.get(2);
        let legacy_status: Option<String> = row.get(3);
        let link_state: Option<String> = row.get(5);
        let link_state_at: Option<DateTime<Utc>> = row.get(6);
        let settings: Option<serde_json::Value> = row.get(9);
        let project: Option<serde_json::Value> = row.get(10);
        let enabled: bool = row.get(11);
        let margin_min: i32 = row.get(12);
        let open_id: Option<i64> = row.get(13);
        let presence = presence::evaluate(
            now,
            &PresenceInput {
                revoked: row.get(1),
                last_seen,
                legacy_status: legacy_status.as_deref(),
                legacy_ready_at: row.get(4),
                link_state: link_state.as_deref(),
                link_state_at,
                listen_window_s: row.get(7),
                next_contact_at: row.get(8),
                send_interval_s: settings
                    .as_ref()
                    .and_then(crate::settings::send_interval_s)
                    .or_else(|| presence::legacy_send_interval_s(project.as_ref())),
                margin_s: i64::from(margin_min) * 60,
            },
        );
        match stale_action(&presence.status, enabled, open_id.is_some()) {
            StaleAction::Keep => {}
            StaleAction::Open => {
                let (Some(expected), Some(stale_after)) =
                    (presence.expected_contact_at, presence.stale_after)
                else {
                    continue;
                };
                let overdue_h =
                    ((now - expected).num_minutes() as f64 / 60.0 * 100.0).round() / 100.0;
                let inserted = db
                    .execute(
                        "INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,detail)
                         VALUES($1,'stale','open',$2,$3,$4) ON CONFLICT(device_id,kind,opened_at) DO NOTHING",
                        &[
                            &device,
                            &overdue_h,
                            &stale_after,
                            &json!({"expected_at":expected,"stale_after":stale_after,
                                "margin_min":margin_min,"last_seen":last_seen,"reason":presence.reason}),
                        ],
                    )
                    .await
                    .map_err(|e| format!("stale alert open: {e}"))?;
                if inserted == 1 {
                    changed.push(device);
                }
            }
            StaleAction::Resolve(reason) => {
                // Contact ends the episode when the device was last heard.
                let at = if reason == "contact" {
                    link_state_at.max(last_seen).unwrap_or(now).min(now)
                } else {
                    now
                };
                db.execute(
                    "UPDATE alerts SET state='resolved',resolved_at=GREATEST($2,opened_at),
                        detail=detail||jsonb_build_object('resolution',$3::text)
                     WHERE id=$1 AND state='open'",
                    &[&open_id, &at, &reason],
                )
                .await
                .map_err(|e| format!("stale alert resolve: {e}"))?;
                changed.push(device);
            }
        }
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_alerts_open_once_and_close_on_contact_or_policy() {
        assert_eq!(stale_action("stale", true, false), StaleAction::Open);
        assert_eq!(stale_action("stale", true, true), StaleAction::Keep);
        assert_eq!(stale_action("stale", false, false), StaleAction::Keep);
        assert_eq!(
            stale_action("stale", false, true),
            StaleAction::Resolve("stale alerts disabled")
        );
        for status in ["awake", "asleep", "offline", "receiving"] {
            assert_eq!(stale_action(status, true, false), StaleAction::Keep);
            assert_eq!(
                stale_action(status, true, true),
                StaleAction::Resolve("contact")
            );
        }
        assert_eq!(
            stale_action("revoked", true, true),
            StaleAction::Resolve("retired")
        );
        assert_eq!(stale_action("never", true, false), StaleAction::Keep);
    }
}
