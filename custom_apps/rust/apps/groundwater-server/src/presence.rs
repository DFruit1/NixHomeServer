//! Device presence and staleness.
//!
//! Revision 2 loggers report presence on `status` (`online`, `ready`,
//! `sleep`, and `offline` from the retained Last Will) and announce their
//! next scheduled connection (`next`). "Stale" therefore means "missed its
//! own announced connection by more than a margin", not "silent for 30
//! minutes": a logger that sends weekly is healthy after six days of silence.
//! Without a `next`, the expected connection is the last contact plus the
//! configured send interval; only when neither is known does the historical
//! 30-minute rule apply.
//!
//! The margin is never shorter than [`RETRY_FLOOR_SECONDS`]: a logger whose
//! connection fails retries 30 minutes later (firmware
//! `GWL_SCHED_RETRY_FIRST_S`), so a shorter margin would raise and clear a
//! missed-connection alert for every single failed attempt.
//!
//! A retained `status` is a broker replay (on the server's subscription), not
//! contact: it never makes a logger awake, and its time never stands in for
//! the last contact.

use chrono::{DateTime, Duration, Utc};

use crate::config::STALE_AFTER_MINUTES;

/// Inputs gathered from one `devices` row.
#[derive(Debug, Clone, Default)]
pub struct PresenceInput<'a> {
    pub revoked: bool,
    pub last_seen: Option<DateTime<Utc>>,
    /// Revision 1 `Ready`/`sleep` evidence.
    pub legacy_status: Option<&'a str>,
    pub legacy_ready_at: Option<DateTime<Utc>>,
    /// Revision 2 `status`.
    pub link_state: Option<&'a str>,
    pub link_state_at: Option<DateTime<Utc>>,
    /// The stored `status` came from a retained replay.
    pub link_retained: bool,
    pub listen_window_s: Option<i32>,
    pub next_contact_at: Option<DateTime<Utc>>,
    /// Configured send interval, when known.
    pub send_interval_s: Option<i64>,
    pub margin_s: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Presence {
    /// `revoked`, `never`, `awake`, `asleep`, `offline`, `stale` or
    /// `receiving` (revision 1 traffic without wake-state evidence).
    pub status: String,
    pub reason: String,
    /// When the next contact is expected.
    pub expected_contact_at: Option<DateTime<Utc>>,
    /// After this instant the device counts as stale.
    pub stale_after: Option<DateTime<Utc>>,
}

fn presence(
    status: &str,
    reason: String,
    expected: Option<DateTime<Utc>>,
    stale: Option<DateTime<Utc>>,
) -> Presence {
    Presence {
        status: status.to_owned(),
        reason,
        expected_contact_at: expected,
        stale_after: stale,
    }
}

/// Grace after `ready` before an unannounced disconnect is assumed: the
/// listen window plus keepalive slack.
const AWAKE_GRACE_SECONDS: i64 = 180;

/// Smallest stale margin: the firmware's first retry after a failed
/// connection (30 min) plus 10 minutes to register and connect.
pub const RETRY_FLOOR_SECONDS: i64 = 40 * 60;

pub fn evaluate(now: DateTime<Utc>, input: &PresenceInput<'_>) -> Presence {
    if input.revoked {
        return presence(
            "revoked",
            "enrollment revoked; new traffic is quarantined".into(),
            None,
            None,
        );
    }
    let Some(last_seen) = input.last_seen.or(input.link_state_at) else {
        return presence(
            "never",
            "no accepted observation or other attributed traffic yet".into(),
            None,
            None,
        );
    };
    // An announced next connection wins, unless the logger has connected
    // since it announced it.
    let contact_at = if input.link_retained {
        input.last_seen
    } else {
        input.link_state_at
    };
    let announced = input
        .next_contact_at
        .filter(|next| contact_at.is_none_or(|at| *next >= at - Duration::minutes(5)));
    let (expected, basis) = match (announced, input.send_interval_s) {
        (Some(next), _) => (next, "announced next connection".to_owned()),
        (None, Some(interval)) => (
            last_seen + Duration::seconds(interval),
            format!("last contact + send interval {interval} s"),
        ),
        (None, None) => (
            last_seen + Duration::minutes(STALE_AFTER_MINUTES),
            format!("no send interval known; fixed {STALE_AFTER_MINUTES} min"),
        ),
    };
    let margin = if input.send_interval_s.is_some() || announced.is_some() {
        Duration::seconds(input.margin_s.max(RETRY_FLOOR_SECONDS))
    } else {
        Duration::zero()
    };
    let stale_after = expected + margin;
    let stale = now > stale_after;
    let stale_presence = || {
        presence(
            "stale",
            format!(
                "no contact since {}; expected by {} ({basis}) plus {} min margin",
                last_seen.to_rfc3339(),
                expected.to_rfc3339(),
                margin.num_minutes()
            ),
            Some(expected),
            Some(stale_after),
        )
    };

    if let Some(state) = input.link_state {
        let at = input.link_state_at.unwrap_or(last_seen);
        let window = i64::from(input.listen_window_s.unwrap_or(60)) + AWAKE_GRACE_SECONDS;
        return match state {
            "online" | "ready" if !input.link_retained && now - at <= Duration::seconds(window) => presence(
                "awake",
                format!("{state} since {}; commands are delivered now", at.to_rfc3339()),
                Some(expected),
                Some(stale_after),
            ),
            _ if stale => stale_presence(),
            "offline" => presence(
                "offline",
                "connection lost without a clean sleep (Last Will); commands wait in the broker session".into(),
                Some(expected),
                Some(stale_after),
            ),
            _ => presence(
                "asleep",
                format!(
                    "sleeping; next connection expected {} ({basis})",
                    expected.to_rfc3339()
                ),
                Some(expected),
                Some(stale_after),
            ),
        };
    }

    // Revision 1: explicit Ready/sleep evidence when bound, else receipt.
    if crate::platform::awake(
        now,
        input.legacy_ready_at,
        input.legacy_status.unwrap_or(""),
    ) {
        return presence(
            "awake",
            "explicitly bound Ready; command window open".into(),
            Some(expected),
            Some(stale_after),
        );
    }
    if stale {
        return stale_presence();
    }
    if input.legacy_status.is_some() {
        return presence(
            "asleep",
            "sleep received or Ready window expired".into(),
            Some(expected),
            Some(stale_after),
        );
    }
    presence(
        "receiving",
        "attributed traffic arriving; wake state needs device-status".into(),
        Some(expected),
        Some(stale_after),
    )
}

/// Send interval of a revision 1 unit from its full project settings
/// (`sf` is `H:M`).
pub fn legacy_send_interval_s(project_config: Option<&serde_json::Value>) -> Option<i64> {
    let text = project_config?.get("sf")?.as_str()?;
    let (hours, minutes) = text.split_once(':')?;
    let total = hours.parse::<i64>().ok()? * 3600 + minutes.parse::<i64>().ok()? * 60;
    (total > 0).then_some(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(minutes: i64) -> DateTime<Utc> {
        crate::rev2_store::utc(1_763_300_000) + Duration::minutes(minutes)
    }

    #[test]
    fn a_weekly_logger_is_asleep_not_stale_between_connections() {
        let input = PresenceInput {
            last_seen: Some(at(0)),
            link_state: Some("sleep"),
            link_state_at: Some(at(0)),
            next_contact_at: Some(at(7 * 24 * 60)),
            margin_s: 1800,
            ..Default::default()
        };
        let now = at(6 * 24 * 60);
        let presence = evaluate(now, &input);
        assert_eq!(presence.status, "asleep");
        assert_eq!(presence.expected_contact_at, Some(at(7 * 24 * 60)));
        // The 30 min margin is raised to the 40 min retry floor.
        assert_eq!(presence.stale_after, Some(at(7 * 24 * 60 + 40)));
        // Missing the announced connection by more than the margin is stale.
        assert_eq!(evaluate(at(7 * 24 * 60 + 41), &input).status, "stale");
        assert_eq!(evaluate(at(7 * 24 * 60 + 39), &input).status, "asleep");
    }

    #[test]
    fn ready_is_awake_only_inside_the_listen_window() {
        let input = PresenceInput {
            last_seen: Some(at(0)),
            link_state: Some("ready"),
            link_state_at: Some(at(0)),
            listen_window_s: Some(60),
            next_contact_at: Some(at(60)),
            margin_s: 1800,
            ..Default::default()
        };
        assert_eq!(evaluate(at(2), &input).status, "awake");
        assert_eq!(evaluate(at(10), &input).status, "asleep");
        // A retained ready replayed at server start is not a live logger.
        let replayed = PresenceInput {
            link_retained: true,
            link_state_at: Some(at(3)),
            ..input
        };
        assert_eq!(evaluate(at(4), &replayed).status, "asleep");
    }

    #[test]
    fn last_will_is_offline_until_the_next_connection_is_missed() {
        let input = PresenceInput {
            last_seen: Some(at(0)),
            link_state: Some("offline"),
            link_state_at: Some(at(1)),
            next_contact_at: Some(at(24 * 60)),
            margin_s: 1800,
            ..Default::default()
        };
        assert_eq!(evaluate(at(5), &input).status, "offline");
        assert_eq!(evaluate(at(24 * 60 + 41), &input).status, "stale");
    }

    #[test]
    fn without_next_the_configured_interval_then_thirty_minutes_apply() {
        let with_interval = PresenceInput {
            last_seen: Some(at(0)),
            link_state: Some("sleep"),
            link_state_at: Some(at(0)),
            send_interval_s: Some(3600),
            margin_s: 600,
            ..Default::default()
        };
        assert_eq!(evaluate(at(95), &with_interval).status, "asleep");
        assert_eq!(evaluate(at(101), &with_interval).status, "stale");
        // A next announced before the latest connection is stale evidence.
        let old_next = PresenceInput {
            next_contact_at: Some(at(-120)),
            ..with_interval.clone()
        };
        assert_eq!(evaluate(at(65), &old_next).status, "asleep");
        let legacy = PresenceInput {
            last_seen: Some(at(0)),
            ..Default::default()
        };
        assert_eq!(evaluate(at(29), &legacy).status, "receiving");
        assert_eq!(evaluate(at(31), &legacy).status, "stale");
        assert_eq!(
            legacy_send_interval_s(Some(&serde_json::json!({"sf":"1:30"}))),
            Some(5400)
        );
        assert_eq!(evaluate(at(0), &PresenceInput::default()).status, "never");
        assert_eq!(
            evaluate(
                at(0),
                &PresenceInput {
                    revoked: true,
                    ..Default::default()
                }
            )
            .status,
            "revoked"
        );
    }
}
