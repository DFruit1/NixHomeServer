//! Device-time interpretation.
//!
//! The firmware writes `20YY-MM-DDTHH:MM:SS` with **no timezone** (`main.c`
//! `dtostr`), from a GPS-derived RTC. Two independent hazards follow:
//!
//! 1. Before the first GPS fix the RTC holds CubeMX defaults, so captured
//!    payloads contain `2000-01-01T00:42:27` — a syntactically valid but
//!    meaningless time.
//! 2. Any conversion therefore needs *evidence* about the device's clock. A
//!    payload that does carry a `Z` or numeric offset must never have the
//!    device's configured local offset subtracted on top of it: that turns one
//!    correct instant into a wrong one, and it is the failure mode the source
//!    review calls out ("a stripped Z with an unrelated local offset").
//!
//! This module never guesses. Server receipt time is always retained by the
//! caller; the device's original text is always retained next to the derived
//! instant; and when no clock policy is established the interpretation is
//! `Ambiguous` with `recorded_at = None` rather than a plausible-looking
//! invention.

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};

/// Earliest device timestamp treated as plausible.
///
/// The firmware boots with CubeMX defaults when GPS has never synced, and
/// captured payloads show `2000-01-01`; anything before this is classified
/// [`TimeQuality::Reset`] and kept as evidence rather than discarded.
pub const PLAUSIBLE_EPOCH_YEAR: i32 = 2024;

/// How far ahead of server receipt a device timestamp may sit before it is
/// classified [`TimeQuality::Future`]. GPS-derived time can be modestly ahead
/// of a host with a drifting clock, so the window is generous.
pub const MAX_FUTURE_SKEW_HOURS: i64 = 24;

/// Age beyond which a plausible reading is additionally noted as backlog.
///
/// Backlog replay is normal (a device reconnects after days offline and
/// re-sends its SD log), so this annotates rather than downgrades.
pub const BACKLOG_NOTE_HOURS: i64 = 48;

/// What the platform knows about a device's clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClockPolicy {
    /// The device's `TIME` text is UTC (no conversion).
    Utc,
    /// The device's `TIME` text is local time at a fixed offset from UTC,
    /// derived from the firmware's configured `ltost`.
    LocalOffset { offset_minutes: i32 },
    /// No evidence yet: retain the text, derive no instant.
    Unknown,
}

impl ClockPolicy {
    /// Parses an operator-configured policy.
    ///
    /// `local-offset` also accepts an inline offset (`local-offset:+05:30`) so
    /// a binding can carry everything needed to interpret its device's time.
    pub fn parse(value: &str) -> Option<Self> {
        let value = value.trim();
        if value.eq_ignore_ascii_case("utc") {
            return Some(Self::Utc);
        }
        if value.eq_ignore_ascii_case("unknown") {
            return Some(Self::Unknown);
        }
        let lower = value.to_ascii_lowercase();
        let rest = lower.strip_prefix("local-offset")?.trim();
        if rest.is_empty() {
            // A bare `local-offset` has no evidence for the offset, so it is
            // the same as `unknown` rather than a silent UTC+5 default.
            return Some(Self::Unknown);
        }
        let rest = rest.strip_prefix(':').or_else(|| rest.strip_prefix('='))?;
        parse_offset(rest).map(|offset_minutes| Self::LocalOffset { offset_minutes })
    }

    /// The offset this policy applies to a zoneless device timestamp.
    pub fn offset_minutes(self) -> Option<i32> {
        match self {
            Self::Utc => Some(0),
            Self::LocalOffset { offset_minutes } => Some(offset_minutes),
            Self::Unknown => None,
        }
    }
}

/// How much trust the derived instant deserves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimeQuality {
    /// Inside the plausible window.
    Plausible,
    /// Before the first GPS fix (RTC defaults); the instant is retained as
    /// evidence but excludes the reading from "latest plausible" views.
    Reset,
    /// Ahead of server receipt by more than [`MAX_FUTURE_SKEW_HOURS`].
    Future,
    /// Not a parsable timestamp. The raw text is retained.
    Invalid,
    /// Parsable, but no clock policy establishes what zone it was written in.
    Ambiguous,
}

impl TimeQuality {
    /// Stable name persisted with the observation.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Plausible => "plausible",
            Self::Reset => "reset",
            Self::Future => "future",
            Self::Invalid => "invalid",
            Self::Ambiguous => "ambiguous",
        }
    }

    /// Whether the instant may drive "latest plausible event" views.
    pub fn is_plausible(self) -> bool {
        matches!(self, Self::Plausible)
    }
}

/// Where the timezone evidence came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoneSource {
    /// The payload itself carried `Z` or a numeric offset.
    Payload,
    /// The enrollment's clock policy supplied the offset.
    DevicePolicy,
    /// No evidence; no instant derived.
    None,
}

impl ZoneSource {
    /// Stable name persisted with the observation.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Payload => "payload",
            Self::DevicePolicy => "device-policy",
            Self::None => "none",
        }
    }
}

/// The result of interpreting one device timestamp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterpretedTime {
    /// Derived UTC instant, absent when the text is invalid or ambiguous.
    pub recorded_at: Option<DateTime<Utc>>,
    /// Trust classification.
    pub quality: TimeQuality,
    /// Human-readable explanation, persisted so the decision is auditable.
    pub reason: String,
    /// Offset actually applied, in minutes.
    pub offset_applied_minutes: Option<i32>,
    /// Which evidence supplied the zone.
    pub zone_source: ZoneSource,
    /// Server receipt minus derived instant, in seconds. Negative when the
    /// device clock runs ahead.
    pub lag_seconds: Option<i64>,
}

/// A device timestamp parsed out of its text, before any policy is applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceTime {
    /// The wall-clock value as written by the device.
    pub naive: NaiveDateTime,
    /// A designator that already fixes the zone (`Z` or numeric offset).
    pub fixed_offset_minutes: Option<i32>,
}

/// Interprets the firmware's `TIME` text under a device clock policy.
///
/// Precedence is deliberate and is the whole point of this module:
///
/// 1. a zone designator in the payload wins — the text is self-describing;
/// 2. otherwise the enrollment's clock policy supplies the offset;
/// 3. otherwise nothing is derived and the quality is `Ambiguous`.
pub fn interpret(
    device_time_text: Option<&str>,
    policy: ClockPolicy,
    received_at: DateTime<Utc>,
) -> InterpretedTime {
    let Some(text) = device_time_text else {
        return InterpretedTime {
            recorded_at: None,
            quality: TimeQuality::Invalid,
            reason: "payload carried no TIME field".to_string(),
            offset_applied_minutes: None,
            zone_source: ZoneSource::None,
            lag_seconds: None,
        };
    };

    let Some(parsed) = parse_device_time(text) else {
        return InterpretedTime {
            recorded_at: None,
            quality: TimeQuality::Invalid,
            reason: format!("TIME {text:?} is not a parsable device timestamp"),
            offset_applied_minutes: None,
            zone_source: ZoneSource::None,
            lag_seconds: None,
        };
    };

    let (recorded_at, zone_source, offset_applied_minutes) =
        match (parsed.fixed_offset_minutes, policy) {
            (Some(offset), _) => {
                // Self-describing text: applying the device's local offset on
                // top would move a correct instant by the offset twice.
                let utc = Utc.from_utc_datetime(
                    &(parsed.naive - chrono::Duration::minutes(i64::from(offset))),
                );
                (Some(utc), ZoneSource::Payload, Some(offset))
            }
            (None, ClockPolicy::Unknown) => (None, ZoneSource::None, None),
            (None, policy) => {
                let offset = policy.offset_minutes().unwrap_or(0);
                let utc = Utc.from_utc_datetime(
                    &(parsed.naive - chrono::Duration::minutes(i64::from(offset))),
                );
                (Some(utc), ZoneSource::DevicePolicy, Some(offset))
            }
        };

    let Some(recorded_at) = recorded_at else {
        return InterpretedTime {
            recorded_at: None,
            quality: TimeQuality::Ambiguous,
            reason: format!(
                "TIME {text:?} has no zone and the device clock policy is not established"
            ),
            offset_applied_minutes: None,
            zone_source: ZoneSource::None,
            lag_seconds: None,
        };
    };

    let (quality, reason) = classify(
        recorded_at,
        received_at,
        zone_source,
        offset_applied_minutes,
    );
    InterpretedTime {
        recorded_at: Some(recorded_at),
        quality,
        reason,
        offset_applied_minutes,
        zone_source,
        lag_seconds: Some((received_at - recorded_at).num_seconds()),
    }
}

/// Classifies a derived instant against the plausible window.
fn classify(
    recorded_at: DateTime<Utc>,
    received_at: DateTime<Utc>,
    zone_source: ZoneSource,
    offset_applied_minutes: Option<i32>,
) -> (TimeQuality, String) {
    let basis = match zone_source {
        ZoneSource::Payload => "payload carried an explicit zone; device clock policy not applied",
        ZoneSource::DevicePolicy => "device clock policy supplied the zone",
        ZoneSource::None => "no zone evidence",
    };
    let offset_note = match offset_applied_minutes {
        Some(offset) if zone_source == ZoneSource::DevicePolicy => {
            format!(" (offset {offset:+} min applied)")
        }
        _ => String::new(),
    };

    let earliest = Utc
        .with_ymd_and_hms(PLAUSIBLE_EPOCH_YEAR, 1, 1, 0, 0, 0)
        .single()
        .expect("constant epoch is valid");

    if recorded_at < earliest {
        return (
            TimeQuality::Reset,
            format!(
                "device clock predates the first GPS fix ({basis}); instant retained as evidence, not used as event time"
            ),
        );
    }

    let latest = received_at + chrono::Duration::hours(MAX_FUTURE_SKEW_HOURS);
    if recorded_at > latest {
        return (
            TimeQuality::Future,
            format!(
                "device clock is more than {MAX_FUTURE_SKEW_HOURS}h ahead of server receipt ({basis})"
            ),
        );
    }

    let lag = (received_at - recorded_at).num_hours();
    if lag > BACKLOG_NOTE_HOURS {
        return (
            TimeQuality::Plausible,
            format!("backlog replay {lag}h behind server receipt{offset_note}; {basis}"),
        );
    }

    (
        TimeQuality::Plausible,
        format!("device time interpreted{offset_note}; {basis}"),
    )
}

/// Parses the firmware's device timestamp, keeping any explicit zone.
///
/// The firmware writes a literal `20` century prefix followed by a two-digit
/// year (`20YY-MM-DDTHH:MM:SS`). Full four-digit years are accepted unchanged,
/// and so are `Z`/`±HH:MM` suffixes, so a firmware revision that corrects the
/// century or adds a zone needs no parser change here.
pub fn parse_device_time(value: &str) -> Option<DeviceTime> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let (body, fixed_offset_minutes) = split_zone(trimmed)?;
    // A bare `YY-MM-DDTHH:MM:SS` is what the firmware's literal `20` century
    // prefix produces. A full `YYYY-...` value must be left alone: the century
    // is only added when the year component is genuinely two digits wide.
    let candidate = if looks_like_two_digit_year(body) {
        format!("20{body}")
    } else {
        body.to_string()
    };
    let normalized = candidate.replace('T', " ");
    for format in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(&normalized, format) {
            return Some(DeviceTime {
                naive,
                fixed_offset_minutes,
            });
        }
    }
    None
}

/// Splits an explicit zone suffix off a timestamp.
///
/// Returns `None` for a suffix that looks like a zone but cannot be parsed, so
/// a malformed `…+5` is an invalid timestamp rather than a silent local time.
fn split_zone(value: &str) -> Option<(&str, Option<i32>)> {
    if let Some(body) = value.strip_suffix('Z').or_else(|| value.strip_suffix('z')) {
        return Some((body, Some(0)));
    }
    let bytes = value.as_bytes();
    if bytes.len() > 6 {
        let sign_index = bytes.len() - 6;
        let sign = bytes[sign_index];
        if (sign == b'+' || sign == b'-') && bytes[sign_index + 3] == b':' {
            let offset = parse_offset(&value[sign_index..])?;
            return Some((value[..sign_index].trim_end(), Some(offset)));
        }
    }
    Some((value, None))
}

/// Parses `±HH:MM` (or `±HHMM`) into minutes east of UTC.
fn parse_offset(value: &str) -> Option<i32> {
    let trimmed = value.trim();
    let sign = match trimmed.as_bytes().first()? {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let rest = &trimmed[1..];
    let (hours, minutes) = match rest.split_once(':') {
        Some((hours, minutes)) => (hours, minutes),
        None if rest.len() == 4 => rest.split_at(2),
        None => return None,
    };
    let hours: i32 = hours.parse().ok()?;
    let minutes: i32 = minutes.parse().ok()?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    Some(sign * (hours * 60 + minutes))
}

/// True for `YY-MM-DD...` where `YY` is two digits followed by a separator.
///
/// A full `YYYY-MM-DD...` has a digit at index 4, so it is rejected here and
/// parsed as-is instead of being given a bogus century prefix.
fn looks_like_two_digit_year(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_digit() && bytes[1].is_ascii_digit() && bytes[2] == b'-'
}

#[cfg(test)]
mod tests {
    use super::*;

    fn received() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 3, 2, 0, 0)
            .single()
            .expect("timestamp")
    }

    #[test]
    fn local_offset_policy_converts_to_utc() {
        let interpreted = interpret(
            Some("2026-10-03T01:33:45"),
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
            received(),
        );
        assert_eq!(
            interpreted.recorded_at.expect("instant").to_rfc3339(),
            "2026-10-02T20:33:45+00:00"
        );
        assert_eq!(interpreted.quality, TimeQuality::Plausible);
        assert_eq!(interpreted.zone_source, ZoneSource::DevicePolicy);
        assert_eq!(interpreted.offset_applied_minutes, Some(300));
        assert!(interpreted.reason.contains("offset +300 min applied"));
    }

    #[test]
    fn utc_policy_applies_no_shift() {
        let interpreted = interpret(Some("2026-10-03T01:33:45"), ClockPolicy::Utc, received());
        assert_eq!(
            interpreted.recorded_at.expect("instant").to_rfc3339(),
            "2026-10-03T01:33:45+00:00"
        );
        assert_eq!(interpreted.offset_applied_minutes, Some(0));
    }

    #[test]
    fn payload_z_suffix_wins_over_a_local_offset_policy() {
        // The regression this module exists for: a `Z` timestamp must not also
        // have the device's local offset subtracted.
        let interpreted = interpret(
            Some("2026-10-03T01:33:45Z"),
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
            received(),
        );
        assert_eq!(
            interpreted.recorded_at.expect("instant").to_rfc3339(),
            "2026-10-03T01:33:45+00:00"
        );
        assert_eq!(interpreted.zone_source, ZoneSource::Payload);
        assert_eq!(interpreted.offset_applied_minutes, Some(0));
        assert!(interpreted
            .reason
            .contains("device clock policy not applied"));
    }

    #[test]
    fn payload_numeric_offset_is_honoured() {
        let interpreted = interpret(
            Some("2026-10-03T01:33:45+05:30"),
            ClockPolicy::Utc,
            received(),
        );
        assert_eq!(
            interpreted.recorded_at.expect("instant").to_rfc3339(),
            "2026-10-02T20:03:45+00:00"
        );
        assert_eq!(interpreted.zone_source, ZoneSource::Payload);
    }

    #[test]
    fn unknown_clock_policy_is_ambiguous_not_invented() {
        let interpreted = interpret(
            Some("2026-10-03T01:33:45"),
            ClockPolicy::Unknown,
            received(),
        );
        assert_eq!(interpreted.recorded_at, None);
        assert_eq!(interpreted.quality, TimeQuality::Ambiguous);
        assert_eq!(interpreted.zone_source, ZoneSource::None);
        assert!(interpreted
            .reason
            .contains("clock policy is not established"));
    }

    #[test]
    fn pre_gps_reset_clock_is_classified_not_dropped() {
        // Captured from hardware before the first GPS fix.
        let interpreted = interpret(
            Some("2000-01-01T00:42:27"),
            ClockPolicy::LocalOffset { offset_minutes: 0 },
            received(),
        );
        assert_eq!(
            interpreted.recorded_at.expect("instant").to_rfc3339(),
            "2000-01-01T00:42:27+00:00"
        );
        assert_eq!(interpreted.quality, TimeQuality::Reset);
        assert!(!interpreted.quality.is_plausible());
    }

    #[test]
    fn future_device_clock_is_classified() {
        let interpreted = interpret(Some("2099-01-01T00:00:00"), ClockPolicy::Utc, received());
        assert_eq!(interpreted.quality, TimeQuality::Future);
        assert!(interpreted.reason.contains("ahead of server receipt"));
    }

    #[test]
    fn minor_clock_skew_stays_plausible() {
        let interpreted = interpret(Some("2026-10-03T02:30:00"), ClockPolicy::Utc, received());
        assert_eq!(interpreted.quality, TimeQuality::Plausible);
    }

    #[test]
    fn backlog_is_plausible_but_annotated() {
        let interpreted = interpret(Some("2026-09-28T02:00:00"), ClockPolicy::Utc, received());
        assert_eq!(interpreted.quality, TimeQuality::Plausible);
        assert_eq!(interpreted.lag_seconds, Some(5 * 24 * 3600));
        assert!(interpreted.reason.contains("backlog replay"));
    }

    #[test]
    fn missing_and_unparsable_times_are_invalid() {
        let missing = interpret(None, ClockPolicy::Utc, received());
        assert_eq!(missing.quality, TimeQuality::Invalid);
        assert_eq!(missing.recorded_at, None);

        let garbage = interpret(Some("not a time"), ClockPolicy::Utc, received());
        assert_eq!(garbage.quality, TimeQuality::Invalid);
        assert_eq!(garbage.recorded_at, None);
        assert!(garbage.reason.contains("not a parsable device timestamp"));
    }

    #[test]
    fn parses_both_two_and_four_digit_years() {
        let full = parse_device_time("2026-10-03T01:33:45").expect("parses");
        let two_digit = parse_device_time("26-10-03T01:33:45").expect("parses");
        assert_eq!(full.naive, two_digit.naive);
        assert_eq!(full.fixed_offset_minutes, None);
        assert_eq!(two_digit.fixed_offset_minutes, None);
    }

    #[test]
    fn parses_zone_suffixes_and_rejects_malformed_ones() {
        assert_eq!(
            parse_device_time("2026-10-03T01:33:45Z")
                .expect("parses")
                .fixed_offset_minutes,
            Some(0)
        );
        assert_eq!(
            parse_device_time("2026-10-03T01:33:45-07:00")
                .expect("parses")
                .fixed_offset_minutes,
            Some(-420)
        );
        // A truncated zone must not be treated as a zoneless local time.
        assert!(parse_device_time("2026-10-03T01:33:45+5").is_none());
        assert!(parse_device_time("2026-10-03T01:33:45+25:00").is_none());
    }

    #[test]
    fn clock_policy_round_trips() {
        assert_eq!(ClockPolicy::parse("utc"), Some(ClockPolicy::Utc));
        assert_eq!(ClockPolicy::parse("UNKNOWN"), Some(ClockPolicy::Unknown));
        assert_eq!(
            ClockPolicy::parse("local-offset:+05:30"),
            Some(ClockPolicy::LocalOffset {
                offset_minutes: 330
            })
        );
        assert_eq!(
            ClockPolicy::parse("local-offset=-07:00"),
            Some(ClockPolicy::LocalOffset {
                offset_minutes: -420
            })
        );
        // A bare `local-offset` carries no evidence and must not default to
        // the firmware's UTC+5.
        assert_eq!(
            ClockPolicy::parse("local-offset"),
            Some(ClockPolicy::Unknown)
        );
        assert_eq!(ClockPolicy::parse("nonsense"), None);
    }
}
