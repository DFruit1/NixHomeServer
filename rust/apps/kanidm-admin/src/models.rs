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
    pub uuid: Option<String>,
    pub access_groups: AccessGroups,
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
        uuid: string_field(object, "uuid"),
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
