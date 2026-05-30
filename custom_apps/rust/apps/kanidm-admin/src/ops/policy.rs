use serde_json::{json, Value};

use crate::{
    inventory::policy::{matches_policy_value, PolicyField},
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck, VerificationPolicy},
    ops::{reconcile_failed_write, FailedWriteContext, ReconciledWrite},
    output::CommandOutput,
    validation::{
        validate_identifier_field, validate_seconds_field, AUTH_EXPIRY_MAX_SECONDS,
        AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS, PRIVILEGE_EXPIRY_MIN_SECONDS,
    },
    AppError,
};

use super::group::{human_group_summary, load_group};

pub fn show_group_policy(cli: &KanidmCli, group: &str) -> Result<CommandOutput, AppError> {
    let group = load_group(cli, group)?;
    Ok(CommandOutput {
        message: format!("loaded account policy for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
    })
}

pub fn set_group_auth_expiry(
    cli: &KanidmCli,
    group: &str,
    seconds: u64,
) -> Result<CommandOutput, AppError> {
    let group = validate_identifier_field("group name", group)?;
    let seconds = validate_seconds_field(
        "auth expiry",
        seconds,
        AUTH_EXPIRY_MIN_SECONDS,
        AUTH_EXPIRY_MAX_SECONDS,
    )?;
    let mut warnings = Vec::new();
    apply_policy_write(
        cli,
        &group,
        PolicyField::AuthExpiry,
        Some(seconds),
        "set_auth_expiry",
        &mut warnings,
        |cli, group| cli.group_policy_auth_expiry_set(group, seconds),
    )?;
    let group = verify_policy_field(cli, &group, PolicyField::AuthExpiry, Some(seconds))?;
    Ok(CommandOutput {
        message: format!("set auth-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: merge_warnings(warnings, group.warnings),
    })
}

pub fn reset_group_auth_expiry(cli: &KanidmCli, group: &str) -> Result<CommandOutput, AppError> {
    let mut warnings = Vec::new();
    apply_policy_write(
        cli,
        group,
        PolicyField::AuthExpiry,
        None,
        "reset_auth_expiry",
        &mut warnings,
        |cli, group| cli.group_policy_auth_expiry_reset(group),
    )?;
    let group = verify_policy_field(cli, group, PolicyField::AuthExpiry, None)?;
    Ok(CommandOutput {
        message: format!("reset auth-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: merge_warnings(warnings, group.warnings),
    })
}

pub fn set_group_privilege_expiry(
    cli: &KanidmCli,
    group: &str,
    seconds: u64,
) -> Result<CommandOutput, AppError> {
    let group = validate_identifier_field("group name", group)?;
    let seconds = validate_seconds_field(
        "privilege expiry",
        seconds,
        PRIVILEGE_EXPIRY_MIN_SECONDS,
        PRIVILEGE_EXPIRY_MAX_SECONDS,
    )?;
    let mut warnings = Vec::new();
    apply_policy_write(
        cli,
        &group,
        PolicyField::PrivilegeExpiry,
        Some(seconds),
        "set_privilege_expiry",
        &mut warnings,
        |cli, group| cli.group_policy_privilege_expiry_set(group, seconds),
    )?;
    let group = verify_policy_field(cli, &group, PolicyField::PrivilegeExpiry, Some(seconds))?;
    Ok(CommandOutput {
        message: format!("set privilege-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: merge_warnings(warnings, group.warnings),
    })
}

pub fn reset_group_privilege_expiry(
    cli: &KanidmCli,
    group: &str,
) -> Result<CommandOutput, AppError> {
    let mut warnings = Vec::new();
    apply_policy_write(
        cli,
        group,
        PolicyField::PrivilegeExpiry,
        None,
        "reset_privilege_expiry",
        &mut warnings,
        |cli, group| cli.group_policy_privilege_expiry_reset(group),
    )?;
    let group = verify_policy_field(cli, group, PolicyField::PrivilegeExpiry, None)?;
    Ok(CommandOutput {
        message: format!("reset privilege-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: merge_warnings(warnings, group.warnings),
    })
}

fn apply_policy_write<F>(
    cli: &KanidmCli,
    group: &str,
    field: PolicyField,
    expected: Option<u64>,
    step_name: &str,
    warnings: &mut Vec<String>,
    action: F,
) -> Result<(), AppError>
where
    F: FnOnce(&KanidmCli, &str) -> Result<(), AppError>,
{
    match action(cli, group) {
        Ok(()) => Ok(()),
        Err(error) => {
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "group policy",
                    name: group,
                    requested_state: json!({
                        "group": group,
                        "field": policy_field_name(field),
                        "expected": expected,
                    }),
                    completed_steps: &[],
                    failed_step: step_name,
                    error,
                    next_actions: policy_next_actions(group),
                },
                || verify_policy_field(cli, group, field, expected),
                |_| true,
                policy_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            Ok(())
        }
    }
}

fn verify_policy_field(
    cli: &KanidmCli,
    group: &str,
    field: PolicyField,
    expected: Option<u64>,
) -> Result<crate::inventory::Parsed<crate::inventory::groups::GroupRecord>, AppError> {
    verify_with_retry(
        VerificationPolicy::PolicyConvergence,
        &format!("policy verification failed for Kanidm group '{group}'"),
        json!({
            "group": group,
            "field": policy_field_name(field),
            "expected": expected,
        }),
        true,
        || {
            let raw = cli.group_get::<Value>(group)?;
            let parsed = load_group(cli, group)?;
            let observed = json!({
                "group": parsed.value.name,
                "policy": parsed.value.policy,
                "warnings": parsed.warnings,
            });
            if matches_policy_value(&raw, field, expected) {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: parsed,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn policy_field_name(field: PolicyField) -> &'static str {
    match field {
        PolicyField::AuthExpiry => "auth_expiry_seconds",
        PolicyField::PrivilegeExpiry => "privilege_expiry_seconds",
    }
}

fn policy_observed_state(
    group: &crate::inventory::Parsed<crate::inventory::groups::GroupRecord>,
) -> Value {
    json!({
        "group": &group.value.name,
        "policy": &group.value.policy,
        "warnings": &group.warnings,
    })
}

fn policy_next_actions(group: &str) -> Vec<String> {
    vec![
        format!("Inspect the policy with `kanidm-admin policy group show {group}`."),
        "If the live policy is still wrong, rerun the policy command after confirming the group name.".to_string(),
    ]
}

fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}
