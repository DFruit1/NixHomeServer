pub mod clients;
pub mod groups;
pub mod policy;
pub mod users;

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::AppError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Parsed<T> {
    pub value: T,
    pub warnings: Vec<String>,
}

pub(crate) fn normalize_list_object(value: &Value) -> Option<&Map<String, Value>> {
    match value {
        Value::Object(map) => match map.get("attrs") {
            Some(Value::Object(attrs)) => Some(attrs),
            Some(_) => None,
            None => Some(map),
        },
        _ => None,
    }
}

pub(crate) fn normalize_record_object<'a>(
    value: &'a Value,
    resource: &str,
    hint: &str,
    warnings: &mut Vec<String>,
) -> Result<&'a Map<String, Value>, AppError> {
    match value {
        Value::Array(entries) => match entries.as_slice() {
            [] => Err(AppError::NotFound {
                resource: resource.to_string(),
                name: hint.to_string(),
                details: json!({
                    "source": "empty_json_array",
                    "value": value,
                }),
                message: format!("{resource} '{hint}' was not found"),
            }),
            [entry] => normalize_record_object(entry, resource, hint, warnings),
            _ => Err(AppError::Verification {
                message: format!(
                    "expected one Kanidm {resource} record for '{hint}', but received {} records",
                    entries.len()
                ),
                details: json!({ "value": value }),
            }),
        },
        Value::Object(map) => {
            if let Some(attrs) = map.get("attrs") {
                if let Value::Object(attrs) = attrs {
                    Ok(attrs)
                } else {
                    Err(AppError::Json {
                        message: format!(
                            "Kanidm {resource} record for '{hint}' contained a non-object 'attrs' field"
                        ),
                        details: json!({ "value": value }),
                    })
                }
            } else {
                warnings.push(format!(
                    "Kanidm {resource} record for '{hint}' did not contain 'attrs'; parsed the top-level object instead"
                ));
                Ok(map)
            }
        }
        _ => Err(AppError::Json {
            message: format!("Kanidm {resource} record for '{hint}' was not a JSON object"),
            details: json!({ "value": value }),
        }),
    }
}

pub(crate) fn string_like(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        Value::Array(entries) => entries.first().and_then(string_like),
        _ => None,
    }
}

pub(crate) fn list_string_field(object: &Map<String, Value>, field: &str) -> Option<String> {
    object.get(field).and_then(string_like)
}

pub(crate) fn required_string_field(
    object: &Map<String, Value>,
    resource: &str,
    field: &str,
    hint: &str,
) -> Result<String, AppError> {
    list_string_field(object, field).ok_or_else(|| AppError::Json {
        message: format!(
            "Kanidm {resource} record for '{hint}' did not contain required string field '{field}'"
        ),
        details: json!({ "value": object }),
    })
}

pub(crate) fn optional_string_field(
    object: &Map<String, Value>,
    field: &str,
    warnings: &mut Vec<String>,
) -> Option<String> {
    let value = object.get(field)?;
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Array(entries) => entries
            .first()
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        _ => {
            warnings.push(format!(
                "ignored non-string Kanidm field '{field}' while parsing a record"
            ));
            None
        }
    }
}

pub(crate) fn dedup_sort(values: &mut Vec<String>) {
    values.sort();
    values.dedup();
}

pub(crate) fn normalized_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

pub(crate) fn walk_object_fields<'a, F>(value: &'a Value, callback: &mut F)
where
    F: FnMut(&str, &'a Value),
{
    match value {
        Value::Object(map) => {
            for (key, entry) in map {
                callback(key, entry);
                walk_object_fields(entry, callback);
            }
        }
        Value::Array(entries) => {
            for entry in entries {
                walk_object_fields(entry, callback);
            }
        }
        _ => {}
    }
}

pub(crate) fn collect_strings(value: &Value) -> Vec<String> {
    match value {
        Value::String(value) => vec![value.clone()],
        Value::Array(entries) => entries.iter().filter_map(string_like).collect(),
        _ => Vec::new(),
    }
}
