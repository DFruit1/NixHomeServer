use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::AppError;

use super::{
    collect_strings, dedup_sort, normalize_list_object, normalize_record_object, normalized_key,
    optional_string_field, required_string_field, walk_object_fields, Parsed,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupScopeMap {
    pub group: String,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupClaimMap {
    pub group: String,
    pub claims: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClientSummary {
    pub name: String,
    pub display_name: Option<String>,
    pub landing_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClientRecord {
    pub name: String,
    pub display_name: Option<String>,
    pub landing_url: Option<String>,
    pub redirect_urls: Vec<String>,
    pub scope_maps: Vec<GroupScopeMap>,
    pub claim_maps: Vec<GroupClaimMap>,
    pub referenced_groups: Vec<String>,
    pub pkce_enabled: Option<bool>,
    pub consent_prompt_enabled: Option<bool>,
}

pub fn parse_client_list(value: &Value) -> Result<Parsed<Vec<ClientSummary>>, AppError> {
    let entries = value.as_array().ok_or_else(|| AppError::Json {
        message: "kanidm oauth2 client list did not return a JSON array".to_string(),
        details: json!({ "value": value }),
    })?;

    let mut clients = Vec::new();
    let mut warnings = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        let Some(object) = normalize_list_object(entry) else {
            warnings.push(format!(
                "skipped malformed oauth2 client list entry at index {index}: entry was not an object or attrs object"
            ));
            continue;
        };
        let Some(name) = object.get("name").and_then(super::string_like) else {
            warnings.push(format!(
                "skipped malformed oauth2 client list entry at index {index}: missing string field 'name'"
            ));
            continue;
        };
        clients.push(ClientSummary {
            name,
            display_name: find_display_name(object),
            landing_url: find_landing_url(object),
        });
    }
    clients.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(Parsed {
        value: clients,
        warnings,
    })
}

pub fn parse_client_record(
    value: &Value,
    client_hint: &str,
) -> Result<Parsed<ClientRecord>, AppError> {
    let mut warnings = Vec::new();
    let object = normalize_record_object(value, "oauth2 client", client_hint, &mut warnings)?;
    let name = required_string_field(object, "oauth2 client", "name", client_hint)?;
    let scope_maps = collect_scope_maps(value);
    let claim_maps = collect_claim_maps(value);
    let referenced_groups = collect_referenced_groups(&scope_maps, &claim_maps);

    Ok(Parsed {
        value: ClientRecord {
            name,
            display_name: find_display_name(object),
            landing_url: find_landing_url(object),
            redirect_urls: collect_redirect_urls(value),
            scope_maps,
            claim_maps,
            referenced_groups,
            pkce_enabled: find_pkce_enabled(value),
            consent_prompt_enabled: find_consent_prompt_enabled(value),
        },
        warnings,
    })
}

fn find_display_name(object: &Map<String, Value>) -> Option<String> {
    optional_string_field(object, "displayname", &mut Vec::new()).or_else(|| {
        object
            .iter()
            .find(|(key, _)| normalized_key(key).contains("displayname"))
            .and_then(|(_, value)| super::string_like(value))
    })
}

fn find_landing_url(object: &Map<String, Value>) -> Option<String> {
    if let Some(url) = object
        .iter()
        .find(|(key, _)| normalized_key(key).contains("landing"))
        .and_then(|(_, value)| super::string_like(value))
    {
        return Some(url);
    }
    object
        .iter()
        .find(|(key, _)| {
            normalized_key(key).contains("origin") && normalized_key(key).contains("landing")
        })
        .and_then(|(_, value)| super::string_like(value))
}

fn collect_redirect_urls(value: &Value) -> Vec<String> {
    let mut urls = Vec::new();
    walk_object_fields(value, &mut |key, entry| {
        let key = normalized_key(key);
        if key.contains("redirect") || key.contains("originurl") {
            urls.extend(collect_strings(entry));
        }
    });
    urls.retain(|value| value.contains("://"));
    dedup_sort(&mut urls);
    urls
}

fn collect_scope_maps(value: &Value) -> Vec<GroupScopeMap> {
    let mut maps = Vec::new();
    walk_object_fields(value, &mut |key, entry| {
        let key = normalized_key(key);
        if !key.contains("scopemap") {
            return;
        }
        if let Value::Object(map) = entry {
            for (group, scopes) in map {
                let mut scopes = collect_strings(scopes);
                dedup_sort(&mut scopes);
                maps.push(GroupScopeMap {
                    group: group.clone(),
                    scopes,
                });
            }
        }
    });
    maps.sort_by(|left, right| left.group.cmp(&right.group));
    maps.dedup_by(|left, right| left.group == right.group && left.scopes == right.scopes);
    maps
}

fn collect_claim_maps(value: &Value) -> Vec<GroupClaimMap> {
    let mut maps = Vec::new();
    walk_object_fields(value, &mut |key, entry| {
        let key = normalized_key(key);
        if !key.contains("claimmap") {
            return;
        }
        if let Value::Object(map) = entry {
            for (group, claims) in map {
                let mut claim_names = match claims {
                    Value::Object(claim_map) => claim_map.keys().cloned().collect::<Vec<_>>(),
                    _ => collect_strings(claims),
                };
                dedup_sort(&mut claim_names);
                maps.push(GroupClaimMap {
                    group: group.clone(),
                    claims: claim_names,
                });
            }
        }
    });
    maps.sort_by(|left, right| left.group.cmp(&right.group));
    maps.dedup_by(|left, right| left.group == right.group && left.claims == right.claims);
    maps
}

fn collect_referenced_groups(
    scope_maps: &[GroupScopeMap],
    claim_maps: &[GroupClaimMap],
) -> Vec<String> {
    let mut groups = scope_maps
        .iter()
        .map(|map| map.group.clone())
        .chain(claim_maps.iter().map(|map| map.group.clone()))
        .collect::<Vec<_>>();
    dedup_sort(&mut groups);
    groups
}

fn find_pkce_enabled(value: &Value) -> Option<bool> {
    find_bool_flag(value, "pkce")
}

fn find_consent_prompt_enabled(value: &Value) -> Option<bool> {
    find_bool_flag(value, "consent")
}

fn find_bool_flag(value: &Value, needle: &str) -> Option<bool> {
    let mut result = None;
    walk_object_fields(value, &mut |key, entry| {
        if result.is_some() {
            return;
        }
        let key = normalized_key(key);
        if !key.contains(needle) {
            return;
        }
        let Some(value) = value_to_bool(entry) else {
            return;
        };
        result = Some(if key.contains("disable") {
            !value
        } else {
            value
        });
    });
    result
}

fn value_to_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(value) => Some(*value),
        Value::String(value) => match value.to_ascii_lowercase().as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        Value::Array(entries) => entries.first().and_then(value_to_bool),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn parses_client_record_and_referenced_groups() {
        let record = parse_client_record(
            &json!({
                "attrs": {
                    "name": ["files"],
                    "displayname": ["Files"],
                    "origin_landing": ["https://files.example.test"]
                },
                "scope_maps": {
                    "user-files": ["openid", "profile"],
                    "shared-files-read-write-access": ["openid", "groups"]
                },
                "redirect_urls": ["https://files.example.test/oauth2/callback"],
                "disable_pkce": [false],
                "disable_consent_prompt": [true]
            }),
            "files",
        )
        .expect("client");

        assert_eq!(
            record.value.referenced_groups,
            vec![
                "shared-files-read-write-access".to_string(),
                "user-files".to_string()
            ]
        );
        assert_eq!(record.value.pkce_enabled, Some(true));
        assert_eq!(record.value.consent_prompt_enabled, Some(false));
    }
}
