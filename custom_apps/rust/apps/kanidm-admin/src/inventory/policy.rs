use serde::Serialize;
use serde_json::Value;

use super::{normalized_key, walk_object_fields};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Default)]
pub struct GroupPolicySnapshot {
    pub auth_expiry_seconds: Option<u64>,
    pub privilege_expiry_seconds: Option<u64>,
}

pub fn extract_policy_snapshot(value: &Value) -> GroupPolicySnapshot {
    GroupPolicySnapshot {
        auth_expiry_seconds: find_policy_number(value, PolicyField::AuthExpiry),
        privilege_expiry_seconds: find_policy_number(value, PolicyField::PrivilegeExpiry),
    }
}

pub fn matches_policy_value(value: &Value, field: PolicyField, expected: Option<u64>) -> bool {
    find_policy_number(value, field) == expected
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyField {
    AuthExpiry,
    PrivilegeExpiry,
}

fn find_policy_number(value: &Value, field: PolicyField) -> Option<u64> {
    let mut matched = None;
    walk_object_fields(value, &mut |key, entry| {
        if matched.is_some() {
            return;
        }
        let key = normalized_key(key);
        let is_match = match field {
            PolicyField::AuthExpiry => {
                key.contains("auth") && key.contains("expiry") && !key.contains("privilege")
            }
            PolicyField::PrivilegeExpiry => key.contains("privilege") && key.contains("expiry"),
        };
        if is_match {
            matched = value_to_u64(entry);
        }
    });
    matched
}

fn value_to_u64(value: &Value) -> Option<u64> {
    match value {
        Value::Number(value) => value.as_u64(),
        Value::String(value) => value.parse::<u64>().ok(),
        Value::Array(entries) => entries.first().and_then(value_to_u64),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn extracts_policy_values_from_live_like_json() {
        let snapshot = extract_policy_snapshot(&json!({
            "attrs": {
                "auth_expiry": ["3600"],
                "privilege_expiry": [900]
            }
        }));

        assert_eq!(snapshot.auth_expiry_seconds, Some(3600));
        assert_eq!(snapshot.privilege_expiry_seconds, Some(900));
    }
}
