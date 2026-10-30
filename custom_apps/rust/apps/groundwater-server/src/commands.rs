//! Wire contracts checked against firmware 8278b61, flash_config.c and
//! danger_commands.c. Keep spellings (including Get_debuging) literal.
use serde_json::{json, Value};

pub const PROJECT_KEYS: [&str; 11] = [
    "NA", "l", "id", "lf", "sf", "fac", "fst", "mG", "MG", "S", "ltost",
];
pub const CFG_KEYS: [&str; 9] = [
    "Flush_mqtt",
    "Flush_sd",
    "Self_test",
    "Get_debuging",
    "Get_Status",
    "Fetch_File_List",
    "Fetch_File_Chunk",
    "CLEAR_ERROR_LATCH",
    "Disable_Logging",
];
pub const DANGER_KEYS: [&str; 6] = [
    "Factory reset",
    "Wipe_MRAM",
    "Wipe_sd",
    "Disable Logging",
    "Reboot",
    "Erase keys",
];

/// Most V2.x handlers only printf/TODO, despite acknowledging receipt. Keep
/// this display contract aligned with groundwater_command_supported in SQL.
pub fn capabilities(profile: &str, policy: &str, offset: Option<i32>, unverified: bool) -> Value {
    let known = matches!(profile, "V21" | "V20" | "ML");
    let clock = policy == "utc"
        || (policy == "local-offset" && offset.is_some_and(|n| (0..1440).contains(&n)));
    json!({"test":known,"project_settings":known && clock && !unverified,
        "cfg_keys":[],"danger_commands":if matches!(profile,"V21"|"V20"){vec!["Reboot"]}else{vec![]}})
}

/// Construct in explicit order; serde's sorted-map order puts `lf` before `l`.
/// Simulate Extract_Value's unanchored strstr, including its fixed +3 skip.
pub fn project_payload(config: &Value) -> Result<String, String> {
    let object = config.as_object().ok_or("config must be an object")?;
    if object.len() != PROJECT_KEYS.len() || PROJECT_KEYS.iter().any(|k| !object.contains_key(*k)) {
        return Err("config requires exactly NA,l,id,lf,sf,fac,fst,mG,MG,S,ltost".into());
    }
    let mut values = Vec::new();
    for key in PROJECT_KEYS {
        let value = config[key]
            .as_str()
            .ok_or_else(|| format!("{key} must be a string"))?;
        if value.is_empty()
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._,:-".contains(&b))
        {
            return Err(format!("{key} contains unsafe characters"));
        }
        values.push(value);
    }
    integer(values[0], 1, 255, "NA")?;
    if values[1].len() > 9 || values[2].len() > 12 {
        return Err("l/id exceed 9/12 bytes".into());
    }
    hm(values[3], 3, "lf")?;
    hm(values[4], 5, "sf")?;
    hm(values[10], 0, "ltost")?;
    let factors: Vec<_> = values[5].split(',').collect();
    if factors.len() != 4 {
        return Err("fac requires four decimal coefficients".into());
    }
    for factor in factors {
        let (whole, fraction) = factor
            .split_once('.')
            .ok_or("fac requires a.p,b.p,c.p,d.p")?;
        integer(whole, -32768, 32767, "fac")?;
        integer(fraction, 0, 99, "fac fraction")?;
        if fraction.len() != 2 {
            return Err("fac fractions require two digits (firmware divides by 100)".into());
        }
        // C adds the unsigned fractional part to the signed integer. -0.25
        // would become +0.25; reject rather than silently changing calibration.
        if whole.starts_with('-') && fraction != "00" {
            return Err(
                "negative fac coefficients must have .00 (firmware sign limitation)".into(),
            );
        }
    }
    if values[6].len() != 19
        || chrono::NaiveDateTime::parse_from_str(values[6], "%Y-%m-%dT%H:%M:%S").is_err()
        || !values[6].starts_with("20")
    {
        return Err("fst must be a valid 20YY-MM-DDTHH:MM:SS".into());
    }
    let low = integer(values[7], -1000, 1000, "mG")?;
    let high = integer(values[8], -1000, 1000, "MG")?;
    if low >= high {
        return Err("mG must be below MG".into());
    }
    if values[9].len() != 4 || !values[9].bytes().all(|b| b == b'0' || b == b'1') {
        return Err("S requires four binary flags".into());
    }
    let wire = format!(
        "{{{}}}",
        PROJECT_KEYS
            .iter()
            .zip(&values)
            .map(|(k, v)| format!("\"{k}\":\"{v}\""))
            .collect::<Vec<_>>()
            .join(",")
    );
    if wire.len() > 150 {
        return Err(format!(
            "project settings exceed 150 bytes ({})",
            wire.len()
        ));
    }
    for (key, expected) in PROJECT_KEYS.iter().zip(values) {
        let start = wire.find(key).ok_or("missing firmware key")? + key.len() + 3;
        let actual = wire.get(start..).and_then(|s| s.split('"').next());
        if actual != Some(expected) {
            return Err(format!(
                "value contains a key substring that hijacks firmware extraction of {key}"
            ));
        }
    }
    Ok(wire)
}

fn integer(text: &str, min: i32, max: i32, key: &str) -> Result<i32, String> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let value = text.parse::<i32>().ok().filter(|v| (min..=max).contains(v));
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) || value.is_none() {
        return Err(format!("{key} must be an integer in {min}..{max}"));
    }
    Ok(value.unwrap())
}

fn hm(text: &str, min_minutes: i32, key: &str) -> Result<(), String> {
    let (h, m) = text
        .split_once(':')
        .ok_or_else(|| format!("{key} requires H:M"))?;
    let h = integer(h, 0, 23, key)?;
    let m = integer(m, 0, 59, key)?;
    if h * 60 + m < min_minutes {
        return Err(format!("{key} minimum is {min_minutes} minutes"));
    }
    Ok(())
}

/// Return the audit JSON and exact, compact wire payload. Danger commands in
/// this firmware are JSON boolean strings, even when the API accepts a name.
pub fn command_payload(
    kind: &str,
    payload: &Value,
    confirm: Option<&str>,
) -> Result<(Value, String), String> {
    let normalized = match kind {
        "cfg" => {
            validate_flags(payload, &CFG_KEYS)?;
            payload.clone()
        }
        "danger" => {
            if confirm != Some("DANGER") {
                return Err("type DANGER to confirm this command".into());
            }
            let value = if let Some(name) = payload.as_str() {
                if !DANGER_KEYS.contains(&name) {
                    return Err("unknown danger command".into());
                }
                json!({name:"1"})
            } else {
                payload.clone()
            };
            validate_flags(&value, &DANGER_KEYS)?;
            if !value.as_object().unwrap().values().any(|v| v == "1") {
                return Err("danger command must enable an action".into());
            }
            value
        }
        "test" if payload.as_object().is_some_and(|v| v.is_empty()) => payload.clone(),
        _ => return Err("kind must be cfg, test or danger (test payload is {})".into()),
    };
    let wire = if kind == "test" {
        "test".into()
    } else {
        normalized.to_string()
    };
    if wire.len() > 150 {
        return Err("command exceeds 150 bytes".into());
    }
    Ok((normalized, wire))
}

fn validate_flags(payload: &Value, keys: &[&str]) -> Result<(), String> {
    let object = payload
        .as_object()
        .filter(|o| !o.is_empty())
        .ok_or("payload must be a nonempty object")?;
    if object
        .iter()
        .any(|(k, v)| !keys.contains(&k.as_str()) || !matches!(v.as_str(), Some("0" | "1")))
    {
        return Err(format!(
            "only firmware keys {} with string values 0 or 1 are accepted",
            keys.join(",")
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    pub fn config() -> Value {
        json!({"NA":"3","l":"A1","id":"B1","lf":"0:3","sf":"0:9","fac":"1.00,1.00,0.00,0.00","fst":"2026-10-01T00:00:00","mG":"0","MG":"9","S":"0101","ltost":"5:0"})
    }
    #[test]
    fn builder_matches_firmware_extractor_and_limits() {
        let wire = project_payload(&config()).unwrap();
        assert!(wire.len() <= 150);
        for key in PROJECT_KEYS {
            let pos = wire.find(key).unwrap() + key.len() + 3;
            let extracted = wire[pos..].split('"').next().unwrap();
            assert_eq!(Some(extracted), config()[key].as_str(), "{key}");
        }
    }
    #[test]
    fn refuses_partial_unsafe_or_malformed_project_config() {
        for (key, value) in [
            ("l", "S"),
            ("id", "too-long-sensor"),
            ("lf", "0:2"),
            ("sf", "0:4"),
            ("fac", "1.5,1,0,0"),
            ("fst", "2026-02-30T00:00:00"),
            ("mG", "1.2"),
            ("ltost", "-5:0"),
            ("S", "101"),
        ] {
            let mut cfg = config();
            cfg[key] = json!(value);
            assert!(project_payload(&cfg).is_err(), "{key}={value}");
        }
        let mut cfg = config();
        cfg.as_object_mut().unwrap().remove("NA");
        assert!(project_payload(&cfg).is_err());
    }
    #[test]
    fn incremental_and_danger_commands_use_real_firmware_keys() {
        assert!(command_payload("cfg", &json!({"Flush_mqtt":"1"}), None).is_ok());
        assert!(command_payload("cfg", &json!({"Get_debugging":"1"}), None).is_err());
        assert!(command_payload("cfg", &json!({"Self_test":true}), None).is_err());
        assert!(command_payload("danger", &json!("Reboot"), None).is_err());
        assert_eq!(
            command_payload("danger", &json!("Reboot"), Some("DANGER"))
                .unwrap()
                .0,
            json!({"Reboot":"1"})
        );
        assert!(command_payload("test", &json!({}), None).is_ok());
    }
}
