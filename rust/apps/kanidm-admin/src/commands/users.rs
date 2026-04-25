use serde_json::{json, Value};

use crate::{
    kanidm_cli::KanidmCli,
    models::{parse_person_list, parse_person_record, parse_reset_token_summary},
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

pub fn list_users(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let value = cli.person_list::<Value>()?;
    let people = parse_person_list(&value)?;
    let human = if people.is_empty() {
        "No Kanidm users found.".to_string()
    } else {
        let mut lines = vec![format!(
            "{:<20} {:<24} {}",
            "ACCOUNT ID", "DISPLAY NAME", "PRIMARY EMAIL"
        )];
        lines.extend(people.iter().map(|person| {
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
        message: format!("listed {} Kanidm user(s)", people.len()),
        human,
        details: json!({ "users": people }),
    })
}

pub fn show_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let value = cli.person_get::<Value>(account_id)?;
    let person = parse_person_record(&value, account_id)?;
    let human = format!(
        "Account ID: {}\nDisplay Name: {}\nPrimary Email: {}\nSPN: {}\nUUID: {}\nValid From: {}\nExpiry Date: {}\n\nManaged Login Groups:\n{}\n\nManaged Admin-Intent Groups:\n{}",
        person.account_id,
        person.display_name.as_deref().unwrap_or("-"),
        person.primary_email.as_deref().unwrap_or("-"),
        person.spn.as_deref().unwrap_or("-"),
        person.uuid.as_deref().unwrap_or("-"),
        person.valid_from.as_deref().unwrap_or("not set"),
        person.expiry.as_deref().unwrap_or("not set"),
        render_group_block(&person.access_groups.login),
        render_group_block(&person.access_groups.admin_intent),
    );

    Ok(CommandOutput {
        message: format!("loaded Kanidm user '{}'", person.account_id),
        human,
        details: json!({ "user": person }),
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
                "error": error.to_string(),
            }),
        });
    }

    let value = cli.person_get::<Value>(&options.account_id)?;
    let person = parse_person_record(&value, &options.account_id)?;
    let human = format!(
        "Created Kanidm user '{}'.\nDisplay Name: {}\nPrimary Email: {}\n\nManaged Login Groups:\n{}\n\nManaged Admin-Intent Groups:\n{}",
        person.account_id,
        person.display_name.as_deref().unwrap_or("-"),
        person.primary_email.as_deref().unwrap_or("-"),
        render_group_block(&person.access_groups.login),
        render_group_block(&person.access_groups.admin_intent),
    );

    Ok(CommandOutput {
        message: format!("created Kanidm user '{}'", person.account_id),
        human,
        details: json!({
            "user": person,
            "completed_steps": completed_steps,
        }),
    })
}

pub fn reset_token(cli: &KanidmCli, options: ResetTokenOptions) -> Result<CommandOutput, AppError> {
    let stdout = cli.person_create_reset_token(&options.account_id, options.ttl_seconds)?;
    let summary = parse_reset_token_summary(&stdout);

    let mut human = format!(
        "Created a password reset token for '{}'.\nTTL Seconds: {}",
        options.account_id, options.ttl_seconds
    );
    if let Some(url) = &summary.reset_url {
        human.push_str(&format!("\nReset URL: {url}"));
    }
    if let Some(token) = &summary.token {
        human.push_str(&format!("\nToken: {token}"));
    }
    human.push_str(
        "\n\nGive this token or link to the target user through a secure channel.\n\nRaw Output:\n",
    );
    human.push_str(if summary.raw_output.is_empty() {
        "(no output)"
    } else {
        &summary.raw_output
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
            "reset_token": summary,
        }),
    })
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
