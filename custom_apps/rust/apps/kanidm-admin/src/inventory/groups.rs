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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum GroupCategory {
    Foundation,
    AppUser,
    AppAdmin,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct GroupHelp {
    pub summary: &'static str,
    pub detail: &'static str,
    pub category: GroupCategory,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedGroupHelp {
    pub summary: String,
    pub detail: String,
    pub category: GroupCategory,
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

pub fn resolve_group_help(name: &str, description: Option<&str>) -> ResolvedGroupHelp {
    if let Some(help) = curated_group_help(name) {
        return ResolvedGroupHelp {
            summary: help.summary.to_string(),
            detail: help.detail.to_string(),
            category: help.category,
        };
    }

    match description
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
    {
        Some(description) => ResolvedGroupHelp {
            summary: description,
            detail: "This live group is visible in the guided picker, but it is not part of the common curated operator guidance set.".to_string(),
            category: inferred_category(name),
        },
        None => ResolvedGroupHelp {
            summary: "No curated guidance is available for this group.".to_string(),
            detail: "This live group is not part of the common operator guidance set."
                .to_string(),
            category: inferred_category(name),
        },
    }
}

pub fn is_operator_visible_group(name: &str) -> bool {
    !name.starts_with("idm_") && name != "system_admins"
}

pub fn category_sort_rank(name: &str) -> usize {
    match resolve_group_help(name, None).category {
        GroupCategory::Foundation => 0,
        GroupCategory::AppUser => 1,
        GroupCategory::AppAdmin => 2,
        GroupCategory::Other => 3,
    }
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

fn curated_group_help(name: &str) -> Option<GroupHelp> {
    Some(match name {
        "users" => GroupHelp {
            summary: "Baseline identity membership for a normal user account.",
            detail: "Use this for most people first. It means the person exists in Kanidm and can access baseline services that only require general membership.",
            category: GroupCategory::Foundation,
        },
        "user-files" => GroupHelp {
            summary: "Grants browser Files access and provisions a personal file root.",
            detail: "Add this when the user should access personal file areas through Filestash or the upload flow. Direct SFTP login is controlled separately by files-sftp-users.",
            category: GroupCategory::Foundation,
        },
        "files-sftp-users" => GroupHelp {
            summary: "Grants password-based access to the restricted files SFTP endpoint.",
            detail: "Add this only when the user should connect directly to the dedicated SFTP port. The endpoint uses Kanidm password/PAM auth, forces internal-sftp, and does not grant normal shell SSH.",
            category: GroupCategory::Foundation,
        },
        "files-shared-users" => GroupHelp {
            summary: "Adds the protected shared files view inside the user's file root.",
            detail: "Add this when the user should see _Shared in Filestash or direct SFTP. They can read, write, edit, and rename there, but deletes are denied through the protected view.",
            category: GroupCategory::Foundation,
        },
        "system_admins" => GroupHelp {
            summary: "Grants broad system administration authority.",
            detail: "Bootstrap this manually with the regular kanidm CLI only when someone truly needs high-level server authority. It is intentionally hidden from normal guided access-management flows.",
            category: GroupCategory::AppAdmin,
        },
        "app-admin" => GroupHelp {
            summary: "Grants application admin roles when paired with app access.",
            detail: "Add this only for trusted operators who already belong to the matching app's `*-users` group. It does not grant app sign-in by itself.",
            category: GroupCategory::AppAdmin,
        },
        "mail-archive-users" => GroupHelp {
            summary: "Grants access to the mail archive web app.",
            detail: "Add this only for users who should sign in to the mail archive. It provides application access rather than broader platform authority.",
            category: GroupCategory::AppUser,
        },
        "immich-users" => GroupHelp {
            summary: "Grants Immich sign-in access.",
            detail: "Add this when the user should use the Photos app. First successful OIDC login provisions the local Immich account.",
            category: GroupCategory::AppUser,
        },
        "jellyfin-users" => GroupHelp {
            summary: "Grants managed Jellyfin local-account and library access.",
            detail: "Add this when the user should have a managed Jellyfin local account and their personal video libraries. Jellyfin library-wide admin visibility also requires `app-admin` and inclusion in `jellyfinAdminUsers`.",
            category: GroupCategory::AppUser,
        },
        "paperless-users" => GroupHelp {
            summary: "Grants normal non-admin Paperless access.",
            detail: "Add this when the user should use the Documents app day to day. First successful OIDC login creates or links the local Paperless account and grants normal document-management access without app administration.",
            category: GroupCategory::AppUser,
        },
        "audiobookshelf-users" => GroupHelp {
            summary: "Grants Audiobookshelf sign-in access.",
            detail: "Add this when the user should access the Audiobooks app. It is for normal app use rather than administration.",
            category: GroupCategory::AppUser,
        },
        "kavita-users" => GroupHelp {
            summary: "Grants Kavita sign-in access.",
            detail: "Add this when the user should access the Books app. It enables normal use without granting app-level administrative control.",
            category: GroupCategory::AppUser,
        },
        "downloads-users" => GroupHelp {
            summary: "Grants access to the YouTube downloads web app.",
            detail: "Add this when the user should access the Downloads app. It is a normal application-access grant rather than a platform-wide role.",
            category: GroupCategory::AppUser,
        },
        _ if name.starts_with("ext_") => GroupHelp {
            summary: "Grants access for an external or integration-specific service group.",
            detail: "Use this only when you know the external integration that depends on it. These groups are more specialized than normal day-to-day app access roles.",
            category: GroupCategory::Other,
        },
        _ => return None,
    })
}

fn inferred_category(name: &str) -> GroupCategory {
    match name {
        "users" | "user-files" => GroupCategory::Foundation,
        _ if name.ends_with("-admin") => GroupCategory::AppAdmin,
        _ if name.ends_with("-users") || name.ends_with("-login") => GroupCategory::AppUser,
        _ => GroupCategory::Other,
    }
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
    fn curated_help_prefers_known_groups() {
        let help = resolve_group_help("app-admin", Some("ignored"));

        assert_eq!(help.category, GroupCategory::AppAdmin);
        assert!(help.summary.contains("application admin"));
    }

    #[test]
    fn fallback_help_uses_live_description() {
        let help = resolve_group_help("custom-app-users", Some("Custom app access."));

        assert_eq!(help.category, GroupCategory::AppUser);
        assert_eq!(help.summary, "Custom app access.");
    }

    #[test]
    fn fallback_help_uses_default_copy_without_description() {
        let help = resolve_group_help("custom-group", None);

        assert_eq!(help.category, GroupCategory::Other);
        assert!(help.summary.contains("No curated guidance"));
    }

    #[test]
    fn operator_visible_groups_hide_protected_entries() {
        assert!(!is_operator_visible_group("idm_admins"));
        assert!(!is_operator_visible_group("system_admins"));
        assert!(is_operator_visible_group("ext_radius_servers"));
    }
}
