//! Wire parsing for the firmware's telemetry payload.
//!
//! Every measurement is a JSON **string** built by `sprintf`
//! (`main.c:559`), e.g.
//!
//! ```text
//! {"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}
//! ```
//!
//! The original text is evidence: `01.25`, `007` and `3.000000` carry the
//! firmware's field width and precision, and re-serialising them as numbers
//! would quietly claim a resolution the device never measured. This module
//! therefore keeps each field's text verbatim alongside its parsed number, and
//! leaves every trust decision — which profile, whether the value is in range,
//! whose device it is — to [`crate::adapter`].
//!
//! A payload the firmware truncates stays truncated here: `SOL` is
//! integer-valued in every inspected build, so `"3.000000"` is reported as
//! three volts with a truncation quality reason rather than being scaled.

use serde_json::Value;

/// Largest absolute groundwater level accepted as a water measurement, in
/// metres.
///
/// The firmware calibrates `GWL` to metres but neither its datum nor its sign
/// convention is commissioned (`GW-001-source-review.md` §3), so this is a
/// sanity bound, not a physical claim: it rejects an encoded ADC failure that
/// produces a huge number while accepting any plausible bore reading. Domain
/// review may tighten it once an installation reference exists.
pub const GWL_ABS_LIMIT_M: f64 = 1000.0;

/// One wire field, preserving the firmware's text.
#[derive(Debug, Clone, PartialEq)]
pub struct FieldText {
    /// The value exactly as the firmware serialised it. Nothing is trimmed or
    /// re-formatted: the field width, padding and precision are part of the
    /// evidence, and a whitespace change is a firmware change worth seeing.
    pub text: String,
    /// The same text parsed as a number, when it is one.
    pub value: Option<f64>,
}

impl FieldText {
    /// A finite numeric value, or `None` for text that is not a number.
    pub fn number(&self) -> Option<f64> {
        self.value.filter(|value| value.is_finite())
    }
}

/// A telemetry payload as it arrived, with no trust applied.
#[derive(Debug, Clone, PartialEq)]
pub struct WireReading {
    /// The parsed JSON object, retained for the delivery record.
    pub payload: Value,
    /// The device identifier the payload *claims*, if any. A claim is
    /// evidence, not authentication: see [`crate::adapter`].
    pub claimed_device_id: Option<String>,
    /// Groundwater level, always present in an accepted reading.
    pub gwl: FieldText,
    /// Device-local time text, verbatim and unparsed.
    pub time_text: Option<String>,
    /// Signal strength on the firmware's transformed-CSQ scale.
    pub rssi: Option<FieldText>,
    /// Battery input voltage.
    pub battery_v: Option<FieldText>,
    /// Solar input voltage (integer-truncated by the firmware).
    pub solar_v: Option<FieldText>,
}

/// Why a payload is not a usable reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    /// Not valid JSON.
    NotJson,
    /// Valid JSON, but not an object.
    NotAnObject,
    /// No `GWL`/`gwl` field.
    MissingLevel,
    /// The level field is present but not a finite number.
    LevelNotNumeric,
    /// The level parses but is outside [`GWL_ABS_LIMIT_M`].
    LevelOutOfRange,
}

impl WireError {
    /// Stable reason code persisted with a quarantined delivery.
    pub fn code(self) -> &'static str {
        match self {
            Self::NotJson => "not-json",
            Self::NotAnObject => "not-a-json-object",
            Self::MissingLevel => "missing-gwl",
            Self::LevelNotNumeric => "gwl-not-numeric",
            Self::LevelOutOfRange => "gwl-out-of-range",
        }
    }
}

impl std::fmt::Display for WireError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJson => formatter.write_str("payload is not valid JSON"),
            Self::NotAnObject => formatter.write_str("payload is not a JSON object"),
            Self::MissingLevel => formatter.write_str("payload has no GWL field"),
            Self::LevelNotNumeric => formatter.write_str("GWL is not a finite number"),
            Self::LevelOutOfRange => formatter.write_str("GWL is outside the accepted range"),
        }
    }
}

impl std::error::Error for WireError {}

/// Parses a telemetry payload, preserving field text.
///
/// The trailing `\n` left by the firmware's SD-card line reader is trimmed.
/// Missing or unparsable *health* fields are kept as `None` — they never
/// become a zero — while a missing or invalid `GWL` is an error, because a
/// water reading without a water value cannot be repaired by the server.
pub fn parse_wire_reading(payload: &str) -> Result<WireReading, WireError> {
    let text = payload.trim();
    let value: Value = serde_json::from_str(text).map_err(|_| WireError::NotJson)?;
    let object = value.as_object().ok_or(WireError::NotAnObject)?;

    let gwl_text =
        field(object, &["GWL", "gwl", "gwl_string", "level"]).ok_or(WireError::MissingLevel)?;
    let gwl_value = number_from(&gwl_text).ok_or(WireError::LevelNotNumeric)?;
    if gwl_value.abs() > GWL_ABS_LIMIT_M {
        return Err(WireError::LevelOutOfRange);
    }

    Ok(WireReading {
        claimed_device_id: field(object, &["DeviceID", "deviceId", "device_id", "s_id"])
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty()),
        gwl: FieldText {
            text: gwl_text,
            value: Some(gwl_value),
        },
        time_text: field(object, &["TIME", "time", "timestamp", "l_timeoffset"])
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty()),
        rssi: optional_field(object, &["RSSI", "rssi"]),
        battery_v: optional_field(object, &["BL", "bl", "battery"]),
        solar_v: optional_field(object, &["SOL", "sol", "solar"]),
        payload: value,
    })
}

/// Reads a field that may be a JSON string or number, keeping its text.
fn optional_field(object: &serde_json::Map<String, Value>, names: &[&str]) -> Option<FieldText> {
    let text = field(object, names)?;
    let value = number_from(&text);
    Some(FieldText { text, value })
}

/// Reads the first present field from a set of accepted spellings.
///
/// Values are normally JSON strings, but a numeric spelling is accepted so a
/// firmware revision that emits real JSON numbers needs no parser change.
fn field(object: &serde_json::Map<String, Value>, names: &[&str]) -> Option<String> {
    for name in names {
        match object.get(*name) {
            Some(Value::String(text)) => return Some(text.clone()),
            Some(Value::Number(number)) => return Some(number.to_string()),
            _ => continue,
        }
    }
    None
}

/// Coerces firmware text to a finite `f64`.
///
/// Non-finite results (`NaN`, `inf`) are rejected here rather than propagated:
/// a non-finite level is an encoding failure, and treating it as a number
/// would let it into a chart or an average.
fn number_from(text: &str) -> Option<f64> {
    text.trim()
        .parse::<f64>()
        .ok()
        .filter(|value| value.is_finite())
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
    fn preserves_every_field_text_as_sent() {
        let reading = parse_wire_reading(SAMPLE).expect("parses");
        assert_eq!(
            reading.claimed_device_id.as_deref(),
            Some("8F3A21C04B9E77A1D25C01FE")
        );
        // Zero padding and six-decimal solar survive verbatim.
        assert_eq!(reading.gwl.text, "01.25");
        assert_eq!(reading.gwl.number(), Some(1.25));
        assert_eq!(
            reading.rssi.as_ref().map(|field| field.text.as_str()),
            Some("007")
        );
        assert_eq!(
            reading.battery_v.as_ref().map(|field| field.text.as_str()),
            Some("03.14")
        );
        assert_eq!(
            reading.solar_v.as_ref().map(|field| field.text.as_str()),
            Some("3.000000")
        );
        assert_eq!(reading.time_text.as_deref(), Some("2026-10-03T01:33:45"));
    }

    #[test]
    fn trims_the_sd_card_trailing_newline_only() {
        let reading = parse_wire_reading(SAMPLE).expect("parses");
        // The parsed object is the audit copy and carries no newline ambiguity.
        assert_eq!(reading.payload["GWL"], "01.25");
    }

    #[test]
    fn a_reading_without_identity_still_parses() {
        // V20/ML payloads: the identity is simply absent.
        let payload = r#"{"GWL":"02.75","TIME":"2026-10-03T02:00:00","RSSI":"041","BL":"03.10","SOL":"0.000000"}"#;
        let reading = parse_wire_reading(payload).expect("parses");
        assert_eq!(reading.claimed_device_id, None);
        assert_eq!(reading.gwl.text, "02.75");
    }

    #[test]
    fn numeric_json_values_are_accepted_without_losing_the_reading() {
        let payload = r#"{"DeviceID":"abc","GWL":1.25,"TIME":"2026-10-03T01:33:45","RSSI":7}"#;
        let reading = parse_wire_reading(payload).expect("parses");
        assert_eq!(reading.gwl.text, "1.25");
        assert_eq!(reading.gwl.number(), Some(1.25));
        assert_eq!(
            reading.rssi.as_ref().and_then(|field| field.number()),
            Some(7.0)
        );
    }

    #[test]
    fn missing_health_fields_stay_absent_rather_than_zero() {
        let payload = r#"{"DeviceID":"abc","GWL":"1.00","TIME":"2026-10-03T01:33:45"}"#;
        let reading = parse_wire_reading(payload).expect("parses");
        assert_eq!(reading.rssi, None);
        assert_eq!(reading.battery_v, None);
        assert_eq!(reading.solar_v, None);
    }

    #[test]
    fn malformed_health_fields_keep_their_text_but_no_number() {
        // A garbled battery field must not invalidate a usable water reading,
        // and must not be presented as 0 V either.
        let payload =
            r#"{"DeviceID":"abc","GWL":"1.00","TIME":"2026-10-03T01:33:45","BL":"--","SOL":""}"#;
        let reading = parse_wire_reading(payload).expect("parses");
        let battery = reading.battery_v.expect("battery present");
        assert_eq!(battery.text, "--");
        assert_eq!(battery.number(), None);
        let solar = reading.solar_v.expect("solar present");
        assert_eq!(solar.text, "");
        assert_eq!(solar.number(), None);
    }

    #[test]
    fn rejects_payloads_that_cannot_carry_a_water_measurement() {
        assert_eq!(parse_wire_reading("not json"), Err(WireError::NotJson));
        assert_eq!(parse_wire_reading("[1,2]"), Err(WireError::NotAnObject));
        assert_eq!(
            parse_wire_reading(r#"{"DeviceID":"a","TIME":"2026-10-03T01:33:45"}"#),
            Err(WireError::MissingLevel)
        );
        assert_eq!(
            parse_wire_reading(r#"{"DeviceID":"a","GWL":"high"}"#),
            Err(WireError::LevelNotNumeric)
        );
        assert_eq!(
            parse_wire_reading(r#"{"DeviceID":"a","GWL":"NaN"}"#),
            Err(WireError::LevelNotNumeric)
        );
        assert_eq!(
            parse_wire_reading(r#"{"DeviceID":"a","GWL":"inf"}"#),
            Err(WireError::LevelNotNumeric)
        );
        assert_eq!(
            parse_wire_reading(r#"{"DeviceID":"a","GWL":"2500.00"}"#),
            Err(WireError::LevelOutOfRange)
        );
    }

    #[test]
    fn accepts_negative_and_space_padded_levels() {
        let payload = r#"{"GWL":" -01.50 ","TIME":"2026-10-03T01:33:45"}"#;
        let reading = parse_wire_reading(payload).expect("parses");
        assert_eq!(reading.gwl.number(), Some(-1.5));
        // Text is evidence, whitespace included.
        assert_eq!(reading.gwl.text, " -01.50 ");
    }

    #[test]
    fn wire_error_codes_are_stable() {
        let codes: Vec<&str> = [
            WireError::NotJson,
            WireError::NotAnObject,
            WireError::MissingLevel,
            WireError::LevelNotNumeric,
            WireError::LevelOutOfRange,
        ]
        .iter()
        .map(|error| error.code())
        .collect();
        assert_eq!(
            codes,
            vec![
                "not-json",
                "not-a-json-object",
                "missing-gwl",
                "gwl-not-numeric",
                "gwl-out-of-range"
            ]
        );
    }
}
