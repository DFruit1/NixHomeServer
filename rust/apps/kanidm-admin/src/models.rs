use serde::Serialize;
use serde_json::Value;

use crate::{
    groups::{admin_intent_groups, filter_managed_group_names, login_groups},
    AppError,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonSummary {
    pub account_id: String,
    pub display_name: Option<String>,
    pub primary_email: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AccessGroups {
    pub all_managed: Vec<String>,
    pub login: Vec<String>,
    pub admin_intent: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonRecord {
    pub account_id: String,
    pub display_name: Option<String>,
    pub primary_email: Option<String>,
    pub spn: Option<String>,
    pub uuid: Option<String>,
    pub valid_from: Option<String>,
    pub expiry: Option<String>,
    pub access_groups: AccessGroups,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupSummary {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResetTokenSummary {
    pub raw_output: String,
    pub reset_url: Option<String>,
    pub token: Option<String>,
}

pub fn parse_person_list(value: &Value) -> Result<Vec<PersonSummary>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm person list did not return a JSON array".to_string(),
        details: serde_json::json!({ "value": value }),
    })?;

    let mut people = entries
        .iter()
        .filter_map(parse_person_summary)
        .collect::<Vec<_>>();
    people.sort_by(|left, right| left.account_id.cmp(&right.account_id));
    Ok(people)
}

pub fn parse_person_record(value: &Value, account_id_hint: &str) -> Result<PersonRecord, AppError> {
    let object = normalize_person_value(value).ok_or_else(|| AppError::UserNotFound {
        account_id: account_id_hint.to_string(),
    })?;
    let account_id = string_field(object, "name").ok_or_else(|| AppError::UserNotFound {
        account_id: account_id_hint.to_string(),
    })?;
    let groups = direct_member_of(object);
    let all_managed = filter_managed_group_names(groups.iter().map(String::as_str));

    Ok(PersonRecord {
        account_id,
        display_name: string_field(object, "displayname"),
        primary_email: string_field(object, "mail"),
        spn: string_field(object, "spn"),
        uuid: string_field(object, "uuid"),
        valid_from: string_field(object, "account_valid_from"),
        expiry: string_field(object, "account_expire"),
        access_groups: AccessGroups {
            login: login_groups(&all_managed),
            admin_intent: admin_intent_groups(&all_managed),
            all_managed,
        },
    })
}

fn parse_person_summary(value: &Value) -> Option<PersonSummary> {
    let object = normalize_person_value(value)?;
    let account_id = string_field(object, "name")?;
    Some(PersonSummary {
        account_id,
        display_name: string_field(object, "displayname"),
        primary_email: string_field(object, "mail"),
    })
}

fn normalize_person_value(value: &Value) -> Option<&Value> {
    match value {
        Value::Array(entries) => entries.first().and_then(normalize_person_value),
        Value::Object(map) => {
            if let Some(attrs) = map.get("attrs") {
                Some(attrs)
            } else {
                Some(value)
            }
        }
        _ => None,
    }
}

fn string_field(object: &Value, field: &str) -> Option<String> {
    let values = object.get(field)?;
    match values {
        Value::Array(entries) => entries
            .first()
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        Value::String(value) => Some(value.clone()),
        _ => None,
    }
}

fn direct_member_of(object: &Value) -> Vec<String> {
    let raw = object
        .get("directmemberof")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|value| value.split('@').next().unwrap_or(value).to_string())
        .collect::<Vec<_>>();
    filter_managed_group_names(raw.iter().map(String::as_str))
}

pub fn parse_group_list(value: &Value) -> Result<Vec<GroupSummary>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm group list did not return a JSON array".to_string(),
        details: serde_json::json!({ "value": value }),
    })?;

    let mut groups = entries
        .iter()
        .filter_map(|entry| {
            let object = normalize_person_value(entry)?;
            let name = string_field(object, "name")?;
            Some(GroupSummary {
                name,
                description: string_field(object, "description"),
            })
        })
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(groups)
}

pub fn parse_reset_token_summary(stdout: &str) -> ResetTokenSummary {
    let raw_output = stdout.trim().to_string();
    let reset_url = raw_output
        .split_whitespace()
        .find(|word| word.starts_with("https://") || word.starts_with("http://"))
        .map(trim_token_text);

    let token = raw_output.lines().find_map(|line| {
        let lower = line.to_lowercase();
        if !lower.contains("token") {
            return None;
        }

        if let Some((_, value)) = line.split_once(':') {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }

        None
    });

    ResetTokenSummary {
        raw_output,
        reset_url,
        token,
    }
}

fn trim_token_text(value: &str) -> String {
    value
        .trim_matches(|ch: char| matches!(ch, '"' | '\'' | ',' | '.' | ')' | '('))
        .to_string()
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

        assert_eq!(groups[0].name, "immich-users");
        assert_eq!(groups[1].name, "users");
    }

    #[test]
    fn parses_reset_token_output() {
        let summary = parse_reset_token_summary(
            "Reset token: abc123\nUse this link: https://id.example.test/ui/reset?token=abc123\n",
        );

        assert_eq!(summary.token.as_deref(), Some("abc123"));
        assert_eq!(
            summary.reset_url.as_deref(),
            Some("https://id.example.test/ui/reset?token=abc123")
        );
    }
}
