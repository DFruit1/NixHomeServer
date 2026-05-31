use super::super::*;

pub(in crate::interactive) fn local_helpers_menu(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
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
