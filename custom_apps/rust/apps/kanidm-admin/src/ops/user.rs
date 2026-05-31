use serde_json::{json, Value};

use crate::{
    context::SftpRuntimeConfig,
    inventory::{
        users::{parse_user_list, parse_user_record, UserRecord},
        Parsed,
    },
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck, VerificationPolicy},
    models::parse_reset_token_summary,
    ops::{
        reconcile_failed_write,
        sftp::{diagnose_sftp_login, set_posix_password_and_verify, test_sftp_login},
        FailedWriteContext, ReconciledWrite,
    },
    output::{CommandOutput, Sensitivity},
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_seconds_field,
        RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
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
pub struct PosixPasswordOptions {
    pub account_id: String,
    pub password: String,
    pub run_auth_test: bool,
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
    let options = CreateUserOptions {
        account_id: validate_account_id(&options.account_id)?,
        display_name: validate_display_name(&options.display_name)?,
        email: options.email.as_deref().map(validate_email).transpose()?,
        clear_validity: options.clear_validity,
    };
    let requested_state = requested_user_state(&options);
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();

    match cli.person_create(&options.account_id, &options.display_name) {
        Ok(()) => completed_steps.push("person_create".to_string()),
        Err(AppError::AlreadyExists {
            message,
            resource,
            name,
            details,
        }) => {
            let observed_state = match load_user(cli, &options.account_id) {
                Ok(user) => user_observed_state(&user),
                Err(error) => error.json_payload(),
            };
            return Err(AppError::AlreadyExists {
                message,
                resource,
                name,
                details: json!({
                    "resource": "user",
                    "name": options.account_id,
                    "requested_state": requested_state,
                    "observed_state": observed_state,
                    "next_actions": create_user_next_actions("person_create", &options.account_id),
                    "backend": details.get("backend").cloned().unwrap_or(details),
                }),
            });
        }
        Err(error) => return Err(error),
    }

    if options.clear_validity {
        run_create_step(
            cli,
            &options,
            &requested_state,
            &mut completed_steps,
            &mut warnings,
            "clear_expiry",
            |cli, account_id| cli.clear_expiry(account_id),
        )?;
        run_create_step(
            cli,
            &options,
            &requested_state,
            &mut completed_steps,
            &mut warnings,
            "clear_valid_from",
            |cli, account_id| cli.clear_valid_from(account_id),
        )?;
    }

    if options.email.is_some() {
        run_create_step(
            cli,
            &options,
            &requested_state,
            &mut completed_steps,
            &mut warnings,
            "update_mail",
            |cli, account_id| {
                cli.update_mail(account_id, options.email.as_deref().expect("email present"))
            },
        )?;
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
            "requested_state": requested_state,
            "observed_state": user_observed_state(&person),
            "user": person.value,
            "completed_steps": completed_steps,
        }),
        warnings: merge_warnings(warnings, person.warnings),
    })
}

pub fn disable_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let requested_state = json!({ "account_id": account_id, "expiry": "set" });
    let mut warnings = Vec::new();
    let person = match cli.person_disable(account_id) {
        Ok(()) => verify_disabled_user(cli, account_id)?,
        Err(error) => {
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user",
                    name: account_id,
                    requested_state,
                    completed_steps: &[],
                    failed_step: "person_disable",
                    error,
                    next_actions: user_state_next_actions(account_id),
                },
                || verify_disabled_user(cli, account_id),
                |_| true,
                user_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            value
        }
    };

    Ok(CommandOutput {
        message: format!("disabled Kanidm user '{}'", person.value.account_id),
        human: format!(
            "Disabled Kanidm user '{}'.\n\n{}",
            person.value.account_id,
            human_user_summary(&person.value)
        ),
        details: json!({ "user": person.value, "action": "disable" }),
        warnings: merge_warnings(warnings, person.warnings),
    })
}

pub fn enable_user(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    let requested_state = json!({
        "account_id": account_id,
        "valid_from": Value::Null,
        "expiry": Value::Null,
    });
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();
    run_enable_step(
        cli,
        account_id,
        &requested_state,
        &mut completed_steps,
        &mut warnings,
        "clear_expiry",
        |cli, account_id| cli.clear_expiry(account_id),
    )?;
    run_enable_step(
        cli,
        account_id,
        &requested_state,
        &mut completed_steps,
        &mut warnings,
        "clear_valid_from",
        |cli, account_id| cli.clear_valid_from(account_id),
    )?;
    let person = verify_enabled_user(cli, account_id)?;

    Ok(CommandOutput {
        message: format!("enabled Kanidm user '{}'", person.value.account_id),
        human: format!(
            "Enabled Kanidm user '{}'.\n\n{}",
            person.value.account_id,
            human_user_summary(&person.value)
        ),
        details: json!({
            "user": person.value,
            "action": "enable",
            "completed_steps": completed_steps,
        }),
        warnings: merge_warnings(warnings, person.warnings),
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

    let requested_state = json!({ "account_id": options.account_id, "deleted": true });
    let mut warnings = Vec::new();
    match cli.person_delete(&options.account_id) {
        Ok(()) => {
            verify_user_deleted(cli, &options.account_id)?;
        }
        Err(error) => {
            let ReconciledWrite { warning, .. } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user",
                    name: &options.account_id,
                    requested_state,
                    completed_steps: &[],
                    failed_step: "person_delete",
                    error,
                    next_actions: delete_user_next_actions(&options.account_id),
                },
                || verify_user_deleted(cli, &options.account_id),
                |_| true,
                |observed| observed.clone(),
            )?;
            warnings.push(warning);
        }
    };

    Ok(CommandOutput {
        message: format!("deleted Kanidm user '{}'", options.account_id),
        human: format!("Deleted Kanidm user '{}'.", options.account_id),
        details: json!({
            "account_id": options.account_id,
            "deleted": true,
        }),
        warnings,
    })
}

pub fn reset_token(cli: &KanidmCli, options: ResetTokenOptions) -> Result<CommandOutput, AppError> {
    let options = ResetTokenOptions {
        account_id: validate_account_id(&options.account_id)?,
        ttl_seconds: validate_seconds_field(
            "reset token TTL",
            options.ttl_seconds,
            RESET_TOKEN_TTL_MIN_SECONDS,
            RESET_TOKEN_TTL_MAX_SECONDS,
        )?,
    };
    let stdout = cli.person_create_reset_token(&options.account_id, options.ttl_seconds)?;
    let summary = parse_reset_token_summary(&stdout);

    let mut human = format!(
        "Created a temporary password reset link for '{}'.\nExpires In: {} seconds",
        options.account_id, options.ttl_seconds
    );
    if let Some(url) = &summary.value.reset_url {
        human.push_str(&format!("\nReset Link: {url}"));
    }
    if let Some(token) = &summary.value.token {
        human.push_str(&format!("\nFallback Token: {token}"));
    }
    human.push_str(
        "\n\nOperator Checklist:\n- Send the link through a secure channel.\n- Do not paste the link or token into shared chat.\n- Regenerate the reset link if it was mishandled.\n\nIf the link is unusable, the fallback token may still help with manual recovery.\n\nRaw Output:\n",
    );
    human.push_str(if summary.value.raw_output.is_empty() {
        "(no output)"
    } else {
        &summary.value.raw_output
    });

    Ok(CommandOutput::new(
        format!(
            "created a password reset token for '{}'",
            options.account_id
        ),
        human,
        json!({
            "sensitive_fields": ["reset_token"],
            "account_id": options.account_id,
            "ttl_seconds": options.ttl_seconds,
            "parsed_fields_complete": summary.value.token.is_some() && summary.value.reset_url.is_some() && summary.warnings.is_empty(),
            "reset_token": summary.value,
        }),
    )
    .with_sensitivity(Sensitivity::Sensitive)
    .with_warnings(summary.warnings))
}

pub fn set_posix_password(
    cli: &KanidmCli,
    options: PosixPasswordOptions,
) -> Result<CommandOutput, AppError> {
    set_posix_password_with_config(cli, &SftpRuntimeConfig::default(), options)
}

pub fn set_posix_password_with_config(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    options: PosixPasswordOptions,
) -> Result<CommandOutput, AppError> {
    set_posix_password_and_verify(cli, config, options)
}

pub fn test_posix_password(cli: &KanidmCli, account_id: &str) -> Result<CommandOutput, AppError> {
    test_posix_password_with_config(cli, &SftpRuntimeConfig::default(), account_id)
}

pub fn test_posix_password_with_config(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    test_sftp_login(cli, config, account_id, true)
}

pub fn diagnose_posix_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    diagnose_posix_password_with_config(cli, &SftpRuntimeConfig::default(), account_id)
}

pub fn diagnose_posix_password_with_config(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    diagnose_sftp_login(cli, config, account_id)
}

pub fn load_user(cli: &KanidmCli, account_id: &str) -> Result<Parsed<UserRecord>, AppError> {
    parse_user_record(&cli.person_get::<Value>(account_id)?, account_id)
}

fn run_create_step<F>(
    cli: &KanidmCli,
    options: &CreateUserOptions,
    requested_state: &Value,
    completed_steps: &mut Vec<String>,
    warnings: &mut Vec<String>,
    step_name: &str,
    action: F,
) -> Result<(), AppError>
where
    F: FnOnce(&KanidmCli, &str) -> Result<(), AppError>,
{
    match action(cli, &options.account_id) {
        Ok(()) => {
            completed_steps.push(step_name.to_string());
            Ok(())
        }
        Err(error) => {
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user",
                    name: &options.account_id,
                    requested_state: requested_state.clone(),
                    completed_steps,
                    failed_step: step_name,
                    error,
                    next_actions: create_user_next_actions(step_name, &options.account_id),
                },
                || load_user(cli, &options.account_id),
                |user: &Parsed<UserRecord>| user_matches_requested(&user.value, options),
                user_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            completed_steps.push(step_name.to_string());
            Ok(())
        }
    }
}

fn run_enable_step<F>(
    cli: &KanidmCli,
    account_id: &str,
    requested_state: &Value,
    completed_steps: &mut Vec<String>,
    warnings: &mut Vec<String>,
    step_name: &str,
    action: F,
) -> Result<(), AppError>
where
    F: FnOnce(&KanidmCli, &str) -> Result<(), AppError>,
{
    match action(cli, account_id) {
        Ok(()) => {
            completed_steps.push(step_name.to_string());
            Ok(())
        }
        Err(error) => {
            let ReconciledWrite { value, warning } = reconcile_failed_write(
                FailedWriteContext {
                    resource: "user",
                    name: account_id,
                    requested_state: requested_state.clone(),
                    completed_steps,
                    failed_step: step_name,
                    error,
                    next_actions: user_state_next_actions(account_id),
                },
                || verify_enabled_user(cli, account_id),
                |_| true,
                user_observed_state,
            )?;
            warnings.push(warning);
            warnings.extend(value.warnings.iter().cloned());
            completed_steps.push(step_name.to_string());
            Ok(())
        }
    }
}

fn verify_disabled_user(cli: &KanidmCli, account_id: &str) -> Result<Parsed<UserRecord>, AppError> {
    verify_user_state(
        cli,
        account_id,
        json!({ "account_id": account_id, "expiry": "set" }),
        &format!(
            "disabled Kanidm user '{}' but post-change verification did not converge",
            account_id
        ),
        true,
        |person| person.expiry.is_some(),
    )
}

fn verify_enabled_user(cli: &KanidmCli, account_id: &str) -> Result<Parsed<UserRecord>, AppError> {
    verify_user_state(
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
    )
}

fn verify_user_deleted(cli: &KanidmCli, account_id: &str) -> Result<Value, AppError> {
    verify_with_retry(
        VerificationPolicy::ReadAfterWrite,
        &format!(
            "deleted Kanidm user '{account_id}' but post-delete verification did not converge"
        ),
        json!({ "account_id": account_id, "deleted": true }),
        true,
        || match load_user(cli, account_id) {
            Err(AppError::NotFound { .. }) => Ok(VerificationCheck::Matched {
                observed: json!({
                    "deleted": true,
                    "account_id": account_id,
                }),
                value: json!({
                    "deleted": true,
                    "account_id": account_id,
                }),
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
    )
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
    verify_with_retry(
        VerificationPolicy::ReadAfterWrite,
        context,
        expected_state,
        write_completed,
        || {
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
        },
    )
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

fn requested_user_state(options: &CreateUserOptions) -> Value {
    json!({
        "account_id": options.account_id,
        "display_name": options.display_name,
        "primary_email": options.email,
        "clear_validity": options.clear_validity,
    })
}

fn user_matches_requested(user: &UserRecord, options: &CreateUserOptions) -> bool {
    user.account_id == options.account_id
        && user.display_name.as_deref() == Some(options.display_name.as_str())
        && options
            .email
            .as_ref()
            .is_none_or(|email| user.primary_email.as_ref() == Some(email))
        && (!options.clear_validity || (user.valid_from.is_none() && user.expiry.is_none()))
}

fn user_observed_state(user: &Parsed<UserRecord>) -> Value {
    json!({
        "user": &user.value,
        "warnings": &user.warnings,
    })
}

fn create_user_next_actions(step_name: &str, account_id: &str) -> Vec<String> {
    match step_name {
        "person_create" => vec![
            format!("Inspect the existing user with `kanidm-admin user show {account_id}`."),
            "If the existing account is intentional, continue with access setup instead of creating it again.".to_string(),
        ],
        "update_mail" => vec![
            format!("Inspect the current user with `kanidm-admin user show {account_id}`."),
            format!("If the email is still missing, rerun `kanidm-admin user create {account_id} --display-name ... --email ...` or set the mail field directly."),
        ],
        _ => vec![
            format!("Inspect the current user with `kanidm-admin user show {account_id}`."),
            "If the validity fields are still restricted, rerun the create flow or clear them manually.".to_string(),
        ],
    }
}

fn user_state_next_actions(account_id: &str) -> Vec<String> {
    vec![
        format!("Inspect the current user with `kanidm-admin user show {account_id}`."),
        "If the live state is still wrong, rerun the command after confirming the target account."
            .to_string(),
    ]
}

fn delete_user_next_actions(account_id: &str) -> Vec<String> {
    vec![
        format!("Confirm whether the user still exists with `kanidm-admin user show {account_id}`."),
        "If the account still exists and deletion is still intended, rerun the delete command with the same --confirm value.".to_string(),
    ]
}

fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
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

#[cfg(test)]
mod tests {
    use std::{
        env, fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand,
    };

    use crate::{context::ResolvedContext, TEST_ENV_LOCK};

    use super::*;

    fn write_script(path: &Path, body: &str) {
        let shell = ProcessCommand::new("bash")
            .args(["-lc", "command -v bash"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .map(|stdout| stdout.trim().to_string())
            .filter(|stdout| !stdout.is_empty())
            .unwrap_or_else(|| "/bin/sh".to_string());
        let rewritten = body.replacen("#!/usr/bin/env bash", &format!("#!{shell}"), 1);
        fs::write(path, rewritten).expect("write script");
        let mut permissions = fs::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("chmod");
    }

    fn install_sftp_probe_stubs(bin_dir: &Path, account_id: &str, groups: &str) {
        write_script(
            &bin_dir.join("getent"),
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "passwd" && "$2" == {} ]]; then
  printf '{}:x:2000:2000:Test User:/home/{}:/bin/bash\n'
  exit 0
fi
exit 2
"#,
                serde_json::to_string(account_id).expect("json account"),
                account_id,
                account_id,
            ),
        );
        write_script(
            &bin_dir.join("id"),
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-nG" && "$2" == {} ]]; then
  printf '{}\n'
  exit 0
fi
exit 1
"#,
                serde_json::to_string(account_id).expect("json account"),
                groups,
            ),
        );
        write_script(
            &bin_dir.join("systemctl"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "is-active" ]]; then
  printf 'active\n'
  exit 0
fi
exit 1
"#,
        );
        write_script(
            &bin_dir.join("findmnt"),
            r#"#!/usr/bin/env bash
set -euo pipefail
printf '%s on %s type none (rw,bind)\n' "$1" "$1"
exit 0
"#,
        );
    }

    fn prepend_path(bin_dir: &Path) -> Option<std::ffi::OsString> {
        let original_path = env::var_os("PATH");
        let mut entries = vec![bin_dir.to_path_buf()];
        if let Some(path) = &original_path {
            entries.extend(env::split_paths(path));
        }
        env::set_var(
            "PATH",
            env::join_paths(entries).expect("join test PATH entries"),
        );
        original_path
    }

    fn restore_path(original_path: Option<std::ffi::OsString>) {
        match original_path {
            Some(path) => env::set_var("PATH", path),
            None => env::remove_var("PATH"),
        }
    }

    #[test]
    fn create_user_reports_existing_account_with_observed_state() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "person" && "${args[1]}" == "create" ]]; then
  printf 'user already exists\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "person" && "${args[1]}" == "get" && "${args[2]}" == "dsaw" ]]; then
  printf '{"attrs":{"name":["dsaw"],"displayname":["Dan"],"mail":["dsaw@example.test"]}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });

        let error = create_user(
            &cli,
            CreateUserOptions {
                account_id: "dsaw".to_string(),
                display_name: "Dan".to_string(),
                email: Some("dsaw@example.test".to_string()),
                clear_validity: true,
            },
        )
        .expect_err("already exists");

        match error {
            AppError::AlreadyExists { details, .. } => {
                assert_eq!(details["observed_state"]["user"]["account_id"], "dsaw");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn create_user_returns_partial_success_when_mail_update_does_not_converge() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state = dir.path().join("created");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
state_file={}
args=("$@")
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "create" ]]; then
  : > "$state_file"
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "validity" ]]; then
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "update" ]]; then
  printf 'mail update failed\n' >&2
  exit 1
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && -f "$state_file" ]]; then
  printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"]}}}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
                serde_json::to_string(&state.display().to_string()).expect("json path"),
            ),
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });

        let error = create_user(
            &cli,
            CreateUserOptions {
                account_id: "dsaw".to_string(),
                display_name: "Dan".to_string(),
                email: Some("dsaw@example.test".to_string()),
                clear_validity: true,
            },
        )
        .expect_err("partial success");

        match error {
            AppError::PartialSuccess { details, .. } => {
                assert_eq!(details["failed_step"], "update_mail");
                assert_eq!(details["observed_state"]["user"]["account_id"], "dsaw");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn create_user_succeeds_with_warning_when_mail_failure_already_converged() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state = dir.path().join("mail.txt");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
mail_file={}
args=("$@")
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "create" ]]; then
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "validity" ]]; then
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "update" ]]; then
  printf '%s' "${{args[4]}}" > "$mail_file"
  printf 'mail update failed\n' >&2
  exit 1
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" ]]; then
  mail_value="$(cat "$mail_file" 2>/dev/null || true)"
  if [[ -n "$mail_value" ]]; then
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"mail":["%s"]}}}}' "$mail_value"
  else
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"]}}}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
                serde_json::to_string(&state.display().to_string()).expect("json path"),
            ),
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });

        let output = create_user(
            &cli,
            CreateUserOptions {
                account_id: "dsaw".to_string(),
                display_name: "Dan".to_string(),
                email: Some("dsaw@example.test".to_string()),
                clear_validity: true,
            },
        )
        .expect("create user");

        assert!(output
            .warnings
            .iter()
            .any(|warning| warning.contains("update_mail")));
    }

    #[test]
    fn set_posix_password_runs_interactive_kanidm_command() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let recorded = dir.path().join("recorded-args.txt");
        let cache_recorded = dir.path().join("cache-recorded-args.txt");
        let script = dir.path().join("kanidm");
        let cache_script = dir.path().join("kanidm-unix");
        let chroot_base = dir.path().join("chroots");
        let users_root = dir.path().join("users");
        fs::create_dir_all(chroot_base.join("alice")).expect("chroot");
        fs::create_dir_all(users_root.join("alice")).expect("user root");
        install_sftp_probe_stubs(dir.path(), "alice", "users files-sftp-users");
        let original_path = prepend_path(dir.path());
        write_script(
            &script,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
recorded={}
args=("$@")
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "alice" ]]; then
  printf '{{"attrs":{{"name":["alice"],"displayname":["Alice"],"mail":["alice@example.test"],"directmemberof":["files-sftp-users"]}}}}'
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "posix" && "${{args[2]}}" == "set-password" ]]; then
  IFS= read -r password_one
  IFS= read -r password_two
  printf '%s\n%s\n%s\n' "$*" "$password_one" "$password_two" > "$recorded"
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
                serde_json::to_string(&recorded.display().to_string()).expect("json path"),
            ),
        );
        write_script(
            &cache_script,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "cache-invalidate" ]]; then
  printf '%s\n' "$*" > {}
fi
if [[ "$1" == "status" ]]; then
  printf 'system: online\nKanidm: online\n'
fi
"#,
                serde_json::to_string(&cache_recorded.display().to_string()).expect("json path"),
            ),
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });
        let config = SftpRuntimeConfig {
            sftp_chroot_base: chroot_base.display().to_string(),
            users_root: users_root.display().to_string(),
            ..SftpRuntimeConfig::default()
        };

        let output = set_posix_password_with_config(
            &cli,
            &config,
            PosixPasswordOptions {
                account_id: "alice".to_string(),
                password: "correct horse battery staple".to_string(),
                run_auth_test: false,
            },
        )
        .expect("set posix password");
        restore_path(original_path);

        let recorded_args = fs::read_to_string(recorded).expect("recorded args");
        assert!(recorded_args.contains("person posix set-password alice"));
        assert!(recorded_args.contains("--name admindsaw"));
        assert!(
            recorded_args.contains("correct horse battery staple\ncorrect horse battery staple")
        );
        let cache_recorded_args = fs::read_to_string(cache_recorded).expect("cache recorded args");
        assert_eq!(cache_recorded_args.trim(), "cache-invalidate");
        assert!(output
            .human
            .contains("Kanidm accepted the POSIX/UNIX password update"));
        assert!(output.human.contains("UnixD cache invalidated: yes"));
        assert!(output.human.contains("SFTP readiness: ready"));
        assert_eq!(output.details["kanidm_update_accepted"], true);
        assert_eq!(output.details["unixd_cache_invalidated"], true);
        assert_eq!(output.details["sftp_readiness"]["ready"], true);
        let rendered = serde_json::to_string(&output.json_payload()).expect("render json");
        assert!(!rendered.contains("correct horse battery staple"));
        assert!(output.warnings.is_empty());
    }

    #[test]
    fn set_posix_password_warns_when_unixd_cache_invalidation_fails() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let recorded = dir.path().join("recorded-args.txt");
        let script = dir.path().join("kanidm");
        let cache_script = dir.path().join("kanidm-unix");
        let chroot_base = dir.path().join("chroots");
        let users_root = dir.path().join("users");
        fs::create_dir_all(chroot_base.join("alice")).expect("chroot");
        fs::create_dir_all(users_root.join("alice")).expect("user root");
        install_sftp_probe_stubs(dir.path(), "alice", "users files-sftp-users");
        let original_path = prepend_path(dir.path());
        write_script(
            &script,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
recorded={}
args=("$@")
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "alice" ]]; then
  printf '{{"attrs":{{"name":["alice"],"displayname":["Alice"],"mail":["alice@example.test"],"directmemberof":["files-sftp-users"]}}}}'
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "posix" && "${{args[2]}}" == "set-password" ]]; then
  IFS= read -r password_one
  IFS= read -r password_two
  printf '%s\n%s\n%s\n' "$*" "$password_one" "$password_two" > "$recorded"
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
                serde_json::to_string(&recorded.display().to_string()).expect("json path"),
            ),
        );
        write_script(
            &cache_script,
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "cache-invalidate" ]]; then
  printf 'cache unavailable\n' >&2
  exit 1
fi
if [[ "$1" == "status" ]]; then
  printf 'system: online\nKanidm: online\n'
  exit 0
fi
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });
        let config = SftpRuntimeConfig {
            sftp_chroot_base: chroot_base.display().to_string(),
            users_root: users_root.display().to_string(),
            ..SftpRuntimeConfig::default()
        };

        let output = set_posix_password_with_config(
            &cli,
            &config,
            PosixPasswordOptions {
                account_id: "alice".to_string(),
                password: "correct horse battery staple".to_string(),
                run_auth_test: false,
            },
        )
        .expect("set posix password");
        restore_path(original_path);

        assert!(fs::read_to_string(recorded)
            .expect("recorded args")
            .contains("correct horse battery staple\ncorrect horse battery staple"));
        assert!(output.human.contains("UnixD cache invalidated: no"));
        assert_eq!(output.details["kanidm_update_accepted"], true);
        assert_eq!(output.details["unixd_cache_invalidated"], false);
        assert!(output
            .warnings
            .iter()
            .any(|warning| warning.contains("cache unavailable")));
    }
}
