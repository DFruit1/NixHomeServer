use serde_json::{json, Value};

use crate::{
    inventory::policy::{matches_policy_value, PolicyField},
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck},
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
    cli.group_policy_auth_expiry_set(&group, seconds)?;
    let group = verify_policy_field(cli, &group, PolicyField::AuthExpiry, Some(seconds))?;
    Ok(CommandOutput {
        message: format!("set auth-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
    })
}

pub fn reset_group_auth_expiry(cli: &KanidmCli, group: &str) -> Result<CommandOutput, AppError> {
    cli.group_policy_auth_expiry_reset(group)?;
    let group = verify_policy_field(cli, group, PolicyField::AuthExpiry, None)?;
    Ok(CommandOutput {
        message: format!("reset auth-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
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
    cli.group_policy_privilege_expiry_set(&group, seconds)?;
    let group = verify_policy_field(cli, &group, PolicyField::PrivilegeExpiry, Some(seconds))?;
    Ok(CommandOutput {
        message: format!("set privilege-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
    })
}

pub fn reset_group_privilege_expiry(
    cli: &KanidmCli,
    group: &str,
) -> Result<CommandOutput, AppError> {
    cli.group_policy_privilege_expiry_reset(group)?;
    let group = verify_policy_field(cli, group, PolicyField::PrivilegeExpiry, None)?;
    Ok(CommandOutput {
        message: format!("reset privilege-expiry for group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
    })
}

fn verify_policy_field(
    cli: &KanidmCli,
    group: &str,
    field: PolicyField,
    expected: Option<u64>,
) -> Result<crate::inventory::Parsed<crate::inventory::groups::GroupRecord>, AppError> {
    verify_with_retry(
        &format!("policy verification failed for Kanidm group '{group}'"),
        json!({
            "group": group,
            "field": match field {
                PolicyField::AuthExpiry => "auth_expiry_seconds",
                PolicyField::PrivilegeExpiry => "privilege_expiry_seconds",
            },
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
