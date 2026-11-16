//! Missed-connection (`stale`) alerts. The alerts raised from what loggers
//! report (logger events, health, watchdog boots) are database triggers in
//! `alerting.sql`, so they commit with the data that raised them.
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
                p.stale_enabled,p.stale_margin_min,d.link_retained,
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
        let link_retained: bool = row.get(13);
        let open_id: Option<i64> = row.get(14);
        let presence = presence::evaluate(
            now,
            &PresenceInput {
                revoked: row.get(1),
                last_seen,
                legacy_status: legacy_status.as_deref(),
                legacy_ready_at: row.get(4),
                link_state: link_state.as_deref(),
                link_state_at,
                link_retained,
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
                // A connection missed long ago (the server was down) is still
                // news while it lasts: groundwater_alert_enqueue_open covers
                // what the 24-hour notification trigger leaves out.
                let inserted: Option<i64> = db
                    .query_opt(
                        "INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,detail)
                         VALUES($1,'stale','open',$2,$3,$4) ON CONFLICT(device_id,kind,opened_at) DO NOTHING
                         RETURNING id",
                        &[
                            &device,
                            &overdue_h,
                            &stale_after,
                            &json!({"expected_at":expected,"stale_after":stale_after,
                                "margin_min":(stale_after - expected).num_minutes(),
                                "last_seen":last_seen,"reason":presence.reason}),
                        ],
                    )
                    .await
                    .map_err(|e| format!("stale alert open: {e}"))?
                    .map(|row| row.get(0));
                if let Some(id) = inserted {
                    db.execute("SELECT groundwater_alert_enqueue_open($1)", &[&id])
                        .await
                        .map_err(|e| format!("stale alert notification: {e}"))?;
                    changed.push(device);
                }
            }
            StaleAction::Resolve(reason) => {
                // Contact ends the episode when the device was last heard
                // (a retained status replay is not contact).
                let at = if reason == "contact" {
                    link_state_at
                        .filter(|_| !link_retained)
                        .max(last_seen)
                        .unwrap_or(now)
                        .min(now)
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

/// Logger events → alerts (`alerting.sql`) against a disposable database.
/// Regression coverage for lost and repeated alerts: a storage copy without
/// `seq` and its record notified twice, a copy after a log wipe was taken
/// for an old record and never alerted, and an alarm reported days late was
/// never notified while it was still active.
#[cfg(test)]
mod db_tests {
    use chrono::{DateTime, Duration, Utc};
    use serde_json::{json, Value};
    use tokio_postgres::Client;

    const D: &str = "0A1B2C3D4E5F60718293A4B5";

    async fn setup() -> Client {
        let url = std::env::var("GROUNDWATER_TEST_DATABASE_URL").unwrap();
        let client = crate::db::connect(&url).await.unwrap();
        crate::db::migrate(&client).await.unwrap();
        client
            .batch_execute(
                "TRUNCATE devices,device_bindings,observations,deliveries,alerts,device_events,device_health,
                    notification_outbox,notification_rules,alert_event_links RESTART IDENTITY CASCADE",
            )
            .await
            .unwrap();
        crate::db::migrate(&client).await.unwrap();
        client
            .execute(
                "INSERT INTO devices(device_id,source_profile,clock_policy) VALUES($1,'V22','utc')",
                &[&D],
            )
            .await
            .unwrap();
        client
    }

    /// Inserts one device event as ingest does (`seq`/`log_id` optional).
    async fn event(
        client: &Client,
        source: &str,
        event: &str,
        seq: Option<i64>,
        log_id: Option<i64>,
        at: DateTime<Utc>,
        details: Value,
    ) {
        client
            .execute(
                "INSERT INTO device_events(device_id,source,event,seq,log_id,recorded_at,time_valid,received_at,details)
                 VALUES($1,$2,$3,$4,$5,$6,true,now(),$7)",
                &[&D, &source, &event, &seq, &log_id, &at, &details],
            )
            .await
            .unwrap();
    }

    async fn alerts(client: &Client, kind: &str) -> Vec<(String, DateTime<Utc>)> {
        client
            .query(
                "SELECT state,opened_at FROM alerts WHERE kind=$1 AND NOT superseded ORDER BY opened_at",
                &[&kind],
            )
            .await
            .unwrap()
            .iter()
            .map(|r| (r.get(0), r.get(1)))
            .collect()
    }

    async fn openings(client: &Client, kind: &str) -> i64 {
        client
            .query_one(
                "SELECT count(*) FROM notification_outbox WHERE kind=$1 AND transition='open'",
                &[&kind],
            )
            .await
            .unwrap()
            .get(0)
    }

    // R3 (independent review): a hand resolution stamps resolved_at with
    // the server's clock, and every event older than that was filed as
    // history: a new 2500 mg impact and a level alarm still active after
    // the click raised no alert and no notification.
    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn a_hand_resolution_silences_only_the_occurrence_on_screen() {
        let client = setup().await;
        let now = DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap();
        let t = |minutes: i64| now - Duration::minutes(minutes);
        let high = |s: &str| json!({"limit":"high","state":s,"level":12.0,"threshold":10.5});
        event(
            &client,
            "record",
            "impact",
            Some(1),
            Some(7),
            t(300),
            json!({"peak_mg":900}),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_enter",
            Some(2),
            Some(7),
            t(300),
            high("enter"),
        )
        .await;
        client
            .execute(
                "UPDATE alerts SET state='resolved',resolved_at=now(),resolved_by='op' WHERE state='open'",
                &[],
            )
            .await
            .unwrap();
        // The same occurrences reported again (a resend under another log)
        // stay silenced.
        event(
            &client,
            "record",
            "impact",
            Some(1),
            Some(8),
            t(300),
            json!({"peak_mg":900}),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_enter",
            Some(2),
            Some(8),
            t(300),
            high("enter"),
        )
        .await;
        assert_eq!(
            alerts(&client, "impact").await,
            vec![("resolved".into(), t(300))]
        );
        assert_eq!(
            alerts(&client, "gwl_alarm").await,
            vec![("resolved".into(), t(300))]
        );
        // Next connection: a new impact, and the level fell and rose again
        // before the click; it is above the limit now.
        event(
            &client,
            "record",
            "impact",
            Some(3),
            Some(7),
            t(60),
            json!({"peak_mg":2500}),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_exit",
            Some(4),
            Some(7),
            t(200),
            high("exit"),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_enter",
            Some(5),
            Some(7),
            t(100),
            high("enter"),
        )
        .await;
        assert_eq!(
            alerts(&client, "impact").await,
            vec![("resolved".into(), t(300)), ("open".into(), t(60))]
        );
        assert_eq!(
            alerts(&client, "gwl_alarm").await,
            vec![("resolved".into(), t(300)), ("open".into(), t(100))]
        );
        assert_eq!(openings(&client, "impact").await, 2);
        assert_eq!(openings(&client, "gwl_alarm").await, 2);
        // The exit closed the hand-resolved episode in logger time.
        let role: String = client
            .query_one("SELECT role FROM alert_event_links l JOIN device_events e ON e.id=l.event_id WHERE e.seq=4", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(role, "close");
    }

    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn logger_events_raise_one_alert_whichever_copy_arrives() {
        let client = setup().await;
        let now = DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap();
        let t = |minutes: i64| now - Duration::minutes(minutes);

        // Copy first, record later: one alert, one notification; the exit
        // record closes it and its copy changes nothing.
        let enter = json!({"state":"enter","ss":3,"mv":2100});
        event(
            &client,
            "alert",
            "sensor_fault",
            Some(41),
            None,
            t(10),
            enter,
        )
        .await;
        let record = json!({"state":"enter","sensor_status":3,"sensor_mv":2100});
        event(
            &client,
            "record",
            "sensor_fault",
            Some(41),
            Some(7),
            t(10),
            record,
        )
        .await;
        assert_eq!(alerts(&client, "sensor_fault").await.len(), 1);
        assert_eq!(openings(&client, "sensor_fault").await, 1);
        let exit = json!({"state":"exit","sensor_status":3});
        event(
            &client,
            "record",
            "sensor_fault",
            Some(42),
            Some(7),
            t(5),
            exit,
        )
        .await;
        event(
            &client,
            "alert",
            "sensor_fault",
            Some(42),
            None,
            t(5),
            json!({"state":"exit","ss":3}),
        )
        .await;
        assert_eq!(
            alerts(&client, "sensor_fault").await,
            [("resolved".into(), t(10))]
        );

        // Storage copies carry no seq: matched to the record by instant.
        let sd = json!({"kind":"sd_full","unsaved":0,"usable":1});
        event(
            &client,
            "alert",
            "storage_warning",
            None,
            None,
            t(8),
            sd.clone(),
        )
        .await;
        event(
            &client,
            "record",
            "storage_warning",
            Some(43),
            Some(7),
            t(8),
            sd,
        )
        .await;
        assert_eq!(alerts(&client, "sd_card").await.len(), 1);
        assert_eq!(openings(&client, "sd_card").await, 1);
        let restored = json!({"kind":"sd_restored"});
        event(
            &client,
            "record",
            "storage_warning",
            Some(44),
            Some(7),
            t(4),
            restored,
        )
        .await;
        assert_eq!(alerts(&client, "sd_card").await[0].0, "resolved");

        // After a wipe the logger restarts seq: a new copy with an old seq
        // is a new event, not the old record's twin.
        let power = json!({"state":"enter","bat_mv":6550});
        event(
            &client,
            "record",
            "power_critical",
            Some(5),
            Some(7),
            t(3000),
            power.clone(),
        )
        .await;
        let power_exit = json!({"state":"exit","bat_mv":6800});
        event(
            &client,
            "record",
            "power_critical",
            Some(6),
            Some(7),
            t(2990),
            power_exit,
        )
        .await;
        event(
            &client,
            "alert",
            "power_critical",
            Some(5),
            None,
            t(2),
            power,
        )
        .await;
        assert_eq!(
            alerts(&client, "power_critical").await,
            [("resolved".into(), t(3000)), ("open".into(), t(2))]
        );

        // Copies precede older unsent records in a connection: the current
        // episode stays open, the older one becomes resolved history.
        let high =
            |state: &str| json!({"limit":"high","state":state,"level":11.0,"threshold":10.5});
        event(
            &client,
            "alert",
            "gwl_alarm_enter",
            Some(30),
            None,
            t(60),
            high("enter"),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_enter",
            Some(10),
            Some(7),
            t(300),
            high("enter"),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_exit",
            Some(20),
            Some(7),
            t(200),
            high("exit"),
        )
        .await;
        event(
            &client,
            "record",
            "gwl_alarm_enter",
            Some(30),
            Some(7),
            t(60),
            high("enter"),
        )
        .await;
        assert_eq!(
            alerts(&client, "gwl_alarm").await,
            [("resolved".into(), t(300)), ("open".into(), t(60))]
        );
        assert_eq!(openings(&client, "gwl_alarm").await, 1);

        // Latched kinds: a second impact updates the open alert.
        for minutes in [50, 30] {
            event(
                &client,
                "alert",
                "impact",
                Some(60 + minutes),
                None,
                t(minutes),
                json!({"peak_mg":900}),
            )
            .await;
        }
        assert_eq!(alerts(&client, "impact").await.len(), 1);
        assert_eq!(openings(&client, "impact").await, 1);
    }

    #[tokio::test]
    #[ignore = "requires disposable GROUNDWATER_TEST_DATABASE_URL"]
    async fn late_reports_notify_only_what_is_still_current() {
        let client = setup().await;
        let now = DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap();
        let days = |d: i64| now - Duration::days(d);
        let low = |state: &str| json!({"limit":"low","state":state,"level":0.4,"threshold":0.5});
        // Still active after three days offline: notified although old.
        event(
            &client,
            "alert",
            "gwl_alarm_enter",
            Some(1),
            None,
            days(3),
            low("enter"),
        )
        .await;
        assert_eq!(openings(&client, "gwl_alarm").await, 1);
        // Ended two days ago: the episode is history, not news.
        event(
            &client,
            "alert",
            "gwl_alarm_exit",
            Some(2),
            None,
            days(2),
            low("exit"),
        )
        .await;
        client
            .execute(
                "UPDATE notification_outbox SET created_at=now()-interval '5 minutes',next_attempt_at=now()",
                &[],
            )
            .await
            .unwrap();
        let ops = crate::config::OpsSettings::default();
        crate::notify::process(&client, &ops, &crate::notify::http_client())
            .await
            .unwrap();
        let states: Vec<(String, String, Option<String>)> = client
            .query(
                "SELECT transition,state,reason FROM notification_outbox ORDER BY id",
                &[],
            )
            .await
            .unwrap()
            .iter()
            .map(|r| (r.get(0), r.get(1), r.get(2)))
            .collect();
        assert_eq!(
            states,
            [("open".into(), "skipped".into(), Some("history".into()))]
        );
        assert!(matches!(
            crate::notify::late(now, days(3), now, Some(now - Duration::hours(2))),
            crate::notify::Late::Ended(_)
        ));
    }
}
