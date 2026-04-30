use serde::Serialize;
use serde_json::{json, Value};

use crate::AppError;

use super::policy::{extract_policy_snapshot, GroupPolicySnapshot};
use super::{
    dedup_sort, normalize_list_object, normalize_record_object, optional_string_field,
    required_string_field, Parsed,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupSummary {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupRecord {
    pub name: String,
    pub description: Option<String>,
    pub members: Vec<String>,
    pub policy: GroupPolicySnapshot,
}

pub fn parse_group_list(value: &Value) -> Result<Parsed<Vec<GroupSummary>>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm group list did not return a JSON array".to_string(),
        details: json!({ "value": value }),
    })?;

    let mut groups = Vec::new();
    let mut warnings = Vec::new();

    for (index, entry) in entries.iter().enumerate() {
        let Some(object) = normalize_list_object(entry) else {
            warnings.push(format!(
                "skipped malformed Kanidm group list entry at index {index}: entry was not an object or attrs object"
            ));
            continue;
        };

        let Some(name) = object.get("name").and_then(super::string_like) else {
            warnings.push(format!(
                "skipped malformed Kanidm group list entry at index {index}: missing string field 'name'"
            ));
            continue;
        };

        groups.push(GroupSummary {
            name,
            description: object.get("description").and_then(super::string_like),
        });
    }

    groups.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(Parsed {
        value: groups,
        warnings,
    })
}

pub fn parse_group_record(
    value: &Value,
    group_hint: &str,
) -> Result<Parsed<GroupRecord>, AppError> {
    let mut warnings = Vec::new();
    let object = normalize_record_object(value, "group", group_hint, &mut warnings)?;
    let name = required_string_field(object, "group", "name", group_hint)?;

    Ok(Parsed {
        value: GroupRecord {
            name,
            description: optional_string_field(object, "description", &mut warnings),
            members: parse_members(object.get("member"), &mut warnings),
            policy: extract_policy_snapshot(value),
        },
        warnings,
    })
}

pub fn parse_group_members(
    value: &Value,
    group_hint: &str,
) -> Result<Parsed<Vec<String>>, AppError> {
    if let Ok(group) = parse_group_record(value, group_hint) {
        return Ok(Parsed {
            value: group.value.members,
            warnings: group.warnings,
        });
    }

    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: format!("kanidm group members for '{group_hint}' did not return a JSON array"),
        details: json!({ "value": value }),
    })?;

    let mut members = Vec::new();
    let mut warnings = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        let Some(object) = normalize_list_object(entry) else {
            warnings.push(format!(
                "skipped malformed Kanidm group member entry at index {index}: entry was not an object or attrs object"
            ));
            continue;
        };
        let Some(name) = object.get("name").and_then(super::string_like) else {
            warnings.push(format!(
                "skipped malformed Kanidm group member entry at index {index}: missing string field 'name'"
            ));
            continue;
        };
        members.push(name);
    }

    dedup_sort(&mut members);
    Ok(Parsed {
        value: members,
        warnings,
    })
}

fn parse_members(value: Option<&Value>, warnings: &mut Vec<String>) -> Vec<String> {
    let mut members = match value {
        Some(Value::Array(entries)) => entries
            .iter()
            .filter_map(Value::as_str)
            .map(|value| value.split('@').next().unwrap_or(value).to_string())
            .collect::<Vec<_>>(),
        Some(other) => {
            warnings.push(format!(
                "ignored non-array 'member' field while parsing a group record: {other}"
            ));
            Vec::new()
        }
        None => Vec::new(),
    };
    dedup_sort(&mut members);
    members
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn parses_group_list() {
        let groups = parse_group_list(&json!([
            { "attrs": { "name": ["users"], "description": ["Baseline identity only."] } },
            { "attrs": { "name": ["immich-users"], "description": ["Photos login."] } }
        ]))
        .expect("group list");

        assert_eq!(groups.value[0].name, "immich-users");
        assert_eq!(groups.value[1].name, "users");
        assert!(groups.warnings.is_empty());
    }
}
