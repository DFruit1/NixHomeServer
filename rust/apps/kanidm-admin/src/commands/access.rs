use serde_json::{json, Value};

use crate::{
    groups::{managed_group, required_group_for_app, AppAccessTarget},
    kanidm_cli::KanidmCli,
    models::{parse_person_record, PersonRecord},
    output::CommandOutput,
    AppError,
};

pub fn show_access(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let person = load_person(cli, account_id)?;
    Ok(CommandOutput {
        message: format!("loaded access groups for '{}'", person.account_id),
        human: human_access_summary(&person),
        details: json!({ "user": person }),
    })
}

pub fn grant_access(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
) -> Result<CommandOutput, AppError> {
    validate_managed_group(group)?;
    cli.group_add_members(group, account_id)?;
    verify_group_membership(cli, account_id, group, true)?;
    let person = load_person(cli, account_id)?;

    Ok(CommandOutput {
        message: format!("granted '{group}' to '{account_id}'"),
        human: format!(
            "Granted '{group}' to '{account_id}'.\n\n{}",
            human_access_summary(&person)
        ),
        details: json!({ "user": person, "changed_group": group, "action": "grant" }),
    })
}

pub fn revoke_access(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
) -> Result<CommandOutput, AppError> {
    validate_managed_group(group)?;
    cli.group_remove_members(group, account_id)?;
    verify_group_membership(cli, account_id, group, false)?;
    let person = load_person(cli, account_id)?;

    Ok(CommandOutput {
        message: format!("revoked '{group}' from '{account_id}'"),
        human: format!(
            "Revoked '{group}' from '{account_id}'.\n\n{}",
            human_access_summary(&person)
        ),
        details: json!({ "user": person, "changed_group": group, "action": "revoke" }),
    })
}

pub fn why_denied(
    cli: &KanidmCli,
    account_id: &str,
    app: AppAccessTarget,
) -> Result<CommandOutput, AppError> {
    let person = load_person(cli, account_id)?;
    let required_group = required_group_for_app(app);
    let has_required_group = person
        .access_groups
        .all_managed
        .iter()
        .any(|group| group == required_group);

    let human = if has_required_group {
        format!(
            "User '{}' already has the required login group '{}' for '{:?}'.\nThe denial is unlikely to be caused by missing repo-managed group membership.\n\n{}",
            person.account_id,
            required_group,
            app,
            human_access_summary(&person),
        )
    } else {
        format!(
            "User '{}' is missing the required login group '{}' for '{:?}'.\n\nFix:\nkanidm-admin access grant {} {}\n\n{}",
            person.account_id,
            required_group,
            app,
            person.account_id,
            required_group,
            human_access_summary(&person),
        )
    };

    Ok(CommandOutput {
        message: format!("evaluated likely access denial for '{}'", person.account_id),
        human,
        details: json!({
            "user": person,
            "app": app,
            "required_group": required_group,
            "has_required_group": has_required_group,
        }),
    })
}

fn load_person(cli: &KanidmCli, account_id: &str) -> Result<PersonRecord, AppError> {
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

fn verify_group_membership(
    cli: &KanidmCli,
    account_id: &str,
    group: &str,
    expected_present: bool,
) -> Result<(), AppError> {
    let person = load_person(cli, account_id)?;
    let actual_present = person
        .access_groups
        .all_managed
        .iter()
        .any(|candidate| candidate == group);

    if actual_present == expected_present {
        Ok(())
    } else {
        Err(AppError::Verification {
            message: format!(
                "post-change verification failed for user '{}' and group '{}'",
                account_id, group
            ),
            details: json!({
                "account_id": account_id,
                "group": group,
                "expected_present": expected_present,
                "actual_groups": person.access_groups.all_managed,
            }),
        })
    }
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
