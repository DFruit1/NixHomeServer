use crate::{context::ResolvedContext, kanidm_cli::KanidmCli, AppError};

use super::{
    advanced_menu, create_user_flow, disable_enable_user_flow, find_view_user_flow, forms,
    help_user_reset_password_flow,
    home::{load_home, HomeCache, HomeSummary},
    manage_user_access_flow, manage_user_ssh_keys_flow, recover_target_interactively_with_snapshot,
    render_bullets, simple_menu_items,
};
use crate::ops::executor::RecoveryTarget;
use crate::session_state::should_prompt_for_startup_login;

pub(super) enum SimpleMenuAction {
    CreateUser,
    ManageUserAccess,
    FindViewUser,
    DisableEnableUser,
    ManageUserSshKeys,
    HelpUserResetPassword,
    Advanced,
    Exit,
}

pub fn run(context: &ResolvedContext, kanidm: &KanidmCli) -> Result<(), AppError> {
    let mut home_cache = HomeCache::default();
    if let Ok(snapshot) = kanidm.session_snapshot() {
        if should_prompt_for_startup_login(&snapshot) {
            let _ = recover_target_interactively_with_snapshot(
                kanidm,
                RecoveryTarget::BaseSession,
                None,
                Some(&snapshot),
            )?;
        }
    }
    loop {
        let home = load_home(kanidm, &mut home_cache);
        let action = select_main_menu(context, &home)?;
        match action {
            SimpleMenuAction::CreateUser => create_user_flow(kanidm)?,
            SimpleMenuAction::ManageUserAccess => manage_user_access_flow(kanidm)?,
            SimpleMenuAction::FindViewUser => find_view_user_flow(kanidm)?,
            SimpleMenuAction::DisableEnableUser => disable_enable_user_flow(kanidm)?,
            SimpleMenuAction::ManageUserSshKeys => manage_user_ssh_keys_flow(kanidm)?,
            SimpleMenuAction::HelpUserResetPassword => help_user_reset_password_flow(kanidm)?,
            SimpleMenuAction::Advanced => advanced_menu(context, kanidm)?,
            SimpleMenuAction::Exit => break,
        }
    }

    Ok(())
}

fn select_main_menu(
    context: &ResolvedContext,
    home: &HomeSummary,
) -> Result<SimpleMenuAction, AppError> {
    let mut intro = home.render(&context.server_url, &context.admin_name);
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
        4 => SimpleMenuAction::ManageUserSshKeys,
        5 => SimpleMenuAction::HelpUserResetPassword,
        6 => SimpleMenuAction::Advanced,
        _ => SimpleMenuAction::Exit,
    })
}
