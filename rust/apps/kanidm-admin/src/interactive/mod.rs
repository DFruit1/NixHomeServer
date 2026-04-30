pub mod forms;
pub mod render;

use serde_json::Value;

use crate::{
    context::ResolvedContext,
    inventory::{
        clients::{parse_client_list, ClientSummary},
        groups::{parse_group_list, GroupSummary},
        users::{parse_user_list, UserSummary},
        Parsed,
    },
    kanidm_cli::{KanidmCli, SessionState},
    ops::{
        client::{
            client_consent_disable, client_consent_enable, client_pkce_disable, client_pkce_enable,
            client_redirect_add, client_redirect_remove, client_secret_reset, client_secret_show,
            list_clients, show_client,
        },
        context::{doctor, show_context},
        group::{group_members, list_groups, search_groups, show_group},
        local::stage_jellyfin_password,
        membership::{
            add_membership, prepare_membership_picker_inventory, remove_membership, set_membership,
            show_membership, SetMembershipOptions,
        },
        policy::{
            reset_group_auth_expiry, reset_group_privilege_expiry, set_group_auth_expiry,
            set_group_privilege_expiry, show_group_policy,
        },
        session::{session_login, session_logout, session_reauth, session_status},
        user::{
            create_user, delete_user, disable_user, enable_user, list_users, reset_token,
            show_user, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
        },
    },
    output::CommandOutput,
    AppError,
};

enum MenuAction {
    Sessions,
    Users,
    Groups,
    Memberships,
    Clients,
    Policy,
    Context,
    LocalHelpers,
    Exit,
}

pub fn run(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let home = load_home(kanidm);
        render::print_output("Kanidm Admin", &home.render(context));
        if !home.warnings.is_empty() {
            render::print_note("Warnings", &render_bullets(&home.warnings));
        }

        let action = select_main_menu()?;
        match action {
            MenuAction::Sessions => sessions_menu(kanidm)?,
            MenuAction::Users => users_menu(kanidm)?,
            MenuAction::Groups => groups_menu(kanidm)?,
            MenuAction::Memberships => memberships_menu(kanidm)?,
            MenuAction::Clients => clients_menu(kanidm)?,
            MenuAction::Policy => policy_menu(kanidm)?,
            MenuAction::Context => context_menu(context, kanidm)?,
            MenuAction::LocalHelpers => local_helpers_menu()?,
            MenuAction::Exit => break,
        }
    }

    Ok(())
}

struct HomeSummary {
    authenticated: bool,
    diagnostic: String,
    user_count: Option<usize>,
    group_count: Option<usize>,
    client_count: Option<usize>,
    warnings: Vec<String>,
}

impl HomeSummary {
    fn render(&self, context: &ResolvedContext) -> String {
        format!(
            "Server URL: {}\nAdmin Name: {}\nSession Active: {}\nDiagnostic: {}\nUsers: {}\nGroups: {}\nOAuth2 Clients: {}",
            context.server_url,
            context.admin_name,
            if self.authenticated { "yes" } else { "no" },
            self.diagnostic,
            render_count(self.user_count),
            render_count(self.group_count),
            render_count(self.client_count),
        )
    }
}

fn load_home(kanidm: &KanidmCli) -> HomeSummary {
    let mut warnings = Vec::new();

    let (authenticated, diagnostic) = match kanidm.session_status() {
        Ok(SessionState::Authenticated { .. }) => (
            true,
            format!(
                "Authenticated session is active for '{}'.",
                kanidm.admin_name()
            ),
        ),
        Ok(SessionState::Expired { .. }) => (
            false,
            format!("Session for '{}' has expired.", kanidm.admin_name()),
        ),
        Ok(SessionState::Missing { .. }) => (
            false,
            format!("No Kanidm session is active for '{}'.", kanidm.admin_name()),
        ),
        Ok(SessionState::ReauthRequired { .. }) => (
            false,
            format!(
                "Session for '{}' is authenticated, but privileged reauthentication is required.",
                kanidm.admin_name()
            ),
        ),
        Err(error) => {
            warnings.push(error.human_message());
            (false, "session state unavailable".to_string())
        }
    };

    let user_count = load_count(|| {
        let parsed = parse_user_list(&kanidm.person_list::<Value>()?)?;
        warnings.extend(parsed.warnings.clone());
        Ok(parsed.value.len())
    });
    let group_count = load_count(|| {
        let parsed = parse_group_list(&kanidm.group_list::<Value>()?)?;
        warnings.extend(parsed.warnings.clone());
        Ok(parsed.value.len())
    });
    let client_count = load_count(|| {
        let parsed = parse_client_list(&kanidm.oauth2_list::<Value>()?)?;
        warnings.extend(parsed.warnings.clone());
        Ok(parsed.value.len())
    });

    warnings.sort();
    warnings.dedup();

    HomeSummary {
        authenticated,
        diagnostic,
        user_count,
        group_count,
        client_count,
        warnings,
    }
}

fn load_count<F>(loader: F) -> Option<usize>
where
    F: FnOnce() -> Result<usize, AppError>,
{
    loader().ok()
}

fn select_main_menu() -> Result<MenuAction, AppError> {
    let items = vec![
        "Sessions".to_string(),
        "Users".to_string(),
        "Groups".to_string(),
        "Memberships".to_string(),
        "OAuth2 Clients".to_string(),
        "Group Policy".to_string(),
        "Context".to_string(),
        "Local Helpers".to_string(),
        "Exit".to_string(),
    ];
    let Some(selection) = forms::select("Select an area", &items, 0)? else {
        return Ok(MenuAction::Exit);
    };
    Ok(match selection {
        0 => MenuAction::Sessions,
        1 => MenuAction::Users,
        2 => MenuAction::Groups,
        3 => MenuAction::Memberships,
        4 => MenuAction::Clients,
        5 => MenuAction::Policy,
        6 => MenuAction::Context,
        7 => MenuAction::LocalHelpers,
        _ => MenuAction::Exit,
    })
}

fn sessions_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "Status".to_string(),
            "Login".to_string(),
            "Reauthenticate".to_string(),
            "Logout".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Sessions", &items, 0)? {
            Some(0) => session_status_flow(kanidm)?,
            Some(1) => run_command("Login", kanidm, || session_login(kanidm))?,
            Some(2) => run_command("Reauthenticate", kanidm, || session_reauth(kanidm))?,
            Some(3) => run_command("Logout", kanidm, || session_logout(kanidm))?,
            _ => break,
        }
    }
    Ok(())
}

fn users_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "List users".to_string(),
            "Create user".to_string(),
            "View user".to_string(),
            "Disable user".to_string(),
            "Enable user".to_string(),
            "Delete user".to_string(),
            "Reset token".to_string(),
            "Edit memberships".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Users", &items, 0)? {
            Some(0) => run_command("Kanidm Users", kanidm, || list_users(kanidm))?,
            Some(1) => create_user_flow(kanidm)?,
            Some(2) => user_target_flow(kanidm, "Select a user to inspect", |account_id| {
                show_user(kanidm, account_id)
            })?,
            Some(3) => user_target_flow(kanidm, "Select a user to disable", |account_id| {
                disable_user(kanidm, account_id)
            })?,
            Some(4) => user_target_flow(kanidm, "Select a user to enable", |account_id| {
                enable_user(kanidm, account_id)
            })?,
            Some(5) => delete_user_flow(kanidm)?,
            Some(6) => reset_token_flow(kanidm)?,
            Some(7) => edit_membership_flow(kanidm)?,
            _ => break,
        }
    }
    Ok(())
}

fn groups_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "List groups".to_string(),
            "Search groups".to_string(),
            "Show group".to_string(),
            "List group members".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Groups", &items, 0)? {
            Some(0) => run_command("Groups", kanidm, || list_groups(kanidm))?,
            Some(1) => {
                let query = forms::input_required("Search query", None)?;
                run_command("Group Search", kanidm, || search_groups(kanidm, &query))?;
            }
            Some(2) => group_target_flow(kanidm, "Select a group to inspect", |group| {
                show_group(kanidm, group)
            })?,
            Some(3) => group_target_flow(kanidm, "Select a group to inspect members", |group| {
                group_members(kanidm, group)
            })?,
            _ => break,
        }
    }
    Ok(())
}

fn memberships_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "Show user memberships".to_string(),
            "Add memberships".to_string(),
            "Remove memberships".to_string(),
            "Set exact memberships".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Memberships", &items, 0)? {
            Some(0) => user_target_flow(
                kanidm,
                "Select a user to inspect memberships",
                |account_id| show_membership(kanidm, account_id),
            )?,
            Some(1) => membership_change_flow(kanidm, MembershipChange::Add)?,
            Some(2) => membership_change_flow(kanidm, MembershipChange::Remove)?,
            Some(3) => edit_membership_flow(kanidm)?,
            _ => break,
        }
    }
    Ok(())
}

fn clients_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "List clients".to_string(),
            "Show client".to_string(),
            "Show client secret".to_string(),
            "Reset client secret".to_string(),
            "Enable PKCE".to_string(),
            "Disable PKCE".to_string(),
            "Enable consent prompt".to_string(),
            "Disable consent prompt".to_string(),
            "Add redirect URL".to_string(),
            "Remove redirect URL".to_string(),
            "Back".to_string(),
        ];
        match forms::select("OAuth2 Clients", &items, 0)? {
            Some(0) => run_command("OAuth2 Clients", kanidm, || list_clients(kanidm))?,
            Some(1) => client_target_flow(kanidm, "Select an oauth2 client to inspect", |client| {
                show_client(kanidm, client)
            })?,
            Some(2) => client_target_flow(kanidm, "Select an oauth2 client secret to show", |client| {
                client_secret_show(kanidm, client)
            })?,
            Some(3) => client_target_flow(
                kanidm,
                "Select an oauth2 client secret to reset",
                |client| client_secret_reset(kanidm, client),
            )?,
            Some(4) => client_target_flow(kanidm, "Select an oauth2 client", |client| {
                client_pkce_enable(kanidm, client)
            })?,
            Some(5) => client_target_flow(kanidm, "Select an oauth2 client", |client| {
                client_pkce_disable(kanidm, client)
            })?,
            Some(6) => client_target_flow(kanidm, "Select an oauth2 client", |client| {
                client_consent_enable(kanidm, client)
            })?,
            Some(7) => client_target_flow(kanidm, "Select an oauth2 client", |client| {
                client_consent_disable(kanidm, client)
            })?,
            Some(8) => redirect_flow(kanidm, true)?,
            Some(9) => redirect_flow(kanidm, false)?,
            _ => break,
        }
    }
    Ok(())
}

fn policy_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "Show group policy".to_string(),
            "Set auth expiry".to_string(),
            "Reset auth expiry".to_string(),
            "Set privilege expiry".to_string(),
            "Reset privilege expiry".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Group Policy", &items, 0)? {
            Some(0) => group_target_flow(kanidm, "Select a group to inspect", |group| {
                show_group_policy(kanidm, group)
            })?,
            Some(1) => policy_set_flow(kanidm, true)?,
            Some(2) => group_target_flow(kanidm, "Select a group", |group| {
                reset_group_auth_expiry(kanidm, group)
            })?,
            Some(3) => policy_set_flow(kanidm, false)?,
            Some(4) => group_target_flow(kanidm, "Select a group", |group| {
                reset_group_privilege_expiry(kanidm, group)
            })?,
            _ => break,
        }
    }
    Ok(())
}

fn context_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let items = vec![
            "Show context".to_string(),
            "Doctor".to_string(),
            "Back".to_string(),
        ];
        match forms::select("Context", &items, 0)? {
            Some(0) => {
                render_output("Context", show_context(context))?;
            }
            Some(1) => {
                run_command("Doctor", kanidm, || doctor(context, kanidm))?;
            }
            _ => break,
        }
    }
    Ok(())
}

fn local_helpers_menu() -> Result<(), AppError> {
    loop {
        let items = vec!["Stage Jellyfin password".to_string(), "Back".to_string()];
        match forms::select("Local Helpers", &items, 0)? {
            Some(0) => {
                let account_id = forms::input_required("Jellyfin account id", None)?;
                let password_env =
                    forms::input_required("Password env var", Some("JELLYFIN_PASSWORD"))?;
                run_local_command("Jellyfin Password", || {
                    stage_jellyfin_password(&account_id, &password_env)
                })?;
            }
            _ => break,
        }
    }
    Ok(())
}

fn create_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let account_id = forms::input_required("New account id / username", None)?;
    let display_name = forms::input_required(
        &format!("Display name for '{account_id}'"),
        Some(&account_id),
    )?;
    let email = forms::input_optional("Primary email (leave blank to skip)", None)?;
    let Some(clear_validity) = forms::confirm("Clear validity restrictions after creation?", true)?
    else {
        return Ok(());
    };
    run_command("Create User", kanidm, || {
        create_user(
            kanidm,
            CreateUserOptions {
                account_id: account_id.clone(),
                display_name: display_name.clone(),
                email: email.clone(),
                clear_validity,
            },
        )
    })
}

fn delete_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to delete")? else {
        return Ok(());
    };
    let confirmation = forms::input_required(
        &format!("Type {account_id} to permanently delete the user"),
        None,
    )?;
    run_command("Delete User", kanidm, || {
        delete_user(
            kanidm,
            DeleteUserOptions {
                account_id: account_id.clone(),
                confirm: confirmation.clone(),
            },
        )
    })
}

fn reset_token_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) =
        choose_account_id(kanidm, "Select a user to generate a reset token for")?
    else {
        return Ok(());
    };
    let ttl_text = forms::input_required("Reset token lifetime in seconds", Some("3600"))?;
    let ttl_seconds = ttl_text.parse::<u64>().map_err(|error| AppError::Config {
        message: format!("invalid reset token TTL '{ttl_text}': {error}"),
    })?;
    run_command("Password Reset Token", kanidm, || {
        reset_token(
            kanidm,
            ResetTokenOptions {
                account_id: account_id.clone(),
                ttl_seconds,
            },
        )
    })
}

fn policy_set_flow(kanidm: &KanidmCli, auth: bool) -> Result<(), AppError> {
    let prompt = if auth {
        "Select a group for auth-expiry"
    } else {
        "Select a group for privilege-expiry"
    };
    let Some(group) = choose_group_name(kanidm, prompt)? else {
        return Ok(());
    };
    let seconds_text = forms::input_required("Expiry in seconds", Some("3600"))?;
    let seconds = seconds_text
        .parse::<u64>()
        .map_err(|error| AppError::Config {
            message: format!("invalid expiry '{seconds_text}': {error}"),
        })?;
    if auth {
        run_command("Group Policy", kanidm, || {
            set_group_auth_expiry(kanidm, &group, seconds)
        })
    } else {
        run_command("Group Policy", kanidm, || {
            set_group_privilege_expiry(kanidm, &group, seconds)
        })
    }
}

fn redirect_flow(kanidm: &KanidmCli, add: bool) -> Result<(), AppError> {
    let Some(client) = choose_client_name(kanidm, "Select an oauth2 client")? else {
        return Ok(());
    };
    let url = forms::input_required("Redirect URL", None)?;
    if add {
        run_command("OAuth2 Redirect", kanidm, || {
            client_redirect_add(kanidm, &client, &url)
        })
    } else {
        run_command("OAuth2 Redirect", kanidm, || {
            client_redirect_remove(kanidm, &client, &url)
        })
    }
}

fn edit_membership_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(
        kanidm,
        "Select a user to authoritatively set direct memberships for",
    )?
    else {
        return Ok(());
    };
    let inventory = prepare_membership_picker_inventory(kanidm)?;
    if !inventory.warnings.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            &format!(
                "Authoritative membership editing is blocked because the live discovery set is incomplete.\n\nWarnings:\n{}",
                render_bullets(&inventory.warnings)
            ),
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let current = show_membership(kanidm, &account_id)?;
    let defaults = extract_groups(&current)
        .iter()
        .map(|current_group| current_group.to_string())
        .collect::<Vec<_>>();
    let item_defaults = inventory
        .groups
        .iter()
        .map(|group| defaults.iter().any(|current| current == &group.name))
        .collect::<Vec<_>>();
    let Some(selected) = forms::membership_picker(
        &format!("Select direct memberships for '{account_id}'"),
        &inventory.groups,
        &item_defaults,
    )? else {
        return Ok(());
    };
    let groups = selected
        .into_iter()
        .map(|index| inventory.groups[index].name.clone())
        .collect::<Vec<_>>();

    run_command("Memberships", kanidm, || {
        set_membership(
            kanidm,
            SetMembershipOptions {
                account_id: account_id.clone(),
                groups,
                allow_empty: true,
            },
        )
    })
}

fn membership_change_flow(kanidm: &KanidmCli, mode: MembershipChange) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user")? else {
        return Ok(());
    };
    let group_text =
        forms::input_required("Enter one or more group names separated by spaces", None)?;
    let groups = group_text
        .split_whitespace()
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    match mode {
        MembershipChange::Add => run_command("Memberships", kanidm, || {
            add_membership(kanidm, &account_id, &groups)
        }),
        MembershipChange::Remove => run_command("Memberships", kanidm, || {
            remove_membership(kanidm, &account_id, &groups)
        }),
    }
}

fn user_target_flow<F>(kanidm: &KanidmCli, prompt: &str, action: F) -> Result<(), AppError>
where
    F: FnOnce(&str) -> Result<CommandOutput, AppError>,
{
    let Some(account_id) = choose_account_id(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("User", kanidm, || action(&account_id))
}

fn group_target_flow<F>(kanidm: &KanidmCli, prompt: &str, action: F) -> Result<(), AppError>
where
    F: FnOnce(&str) -> Result<CommandOutput, AppError>,
{
    let Some(group) = choose_group_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("Group", kanidm, || action(&group))
}

fn client_target_flow<F>(kanidm: &KanidmCli, prompt: &str, action: F) -> Result<(), AppError>
where
    F: FnOnce(&str) -> Result<CommandOutput, AppError>,
{
    let Some(client) = choose_client_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("OAuth2 Client", kanidm, || action(&client))
}

fn choose_account_id(kanidm: &KanidmCli, prompt: &str) -> Result<Option<String>, AppError> {
    let people = parse_user_list(&kanidm.person_list::<Value>()?)?;
    choose_from_users(prompt, &people)
}

fn choose_group_name(kanidm: &KanidmCli, prompt: &str) -> Result<Option<String>, AppError> {
    let groups = parse_group_list(&kanidm.group_list::<Value>()?)?;
    choose_from_groups(prompt, &groups)
}

fn choose_client_name(kanidm: &KanidmCli, prompt: &str) -> Result<Option<String>, AppError> {
    let clients = parse_client_list(&kanidm.oauth2_list::<Value>()?)?;
    choose_from_clients(prompt, &clients)
}

fn choose_from_users(
    prompt: &str,
    people: &Parsed<Vec<UserSummary>>,
) -> Result<Option<String>, AppError> {
    if !people.warnings.is_empty() {
        render::print_note(
            "User Inventory Warning",
            &format!(
                "The listed users may be incomplete because the Kanidm user list contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&people.warnings)
            ),
        );
    }
    if people.value.is_empty() {
        return forms::input_optional("No users were listed. Enter an account id manually", None);
    }
    let mut items = vec!["Enter an account id manually".to_string()];
    items.extend(people.value.iter().map(|person| {
        format!(
            "{} | {} | {}",
            person.account_id,
            person.display_name.as_deref().unwrap_or("-"),
            person.primary_email.as_deref().unwrap_or("-")
        )
    }));
    let Some(selection) = forms::select(prompt, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional("Enter the Kanidm account id to manage", None);
    }
    Ok(Some(people.value[selection - 1].account_id.clone()))
}

fn choose_from_groups(
    prompt: &str,
    groups: &Parsed<Vec<GroupSummary>>,
) -> Result<Option<String>, AppError> {
    if !groups.warnings.is_empty() {
        render::print_note(
            "Group Inventory Warning",
            &format!(
                "The listed groups may be incomplete because the Kanidm group list contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&groups.warnings)
            ),
        );
    }
    if groups.value.is_empty() {
        return forms::input_optional("No groups were listed. Enter a group name manually", None);
    }
    let mut items = vec!["Enter a group name manually".to_string()];
    items.extend(groups.value.iter().map(|group| {
        format!(
            "{} | {}",
            group.name,
            group.description.as_deref().unwrap_or("-")
        )
    }));
    let Some(selection) = forms::select(prompt, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional("Enter the group name to manage", None);
    }
    Ok(Some(groups.value[selection - 1].name.clone()))
}

fn choose_from_clients(
    prompt: &str,
    clients: &Parsed<Vec<ClientSummary>>,
) -> Result<Option<String>, AppError> {
    if !clients.warnings.is_empty() {
        render::print_note(
            "OAuth2 Client Inventory Warning",
            &format!(
                "The listed oauth2 clients may be incomplete because discovery contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&clients.warnings)
            ),
        );
    }
    if clients.value.is_empty() {
        return forms::input_optional(
            "No oauth2 clients were listed. Enter a client name manually",
            None,
        );
    }
    let mut items = vec!["Enter an oauth2 client name manually".to_string()];
    items.extend(clients.value.iter().map(|client| {
        format!(
            "{} | {} | {}",
            client.name,
            client.display_name.as_deref().unwrap_or("-"),
            client.landing_url.as_deref().unwrap_or("-")
        )
    }));
    let Some(selection) = forms::select(prompt, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional("Enter the oauth2 client name to manage", None);
    }
    Ok(Some(clients.value[selection - 1].name.clone()))
}

fn run_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(output) => render_output(title, output),
        Err(error) => {
            if prompt_for_session_recovery(kanidm, &error)? {
                return Ok(());
            }
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(())
        }
    }
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

fn render_output(title: &str, output: CommandOutput) -> Result<(), AppError> {
    render::print_output(title, &output.render_human());
    forms::pause("Press Enter or Esc to continue")
}

fn session_status_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    match kanidm.session_status()? {
        SessionState::Expired { .. } => {
            render::print_note(
                "Session Status",
                &format!(
                    "Session for '{}' has expired. Would you like to reauthenticate?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Reauthenticate now?", true)? {
                Some(true) => run_command("Reauthenticate", kanidm, || session_reauth(kanidm)),
                _ => Ok(()),
            }
        }
        SessionState::Missing { .. } => {
            render::print_note(
                "Session Status",
                &format!(
                    "Session for '{}' is unavailable. Would you like to authenticate now?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Authenticate now?", true)? {
                Some(true) => run_command("Login", kanidm, || session_login(kanidm)),
                _ => Ok(()),
            }
        }
        SessionState::ReauthRequired { .. } => {
            render::print_note(
                "Session Status",
                &format!(
                    "Session for '{}' requires privileged reauthentication. Would you like to reauthenticate now?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Reauthenticate now?", true)? {
                Some(true) => run_command("Reauthenticate", kanidm, || session_reauth(kanidm)),
                _ => Ok(()),
            }
        }
        _ => run_command("Session Status", kanidm, || session_status(kanidm)),
    }
}

fn prompt_for_session_recovery(kanidm: &KanidmCli, error: &AppError) -> Result<bool, AppError> {
    match error {
        AppError::SessionRequired { .. } => {
            render::print_note(
                "Session Required",
                &format!(
                    "Session for '{}' has expired or is unavailable. Would you like to authenticate now?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Authenticate now?", true)? {
                Some(true) => {
                    run_command("Login", kanidm, || session_login(kanidm))?;
                    Ok(true)
                }
                _ => Ok(true),
            }
        }
        AppError::ReauthRequired { .. } => {
            render::print_note(
                "Reauthentication Required",
                &format!(
                    "Session for '{}' requires reauthentication. Would you like to reauthenticate now?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Reauthenticate now?", true)? {
                Some(true) => {
                    run_command("Reauthenticate", kanidm, || session_reauth(kanidm))?;
                    Ok(true)
                }
                _ => Ok(true),
            }
        }
        _ => Ok(false),
    }
}

fn render_count(value: Option<usize>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unavailable".to_string())
}

fn render_bullets(items: &[String]) -> String {
    items
        .iter()
        .map(|item| format!("- {item}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn extract_groups(output: &CommandOutput) -> Vec<String> {
    output
        .details
        .get("groups")
        .and_then(Value::as_array)
        .map(|groups| {
            groups
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

enum MembershipChange {
    Add,
    Remove,
}
