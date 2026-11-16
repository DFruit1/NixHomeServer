//! Alert and logger-event notifications through the local ntfy server.
//!
//! Database triggers (`ops.sql`) put one `notification_outbox` row per alert
//! transition or notifiable logger event; this worker decides what to send
//! and delivers it as an ntfy JSON publish. Deciding happens here, not in the
//! triggers, so a rule change applies to everything still pending and the
//! decision is unit-testable.
//!
//! Flapping protection: per device and kind, an opening or event is sent at
//! most once per rule cooldown (the next one sent says how many were
//! suppressed meanwhile); a resolution is sent only when its opening was;
//! a fleet-wide hourly cap applies to everything except critical messages.

use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use tokio_postgres::Client;

use crate::config::{NtfyTarget, OpsSettings};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

impl Severity {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "info" => Self::Info,
            "warning" => Self::Warning,
            "critical" => Self::Critical,
            _ => return None,
        })
    }
}

/// Notification kinds, their labels, source and possible severities.
pub const KINDS: [(&str, &str, &str, &[&str]); 10] = [
    ("above_max", "Level above maximum", "alert", &["warning"]),
    ("below_min", "Level below minimum", "alert", &["warning"]),
    ("battery_low", "Battery low", "alert", &["warning"]),
    ("solar_low", "Solar low", "alert", &["info"]),
    ("stale", "Missed connection", "alert", &["warning"]),
    ("gwl_alarm", "Logger level alarm", "event", &["warning"]),
    ("power_critical", "Power critical", "event", &["critical"]),
    ("sensor_fault", "Sensor fault", "event", &["warning"]),
    (
        "storage",
        "Storage (SD/MRAM)",
        "event",
        &["info", "warning", "critical"],
    ),
    (
        "tamper",
        "Impact, orientation or movement",
        "event",
        &["warning"],
    ),
];

pub fn known_kind(kind: &str) -> bool {
    KINDS.iter().any(|(k, ..)| *k == kind)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub enabled: bool,
    pub min_severity: Severity,
    pub priority: i16,
    pub cooldown_min: i32,
    pub notify_resolved: bool,
    pub topic: Option<String>,
}

/// What the outbox already says about this item's neighbours.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct History {
    /// Last opening/event sent for the same device and kind.
    pub last_sent: Option<DateTime<Utc>>,
    /// For a resolution: whether its opening was sent.
    pub opener_sent: bool,
    /// Messages sent fleet-wide in the last hour.
    pub sent_last_hour: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Send,
    /// Counted against flapping; reported by the next message sent.
    Suppress(&'static str),
    /// Not a notification under the current rules.
    Skip(&'static str),
}

pub fn decide(
    now: DateTime<Utc>,
    configured: bool,
    rule: Option<&Rule>,
    severity: Severity,
    transition: &str,
    history: &History,
    max_per_hour: i64,
) -> Decision {
    if !configured {
        return Decision::Skip("not-configured");
    }
    let Some(rule) = rule.filter(|r| r.enabled) else {
        return Decision::Skip("disabled");
    };
    if severity < rule.min_severity {
        return Decision::Skip("below-severity");
    }
    if transition == "resolved" {
        if !rule.notify_resolved {
            return Decision::Skip("disabled");
        }
        if !history.opener_sent {
            return Decision::Skip("resolved-unsent");
        }
    } else if history
        .last_sent
        .is_some_and(|at| now - at < chrono::Duration::minutes(i64::from(rule.cooldown_min)))
    {
        return Decision::Suppress("cooldown");
    }
    if severity < Severity::Critical && history.sent_last_hour >= max_per_hour {
        return Decision::Suppress("rate-limit");
    }
    Decision::Send
}

/// Everything a message is composed from.
#[derive(Debug, Clone)]
pub struct Item {
    pub device_id: String,
    pub display_name: String,
    pub location_id: Option<String>,
    pub project: String,
    pub kind: String,
    pub event: String,
    pub severity: Severity,
    pub transition: String,
    pub occurred_at: DateTime<Utc>,
    pub details: Value,
    pub from_alert: bool,
    pub suppressed: i64,
    pub suppressed_since: Option<DateTime<Utc>>,
}

fn num(details: &Value, key: &str) -> Option<f64> {
    details.get(key).and_then(Value::as_f64)
}

fn text<'a>(details: &'a Value, key: &str) -> Option<&'a str> {
    details.get(key).and_then(Value::as_str)
}

fn fixed(value: Option<f64>, digits: usize, unit: &str) -> String {
    value.map_or_else(String::new, |v| format!(" ({v:.digits$} {unit})"))
}

/// One line describing what happened.
pub fn headline(item: &Item) -> String {
    let d = &item.details;
    let resolved = item.transition == "resolved";
    let trigger = num(d, "trigger_value");
    let line = match (item.kind.as_str(), resolved) {
        ("above_max", false) => format!("level above maximum{}", fixed(trigger, 2, "m")),
        ("above_max", true) => "level back below maximum".into(),
        ("below_min", false) => format!("level below minimum{}", fixed(trigger, 2, "m")),
        ("below_min", true) => "level back above minimum".into(),
        ("battery_low", false) => format!("battery low{}", fixed(trigger, 2, "V")),
        ("battery_low", true) => "battery recovered".into(),
        ("solar_low", false) => format!("solar low{}", fixed(trigger, 2, "V")),
        ("solar_low", true) => "solar charging recovered".into(),
        ("stale", false) => format!(
            "missed its expected connection{}",
            fixed(trigger, 1, "h overdue")
        ),
        ("stale", true) => "connected again".into(),
        ("gwl_alarm", false) => format!(
            "logger {} level alarm{}",
            text(d, "limit").unwrap_or("level"),
            match (num(d, "level"), num(d, "threshold")) {
                (Some(l), Some(t)) => format!(" ({l:.3} m, threshold {t:.3} m)"),
                (Some(l), None) => format!(" ({l:.3} m)"),
                _ => String::new(),
            }
        ),
        ("gwl_alarm", true) => format!(
            "logger {} level alarm cleared",
            text(d, "limit").unwrap_or("level")
        ),
        ("power_critical", false) => format!(
            "power critical{}",
            fixed(num(d, "bat_mv").map(|mv| mv / 1000.0), 2, "V battery")
        ),
        ("power_critical", true) => "power recovered".into(),
        ("sensor_fault", false) => format!(
            "sensor fault{}",
            text(d, "sensor_status_name")
                .map(|s| format!(" ({s})"))
                .unwrap_or_default()
        ),
        ("sensor_fault", true) => "sensor fault cleared".into(),
        ("storage", _) => match (item.event.as_str(), text(d, "kind")) {
            ("tail_lock", _) | (_, Some("tail_lock")) => {
                "MRAM full of unsaved data: logging is locked until it is saved".into()
            }
            ("tail_unlocked", _) | (_, Some("tail_unlocked")) => "MRAM tail lock released".into(),
            (_, Some("sd_full")) => "SD card full".into(),
            (_, Some("sd_missing")) => "SD card missing".into(),
            (_, Some("sd_error")) => "SD card error".into(),
            (_, Some("sd_restored")) => "SD card restored".into(),
            (_, Some("mram_almost_full")) => "MRAM almost full of unsaved data".into(),
            (_, Some("mram_fault")) => "MRAM fault".into(),
            (_, Some("mram_ok")) => "MRAM back to normal".into(),
            (_, other) => format!("storage warning ({})", other.unwrap_or("unknown")),
        },
        ("tamper", _) => match item.event.as_str() {
            "impact" => format!(
                "impact detected{}",
                fixed(num(d, "peak_mg").or(num(d, "peak")), 0, "mg")
            ),
            "orientation" => format!("orientation changed{}", fixed(num(d, "tilt_deg"), 1, "°")),
            "gps_moved" => match (
                num(d, "distance_m").or(num(d, "dist_m")),
                num(d, "threshold_m").or(num(d, "thr_m")),
            ) {
                (Some(m), Some(t)) => format!("moved {m:.0} m (threshold {t:.0} m)"),
                (Some(m), None) => format!("moved {m:.0} m"),
                _ => "position moved".into(),
            },
            other => other.replace('_', " "),
        },
        (other, true) => format!("{} resolved", other.replace('_', " ")),
        (other, false) => other.replace('_', " "),
    };
    match text(d, "resolved_by").filter(|_| resolved) {
        Some(by) => format!("{line} (resolved by {by})"),
        None => line,
    }
}

pub struct Message {
    pub title: String,
    pub body: String,
    pub priority: i16,
    pub tags: Vec<&'static str>,
    pub click: Option<String>,
}

pub fn compose(item: &Item, rule: &Rule, public_url: Option<&str>) -> Message {
    let name = if item.display_name.is_empty() {
        item.device_id.as_str()
    } else {
        item.display_name.as_str()
    };
    let headline = headline(item);
    let mut body = vec![
        headline.clone(),
        format!("Device: {name} ({})", item.device_id),
    ];
    let mut place = Vec::new();
    if let Some(location) = item.location_id.as_deref().filter(|l| !l.is_empty()) {
        place.push(format!("Location: {location}"));
    }
    if !item.project.is_empty() {
        place.push(format!("Project: {}", item.project));
    }
    if !place.is_empty() {
        body.push(place.join(" · "));
    }
    body.push(format!(
        "When: {} UTC",
        item.occurred_at.format("%Y-%m-%d %H:%M")
    ));
    if let Some(note) = text(&item.details, "resolve_note").filter(|n| !n.is_empty()) {
        body.push(format!("Note: {note}"));
    }
    if item.suppressed > 0 {
        body.push(format!(
            "{} similar notification{} suppressed{}",
            item.suppressed,
            if item.suppressed == 1 { "" } else { "s" },
            item.suppressed_since
                .map(|at| format!(" since {} UTC", at.format("%Y-%m-%d %H:%M")))
                .unwrap_or_default()
        ));
    }
    let resolved = item.transition == "resolved";
    let tags = if resolved {
        vec!["white_check_mark"]
    } else {
        match item.severity {
            Severity::Critical => vec!["rotating_light"],
            Severity::Warning => vec!["warning"],
            Severity::Info => vec!["information_source"],
        }
    };
    let view = if item.from_alert { "alerts" } else { "events" };
    Message {
        title: format!("{name}: {headline}"),
        body: body.join("\n"),
        priority: if resolved {
            rule.priority.min(3)
        } else {
            rule.priority
        },
        tags,
        click: public_url.map(|base| {
            format!(
                "{}/#device={}&view={view}",
                base.trim_end_matches('/'),
                item.device_id
            )
        }),
    }
}

/// Publishes one message with ntfy's JSON API (`POST /` with the topic in
/// the body), which carries UTF-8 titles without header encoding.
pub async fn publish(
    http: &reqwest::Client,
    target: &NtfyTarget,
    topic: Option<&str>,
    message: &Message,
) -> Result<(), String> {
    let mut body = json!({
        "topic": topic.unwrap_or(&target.topic),
        "title": message.title,
        "message": message.body,
        "priority": message.priority,
        "tags": message.tags,
    });
    if let Some(click) = &message.click {
        body["click"] = json!(click);
    }
    let response = http
        .post(format!("{}/", target.server))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("ntfy unreachable: {e}"))?;
    let status = response.status();
    if status.is_success() {
        Ok(())
    } else {
        let text = response.text().await.unwrap_or_default();
        Err(format!(
            "ntfy answered {status}: {}",
            text.chars().take(200).collect::<String>()
        ))
    }
}

pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .expect("reqwest client")
}

const MAX_ATTEMPTS: i32 = 5;

/// Processes due outbox rows. Single worker: no row locking needed.
pub async fn process(
    db: &Client,
    ops: &OpsSettings,
    http: &reqwest::Client,
) -> Result<usize, String> {
    let rows = db
        .query(
            "SELECT o.id,o.device_id,o.kind,o.severity,o.transition,o.alert_id,o.event,o.occurred_at,o.details,
                o.attempts,d.display_name,d.location_id,d.project,d.revoked_at IS NOT NULL,
                r.enabled,r.min_severity,r.priority,r.cooldown_min,r.notify_resolved,r.topic,
                COALESCE(a.superseded,false)
             FROM notification_outbox o JOIN devices d ON d.device_id=o.device_id
             LEFT JOIN notification_rules r ON r.kind=o.kind
             LEFT JOIN alerts a ON a.id=o.alert_id
             WHERE o.state='pending' AND o.next_attempt_at<=now() ORDER BY o.id LIMIT 25",
            &[],
        )
        .await
        .map_err(|e| format!("notification outbox: {e}"))?;
    let handled = rows.len();
    for row in rows {
        let id: i64 = row.get(0);
        let device_id: String = row.get(1);
        let kind: String = row.get(2);
        let severity = Severity::parse(row.get(3)).unwrap_or(Severity::Warning);
        let transition: String = row.get(4);
        let alert_id: Option<i64> = row.get(5);
        let attempts: i32 = row.get(9);
        let revoked: bool = row.get(13);
        let superseded: bool = row.get(20);
        let rule = row.get::<_, Option<bool>>(14).map(|enabled| Rule {
            enabled,
            min_severity: Severity::parse(row.get(15)).unwrap_or(Severity::Warning),
            priority: row.get(16),
            cooldown_min: row.get(17),
            notify_resolved: row.get(18),
            topic: row.get(19),
        });
        if revoked || superseded {
            finish(
                db,
                id,
                "skipped",
                Some(if revoked { "revoked" } else { "superseded" }),
                None,
                0,
            )
            .await?;
            continue;
        }
        let history = history(db, id, &device_id, &kind, &transition, alert_id).await?;
        let decision = decide(
            Utc::now(),
            ops.ntfy.is_some(),
            rule.as_ref(),
            severity,
            &transition,
            &history,
            ops.notify_max_per_hour,
        );
        match decision {
            Decision::Skip(reason) => finish(db, id, "skipped", Some(reason), None, 0).await?,
            Decision::Suppress(reason) => {
                finish(db, id, "suppressed", Some(reason), None, 0).await?
            }
            Decision::Send => {
                let (Some(target), Some(rule)) = (&ops.ntfy, &rule) else {
                    continue;
                };
                let (suppressed, since) = if transition == "resolved" {
                    (0, None)
                } else {
                    suppressed_since(db, id, &device_id, &kind, history.last_sent).await?
                };
                let item = Item {
                    device_id: device_id.clone(),
                    display_name: row.get(10),
                    location_id: row.get(11),
                    project: row.get(12),
                    kind: kind.clone(),
                    event: row.get(6),
                    severity,
                    transition: transition.clone(),
                    occurred_at: row.get(7),
                    details: row.get(8),
                    from_alert: alert_id.is_some(),
                    suppressed,
                    suppressed_since: since,
                };
                let message = compose(&item, rule, ops.public_url.as_deref());
                db.execute(
                    "UPDATE notification_outbox SET title=$2,message=$3,suppressed_count=$4,attempts=attempts+1 WHERE id=$1",
                    &[&id, &message.title, &message.body, &(suppressed as i32)],
                )
                .await
                .map_err(|e| format!("notification compose: {e}"))?;
                match publish(http, target, rule.topic.as_deref(), &message).await {
                    Ok(()) => finish(db, id, "sent", None, None, 0).await?,
                    Err(error) if attempts + 1 >= MAX_ATTEMPTS => {
                        eprintln!("groundwater notify: giving up on #{id}: {error}");
                        finish(db, id, "failed", Some("delivery"), Some(&error), 0).await?
                    }
                    Err(error) => {
                        let backoff = 60i64 << attempts.clamp(0, 6);
                        finish(db, id, "pending", None, Some(&error), backoff).await?
                    }
                }
            }
        }
    }
    Ok(handled)
}

async fn finish(
    db: &Client,
    id: i64,
    state: &str,
    reason: Option<&str>,
    error: Option<&str>,
    retry_after_s: i64,
) -> Result<(), String> {
    db.execute(
        "UPDATE notification_outbox SET state=$2,reason=$3,error=$4,
            sent_at=CASE WHEN $2='sent' THEN now() ELSE sent_at END,
            next_attempt_at=now()+make_interval(secs=>$5::double precision)
         WHERE id=$1",
        &[&id, &state, &reason, &error, &(retry_after_s as f64)],
    )
    .await
    .map(|_| ())
    .map_err(|e| format!("notification state: {e}"))
}

async fn history(
    db: &Client,
    id: i64,
    device: &str,
    kind: &str,
    transition: &str,
    alert_id: Option<i64>,
) -> Result<History, String> {
    let row = db
        .query_one(
            "SELECT
                (SELECT max(sent_at) FROM notification_outbox WHERE device_id=$1 AND kind=$2 AND state='sent'
                    AND transition<>'resolved'),
                CASE WHEN $3='resolved' THEN COALESCE(
                    CASE WHEN $4::bigint IS NOT NULL THEN
                        (SELECT state='sent' FROM notification_outbox WHERE alert_id=$4 AND transition='open'
                         ORDER BY id DESC LIMIT 1)
                    ELSE
                        (SELECT state='sent' FROM notification_outbox WHERE device_id=$1 AND kind=$2
                           AND transition='open' AND id<$5 ORDER BY id DESC LIMIT 1)
                    END,false) ELSE false END,
                (SELECT count(*) FROM notification_outbox WHERE state='sent' AND sent_at>now()-interval '1 hour')",
            &[&device, &kind, &transition, &alert_id, &id],
        )
        .await
        .map_err(|e| format!("notification history: {e}"))?;
    Ok(History {
        last_sent: row.get(0),
        opener_sent: row.get(1),
        sent_last_hour: row.get(2),
    })
}

async fn suppressed_since(
    db: &Client,
    id: i64,
    device: &str,
    kind: &str,
    last_sent: Option<DateTime<Utc>>,
) -> Result<(i64, Option<DateTime<Utc>>), String> {
    let row = db
        .query_one(
            "SELECT count(*),min(created_at) FROM notification_outbox
             WHERE device_id=$1 AND kind=$2 AND state='suppressed' AND id<$3
               AND created_at>COALESCE($4,'-infinity'::timestamptz)",
            &[&device, &kind, &id, &last_sent],
        )
        .await
        .map_err(|e| format!("notification suppressed count: {e}"))?;
    Ok((row.get(0), row.get(1)))
}

/// Sends a test message straight away (operator action).
pub async fn send_test(ops: &OpsSettings, user: &str) -> Result<(), String> {
    let target = ops
        .ntfy
        .as_ref()
        .ok_or("notifications are not configured (GROUNDWATER_NTFY_URL is unset)")?;
    let message = Message {
        title: "Groundwater notifications test".into(),
        body: format!("Test message requested by {user}. Alerts from the groundwater platform arrive on this topic."),
        priority: 3,
        tags: vec!["test_tube"],
        click: ops.public_url.clone(),
    };
    publish(&http_client(), target, None, &message).await
}

/// The notifier loop. It owns its database connection and reconnects after
/// an outage; a failing ntfy never affects ingest.
pub async fn run(database_url: String, ops: OpsSettings) {
    let http = http_client();
    let mut db: Option<Client> = None;
    let mut timer = tokio::time::interval(Duration::from_secs(5));
    loop {
        timer.tick().await;
        if db.as_ref().is_none_or(Client::is_closed) {
            match crate::db::connect(&database_url).await {
                Ok(client) => db = Some(client),
                Err(e) => {
                    eprintln!("groundwater notify: {e}");
                    continue;
                }
            }
        }
        let Some(client) = db.as_ref() else { continue };
        if let Err(e) = process(client, &ops, &http).await {
            eprintln!("groundwater notify: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule() -> Rule {
        Rule {
            enabled: true,
            min_severity: Severity::Warning,
            priority: 4,
            cooldown_min: 60,
            notify_resolved: true,
            topic: None,
        }
    }

    fn at(minutes: i64) -> DateTime<Utc> {
        crate::rev2_store::utc(1_763_300_000) + chrono::Duration::minutes(minutes)
    }

    #[test]
    fn rules_gate_by_configuration_enablement_and_severity() {
        let h = History::default();
        let r = rule();
        let d = |configured, rule: Option<&Rule>, severity| {
            decide(at(0), configured, rule, severity, "open", &h, 30)
        };
        assert_eq!(
            d(false, Some(&r), Severity::Critical),
            Decision::Skip("not-configured")
        );
        assert_eq!(
            d(true, None, Severity::Critical),
            Decision::Skip("disabled")
        );
        let off = Rule {
            enabled: false,
            ..rule()
        };
        assert_eq!(
            d(true, Some(&off), Severity::Critical),
            Decision::Skip("disabled")
        );
        assert_eq!(
            d(true, Some(&r), Severity::Info),
            Decision::Skip("below-severity")
        );
        assert_eq!(d(true, Some(&r), Severity::Warning), Decision::Send);
    }

    #[test]
    fn a_flapping_device_sends_at_most_one_pair_per_cooldown() {
        let r = rule();
        // open #1 sent at t=0
        let open = |now, last_sent| {
            decide(
                now,
                true,
                Some(&r),
                Severity::Warning,
                "open",
                &History {
                    last_sent,
                    opener_sent: false,
                    sent_last_hour: 1,
                },
                30,
            )
        };
        let resolved = |opener_sent| {
            decide(
                at(5),
                true,
                Some(&r),
                Severity::Warning,
                "resolved",
                &History {
                    last_sent: Some(at(0)),
                    opener_sent,
                    sent_last_hour: 1,
                },
                30,
            )
        };
        assert_eq!(open(at(0), None), Decision::Send);
        // Its resolution is paired with a sent opening: sent despite cooldown.
        assert_eq!(resolved(true), Decision::Send);
        // Reopening within the cooldown is suppressed, and so is its resolution.
        assert_eq!(open(at(10), Some(at(0))), Decision::Suppress("cooldown"));
        assert_eq!(resolved(false), Decision::Skip("resolved-unsent"));
        // After the cooldown the next opening goes out again.
        assert_eq!(open(at(61), Some(at(0))), Decision::Send);
        let no_resolved = Rule {
            notify_resolved: false,
            ..rule()
        };
        assert_eq!(
            decide(
                at(5),
                true,
                Some(&no_resolved),
                Severity::Warning,
                "resolved",
                &History {
                    opener_sent: true,
                    ..Default::default()
                },
                30
            ),
            Decision::Skip("disabled")
        );
    }

    #[test]
    fn the_fleet_cap_spares_critical_messages() {
        let busy = History {
            sent_last_hour: 30,
            ..Default::default()
        };
        let r = rule();
        assert_eq!(
            decide(at(0), true, Some(&r), Severity::Warning, "event", &busy, 30),
            Decision::Suppress("rate-limit")
        );
        assert_eq!(
            decide(
                at(0),
                true,
                Some(&r),
                Severity::Critical,
                "event",
                &busy,
                30
            ),
            Decision::Send
        );
    }

    fn item(kind: &str, event: &str, transition: &str, details: Value) -> Item {
        Item {
            device_id: "6A1B2C3D4E5F60718293A4B5".into(),
            display_name: "Bore 7".into(),
            location_id: Some("A7".into()),
            project: "North".into(),
            kind: kind.into(),
            event: event.into(),
            severity: Severity::Warning,
            transition: transition.into(),
            occurred_at: at(0),
            details,
            from_alert: kind == "battery_low",
            suppressed: 0,
            suppressed_since: None,
        }
    }

    #[test]
    fn messages_name_the_device_place_and_link() {
        let mut battery = item(
            "battery_low",
            "battery_low",
            "open",
            json!({"trigger_value":6.912}),
        );
        battery.suppressed = 3;
        battery.suppressed_since = Some(at(-90));
        let message = compose(&battery, &rule(), Some("https://groundwater.example/"));
        assert_eq!(message.title, "Bore 7: battery low (6.91 V)");
        assert!(message
            .body
            .contains("Device: Bore 7 (6A1B2C3D4E5F60718293A4B5)"));
        assert!(message.body.contains("Location: A7 · Project: North"));
        assert!(message
            .body
            .contains("3 similar notifications suppressed since"));
        assert_eq!(
            message.click.as_deref(),
            Some("https://groundwater.example/#device=6A1B2C3D4E5F60718293A4B5&view=alerts")
        );
        assert_eq!(message.tags, ["warning"]);
        assert_eq!(message.priority, 4);
        let resolved = compose(
            &item(
                "battery_low",
                "battery_low",
                "resolved",
                json!({"resolved_by":"alice","resolve_note":"pack swapped"}),
            ),
            &rule(),
            None,
        );
        assert_eq!(
            resolved.title,
            "Bore 7: battery recovered (resolved by alice)"
        );
        assert!(resolved.body.contains("Note: pack swapped"));
        assert_eq!(resolved.priority, 3);
        assert_eq!(resolved.click, None);
    }

    #[test]
    fn logger_events_read_naturally() {
        let h =
            |kind, event, transition, details| headline(&item(kind, event, transition, details));
        assert_eq!(
            h(
                "gwl_alarm",
                "gwl_alarm_enter",
                "open",
                json!({"limit":"high","level":12.3456,"threshold":10.5})
            ),
            "logger high level alarm (12.346 m, threshold 10.500 m)"
        );
        assert_eq!(
            h(
                "power_critical",
                "power_critical",
                "open",
                json!({"bat_mv":6550})
            ),
            "power critical (6.55 V battery)"
        );
        assert_eq!(
            h(
                "storage",
                "storage_warning",
                "event",
                json!({"kind":"sd_full"})
            ),
            "SD card full"
        );
        assert_eq!(
            h("storage", "tail_lock", "event", json!({})),
            "MRAM full of unsaved data: logging is locked until it is saved"
        );
        assert_eq!(
            h(
                "tamper",
                "gps_moved",
                "event",
                json!({"dist_m":230,"thr_m":100})
            ),
            "moved 230 m (threshold 100 m)"
        );
        assert_eq!(
            h("stale", "stale", "open", json!({"trigger_value":5.25})),
            "missed its expected connection (5.2 h overdue)"
        );
    }
}
