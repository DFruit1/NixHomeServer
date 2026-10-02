//! Telemetry parsing and device-time normalisation.
//!
//! The firmware emits every measurement as a JSON **string** built by
//! `sprintf` (`main.c:559`), e.g.
//!
//! ```text
//! {"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}
//! ```
//!
//! Because those strings are also what a future firmware revision is most
//! likely to change, every accessor accepts both a JSON string and a JSON
//! number, and an unparsable measurement is dropped from the typed struct
//! rather than failing the whole reading. The raw payload is always retained
//! in the message log, so a firmware change that this parser cannot yet read
//! still leaves a complete audit trail.
//!
//! Device time is **local**: GPS UTC plus the configured `ltost` offset
//! (firmware default UTC+5). The `TIME` string carries no timezone, so the
//! platform must subtract the offset to place readings on a UTC timeline. The
//! result is flagged [`Reading::time_plausible`]: before the first GPS fix the
//! RTC holds CubeMX defaults and produces timestamps that are simply wrong.

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};

/// Firmware default local offset, `ltost` = `5:00`, when a device's configured
/// offset is unknown.
pub const DEFAULT_LOCAL_OFFSET_MINUTES: i32 = 300;

/// Earliest device timestamp treated as plausible. The firmware boots with
/// CubeMX defaults when GPS has never synced, and older captured payloads show
/// `2000-01-01`; anything before this is flagged rather than dropped.
const PLAUSIBLE_EPOCH_YEAR: i32 = 2024;

/// How far ahead of this host's clock a device timestamp may be and still be
/// considered plausible.
///
/// The firmware derives its time from GPS, so its clock is normally at least as
/// good as the host's, and a modest positive skew is routine. The window is
/// deliberately generous so a host with a drifting RTC does not start marking
/// good readings as implausible.
pub const MAX_FUTURE_SKEW_DAYS: i64 = 1;

/// How far ahead of this host's clock a reading may sit and still be returned
/// by a series query.
///
/// This deliberately matches [`MAX_FUTURE_SKEW_DAYS`]: a reading the plausibility
/// check accepts must also be visible to the chart, or the UI would silently
/// hide data it just judged valid.
pub const MAX_QUERY_FUTURE_SKEW_DAYS: i64 = MAX_FUTURE_SKEW_DAYS;

/// A parsed groundwater level reading.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    /// 24-character hex DeviceID from the MCU UID hash.
    pub device_id: String,
    /// Groundwater level in metres.
    pub gwl: f64,
    /// Device-reported local time, normalised to UTC using the device offset.
    pub recorded_at: DateTime<Utc>,
    /// The device's own timestamp string, kept for display and debugging.
    pub device_time: String,
    /// Signal quality on the firmware's 0-100 scale (not dBm).
    pub rssi: Option<i16>,
    /// Battery voltage in volts (not percent).
    pub battery_v: Option<f64>,
    /// Solar panel voltage. The firmware truncates this to a whole number, so
    /// it is effectively a coarse day/night indicator.
    pub solar_v: Option<f64>,
    /// False when the device clock cannot be trusted, e.g. before the first
    /// GPS fix.
    pub time_plausible: bool,
    /// Original payload text, trimmed of the trailing newline the firmware's
    /// SD-card line reader leaves behind.
    pub raw: String,
}

/// Why a payload could not be turned into a [`Reading`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    /// Not valid JSON, or not a JSON object.
    NotAnObject,
    /// No device identifier in any recognised spelling.
    NoDeviceId,
    /// No `GWL`/`gwl` level field.
    NoLevel,
    /// The level field was present but not a finite number.
    LevelNotNumeric,
    /// No parsable device timestamp.
    NoTimestamp,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::NotAnObject => "payload is not a JSON object",
            Self::NoDeviceId => "payload has no DeviceID",
            Self::NoLevel => "payload has no GWL field",
            Self::LevelNotNumeric => "GWL field is not a number",
            Self::NoTimestamp => "payload has no parsable TIME field",
        })
    }
}

impl std::error::Error for ParseError {}

/// Parses a telemetry payload.
///
/// `local_offset_minutes` is the device's configured `ltost` offset, used to
/// convert the device's local timestamp to UTC.
pub fn parse_reading(
    payload: &str,
    local_offset_minutes: i32,
) -> Result<Reading, ParseError> {
    let raw = payload.trim().to_string();
    let value: serde_json::Value =
        serde_json::from_str(raw.trim()).map_err(|_| ParseError::NotAnObject)?;
    let object = value.as_object().ok_or(ParseError::NotAnObject)?;

    let device_id = field(object, &["DeviceID", "deviceId", "device_id", "s_id"])
        .filter(|value| !value.trim().is_empty())
        .ok_or(ParseError::NoDeviceId)?
        .trim()
        .to_ascii_uppercase();

    let gwl_text = field(object, &["GWL", "gwl", "gwl_string", "level"]).ok_or(ParseError::NoLevel)?;
    let gwl = as_f64(&gwl_text).ok_or(ParseError::LevelNotNumeric)?;
    if !gwl.is_finite() {
        return Err(ParseError::LevelNotNumeric);
    }

    let device_time = field(
        object,
        &["TIME", "time", "timestamp", "l_timeoffset"],
    )
    .ok_or(ParseError::NoTimestamp)?
    .trim()
    .to_string();
    let naive = parse_device_time(&device_time).ok_or(ParseError::NoTimestamp)?;
    let recorded_at = naive_to_utc(naive, local_offset_minutes);

    Ok(Reading {
        device_id,
        gwl,
        recorded_at,
        device_time,
        rssi: field(object, &["RSSI", "rssi"])
            .and_then(|value| as_f64(&value))
            .map(|value| value as i16),
        battery_v: field(object, &["BL", "bl", "battery"]).and_then(|v| as_f64(&v)),
        solar_v: field(object, &["SOL", "sol", "solar"]).and_then(|v| as_f64(&v)),
        time_plausible: is_plausible(recorded_at),
        raw,
    })
}

/// True when a device timestamp is inside a window where it could plausibly be
/// real. Backlog replay legitimately carries old device times, so this only
/// rejects timestamps that could not describe a real deployment: years before
/// the project began, or readings dated in the future.
pub fn is_plausible(recorded_at: DateTime<Utc>) -> bool {
    let earliest = Utc
        .with_ymd_and_hms(PLAUSIBLE_EPOCH_YEAR, 1, 1, 0, 0, 0)
        .single()
        .expect("constant epoch is valid");
    let latest = Utc::now() + chrono::Duration::days(MAX_FUTURE_SKEW_DAYS);
    recorded_at >= earliest && recorded_at <= latest
}

/// Converts the firmware's `20YY-MM-DDTHH:MM:SS` to a UTC instant by
/// subtracting the device's local offset.
pub fn naive_to_utc(naive: NaiveDateTime, local_offset_minutes: i32) -> DateTime<Utc> {
    Utc.from_utc_datetime(&(naive - chrono::Duration::minutes(i64::from(local_offset_minutes))))
}

/// Parses the firmware's device-local timestamp.
///
/// The firmware writes a literal `20` century prefix followed by a two-digit
/// year (`main.c:554-555`), so the value is `20YY-MM-DDTHH:MM:SS`. Full
/// four-digit years and a `Z`/offset suffix are also accepted so a firmware
/// revision that corrects the century does not need a parser change here.
pub fn parse_device_time(value: &str) -> Option<NaiveDateTime> {
    let trimmed = value.trim();
    // A bare `YY-MM-DDTHH:MM:SS` is what the firmware's literal `20` century
    // prefix produces. A full `YYYY-...` value must be left alone: the century
    // is only added when the year component is genuinely two digits wide.
    let candidate = if looks_like_two_digit_year(trimmed) {
        format!("20{trimmed}")
    } else {
        trimmed.to_string()
    };
    let normalized = candidate.replace('T', " ");
    let normalized = normalized.trim_end_matches('Z');
    for format in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(&normalized, format) {
            return Some(naive);
        }
    }
    None
}

/// True for `YY-MM-DD...` where `YY` is two digits followed by a separator.
///
/// A full `YYYY-MM-DD...` has a digit at index 4, so it is rejected here and
/// parsed as-is instead of being given a bogus century prefix.
fn looks_like_two_digit_year(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_digit()
        && bytes[1].is_ascii_digit()
        && bytes[2] == b'-'
}

/// Reads the first present field from a set of accepted spellings.
///
/// Values are normally JSON strings, but a numeric spelling is accepted too so
/// a firmware revision that emits real JSON numbers does not need a parser
/// change. Returns [`Cow::Borrowed`] for the common string case.
fn field<'a>(
    object: &'a serde_json::Map<String, serde_json::Value>,
    names: &[&str],
) -> Option<std::borrow::Cow<'a, str>> {
    for name in names {
        let Some(value) = object.get(*name) else {
            continue;
        };
        match value {
            serde_json::Value::String(text) => return Some(std::borrow::Cow::Borrowed(text)),
            serde_json::Value::Number(number) => {
                return Some(std::borrow::Cow::Owned(number.to_string()))
            }
            _ => continue,
        }
    }
    None
}

/// Coerces a measurement to `f64`. The firmware zero-pads and space-pads its
/// values (`%05.2f`, `%03d`), so leading/trailing whitespace is expected.
fn as_f64(value: &str) -> Option<f64> {
    value.trim().parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = concat!(
        r#"{"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","#,
        r#""TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}"#,
        "\n"
    );

    #[test]
    fn parses_the_shipped_payload_shape() {
        let reading = parse_reading(SAMPLE, DEFAULT_LOCAL_OFFSET_MINUTES).expect("parses");
        assert_eq!(reading.device_id, "8F3A21C04B9E77A1D25C01FE");
        assert!((reading.gwl - 1.25).abs() < f64::EPSILON);
        assert_eq!(reading.rssi, Some(7));
        assert!((reading.battery_v.unwrap() - 3.14).abs() < 1e-9);
        assert!((reading.solar_v.unwrap() - 3.0).abs() < 1e-9);
        // Trailing newline from the SD line reader is stripped.
        assert!(!reading.raw.ends_with('\n'));
        assert_eq!(reading.raw, SAMPLE.trim());
    }

    #[test]
    fn converts_device_local_time_to_utc() {
        let reading = parse_reading(SAMPLE, 300).expect("parses");
        // 01:33:45 local at UTC+5 is 20:33:45 UTC the previous day.
        assert_eq!(reading.recorded_at.to_rfc3339(), "2026-10-02T20:33:45+00:00");
        let utc_offset_zero = parse_reading(SAMPLE, 0).expect("parses");
        assert_eq!(utc_offset_zero.recorded_at.to_rfc3339(), "2026-10-03T01:33:45+00:00");
    }

    #[test]
    fn accepts_numeric_json_values_as_well_as_strings() {
        let payload = r#"{"DeviceID":"abc123","GWL":1.25,"TIME":"2026-10-03T01:33:45","RSSI":7}"#;
        let reading = parse_reading(payload, 0).expect("parses");
        assert!((reading.gwl - 1.25).abs() < f64::EPSILON);
        assert_eq!(reading.rssi, Some(7));
    }

    #[test]
    fn accepts_lowercase_field_spellings_for_evolution() {
        let payload = r#"{"deviceId":"abc123","gwl":"2.5","time":"2026-10-03T01:33:45"}"#;
        let reading = parse_reading(payload, 0).expect("parses");
        assert_eq!(reading.device_id, "ABC123");
        assert!((reading.gwl - 2.5).abs() < f64::EPSILON);
    }

    #[test]
    fn rejects_payloads_without_identity_or_level() {
        assert_eq!(parse_reading("not json", 0), Err(ParseError::NotAnObject));
        assert_eq!(parse_reading("[1,2]", 0), Err(ParseError::NotAnObject));
        assert_eq!(
            parse_reading(r#"{"GWL":"1.0","TIME":"2026-10-03T01:33:45"}"#, 0),
            Err(ParseError::NoDeviceId)
        );
        assert_eq!(
            parse_reading(r#"{"DeviceID":"a","TIME":"2026-10-03T01:33:45"}"#, 0),
            Err(ParseError::NoLevel)
        );
        assert_eq!(
            parse_reading(r#"{"DeviceID":"a","GWL":"high","TIME":"2026-10-03T01:33:45"}"#, 0),
            Err(ParseError::LevelNotNumeric)
        );
        assert_eq!(
            parse_reading(r#"{"DeviceID":"a","GWL":"1.0","TIME":"nope"}"#, 0),
            Err(ParseError::NoTimestamp)
        );
    }

    #[test]
    fn tolerates_missing_optional_measurements() {
        let payload = r#"{"DeviceID":"a","GWL":"1.0","TIME":"2026-10-03T01:33:45"}"#;
        let reading = parse_reading(payload, 0).expect("parses");
        assert_eq!(reading.rssi, None);
        assert_eq!(reading.battery_v, None);
        assert_eq!(reading.solar_v, None);
    }

    #[test]
    fn flags_pre_gps_fix_timestamps_as_implausible() {
        // Captured from real hardware before the first GPS fix.
        let payload =
            r#"{"DeviceID":"a","GWL":"05.21","TIME":"2000-01-01T00:42:27","RSSI":"058","BL":"00.00"}"#;
        let reading = parse_reading(payload, 0).expect("parses");
        assert!(!reading.time_plausible);
        assert_eq!(reading.recorded_at.to_rfc3339(), "2000-01-01T00:42:27+00:00");
    }

    #[test]
    fn accepts_backlog_readings_older_than_the_configured_offset() {
        // A device offline for a week replays old but genuine timestamps.
        let payload = r#"{"DeviceID":"a","GWL":"1.0","TIME":"2026-09-20T04:00:00"}"#;
        let reading = parse_reading(payload, 300).expect("parses");
        assert!(reading.time_plausible);
    }

    #[test]
    fn parses_both_two_and_four_digit_years() {
        let full = parse_device_time("2026-10-03T01:33:45").expect("parses");
        // The firmware's literal `20` century prefix produces `26-10-03...`.
        let two_digit = parse_device_time("26-10-03T01:33:45").expect("parses");
        assert_eq!(full, two_digit);
        assert_eq!(full.to_string(), "2026-10-03 01:33:45");
        // A firmware revision correcting the century to a full year still works.
        assert_eq!(
            parse_device_time("2026-10-03T01:33:45Z").expect("parses"),
            full
        );
    }

    #[test]
    fn rejects_unparsable_device_times() {
        assert!(parse_device_time("").is_none());
        assert!(parse_device_time("2026-13-45T99:99:99").is_none());
        assert!(parse_device_time("not a time").is_none());
    }
}