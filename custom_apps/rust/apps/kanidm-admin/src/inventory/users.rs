use serde::Serialize;
use serde_json::{json, Value};

use crate::AppError;

use super::{
    dedup_sort, normalize_list_object, normalize_record_object, optional_string_field,
    required_string_field, Parsed,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserSummary {
    pub account_id: String,
    pub display_name: Option<String>,
    pub primary_email: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserRecord {
    pub account_id: String,
    pub display_name: Option<String>,
    pub primary_email: Option<String>,
    pub spn: Option<String>,
    pub uuid: Option<String>,
    pub valid_from: Option<String>,
    pub expiry: Option<String>,
    pub groups: Vec<String>,
}

pub fn parse_user_list(value: &Value) -> Result<Parsed<Vec<UserSummary>>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm person list did not return a JSON array".to_string(),
        details: json!({ "value": value }),
    })?;

    let mut people = Vec::new();
    let mut warnings = Vec::new();

    for (index, entry) in entries.iter().enumerate() {
        match parse_user_summary(entry) {
            Ok(summary) => people.push(summary),
            Err(reason) => warnings.push(format!(
                "skipped malformed Kanidm person list entry at index {index}: {reason}"
            )),
        }
    }

    people.sort_by(|left, right| left.account_id.cmp(&right.account_id));
    Ok(Parsed {
        value: people,
        warnings,
    })
}

pub fn parse_user_record(
    value: &Value,
    account_id_hint: &str,
) -> Result<Parsed<UserRecord>, AppError> {
    let mut warnings = Vec::new();
    let object = normalize_record_object(value, "user", account_id_hint, &mut warnings)?;
    let account_id = required_string_field(object, "user", "name", account_id_hint)?;
    let groups = parse_groups(object.get("directmemberof"), &mut warnings);

    Ok(Parsed {
        value: UserRecord {
            account_id,
            display_name: optional_string_field(object, "displayname", &mut warnings),
            primary_email: optional_string_field(object, "mail", &mut warnings),
            spn: optional_string_field(object, "spn", &mut warnings),
            uuid: optional_string_field(object, "uuid", &mut warnings),
            valid_from: optional_string_field(object, "account_valid_from", &mut warnings),
            expiry: optional_string_field(object, "account_expire", &mut warnings),
            groups,
        },
        warnings,
    })
}

fn parse_user_summary(value: &Value) -> Result<UserSummary, String> {
    let object = normalize_list_object(value)
        .ok_or_else(|| "entry was not an object or attrs object".to_string())?;
    let account_id = object
        .get("name")
        .and_then(super::string_like)
        .ok_or_else(|| "missing string field 'name'".to_string())?;

    Ok(UserSummary {
        account_id,
        display_name: object.get("displayname").and_then(super::string_like),
        primary_email: object.get("mail").and_then(super::string_like),
    })
}

fn parse_groups(value: Option<&Value>, warnings: &mut Vec<String>) -> Vec<String> {
    let mut groups = match value {
        Some(Value::Array(entries)) => entries
            .iter()
            .filter_map(Value::as_str)
            .map(|value| value.split('@').next().unwrap_or(value).to_string())
            .collect::<Vec<_>>(),
        Some(other) => {
            warnings.push(format!(
                "ignored non-array 'directmemberof' field while parsing a user record: {other}"
            ));
            Vec::new()
        }
        None => Vec::new(),
    };

    dedup_sort(&mut groups);
    groups
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn warns_when_person_list_entries_are_malformed() {
        let parsed = parse_user_list(&json!([
            { "attrs": { "name": ["dsaw"], "displayname": ["Dan"] } },
            { "attrs": { "displayname": ["Missing Name"] } }
        ]))
        .expect("person list");

        assert_eq!(parsed.value.len(), 1);
        assert_eq!(parsed.warnings.len(), 1);
    }

    #[test]
    fn parses_user_groups_without_hardcoded_filtering() {
        let parsed = parse_user_record(
            &json!({
                "attrs": {
                    "name": ["dsaw"],
                    "directmemberof": ["idm_admins@example.test", "paperless-users@example.test"]
                }
            }),
            "dsaw",
        )
        .expect("user");

        assert_eq!(
            parsed.value.groups,
            vec!["idm_admins".to_string(), "paperless-users".to_string()]
        );
    }
}
