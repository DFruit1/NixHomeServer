//! Structured firmware acknowledgments on the `gwl/v1` contract.
//!
//! Legacy firmware echoes a `cfg` payload, sends the fixed text
//! `Danger Acknowledge`, and never acknowledges project settings or Reboot.
//! V2.1 firmware on `gwl/v1` topics instead reports what it actually did:
//!
//! ```text
//! config/applied  {"kind":"project-settings","status":"ok"}
//! config/applied  {"kind":"cfg","status":"failed","results":{"Get_Status":"unsupported"}}
//! cmd/ack         {"kind":"danger","status":"ok","results":{"Reboot":"ok"}}
//! cmd/ack         {"kind":"danger","status":"rejected","reason":"no-action"}
//! ```
//!
//! `status` is `ok` (everything requested was done), `partial`, `failed`
//! (nothing was done) or `rejected` (the payload was not accepted). Each
//! `results` value is `ok`, `unsupported` or `failed`. Reboot reports `ok`
//! just before the logger resets.
use serde_json::{Map, Value};

pub const STATUSES: [&str; 4] = ["ok", "partial", "failed", "rejected"];

/// The command kind a structured acknowledgment confirms, if `ack` is one
/// and arrived on the `gwl/v1` channel that carries that kind.
pub fn structured_kind(channel: Option<&str>, ack: &Value) -> Option<&'static str> {
    let object = ack.as_object()?;
    let status = object.get("status")?.as_str()?;
    if !STATUSES.contains(&status) {
        return None;
    }
    let kind = match (channel?, object.get("kind")?.as_str()?) {
        ("config/applied", "project-settings") => "project-settings",
        ("config/applied", "cfg") => "cfg",
        ("cmd/ack", "danger") => "danger",
        _ => return None,
    };
    if let Some(results) = object.get("results") {
        let results = results.as_object()?;
        if results.values().any(|r| r.as_str().is_none()) {
            return None;
        }
    }
    Some(kind)
}

/// Whether the logger reports that it stored and applied project settings.
pub fn settings_applied(ack: &Value) -> bool {
    ack.get("kind").and_then(Value::as_str) == Some("project-settings")
        && ack.get("status").and_then(Value::as_str) == Some("ok")
}

/// The toggles to merge into `applied_config` once `ack` confirms the
/// `requested` cfg command. A legacy echo is the applied state itself. A
/// structured ack applies only the requested keys it reports as `ok`.
pub fn applied_cfg(requested: &Value, ack: &Value) -> Value {
    let Some(results) = ack.get("results").and_then(Value::as_object) else {
        if ack.get("kind").is_some() {
            return Value::Object(Map::new());
        }
        return ack.clone();
    };
    let applied = results
        .iter()
        .filter(|(_, result)| result.as_str() == Some("ok"))
        .filter_map(|(key, _)| Some((key.clone(), requested.get(key)?.clone())))
        .collect();
    Value::Object(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn structured_acks_are_recognised_only_on_their_v1_channel() {
        let settings = json!({"kind":"project-settings","status":"ok"});
        let cfg = json!({"kind":"cfg","status":"partial","results":{"Get_Status":"ok"}});
        let danger = json!({"kind":"danger","status":"ok","results":{"Reboot":"ok"}});
        assert_eq!(
            structured_kind(Some("config/applied"), &settings),
            Some("project-settings")
        );
        assert_eq!(structured_kind(Some("config/applied"), &cfg), Some("cfg"));
        assert_eq!(structured_kind(Some("cmd/ack"), &danger), Some("danger"));
        // A kind on the other channel, or on a legacy topic, is not an ack.
        assert_eq!(structured_kind(Some("cmd/ack"), &cfg), None);
        assert_eq!(structured_kind(Some("config/applied"), &danger), None);
        assert_eq!(structured_kind(None, &settings), None);
    }

    #[test]
    fn legacy_echoes_and_malformed_acks_are_not_structured() {
        for ack in [
            json!({"Get_Status":"1"}),
            json!("Danger Acknowledge"),
            json!({"kind":"cfg"}),
            json!({"kind":"cfg","status":"done"}),
            json!({"kind":"cfg","status":"ok","results":["Get_Status"]}),
            json!({"kind":"cfg","status":"ok","results":{"Get_Status":1}}),
        ] {
            assert_eq!(structured_kind(Some("config/applied"), &ack), None, "{ack}");
        }
    }

    #[test]
    fn only_an_ok_settings_ack_applies_settings() {
        assert!(settings_applied(
            &json!({"kind":"project-settings","status":"ok"})
        ));
        assert!(!settings_applied(
            &json!({"kind":"project-settings","status":"rejected","reason":"too-long"})
        ));
        assert!(!settings_applied(
            &json!({"kind":"project-settings","status":"failed"})
        ));
        assert!(!settings_applied(&json!({"Get_Status":"1"})));
    }

    #[test]
    fn cfg_applies_requested_values_only_for_ok_results() {
        let requested = json!({"Get_Status":"1","Flush_sd":"0","Flush_mqtt":"1"});
        let ack = json!({"kind":"cfg","status":"partial","results":{
            "Get_Status":"ok","Flush_sd":"unsupported","Flush_mqtt":"failed","Self_test":"ok"}});
        // Self_test was not requested, so its value is unknown: skip it.
        assert_eq!(applied_cfg(&requested, &ack), json!({"Get_Status":"1"}));
        let rejected = json!({"kind":"cfg","status":"rejected","reason":"not-json"});
        assert_eq!(applied_cfg(&requested, &rejected), json!({}));
        // Legacy firmware echoes the applied toggles.
        let echo = json!({"Get_Status":"1"});
        assert_eq!(applied_cfg(&echo, &echo), echo);
    }
}
