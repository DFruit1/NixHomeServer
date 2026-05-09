use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    inventory::{
        clients::{parse_client_list, parse_client_record},
        groups::{category_sort_rank, is_operator_visible_group, parse_group_list, GroupSummary},
    },
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck, VerificationPolicy},
    ops::{reconcile_failed_write, FailedWriteContext, ReconciledWrite},
    output::CommandOutput,
    AppError,
};

use super::{group::load_group, user::load_user};

#[derive(Debug, Clone)]
pub struct SetMembershipOptions {
    pub account_id: String,
    pub groups: Vec<String>,
    pub preserve_groups: Vec<String>,
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
    if desired.is_empty() {
        return Err(AppError::Config {
            message: format!(
                "adding memberships for '{}' requires at least one group name",
                account_id
            ),
        });
    }
    let requested_state = json!({
        "account_id": account_id,
        "groups": desired,
        "mode": MembershipMode::ContainsAll.as_str(),
    });
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();
    for group in &desired {
        let _ = load_group(cli, group)?;
        match cli.group_add_members(group, account_id) {
            Ok(()) => completed_steps.push(format!("group_add_members:{group}")),
            Err(error) => {
                let ReconciledWrite { value, warning } = reconcile_failed_write(
                    FailedWriteContext {
                        resource: "user membership",
                        name: account_id,
                        requested_state: requested_state.clone(),
                        completed_steps: &completed_steps,
                        failed_step: &format!("group_add_members:{group}"),
                        error,
                        next_actions: membership_next_actions(
                            account_id,
                            MembershipMode::ContainsAll,
                        ),
                    },
                    || verify_membership(cli, account_id, &desired, MembershipMode::ContainsAll),
                    |_| true,
                    membership_observed_state,
                )?;
                warnings.push(warning);
                warnings.extend(value.warnings.iter().cloned());
                completed_steps.push(format!("group_add_members:{group}"));
            }
        }
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
            "requested_state": requested_state,
            "user": user.value,
        }),
        warnings: merge_warnings(warnings, user.warnings),
    })
}

pub fn remove_membership(
    cli: &KanidmCli,
    account_id: &str,
    groups: &[String],
) -> Result<CommandOutput, AppError> {
    let desired = normalize_groups(groups.to_vec());
    if desired.is_empty() {
        return Err(AppError::Config {
            message: format!(
                "removing memberships for '{}' requires at least one group name",
                account_id
            ),
        });
    }
    let requested_state = json!({
        "account_id": account_id,
        "groups": desired,
        "mode": MembershipMode::ExcludesAll.as_str(),
    });
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();
    for group in &desired {
        let _ = load_group(cli, group)?;
        match cli.group_remove_members(group, account_id) {
            Ok(()) => completed_steps.push(format!("group_remove_members:{group}")),
            Err(error) => {
                let ReconciledWrite { value, warning } = reconcile_failed_write(
                    FailedWriteContext {
                        resource: "user membership",
                        name: account_id,
                        requested_state: requested_state.clone(),
                        completed_steps: &completed_steps,
                        failed_step: &format!("group_remove_members:{group}"),
                        error,
                        next_actions: membership_next_actions(
                            account_id,
                            MembershipMode::ExcludesAll,
                        ),
                    },
                    || verify_membership(cli, account_id, &desired, MembershipMode::ExcludesAll),
                    |_| true,
                    membership_observed_state,
                )?;
                warnings.push(warning);
                warnings.extend(value.warnings.iter().cloned());
                completed_steps.push(format!("group_remove_members:{group}"));
            }
        }
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
            "requested_state": requested_state,
            "user": user.value,
        }),
        warnings: merge_warnings(warnings, user.warnings),
    })
}

pub fn set_membership(
    cli: &KanidmCli,
    options: SetMembershipOptions,
) -> Result<CommandOutput, AppError> {
    let desired_groups = normalize_groups(options.groups);
    let preserved_groups = normalize_groups(options.preserve_groups);
    let effective_desired_groups =
        normalize_groups([desired_groups.clone(), preserved_groups.clone()].concat());
    let requested_state = json!({
        "account_id": options.account_id,
        "groups": effective_desired_groups,
        "mode": MembershipMode::Exact.as_str(),
    });
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();
    if effective_desired_groups.is_empty() && !options.allow_empty {
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

    let diff = membership_diff(&current.value.groups, &effective_desired_groups);
    for group in &diff.added {
        completed_steps.push(format!("group_add_members:{group}"));
        if let Err(error) = cli.group_add_members(group, &options.account_id) {
            completed_steps.pop();
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user membership",
                    name: &options.account_id,
                    requested_state: requested_state.clone(),
                    completed_steps: &completed_steps,
                    failed_step: &format!("group_add_members:{group}"),
                    error,
                    next_actions: membership_next_actions(
                        &options.account_id,
                        MembershipMode::Exact,
                    ),
                },
                || {
                    verify_membership(
                        cli,
                        &options.account_id,
                        &effective_desired_groups,
                        MembershipMode::Exact,
                    )
                },
                |_| true,
                membership_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            completed_steps.push(format!("group_add_members:{group}"));
        }
    }
    for group in &diff.removed {
        completed_steps.push(format!("group_remove_members:{group}"));
        if let Err(error) = cli.group_remove_members(group, &options.account_id) {
            completed_steps.pop();
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user membership",
                    name: &options.account_id,
                    requested_state: requested_state.clone(),
                    completed_steps: &completed_steps,
                    failed_step: &format!("group_remove_members:{group}"),
                    error,
                    next_actions: membership_next_actions(
                        &options.account_id,
                        MembershipMode::Exact,
                    ),
                },
                || {
                    verify_membership(
                        cli,
                        &options.account_id,
                        &effective_desired_groups,
                        MembershipMode::Exact,
                    )
                },
                |_| true,
                membership_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            completed_steps.push(format!("group_remove_members:{group}"));
        }
    }

    let user = verify_membership(
        cli,
        &options.account_id,
        &effective_desired_groups,
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
            "preserved_groups": preserved_groups,
            "effective_desired_groups": effective_desired_groups,
            "requested_state": requested_state,
            "completed_steps": completed_steps,
            "added": diff.added,
            "removed": diff.removed,
            "user": user.value,
        }),
        warnings: merge_warnings(warnings, user.warnings),
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

    let mut ordered = groups
        .value
        .into_iter()
        .filter(|group| is_guided_picker_group(&group.name))
        .collect::<Vec<_>>();
    ordered.sort_by(|left, right| {
        let left_key = (
            category_sort_rank(&left.name),
            !referenced_groups
                .iter()
                .any(|candidate| candidate == &left.name),
            left.name.clone(),
        );
        let right_key = (
            category_sort_rank(&right.name),
            !referenced_groups
                .iter()
                .any(|candidate| candidate == &right.name),
            right.name.clone(),
        );
        left_key.cmp(&right_key)
    });

    warnings.sort();
    warnings.dedup();

    Ok(MembershipPickerInventory {
        groups: ordered,
        referenced_groups,
        warnings,
    })
}

fn is_guided_picker_group(name: &str) -> bool {
    is_operator_visible_group(name)
}

fn verify_membership(
    cli: &KanidmCli,
    account_id: &str,
    expected_groups: &[String],
    mode: MembershipMode,
) -> Result<crate::inventory::Parsed<crate::inventory::users::UserRecord>, AppError> {
    verify_with_retry(
        VerificationPolicy::MembershipConvergence,
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

fn membership_observed_state(
    user: &crate::inventory::Parsed<crate::inventory::users::UserRecord>,
) -> Value {
    json!({
        "actual_groups": &user.value.groups,
        "warnings": &user.warnings,
    })
}

fn membership_next_actions(account_id: &str, mode: MembershipMode) -> Vec<String> {
    let command = match mode {
        MembershipMode::ContainsAll | MembershipMode::ExcludesAll => {
            format!("kanidm-admin membership show {account_id}")
        }
        MembershipMode::Exact => format!("kanidm-admin membership show {account_id}"),
    };
    vec![
        format!("Inspect the current memberships with `{command}`."),
        "If the live state is still wrong, rerun the membership command after confirming the target groups.".to_string(),
    ]
}

fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}

pub(crate) fn normalize_groups(groups: Vec<String>) -> Vec<String> {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MembershipDiff {
    pub(crate) added: Vec<String>,
    pub(crate) removed: Vec<String>,
}

impl MembershipDiff {
    pub(crate) fn is_empty(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty()
    }
}

pub(crate) fn membership_diff(current: &[String], desired: &[String]) -> MembershipDiff {
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
    fn guided_picker_filters_internal_groups() {
        let inventory = MembershipPickerInventory {
            groups: vec![
                GroupSummary {
                    name: "idm_admins".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "ext_radius_servers".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "app-admin".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "shared-files-read-write-access".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "system_admins".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "users".to_string(),
                    description: None,
                },
            ],
            referenced_groups: vec!["shared-files-read-write-access".to_string()],
            warnings: Vec::new(),
        };

        let visible = inventory
            .groups
            .into_iter()
            .filter(|group| is_guided_picker_group(&group.name))
            .map(|group| group.name)
            .collect::<Vec<_>>();

        assert_eq!(
            visible,
            vec![
                "ext_radius_servers".to_string(),
                "app-admin".to_string(),
                "shared-files-read-write-access".to_string(),
                "users".to_string()
            ]
        );
    }

    #[test]
    fn guided_picker_keeps_common_groups_ahead_of_unknown_groups() {
        let mut groups = [
            GroupSummary {
                name: "custom-group".to_string(),
                description: None,
            },
            GroupSummary {
                name: "users".to_string(),
                description: None,
            },
            GroupSummary {
                name: "app-admin".to_string(),
                description: None,
            },
            GroupSummary {
                name: "immich-users".to_string(),
                description: None,
            },
        ];

        groups.sort_by(|left, right| {
            let left_key = (category_sort_rank(&left.name), left.name.clone());
            let right_key = (category_sort_rank(&right.name), right.name.clone());
            left_key.cmp(&right_key)
        });

        assert_eq!(groups[0].name, "users");
        assert_eq!(groups[1].name, "immich-users");
        assert_eq!(groups[2].name, "app-admin");
        assert_eq!(groups[3].name, "custom-group");
    }

    #[test]
    fn membership_diff_preserves_hidden_groups_when_included_in_effective_target() {
        let diff = membership_diff(
            &[
                "idm_all_persons".to_string(),
                "users".to_string(),
                "app-admin".to_string(),
            ],
            &["idm_all_persons".to_string(), "users".to_string()],
        );

        assert!(diff.added.is_empty());
        assert_eq!(diff.removed, vec!["app-admin".to_string()]);
    }
}
