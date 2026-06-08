use crate::{
    inventory::{
        clients::ClientRecord,
        groups::{is_operator_visible_group, resolve_group_help, GroupRecord, GroupSummary},
        users::UserRecord,
        Parsed,
    },
    kanidm_cli::KanidmCli,
    ops::{
        client::load_client,
        group::load_group,
        local::{VaultwardenUserState, VaultwardenUserStatus},
        membership::{membership_diff, normalize_groups},
        user::load_user,
    },
    AppError,
};

use super::{forms, perform_interactive_read, render, render_bullets};

pub(super) fn is_user_enabled(user: &UserRecord) -> bool {
    user.valid_from.is_none() && user.expiry.is_none()
}

pub(super) fn human_operator_user_summary(user: &UserRecord) -> String {
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

pub(super) fn render_group_block(groups: &[String]) -> String {
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

pub(super) fn missing_visible_membership_inventory(
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

pub(super) fn preserved_hidden_memberships<'a>(
    current_groups: &'a [String],
) -> impl Iterator<Item = String> + 'a {
    current_groups
        .iter()
        .filter(|group| !is_operator_visible_group(group))
        .cloned()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MembershipReview {
    pub(super) account_id: String,
    pub(super) current_visible_groups: Vec<String>,
    pub(super) selected_visible_groups: Vec<String>,
    pub(super) preserved_hidden_groups: Vec<String>,
    pub(super) effective_desired_groups: Vec<String>,
    pub(super) diff: crate::ops::membership::MembershipDiff,
}

impl MembershipReview {
    pub(super) fn render(&self) -> String {
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

pub(super) fn build_membership_review(
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
pub(super) enum MembershipChange {
    Add,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MembershipChangeReview {
    pub(super) account_id: String,
    pub(super) current_direct_groups: Vec<String>,
    pub(super) selected_groups: Vec<String>,
    pub(super) already_present: Vec<String>,
    pub(super) already_absent: Vec<String>,
    pub(super) groups_to_add: Vec<String>,
    pub(super) groups_to_remove: Vec<String>,
}

impl MembershipChangeReview {
    pub(super) fn is_noop(&self) -> bool {
        self.groups_to_add.is_empty() && self.groups_to_remove.is_empty()
    }

    pub(super) fn render(&self) -> String {
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

pub(super) fn build_membership_change_review(
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

pub(super) fn build_delete_user_review(user: &UserRecord) -> String {
    format!(
        "{}\n\nWarning:\n- This permanently removes the Kanidm person record.\n- Existing direct memberships and downstream app access will be affected.",
        human_operator_user_summary(user)
    )
}

pub(super) fn build_reset_password_review(user: &UserRecord, ttl_seconds: u64) -> String {
    format!(
        "{}\n\nReset Link TTL: {} seconds\n\nWarning:\n- The resulting reset link or token is sensitive.\n- Share it only through a secure channel.",
        human_operator_user_summary(user),
        ttl_seconds,
    )
}

pub(super) fn build_vaultwarden_invite_review(
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

pub(super) fn build_vaultwarden_invite_actions(
    vaultwarden_status: &VaultwardenUserStatus,
) -> Vec<String> {
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

pub(super) fn build_vaultwarden_invite_prompt(
    vaultwarden_status: &VaultwardenUserStatus,
) -> Option<&'static str> {
    match vaultwarden_status.state {
        VaultwardenUserState::Missing => Some("Create the Vaultwarden signup now?"),
        VaultwardenUserState::InvitePending => Some("Refresh the pending Vaultwarden signup now?"),
        VaultwardenUserState::Active => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PolicyChange {
    Set(u64),
    Reset,
}

pub(super) fn build_policy_review(group: &GroupRecord, auth: bool, change: PolicyChange) -> String {
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

pub(super) fn build_redirect_review(
    client: &ClientRecord,
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

pub(super) fn block_incomplete_inventory(
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

pub(super) fn require_complete_user_for_action(
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

pub(super) fn require_complete_group_for_action(
    kanidm: &KanidmCli,
    group: &str,
    action: &str,
) -> Result<Option<Parsed<GroupRecord>>, AppError> {
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

pub(super) fn require_complete_client_for_action(
    kanidm: &KanidmCli,
    client: &str,
    action: &str,
) -> Result<Option<Parsed<ClientRecord>>, AppError> {
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
