pub mod controller;
pub mod forms;
pub mod home;
pub mod render;

pub use controller::run;

use serde_json::Value;

use crate::{
    context::ResolvedContext,
    inventory::{groups::GroupSummary, users::UserRecord},
    kanidm_cli::{KanidmCli, SessionSnapshot},
    ops::{
        client::{
            client_consent_disable, client_consent_enable, client_pkce_disable, client_pkce_enable,
            client_redirect_add, client_redirect_remove, client_secret_reset, client_secret_show,
            list_clients, show_client,
        },
        context::{doctor, show_context},
        executor::{
            execute_interactive_operation, OperationKind, OperationOutcome, OperationPreconditions,
            RecoveryTarget,
        },
        group::{group_members, list_groups, search_groups, show_group},
        local::{invite_vaultwarden_user, lookup_vaultwarden_user, stage_jellyfin_password},
        membership::{
            add_membership_with_config, prepare_membership_picker_inventory,
            remove_membership_with_config, set_membership_with_config, show_membership,
            SetMembershipOptions,
        },
        policy::{
            reset_group_auth_expiry, reset_group_privilege_expiry, set_group_auth_expiry,
            set_group_privilege_expiry, show_group_policy,
        },
        session::{session_login, session_logout, session_reauth, session_status},
        user::{
            create_user, delete_user, disable_user, enable_user, load_user, reset_token,
            set_posix_password_with_config, CreateUserOptions, DeleteUserOptions,
            PosixPasswordOptions, ResetTokenOptions,
        },
    },
    output::{
        render_backend_steps_full, render_backend_steps_summary, render_error, section_title,
        CommandOutput, OutputFormat,
    },
    session_state::{
        concise_session_message, login_prompt_message, should_prompt_for_startup_login,
    },
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url_for_server, validate_seconds_field, AUTH_EXPIRY_MAX_SECONDS,
        AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS, PRIVILEGE_EXPIRY_MIN_SECONDS,
        RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
    AppError,
};

fn advanced_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "Advanced",
        Some(
            "Specialized Kanidm session management, lower-level tools, and local helpers live here. Use this area when the guided day-to-day workflows are not enough.",
        ),
        &advanced_menu_items(),
        0,
    )? {
        match selection {
            0 => session_tools_menu(kanidm)?,
            1 => group_inspection_menu(kanidm)?,
            2 => membership_tools_menu(context, kanidm)?,
            3 => clients_menu(kanidm)?,
            4 => policy_menu(kanidm)?,
            5 => context_menu(context, kanidm)?,
            6 => local_helpers_menu(context, kanidm)?,
            7 => delete_user_flow(kanidm)?,
            _ => break,
        }
    }
    Ok(())
}

fn session_tools_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) =
        forms::contextual_select("Session Tools", None, &session_tools_items(), 0)?
    {
        match selection {
            0 => session_status_flow(kanidm)?,
            1 => run_session_command("Login", kanidm, || session_login(kanidm))?,
            2 => run_session_command("Reauthenticate", kanidm, || session_reauth(kanidm))?,
            3 => run_session_command("Logout", kanidm, || session_logout(kanidm))?,
            _ => break,
        }
    }
    Ok(())
}

fn group_inspection_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) =
        forms::contextual_select("Group Inspection", None, &group_inspection_items(), 0)?
    {
        match selection {
            0 => run_command("Groups", kanidm, || list_groups(kanidm))?,
            1 => {
                let Some(query) = prompt_submitted(forms::input_required("Search query", None)?)
                else {
                    continue;
                };
                run_command("Group Search", kanidm, || search_groups(kanidm, &query))?;
            }
            2 => group_target_flow_with_scope(
                kanidm,
                "Select a group to inspect",
                GroupPickerScope::AllGroups,
                |group| show_group(kanidm, group),
            )?,
            3 => group_target_flow_with_scope(
                kanidm,
                "Select a group to inspect members",
                GroupPickerScope::AllGroups,
                |group| group_members(kanidm, group),
            )?,
            _ => break,
        }
    }
    Ok(())
}

fn membership_tools_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) =
        forms::contextual_select("Membership Tools", None, &membership_tools_items(), 0)?
    {
        match selection {
            0 => user_target_flow(kanidm, "Select a user to inspect access", |account_id| {
                show_membership(kanidm, account_id)
            })?,
            1 => membership_change_flow(context, kanidm, MembershipChange::Add)?,
            2 => membership_change_flow(context, kanidm, MembershipChange::Remove)?,
            3 => edit_membership_flow(context, kanidm)?,
            _ => break,
        }
    }
    Ok(())
}

fn clients_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "OAuth2 Clients",
        Some(
            "Inspect live OAuth2 clients, secrets, redirect URLs, PKCE, and consent prompts. Use filtering to narrow long client lists quickly.",
        ),
        &client_menu_items(),
        0,
    )? {
        match selection {
            0 => run_command("OAuth2 Clients", kanidm, || list_clients(kanidm))?,
            1 => {
                client_target_flow(kanidm, "Select an oauth2 client to inspect", |client| {
                    show_client(kanidm, client)
                })?
            }
            2 => {
                client_target_flow(kanidm, "Select an oauth2 client secret to show", |client| {
                    client_secret_show(kanidm, client)
                })?
            }
            3 => client_target_flow_privileged(
                kanidm,
                "Select an oauth2 client secret to reset",
                |client| client_secret_reset(kanidm, client),
            )?,
            4 => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_pkce_enable(kanidm, client)
                })?
            }
            5 => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_pkce_disable(kanidm, client)
                })?
            }
            6 => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_consent_enable(kanidm, client)
                })?
            }
            7 => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_consent_disable(kanidm, client)
                })?
            }
            8 => redirect_flow(kanidm, true)?,
            9 => redirect_flow(kanidm, false)?,
            _ => break,
        }
    }
    Ok(())
}

fn policy_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "Group Policy",
        Some(
            "Inspect or tune live Kanidm account-policy settings for a group. All live groups are shown here, including internal Kanidm groups.",
        ),
        &policy_menu_items(),
        0,
    )? {
        match selection {
            0 => group_target_flow_with_scope(
                kanidm,
                "Select a group to inspect",
                GroupPickerScope::AllGroups,
                |group| show_group_policy(kanidm, group),
            )?,
            1 => policy_set_flow(kanidm, true)?,
            2 => policy_reset_flow(kanidm, true)?,
            3 => policy_set_flow(kanidm, false)?,
            4 => policy_reset_flow(kanidm, false)?,
            _ => break,
        }
    }
    Ok(())
}

fn context_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "Context",
        Some(
            "Inspect the resolved repo and Kanidm connection context or run basic environment checks when discovery or sessions look unhealthy.",
        ),
        &context_menu_items(),
        0,
    )? {
        match selection {
            0 => {
                render_output("Context", show_context(context))?;
            }
            1 => {
                run_command("Doctor", kanidm, || doctor(context, kanidm, false))?;
            }
            _ => break,
        }
    }
    Ok(())
}

fn policy_set_flow(kanidm: &KanidmCli, auth: bool) -> Result<(), AppError> {
    let prompt = if auth {
        "Select a group for auth-expiry"
    } else {
        "Select a group for privilege-expiry"
    };
    let Some(group) = choose_group_name_with_scope(kanidm, prompt, GroupPickerScope::AllGroups)?
    else {
        return Ok(());
    };
    let Some(seconds_text) =
        prompt_submitted(forms::input_required("Expiry in seconds", Some("3600"))?)
    else {
        return Ok(());
    };
    let seconds = validate_seconds_field(
        if auth {
            "auth expiry"
        } else {
            "privilege expiry"
        },
        seconds_text
            .parse::<u64>()
            .map_err(|error| AppError::Config {
                message: format!("invalid expiry '{seconds_text}': {error}"),
            })?,
        if auth {
            AUTH_EXPIRY_MIN_SECONDS
        } else {
            PRIVILEGE_EXPIRY_MIN_SECONDS
        },
        if auth {
            AUTH_EXPIRY_MAX_SECONDS
        } else {
            PRIVILEGE_EXPIRY_MAX_SECONDS
        },
    )?;
    let Some(group_record) =
        require_complete_group_for_action(kanidm, &group, "change live Kanidm group policy for")?
    else {
        return Ok(());
    };
    let current_value = if auth {
        group_record.value.policy.auth_expiry_seconds
    } else {
        group_record.value.policy.privilege_expiry_seconds
    };
    if current_value == Some(seconds) {
        render::print_note("Group Policy", "No policy changes would be applied.");
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note(
        "Review Group Policy Change",
        &build_policy_review(&group_record.value, auth, PolicyChange::Set(seconds)),
    );
    match forms::confirm("Apply this group policy change now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    if auth {
        run_privileged_command("Group Policy", kanidm, || {
            set_group_auth_expiry(kanidm, &group, seconds)
        })
    } else {
        run_privileged_command("Group Policy", kanidm, || {
            set_group_privilege_expiry(kanidm, &group, seconds)
        })
    }
}

fn policy_reset_flow(kanidm: &KanidmCli, auth: bool) -> Result<(), AppError> {
    let prompt = if auth {
        "Select a group to reset auth-expiry"
    } else {
        "Select a group to reset privilege-expiry"
    };
    let Some(group) = choose_group_name_with_scope(kanidm, prompt, GroupPickerScope::AllGroups)?
    else {
        return Ok(());
    };
    let Some(group_record) =
        require_complete_group_for_action(kanidm, &group, "change live Kanidm group policy for")?
    else {
        return Ok(());
    };
    let current_value = if auth {
        group_record.value.policy.auth_expiry_seconds
    } else {
        group_record.value.policy.privilege_expiry_seconds
    };
    if current_value.is_none() {
        render::print_note("Group Policy", "No policy changes would be applied.");
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note(
        "Review Group Policy Reset",
        &build_policy_review(&group_record.value, auth, PolicyChange::Reset),
    );
    match forms::confirm("Apply this group policy change now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    if auth {
        run_privileged_command("Group Policy", kanidm, || {
            reset_group_auth_expiry(kanidm, &group)
        })
    } else {
        run_privileged_command("Group Policy", kanidm, || {
            reset_group_privilege_expiry(kanidm, &group)
        })
    }
}

fn perform_command<F>(kanidm: &KanidmCli, action: F) -> Result<Option<CommandOutput>, AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    kanidm.begin_backend_operation();
    match execute_interactive_operation(
        kanidm,
        OperationKind::Read,
        OperationPreconditions::None,
        action,
        |target, error, _snapshot| recover_target_interactively(kanidm, target, error),
    )? {
        OperationOutcome::Success(output) => Ok(Some(output)),
        OperationOutcome::Cancelled => Ok(None),
        OperationOutcome::RecoverableFailure(error) | OperationOutcome::Fatal(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(None)
        }
    }
}

fn perform_interactive_read<T, F>(kanidm: &KanidmCli, mut action: F) -> Result<Option<T>, AppError>
where
    F: FnMut() -> Result<T, AppError>,
{
    kanidm.begin_backend_operation();
    match execute_interactive_operation(
        kanidm,
        OperationKind::Read,
        OperationPreconditions::None,
        &mut action,
        |target, error, _snapshot| recover_target_interactively(kanidm, target, error),
    )? {
        OperationOutcome::Success(value) => Ok(Some(value)),
        OperationOutcome::Cancelled => Ok(None),
        OperationOutcome::RecoverableFailure(error) | OperationOutcome::Fatal(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(None)
        }
    }
}

fn prompt_submitted<T>(result: forms::PromptResult<T>) -> Option<T> {
    match result {
        forms::PromptResult::Submitted(value) => Some(value),
        forms::PromptResult::Cancelled => None,
    }
}

fn prompt_optional_submitted<T>(
    result: forms::PromptResult<Option<T>>,
) -> Result<Option<T>, AppError> {
    Ok(match result {
        forms::PromptResult::Submitted(value) => value,
        forms::PromptResult::Cancelled => None,
    })
}

fn perform_privileged_command<F>(
    kanidm: &KanidmCli,
    action: F,
) -> Result<PrivilegedCommandResult, AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    kanidm.begin_backend_operation();
    match execute_interactive_operation(
        kanidm,
        OperationKind::PrivilegedWrite,
        OperationPreconditions::PrivilegedWriteReady,
        action,
        |target, error, snapshot| {
            recover_target_interactively_with_snapshot(kanidm, target, error, snapshot)
        },
    )? {
        OperationOutcome::Success(output) => Ok(PrivilegedCommandResult::Output(output)),
        OperationOutcome::Cancelled => Ok(PrivilegedCommandResult::Cancelled),
        OperationOutcome::RecoverableFailure(error) | OperationOutcome::Fatal(error) => {
            Ok(PrivilegedCommandResult::Error(error))
        }
    }
}

fn run_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    if let Some(mut output) = perform_command(kanidm, action)? {
        attach_backend_steps(kanidm, &mut output);
        render_output(title, output)?;
    }
    Ok(())
}

fn run_privileged_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    match perform_privileged_command(kanidm, action)? {
        PrivilegedCommandResult::Output(mut output) => {
            attach_backend_steps(kanidm, &mut output);
            render_output(title, output)?;
        }
        PrivilegedCommandResult::Error(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
        }
        PrivilegedCommandResult::Cancelled => {}
    }
    Ok(())
}

fn run_local_command<F>(title: &str, action: F) -> Result<(), AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(output) => render_output(title, output),
        Err(error) => {
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(())
        }
    }
}

fn run_session_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    kanidm.begin_backend_operation();
    match action() {
        Ok(mut output) => {
            attach_backend_steps(kanidm, &mut output);
            render_output(title, output)
        }
        Err(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(())
        }
    }
}

fn render_output(title: &str, output: CommandOutput) -> Result<(), AppError> {
    render::print_output(title, &output.render_human());
    forms::pause("Press Enter or Esc to continue")
}

fn attach_backend_steps(kanidm: &KanidmCli, output: &mut CommandOutput) {
    let steps = kanidm.take_backend_steps();
    if steps.is_empty() {
        return;
    }
    if let Some(details) = output.details.as_object_mut() {
        details
            .entry("backend_steps")
            .or_insert_with(|| serde_json::Value::Array(steps));
    }
}

fn render_error_with_backend_summary(kanidm: &KanidmCli, error: &AppError) {
    let steps = kanidm.take_backend_steps();
    if steps.is_empty() {
        render::print_error(error);
        return;
    }
    let mut body = render_error(OutputFormat::Human, error);
    if let Some(summary) = render_backend_steps_summary(Some(&serde_json::Value::Array(steps))) {
        body.push_str(&format!("\n\n{}:\n", section_title("Backend Commands")));
        body.push_str(&summary);
    }
    render::print_block("Error", &body);
}

fn show_backend_logs_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let logs = kanidm.recent_backend_logs();
    let body = if logs.is_empty() {
        "No backend commands have been recorded in this TUI session yet.".to_string()
    } else {
        render_backend_steps_full(Some(&serde_json::Value::Array(logs)))
            .unwrap_or_else(|| "No renderable backend log entries were found.".to_string())
    };
    render::print_output("Backend Logs", &body);
    forms::pause("Press Enter or Esc to continue")
}

fn session_status_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let snapshot = kanidm.session_snapshot()?;
    if should_prompt_for_startup_login(&snapshot) {
        let _ = recover_target_interactively_with_snapshot(
            kanidm,
            RecoveryTarget::BaseSession,
            None,
            Some(&snapshot),
        )?;
        return Ok(());
    }

    run_command("Session Status", kanidm, || session_status(kanidm))
}

fn recover_target_interactively(
    kanidm: &KanidmCli,
    target: RecoveryTarget,
    error: Option<&AppError>,
) -> Result<bool, AppError> {
    recover_target_interactively_with_snapshot(kanidm, target, error, None)
}

pub(super) fn recover_target_interactively_with_snapshot(
    kanidm: &KanidmCli,
    target: RecoveryTarget,
    error: Option<&AppError>,
    snapshot: Option<&SessionSnapshot>,
) -> Result<bool, AppError> {
    let owned_snapshot = if snapshot.is_none() {
        kanidm.session_snapshot().ok()
    } else {
        None
    };
    let snapshot = snapshot.or(owned_snapshot.as_ref());

    match target {
        RecoveryTarget::BaseSession => {
            if let Some(snapshot) = snapshot {
                if let Some(message) = concise_session_message(kanidm.admin_name(), snapshot) {
                    render::print_note("Authentication Required", &message);
                } else {
                    render::print_note(
                        "Authentication Required",
                        &format!(
                            "The delegated Kanidm session for '{}' is not ready for this action.\n\nDiagnostic:\n{}",
                            kanidm.admin_name(),
                            snapshot.diagnostic_raw.trim()
                        ),
                    );
                }
            } else if let Some(error) = error {
                render::print_note("Authentication Required", &error.human_message());
            }
            let prompt = snapshot
                .and_then(login_prompt_message)
                .unwrap_or("Authenticate now?");
            recover_login(kanidm, prompt)
        }
        RecoveryTarget::PrivilegedWrites => {
            let _ = snapshot;
            let _ = error;
            render::print_note(
                "Reauthentication Required",
                privileged_reauth_note_message(),
            );
            recover_reauth(kanidm)
        }
    }
}

fn privileged_reauth_note_message() -> &'static str {
    "Your base login is active.\nThis action requires reauthentication for added security.\nThe tool will now hand the terminal to Kanidm for the admin sign-in prompt, then continue the change."
}

fn recover_login(kanidm: &KanidmCli, prompt: &str) -> Result<bool, AppError> {
    match forms::confirm(prompt, true)? {
        Some(true) => {
            kanidm.begin_backend_operation();
            run_session_recovery_command("Login", kanidm, || session_login(kanidm))
        }
        _ => Ok(false),
    }
}

fn recover_reauth(kanidm: &KanidmCli) -> Result<bool, AppError> {
    run_privileged_session_recovery_command(kanidm)
}

fn run_privileged_session_recovery_command(kanidm: &KanidmCli) -> Result<bool, AppError> {
    kanidm.begin_backend_operation();
    match session_reauth(kanidm) {
        Ok(mut output) => {
            attach_backend_steps(kanidm, &mut output);
            render_output("Reauthenticate", output)?;
            Ok(true)
        }
        Err(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(false)
        }
    }
}

fn run_session_recovery_command<F>(
    title: &str,
    kanidm: &KanidmCli,
    action: F,
) -> Result<bool, AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(mut output) => {
            attach_backend_steps(kanidm, &mut output);
            render_output(title, output)?;
            Ok(true)
        }
        Err(error) => {
            render_error_with_backend_summary(kanidm, &error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(false)
        }
    }
}

mod flows;
mod menus;
mod pickers;
mod reviews;
pub(in crate::interactive) use flows::*;
use menus::*;
use pickers::*;
use reviews::*;

enum PrivilegedCommandResult {
    Output(CommandOutput),
    Error(AppError),
    Cancelled,
}

fn partial_success_has_observed_user(error: &AppError, account_id: &str) -> bool {
    match error {
        AppError::PartialSuccess { details, .. } => details
            .get("observed_state")
            .and_then(|state| state.get("user"))
            .and_then(|user| user.get("account_id"))
            .and_then(Value::as_str)
            .is_some_and(|observed| observed == account_id),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

    use crate::context::ResolvedContext;
    use crate::interactive::home::{
        load_home, summarize_home_session_state, HomeBaseSessionStatus, HomeCache, HomeCountStatus,
        HomePrivilegedWriteStatus,
    };
    use crate::inventory::{
        clients::ClientRecord, groups::GroupRecord, policy::GroupPolicySnapshot,
    };
    use crate::kanidm_cli::{BaseSessionState, PrivilegedWriteState};

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

    fn stub_kanidm(script_body: &str) -> KanidmCli {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(&script, script_body);
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: Some("https://passwords.example.test".to_string()),
            vaultwarden_admin_token_file: Some("/run/agenix/vaultwardenAdminToken".into()),
            sftp_runtime: crate::context::SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });
        std::mem::forget(dir);
        cli
    }

    #[test]
    fn simple_menu_stays_task_oriented() {
        let labels = simple_menu_items()
            .into_iter()
            .map(|item| item.label)
            .collect::<Vec<_>>();

        assert_eq!(
            labels,
            vec![
                "Create User",
                "Manage User Access",
                "Find / View User",
                "Disable / Enable User",
                "Help User Reset Password",
                "Set / Reset POSIX Password",
                "Show Backend Logs",
                "Advanced",
                "Exit",
            ]
        );
    }

    #[test]
    fn advanced_menu_contains_low_level_tools() {
        let labels = advanced_menu_items()
            .into_iter()
            .map(|item| item.label)
            .collect::<Vec<_>>();

        assert!(labels.contains(&"Session Tools".to_string()));
        assert!(labels.contains(&"Membership Tools".to_string()));
        assert!(labels.contains(&"Delete User".to_string()));
    }

    #[test]
    fn advanced_submenus_expose_stable_labels() {
        assert_eq!(
            session_tools_items()
                .into_iter()
                .map(|item| item.label)
                .collect::<Vec<_>>(),
            vec!["Status", "Login", "Reauthenticate", "Logout", "Back"]
        );
        assert_eq!(
            client_menu_items()
                .into_iter()
                .map(|item| item.label)
                .collect::<Vec<_>>(),
            vec![
                "List clients",
                "Show client",
                "Show client secret",
                "Reset client secret",
                "Enable PKCE",
                "Disable PKCE",
                "Enable consent prompt",
                "Disable consent prompt",
                "Add redirect URL",
                "Remove redirect URL",
                "Back",
            ]
        );
        assert_eq!(
            policy_menu_items()
                .into_iter()
                .map(|item| item.label)
                .collect::<Vec<_>>(),
            vec![
                "Show group policy",
                "Set auth expiry",
                "Reset auth expiry",
                "Set privilege expiry",
                "Reset privilege expiry",
                "Back",
            ]
        );
        assert_eq!(
            context_menu_items()
                .into_iter()
                .map(|item| item.label)
                .collect::<Vec<_>>(),
            vec!["Show context", "Doctor", "Back"]
        );
        assert_eq!(
            local_helpers_menu_items()
                .into_iter()
                .map(|item| item.label)
                .collect::<Vec<_>>(),
            vec![
                "Invite user to Vaultwarden",
                "Stage Jellyfin password",
                "Back"
            ]
        );
    }

    #[test]
    fn operator_visible_group_picker_excludes_protected_groups() {
        let picker = build_group_picker_inventory(
            &[
                GroupSummary {
                    name: "idm_admins".to_string(),
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
            GroupPickerScope::OperatorVisibleOnly,
        );

        assert_eq!(
            picker.groups,
            vec![GroupSummary {
                name: "users".to_string(),
                description: None,
            }]
        );
        assert_eq!(picker.manual_label, "Enter a group name manually");
        assert!(picker.intro.contains("intentionally hidden"));
    }

    #[test]
    fn all_groups_picker_includes_internal_groups() {
        let picker = build_group_picker_inventory(
            &[
                GroupSummary {
                    name: "idm_admins".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "users".to_string(),
                    description: None,
                },
            ],
            GroupPickerScope::AllGroups,
        );

        assert_eq!(
            picker.groups,
            vec![
                GroupSummary {
                    name: "idm_admins".to_string(),
                    description: None,
                },
                GroupSummary {
                    name: "users".to_string(),
                    description: None,
                },
            ]
        );
        assert_eq!(picker.manual_label, "Enter a group name manually");
        assert!(picker.intro.contains("including internal Kanidm groups"));
    }

    #[test]
    fn reauth_home_session_stays_active_but_requires_privileged_refresh() {
        let (base_session, privileged_writes, diagnostic) = summarize_home_session_state(
            "admindsaw",
            &SessionSnapshot {
                admin_name: "admindsaw".to_string(),
                server_url: "https://id.example.test".to_string(),
                matched_principal: Some("admindsaw@example.test".to_string()),
                base_session_state: BaseSessionState::Present,
                privileged_write_state: PrivilegedWriteState::ReauthRequired,
                base_expiry: crate::kanidm_cli::ParsedExpiry::Never,
                privileged_expiry: crate::kanidm_cli::ParsedExpiry::Unknown("unknown".to_string()),
                diagnostic_raw: "reauth".to_string(),
                parse_confidence: crate::kanidm_cli::ParseConfidence::High,
            },
        );

        assert_eq!(base_session, HomeBaseSessionStatus::Active);
        assert_eq!(privileged_writes, HomePrivilegedWriteStatus::ReauthRequired);
        assert!(diagnostic.contains("reauthentication is required"));
    }

    #[test]
    fn missing_and_expired_home_sessions_are_not_reported_as_active() {
        let missing = summarize_home_session_state(
            "admindsaw",
            &SessionSnapshot {
                admin_name: "admindsaw".to_string(),
                server_url: "https://id.example.test".to_string(),
                matched_principal: None,
                base_session_state: BaseSessionState::Missing,
                privileged_write_state: PrivilegedWriteState::Unavailable,
                base_expiry: crate::kanidm_cli::ParsedExpiry::Unknown("missing".to_string()),
                privileged_expiry: crate::kanidm_cli::ParsedExpiry::Unknown("missing".to_string()),
                diagnostic_raw: "missing".to_string(),
                parse_confidence: crate::kanidm_cli::ParseConfidence::High,
            },
        );
        let expired = summarize_home_session_state(
            "admindsaw",
            &SessionSnapshot {
                admin_name: "admindsaw".to_string(),
                server_url: "https://id.example.test".to_string(),
                matched_principal: Some("admindsaw@example.test".to_string()),
                base_session_state: BaseSessionState::Expired,
                privileged_write_state: PrivilegedWriteState::Unavailable,
                base_expiry: crate::kanidm_cli::ParsedExpiry::Unknown("expired".to_string()),
                privileged_expiry: crate::kanidm_cli::ParsedExpiry::Unknown("expired".to_string()),
                diagnostic_raw: "expired".to_string(),
                parse_confidence: crate::kanidm_cli::ParseConfidence::High,
            },
        );

        assert_eq!(missing.0, HomeBaseSessionStatus::Missing);
        assert_eq!(missing.1, HomePrivilegedWriteStatus::Unavailable);
        assert_eq!(expired.0, HomeBaseSessionStatus::Expired);
        assert_eq!(expired.1, HomePrivilegedWriteStatus::Unavailable);
    }

    #[test]
    fn authenticated_home_session_reports_privileged_writes_ready() {
        let (base_session, privileged_writes, diagnostic) = summarize_home_session_state(
            "admindsaw",
            &SessionSnapshot {
                admin_name: "admindsaw".to_string(),
                server_url: "https://id.example.test".to_string(),
                matched_principal: Some("admindsaw@example.test".to_string()),
                base_session_state: BaseSessionState::Present,
                privileged_write_state: PrivilegedWriteState::Ready,
                base_expiry: crate::kanidm_cli::ParsedExpiry::Never,
                privileged_expiry: crate::kanidm_cli::ParsedExpiry::At(
                    time::OffsetDateTime::now_utc(),
                ),
                diagnostic_raw: "ok".to_string(),
                parse_confidence: crate::kanidm_cli::ParseConfidence::High,
            },
        );

        assert_eq!(base_session, HomeBaseSessionStatus::Active);
        assert_eq!(privileged_writes, HomePrivilegedWriteStatus::Ready);
        assert!(diagnostic.contains("Privileged write commands are ready"));
    }

    #[test]
    fn privileged_reauth_copy_is_plain_language() {
        assert_eq!(
            privileged_reauth_note_message(),
            "Your base login is active.\nThis action requires reauthentication for added security.\nThe tool will now hand the terminal to Kanidm for the admin sign-in prompt, then continue the change."
        );
    }

    #[test]
    fn load_home_skips_live_counts_when_base_session_is_missing() {
        let cli = stub_kanidm(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'No valid auth tokens found\n' >&2
  exit 1
fi
echo "unexpected live probe: $*" >&2
exit 99
"#,
        );

        let home = load_home(&cli, &mut HomeCache::default());

        assert_eq!(home.base_session, HomeBaseSessionStatus::Missing);
        assert!(matches!(
            home.user_count,
            HomeCountStatus::Unavailable { .. }
        ));
        assert!(matches!(
            home.group_count,
            HomeCountStatus::Unavailable { .. }
        ));
        assert!(matches!(
            home.client_count,
            HomeCountStatus::Unavailable { .. }
        ));
        assert!(home
            .warnings
            .iter()
            .any(|warning| warning.contains("Users count is unavailable")));
    }

    #[test]
    fn missing_visible_membership_inventory_ignores_hidden_idm_groups() {
        let missing = missing_visible_membership_inventory(
            &[
                "idm_all_persons".to_string(),
                "users".to_string(),
                "app-admin".to_string(),
            ],
            &[GroupSummary {
                name: "users".to_string(),
                description: None,
            }],
        );

        assert_eq!(missing, vec!["app-admin".to_string()]);
    }

    #[test]
    fn preserved_hidden_memberships_returns_only_non_visible_groups() {
        let preserved = preserved_hidden_memberships(&[
            "idm_all_persons".to_string(),
            "users".to_string(),
            "ext_radius_servers".to_string(),
        ])
        .collect::<Vec<_>>();

        assert_eq!(preserved, vec!["idm_all_persons".to_string()]);
    }

    #[test]
    fn partial_success_follow_up_requires_observed_user() {
        let error = AppError::PartialSuccess {
            message: "partial".to_string(),
            details: serde_json::json!({
                "observed_state": {
                    "user": {
                        "account_id": "dsaw"
                    }
                }
            }),
        };

        assert!(partial_success_has_observed_user(&error, "dsaw"));
        assert!(!partial_success_has_observed_user(&error, "someone-else"));
    }

    #[test]
    fn membership_review_computes_add_remove_and_final_sets() {
        let review = build_membership_review(
            "dsaw",
            &[
                "idm_all_persons".to_string(),
                "users".to_string(),
                "paperless-users".to_string(),
            ],
            vec!["users".to_string(), "user-files".to_string()],
            vec!["idm_all_persons".to_string()],
        );

        assert_eq!(
            review.current_visible_groups,
            vec!["paperless-users".to_string(), "users".to_string()]
        );
        assert_eq!(
            review.selected_visible_groups,
            vec!["user-files".to_string(), "users".to_string()]
        );
        assert_eq!(
            review.preserved_hidden_groups,
            vec!["idm_all_persons".to_string()]
        );
        assert_eq!(
            review.effective_desired_groups,
            vec![
                "idm_all_persons".to_string(),
                "user-files".to_string(),
                "users".to_string()
            ]
        );
        assert_eq!(review.diff.added, vec!["user-files".to_string()]);
        assert_eq!(review.diff.removed, vec!["paperless-users".to_string()]);
    }

    #[test]
    fn membership_review_detects_noop_exact_set() {
        let review = build_membership_review(
            "dsaw",
            &["idm_all_persons".to_string(), "users".to_string()],
            vec!["users".to_string()],
            vec!["idm_all_persons".to_string()],
        );

        assert!(review.diff.is_empty());
    }

    #[test]
    fn membership_review_render_shows_preserved_hidden_groups() {
        let review = build_membership_review(
            "dsaw",
            &["idm_all_persons".to_string(), "users".to_string()],
            vec!["users".to_string()],
            vec!["idm_all_persons".to_string()],
        );

        let rendered = review.render();
        assert!(rendered.contains("Preserved Hidden Groups"));
        assert!(rendered.contains("idm_all_persons"));
    }

    #[test]
    fn membership_change_review_add_computes_actual_changes() {
        let review = build_membership_change_review(
            "dsaw",
            &["users".to_string(), "paperless-users".to_string()],
            vec!["paperless-users".to_string(), "user-files".to_string()],
            MembershipChange::Add,
        );

        assert_eq!(review.already_present, vec!["paperless-users".to_string()]);
        assert_eq!(review.groups_to_add, vec!["user-files".to_string()]);
        assert!(review.groups_to_remove.is_empty());
    }

    #[test]
    fn membership_change_review_remove_computes_actual_changes() {
        let review = build_membership_change_review(
            "dsaw",
            &["users".to_string(), "paperless-users".to_string()],
            vec!["paperless-users".to_string(), "user-files".to_string()],
            MembershipChange::Remove,
        );

        assert_eq!(review.already_absent, vec!["user-files".to_string()]);
        assert_eq!(review.groups_to_remove, vec!["paperless-users".to_string()]);
        assert!(review.groups_to_add.is_empty());
    }

    #[test]
    fn membership_change_review_detects_noop() {
        let review = build_membership_change_review(
            "dsaw",
            &["users".to_string()],
            vec!["users".to_string()],
            MembershipChange::Add,
        );

        assert!(review.is_noop());
    }

    #[test]
    fn reset_password_review_includes_ttl_and_user_summary() {
        let rendered = build_reset_password_review(
            &UserRecord {
                account_id: "dsaw".to_string(),
                display_name: Some("Dan".to_string()),
                primary_email: Some("dsaw@example.test".to_string()),
                spn: None,
                uuid: None,
                valid_from: None,
                expiry: None,
                groups: vec!["users".to_string()],
            },
            3600,
        );

        assert!(rendered.contains("Reset Link TTL: 3600 seconds"));
        assert!(rendered.contains("secure channel"));
        assert!(rendered.contains("Account ID: dsaw"));
    }

    #[test]
    fn posix_password_review_distinguishes_sftp_password() {
        let rendered = build_posix_password_review(&UserRecord {
            account_id: "dsaw".to_string(),
            display_name: Some("Dan".to_string()),
            primary_email: Some("dsaw@example.test".to_string()),
            spn: None,
            uuid: None,
            valid_from: None,
            expiry: None,
            groups: vec!["files-sftp-users".to_string()],
        });

        assert!(rendered.contains("POSIX/UNIX password"));
        assert!(rendered.contains("direct SFTP"));
        assert!(rendered.contains("web/OIDC password"));
    }

    #[test]
    fn redirect_review_shows_current_presence() {
        let rendered = build_redirect_review(
            &ClientRecord {
                name: "files".to_string(),
                display_name: Some("Files".to_string()),
                landing_url: Some("https://files.example.test".to_string()),
                redirect_urls: vec!["https://files.example.test/oauth2/callback".to_string()],
                scope_maps: Vec::new(),
                claim_maps: Vec::new(),
                referenced_groups: Vec::new(),
                pkce_enabled: Some(true),
                consent_prompt_enabled: Some(true),
            },
            "https://files.example.test/oauth2/callback",
            false,
            true,
        );

        assert!(rendered.contains("Currently Present: yes"));
        assert!(rendered.contains("remove redirect URL"));
    }

    #[test]
    fn policy_review_shows_current_and_requested_values() {
        let rendered = build_policy_review(
            &GroupRecord {
                name: "idm_all_persons".to_string(),
                description: Some("Foundation".to_string()),
                members: Vec::new(),
                policy: GroupPolicySnapshot {
                    auth_expiry_seconds: Some(3600),
                    privilege_expiry_seconds: None,
                },
            },
            true,
            PolicyChange::Set(7200),
        );

        assert!(rendered.contains("Current Auth Expiry Seconds: 3600"));
        assert!(rendered.contains("Requested Change: 7200"));
    }
}
