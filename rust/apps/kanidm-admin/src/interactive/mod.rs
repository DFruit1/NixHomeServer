pub mod forms;
pub mod render;

use serde_json::Value;

use crate::{
    context::ResolvedContext,
    inventory::{
        clients::{parse_client_list, ClientSummary},
        groups::{is_operator_visible_group, parse_group_list, resolve_group_help, GroupSummary},
        users::{parse_user_list, UserRecord, UserSummary},
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
            assign_system_admin, create_user, delete_user, disable_user, enable_user, load_user,
            reset_token, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
            DEFAULT_SYSTEM_ADMIN_GROUPS,
        },
    },
    output::CommandOutput,
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url, validate_seconds_field, AUTH_EXPIRY_MAX_SECONDS,
        AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS, PRIVILEGE_EXPIRY_MIN_SECONDS,
        RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
    AppError,
};

enum SimpleMenuAction {
    CreateUser,
    ManageUserAccess,
    FindViewUser,
    DisableEnableUser,
    HelpUserResetPassword,
    Advanced,
    Exit,
}

pub fn run(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    loop {
        let home = load_home(kanidm);
        let action = select_main_menu(context, &home)?;
        match action {
            SimpleMenuAction::CreateUser => create_user_flow(kanidm)?,
            SimpleMenuAction::ManageUserAccess => manage_user_access_flow(kanidm)?,
            SimpleMenuAction::FindViewUser => find_view_user_flow(kanidm)?,
            SimpleMenuAction::DisableEnableUser => disable_enable_user_flow(kanidm)?,
            SimpleMenuAction::HelpUserResetPassword => help_user_reset_password_flow(kanidm)?,
            SimpleMenuAction::Advanced => advanced_menu(context, kanidm)?,
            SimpleMenuAction::Exit => break,
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
                "Authenticated base session is active for '{}'. Privileged write commands may still require reauthentication.",
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

fn kanidm_with_admin_name(context: &ResolvedContext, admin_name: &str) -> KanidmCli {
    KanidmCli::new(&ResolvedContext {
        repo_root: context.repo_root.clone(),
        server_url: context.server_url.clone(),
        admin_name: admin_name.to_string(),
        kanidm_bin: context.kanidm_bin.clone(),
    })
}

fn select_main_menu(
    context: &ResolvedContext,
    home: &HomeSummary,
) -> Result<SimpleMenuAction, AppError> {
    let mut intro = home.render(context);
    if !home.warnings.is_empty() {
        intro.push_str("\n\nWarnings:\n");
        intro.push_str(&render_bullets(&home.warnings));
    }

    let Some(selection) =
        forms::contextual_select("Kanidm Admin", Some(&intro), &simple_menu_items(), 0)?
    else {
        return Ok(SimpleMenuAction::Exit);
    };

    Ok(match selection {
        0 => SimpleMenuAction::CreateUser,
        1 => SimpleMenuAction::ManageUserAccess,
        2 => SimpleMenuAction::FindViewUser,
        3 => SimpleMenuAction::DisableEnableUser,
        4 => SimpleMenuAction::HelpUserResetPassword,
        5 => SimpleMenuAction::Advanced,
        _ => SimpleMenuAction::Exit,
    })
}

fn advanced_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "Advanced",
        Some(
            "Specialized Kanidm and local helper tools live here. Use this area when the guided day-to-day workflows are not enough.",
        ),
        &advanced_menu_items(),
        0,
    )? {
        match selection {
            0 => session_tools_menu(kanidm)?,
            1 => group_inspection_menu(kanidm)?,
            2 => membership_tools_menu(kanidm)?,
            3 => clients_menu(kanidm)?,
            4 => policy_menu(kanidm)?,
            5 => context_menu(context, kanidm)?,
            6 => assign_system_admin_flow(context)?,
            7 => local_helpers_menu()?,
            8 => delete_user_flow(kanidm)?,
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
            1 => run_command("Login", kanidm, || session_login(kanidm))?,
            2 => run_command("Reauthenticate", kanidm, || session_reauth(kanidm))?,
            3 => run_command("Logout", kanidm, || session_logout(kanidm))?,
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
                let query = forms::input_required("Search query", None)?;
                run_command("Group Search", kanidm, || search_groups(kanidm, &query))?;
            }
            2 => group_target_flow(kanidm, "Select a group to inspect", |group| {
                show_group(kanidm, group)
            })?,
            3 => group_target_flow(kanidm, "Select a group to inspect members", |group| {
                group_members(kanidm, group)
            })?,
            _ => break,
        }
    }
    Ok(())
}

fn membership_tools_menu(kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) =
        forms::contextual_select("Membership Tools", None, &membership_tools_items(), 0)?
    {
        match selection {
            0 => user_target_flow(kanidm, "Select a user to inspect access", |account_id| {
                show_membership(kanidm, account_id)
            })?,
            1 => membership_change_flow(kanidm, MembershipChange::Add)?,
            2 => membership_change_flow(kanidm, MembershipChange::Remove)?,
            3 => edit_membership_flow(kanidm)?,
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
            Some(1) => {
                client_target_flow(kanidm, "Select an oauth2 client to inspect", |client| {
                    show_client(kanidm, client)
                })?
            }
            Some(2) => {
                client_target_flow(kanidm, "Select an oauth2 client secret to show", |client| {
                    client_secret_show(kanidm, client)
                })?
            }
            Some(3) => client_target_flow_privileged(
                kanidm,
                "Select an oauth2 client secret to reset",
                |client| client_secret_reset(kanidm, client),
            )?,
            Some(4) => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_pkce_enable(kanidm, client)
                })?
            }
            Some(5) => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_pkce_disable(kanidm, client)
                })?
            }
            Some(6) => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_consent_enable(kanidm, client)
                })?
            }
            Some(7) => {
                client_target_flow_privileged(kanidm, "Select an oauth2 client", |client| {
                    client_consent_disable(kanidm, client)
                })?
            }
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
            Some(2) => group_target_flow_privileged(kanidm, "Select a group", |group| {
                reset_group_auth_expiry(kanidm, group)
            })?,
            Some(3) => policy_set_flow(kanidm, false)?,
            Some(4) => group_target_flow_privileged(kanidm, "Select a group", |group| {
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
                let account_id = forms::input_required_validated(
                    "Jellyfin account id",
                    None,
                    validate_account_id,
                )?;
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
    let account_id =
        forms::input_required_validated("New account id / username", None, validate_account_id)?;
    let display_name = forms::input_required_validated(
        &format!("Display name for '{account_id}'"),
        Some(&account_id),
        validate_display_name,
    )?;
    let email = forms::input_optional_validated(
        "Primary email (leave blank to skip)",
        None,
        validate_email,
    )?;
    let Some(clear_validity) = forms::confirm("Clear validity restrictions after creation?", true)?
    else {
        return Ok(());
    };
    let outcome = perform_privileged_command(kanidm, || {
        create_user(
            kanidm,
            CreateUserOptions {
                account_id: account_id.clone(),
                display_name: display_name.clone(),
                email: email.clone(),
                clear_validity,
            },
        )
    })?;

    let output = match outcome {
        PrivilegedCommandResult::Output(output) => output,
        PrivilegedCommandResult::Cancelled => return Ok(()),
        PrivilegedCommandResult::Error(error) => {
            render::print_error(&error);
            if matches!(error, AppError::PartialSuccess { .. })
                && partial_success_has_observed_user(&error, &account_id)
            {
                match forms::confirm("Continue to access setup for this existing user?", false)? {
                    Some(true) => return edit_membership_for_account(kanidm, &account_id),
                    _ => return Ok(()),
                }
            }
            forms::pause("Press Enter or Esc to continue")?;
            return Ok(());
        }
    };

    render::print_output(
        "Create User",
        &format!(
            "{}\n\nNext Step:\nChoose the access groups that should apply to this new user.",
            output.render_human()
        ),
    );
    forms::pause("Press Enter or Esc to continue to access setup")?;
    edit_membership_for_account(kanidm, &account_id)
}

fn delete_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to delete")? else {
        return Ok(());
    };
    let confirmation = forms::input_required(
        &format!("Type {account_id} to permanently delete the user"),
        None,
    )?;
    run_privileged_command("Delete User", kanidm, || {
        delete_user(
            kanidm,
            DeleteUserOptions {
                account_id: account_id.clone(),
                confirm: confirmation.clone(),
            },
        )
    })
}

fn help_user_reset_password_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) =
        choose_account_id(kanidm, "Select a user who needs a password reset link")?
    else {
        return Ok(());
    };
    let ttl_text = forms::input_required("Password reset link lifetime in seconds", Some("3600"))?;
    let ttl_seconds = validate_seconds_field(
        "reset token TTL",
        ttl_text.parse::<u64>().map_err(|error| AppError::Config {
            message: format!("invalid reset token TTL '{ttl_text}': {error}"),
        })?,
        RESET_TOKEN_TTL_MIN_SECONDS,
        RESET_TOKEN_TTL_MAX_SECONDS,
    )?;
    run_privileged_command("Help User Reset Password", kanidm, || {
        reset_token(
            kanidm,
            ResetTokenOptions {
                account_id: account_id.clone(),
                ttl_seconds,
            },
        )
    })
}

fn assign_system_admin_flow(context: &ResolvedContext) -> Result<(), AppError> {
    let idm_admin = kanidm_with_admin_name(context, "idm_admin");
    render::print_note(
        "Assign System Admin",
        &format!(
            "This recovery flow uses the break-glass 'idm_admin' account instead of '{}'.\n\nLog in as 'idm_admin' when prompted. The flow grants only the default Kanidm administration roles needed for user/group administration and system operation:\n{}",
            context.admin_name,
            render_bullets(
                &DEFAULT_SYSTEM_ADMIN_GROUPS
                    .iter()
                    .map(|group| (*group).to_string())
                    .collect::<Vec<_>>(),
            ),
        ),
    );
    forms::pause("Press Enter or Esc to continue")?;

    if !ensure_privileged_session_ready(&idm_admin)? {
        return Ok(());
    }

    let Some(account_id) = choose_account_id(
        &idm_admin,
        "Select a user to receive default Kanidm administration roles",
    )?
    else {
        return Ok(());
    };

    run_privileged_command("Assign System Admin", &idm_admin, || {
        assign_system_admin(&idm_admin, &account_id)
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

fn redirect_flow(kanidm: &KanidmCli, add: bool) -> Result<(), AppError> {
    let Some(client) = choose_client_name(kanidm, "Select an oauth2 client")? else {
        return Ok(());
    };
    let url = forms::input_required_validated("Redirect URL", None, validate_redirect_url)?;
    if add {
        run_privileged_command("OAuth2 Redirect", kanidm, || {
            client_redirect_add(kanidm, &client, &url)
        })
    } else {
        run_privileged_command("OAuth2 Redirect", kanidm, || {
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
    edit_membership_for_account(kanidm, &account_id)
}

fn edit_membership_for_account(kanidm: &KanidmCli, account_id: &str) -> Result<(), AppError> {
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
    if inventory.groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            "Authoritative membership editing is blocked because the live group picker returned no visible groups. Use read-only inspection or fix Kanidm group discovery first.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let current = show_membership(kanidm, account_id)?;
    let current_groups = extract_groups(&current);
    let missing_groups = missing_visible_membership_inventory(&current_groups, &inventory.groups);
    if !missing_groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            &format!(
                "Authoritative membership editing is blocked because the live group picker is missing the user's current visible access groups.\n\nMissing Groups:\n{}\n\nCurrent Direct Groups:\n{}",
                render_bullets(&missing_groups),
                render_group_block(&current_groups),
            ),
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let defaults = current_groups
        .iter()
        .map(|current_group| current_group.to_string())
        .collect::<Vec<_>>();
    let item_defaults = inventory
        .groups
        .iter()
        .map(|group| defaults.iter().any(|current| current == &group.name))
        .collect::<Vec<_>>();
    let Some(selected) = forms::membership_picker(
        &format!("Set access groups for '{account_id}'"),
        &inventory.groups,
        &item_defaults,
        &current_groups,
    )?
    else {
        return Ok(());
    };
    let groups = selected
        .into_iter()
        .map(|index| inventory.groups[index].name.clone())
        .collect::<Vec<_>>();
    let preserve_groups = preserved_hidden_memberships(&current_groups).collect::<Vec<_>>();

    run_privileged_command("Memberships", kanidm, || {
        set_membership(
            kanidm,
            SetMembershipOptions {
                account_id: account_id.to_string(),
                groups: groups.clone(),
                preserve_groups: preserve_groups.clone(),
                allow_empty: true,
            },
        )
    })
}

fn manage_user_access_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to manage access for")? else {
        return Ok(());
    };
    edit_membership_for_account(kanidm, &account_id)
}

fn find_view_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to view")? else {
        return Ok(());
    };
    let user = load_user(kanidm, &account_id)?;
    render::print_output("User Summary", &human_operator_user_summary(&user.value));
    forms::pause("Press Enter or Esc to continue")
}

fn disable_enable_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to disable or re-enable")?
    else {
        return Ok(());
    };
    let user = load_user(kanidm, &account_id)?;
    let enabled = is_user_enabled(&user.value);
    render::print_note(
        "User State",
        &format!(
            "{}\n\nCurrent Status: {}",
            human_operator_user_summary(&user.value),
            if enabled {
                "enabled"
            } else {
                "disabled or restricted"
            }
        ),
    );
    match forms::confirm(
        if enabled {
            "Disable this user now?"
        } else {
            "Enable this user now?"
        },
        true,
    )? {
        Some(true) if enabled => {
            run_privileged_command("Disable User", kanidm, || disable_user(kanidm, &account_id))
        }
        Some(true) => {
            run_privileged_command("Enable User", kanidm, || enable_user(kanidm, &account_id))
        }
        _ => Ok(()),
    }
}

fn membership_change_flow(kanidm: &KanidmCli, mode: MembershipChange) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user")? else {
        return Ok(());
    };
    let group_text =
        forms::input_required("Enter one or more group names separated by spaces", None)?;
    let groups = group_text
        .split_whitespace()
        .map(|group| validate_identifier_field("group name", group))
        .collect::<Result<Vec<_>, _>>()?;
    match mode {
        MembershipChange::Add => run_privileged_command("Memberships", kanidm, || {
            add_membership(kanidm, &account_id, &groups)
        }),
        MembershipChange::Remove => run_privileged_command("Memberships", kanidm, || {
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

fn group_target_flow_privileged<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    action: F,
) -> Result<(), AppError>
where
    F: Fn(&str) -> Result<CommandOutput, AppError>,
{
    let Some(group) = choose_group_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_privileged_command("Group", kanidm, || action(&group))
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

fn client_target_flow_privileged<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    action: F,
) -> Result<(), AppError>
where
    F: Fn(&str) -> Result<CommandOutput, AppError>,
{
    let Some(client) = choose_client_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_privileged_command("OAuth2 Client", kanidm, || action(&client))
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
        return forms::input_optional_validated(
            "No users were listed. Enter an account id manually",
            None,
            validate_account_id,
        );
    }
    let mut items = vec![menu_item(
        "Enter an account id manually",
        "Type an account id directly.",
        "Use manual entry when the user is missing from discovery or you already know the exact account id.",
    )];
    items.extend(people.value.iter().map(|person| {
        menu_item(
            &person.account_id,
            person
                .display_name
                .as_deref()
                .unwrap_or("No display name is set for this user."),
            &format!(
                "Primary email: {}",
                person.primary_email.as_deref().unwrap_or("not set")
            ),
        )
    }));
    let Some(selection) = forms::contextual_select(prompt, None, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional_validated(
            "Enter the Kanidm account id to manage",
            None,
            validate_account_id,
        );
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
        return forms::input_optional_validated(
            "No groups were listed. Enter a group name manually",
            None,
            |value| validate_identifier_field("group name", value),
        );
    }
    let visible_groups = groups
        .value
        .iter()
        .filter(|group| is_operator_visible_group(&group.name))
        .cloned()
        .collect::<Vec<_>>();
    if visible_groups.is_empty() {
        return forms::input_optional_validated(
            "No non-IDM groups were listed. Enter a group name manually",
            None,
            |value| validate_identifier_field("group name", value),
        );
    }
    let Some(selection) =
        forms::group_picker(prompt, "Enter a group name manually", &visible_groups)?
    else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional_validated("Enter the group name to manage", None, |value| {
            validate_identifier_field("group name", value)
        });
    }
    Ok(Some(visible_groups[selection - 1].name.clone()))
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
        return forms::input_optional_validated(
            "No oauth2 clients were listed. Enter a client name manually",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        );
    }
    let mut items = vec![menu_item(
        "Enter an oauth2 client name manually",
        "Type a client name directly.",
        "Use manual entry when the client is missing from live discovery or you already know the exact name.",
    )];
    items.extend(clients.value.iter().map(|client| {
        menu_item(
            &client.name,
            client
                .display_name
                .as_deref()
                .unwrap_or("No display name is set for this client."),
            &format!(
                "Landing URL: {}",
                client.landing_url.as_deref().unwrap_or("not set")
            ),
        )
    }));
    let Some(selection) = forms::contextual_select(prompt, None, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return forms::input_optional_validated(
            "Enter the oauth2 client name to manage",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        );
    }
    Ok(Some(clients.value[selection - 1].name.clone()))
}

fn perform_command<F>(kanidm: &KanidmCli, action: F) -> Result<Option<CommandOutput>, AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(output) => Ok(Some(output)),
        Err(error) => {
            match prompt_for_session_recovery(kanidm, &error)? {
                SessionRecoveryResult::Recovered | SessionRecoveryResult::Aborted => {
                    return Ok(None);
                }
                SessionRecoveryResult::NotApplicable => {}
            }
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(None)
        }
    }
}

fn perform_privileged_command<F>(
    kanidm: &KanidmCli,
    mut action: F,
) -> Result<PrivilegedCommandResult, AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    if !ensure_privileged_session_ready(kanidm)? {
        return Ok(PrivilegedCommandResult::Cancelled);
    }

    match action() {
        Ok(output) => Ok(PrivilegedCommandResult::Output(output)),
        Err(error) => match prompt_for_session_recovery(kanidm, &error)? {
            SessionRecoveryResult::Recovered => match action() {
                Ok(output) => Ok(PrivilegedCommandResult::Output(output)),
                Err(retry_error) => Ok(PrivilegedCommandResult::Error(retry_error)),
            },
            SessionRecoveryResult::Aborted => Ok(PrivilegedCommandResult::Cancelled),
            SessionRecoveryResult::NotApplicable => Ok(PrivilegedCommandResult::Error(error)),
        },
    }
}

fn run_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    if let Some(output) = perform_command(kanidm, action)? {
        render_output(title, output)?;
    }
    Ok(())
}

fn run_privileged_command<F>(title: &str, kanidm: &KanidmCli, action: F) -> Result<(), AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
    match perform_privileged_command(kanidm, action)? {
        PrivilegedCommandResult::Output(output) => render_output(title, output)?,
        PrivilegedCommandResult::Error(error) => {
            render::print_error(&error);
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
                    "Session for '{}' has expired. Would you like to authenticate again now?",
                    kanidm.admin_name()
                ),
            );
            match forms::confirm("Authenticate now?", true)? {
                Some(true) => run_command("Login", kanidm, || session_login(kanidm)),
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

fn ensure_privileged_session_ready(kanidm: &KanidmCli) -> Result<bool, AppError> {
    match kanidm.session_status()? {
        SessionState::Authenticated { .. } => Ok(true),
        SessionState::Expired { diagnostic } => {
            render::print_note(
                "Authentication Required",
                &format!(
                    "The authenticated Kanidm session for '{}' has expired, so privileged commands cannot run yet.\n\nDiagnostic:\n{}",
                    kanidm.admin_name(),
                    diagnostic.trim()
                ),
            );
            recover_login(kanidm, "Authenticate now?")
        }
        SessionState::Missing { diagnostic } => {
            render::print_note(
                "Authentication Required",
                &format!(
                    "No authenticated Kanidm session is active for '{}', so privileged commands cannot run yet.\n\nDiagnostic:\n{}",
                    kanidm.admin_name(),
                    diagnostic.trim()
                ),
            );
            recover_login(kanidm, "Authenticate now?")
        }
        SessionState::ReauthRequired { diagnostic } => {
            render::print_note(
                "Reauthentication Required",
                &format!(
                    "The base Kanidm session for '{}' is still active, but privileged write access has expired.\n\nDiagnostic:\n{}",
                    kanidm.admin_name(),
                    diagnostic.trim()
                ),
            );
            recover_reauth(kanidm, "Reauthenticate now?")
        }
    }
}

fn recover_login(kanidm: &KanidmCli, prompt: &str) -> Result<bool, AppError> {
    match forms::confirm(prompt, true)? {
        Some(true) => run_session_recovery_command("Login", || session_login(kanidm)),
        _ => Ok(false),
    }
}

fn recover_reauth(kanidm: &KanidmCli, prompt: &str) -> Result<bool, AppError> {
    match forms::confirm(prompt, true)? {
        Some(true) => run_session_recovery_command("Reauthenticate", || session_reauth(kanidm)),
        _ => Ok(false),
    }
}

fn run_session_recovery_command<F>(title: &str, action: F) -> Result<bool, AppError>
where
    F: FnOnce() -> Result<CommandOutput, AppError>,
{
    match action() {
        Ok(output) => {
            render_output(title, output)?;
            Ok(true)
        }
        Err(error) => {
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(false)
        }
    }
}

fn prompt_for_session_recovery(
    kanidm: &KanidmCli,
    error: &AppError,
) -> Result<SessionRecoveryResult, AppError> {
    match error {
        AppError::SessionRequired { .. } => {
            render::print_note(
                "Session Required",
                &format!(
                    "Session for '{}' has expired or is unavailable. Would you like to authenticate now?",
                    kanidm.admin_name()
                ),
            );
            recover_login(kanidm, "Authenticate now?").map(|recovered| {
                if recovered {
                    SessionRecoveryResult::Recovered
                } else {
                    SessionRecoveryResult::Aborted
                }
            })
        }
        AppError::ReauthRequired { .. } => {
            render::print_note(
                "Reauthentication Required",
                &format!(
                    "Session for '{}' requires privileged reauthentication. The base session may still appear active, but write access has expired. Would you like to reauthenticate now?",
                    kanidm.admin_name()
                ),
            );
            recover_reauth(kanidm, "Reauthenticate now?").map(|recovered| {
                if recovered {
                    SessionRecoveryResult::Recovered
                } else {
                    SessionRecoveryResult::Aborted
                }
            })
        }
        _ => Ok(SessionRecoveryResult::NotApplicable),
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

fn menu_item(label: &str, summary: &str, detail: &str) -> forms::ContextualItem {
    forms::ContextualItem {
        label: label.to_string(),
        summary: summary.to_string(),
        detail: detail.to_string(),
    }
}

fn simple_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Create User",
            "Create a new Kanidm person and then assign their access groups.",
            "Use this for new staff or household members. The workflow creates the identity first and then immediately guides you through normal and admin access groups.",
        ),
        menu_item(
            "Manage User Access",
            "Set the user's normal app and file access groups.",
            "Use this to review and replace the user's full direct-group access set. This is the main day-to-day workflow for normal versus admin access changes.",
        ),
        menu_item(
            "Find / View User",
            "Inspect a user and understand what access they currently have.",
            "Use this when you need to confirm identity details, status, direct groups, or app-access implications without changing anything.",
        ),
        menu_item(
            "Disable / Enable User",
            "Temporarily block or restore a user's ability to sign in.",
            "Use disable for temporary lockout or offboarding without deleting the identity. The workflow detects the current state and offers only the valid action.",
        ),
        menu_item(
            "Help User Reset Password",
            "Generate a temporary password reset link for a user.",
            "Use this when someone cannot sign in and needs to set a new password. The result should be shared through a secure channel because it grants temporary password reset access.",
        ),
        menu_item(
            "Advanced",
            "Open lower-level Kanidm and local helper tools.",
            "Use this for session management, raw membership tools, group inspection, OAuth2 clients, policy, diagnostics, or permanent deletion.",
        ),
        menu_item(
            "Exit",
            "Leave the interactive Kanidm admin tool.",
            "Use this when you are finished with user administration tasks.",
        ),
    ]
}

fn advanced_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Session Tools",
            "Inspect or manage the current Kanidm CLI session.",
            "Use this for explicit login, reauthentication, logout, or session inspection. Most day-to-day flows can rely on the automatic session recovery prompts instead.",
        ),
        menu_item(
            "Group Inspection",
            "Read group information without changing access.",
            "Use this to list groups, inspect a group, search by name, or review group members. Manual entry still works for hidden internal groups when you already know the exact name.",
        ),
        menu_item(
            "Membership Tools",
            "Open the lower-level direct-group access commands.",
            "Use this only when the guided access workflow is not enough. These tools expose raw add, remove, inspect, and exact-set operations.",
        ),
        menu_item(
            "OAuth2 Clients",
            "Inspect and adjust live OAuth2 client behavior.",
            "Use this for client secrets, redirects, PKCE, and consent prompts. New system admins normally do not need this during user onboarding.",
        ),
        menu_item(
            "Group Policy",
            "Inspect or tune live Kanidm group account policy.",
            "Use this for auth-expiry or privilege-expiry changes. This is a specialized area and not part of routine user administration.",
        ),
        menu_item(
            "Context / Doctor",
            "Inspect tool context and run basic environment checks.",
            "Use this when troubleshooting Kanidm connection context or verifying that the admin tool resolves the right server and operator identity.",
        ),
        menu_item(
            "Assign System Admin",
            "Grant the default Kanidm administration roles to a user.",
            "Use this disaster-recovery workflow when a named person account needs the built-in Kanidm admin roles. It uses the break-glass 'idm_admin' account and grants only 'idm_admins' and 'system_admins'.",
        ),
        menu_item(
            "Local Helpers",
            "Run machine-local helper utilities that are not normal Kanidm operations.",
            "Use this for local helper tasks such as staging a Jellyfin password hash. This area is intentionally separate from normal identity administration.",
        ),
        menu_item(
            "Delete User",
            "Permanently remove a Kanidm identity.",
            "Use this only when the identity should no longer exist at all. Do not use it for temporary lockout or routine access removal.",
        ),
        menu_item(
            "Back",
            "Return to the main task menu.",
            "Go back to the default guided admin workflow.",
        ),
    ]
}

fn session_tools_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Status",
            "Inspect the current Kanidm CLI session state.",
            "Use this to confirm whether the delegated operator session is active, expired, or needs privileged reauthentication.",
        ),
        menu_item(
            "Login",
            "Start a new Kanidm CLI session.",
            "Use this when no valid session exists yet. The login flow requires an interactive terminal.",
        ),
        menu_item(
            "Reauthenticate",
            "Refresh privileged session access.",
            "Use this when a session exists but privileged operations now require reauthentication.",
        ),
        menu_item(
            "Logout",
            "End the current Kanidm CLI session.",
            "Use this when the current delegated operator session should be cleared from the machine.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing the current Kanidm session.",
        ),
    ]
}

fn group_inspection_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "List groups",
            "Show the live Kanidm groups.",
            "Use this for a broad read-only inventory of available groups.",
        ),
        menu_item(
            "Search groups",
            "Search live groups by name or description.",
            "Use this when you need to find a group quickly without scanning the full list.",
        ),
        menu_item(
            "Show group",
            "Inspect one group in detail.",
            "Use this to review a group's description and other live details.",
        ),
        menu_item(
            "List group members",
            "Show the people currently in a group.",
            "Use this to confirm who currently holds a specific access or admin role.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without inspecting more groups.",
        ),
    ]
}

fn membership_tools_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item("View User Access", "Show a user's current direct groups.", "Use this for a raw read-only view of direct group membership when the guided user summary is not enough."),
        menu_item("Add memberships", "Add one or more direct groups without replacing the rest.", "Use this only when you intentionally want an incremental access change instead of replacing the full direct-group set."),
        menu_item("Remove memberships", "Remove one or more direct groups without changing the rest.", "Use this for targeted incremental access removal when the full guided access workflow would be excessive."),
        menu_item("Set exact memberships", "Replace the user's full direct-group set.", "Use this to authoritatively define the final direct-group access list for a user. This is the same exact-set behavior used by the guided access workflow."),
        menu_item("Back", "Return to Advanced.", "Go back without making membership changes."),
    ]
}

fn is_user_enabled(user: &UserRecord) -> bool {
    user.valid_from.is_none() && user.expiry.is_none()
}

fn human_operator_user_summary(user: &UserRecord) -> String {
    let status = if is_user_enabled(user) {
        "enabled"
    } else {
        "disabled or restricted"
    };
    let visible_groups = user
        .groups
        .iter()
        .filter(|group| is_operator_visible_group(group))
        .cloned()
        .collect::<Vec<_>>();
    let hidden_groups = user
        .groups
        .iter()
        .filter(|group| !is_operator_visible_group(group))
        .cloned()
        .collect::<Vec<_>>();

    let mut body = format!(
        "Account ID: {}\nDisplay Name: {}\nPrimary Email: {}\nStatus: {}\n\nVisible Access Groups:\n{}",
        user.account_id,
        user.display_name.as_deref().unwrap_or("-"),
        user.primary_email.as_deref().unwrap_or("-"),
        status,
        render_group_block(&visible_groups),
    );

    if !hidden_groups.is_empty() {
        body.push_str("\n\nHidden Internal IDM Groups:\n");
        body.push_str(&render_group_block(&hidden_groups));
    }

    let implications = visible_groups
        .iter()
        .map(|group| {
            let help = resolve_group_help(group, None);
            format!("- {group}: {}", help.summary)
        })
        .collect::<Vec<_>>();
    if !implications.is_empty() {
        body.push_str("\n\nAccess Notes:\n");
        body.push_str(&implications.join("\n"));
    }

    body
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

fn missing_visible_membership_inventory(
    current_groups: &[String],
    inventory_groups: &[GroupSummary],
) -> Vec<String> {
    let inventory_names = inventory_groups
        .iter()
        .map(|group| group.name.as_str())
        .collect::<std::collections::BTreeSet<_>>();

    current_groups
        .iter()
        .filter(|group| is_operator_visible_group(group))
        .filter(|group| !inventory_names.contains(group.as_str()))
        .cloned()
        .collect::<Vec<_>>()
}

fn preserved_hidden_memberships<'a>(
    current_groups: &'a [String],
) -> impl Iterator<Item = String> + 'a {
    current_groups
        .iter()
        .filter(|group| !is_operator_visible_group(group))
        .cloned()
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

enum SessionRecoveryResult {
    NotApplicable,
    Recovered,
    Aborted,
}

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
    use super::*;

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
    fn missing_visible_membership_inventory_ignores_hidden_idm_groups() {
        let missing = missing_visible_membership_inventory(
            &[
                "idm_all_persons".to_string(),
                "users".to_string(),
                "paperless-admin".to_string(),
            ],
            &[GroupSummary {
                name: "users".to_string(),
                description: None,
            }],
        );

        assert_eq!(missing, vec!["paperless-admin".to_string()]);
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
}
