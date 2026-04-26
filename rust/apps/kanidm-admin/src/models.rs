use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    groups::{admin_intent_groups, filter_managed_group_names, login_groups},
    AppError,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Parsed<T> {
    pub value: T,
    pub warnings: Vec<String>,
}

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

pub fn parse_person_list(value: &Value) -> Result<Parsed<Vec<PersonSummary>>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm person list did not return a JSON array".to_string(),
        details: json!({ "value": value }),
    })?;

    let mut people = Vec::new();
    let mut warnings = Vec::new();

    for (index, entry) in entries.iter().enumerate() {
        match parse_person_summary(entry) {
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

pub fn parse_person_record(
    value: &Value,
    account_id_hint: &str,
) -> Result<Parsed<PersonRecord>, AppError> {
    let mut warnings = Vec::new();
    let object = normalize_record_object(value, account_id_hint, &mut warnings)?;
    let account_id = required_string_field(object, "name", account_id_hint)?;
    let all_managed = direct_member_of(object, &mut warnings);

    Ok(Parsed {
        value: PersonRecord {
            account_id,
            display_name: optional_string_field(object, "displayname", &mut warnings),
            primary_email: optional_string_field(object, "mail", &mut warnings),
            spn: optional_string_field(object, "spn", &mut warnings),
            uuid: optional_string_field(object, "uuid", &mut warnings),
            valid_from: optional_string_field(object, "account_valid_from", &mut warnings),
            expiry: optional_string_field(object, "account_expire", &mut warnings),
            access_groups: AccessGroups {
                login: login_groups(&all_managed),
                admin_intent: admin_intent_groups(&all_managed),
                all_managed,
            },
        },
        warnings,
    })
}

fn parse_person_summary(value: &Value) -> Result<PersonSummary, String> {
    let object = normalize_list_object(value)
        .ok_or_else(|| "entry was not an object or attrs object".to_string())?;
    let account_id = list_string_field(object, "name")
        .ok_or_else(|| "missing string field 'name'".to_string())?;

    Ok(PersonSummary {
        account_id,
        display_name: list_string_field(object, "displayname"),
        primary_email: list_string_field(object, "mail"),
    })
}

fn normalize_list_object(value: &Value) -> Option<&Value> {
    match value {
        Value::Object(map) => map.get("attrs").unwrap_or(value).as_object().map(|_| {
            if let Some(attrs) = map.get("attrs") {
                attrs
            } else {
                value
            }
        }),
        _ => None,
    }
}

fn normalize_record_object<'a>(
    value: &'a Value,
    account_id_hint: &str,
    warnings: &mut Vec<String>,
) -> Result<&'a Value, AppError> {
    match value {
        Value::Array(entries) => match entries.as_slice() {
            [] => Err(AppError::UserNotFound {
                account_id: account_id_hint.to_string(),
                details: json!({
                    "source": "empty_json_array",
                    "value": value,
                }),
            }),
            [entry] => normalize_record_object(entry, account_id_hint, warnings),
            _ => Err(AppError::Verification {
                message: format!(
                    "expected one Kanidm person record for '{account_id_hint}', but received {} records",
                    entries.len()
                ),
                details: json!({ "value": value }),
            }),
        },
        Value::Object(map) => {
            if let Some(attrs) = map.get("attrs") {
                if attrs.is_object() {
                    Ok(attrs)
                } else {
                    Err(AppError::Json {
                        message: format!(
                            "Kanidm person record for '{account_id_hint}' contained a non-object 'attrs' field"
                        ),
                        details: json!({ "value": value }),
                    })
                }
            } else if value.is_object() {
                warnings.push(format!(
                    "Kanidm person record for '{account_id_hint}' did not contain 'attrs'; parsed the top-level object instead"
                ));
                Ok(value)
            } else {
                Err(AppError::Json {
                    message: format!(
                        "Kanidm person record for '{account_id_hint}' did not contain a JSON object"
                    ),
                    details: json!({ "value": value }),
                })
            }
        }
        _ => Err(AppError::Json {
            message: format!(
                "Kanidm person record for '{account_id_hint}' was not a JSON object"
            ),
            details: json!({ "value": value }),
        }),
    }
}

fn required_string_field(
    object: &Value,
    field: &str,
    account_id_hint: &str,
) -> Result<String, AppError> {
    optional_string_field(object, field, &mut Vec::new()).ok_or_else(|| AppError::Json {
        message: format!(
            "Kanidm person record for '{account_id_hint}' did not contain required string field '{field}'"
        ),
        details: json!({ "value": object }),
    })
}

fn optional_string_field(
    object: &Value,
    field: &str,
    warnings: &mut Vec<String>,
) -> Option<String> {
    let values = object.get(field)?;
    match values {
        Value::Array(entries) => entries
            .first()
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        Value::String(value) => Some(value.clone()),
        _ => {
            warnings.push(format!(
                "ignored non-string Kanidm field '{field}' while parsing a person record"
            ));
            None
        }
    }
}

fn list_string_field(object: &Value, field: &str) -> Option<String> {
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

fn direct_member_of(object: &Value, warnings: &mut Vec<String>) -> Vec<String> {
    match object.get("directmemberof") {
        Some(Value::Array(entries)) => {
            let raw = entries
                .iter()
                .filter_map(Value::as_str)
                .map(|value| value.split('@').next().unwrap_or(value).to_string())
                .collect::<Vec<_>>();
            if entries.iter().any(|entry| !entry.is_string()) {
                warnings.push(
                    "ignored one or more non-string entries in 'directmemberof' while parsing a person record"
                        .to_string(),
                );
            }
            filter_managed_group_names(raw.iter().map(String::as_str))
        }
        Some(other) => {
            warnings.push(format!(
                "ignored non-array 'directmemberof' field while parsing a person record: {other}"
            ));
            Vec::new()
        }
        None => Vec::new(),
    }
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

        let Some(name) = list_string_field(object, "name") else {
            warnings.push(format!(
                "skipped malformed Kanidm group list entry at index {index}: missing string field 'name'"
            ));
            continue;
        };

        groups.push(GroupSummary {
            name,
            description: list_string_field(object, "description"),
        });
    }

    groups.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(Parsed {
        value: groups,
        warnings,
    })
}

pub fn parse_reset_token_summary(stdout: &str) -> Parsed<ResetTokenSummary> {
    let raw_output = stdout.trim().to_string();
    let url_candidates = raw_output
        .split_whitespace()
        .filter(|word| word.starts_with("https://") || word.starts_with("http://"))
        .map(trim_token_text)
        .collect::<Vec<_>>();

    let token_candidates = raw_output
        .lines()
        .filter_map(|line| {
            if let Some((_, value)) = line.split_once(':') {
                let label = line
                    .split_once(':')
                    .map(|(label, _)| label.trim().to_lowercase())?;
                if !label.contains("token") {
                    return None;
                }
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }

            None
        })
        .collect::<Vec<_>>();

    let mut warnings = Vec::new();
    if url_candidates.is_empty() {
        warnings.push(
            "reset-token output did not contain a reset URL; use the raw backend output"
                .to_string(),
        );
    } else if url_candidates.len() > 1 {
        warnings.push(
            "reset-token output contained multiple reset URLs; using the first parsed URL and preserving the raw backend output"
                .to_string(),
        );
    }

    if token_candidates.is_empty() {
        warnings.push(
            "reset-token output did not contain a parseable token; use the raw backend output"
                .to_string(),
        );
    } else if token_candidates.len() > 1 {
        warnings.push(
            "reset-token output contained multiple token-like lines; using the first parsed token and preserving the raw backend output"
                .to_string(),
        );
    }

    Parsed {
        value: ResetTokenSummary {
            raw_output,
            reset_url: url_candidates.first().cloned(),
            token: token_candidates.first().cloned(),
        },
        warnings,
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

        assert_eq!(groups.value[0].name, "immich-users");
        assert_eq!(groups.value[1].name, "users");
        assert!(groups.warnings.is_empty());
    }

    #[test]
    fn warns_when_person_list_entries_are_malformed() {
        let parsed = parse_person_list(&json!([
            { "attrs": { "name": ["dsaw"], "displayname": ["Dan"] } },
            { "attrs": { "displayname": ["Missing Name"] } }
        ]))
        .expect("person list");

        assert_eq!(parsed.value.len(), 1);
        assert_eq!(parsed.warnings.len(), 1);
    }

    #[test]
    fn rejects_unexpected_person_record_shape() {
        let error = parse_person_record(&json!("not-an-object"), "dsaw").expect_err("error");
        assert!(matches!(error, AppError::Json { .. }));
    }

    #[test]
    fn parses_reset_token_output() {
        let summary = parse_reset_token_summary(
            "Reset token: abc123\nUse this link: https://id.example.test/ui/reset?token=abc123\n",
        );

        assert_eq!(summary.value.token.as_deref(), Some("abc123"));
        assert_eq!(
            summary.value.reset_url.as_deref(),
            Some("https://id.example.test/ui/reset?token=abc123")
        );
        assert!(summary.warnings.is_empty());
    }

    #[test]
    fn warns_when_reset_token_output_is_partial() {
        let summary = parse_reset_token_summary("Reset token: abc123\n");

        assert_eq!(summary.value.token.as_deref(), Some("abc123"));
        assert!(summary.value.reset_url.is_none());
        assert_eq!(summary.warnings.len(), 1);
    }
}
