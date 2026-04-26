use std::collections::BTreeSet;

use serde_json::{json, Value};

use crate::{
    groups::{managed_group, required_group_for_app, AppAccessTarget},
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck},
    models::{parse_person_record, Parsed, PersonRecord},
    output::CommandOutput,
    AppError,
};

#[derive(Debug, Clone)]
pub struct SetAccessOptions {
    pub account_id: String,
    pub groups: Vec<String>,
    pub allow_empty: bool,
}

pub fn show_access(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let person = load_person(cli, account_id)?;
    Ok(CommandOutput {
        message: format!("loaded access groups for '{}'", person.value.account_id),
        human: human_access_summary(&person.value),
        details: json!({ "user": person.value }),
        warnings: person.warnings,
    })
}

pub fn grant_access(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
) -> Result<CommandOutput, AppError> {
    validate_managed_group(group)?;
    cli.group_add_members(group, account_id)?;
    let person = verify_group_membership(cli, account_id, group, true)?;

    Ok(CommandOutput {
        message: format!("granted '{group}' to '{account_id}'"),
        human: format!(
            "Granted '{group}' to '{account_id}'.\n\n{}",
            human_access_summary(&person.value)
        ),
        details: json!({
            "user": person.value,
            "changed_group": group,
            "action": "grant",
        }),
        warnings: person.warnings,
    })
}

pub fn revoke_access(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
) -> Result<CommandOutput, AppError> {
    validate_managed_group(group)?;
    cli.group_remove_members(group, account_id)?;
    let person = verify_group_membership(cli, account_id, group, false)?;

    Ok(CommandOutput {
        message: format!("revoked '{group}' from '{account_id}'"),
        human: format!(
            "Revoked '{group}' from '{account_id}'.\n\n{}",
            human_access_summary(&person.value)
        ),
        details: json!({
            "user": person.value,
            "changed_group": group,
            "action": "revoke",
        }),
        warnings: person.warnings,
    })
}

pub fn set_access(cli: &KanidmCli, options: SetAccessOptions) -> Result<CommandOutput, AppError> {
    let desired_groups = normalize_groups(options.groups)?;
    if desired_groups.is_empty() && !options.allow_empty {
        return Err(AppError::Config {
            message: format!(
                "setting managed groups for '{}' to an empty set requires --allow-empty",
                options.account_id
            ),
        });
    }

    let current = load_person(cli, &options.account_id)?;
    let current_groups = current.value.access_groups.all_managed.clone();
    let diff = managed_group_diff(&current_groups, &desired_groups);

    let mut completed_steps = Vec::new();
    for group in &diff.added {
        cli.group_add_members(group, &options.account_id)?;
        completed_steps.push(format!("grant:{group}"));
    }
    for group in &diff.removed {
        cli.group_remove_members(group, &options.account_id)?;
        completed_steps.push(format!("revoke:{group}"));
    }

    let person = match verify_managed_groups(cli, &options.account_id, &desired_groups) {
        Ok(person) => person,
        Err(error) => {
            return Err(AppError::Verification {
                message: format!(
                    "updated managed groups for '{}' but final verification did not converge",
                    options.account_id
                ),
                details: json!({
                    "account_id": options.account_id,
                    "desired_groups": desired_groups,
                    "added": diff.added,
                    "removed": diff.removed,
                    "completed_steps": completed_steps,
                    "write_completed": true,
                    "error": error.json_payload(),
                }),
            });
        }
    };

    Ok(CommandOutput {
        message: format!(
            "set managed access groups for '{}'",
            person.value.account_id
        ),
        human: format!(
            "Set managed access groups for '{}'.\n\nAdded:\n{}\n\nRemoved:\n{}\n\n{}",
            person.value.account_id,
            render_groups(&diff.added),
            render_groups(&diff.removed),
            human_access_summary(&person.value),
        ),
        details: json!({
            "user": person.value,
            "action": "set",
            "added": diff.added,
            "removed": diff.removed,
            "desired_groups": desired_groups,
        }),
        warnings: merge_warnings(current.warnings, person.warnings),
    })
}

pub fn why_denied(
    cli: &KanidmCli,
    account_id: &str,
    app: AppAccessTarget,
) -> Result<CommandOutput, AppError> {
    let required_group = required_group_for_app(app);
    match load_person(cli, account_id) {
        Ok(person) => {
            let has_required_group = person
                .value
                .access_groups
                .all_managed
                .iter()
                .any(|group| group == required_group);

            let checked = [
                format!("user record found: yes ({})", person.value.account_id),
                format!(
                    "required managed login group present: {} ({required_group})",
                    yes_no(has_required_group)
                ),
                format!(
                    "current managed login groups: {}",
                    render_inline_groups(&person.value.access_groups.login)
                ),
                format!(
                    "current managed admin-intent groups: {}",
                    render_inline_groups(&person.value.access_groups.admin_intent)
                ),
                format!(
                    "account validity fields: valid_from={}, expiry={}",
                    person.value.valid_from.as_deref().unwrap_or("not set"),
                    person.value.expiry.as_deref().unwrap_or("not set")
                ),
                app_specific_checked_note(app),
            ];

            let did_not_check = [
                "OIDC client configuration".to_string(),
                "upstream app-local role mapping or provisioning".to_string(),
                "service health, DNS, routing, and TLS".to_string(),
            ];

            Ok(CommandOutput {
                message: format!("checked scoped access diagnostics for '{}'", account_id),
                human: format!(
                    "Scoped access diagnosis for '{}'\nTarget app: {:?}\n\nChecked:\n{}\n\nDid not check:\n{}",
                    account_id,
                    app,
                    checked
                        .iter()
                        .map(|item| format!("- {item}"))
                        .collect::<Vec<_>>()
                        .join("\n"),
                    did_not_check
                        .iter()
                        .map(|item| format!("- {item}"))
                        .collect::<Vec<_>>()
                        .join("\n")
                ),
                details: json!({
                    "account_id": account_id,
                    "app": app,
                    "checked": {
                        "user_found": true,
                        "required_group": required_group,
                        "has_required_group": has_required_group,
                        "login_groups": person.value.access_groups.login,
                        "admin_intent_groups": person.value.access_groups.admin_intent,
                        "valid_from": person.value.valid_from,
                        "expiry": person.value.expiry,
                    },
                    "did_not_check": did_not_check,
                }),
                warnings: person.warnings,
            })
        }
        Err(AppError::UserNotFound { .. }) => Ok(CommandOutput {
            message: format!("checked scoped access diagnostics for '{}'", account_id),
            human: format!(
                "Scoped access diagnosis for '{}'\nTarget app: {:?}\n\nChecked:\n- user record found: no\n- required managed login group present: not checked because the user record was not found\n- current managed login groups: not checked because the user record was not found\n- current managed admin-intent groups: not checked because the user record was not found\n- account validity fields: not checked because the user record was not found\n- app-specific note: {}\n\nDid not check:\n- OIDC client configuration\n- upstream app-local role mapping or provisioning\n- service health, DNS, routing, and TLS",
                account_id,
                app,
                app_specific_missing_user_note(app),
            ),
            details: json!({
                "account_id": account_id,
                "app": app,
                "checked": {
                    "user_found": false,
                    "required_group": required_group,
                    "has_required_group": false,
                },
                "did_not_check": [
                    "required managed login group presence because the user record was not found",
                    "OIDC client configuration",
                    "upstream app-local role mapping or provisioning",
                    "service health, DNS, routing, and TLS",
                ],
            }),
            warnings: Vec::new(),
        }),
        Err(error) => Err(error),
    }
}

fn load_person(cli: &KanidmCli, account_id: &str) -> Result<Parsed<PersonRecord>, AppError> {
    let value = cli.person_get::<Value>(account_id)?;
    parse_person_record(&value, account_id)
}

fn validate_managed_group(group: &str) -> Result<(), AppError> {
    if managed_group(group).is_some() {
        Ok(())
    } else {
        Err(AppError::InvalidManagedGroup {
            group: group.to_string(),
        })
    }
}

fn normalize_groups(groups: Vec<String>) -> Result<Vec<String>, AppError> {
    let mut normalized = BTreeSet::new();
    for group in groups {
        validate_managed_group(&group)?;
        normalized.insert(group);
    }
    Ok(normalized.into_iter().collect())
}

fn verify_group_membership(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
    expected_present: bool,
) -> Result<Parsed<PersonRecord>, AppError> {
    verify_with_retry(
        &format!(
            "post-change verification failed for user '{}' and group '{}'",
            account_id, group
        ),
        json!({
            "account_id": account_id,
            "group": group,
            "expected_present": expected_present,
        }),
        true,
        || {
            let person = load_person(cli, account_id)?;
            let actual_present = person
                .value
                .access_groups
                .all_managed
                .iter()
                .any(|candidate| candidate == group);

            let observed = json!({
                "actual_present": actual_present,
                "actual_groups": &person.value.access_groups.all_managed,
                "warnings": &person.warnings,
            });
            if actual_present == expected_present {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: person,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn verify_managed_groups(
    cli: &KanidmCli,
    account_id: &str,
    desired_groups: &[String],
) -> Result<Parsed<PersonRecord>, AppError> {
    verify_with_retry(
        &format!(
            "managed group verification failed for Kanidm user '{}'",
            account_id
        ),
        json!({
            "account_id": account_id,
            "desired_groups": desired_groups,
        }),
        true,
        || {
            let person = load_person(cli, account_id)?;
            let actual = &person.value.access_groups.all_managed;
            let observed = json!({
                "actual_groups": actual,
                "warnings": &person.warnings,
            });
            if actual == desired_groups {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: person,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn human_access_summary(person: &PersonRecord) -> String {
    format!(
        "Managed Login Groups:\n{}\n\nManaged Admin-Intent Groups:\n{}",
        render_groups(&person.access_groups.login),
        render_groups(&person.access_groups.admin_intent),
    )
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

fn render_inline_groups(groups: &[String]) -> String {
    if groups.is_empty() {
        "(none)".to_string()
    } else {
        groups.join(", ")
    }
}

fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn app_specific_checked_note(_: AppAccessTarget) -> String {
    "app-specific note: this command only checked repo-managed group state and account validity fields."
        .to_string()
}

fn app_specific_missing_user_note(_: AppAccessTarget) -> String {
    "This command only checks repo-managed group state and account validity fields when the user record exists."
        .to_string()
}

#[derive(Debug, Clone)]
struct GroupDiff {
    added: Vec<String>,
    removed: Vec<String>,
}

fn managed_group_diff(current: &[String], desired: &[String]) -> GroupDiff {
    let current = current.iter().cloned().collect::<BTreeSet<_>>();
    let desired = desired.iter().cloned().collect::<BTreeSet<_>>();

    GroupDiff {
        added: desired.difference(&current).cloned().collect(),
        removed: current.difference(&desired).cloned().collect(),
    }
}
