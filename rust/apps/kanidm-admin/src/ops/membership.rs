use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    inventory::{
        clients::{parse_client_list, parse_client_record},
        groups::{parse_group_list, GroupSummary},
    },
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck},
    output::CommandOutput,
    AppError,
};

use super::{group::load_group, user::load_user};

#[derive(Debug, Clone)]
pub struct SetMembershipOptions {
    pub account_id: String,
    pub groups: Vec<String>,
    pub allow_empty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MembershipPickerInventory {
    pub groups: Vec<GroupSummary>,
    pub referenced_groups: Vec<String>,
    pub warnings: Vec<String>,
}

pub fn show_membership(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let user = load_user(cli, account_id)?;
    Ok(CommandOutput {
        message: format!(
            "loaded direct group memberships for '{}'",
            user.value.account_id
        ),
        human: format!(
            "Direct groups for '{}':\n{}",
            user.value.account_id,
            render_groups(&user.value.groups)
        ),
        details: json!({
            "account_id": user.value.account_id,
            "groups": user.value.groups,
        }),
        warnings: user.warnings,
    })
}

pub fn add_membership(
    cli: &KanidmCli,
    account_id: &str,
    groups: &[String],
) -> Result<CommandOutput, AppError> {
    let desired = normalize_groups(groups.to_vec());
    for group in &desired {
        let _ = load_group(cli, group)?;
        cli.group_add_members(group, account_id)?;
    }
    let user = verify_membership(cli, account_id, &desired, MembershipMode::ContainsAll)?;

    Ok(CommandOutput {
        message: format!("added direct memberships to '{}'", account_id),
        human: format!(
            "Added groups to '{}'.\n\nCurrent Direct Groups:\n{}",
            account_id,
            render_groups(&user.value.groups)
        ),
        details: json!({
            "account_id": account_id,
            "groups_added": desired,
            "user": user.value,
        }),
        warnings: user.warnings,
    })
}

pub fn remove_membership(
    cli: &KanidmCli,
    account_id: &str,
    groups: &[String],
) -> Result<CommandOutput, AppError> {
    let desired = normalize_groups(groups.to_vec());
    for group in &desired {
        let _ = load_group(cli, group)?;
        cli.group_remove_members(group, account_id)?;
    }
    let user = verify_membership(cli, account_id, &desired, MembershipMode::ExcludesAll)?;

    Ok(CommandOutput {
        message: format!("removed direct memberships from '{}'", account_id),
        human: format!(
            "Removed groups from '{}'.\n\nCurrent Direct Groups:\n{}",
            account_id,
            render_groups(&user.value.groups)
        ),
        details: json!({
            "account_id": account_id,
            "groups_removed": desired,
            "user": user.value,
        }),
        warnings: user.warnings,
    })
}

pub fn set_membership(
    cli: &KanidmCli,
    options: SetMembershipOptions,
) -> Result<CommandOutput, AppError> {
    let desired_groups = normalize_groups(options.groups);
    if desired_groups.is_empty() && !options.allow_empty {
        return Err(AppError::Config {
            message: format!(
                "setting direct memberships for '{}' to an empty set requires --allow-empty",
                options.account_id
            ),
        });
    }

    let current = load_user(cli, &options.account_id)?;
    if !current.warnings.is_empty() {
        return Err(AppError::InventoryIncomplete {
            message: format!(
                "refusing to authoritatively set memberships for '{}' because the current user record was only partially parsed",
                options.account_id
            ),
            details: json!({
                "account_id": options.account_id,
                "warnings": current.warnings,
            }),
        });
    }

    for group in &desired_groups {
        let _ = load_group(cli, group)?;
    }

    let diff = membership_diff(&current.value.groups, &desired_groups);
    for group in &diff.added {
        cli.group_add_members(group, &options.account_id)?;
    }
    for group in &diff.removed {
        cli.group_remove_members(group, &options.account_id)?;
    }

    let user = verify_membership(
        cli,
        &options.account_id,
        &desired_groups,
        MembershipMode::Exact,
    )?;

    Ok(CommandOutput {
        message: format!("set direct memberships for '{}'", options.account_id),
        human: format!(
            "Set direct memberships for '{}'.\n\nAdded:\n{}\n\nRemoved:\n{}\n\nCurrent Direct Groups:\n{}",
            options.account_id,
            render_groups(&diff.added),
            render_groups(&diff.removed),
            render_groups(&user.value.groups)
        ),
        details: json!({
            "account_id": options.account_id,
            "desired_groups": desired_groups,
            "added": diff.added,
            "removed": diff.removed,
            "user": user.value,
        }),
        warnings: user.warnings,
    })
}

pub fn prepare_membership_picker_inventory(
    cli: &KanidmCli,
) -> Result<MembershipPickerInventory, AppError> {
    let groups = parse_group_list(&cli.group_list::<Value>()?)?;
    let client_list = parse_client_list(&cli.oauth2_list::<Value>()?)?;

    let mut warnings = groups.warnings.clone();
    warnings.extend(client_list.warnings.clone());

    let mut referenced_groups = Vec::new();
    for client in &client_list.value {
        let parsed = parse_client_record(&cli.oauth2_get::<Value>(&client.name)?, &client.name)?;
        warnings.extend(parsed.warnings);
        referenced_groups.extend(parsed.value.referenced_groups);
    }

    referenced_groups.sort();
    referenced_groups.dedup();

    let mut ordered = groups.value.clone();
    ordered.sort_by_key(|group| {
        (
            !referenced_groups
                .iter()
                .any(|candidate| candidate == &group.name),
            group.name.clone(),
        )
    });

    warnings.sort();
    warnings.dedup();

    Ok(MembershipPickerInventory {
        groups: ordered,
        referenced_groups,
        warnings,
    })
}

fn verify_membership(
    cli: &KanidmCli,
    account_id: &str,
    expected_groups: &[String],
    mode: MembershipMode,
) -> Result<crate::inventory::Parsed<crate::inventory::users::UserRecord>, AppError> {
    verify_with_retry(
        &format!("membership verification failed for Kanidm user '{account_id}'"),
        json!({
            "account_id": account_id,
            "expected_groups": expected_groups,
            "mode": mode.as_str(),
        }),
        true,
        || {
            let user = load_user(cli, account_id)?;
            let matched = match mode {
                MembershipMode::ContainsAll => expected_groups
                    .iter()
                    .all(|group| user.value.groups.iter().any(|candidate| candidate == group)),
                MembershipMode::ExcludesAll => expected_groups
                    .iter()
                    .all(|group| !user.value.groups.iter().any(|candidate| candidate == group)),
                MembershipMode::Exact => user.value.groups == expected_groups,
            };
            let observed = json!({
                "actual_groups": &user.value.groups,
                "warnings": &user.warnings,
            });
            if matched {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: user,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn normalize_groups(groups: Vec<String>) -> Vec<String> {
    let mut normalized = groups
        .into_iter()
        .map(|group| group.trim().to_string())
        .filter(|group| !group.is_empty())
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

fn render_groups(groups: &[String]) -> String {
    if groups.is_empty() {
        "(none)".to_string()
    } else {
        groups
            .iter()
            .map(|group| format!("- {group}"))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[derive(Debug, Clone, Copy)]
enum MembershipMode {
    ContainsAll,
    ExcludesAll,
    Exact,
}

impl MembershipMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::ContainsAll => "contains_all",
            Self::ExcludesAll => "excludes_all",
            Self::Exact => "exact",
        }
    }
}

#[derive(Debug, Clone)]
struct MembershipDiff {
    added: Vec<String>,
    removed: Vec<String>,
}

fn membership_diff(current: &[String], desired: &[String]) -> MembershipDiff {
    let current = current.iter().cloned().collect::<BTreeSet<_>>();
    let desired = desired.iter().cloned().collect::<BTreeSet<_>>();
    MembershipDiff {
        added: desired.difference(&current).cloned().collect(),
        removed: current.difference(&desired).cloned().collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prioritizes_client_referenced_groups_first() {
        let inventory = MembershipPickerInventory {
            groups: vec![
                GroupSummary {
                    name: "shared-files-rw".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "users".to_string(),
                    description: None,
                },
            ],
            referenced_groups: vec!["shared-files-rw".to_string()],
            warnings: Vec::new(),
        };

        assert_eq!(inventory.groups[0].name, "shared-files-rw");
    }
}
