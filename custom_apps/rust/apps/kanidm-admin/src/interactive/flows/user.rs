use super::super::*;

pub(in crate::interactive) fn create_user_flow(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
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
            render_error_with_backend_summary(kanidm, &error);
            if matches!(error, AppError::PartialSuccess { .. })
                && partial_success_has_observed_user(&error, &account_id)
            {
                match forms::confirm("Continue to access setup for this existing user?", false)? {
                    Some(true) => {
                        return super::membership::edit_membership_for_account(
                            context,
                            kanidm,
                            &account_id,
                        )
                    }
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
    super::membership::edit_membership_for_account(context, kanidm, &account_id)
}

pub(in crate::interactive) fn delete_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
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

pub(in crate::interactive) fn help_user_reset_password_flow(
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
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

pub(in crate::interactive) fn set_posix_password_flow(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(
        kanidm,
        "Select a user who needs a POSIX/SFTP password set or reset",
    )?
    else {
        return Ok(());
    };
    let Some(user) =
        require_complete_user_for_action(kanidm, &account_id, "set a POSIX/SFTP password for")?
    else {
        return Ok(());
    };
    render::print_note(
        "Review POSIX Password",
        &build_posix_password_review(&user.value),
    );
    match forms::confirm("Set the POSIX/UNIX password now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    render::print_note(
        "POSIX Password Prompt",
        "Enter the new POSIX/UNIX password next.\nThis is separate from the user's web/OIDC password and passkeys.\nAfter Kanidm accepts it, the tool may ask for the same password again to verify UnixD/PAM readiness.",
    );
    let Some(password) = prompt_submitted(forms::password_confirmed("New POSIX/UNIX password")?)
    else {
        return Ok(());
    };
    run_privileged_command("Set POSIX Password", kanidm, || {
        set_posix_password_with_config(
            kanidm,
            &context.sftp_runtime,
            PosixPasswordOptions {
                account_id: account_id.clone(),
                password: password.clone(),
                run_auth_test: true,
            },
        )
    })
}

pub(in crate::interactive) fn manage_user_access_flow(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to manage access for")? else {
        return Ok(());
    };
    super::membership::edit_membership_for_account(context, kanidm, &account_id)
}

pub(in crate::interactive) fn find_view_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user to view")? else {
        return Ok(());
    };
    let Some(user) = perform_interactive_read(kanidm, || load_user(kanidm, &account_id))? else {
        return Ok(());
    };
    render::print_output("User Summary", &human_operator_user_summary(&user.value));
    forms::pause("Press Enter or Esc to continue")
}

pub(in crate::interactive) fn disable_enable_user_flow(kanidm: &KanidmCli) -> Result<(), AppError> {
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
