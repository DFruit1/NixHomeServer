pub mod forms;
pub mod render;

use std::collections::HashSet;

use serde_json::Value;

use crate::{
    commands::{
        access::{set_access, show_access, SetAccessOptions},
        auth::{auth_login, auth_reauth, auth_status},
        config::show_config,
        users::{
            create_user, delete_user, disable_user, enable_user, list_users, reset_token,
            show_user, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
        },
    },
    config::ResolvedConfig,
    groups::{ManagedGroup, MANAGED_GROUPS},
    kanidm_cli::{KanidmCli, SessionState},
    models::{parse_group_list, parse_person_list, PersonSummary},
    output::CommandOutput,
    AppError,
};

enum MenuAction {
    Authenticate,
    Reauthenticate,
    AuthStatus,
    CreateUser,
    ListUsers,
    ViewUser,
    DisableUser,
    EnableUser,
    DeleteUser,
    EditGroups,
    ResetToken,
    Settings,
    Exit,
}

pub fn run(config: &ResolvedConfig, kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let authenticated = match kanidm.session_status() {
            Ok(SessionState::Authenticated { .. }) => true,
            Ok(SessionState::Missing { .. }) => false,
            Err(error) => {
                render::print_error(&error);
                forms::pause("Press Enter to continue")?;
                false
            }
        };

        let action = select_menu_action(authenticated)?;
        match action {
            MenuAction::Authenticate => run_simple_command("Authenticate", || auth_login(kanidm))?,
            MenuAction::Reauthenticate => {
                run_simple_command("Reauthenticate", || auth_reauth(kanidm))?
            }
            MenuAction::AuthStatus => {
                run_simple_command("Authentication Status", || auth_status(kanidm))?
            }
            MenuAction::CreateUser => create_user_flow(kanidm)?,
            MenuAction::ListUsers => {
                run_retryable_command("Kanidm Users", kanidm, || list_users(kanidm))?
            }
            MenuAction::ViewUser => view_user_flow(kanidm)?,
            MenuAction::DisableUser => disable_user_flow(kanidm)?,
            MenuAction::EnableUser => enable_user_flow(kanidm)?,
            MenuAction::DeleteUser => delete_user_flow(kanidm)?,
            MenuAction::EditGroups => edit_groups_flow(kanidm)?,
            MenuAction::ResetToken => reset_token_flow(kanidm)?,
            MenuAction::Settings => {
                let output = show_config(config);
                render::print_output("Current Settings", &output.render_human());
                forms::pause("Press Enter to continue")?;
            }
            MenuAction::Exit => break,
        }
    }

    Ok(())
}

fn select_menu_action(authenticated: bool) -> Result<MenuAction, AppError> {
    let items = if authenticated {
        vec![
            "Authenticate / replace current session".to_string(),
            "Reauthenticate privileged access".to_string(),
            "Show authentication status".to_string(),
            "Create user".to_string(),
            "List users".to_string(),
            "View user".to_string(),
            "Disable user".to_string(),
            "Enable user".to_string(),
            "Delete user".to_string(),
            "Set managed access groups".to_string(),
            "Create password reset token".to_string(),
            "Show settings".to_string(),
            "Exit".to_string(),
        ]
    } else {
        vec![
            "Authenticate".to_string(),
            "Show authentication status".to_string(),
            "Show settings".to_string(),
            "Exit".to_string(),
        ]
    };

    let selection = forms::select(
        if authenticated {
            "Kanidm Admin"
        } else {
            "Kanidm Admin (login required for write operations)"
        },
        &items,
        0,
    )?;

    if authenticated {
        Ok(match selection {
            0 => MenuAction::Authenticate,
            1 => MenuAction::Reauthenticate,
            2 => MenuAction::AuthStatus,
            3 => MenuAction::CreateUser,
            4 => MenuAction::ListUsers,
            5 => MenuAction::ViewUser,
            6 => MenuAction::DisableUser,
            7 => MenuAction::EnableUser,
            8 => MenuAction::DeleteUser,
            9 => MenuAction::EditGroups,
            10 => MenuAction::ResetToken,
            11 => MenuAction::Settings,
            _ => MenuAction::Exit,
        })
    } else {
        Ok(match selection {
            0 => MenuAction::Authenticate,
            1 => MenuAction::AuthStatus,
            2 => MenuAction::Settings,
            _ => MenuAction::Exit,
        })
    }
}

fn run_simple_command<F>(title: &str, action: F) -> Result<(), AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(output) => {
            render::print_output(title, &output.render_human());
            forms::pause("Press Enter to continue")?;
        }
        Err(error) => {
            render::print_error(&error);
            forms::pause("Press Enter to continue")?;
        }
    }

    Ok(())
}

fn run_retryable_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    match run_with_auth_retry(kanidm, action)? {
        Some(output) => render::print_output(title, &output.render_human()),
        None => render::print_note("Cancelled", "No changes were made."),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn create_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let account_id = forms::input_required("New account id / username", None)?;
    let display_name = forms::input_required(
        &format!("Display name for '{account_id}'"),
        Some(&account_id),
    )?;
    let email = forms::input_optional("Primary email (leave blank to skip)", None)?;

    render::print_output(
        "Create User Summary",
        &format!(
            "Server URL: {}\nAdmin username: {}\nAccount id: {}\nDisplay name: {}\nPrimary email: {}",
            kanidm.server_url(),
            kanidm.admin_name(),
            account_id,
            display_name,
            email.as_deref().unwrap_or("(none)"),
        ),
    );

    let confirmation = forms::input_optional(
        &format!("Type CREATE to create '{account_id}'. Leave blank to cancel"),
        None,
    )?;
    if confirmation.as_deref() != Some("CREATE") {
        render::print_note("Cancelled", "User creation was cancelled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "User creation was cancelled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match create_user(
        kanidm,
        CreateUserOptions {
            account_id,
            display_name,
            email,
            clear_validity: true,
        },
    ) {
        Ok(output) => render::print_output("User Created", &output.render_human()),
        Err(error) => render::print_error(&error),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn view_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to inspect")? else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    match run_with_auth_retry(kanidm, || show_user(kanidm, &account_id))? {
        Some(output) => render::print_output("User Detail", &output.render_human()),
        None => render::print_note("Cancelled", "No user was selected."),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn disable_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to disable")? else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    if !forms::confirm(&format!("Disable '{account_id}' now?"), false)? {
        render::print_note("Cancelled", "No user was disabled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "No user was disabled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match disable_user(kanidm, &account_id) {
        Ok(output) => render::print_output("User Disabled", &output.render_human()),
        Err(error) => render::print_error(&error),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn enable_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to enable")? else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    if !forms::confirm(&format!("Enable '{account_id}' now?"), true)? {
        render::print_note("Cancelled", "No user was enabled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "No user was enabled.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match enable_user(kanidm, &account_id) {
        Ok(output) => render::print_output("User Enabled", &output.render_human()),
        Err(error) => render::print_error(&error),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn delete_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to delete")? else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    let confirmation = forms::input_optional(
        &format!("Type {account_id} to permanently delete the user. Leave blank to cancel"),
        None,
    )?;
    if confirmation.as_deref() != Some(account_id.as_str()) {
        render::print_note("Cancelled", "No user was deleted.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "No user was deleted.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match delete_user(
        kanidm,
        DeleteUserOptions {
            confirm: account_id.clone(),
            account_id,
        },
    ) {
        Ok(output) => render::print_output("User Deleted", &output.render_human()),
        Err(error) => render::print_error(&error),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn edit_groups_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) =
        choose_account_id(kanidm, "Select a user to set managed group membership for")?
    else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    let available_groups = match run_with_auth_retry(kanidm, || load_available_groups(kanidm))? {
        Some(groups) => groups,
        None => {
            render::print_note("Cancelled", "No groups were loaded.");
            forms::pause("Press Enter to continue")?;
            return Ok(());
        }
    };

    if available_groups.is_empty() {
        render::print_note(
            "Managed Groups",
            "None of the repo-managed groups were returned by Kanidm.",
        );
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    let current_access = match run_with_auth_retry(kanidm, || show_access(kanidm, &account_id))? {
        Some(output) => output,
        None => {
            render::print_note("Cancelled", "Could not load the current user state.");
            forms::pause("Press Enter to continue")?;
            return Ok(());
        }
    };

    let current_groups = extract_groups(&current_access);
    let items = available_groups
        .iter()
        .map(|group| format!("{} ({})", group.name, group.description))
        .collect::<Vec<_>>();
    let defaults = available_groups
        .iter()
        .map(|group| current_groups.iter().any(|current| current == group.name))
        .collect::<Vec<_>>();
    let selected_indexes = forms::multiselect(
        &format!("Select managed groups for '{account_id}'"),
        &items,
        &defaults,
    )?;
    let selected_groups = selected_indexes
        .into_iter()
        .map(|index| available_groups[index].name.to_string())
        .collect::<Vec<_>>();

    render::print_output(
        "Managed Groups Summary",
        &format!(
            "Authoritative managed groups for '{account_id}':\n{}",
            if selected_groups.is_empty() {
                "(none)".to_string()
            } else {
                selected_groups
                    .iter()
                    .map(|group| format!("- {group}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        ),
    );

    if !forms::confirm("Apply this authoritative managed-group set?", true)? {
        render::print_note("Cancelled", "No group membership changes were applied.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "No group membership changes were applied.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match set_access(
        kanidm,
        SetAccessOptions {
            account_id: account_id.clone(),
            groups: selected_groups,
            allow_empty: true,
        },
    ) {
        Ok(output) => render::print_output("Managed Groups", &output.render_human()),
        Err(error) => {
            render::print_error(&error);
            if let Ok(final_output) = show_access(kanidm, &account_id) {
                render::print_output("Current Managed Access", &final_output.render_human());
            }
        }
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn reset_token_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) =
        choose_account_id(kanidm, "Select a user to generate a reset token for")?
    else {
        render::print_note("Cancelled", "No user was selected.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    };

    let ttl_text = forms::input_required("Reset token lifetime in seconds", Some("3600"))?;
    let ttl_seconds = ttl_text.parse::<u64>().map_err(|error| AppError::Config {
        message: format!("invalid reset token TTL '{ttl_text}': {error}"),
    })?;

    if !prepare_privileged_action(kanidm)? {
        render::print_note("Cancelled", "No reset token was created.");
        forms::pause("Press Enter to continue")?;
        return Ok(());
    }

    match reset_token(
        kanidm,
        ResetTokenOptions {
            account_id,
            ttl_seconds,
        },
    ) {
        Ok(output) => render::print_output("Password Reset Token", &output.render_human()),
        Err(error) => render::print_error(&error),
    }
    forms::pause("Press Enter to continue")?;
    Ok(())
}

fn choose_account_id(kanidm: &KanidmCli, prompt: &str) -> Result<Option<String>, AppError> {
    let people = match run_with_auth_retry(kanidm, || load_people(kanidm))? {
        Some(people) => people,
        None => return Ok(None),
    };

    if people.is_empty() {
        let manual =
            forms::input_optional("No users were listed. Enter an account id manually", None)?;
        return Ok(manual);
    }

    let mut items = vec!["Enter an account id manually".to_string()];
    items.extend(people.iter().map(|person| {
        format!(
            "{} | {} | {}",
            person.account_id,
            person.display_name.as_deref().unwrap_or("-"),
            person.primary_email.as_deref().unwrap_or("-")
        )
    }));
    let selection = forms::select(prompt, &items, 0)?;

    if selection == 0 {
        return forms::input_optional("Enter the Kanidm account id to manage", None);
    }

    Ok(Some(people[selection - 1].account_id.clone()))
}

fn load_people(kanidm: &KanidmCli) -> Result<Vec<PersonSummary>, AppError> {
    let value = kanidm.person_list::<Value>()?;
    Ok(parse_person_list(&value)?.value)
}

fn load_available_groups(kanidm: &KanidmCli) -> Result<Vec<ManagedGroup>, AppError> {
    let value = kanidm.group_list::<Value>()?;
    let existing = parse_group_list(&value)?;
    let existing_names = existing
        .value
        .iter()
        .map(|group| group.name.as_str())
        .collect::<HashSet<_>>();

    Ok(MANAGED_GROUPS
        .iter()
        .copied()
        .filter(|group| existing_names.contains(group.name))
        .collect())
}

fn prepare_privileged_action(kanidm: &KanidmCli) -> Result<bool, AppError> {
    match kanidm.session_status()? {
        SessionState::Authenticated { .. } => {}
        SessionState::Missing { diagnostic } => {
            render::print_note(
                "Authentication Required",
                &format!(
                    "A valid Kanidm CLI session is required before continuing.\n\nDiagnostic:\n{}",
                    diagnostic.trim()
                ),
            );
            if !forms::confirm("Open kanidm login now?", true)? {
                return Ok(false);
            }
            let login = auth_login(kanidm)?;
            render::print_output("Authenticate", &login.render_human());
        }
    }

    render::print_note(
        "Reauthenticate",
        "This action may require privileged Kanidm admin access.",
    );
    let reauth = auth_reauth(kanidm)?;
    render::print_output("Reauthenticate", &reauth.render_human());
    Ok(true)
}

fn run_with_auth_retry<T, F>(kanidm: &KanidmCli, mut action: F) -> Result<Option<T>, AppError>
where
    F: FnMut() -> Result<T, AppError>,
{
    let mut retried_login = false;
    let mut retried_reauth = false;

    loop {
        match action() {
            Ok(value) => return Ok(Some(value)),
            Err(AppError::SessionRequired { message }) if !retried_login => {
                render::print_note("Authentication Required", &message);
                if !forms::confirm("Open kanidm login now?", true)? {
                    return Ok(None);
                }
                let output = auth_login(kanidm)?;
                render::print_output("Authenticate", &output.render_human());
                retried_login = true;
            }
            Err(AppError::ReauthRequired { message }) if !retried_reauth => {
                render::print_note("Reauthentication Required", &message);
                if !forms::confirm("Open kanidm reauth now?", true)? {
                    return Ok(None);
                }
                let output = auth_reauth(kanidm)?;
                render::print_output("Reauthenticate", &output.render_human());
                retried_reauth = true;
            }
            Err(error) => return Err(error),
        }
    }
}

fn extract_groups(output: &CommandOutput) -> Vec<String> {
    output
        .details
        .get("user")
        .and_then(|user| user.get("access_groups"))
        .and_then(|groups| groups.get("all_managed"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}
