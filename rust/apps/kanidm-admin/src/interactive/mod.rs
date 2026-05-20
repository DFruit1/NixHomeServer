pub mod controller;
pub mod forms;
pub mod home;
pub mod render;

pub use controller::run;

use serde_json::Value;

use crate::{
    context::ResolvedContext,
    inventory::{
        clients::{parse_client_list, ClientSummary},
        groups::{is_operator_visible_group, parse_group_list, resolve_group_help, GroupSummary},
        users::{parse_user_list, UserRecord, UserSummary},
        Parsed,
    },
    kanidm_cli::{KanidmCli, SessionSnapshot},
    ops::{
        client::{
            client_consent_disable, client_consent_enable, client_pkce_disable, client_pkce_enable,
            client_redirect_add, client_redirect_remove, client_secret_reset, client_secret_show,
            list_clients, load_client, show_client,
        },
        context::{doctor, show_context},
        executor::{
            execute_interactive_operation, OperationKind, OperationOutcome, OperationPreconditions,
            RecoveryTarget,
        },
        group::{group_members, list_groups, load_group, search_groups, show_group},
        local::{
            invite_vaultwarden_user, lookup_vaultwarden_user, stage_jellyfin_password,
            VaultwardenUserState, VaultwardenUserStatus,
        },
        membership::{
            add_membership, membership_diff, normalize_groups, prepare_membership_picker_inventory,
            remove_membership, set_membership, show_membership, SetMembershipOptions,
        },
        policy::{
            reset_group_auth_expiry, reset_group_privilege_expiry, set_group_auth_expiry,
            set_group_privilege_expiry, show_group_policy,
        },
        session::{session_login, session_logout, session_reauth, session_status},
        user::{
            add_ssh_key, create_user, delete_user, disable_user, enable_user, list_ssh_keys,
            load_user, remove_ssh_key, reset_token, AddSshKeyOptions, CreateUserOptions,
            DeleteUserOptions, RemoveSshKeyOptions, ResetTokenOptions,
        },
    },
    output::CommandOutput,
    session_state::{
        concise_session_message, login_prompt_message, should_prompt_for_startup_login,
    },
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url, validate_seconds_field, validate_ssh_key_tag,
        validate_ssh_public_key, AUTH_EXPIRY_MAX_SECONDS, AUTH_EXPIRY_MIN_SECONDS,
        PRIVILEGE_EXPIRY_MAX_SECONDS, PRIVILEGE_EXPIRY_MIN_SECONDS, RESET_TOKEN_TTL_MAX_SECONDS,
        RESET_TOKEN_TTL_MIN_SECONDS,
    },
    AppError,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GroupPickerScope {
    OperatorVisibleOnly,
    AllGroups,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GroupPickerInventory {
    intro: &'static str,
    no_matching_groups_prompt: &'static str,
    manual_prompt: &'static str,
    manual_label: &'static str,
    manual_detail: &'static str,
    groups: Vec<GroupSummary>,
}

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
            2 => membership_tools_menu(kanidm)?,
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
            1 => run_session_command("Login", || session_login(kanidm))?,
            2 => run_session_command("Reauthenticate", || session_reauth(kanidm))?,
            3 => run_session_command("Logout", || session_logout(kanidm))?,
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
                run_command("Doctor", kanidm, || doctor(context, kanidm))?;
            }
            _ => break,
        }
    }
    Ok(())
}

fn local_helpers_menu(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    while let Some(selection) = forms::contextual_select(
        "Local Helpers",
        Some(
            "Run machine-local helper utilities that are intentionally separate from normal Kanidm identity administration.",
        ),
        &local_helpers_menu_items(),
        0,
    )? {
        match selection {
            0 => {
                let Some(account_id) =
                    choose_account_id(kanidm, "Select a user to invite into Vaultwarden")?
                else {
                    continue;
                };
                let Some(user) = require_complete_user_for_action(
                    kanidm,
                    &account_id,
                    "invite into Vaultwarden",
                )? else {
                    continue;
                };
                let Some(primary_email) = user.value.primary_email.as_deref() else {
                    render::print_error(&AppError::Config {
                        message: format!(
                            "cannot invite '{}' into Vaultwarden because the Kanidm user does not have a primary email",
                            account_id
                        ),
                    });
                    forms::pause("Press Enter or Esc to continue")?;
                    continue;
                };
                let vaultwarden_status = match lookup_vaultwarden_user(context, primary_email) {
                    Ok(status) => status,
                    Err(error) => {
                        render::print_error(&error);
                        forms::pause("Press Enter or Esc to continue")?;
                        continue;
                    }
                };
                render::print_note(
                    "Review Vaultwarden Invite",
                    &build_vaultwarden_invite_review(
                        &user.value,
                        primary_email,
                        &vaultwarden_status,
                        context.vaultwarden_url.as_deref(),
                    ),
                );
                let Some(prompt) = build_vaultwarden_invite_prompt(&vaultwarden_status) else {
                    forms::pause("Press Enter or Esc to continue")?;
                    continue;
                };
                match forms::confirm(prompt, false)? {
                    Some(true) => {}
                    _ => continue,
                }
                run_privileged_command("Vaultwarden Invite", kanidm, || {
                    invite_vaultwarden_user(context, kanidm, &account_id)
                })?;
            }
            1 => {
                let Some(account_id) = prompt_submitted(forms::input_required_validated(
                    "Jellyfin account id",
                    None,
                    validate_account_id,
                )?) else {
                    continue;
                };
                let Some(password_env) =
                    prompt_submitted(forms::input_required("Password env var", Some("JELLYFIN_PASSWORD"))?) else {
                        continue;
                    };
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
    let Some(account_id) = prompt_submitted(forms::input_required_validated(
        "New account id / username",
        None,
        validate_account_id,
    )?) else {
        return Ok(());
    };
    let Some(display_name) = prompt_submitted(forms::input_required_validated(
        &format!("Display name for '{account_id}'"),
        Some(&account_id),
        validate_display_name,
    )?) else {
        return Ok(());
    };
    let email = match forms::input_optional_validated(
        "Primary email (leave blank to skip)",
        None,
        validate_email,
    )? {
        forms::PromptResult::Submitted(email) => email,
        forms::PromptResult::Cancelled => return Ok(()),
    };
    let outcome = perform_privileged_command(kanidm, || {
        create_user(
            kanidm,
            CreateUserOptions {
                account_id: account_id.clone(),
                display_name: display_name.clone(),
                email: email.clone(),
                clear_validity: true,
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
    let Some(user) = require_complete_user_for_action(kanidm, &account_id, "delete")? else {
        return Ok(());
    };
    render::print_note(
        "Review User Deletion",
        &build_delete_user_review(&user.value),
    );
    let Some(confirmation) = prompt_submitted(forms::input_required(
        &format!("Type {account_id} to permanently delete the user"),
        None,
    )?) else {
        return Ok(());
    };
    match forms::confirm("Permanently delete this user now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
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
    let Some(user) =
        require_complete_user_for_action(kanidm, &account_id, "create a password reset link for")?
    else {
        return Ok(());
    };
    let Some(ttl_text) = prompt_submitted(forms::input_required(
        "Password reset link lifetime in seconds",
        Some("3600"),
    )?) else {
        return Ok(());
    };
    let ttl_seconds = validate_seconds_field(
        "reset token TTL",
        ttl_text.parse::<u64>().map_err(|error| AppError::Config {
            message: format!("invalid reset token TTL '{ttl_text}': {error}"),
        })?,
        RESET_TOKEN_TTL_MIN_SECONDS,
        RESET_TOKEN_TTL_MAX_SECONDS,
    )?;
    render::print_note(
        "Review Password Reset Link",
        &build_reset_password_review(&user.value, ttl_seconds),
    );
    match forms::confirm("Create a temporary password reset link now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
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

fn manage_user_ssh_keys_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user for SFTP SSH keys")? else {
        return Ok(());
    };
    while let Some(selection) = forms::contextual_select(
        "SFTP SSH Keys",
        Some(
            "Register public keys that users generated on their own PC. Ask the user for the one-line contents of their .pub file, never their private key. SFTP access also requires user-files membership.",
        ),
        &ssh_key_menu_items(),
        0,
    )? {
        match selection {
            0 => run_command("SFTP SSH Keys", kanidm, || list_ssh_keys(kanidm, &account_id))?,
            1 => add_user_ssh_key_flow(kanidm, &account_id)?,
            2 => remove_user_ssh_key_flow(kanidm, &account_id)?,
            _ => break,
        }
    }
    Ok(())
}

fn add_user_ssh_key_flow(kanidm: &KanidmCli, account_id: &str) -> Result<(), AppError> {
    let Some(user) = require_complete_user_for_action(kanidm, account_id, "add an SSH key for")?
    else {
        return Ok(());
    };
    render::print_note("Add SFTP SSH Key", &build_ssh_key_upload_note(&user.value));
    forms::pause("Press Enter or Esc to continue")?;
    let Some(tag) = prompt_submitted(forms::input_required_validated(
        "SSH key tag",
        Some("local-pc"),
        validate_ssh_key_tag,
    )?) else {
        return Ok(());
    };
    let Some(public_key) = prompt_submitted(forms::input_required_validated(
        "SSH public key",
        None,
        |value| validate_ssh_public_key(value).map(|(key, _)| key),
    )?) else {
        return Ok(());
    };
    let key_type = public_key.split_whitespace().next().unwrap_or("-");
    render::print_note(
        "Review SFTP SSH Key",
        &format!(
            "Account ID: {}\nDisplay Name: {}\nTag: {}\nKey Type: {}\nuser-files: {}\n\nOnly the public key will be stored in Kanidm. The user must keep the matching private key on their own PC.",
            user.value.account_id,
            user.value.display_name.as_deref().unwrap_or("-"),
            tag,
            key_type,
            if user.value.groups.iter().any(|group| group == "user-files") {
                "present"
            } else {
                "missing"
            },
        ),
    );
    match forms::confirm("Register this SSH public key now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    run_privileged_command("SFTP SSH Key", kanidm, || {
        add_ssh_key(
            kanidm,
            AddSshKeyOptions {
                account_id: account_id.to_string(),
                tag: tag.clone(),
                public_key: Some(public_key.clone()),
                public_key_file: None,
            },
        )
    })
}

fn build_ssh_key_upload_note(user: &UserRecord) -> String {
    let account_id = &user.account_id;
    let user_files_status = if user.groups.iter().any(|group| group == "user-files") {
        "present"
    } else {
        "missing; grant it separately if this user should access SFTP"
    };
    format!(
        "Account ID: {account_id}\nDisplay Name: {}\nuser-files: {user_files_status}\n\nWhat to ask the user for:\n- They generate the keypair on their own PC.\n- They send you only the public key line from their .pub file.\n- The public key usually starts with ssh-ed25519 or ssh-rsa.\n- Do not accept or store a private key.\n\nUseful user-side command:\nssh-keygen -t ed25519 -a 100 -C \"{account_id}@local-pc\"\n\nThen ask them to send the contents of:\n~/.ssh/id_ed25519.pub\n\nNext prompts:\n- Tag: a short device label, such as laptop or desktop.\n- SSH public key: paste the complete one-line .pub contents.",
        user.display_name.as_deref().unwrap_or("-"),
    )
}

fn remove_user_ssh_key_flow(kanidm: &KanidmCli, account_id: &str) -> Result<(), AppError> {
    let Some(tag) = prompt_submitted(forms::input_required_validated(
        "SSH key tag to remove",
        None,
        validate_ssh_key_tag,
    )?) else {
        return Ok(());
    };
    render::print_note(
        "Review SFTP SSH Key Removal",
        &format!("Account ID: {account_id}\nTag: {tag}"),
    );
    match forms::confirm("Remove this SSH public key now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    run_privileged_command("SFTP SSH Key", kanidm, || {
        remove_ssh_key(
            kanidm,
            RemoveSshKeyOptions {
                account_id: account_id.to_string(),
                tag: tag.clone(),
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

fn redirect_flow(kanidm: &KanidmCli, add: bool) -> Result<(), AppError> {
    let Some(client) = choose_client_name(kanidm, "Select an oauth2 client")? else {
        return Ok(());
    };
    let Some(url) = prompt_submitted(forms::input_required_validated(
        "Redirect URL",
        None,
        validate_redirect_url,
    )?) else {
        return Ok(());
    };
    let Some(client_record) =
        require_complete_client_for_action(kanidm, &client, "change oauth2 redirect URLs for")?
    else {
        return Ok(());
    };
    let already_present = client_record
        .value
        .redirect_urls
        .iter()
        .any(|candidate| candidate == &url);
    if add && already_present {
        render::print_note(
            "OAuth2 Redirect",
            "No redirect URL changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    if !add && !already_present {
        render::print_note(
            "OAuth2 Redirect",
            "No redirect URL changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note(
        "Review OAuth2 Redirect Change",
        &build_redirect_review(&client_record.value, &url, add, already_present),
    );
    match forms::confirm("Apply this redirect change now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
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
    let Some(inventory) =
        perform_interactive_read(kanidm, || prepare_membership_picker_inventory(kanidm))?
    else {
        return Ok(());
    };
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

    let Some(current) = require_complete_user_for_action(
        kanidm,
        account_id,
        "authoritatively set memberships for",
    )?
    else {
        return Ok(());
    };
    let current_groups = current.value.groups.clone();
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
    let mut item_defaults = inventory
        .groups
        .iter()
        .map(|group| defaults.iter().any(|current| current == &group.name))
        .collect::<Vec<_>>();
    let preserve_groups = preserved_hidden_memberships(&current_groups).collect::<Vec<_>>();

    loop {
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
        let review =
            build_membership_review(account_id, &current_groups, groups, preserve_groups.clone());

        if review.diff.is_empty() {
            render::print_note(
                "Review Membership Changes",
                "No membership changes would be applied.",
            );
            return forms::pause("Press Enter or Esc to continue");
        }

        render::print_note("Review Membership Changes", &review.render());
        match forms::confirm("Apply these membership changes now?", false)? {
            Some(true) => {
                return run_privileged_command("Memberships", kanidm, || {
                    set_membership(
                        kanidm,
                        SetMembershipOptions {
                            account_id: account_id.to_string(),
                            groups: review.selected_visible_groups.clone(),
                            preserve_groups: review.preserved_hidden_groups.clone(),
                            allow_empty: true,
                        },
                    )
                });
            }
            _ => {
                item_defaults = inventory
                    .groups
                    .iter()
                    .map(|group| {
                        review
                            .selected_visible_groups
                            .iter()
                            .any(|selected| selected == &group.name)
                    })
                    .collect::<Vec<_>>();
            }
        }
    }
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
    let Some(user) = perform_interactive_read(kanidm, || load_user(kanidm, &account_id))? else {
        return Ok(());
    };
    render::print_output("User Summary", &human_operator_user_summary(&user.value));
    forms::pause("Press Enter or Esc to continue")
}

fn disable_enable_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to disable or re-enable")?
    else {
        return Ok(());
    };
    let Some(user) =
        require_complete_user_for_action(kanidm, &account_id, "change the enabled state for")?
    else {
        return Ok(());
    };
    let enabled = is_user_enabled(&user.value);
    render::print_note(
        "Review User State Change",
        &format!(
            "{}\n\nCurrent Status: {}\n\nEffect:\n{}",
            human_operator_user_summary(&user.value),
            if enabled {
                "enabled"
            } else {
                "disabled or restricted"
            },
            if enabled {
                "Disabling the user will block sign-in after the validity restriction converges."
            } else {
                "Enabling the user will clear validity restrictions and restore sign-in."
            }
        ),
    );
    match forms::confirm(
        if enabled {
            "Disable this user now?"
        } else {
            "Enable this user now?"
        },
        false,
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
    let Some(current) = require_complete_user_for_action(
        kanidm,
        &account_id,
        if matches!(mode, MembershipChange::Add) {
            "add memberships for"
        } else {
            "remove memberships for"
        },
    )?
    else {
        return Ok(());
    };
    let Some(inventory) =
        perform_interactive_read(kanidm, || prepare_membership_picker_inventory(kanidm))?
    else {
        return Ok(());
    };
    if !inventory.warnings.is_empty() {
        return block_incomplete_inventory(
            "Membership Inventory Incomplete",
            "Incremental membership changes are blocked because the live discovery set is incomplete.",
            &inventory.warnings,
        );
    }
    if inventory.groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            "Incremental membership changes are blocked because the live group picker returned no visible groups. Use read-only inspection or fix Kanidm group discovery first.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let Some(groups) = choose_membership_change_groups(
        kanidm,
        &account_id,
        &current.value,
        &inventory.groups,
        mode,
    )?
    else {
        return Ok(());
    };
    let review = build_membership_change_review(&account_id, &current.value.groups, groups, mode);
    if review.is_noop() {
        render::print_note(
            "Review Membership Changes",
            "No membership changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note("Review Membership Changes", &review.render());
    let prompt = if matches!(mode, MembershipChange::Add) {
        "Add these groups now?"
    } else {
        "Remove these groups now?"
    };
    match forms::confirm(prompt, false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    match mode {
        MembershipChange::Add => run_privileged_command("Memberships", kanidm, || {
            add_membership(kanidm, &account_id, &review.groups_to_add)
        }),
        MembershipChange::Remove => run_privileged_command("Memberships", kanidm, || {
            remove_membership(kanidm, &account_id, &review.groups_to_remove)
        }),
    }
}

fn user_target_flow<F>(kanidm: &KanidmCli, prompt: &str, mut action: F) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
{
    let Some(account_id) = choose_account_id(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("User", kanidm, || action(&account_id))
}

fn group_target_flow_with_scope<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    scope: GroupPickerScope,
    mut action: F,
) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
{
    let Some(group) = choose_group_name_with_scope(kanidm, prompt, scope)? else {
        return Ok(());
    };
    run_command("Group", kanidm, || action(&group))
}

fn client_target_flow<F>(kanidm: &KanidmCli, prompt: &str, mut action: F) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
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
    let Some(people) =
        perform_interactive_read(kanidm, || parse_user_list(&kanidm.person_list::<Value>()?))?
    else {
        return Ok(None);
    };
    choose_from_users(prompt, &people)
}

fn choose_group_name_with_scope(
    kanidm: &KanidmCli,
    prompt: &str,
    scope: GroupPickerScope,
) -> Result<Option<String>, AppError> {
    let Some(groups) =
        perform_interactive_read(kanidm, || parse_group_list(&kanidm.group_list::<Value>()?))?
    else {
        return Ok(None);
    };
    choose_from_groups(prompt, &groups, scope)
}

fn choose_client_name(kanidm: &KanidmCli, prompt: &str) -> Result<Option<String>, AppError> {
    let Some(clients) = perform_interactive_read(kanidm, || {
        parse_client_list(&kanidm.oauth2_list::<Value>()?)
    })?
    else {
        return Ok(None);
    };
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
        return prompt_optional_submitted(forms::input_optional_validated(
            "No users were listed. Enter an account id manually",
            None,
            validate_account_id,
        )?);
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
        return prompt_optional_submitted(forms::input_optional_validated(
            "Enter the Kanidm account id to manage",
            None,
            validate_account_id,
        )?);
    }
    Ok(Some(people.value[selection - 1].account_id.clone()))
}

fn choose_from_groups(
    prompt: &str,
    groups: &Parsed<Vec<GroupSummary>>,
    scope: GroupPickerScope,
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
        return prompt_optional_submitted(forms::input_optional_validated(
            "No groups were listed. Enter a group name manually",
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    let picker = build_group_picker_inventory(&groups.value, scope);
    if picker.groups.is_empty() {
        return prompt_optional_submitted(forms::input_optional_validated(
            picker.no_matching_groups_prompt,
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    let Some(selection) = forms::group_picker(
        prompt,
        Some(picker.intro),
        picker.manual_label,
        picker.manual_detail,
        &picker.groups,
    )?
    else {
        return Ok(None);
    };
    if selection == 0 {
        return prompt_optional_submitted(forms::input_optional_validated(
            picker.manual_prompt,
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    Ok(Some(picker.groups[selection - 1].name.clone()))
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
        return prompt_optional_submitted(forms::input_optional_validated(
            "No oauth2 clients were listed. Enter a client name manually",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        )?);
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
        return prompt_optional_submitted(forms::input_optional_validated(
            "Enter the oauth2 client name to manage",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        )?);
    }
    Ok(Some(clients.value[selection - 1].name.clone()))
}

fn perform_command<F>(kanidm: &KanidmCli, action: F) -> Result<Option<CommandOutput>, AppError>
where
    F: FnMut() -> Result<CommandOutput, AppError>,
{
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
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(None)
        }
    }
}

fn perform_interactive_read<T, F>(kanidm: &KanidmCli, mut action: F) -> Result<Option<T>, AppError>
where
    F: FnMut() -> Result<T, AppError>,
{
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
            render::print_error(&error);
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

fn run_session_command<F>(title: &str, action: F) -> Result<(), AppError>
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
        Some(true) => run_session_recovery_command("Login", || session_login(kanidm)),
        _ => Ok(false),
    }
}

fn recover_reauth(kanidm: &KanidmCli) -> Result<bool, AppError> {
    run_privileged_session_recovery_command(kanidm)
}

fn run_privileged_session_recovery_command(kanidm: &KanidmCli) -> Result<bool, AppError> {
    match session_reauth(kanidm) {
        Ok(output) => {
            render_output("Reauthenticate", output)?;
            Ok(true)
        }
        Err(error) => {
            render::print_error(&error);
            forms::pause("Press Enter or Esc to continue")?;
            Ok(false)
        }
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
            "Use this as the normal safe path for day-to-day access changes. The workflow reviews and replaces the user's full direct-group access set with explicit before-and-after confirmation.",
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
            "Manage SFTP SSH Keys",
            "Register or remove user-provided public keys for local SFTP access.",
            "Use this after a user generates an SSH keypair on their own PC and gives you only the one-line .pub file contents. SFTP access still requires user-files membership.",
        ),
        menu_item(
            "Help User Reset Password",
            "Generate a temporary password reset link for a user.",
            "Use this when someone cannot sign in and needs to set a new password. The result should be shared through a secure channel because it grants temporary password reset access.",
        ),
        menu_item(
            "Advanced",
            "Open session management, lower-level Kanidm, and local helper tools.",
            "Use this for session tools, raw membership tools, group inspection, OAuth2 clients, policy, diagnostics, or permanent deletion.",
        ),
        menu_item(
            "Exit",
            "Leave the interactive Kanidm admin tool.",
            "Use this when you are finished with user administration tasks.",
        ),
    ]
}

fn ssh_key_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "List SSH Keys",
            "Show the user's registered SSH public keys.",
            "Use this before adding or removing a key so you can see existing device tags and avoid reusing a confusing tag.",
        ),
        menu_item(
            "Add SSH Key",
            "Register a user-provided SSH public key.",
            "Ask the user to generate the key on their own PC, then paste the full single-line public key here, for example a line beginning with ssh-ed25519. Never paste a private key.",
        ),
        menu_item(
            "Remove SSH Key",
            "Remove one registered SSH public key by tag.",
            "Use this when a device is retired, lost, replaced, or should no longer access SFTP. List keys first if you are unsure of the tag.",
        ),
        menu_item(
            "Back",
            "Return to the main menu.",
            "Use this when you are done managing SSH keys for this user.",
        ),
    ]
}

fn client_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "List clients",
            "Show the live OAuth2 client inventory.",
            "Use this for a broad read-only list of discoverable OAuth2 clients before drilling into a specific one.",
        ),
        menu_item(
            "Show client",
            "Inspect one OAuth2 client in detail.",
            "Use this to review redirect URLs, scope maps, claim maps, and related client settings.",
        ),
        menu_item(
            "Show client secret",
            "Reveal the current client secret for one OAuth2 client.",
            "Use this only when an operator needs to inspect the currently active secret value for a client.",
        ),
        menu_item(
            "Reset client secret",
            "Generate and apply a new client secret.",
            "Use this when a client secret must be rotated. This is a privileged write operation and may require reauthentication.",
        ),
        menu_item(
            "Enable PKCE",
            "Require PKCE for the selected client.",
            "Use this to harden a client that should perform PKCE-based authorization flows.",
        ),
        menu_item(
            "Disable PKCE",
            "Stop requiring PKCE for the selected client.",
            "Use this only when the client cannot complete PKCE and the runtime configuration must be relaxed.",
        ),
        menu_item(
            "Enable consent prompt",
            "Require a consent prompt for the selected client.",
            "Use this when the client should explicitly prompt users before granting access.",
        ),
        menu_item(
            "Disable consent prompt",
            "Stop requiring a consent prompt for the selected client.",
            "Use this when the current runtime flow should proceed without a consent screen.",
        ),
        menu_item(
            "Add redirect URL",
            "Append one redirect URL to a live OAuth2 client.",
            "Use this when a client needs an additional callback URL. The review screen shows the current redirect set before applying a write.",
        ),
        menu_item(
            "Remove redirect URL",
            "Remove one redirect URL from a live OAuth2 client.",
            "Use this when an old callback URL should no longer be accepted. The review screen shows the current redirect set before applying a write.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing OAuth2 client settings.",
        ),
    ]
}

fn advanced_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Session Tools",
            "Inspect or manage the current Kanidm CLI session.",
            "Use this for explicit login, reauthentication, logout, or session inspection when guided workflows are not enough.",
        ),
        menu_item(
            "Group Inspection",
            "Read group information without changing access.",
            "Use this to list groups, inspect a group, search by name, or review group members. All live groups are shown here, including internal Kanidm groups.",
        ),
        menu_item(
            "Membership Tools",
            "Open the lower-level direct-group access commands.",
            "Use this only when the guided access workflow is not enough. These tools expose targeted add/remove commands plus exact-set operations for experienced operators.",
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
            "Use this when troubleshooting Kanidm context, session health, or incomplete live discovery. Doctor is the first place to look when commands start behaving unexpectedly.",
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
            "Use this to review a group's description and other live details. All live groups are shown here, including internal Kanidm groups.",
        ),
        menu_item(
            "List group members",
            "Show the people currently in a group.",
            "Use this to confirm who currently holds a specific access or admin role. All live groups are shown here, including internal Kanidm groups.",
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
        menu_item("Add memberships", "Add one or more direct groups without replacing the rest.", "Use this for intentional targeted access additions when the full guided exact-set workflow would be excessive. The guided picker remains the default path inside this tool."),
        menu_item("Remove memberships", "Remove one or more direct groups without changing the rest.", "Use this for intentional targeted access removal when the full guided exact-set workflow would be excessive. The guided picker remains the default path inside this tool."),
        menu_item("Set exact memberships", "Replace the user's full direct-group set.", "Use this to authoritatively define the final direct-group access list for a user. This is the same exact-set behavior used by the guided access workflow."),
        menu_item("Back", "Return to Advanced.", "Go back without making membership changes."),
    ]
}

fn policy_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Show group policy",
            "Inspect the current live account-policy values for one group.",
            "Use this to read auth-expiry or privilege-expiry values before deciding whether a live policy write is needed.",
        ),
        menu_item(
            "Set auth expiry",
            "Set the live auth-expiry value for one group.",
            "Use this specialized policy control when the selected group's base authentication session lifetime needs a runtime change.",
        ),
        menu_item(
            "Reset auth expiry",
            "Clear the live auth-expiry value for one group.",
            "Use this when the explicit auth-expiry override should be removed from the selected group.",
        ),
        menu_item(
            "Set privilege expiry",
            "Set the live privileged-session expiry value for one group.",
            "Use this specialized policy control when the selected group's privileged-session lifetime needs a runtime change.",
        ),
        menu_item(
            "Reset privilege expiry",
            "Clear the live privileged-session expiry value for one group.",
            "Use this when the explicit privileged-session expiry override should be removed from the selected group.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing group policy.",
        ),
    ]
}

fn context_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Show context",
            "Inspect the repo and Kanidm connection context used by this tool.",
            "Use this to confirm which repository root, server URL, admin account name, and Kanidm binary path the tool resolved.",
        ),
        menu_item(
            "Doctor",
            "Run basic environment and discovery health checks.",
            "Use this when session state or live inventory looks incomplete or commands are behaving unexpectedly.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without running more context or doctor checks.",
        ),
    ]
}

fn local_helpers_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Invite user to Vaultwarden",
            "Invite a Kanidm user email into Vaultwarden.",
            "Use this onboarding helper to standardize password-vault access for less technical users before they store their Kanidm password, TOTP, and passkey details.",
        ),
        menu_item(
            "Stage Jellyfin password",
            "Write a local Jellyfin password hash file from an environment variable.",
            "Use this machine-local helper when the Jellyfin password hash needs to be staged outside normal Kanidm identity administration.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without running a local helper.",
        ),
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
        body.push_str("\n\nHidden Protected Groups:\n");
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct MembershipReview {
    account_id: String,
    current_visible_groups: Vec<String>,
    selected_visible_groups: Vec<String>,
    preserved_hidden_groups: Vec<String>,
    effective_desired_groups: Vec<String>,
    diff: crate::ops::membership::MembershipDiff,
}

impl MembershipReview {
    fn render(&self) -> String {
        format!(
            "Account ID: {}\n\nCurrent Visible Groups:\n{}\n\nSelected Visible Groups:\n{}\n\nPreserved Hidden Groups:\n{}\n\nGroups To Add:\n{}\n\nGroups To Remove:\n{}\n\nFinal Direct Groups After Apply:\n{}",
            self.account_id,
            render_group_block(&self.current_visible_groups),
            render_group_block(&self.selected_visible_groups),
            render_group_block(&self.preserved_hidden_groups),
            render_group_block(&self.diff.added),
            render_group_block(&self.diff.removed),
            render_group_block(&self.effective_desired_groups),
        )
    }
}

fn build_membership_review(
    account_id: &str,
    current_groups: &[String],
    selected_visible_groups: Vec<String>,
    preserved_hidden_groups: Vec<String>,
) -> MembershipReview {
    let current_visible_groups = normalize_groups(
        current_groups
            .iter()
            .filter(|group| is_operator_visible_group(group))
            .cloned()
            .collect::<Vec<_>>(),
    );
    let selected_visible_groups = normalize_groups(selected_visible_groups);
    let preserved_hidden_groups = normalize_groups(preserved_hidden_groups);
    let effective_desired_groups = normalize_groups(
        [
            selected_visible_groups.clone(),
            preserved_hidden_groups.clone(),
        ]
        .concat(),
    );
    let diff = membership_diff(current_groups, &effective_desired_groups);

    MembershipReview {
        account_id: account_id.to_string(),
        current_visible_groups,
        selected_visible_groups,
        preserved_hidden_groups,
        effective_desired_groups,
        diff,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MembershipChange {
    Add,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MembershipChangeReview {
    account_id: String,
    current_direct_groups: Vec<String>,
    selected_groups: Vec<String>,
    already_present: Vec<String>,
    already_absent: Vec<String>,
    groups_to_add: Vec<String>,
    groups_to_remove: Vec<String>,
}

impl MembershipChangeReview {
    fn is_noop(&self) -> bool {
        self.groups_to_add.is_empty() && self.groups_to_remove.is_empty()
    }

    fn render(&self) -> String {
        format!(
            "Account ID: {}\n\nCurrent Direct Groups:\n{}\n\nSelected Target Groups:\n{}\n\nAlready Present:\n{}\n\nAlready Absent:\n{}\n\nGroups To Add:\n{}\n\nGroups To Remove:\n{}",
            self.account_id,
            render_group_block(&self.current_direct_groups),
            render_group_block(&self.selected_groups),
            render_group_block(&self.already_present),
            render_group_block(&self.already_absent),
            render_group_block(&self.groups_to_add),
            render_group_block(&self.groups_to_remove),
        )
    }
}

fn build_membership_change_review(
    account_id: &str,
    current_groups: &[String],
    selected_groups: Vec<String>,
    mode: MembershipChange,
) -> MembershipChangeReview {
    let current_direct_groups = normalize_groups(current_groups.to_vec());
    let selected_groups = normalize_groups(selected_groups);
    let current_set = current_direct_groups
        .iter()
        .cloned()
        .collect::<std::collections::BTreeSet<_>>();
    let selected_set = selected_groups
        .iter()
        .cloned()
        .collect::<std::collections::BTreeSet<_>>();

    let (already_present, already_absent, groups_to_add, groups_to_remove) = match mode {
        MembershipChange::Add => (
            selected_set
                .intersection(&current_set)
                .cloned()
                .collect::<Vec<_>>(),
            Vec::new(),
            selected_set
                .difference(&current_set)
                .cloned()
                .collect::<Vec<_>>(),
            Vec::new(),
        ),
        MembershipChange::Remove => (
            Vec::new(),
            selected_set
                .difference(&current_set)
                .cloned()
                .collect::<Vec<_>>(),
            Vec::new(),
            selected_set
                .intersection(&current_set)
                .cloned()
                .collect::<Vec<_>>(),
        ),
    };

    MembershipChangeReview {
        account_id: account_id.to_string(),
        current_direct_groups,
        selected_groups,
        already_present,
        already_absent,
        groups_to_add,
        groups_to_remove,
    }
}

fn build_delete_user_review(user: &UserRecord) -> String {
    format!(
        "{}\n\nWarning:\n- This permanently removes the Kanidm person record.\n- Existing direct memberships and downstream app access will be affected.",
        human_operator_user_summary(user)
    )
}

fn build_reset_password_review(user: &UserRecord, ttl_seconds: u64) -> String {
    format!(
        "{}\n\nReset Link TTL: {} seconds\n\nWarning:\n- The resulting reset link or token is sensitive.\n- Share it only through a secure channel.",
        human_operator_user_summary(user),
        ttl_seconds,
    )
}

fn build_vaultwarden_invite_review(
    user: &UserRecord,
    primary_email: &str,
    vaultwarden_status: &VaultwardenUserStatus,
    vaultwarden_url: Option<&str>,
) -> String {
    let planned_actions = build_vaultwarden_invite_actions(vaultwarden_status).join("\n");
    format!(
        "Account ID: {}\nDisplay Name: {}\nPrimary Email: {}\nVaultwarden URL: {}\nVaultwarden Account State: {}\nLegacy SSO Linked: {}\n\nPlanned Actions:\n{}",
        user.account_id,
        user.display_name.as_deref().unwrap_or("-"),
        primary_email,
        vaultwarden_url.unwrap_or("(not resolved)"),
        vaultwarden_status.state_label(),
        if vaultwarden_status.sso_linked {
            "yes"
        } else {
            "no"
        },
        planned_actions,
    )
}

fn build_vaultwarden_invite_actions(vaultwarden_status: &VaultwardenUserStatus) -> Vec<String> {
    let mut actions = Vec::new();
    match vaultwarden_status.state {
        VaultwardenUserState::Missing => actions.push(
            "- Create a pending Vaultwarden signup record through the local admin API.".to_string(),
        ),
        VaultwardenUserState::InvitePending => {
            actions.push("- Refresh the existing pending Vaultwarden signup record.".to_string())
        }
        VaultwardenUserState::Active => {
            actions.push(
                "- Do not create a new signup because the Vaultwarden account is already active."
                    .to_string(),
            );
        }
    }
    actions.push(
        "- User will open the Vaultwarden signup page and register with the exact invited email."
            .to_string(),
    );
    actions
}

fn build_vaultwarden_invite_prompt(
    vaultwarden_status: &VaultwardenUserStatus,
) -> Option<&'static str> {
    match vaultwarden_status.state {
        VaultwardenUserState::Missing => Some("Create the Vaultwarden signup now?"),
        VaultwardenUserState::InvitePending => Some("Refresh the pending Vaultwarden signup now?"),
        VaultwardenUserState::Active => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PolicyChange {
    Set(u64),
    Reset,
}

fn build_policy_review(
    group: &crate::inventory::groups::GroupRecord,
    auth: bool,
    change: PolicyChange,
) -> String {
    let (label, current_value) = if auth {
        ("Auth Expiry Seconds", group.policy.auth_expiry_seconds)
    } else {
        (
            "Privilege Expiry Seconds",
            group.policy.privilege_expiry_seconds,
        )
    };
    let requested = match change {
        PolicyChange::Set(seconds) => seconds.to_string(),
        PolicyChange::Reset => "clear / unset".to_string(),
    };

    format!(
        "Group: {}\nDescription: {}\nCurrent {}: {}\nRequested Change: {}",
        group.name,
        group.description.as_deref().unwrap_or("-"),
        label,
        current_value
            .map(|value| value.to_string())
            .unwrap_or_else(|| "not set".to_string()),
        requested,
    )
}

fn build_redirect_review(
    client: &crate::inventory::clients::ClientRecord,
    url: &str,
    add: bool,
    already_present: bool,
) -> String {
    format!(
        "Client: {}\nDisplay Name: {}\nLanding URL: {}\n\nCurrent Redirect URLs:\n{}\n\nRequested Action: {}\nTarget Redirect URL: {}\nCurrently Present: {}",
        client.name,
        client.display_name.as_deref().unwrap_or("-"),
        client.landing_url.as_deref().unwrap_or("-"),
        render_group_block(&client.redirect_urls),
        if add { "add redirect URL" } else { "remove redirect URL" },
        url,
        if already_present { "yes" } else { "no" },
    )
}

fn block_incomplete_inventory(
    title: &str,
    intro: &str,
    warnings: &[String],
) -> Result<(), AppError> {
    render::print_note(
        title,
        &format!("{intro}\n\nWarnings:\n{}", render_bullets(warnings)),
    );
    forms::pause("Press Enter or Esc to continue")
}

fn require_complete_user_for_action(
    kanidm: &KanidmCli,
    account_id: &str,
    action: &str,
) -> Result<Option<Parsed<UserRecord>>, AppError> {
    let Some(user) = perform_interactive_read(kanidm, || load_user(kanidm, account_id))? else {
        return Ok(None);
    };
    if !user.warnings.is_empty() {
        return Err(AppError::InventoryIncomplete {
            message: format!(
                "refusing to {action} '{}' because the current user record was only partially parsed",
                account_id
            ),
            details: serde_json::json!({
                "account_id": account_id,
                "warnings": user.warnings,
                "next_actions": [
                    "Run `kanidm-admin doctor` to inspect session and inventory health.",
                    format!("Inspect the live user with `kanidm-admin user show {account_id}` once discovery is healthy."),
                ],
            }),
        });
    }
    Ok(Some(user))
}

fn require_complete_group_for_action(
    kanidm: &KanidmCli,
    group: &str,
    action: &str,
) -> Result<Option<Parsed<crate::inventory::groups::GroupRecord>>, AppError> {
    let Some(group_record) = perform_interactive_read(kanidm, || load_group(kanidm, group))? else {
        return Ok(None);
    };
    if !group_record.warnings.is_empty() {
        return Err(AppError::InventoryIncomplete {
            message: format!(
                "refusing to {action} '{group}' because the current group record was only partially parsed"
            ),
            details: serde_json::json!({
                "group": group,
                "warnings": group_record.warnings,
                "next_actions": [
                    "Run `kanidm-admin doctor` to inspect session and inventory health.",
                    format!("Inspect the live group with `kanidm-admin group show {group}` once discovery is healthy."),
                ],
            }),
        });
    }
    Ok(Some(group_record))
}

fn require_complete_client_for_action(
    kanidm: &KanidmCli,
    client: &str,
    action: &str,
) -> Result<Option<Parsed<crate::inventory::clients::ClientRecord>>, AppError> {
    let Some(client_record) = perform_interactive_read(kanidm, || load_client(kanidm, client))?
    else {
        return Ok(None);
    };
    if !client_record.warnings.is_empty() {
        return Err(AppError::InventoryIncomplete {
            message: format!(
                "refusing to {action} '{client}' because the current oauth2 client record was only partially parsed"
            ),
            details: serde_json::json!({
                "client": client,
                "warnings": client_record.warnings,
                "next_actions": [
                    "Run `kanidm-admin doctor` to inspect session and inventory health.",
                    format!("Inspect the live client with `kanidm-admin client show {client}` once discovery is healthy."),
                ],
            }),
        });
    }
    Ok(Some(client_record))
}

fn choose_membership_change_groups(
    _kanidm: &KanidmCli,
    account_id: &str,
    user: &UserRecord,
    groups: &[GroupSummary],
    mode: MembershipChange,
) -> Result<Option<Vec<String>>, AppError> {
    let guided_picker = build_group_picker_inventory(groups, GroupPickerScope::OperatorVisibleOnly);
    let choice_items = vec![
        menu_item(
            "Guided Group Picker",
            "Choose visible groups from the curated picker.",
            guided_picker.intro,
        ),
        menu_item(
            "Manual Entry (Advanced)",
            "Type one or more group names directly.",
            guided_picker.manual_detail,
        ),
        menu_item(
            "Back",
            "Cancel this membership change.",
            "Return without changing memberships.",
        ),
    ];

    let Some(selection) = forms::contextual_select(
        "Choose membership change mode",
        Some(
            "Guided selection is the default safe path for user-facing access groups. Manual entry remains available for advanced cases.",
        ),
        &choice_items,
        0,
    )? else {
        return Ok(None);
    };

    match selection {
        0 => {
            let defaults = groups
                .iter()
                .map(|group| {
                    matches!(mode, MembershipChange::Remove)
                        && user.groups.iter().any(|current| current == &group.name)
                })
                .collect::<Vec<_>>();
            let prompt = if matches!(mode, MembershipChange::Add) {
                format!("Select groups to add to '{account_id}'")
            } else {
                format!("Select groups to remove from '{account_id}'")
            };
            let Some(selected) =
                forms::membership_picker(&prompt, groups, &defaults, &user.groups)?
            else {
                return Ok(None);
            };
            Ok(Some(
                selected
                    .into_iter()
                    .map(|index| groups[index].name.clone())
                    .collect::<Vec<_>>(),
            ))
        }
        1 => {
            let Some(group_text) = prompt_submitted(forms::input_required(
                "Enter one or more group names separated by spaces",
                None,
            )?) else {
                return Ok(None);
            };
            let groups = group_text
                .split_whitespace()
                .map(|group| validate_identifier_field("group name", group))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Some(groups))
        }
        _ => Ok(None),
    }
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

fn build_group_picker_inventory(
    groups: &[GroupSummary],
    scope: GroupPickerScope,
) -> GroupPickerInventory {
    match scope {
        GroupPickerScope::OperatorVisibleOnly => GroupPickerInventory {
            intro: "Choose from the guided access picker. Internal Kanidm groups are intentionally hidden here so the day-to-day access workflow stays focused on user-facing groups.",
            no_matching_groups_prompt:
                "No non-IDM groups were listed. Enter a group name manually",
            manual_prompt: "Enter the group name to manage",
            manual_label: "Enter a group name manually",
            manual_detail: "Use manual entry when the group is hidden from the guided access picker or you already know the exact group name.",
            groups: groups
                .iter()
                .filter(|group| is_operator_visible_group(&group.name))
                .cloned()
                .collect(),
        },
        GroupPickerScope::AllGroups => GroupPickerInventory {
            intro: "Choose from all live groups, including internal Kanidm groups. This advanced workflow is intended for deeper inspection and configuration work.",
            no_matching_groups_prompt: "No live groups were listed. Enter a group name manually",
            manual_prompt: "Enter the group name to manage",
            manual_label: "Enter a group name manually",
            manual_detail: "Use manual entry when the group is missing from live discovery or you already know the exact group name.",
            groups: groups.to_vec(),
        },
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
                "Manage SFTP SSH Keys",
                "Help User Reset Password",
                "Advanced",
                "Exit",
            ]
        );
    }

    #[test]
    fn ssh_key_menu_explains_public_key_handoff() {
        let items = ssh_key_menu_items();
        let add = items
            .iter()
            .find(|item| item.label == "Add SSH Key")
            .expect("add ssh key item");

        assert!(add.detail.contains("single-line public key"));
        assert!(add.detail.contains("ssh-ed25519"));
        assert!(add.detail.contains("Never paste a private key"));
    }

    #[test]
    fn ssh_key_upload_note_spells_out_user_and_operator_steps() {
        let note = build_ssh_key_upload_note(&UserRecord {
            account_id: "alice".to_string(),
            display_name: Some("Alice".to_string()),
            primary_email: None,
            spn: None,
            uuid: None,
            valid_from: None,
            expiry: None,
            groups: vec!["users".to_string()],
        });

        assert!(note.contains("ssh-keygen -t ed25519"));
        assert!(note.contains("~/.ssh/id_ed25519.pub"));
        assert!(note.contains("complete one-line .pub contents"));
        assert!(note.contains("user-files: missing"));
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
            vec![
                "users".to_string(),
                "shared-files-read-write-access".to_string(),
            ],
            vec!["idm_all_persons".to_string()],
        );

        assert_eq!(
            review.current_visible_groups,
            vec!["paperless-users".to_string(), "users".to_string()]
        );
        assert_eq!(
            review.selected_visible_groups,
            vec![
                "shared-files-read-write-access".to_string(),
                "users".to_string()
            ]
        );
        assert_eq!(
            review.preserved_hidden_groups,
            vec!["idm_all_persons".to_string()]
        );
        assert_eq!(
            review.effective_desired_groups,
            vec![
                "idm_all_persons".to_string(),
                "shared-files-read-write-access".to_string(),
                "users".to_string()
            ]
        );
        assert_eq!(
            review.diff.added,
            vec!["shared-files-read-write-access".to_string()]
        );
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
            vec![
                "paperless-users".to_string(),
                "shared-files-read-write-access".to_string(),
            ],
            MembershipChange::Add,
        );

        assert_eq!(review.already_present, vec!["paperless-users".to_string()]);
        assert_eq!(
            review.groups_to_add,
            vec!["shared-files-read-write-access".to_string()]
        );
        assert!(review.groups_to_remove.is_empty());
    }

    #[test]
    fn membership_change_review_remove_computes_actual_changes() {
        let review = build_membership_change_review(
            "dsaw",
            &["users".to_string(), "paperless-users".to_string()],
            vec![
                "paperless-users".to_string(),
                "shared-files-read-write-access".to_string(),
            ],
            MembershipChange::Remove,
        );

        assert_eq!(
            review.already_absent,
            vec!["shared-files-read-write-access".to_string()]
        );
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
