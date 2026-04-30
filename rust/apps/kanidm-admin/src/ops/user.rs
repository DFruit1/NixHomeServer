use serde_json::{json, Value};

use crate::{
    inventory::{
        users::{parse_user_list, parse_user_record, UserRecord},
        Parsed,
    },
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck},
    models::parse_reset_token_summary,
    output::CommandOutput,
    AppError,
};

#[derive(Debug, Clone)]
pub struct CreateUserOptions {
    pub account_id: String,
    pub display_name: String,
    pub email: Option<String>,
    pub clear_validity: bool,
}

#[derive(Debug, Clone)]
pub struct ResetTokenOptions {
    pub account_id: String,
    pub ttl_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct DeleteUserOptions {
    pub account_id: String,
    pub confirm: String,
}

pub fn list_users(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let people = parse_user_list(&cli.person_list::<Value>()?)?;
    let human = if people.value.is_empty() {
        "No Kanidm users found.".to_string()
    } else {
        let mut lines = vec![format!(
            "{:<20} {:<24} {}",
            "ACCOUNT ID", "DISPLAY NAME", "PRIMARY EMAIL"
        )];
        lines.extend(people.value.iter().map(|person| {
            format!(
                "{:<20} {:<24} {}",
                person.account_id,
                person.display_name.as_deref().unwrap_or("-"),
                person.primary_email.as_deref().unwrap_or("-")
            )
        }));
        lines.join("\n")
    };

    Ok(CommandOutput {
        message: format!("listed {} Kanidm user(s)", people.value.len()),
        human,
        details: json!({ "users": people.value }),
        warnings: people.warnings,
    })
}

pub fn show_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let person = load_user(cli, account_id)?;
    Ok(CommandOutput {
        message: format!("loaded Kanidm user '{}'", person.value.account_id),
        human: human_user_summary(&person.value),
        details: json!({ "user": person.value }),
        warnings: person.warnings,
    })
}

pub fn create_user(cli: &KanidmCli, options: CreateUserOptions) -> Result<CommandOutput, AppError> {
    cli.person_create(&options.account_id, &options.display_name)?;

    let mut completed_steps = vec!["person_create".to_string()];
    if let Err(error) = finish_create(cli, &options, &mut completed_steps) {
        return Err(AppError::Verification {
            message: format!(
                "created Kanidm user '{}' but later setup steps failed",
                options.account_id
            ),
            details: json!({
                "account_id": options.account_id,
                "completed_steps": completed_steps,
                "write_completed": true,
                "error": error.json_payload(),
            }),
        });
    }

    let person = verify_user_state(
        cli,
        &options.account_id,
        json!({
            "account_id": options.account_id,
            "primary_email": options.email,
            "valid_from": if options.clear_validity { Value::Null } else { json!("unchanged") },
            "expiry": if options.clear_validity { Value::Null } else { json!("unchanged") },
        }),
        &format!(
            "created Kanidm user '{}' but post-create verification did not converge",
            options.account_id
        ),
        true,
        |person| {
            person.account_id == options.account_id
                && options
                    .email
                    .as_ref()
                    .is_none_or(|email| person.primary_email.as_ref() == Some(email))
                && (!options.clear_validity
                    || (person.valid_from.is_none() && person.expiry.is_none()))
        },
    )?;

    Ok(CommandOutput {
        message: format!("created Kanidm user '{}'", person.value.account_id),
        human: format!(
            "Created Kanidm user '{}'.\n\n{}",
            person.value.account_id,
            human_user_summary(&person.value)
        ),
        details: json!({
            "user": person.value,
            "completed_steps": completed_steps,
        }),
        warnings: person.warnings,
    })
}

pub fn disable_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    cli.person_disable(account_id)?;
    let person = verify_user_state(
        cli,
        account_id,
        json!({ "account_id": account_id, "expiry": "set" }),
        &format!(
            "disabled Kanidm user '{}' but post-change verification did not converge",
            account_id
        ),
        true,
        |person| person.expiry.is_some(),
    )?;

    Ok(CommandOutput {
        message: format!("disabled Kanidm user '{}'", person.value.account_id),
        human: format!(
            "Disabled Kanidm user '{}'.\n\n{}",
            person.value.account_id,
            human_user_summary(&person.value)
        ),
        details: json!({ "user": person.value, "action": "disable" }),
        warnings: person.warnings,
    })
}

pub fn enable_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    cli.person_enable(account_id)?;
    let person = verify_user_state(
        cli,
        account_id,
        json!({
            "account_id": account_id,
            "valid_from": Value::Null,
            "expiry": Value::Null,
        }),
        &format!(
            "enabled Kanidm user '{}' but post-change verification did not converge",
            account_id
        ),
        true,
        |person| person.valid_from.is_none() && person.expiry.is_none(),
    )?;

    Ok(CommandOutput {
        message: format!("enabled Kanidm user '{}'", person.value.account_id),
        human: format!(
            "Enabled Kanidm user '{}'.\n\n{}",
            person.value.account_id,
            human_user_summary(&person.value)
        ),
        details: json!({ "user": person.value, "action": "enable" }),
        warnings: person.warnings,
    })
}

pub fn delete_user(cli: &KanidmCli, options: DeleteUserOptions) -> Result<CommandOutput, AppError> {
    if options.confirm != options.account_id {
        return Err(AppError::Config {
            message: format!(
                "deleting '{}' requires --confirm {}",
                options.account_id, options.account_id
            ),
        });
    }

    cli.person_delete(&options.account_id)?;
    verify_with_retry(
        &format!(
            "deleted Kanidm user '{}' but post-delete verification did not converge",
            options.account_id
        ),
        json!({ "account_id": options.account_id, "deleted": true }),
        true,
        || match load_user(cli, &options.account_id) {
            Err(AppError::NotFound { .. }) => Ok(VerificationCheck::Matched {
                observed: json!({
                    "deleted": true,
                    "account_id": options.account_id,
                }),
                value: (),
            }),
            Err(error) => Err(error),
            Ok(person) => Ok(VerificationCheck::Mismatch {
                observed: json!({
                    "deleted": false,
                    "account_id": person.value.account_id,
                    "user": person.value,
                    "warnings": person.warnings,
                }),
            }),
        },
    )?;

    Ok(CommandOutput {
        message: format!("deleted Kanidm user '{}'", options.account_id),
        human: format!("Deleted Kanidm user '{}'.", options.account_id),
        details: json!({
            "account_id": options.account_id,
            "deleted": true,
        }),
        warnings: Vec::new(),
    })
}

pub fn reset_token(cli: &KanidmCli, options: ResetTokenOptions) -> Result<CommandOutput, AppError> {
    let stdout = cli.person_create_reset_token(&options.account_id, options.ttl_seconds)?;
    let summary = parse_reset_token_summary(&stdout);

    let mut human = format!(
        "Created a password reset token for '{}'.\nTTL Seconds: {}",
        options.account_id, options.ttl_seconds
    );
    if let Some(url) = &summary.value.reset_url {
        human.push_str(&format!("\nReset URL: {url}"));
    }
    if let Some(token) = &summary.value.token {
        human.push_str(&format!("\nToken: {token}"));
    }
    human.push_str(
        "\n\nGive this token or link to the target user through a secure channel.\n\nRaw Output:\n",
    );
    human.push_str(if summary.value.raw_output.is_empty() {
        "(no output)"
    } else {
        &summary.value.raw_output
    });

    Ok(CommandOutput {
        message: format!(
            "created a password reset token for '{}'",
            options.account_id
        ),
        human,
        details: json!({
            "account_id": options.account_id,
            "ttl_seconds": options.ttl_seconds,
            "parsed_fields_complete": summary.value.token.is_some() && summary.value.reset_url.is_some() && summary.warnings.is_empty(),
            "reset_token": summary.value,
        }),
        warnings: summary.warnings,
    })
}

pub fn load_user(cli: &KanidmCli, account_id: &str) -> Result<Parsed<UserRecord>, AppError> {
    parse_user_record(&cli.person_get::<Value>(account_id)?, account_id)
}

fn finish_create(
    cli: &KanidmCli,
    options: &CreateUserOptions,
    completed_steps: &mut Vec<String>,
) -> Result<(), AppError> {
    if options.clear_validity {
        cli.clear_expiry(&options.account_id)?;
        completed_steps.push("clear_expiry".to_string());
        cli.clear_valid_from(&options.account_id)?;
        completed_steps.push("clear_valid_from".to_string());
    }

    if let Some(email) = &options.email {
        cli.update_mail(&options.account_id, email)?;
        completed_steps.push("update_mail".to_string());
    }

    Ok(())
}

fn verify_user_state<F>(
    cli: &KanidmCli,
    account_id: &str,
    expected_state: Value,
    context: &str,
    write_completed: bool,
    predicate: F,
) -> Result<Parsed<UserRecord>, AppError>
where
    F: Fn(&UserRecord) -> bool,
{
    verify_with_retry(context, expected_state, write_completed, || {
        let user = load_user(cli, account_id)?;
        let matched = predicate(&user.value);
        let observed = json!({
            "user": &user.value,
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
    })
}

pub fn human_user_summary(user: &UserRecord) -> String {
    format!(
        "Account ID: {}\nDisplay Name: {}\nPrimary Email: {}\nSPN: {}\nUUID: {}\nValid From: {}\nExpiry Date: {}\n\nDirect Groups:\n{}",
        user.account_id,
        user.display_name.as_deref().unwrap_or("-"),
        user.primary_email.as_deref().unwrap_or("-"),
        user.spn.as_deref().unwrap_or("-"),
        user.uuid.as_deref().unwrap_or("-"),
        user.valid_from.as_deref().unwrap_or("not set"),
        user.expiry.as_deref().unwrap_or("not set"),
        render_group_block(&user.groups),
    )
}

fn render_group_block(groups: &[String]) -> String {
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
