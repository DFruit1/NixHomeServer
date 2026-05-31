use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultwardenUserState {
    Missing,
    InvitePending,
    Active,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultwardenUserStatus {
    pub state: VaultwardenUserState,
    pub user_uuid: Option<String>,
    pub sso_linked: bool,
}

impl VaultwardenUserStatus {
    pub fn state_label(&self) -> &'static str {
        match self.state {
            VaultwardenUserState::Missing => "not present",
            VaultwardenUserState::InvitePending => "invite pending",
            VaultwardenUserState::Active => "active",
        }
    }

    pub(super) fn to_value(&self) -> serde_json::Value {
        json!({
            "state": self.state_label(),
            "user_uuid": self.user_uuid,
            "sso_linked": self.sso_linked,
        })
    }
}

pub fn invite_vaultwarden_user(
    context: &ResolvedContext,
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    invite_vaultwarden_user_with(
        context,
        account_id,
        |account_id| load_user(cli, account_id),
        |path| read_secret_with_sudo_fallback(cli, path),
        fetch_vaultwarden_user_status,
        post_vaultwarden_invite,
        post_vaultwarden_resend_invite,
    )
}

pub fn lookup_vaultwarden_user(
    context: &ResolvedContext,
    primary_email: &str,
) -> Result<VaultwardenUserStatus, AppError> {
    let vaultwarden_url = context
        .vaultwarden_url
        .as_deref()
        .ok_or_else(|| AppError::Config {
            message: "Vaultwarden URL is not configured in kanidm-admin context".to_string(),
        })?;
    let admin_token_path = context
        .vaultwarden_admin_token_file
        .as_deref()
        .ok_or_else(|| AppError::Config {
            message: "Vaultwarden admin token file is not configured in kanidm-admin context"
                .to_string(),
        })?;
    let admin_token = read_secret_with_sudo_fallback_unlogged(admin_token_path)?;
    fetch_vaultwarden_user_status(vaultwarden_url, &admin_token, primary_email)
}

pub fn diagnose_vaultwarden_user(
    context: &ResolvedContext,
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let runtime = vaultwarden_runtime_report(context, cli, account_id)?;
    Ok(vaultwarden_runtime_output(account_id, runtime, "diagnosed"))
}

pub fn reconcile_vaultwarden_user(
    context: &ResolvedContext,
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let invite = invite_vaultwarden_user(context, cli, account_id)?;
    let runtime = vaultwarden_runtime_report(context, cli, account_id)?;
    if !runtime.ready {
        return Err(AppError::Verification {
            message: format!("Vaultwarden runtime did not converge for '{account_id}'"),
            details: json!({
                "runtime": runtime,
                "invite": invite.details,
            }),
        });
    }
    let mut output = vaultwarden_runtime_output(account_id, runtime, "reconciled");
    output.details["invite"] = invite.details;
    output.warnings.extend(invite.warnings);
    Ok(output)
}
