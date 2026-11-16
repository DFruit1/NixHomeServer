//! Protocol revision 2 logger settings: the `config/set` key table
//! (`docs/gwl-v1-rev2.md` §5) and the TLV encoding carried by settings
//! snapshots (Rev2 "Settings encoding (TLV)").
//!
//! Validation mirrors the contract so the operator learns about a bad value
//! before a week-long round trip to a sleeping logger. The logger validates
//! again and stays the authority; the server never assumes a request was
//! applied until the ack carries the effective settings.

use serde_json::{json, Map, Value};

pub const MAX_INTERVAL_S: i64 = 2_332_800;

/// Firmware defaults (contract table "Default" column).
pub fn defaults() -> Map<String, Value> {
    let value = json!({
        "read_s":3600,"send_s":604800,"gps_mode":0,"gps_val":0,"tilt_mode":0,"tilt_val":0,
        "start":0,"fac":[0.0,1.0,1.0,0.0],"tap":1,"tap_sens":5,"gps_sens":5,"lo":null,"hi":null,
        "lo_hys":0.0,"hi_hys":0.0,"loc":"","proj":"","text":"","partial":0,"utc_off":0,"led":0,
        "attempts":3,"listen_s":60
    });
    match value {
        Value::Object(map) => map,
        _ => unreachable!(),
    }
}

fn int(value: &Value, key: &str, min: i64, max: i64) -> Result<i64, String> {
    let number = value
        .as_i64()
        .filter(|n| (min..=max).contains(n))
        .ok_or_else(|| format!("{key} must be an integer in {min}..{max}"))?;
    Ok(number)
}

fn finite_f32(value: &Value, key: &str) -> Result<f64, String> {
    let number = value
        .as_f64()
        .filter(|n| n.is_finite() && n.abs() <= f64::from(f32::MAX))
        .ok_or_else(|| format!("{key} must be a finite number"))?;
    Ok(number)
}

fn text(value: &Value, key: &str, max: usize, newlines: usize) -> Result<(), String> {
    let text = value
        .as_str()
        .ok_or_else(|| format!("{key} must be a string"))?;
    if text.len() > max {
        return Err(format!("{key} is {} bytes, limit {max}", text.len()));
    }
    if text.matches('\n').count() > newlines {
        return Err(format!("{key} allows at most {newlines} newline(s)"));
    }
    if text.chars().any(|c| c.is_control() && c != '\n') {
        return Err(format!("{key} contains a control character"));
    }
    Ok(())
}

fn mode_pair(args: &Map<String, Value>, prefix: &str) -> Result<(), String> {
    let mode_key = format!("{prefix}_mode");
    let val_key = format!("{prefix}_val");
    let mode = args.get(&mode_key);
    let val = args.get(&val_key);
    match (mode, val) {
        (None, None) => Ok(()),
        (None, Some(_)) => Err(format!(
            "{val_key} needs {mode_key}: its range depends on the mode"
        )),
        (Some(mode), val) => {
            let mode = int(mode, &mode_key, 0, 3)?;
            match (mode, val) {
                (1, Some(v)) => int(v, &val_key, 1, 255).map(|_| ()),
                (2, Some(v)) => int(v, &val_key, 600, MAX_INTERVAL_S).map(|_| ()),
                (1 | 2, None) => Err(format!("{mode_key} {mode} requires {val_key}")),
                (_, Some(v)) => int(v, &val_key, 0, MAX_INTERVAL_S).map(|_| ()),
                (_, None) => Ok(()),
            }
        }
    }
}

/// Validates a `config/set` `args` object. Unknown keys are refused here
/// (the logger would report them `unsupported`); every value is checked
/// against the contract table. `now` bounds `start`.
pub fn validate(args: &Value, now: i64) -> Result<(), Vec<String>> {
    let Some(args) = args.as_object() else {
        return Err(vec!["settings must be a JSON object".into()]);
    };
    if args.is_empty() {
        return Err(vec!["settings must name at least one key".into()]);
    }
    let mut errors = Vec::new();
    let mut check = |result: Result<(), String>| {
        if let Err(error) = result {
            errors.push(error);
        }
    };
    for (key, value) in args {
        let result = match key.as_str() {
            "read_s" => int(value, key, 60, MAX_INTERVAL_S).map(|_| ()),
            "send_s" => int(value, key, 300, MAX_INTERVAL_S).map(|_| ()),
            "gps_mode" | "gps_val" | "tilt_mode" | "tilt_val" => Ok(()),
            "start" => int(value, key, 0, i64::from(u32::MAX)).and_then(|start| {
                if start != 0 && start <= now {
                    Err("start must be 0 (none) or a future UTC time".into())
                } else {
                    Ok(())
                }
            }),
            "fac" => match value.as_array() {
                Some(items) if items.len() == 4 => items
                    .iter()
                    .try_for_each(|item| finite_f32(item, "fac").map(|_| ())),
                _ => Err("fac must be [a,p,b,c]: four finite numbers".into()),
            },
            "tap" | "partial" | "led" => int(value, key, 0, 1).map(|_| ()),
            "tap_sens" => int(value, key, 1, 10).map(|_| ()),
            "gps_sens" => int(value, key, 0, 10).map(|_| ()),
            "lo" | "hi" => {
                if value.is_null() {
                    Ok(())
                } else {
                    finite_f32(value, key).map(|_| ())
                }
            }
            "lo_hys" | "hi_hys" => finite_f32(value, key).and_then(|v| {
                if v < 0.0 {
                    Err(format!("{key} must be ≥ 0"))
                } else {
                    Ok(())
                }
            }),
            "loc" | "proj" => text(value, key, 32, 0),
            "text" => text(value, key, 64, 1),
            "utc_off" => int(value, key, -720, 840).map(|_| ()),
            "attempts" => int(value, key, 1, 10).map(|_| ()),
            "listen_s" => int(value, key, 10, 600).map(|_| ()),
            other => Err(format!("{other} is not a contract setting")),
        };
        check(result);
    }
    check(mode_pair(args, "gps"));
    check(mode_pair(args, "tilt"));
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

/// A decoded TLV payload: the keys present plus anything unrecognised.
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedTlv {
    /// Only the tags present, keyed by contract name.
    pub present: Map<String, Value>,
    /// `{"0x16":"0A0B"}` for tags this server does not know.
    pub unknown: Map<String, Value>,
    pub warnings: Vec<String>,
}

impl DecodedTlv {
    /// Effective settings: defaults overlaid by the present tags.
    pub fn effective(&self) -> Value {
        let mut settings = defaults();
        for (key, value) in &self.present {
            settings.insert(key.clone(), value.clone());
        }
        if !self.unknown.is_empty() {
            settings.insert("unknown".into(), Value::Object(self.unknown.clone()));
        }
        Value::Object(settings)
    }
}

fn f32_value(bytes: &[u8]) -> Value {
    let value = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    if value.is_nan() {
        return Value::Null;
    }
    // Shortest round-trip text of the f32, so 12.345f32 reads as 12.345.
    format!("{value}")
        .parse::<f64>()
        .ok()
        .and_then(|v| serde_json::Number::from_f64(v).map(Value::Number))
        .unwrap_or(Value::Null)
}

fn uint(bytes: &[u8]) -> Option<u64> {
    match bytes.len() {
        1 => Some(u64::from(bytes[0])),
        2 => Some(u64::from(u16::from_le_bytes([bytes[0], bytes[1]]))),
        4 => Some(u64::from(u32::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3],
        ]))),
        _ => None,
    }
}

/// Decodes a TLV settings payload (tags ascending, each at most once).
pub fn decode_tlv(payload: &[u8]) -> DecodedTlv {
    let mut present = Map::new();
    let mut unknown = Map::new();
    let mut warnings = Vec::new();
    let mut at = 0;
    let mut last_tag: Option<u8> = None;
    while at < payload.len() {
        if at + 2 > payload.len() {
            warnings.push(format!("truncated TLV header at byte {at}"));
            break;
        }
        let tag = payload[at];
        let length = usize::from(payload[at + 1]);
        let Some(value) = payload.get(at + 2..at + 2 + length) else {
            warnings.push(format!("tag 0x{tag:02X} runs past the payload"));
            break;
        };
        at += 2 + length;
        if last_tag.is_some_and(|last| tag <= last) {
            warnings.push(format!("tag 0x{tag:02X} is out of order or repeated"));
        }
        last_tag = Some(tag);
        let bad = || format!("tag 0x{tag:02X} has length {length}");
        match tag {
            0x01 | 0x02 | 0x05 => match uint(value) {
                Some(v) => {
                    let key = match tag {
                        0x01 => "read_s",
                        0x02 => "send_s",
                        _ => "start",
                    };
                    present.insert(key.into(), json!(v));
                }
                None => warnings.push(bad()),
            },
            0x03 | 0x04 => {
                if length == 5 {
                    let prefix = if tag == 0x03 { "gps" } else { "tilt" };
                    present.insert(format!("{prefix}_mode"), json!(value[0]));
                    present.insert(
                        format!("{prefix}_val"),
                        json!(u32::from_le_bytes([value[1], value[2], value[3], value[4]])),
                    );
                } else {
                    warnings.push(bad());
                }
            }
            0x06 => {
                if length == 16 {
                    let factors: Vec<Value> = value.chunks(4).map(f32_value).collect();
                    present.insert("fac".into(), Value::Array(factors));
                } else {
                    warnings.push(bad());
                }
            }
            0x07 | 0x08 | 0x09 | 0x11 | 0x13 | 0x14 | 0x15 => match uint(value) {
                Some(v) => {
                    let key = match tag {
                        0x07 => "tap",
                        0x08 => "tap_sens",
                        0x09 => "gps_sens",
                        0x11 => "partial",
                        0x13 => "led",
                        0x14 => "attempts",
                        _ => "listen_s",
                    };
                    present.insert(key.into(), json!(v));
                }
                None => warnings.push(bad()),
            },
            0x0A..=0x0D => {
                if length == 4 {
                    let key = ["lo", "hi", "lo_hys", "hi_hys"][usize::from(tag - 0x0A)];
                    present.insert(key.into(), f32_value(value));
                } else {
                    warnings.push(bad());
                }
            }
            0x0E..=0x10 => {
                let key = ["loc", "proj", "text"][usize::from(tag - 0x0E)];
                match std::str::from_utf8(value) {
                    Ok(text) => {
                        present.insert(key.into(), json!(text));
                    }
                    Err(_) => warnings.push(format!("tag 0x{tag:02X} is not UTF-8")),
                }
            }
            0x12 => {
                if length == 2 {
                    present.insert(
                        "utc_off".into(),
                        json!(i16::from_le_bytes([value[0], value[1]])),
                    );
                } else {
                    warnings.push(bad());
                }
            }
            _ => {
                unknown.insert(
                    format!("0x{tag:02X}"),
                    json!(crate::stream::hex_encode(value)),
                );
            }
        }
    }
    DecodedTlv {
        present,
        unknown,
        warnings,
    }
}

/// Send interval from effective settings JSON, if present and sane.
pub fn send_interval_s(settings: &Value) -> Option<i64> {
    settings
        .get("send_s")
        .and_then(Value::as_i64)
        .filter(|v| (300..=MAX_INTERVAL_S).contains(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_763_300_000;

    #[test]
    fn contract_examples_are_valid() {
        assert!(validate(
            &json!({"read_s":900,"send_s":86400,"hi":10.5,"hi_hys":0.2}),
            NOW
        )
        .is_ok());
        assert!(validate(
            &json!({"gps_mode":2,"gps_val":3600,"tilt_mode":3,"fac":[0,1,1,0],"lo":null,
                "loc":"Bore 7","text":"line one\nline two","utc_off":600,"listen_s":120,
                "attempts":5,"led":1,"partial":0,"tap":1,"tap_sens":10,"gps_sens":0,"start":0}),
            NOW
        )
        .is_ok());
    }

    #[test]
    fn every_bound_is_enforced() {
        for (args, fragment) in [
            (json!({"read_s":59}), "read_s"),
            (json!({"read_s":2_332_801}), "read_s"),
            (json!({"read_s":900.5}), "read_s"),
            (json!({"send_s":299}), "send_s"),
            (json!({"gps_mode":4}), "gps_mode"),
            (json!({"gps_mode":1,"gps_val":0}), "gps_val"),
            (json!({"gps_mode":2,"gps_val":599}), "gps_val"),
            (json!({"gps_mode":1}), "requires gps_val"),
            (json!({"tilt_val":5}), "needs tilt_mode"),
            (json!({"start":NOW - 1}), "start"),
            (json!({"fac":[1,2,3]}), "fac"),
            (json!({"fac":[1,2,3,"x"]}), "fac"),
            (json!({"tap":2}), "tap"),
            (json!({"tap_sens":0}), "tap_sens"),
            (json!({"gps_sens":11}), "gps_sens"),
            (json!({"hi":"10"}), "hi"),
            (json!({"lo_hys":-0.1}), "lo_hys"),
            (json!({"loc":"x".repeat(33)}), "loc"),
            (json!({"proj":"a\nb"}), "proj"),
            (json!({"text":"a\nb\nc"}), "text"),
            (json!({"utc_off":-721}), "utc_off"),
            (json!({"attempts":11}), "attempts"),
            (json!({"listen_s":9}), "listen_s"),
            (json!({"foo":1}), "foo"),
        ] {
            let errors = validate(&args, NOW).expect_err(&args.to_string());
            assert!(
                errors.iter().any(|e| e.contains(fragment)),
                "{args}: {errors:?}"
            );
        }
        assert!(validate(&json!({}), NOW).is_err());
        assert!(validate(&json!([1]), NOW).is_err());
    }

    fn tlv(tag: u8, value: &[u8]) -> Vec<u8> {
        [&[tag, value.len() as u8][..], value].concat()
    }

    #[test]
    fn tlv_decodes_every_tag_and_fills_defaults() {
        let payload = [
            tlv(0x01, &900u32.to_le_bytes()),
            tlv(0x02, &86_400u32.to_le_bytes()),
            tlv(0x03, &[2, 0x10, 0x0E, 0, 0]),
            tlv(
                0x06,
                &[0.0f32, 1.0, 2.5, -0.25]
                    .iter()
                    .flat_map(|v| v.to_le_bytes())
                    .collect::<Vec<_>>(),
            ),
            tlv(0x0A, &f32::NAN.to_le_bytes()),
            tlv(0x0B, &10.5f32.to_le_bytes()),
            tlv(0x0D, &0.2f32.to_le_bytes()),
            tlv(0x0E, b"Bore 7"),
            tlv(0x12, &(-300i16).to_le_bytes()),
            tlv(0x15, &120u16.to_le_bytes()),
            tlv(0x30, &[1, 2]),
        ]
        .concat();
        let decoded = decode_tlv(&payload);
        assert!(decoded.warnings.is_empty(), "{:?}", decoded.warnings);
        let settings = decoded.effective();
        assert_eq!(settings["read_s"], 900);
        assert_eq!(settings["gps_mode"], 2);
        assert_eq!(settings["gps_val"], 3600);
        assert_eq!(settings["fac"], json!([0.0, 1.0, 2.5, -0.25]));
        assert_eq!(settings["lo"], Value::Null);
        assert_eq!(settings["hi"], 10.5);
        assert_eq!(settings["hi_hys"], 0.2);
        assert_eq!(settings["loc"], "Bore 7");
        assert_eq!(settings["utc_off"], -300);
        assert_eq!(settings["listen_s"], 120);
        // Defaults for missing tags.
        assert_eq!(settings["tap_sens"], 5);
        assert_eq!(settings["attempts"], 3);
        assert_eq!(settings["unknown"]["0x30"], "0102");
        assert_eq!(send_interval_s(&settings), Some(86_400));
        assert!(validate(
            &Value::Object(
                decoded
                    .present
                    .into_iter()
                    .filter(|(k, _)| k != "start")
                    .collect()
            ),
            NOW
        )
        .is_ok());
    }

    #[test]
    fn malformed_tlv_reports_instead_of_panicking() {
        let decoded = decode_tlv(&[0x02, 0x04, 1, 2, 0x01]);
        assert!(!decoded.warnings.is_empty());
        let decoded = decode_tlv(&[0x02, 0x03, 1, 2, 3, 0x01, 0x04, 1, 0, 0, 0]);
        assert!(decoded.warnings.iter().any(|w| w.contains("0x02")));
        assert!(decoded.warnings.iter().any(|w| w.contains("order")));
    }
}
