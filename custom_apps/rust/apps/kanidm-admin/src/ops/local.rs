use std::{
    env,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use pbkdf2::pbkdf2_hmac;
use rand::{rngs::OsRng, RngCore};
use reqwest::blocking::Client;
use serde_json::json;
use sha2::Sha512;

use crate::{
    context::ResolvedContext,
    inventory::{users::UserRecord, Parsed},
    kanidm_cli::KanidmCli,
    ops::{
        local_runtime::{
            execute_local_command, root_action_spec, run_local_command, run_root_action,
            CheckStatus, LocalCommandSpec, RootAction, RuntimeCheckReport, RuntimeReport,
        },
        user::load_user,
    },
    output::CommandOutput,
    validation::validate_account_id,
    AppError,
};

const DEFAULT_PASSWORD_HASH_DIR: &str = "/var/lib/jellyfin/.nixos-managed/desired-password-hashes";
const PASSWORD_HASH_DIR_ENV: &str = "KANIDM_ADMIN_JELLYFIN_PASSWORD_HASH_DIR";
const JELLYFIN_RECONCILE_SERVICE: &str = "jellyfin-password-reconcile.service";
const JELLYFIN_SERVICE: &str = "jellyfin.service";
const PBKDF2_ITERATIONS: u32 = 210_000;
const VAULTWARDEN_ADMIN_COOKIE: &str = "VW_ADMIN";

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

    fn to_value(&self) -> serde_json::Value {
        json!({
            "state": self.state_label(),
            "user_uuid": self.user_uuid,
            "sso_linked": self.sso_linked,
        })
    }
}

pub fn stage_jellyfin_password(
    account_id: &str,
    password_env: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;

    let password = env::var(password_env).map_err(|_| AppError::Config {
        message: format!("environment variable '{password_env}' is required"),
    })?;
    if password.is_empty() {
        return Err(AppError::Config {
            message: format!("environment variable '{password_env}' must not be empty"),
        });
    }

    let directory = env::var_os(PASSWORD_HASH_DIR_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_PASSWORD_HASH_DIR));
    let path = directory.join(format!("{account_id}.pbkdf2"));

    write_password_hash_atomic(&directory, &path, &hash_password(&password))?;

    Ok(CommandOutput {
        message: format!("staged desired Jellyfin password hash for '{account_id}'"),
        human: format!(
            "Staged the desired Jellyfin password hash for '{account_id}'.\nPath: {}\nSource env var: {password_env}\nThe Jellyfin reconcile service still needs to apply this staged hash.",
            path.display()
        ),
        details: json!({
            "account_id": account_id,
            "path": path,
            "password_env": password_env,
            "staged": true,
            "runtime": jellyfin_password_runtime_report(None, &account_id),
        }),
        warnings: vec![
            "The Jellyfin reconcile timer or service must still converge before the password change is active.".to_string(),
        ],
    })
}

pub fn diagnose_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let runtime = jellyfin_password_runtime_report(Some(cli), &account_id);
    Ok(jellyfin_password_output(&account_id, runtime, "diagnosed"))
}

pub fn reconcile_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let start = run_root_action(
        cli,
        "local jellyfin password reconcile",
        RootAction::StartSystemdUnit {
            unit: JELLYFIN_RECONCILE_SERVICE.to_string(),
        },
        None,
        Duration::from_secs(20),
    );
    let mut runtime = jellyfin_password_runtime_report(Some(cli), &account_id);
    runtime.checks.insert(
        0,
        RuntimeCheckReport {
            id: "jellyfin.password_reconcile.started".to_string(),
            label: "Jellyfin password reconcile service was started".to_string(),
            required: true,
            status: if start
                .result
                .allowed_success(&std::collections::BTreeSet::from([0]))
            {
                CheckStatus::Passed
            } else {
                runtime.ready = false;
                CheckStatus::Failed
            },
            command: start
                .backend_payload
                .get("args")
                .and_then(serde_json::Value::as_array)
                .map(|args| {
                    format!(
                        "sudo {}",
                        args.iter()
                            .filter_map(serde_json::Value::as_str)
                            .collect::<Vec<_>>()
                            .join(" ")
                    )
                }),
            summary: start.result.detail(),
            detail: None,
            probe: Some(start.backend_payload),
        },
    );
    runtime.ready = runtime.required_checks_passed();
    if !runtime.ready {
        return Err(AppError::Verification {
            message: format!("Jellyfin password runtime did not converge for '{account_id}'"),
            details: json!({ "runtime": runtime }),
        });
    }
    Ok(jellyfin_password_output(&account_id, runtime, "reconciled"))
}

pub fn test_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    diagnose_jellyfin_password(cli, account_id)
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

#[allow(clippy::too_many_arguments)]
fn invite_vaultwarden_user_with<LoadUser, ReadToken, LookupStatus, SendInvite, ResendInvite>(
    context: &ResolvedContext,
    account_id: &str,
    load_user: LoadUser,
    read_token: ReadToken,
    lookup_status: LookupStatus,
    send_invite: SendInvite,
    resend_invite: ResendInvite,
) -> Result<CommandOutput, AppError>
where
    LoadUser: Fn(&str) -> Result<Parsed<UserRecord>, AppError>,
    ReadToken: Fn(&Path) -> Result<String, AppError>,
    LookupStatus: Fn(&str, &str, &str) -> Result<VaultwardenUserStatus, AppError>,
    SendInvite: Fn(&str, &str, &str) -> Result<(), AppError>,
    ResendInvite: Fn(&str, &str, &str) -> Result<(), AppError>,
{
    let account_id = validate_account_id(account_id)?;
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

    let user = load_user(&account_id)?;
    let primary_email = user
        .value
        .primary_email
        .clone()
        .ok_or_else(|| AppError::Config {
            message: format!(
                "cannot invite '{}' into Vaultwarden because the Kanidm user does not have a primary email",
                account_id
            ),
        })?;
    let admin_token = read_token(admin_token_path)?;
    let vaultwarden_status = lookup_status(vaultwarden_url, &admin_token, &primary_email)?;

    let mut warnings = user.warnings.clone();

    let invite_result = match vaultwarden_status.state {
        VaultwardenUserState::Missing => send_invite(vaultwarden_url, &admin_token, &primary_email)
            .map(|_| {
                (
                    "created_manual_signup",
                    true,
                    "created a pending Vaultwarden signup record for manual activation",
                )
            }),
        VaultwardenUserState::InvitePending => {
            let user_uuid =
                vaultwarden_status
                    .user_uuid
                    .as_deref()
                    .ok_or_else(|| AppError::Json {
                        message: format!(
                            "Vaultwarden reported a pending signup for '{}' without a user id",
                            primary_email
                        ),
                        details: json!({
                            "primary_email": primary_email,
                            "vaultwarden_status": vaultwarden_status.to_value(),
                        }),
                    })?;
            resend_invite(vaultwarden_url, &admin_token, user_uuid).map(|_| {
                (
                    "refreshed_manual_signup",
                    true,
                    "refreshed the existing pending Vaultwarden signup record",
                )
            })
        }
        VaultwardenUserState::Active => Ok((
            "skipped_active",
            false,
            "detected an already active Vaultwarden account and skipped a new invite",
        )),
    };

    let (invite_action, invite_sent, invite_summary) = invite_result?;
    let manual_signup_url = format!("{}/#/signup", vaultwarden_url.trim_end_matches('/'));

    warnings.sort();
    warnings.dedup();

    Ok(CommandOutput {
        message: match vaultwarden_status.state {
            VaultwardenUserState::Active => {
                format!("Vaultwarden access already active for '{}'", account_id)
            }
            VaultwardenUserState::InvitePending => {
                format!("refreshed the pending Vaultwarden signup for '{}'", account_id)
            }
            VaultwardenUserState::Missing => format!("invited '{}' into Vaultwarden", account_id),
        },
        human: format!(
            "Account ID: {}\nPrimary Email: {}\nVaultwarden URL: {}\nManual Signup URL: {}/#/signup\nVaultwarden Account State: {}\nLegacy SSO Linked: {}\nAction Taken: {}\nManual Signup Ready: {}",
            account_id,
            primary_email,
            vaultwarden_url,
            vaultwarden_url.trim_end_matches('/'),
            vaultwarden_status.state_label(),
            if vaultwarden_status.sso_linked { "yes" } else { "no" },
            invite_summary,
            if invite_sent { "yes" } else { "no" },
        ),
        details: json!({
            "account_id": account_id,
            "primary_email": primary_email,
            "vaultwarden_url": vaultwarden_url,
            "vaultwarden_admin_token_file": admin_token_path.display().to_string(),
            "vaultwarden_status": vaultwarden_status.to_value(),
            "invite_action": invite_action,
            "invite_sent": invite_sent,
            "manual_signup_url": manual_signup_url,
            "manual_signup_ready": invite_sent,
        }),
        warnings,
    })
}

fn read_secret_with_sudo_fallback(cli: &KanidmCli, path: &Path) -> Result<String, AppError> {
    match fs::read_to_string(path) {
        Ok(contents) => normalize_secret_value(path, contents),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            read_secret_via_sudo(cli, path)
        }
        Err(error) => Err(AppError::Io {
            message: format!("failed to read secret file '{}': {error}", path.display()),
        }),
    }
}

fn read_secret_via_sudo(cli: &KanidmCli, path: &Path) -> Result<String, AppError> {
    let execution = run_root_action(
        cli,
        "local sudo read secret file",
        RootAction::ReadSecretFile {
            path: path.to_path_buf(),
        },
        None,
        Duration::from_secs(20),
    );

    if !execution
        .result
        .allowed_success(&std::collections::BTreeSet::from([0]))
    {
        return Err(AppError::Io {
            message: format!(
                "failed to read secret file '{}' via sudo fallback: {}",
                path.display(),
                execution.result.detail()
            ),
        });
    }

    normalize_secret_value(path, execution.result.stdout)
}

fn read_secret_with_sudo_fallback_unlogged(path: &Path) -> Result<String, AppError> {
    match fs::read_to_string(path) {
        Ok(contents) => normalize_secret_value(path, contents),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            let spec = root_action_spec(
                RootAction::ReadSecretFile {
                    path: path.to_path_buf(),
                },
                None,
                Duration::from_secs(20),
            );
            let result = execute_local_command(&spec);
            if !result.allowed_success(&std::collections::BTreeSet::from([0])) {
                return Err(AppError::Io {
                    message: format!(
                        "failed to read secret file '{}' via sudo fallback: {}",
                        path.display(),
                        result.detail()
                    ),
                });
            }
            normalize_secret_value(path, result.stdout)
        }
        Err(error) => Err(AppError::Io {
            message: format!("failed to read secret file '{}': {error}", path.display()),
        }),
    }
}

fn normalize_secret_value(path: &Path, contents: String) -> Result<String, AppError> {
    let trimmed = contents.trim().to_string();
    if trimmed.is_empty() {
        return Err(AppError::Config {
            message: format!("secret file '{}' is empty", path.display()),
        });
    }
    Ok(trimmed)
}

fn jellyfin_password_runtime_report(cli: Option<&KanidmCli>, account_id: &str) -> RuntimeReport {
    let started = Instant::now();
    let directory = env::var_os(PASSWORD_HASH_DIR_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_PASSWORD_HASH_DIR));
    let path = directory.join(format!("{account_id}.pbkdf2"));
    let mut checks = Vec::new();

    let metadata = fs::symlink_metadata(&path);
    checks.push(match &metadata {
        Ok(metadata) if metadata.file_type().is_file() => runtime_check(
            "jellyfin.password_stage.pending",
            "Staged Jellyfin password hash exists",
            true,
            CheckStatus::Passed,
            format!("found {}", path.display()),
        ),
        Ok(_) => runtime_check(
            "jellyfin.password_stage.pending",
            "Staged Jellyfin password hash exists",
            true,
            CheckStatus::Failed,
            format!("{} is not a regular file", path.display()),
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => runtime_check(
            "jellyfin.password_stage.pending",
            "Staged Jellyfin password hash exists",
            true,
            CheckStatus::Failed,
            format!("{} is missing", path.display()),
        ),
        Err(error) => runtime_check(
            "jellyfin.password_stage.pending",
            "Staged Jellyfin password hash exists",
            true,
            CheckStatus::Unknown,
            format!("failed to inspect {}: {error}", path.display()),
        ),
    });

    checks.push(match metadata {
        Ok(metadata) => {
            let mode = metadata.permissions().mode() & 0o777;
            if mode == 0o600 {
                runtime_check(
                    "jellyfin.secret_file.permissions",
                    "Staged Jellyfin hash permissions are 0600",
                    true,
                    CheckStatus::Passed,
                    "mode 0600".to_string(),
                )
            } else {
                runtime_check(
                    "jellyfin.secret_file.permissions",
                    "Staged Jellyfin hash permissions are 0600",
                    true,
                    CheckStatus::Failed,
                    format!("mode {mode:o}"),
                )
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => runtime_check(
            "jellyfin.secret_file.permissions",
            "Staged Jellyfin hash permissions are 0600",
            true,
            CheckStatus::Failed,
            "staged file is missing".to_string(),
        ),
        Err(error) => runtime_check(
            "jellyfin.secret_file.permissions",
            "Staged Jellyfin hash permissions are 0600",
            true,
            CheckStatus::Unknown,
            format!("failed to inspect permissions: {error}"),
        ),
    });

    checks.push(match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() => {
            runtime_check(
                "jellyfin.secret_file.exists",
                "Jellyfin staged password directory is safe",
                true,
                CheckStatus::Passed,
                format!("directory {}", directory.display()),
            )
        }
        Ok(_) => runtime_check(
            "jellyfin.secret_file.exists",
            "Jellyfin staged password directory is safe",
            true,
            CheckStatus::Failed,
            format!("{} is not a plain directory", directory.display()),
        ),
        Err(error) => runtime_check(
            "jellyfin.secret_file.exists",
            "Jellyfin staged password directory is safe",
            true,
            CheckStatus::Failed,
            format!("failed to inspect {}: {error}", directory.display()),
        ),
    });

    if let Some(cli) = cli {
        checks.push(systemd_active_runtime_check(
            cli,
            "jellyfin.service.active",
            "Jellyfin service is active",
            JELLYFIN_SERVICE,
            true,
        ));
        checks.push(systemd_active_runtime_check(
            cli,
            "jellyfin.password_stage.applied",
            "Jellyfin password reconcile service is not failed",
            JELLYFIN_RECONCILE_SERVICE,
            false,
        ));
    } else {
        checks.push(runtime_check(
            "jellyfin.service.active",
            "Jellyfin service is active",
            false,
            CheckStatus::Skipped,
            "not checked by stage command".to_string(),
        ));
    }

    let ready = checks
        .iter()
        .all(|check| !check.required || check.status == CheckStatus::Passed);
    RuntimeReport {
        target: "jellyfin_password".to_string(),
        subject: account_id.to_string(),
        ready,
        attempts: 1,
        elapsed_ms: started.elapsed().as_millis(),
        checks,
    }
}

fn jellyfin_password_output(account_id: &str, runtime: RuntimeReport, verb: &str) -> CommandOutput {
    let ready = runtime.ready;
    let verification = runtime.verification_summary();
    CommandOutput {
        message: format!("Jellyfin password runtime {verb} for '{account_id}'"),
        human: format!(
            "Account ID: {account_id}\nJellyfin password runtime ready: {}",
            if ready { "yes" } else { "no" }
        ),
        details: json!({
            "account_id": account_id,
            "verification": verification,
            "runtime": runtime,
        }),
        warnings: if ready {
            Vec::new()
        } else {
            vec!["Jellyfin password runtime is not ready; inspect runtime.checks for the failing prerequisite.".to_string()]
        },
    }
}

fn vaultwarden_runtime_report(
    context: &ResolvedContext,
    cli: &KanidmCli,
    account_id: &str,
) -> Result<RuntimeReport, AppError> {
    let started = Instant::now();
    let account_id = validate_account_id(account_id)?;
    let mut checks = Vec::new();

    let user = load_user(cli, &account_id)?;
    let primary_email = user.value.primary_email.clone();
    checks.push(if let Some(email) = &primary_email {
        runtime_check(
            "vaultwarden.kanidm.primary_email",
            "Kanidm user has a primary email",
            true,
            CheckStatus::Passed,
            email.clone(),
        )
    } else {
        runtime_check(
            "vaultwarden.kanidm.primary_email",
            "Kanidm user has a primary email",
            true,
            CheckStatus::Failed,
            "primary email is missing".to_string(),
        )
    });

    let vaultwarden_url = context.vaultwarden_url.as_deref();
    checks.push(if let Some(url) = vaultwarden_url {
        runtime_check(
            "vaultwarden.url.configured",
            "Vaultwarden URL is configured",
            true,
            CheckStatus::Passed,
            url.to_string(),
        )
    } else {
        runtime_check(
            "vaultwarden.url.configured",
            "Vaultwarden URL is configured",
            true,
            CheckStatus::Failed,
            "Vaultwarden URL is not configured".to_string(),
        )
    });

    let admin_token_path = context.vaultwarden_admin_token_file.as_deref();
    checks.push(if let Some(path) = admin_token_path {
        runtime_check(
            "vaultwarden.admin_token.path_configured",
            "Vaultwarden admin token path is configured",
            true,
            CheckStatus::Passed,
            path.display().to_string(),
        )
    } else {
        runtime_check(
            "vaultwarden.admin_token.path_configured",
            "Vaultwarden admin token path is configured",
            true,
            CheckStatus::Failed,
            "Vaultwarden admin token path is not configured".to_string(),
        )
    });

    let mut status_value = serde_json::Value::Null;
    if let (Some(url), Some(path), Some(email)) = (vaultwarden_url, admin_token_path, primary_email)
    {
        match read_secret_with_sudo_fallback(cli, path)
            .and_then(|token| fetch_vaultwarden_user_status(url, &token, &email))
        {
            Ok(status) => {
                status_value = status.to_value();
                checks.push(runtime_check(
                    "vaultwarden.admin_login.succeeds",
                    "Vaultwarden admin login and user lookup succeeds",
                    true,
                    CheckStatus::Passed,
                    format!("user state: {}", status.state_label()),
                ));
            }
            Err(error) => checks.push(runtime_check(
                "vaultwarden.admin_login.succeeds",
                "Vaultwarden admin login and user lookup succeeds",
                true,
                CheckStatus::Failed,
                error.human_message(),
            )),
        }
    } else {
        checks.push(runtime_check(
            "vaultwarden.admin_login.succeeds",
            "Vaultwarden admin login and user lookup succeeds",
            true,
            CheckStatus::Skipped,
            "required Vaultwarden context is incomplete".to_string(),
        ));
    }

    let ready = checks
        .iter()
        .all(|check| !check.required || check.status == CheckStatus::Passed);
    let mut report = RuntimeReport {
        target: "vaultwarden".to_string(),
        subject: account_id,
        ready,
        attempts: 1,
        elapsed_ms: started.elapsed().as_millis(),
        checks,
    };
    if status_value != serde_json::Value::Null {
        report.checks.push(RuntimeCheckReport {
            id: "vaultwarden.user.state".to_string(),
            label: "Vaultwarden user state".to_string(),
            required: false,
            status: CheckStatus::Passed,
            command: None,
            summary: status_value["state"]
                .as_str()
                .unwrap_or("unknown")
                .to_string(),
            detail: None,
            probe: Some(status_value),
        });
    }
    Ok(report)
}

fn vaultwarden_runtime_output(
    account_id: &str,
    runtime: RuntimeReport,
    verb: &str,
) -> CommandOutput {
    let ready = runtime.ready;
    let verification = runtime.verification_summary();
    CommandOutput {
        message: format!("Vaultwarden runtime {verb} for '{account_id}'"),
        human: format!(
            "Account ID: {account_id}\nVaultwarden runtime ready: {}",
            if ready { "yes" } else { "no" }
        ),
        details: json!({
            "account_id": account_id,
            "verification": verification,
            "runtime": runtime,
        }),
        warnings: if ready {
            Vec::new()
        } else {
            vec!["Vaultwarden runtime is not ready; inspect runtime.checks for the failing prerequisite.".to_string()]
        },
    }
}

fn systemd_active_runtime_check(
    cli: &KanidmCli,
    id: &'static str,
    label: &str,
    service: &str,
    required: bool,
) -> RuntimeCheckReport {
    let spec = LocalCommandSpec::new("systemctl", ["is-active".to_string(), service.to_string()]);
    let command = spec.display_command().display_string();
    let execution = run_local_command(cli, &format!("local systemctl is-active {service}"), spec);
    let success = execution
        .result
        .allowed_success(&std::collections::BTreeSet::from([0]));
    RuntimeCheckReport {
        id: id.to_string(),
        label: label.to_string(),
        required,
        status: if success {
            CheckStatus::Passed
        } else if required {
            CheckStatus::Failed
        } else {
            CheckStatus::Unknown
        },
        command: Some(command),
        summary: execution.result.detail(),
        detail: None,
        probe: Some(execution.backend_payload),
    }
}

fn runtime_check(
    id: &'static str,
    label: &str,
    required: bool,
    status: CheckStatus,
    summary: String,
) -> RuntimeCheckReport {
    RuntimeCheckReport {
        id: id.to_string(),
        label: label.to_string(),
        required,
        status,
        command: None,
        summary,
        detail: None,
        probe: None,
    }
}

fn fetch_vaultwarden_user_status(
    vaultwarden_url: &str,
    admin_token: &str,
    primary_email: &str,
) -> Result<VaultwardenUserStatus, AppError> {
    let session = login_vaultwarden_admin(vaultwarden_url, admin_token)?;
    let overview_html = session.get_text("/admin/users/overview")?;
    Ok(
        parse_vaultwarden_user_status(&overview_html, primary_email).unwrap_or(
            VaultwardenUserStatus {
                state: VaultwardenUserState::Missing,
                user_uuid: None,
                sso_linked: false,
            },
        ),
    )
}

fn post_vaultwarden_invite(
    vaultwarden_url: &str,
    admin_token: &str,
    primary_email: &str,
) -> Result<(), AppError> {
    let session = login_vaultwarden_admin(vaultwarden_url, admin_token)?;
    session.post_json("/admin/invite", &json!({ "email": primary_email }))
}

fn post_vaultwarden_resend_invite(
    vaultwarden_url: &str,
    admin_token: &str,
    user_uuid: &str,
) -> Result<(), AppError> {
    let session = login_vaultwarden_admin(vaultwarden_url, admin_token)?;
    session.post_empty(&format!("/admin/users/{user_uuid}/invite/resend"))
}

#[derive(Debug, Clone)]
struct VaultwardenAdminSession {
    client: Client,
    base_url: String,
    cookie: String,
}

impl VaultwardenAdminSession {
    fn get_text(&self, path: &str) -> Result<String, AppError> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .client
            .get(&url)
            .header("Cookie", &self.cookie)
            .send()
            .map_err(|error| AppError::Io {
                message: format!(
                    "failed to call Vaultwarden admin endpoint '{}': {error}",
                    url
                ),
            })?;
        response_text(response, &url, "Vaultwarden admin GET")
    }

    fn post_json(&self, path: &str, body: &serde_json::Value) -> Result<(), AppError> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .client
            .post(&url)
            .header("Cookie", &self.cookie)
            .json(body)
            .send()
            .map_err(|error| AppError::Io {
                message: format!(
                    "failed to call Vaultwarden admin endpoint '{}': {error}",
                    url
                ),
            })?;
        response_success(response, &url, "Vaultwarden admin POST")
    }

    fn post_empty(&self, path: &str) -> Result<(), AppError> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .client
            .post(&url)
            .header("Cookie", &self.cookie)
            .header("Content-Type", "application/json")
            .send()
            .map_err(|error| AppError::Io {
                message: format!(
                    "failed to call Vaultwarden admin endpoint '{}': {error}",
                    url
                ),
            })?;
        response_success(response, &url, "Vaultwarden admin POST")
    }
}

fn login_vaultwarden_admin(
    vaultwarden_url: &str,
    admin_token: &str,
) -> Result<VaultwardenAdminSession, AppError> {
    let base_url = vaultwarden_url.trim_end_matches('/').to_string();
    let admin_url = format!("{base_url}/admin");
    let client = Client::builder().build().map_err(|error| AppError::Io {
        message: format!("failed to create Vaultwarden HTTP client: {error}"),
    })?;
    let response = client
        .post(&admin_url)
        .form(&[("token", admin_token)])
        .send()
        .map_err(|error| AppError::Io {
            message: format!(
                "failed to log into the Vaultwarden admin panel '{}': {error}",
                admin_url
            ),
        })?;
    let cookie = extract_vaultwarden_admin_cookie(response.headers())?;
    response_success(response, &admin_url, "Vaultwarden admin login")?;

    Ok(VaultwardenAdminSession {
        client,
        base_url,
        cookie,
    })
}

fn extract_vaultwarden_admin_cookie(
    headers: &reqwest::header::HeaderMap,
) -> Result<String, AppError> {
    for value in headers.get_all(reqwest::header::SET_COOKIE) {
        let Ok(value) = value.to_str() else {
            continue;
        };
        if let Some(cookie) = value.split(';').next() {
            let name = format!("{VAULTWARDEN_ADMIN_COOKIE}=");
            if cookie.starts_with(&name) {
                return Ok(cookie.to_string());
            }
        }
    }

    Err(AppError::Io {
        message: "Vaultwarden admin login did not return a VW_ADMIN session cookie".to_string(),
    })
}

fn response_text(
    response: reqwest::blocking::Response,
    url: &str,
    context: &str,
) -> Result<String, AppError> {
    let status = response.status();
    let body = response.text().unwrap_or_default();
    if status.is_success() {
        return Ok(body);
    }

    Err(AppError::Io {
        message: format!(
            "{context} request to '{}' failed with HTTP {}: {}",
            url,
            status.as_u16(),
            body.trim()
        ),
    })
}

fn response_success(
    response: reqwest::blocking::Response,
    url: &str,
    context: &str,
) -> Result<(), AppError> {
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let body = response.text().unwrap_or_default();
    if context == "Vaultwarden admin POST" {
        if let Some(message) = vaultwarden_admin_post_failure_message(url, status.as_u16(), &body) {
            return Err(AppError::Config { message });
        }
    }

    Err(AppError::Io {
        message: format!(
            "{context} request to '{}' failed with HTTP {}: {}",
            url,
            status.as_u16(),
            body.trim()
        ),
    })
}

fn vaultwarden_admin_post_failure_message(url: &str, status: u16, body: &str) -> Option<String> {
    if status != 500 || !body.to_ascii_lowercase().contains("smtp error") {
        return None;
    }

    Some(format!(
        "Vaultwarden tried to send invitation email even though this repo uses manual signup onboarding.\n\
         Endpoint: {url}\n\
         Server response: {}\n\n\
         Fix the live Vaultwarden config before retrying the invite:\n\
         1. Deploy the no-SMTP Vaultwarden config from this repo.\n\
         2. Check the Vaultwarden admin panel for any persisted SMTP settings and clear them if present.\n\
         3. Restart vaultwarden.service.\n\
         4. Retry kanidm-admin local vaultwarden invite.\n\
         5. After the pending signup exists, the user should open the Manual Signup URL and register with the exact invited email.",
        body.trim()
    ))
}

fn parse_vaultwarden_user_status(
    overview_html: &str,
    primary_email: &str,
) -> Option<VaultwardenUserStatus> {
    let tbody = html_section(overview_html, "<tbody>", "</tbody>").unwrap_or(overview_html);
    let target_email = primary_email.trim().to_ascii_lowercase();
    let mut remaining = tbody;

    while let Some(start) = remaining.find("<tr") {
        let row_start = &remaining[start..];
        let end = row_start.find("</tr>")?;
        let row = &row_start[..end];
        remaining = &row_start[end + "</tr>".len()..];

        let Some(row_email) = extract_html_attribute(row, "data-vw-user-email") else {
            continue;
        };
        if row_email.trim().to_ascii_lowercase() != target_email {
            continue;
        }

        let user_uuid = extract_html_attribute(row, "data-vw-user-uuid");
        let sso_linked = row.contains("vw-delete-sso-user");
        let state = if row.contains("vw-resend-user-invite") {
            VaultwardenUserState::InvitePending
        } else {
            VaultwardenUserState::Active
        };

        return Some(VaultwardenUserStatus {
            state,
            user_uuid,
            sso_linked,
        });
    }

    None
}

fn html_section<'a>(body: &'a str, start_marker: &str, end_marker: &str) -> Option<&'a str> {
    let start = body.find(start_marker)?;
    let from_start = &body[start + start_marker.len()..];
    let end = from_start.find(end_marker)?;
    Some(&from_start[..end])
}

fn extract_html_attribute(body: &str, attribute: &str) -> Option<String> {
    let marker = format!(r#"{attribute}=""#);
    let start = body.find(&marker)?;
    let from_start = &body[start + marker.len()..];
    let end = from_start.find('"')?;
    Some(from_start[..end].to_string())
}

fn hash_password(password: &str) -> String {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);

    let mut derived = [0u8; 64];
    pbkdf2_hmac::<Sha512>(password.as_bytes(), &salt, PBKDF2_ITERATIONS, &mut derived);

    format!(
        "$PBKDF2-SHA512$iterations={PBKDF2_ITERATIONS}${}${}",
        hex_upper(&salt),
        hex_upper(&derived)
    )
}

fn hex_upper(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02X}"));
    }
    out
}

fn write_password_hash_atomic(
    directory: &Path,
    path: &Path,
    password_hash: &str,
) -> Result<(), AppError> {
    ensure_safe_directory_path(directory)?;

    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    builder.mode(0o700);
    builder.create(directory).map_err(|error| AppError::Io {
        message: format!(
            "failed to create Jellyfin password state directory '{}': {error}",
            directory.display()
        ),
    })?;

    let metadata = fs::metadata(directory).map_err(|error| AppError::Io {
        message: format!(
            "failed to inspect Jellyfin password state directory '{}': {error}",
            directory.display()
        ),
    })?;
    if !metadata.is_dir() {
        return Err(AppError::Io {
            message: format!(
                "Jellyfin password state directory path '{}' exists but is not a directory",
                directory.display()
            ),
        });
    }

    let (temp_path, mut file) = create_temp_file(directory, path)?;

    if let Err(error) = file
        .write_all(password_hash.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
    {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to write temporary Jellyfin password state file '{}': {error}",
                temp_path.display()
            ),
        });
    }

    if let Err(error) = file.sync_all() {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to fsync temporary Jellyfin password state file '{}': {error}",
                temp_path.display()
            ),
        });
    }
    drop(file);

    if let Err(error) = fs::rename(&temp_path, path) {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to atomically replace Jellyfin password state file '{}' with '{}': {error}",
                path.display(),
                temp_path.display()
            ),
        });
    }

    best_effort_directory_sync(directory);
    Ok(())
}

fn ensure_safe_directory_path(directory: &Path) -> Result<(), AppError> {
    let mut current = PathBuf::new();

    for component in directory.components() {
        current.push(component.as_os_str());

        let metadata = match fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(AppError::Io {
                    message: format!(
                        "failed to inspect Jellyfin password path component '{}': {error}",
                        current.display()
                    ),
                });
            }
        };

        if metadata.file_type().is_symlink() {
            return Err(AppError::Io {
                message: format!(
                    "Jellyfin password state directory path '{}' resolves through symlinked component '{}'",
                    directory.display(),
                    current.display()
                ),
            });
        }

        if current != directory && !metadata.is_dir() {
            return Err(AppError::Io {
                message: format!(
                    "Jellyfin password path component '{}' exists but is not a directory",
                    current.display()
                ),
            });
        }
    }

    Ok(())
}

fn create_temp_file(directory: &Path, path: &Path) -> Result<(PathBuf, File), AppError> {
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("jellyfin");

    for _ in 0..32 {
        let temp_path = directory.join(format!(".{stem}.pbkdf2.tmp-{}", random_suffix()));
        match OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temp_path)
        {
            Ok(file) => return Ok((temp_path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(AppError::Io {
                    message: format!(
                        "failed to open temporary Jellyfin password state file '{}' in '{}': {error}",
                        temp_path.display(),
                        directory.display()
                    ),
                });
            }
        }
    }

    Err(AppError::Io {
        message: format!(
            "failed to allocate a unique temporary Jellyfin password state file in '{}'",
            directory.display()
        ),
    })
}

fn random_suffix() -> String {
    let mut bytes = [0u8; 8];
    OsRng.fill_bytes(&mut bytes);
    hex_upper(&bytes)
}

fn cleanup_temp_file(path: &Path) {
    let _ = fs::remove_file(path);
}

fn best_effort_directory_sync(directory: &Path) {
    if let Ok(dir) = File::open(directory) {
        let _ = dir.sync_all();
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Read, Write},
        net::TcpListener,
        sync::{Arc, Mutex},
        thread,
    };

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn writes_password_hash_file_from_env() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempfile::tempdir().expect("tempdir");
        let original_password = env::var_os("TEST_JELLYFIN_PASSWORD");
        let original_dir = env::var_os(PASSWORD_HASH_DIR_ENV);
        env::set_var("TEST_JELLYFIN_PASSWORD", "correct horse battery staple");
        env::set_var(PASSWORD_HASH_DIR_ENV, temp.path());

        let output =
            stage_jellyfin_password("dsaw", "TEST_JELLYFIN_PASSWORD").expect("set password");

        let hash_path = temp.path().join("dsaw.pbkdf2");
        let stored = fs::read_to_string(&hash_path).expect("hash file");
        assert!(stored.contains("$PBKDF2-SHA512$iterations=210000$"));
        assert_eq!(output.details["account_id"], "dsaw");

        match original_password {
            Some(value) => env::set_var("TEST_JELLYFIN_PASSWORD", value),
            None => env::remove_var("TEST_JELLYFIN_PASSWORD"),
        }
        match original_dir {
            Some(value) => env::set_var(PASSWORD_HASH_DIR_ENV, value),
            None => env::remove_var(PASSWORD_HASH_DIR_ENV),
        }
    }

    fn context_with_token_file(token_path: &Path) -> ResolvedContext {
        ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: "kanidm".into(),
            vaultwarden_url: Some("https://passwords.example.test".to_string()),
            vaultwarden_admin_token_file: Some(token_path.to_path_buf()),
            sftp_runtime: crate::context::SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        }
    }

    fn parsed_user(primary_email: Option<&str>, groups: &[&str]) -> Parsed<UserRecord> {
        Parsed {
            value: UserRecord {
                account_id: "dsaw".to_string(),
                display_name: Some("Dan".to_string()),
                primary_email: primary_email.map(ToString::to_string),
                spn: None,
                uuid: None,
                valid_from: None,
                expiry: None,
                groups: groups.iter().map(|group| (*group).to_string()).collect(),
            },
            warnings: Vec::new(),
        }
    }

    #[test]
    fn vaultwarden_invite_requires_primary_email() {
        let temp = tempfile::tempdir().expect("tempdir");
        let token_path = temp.path().join("vaultwarden-token");
        fs::write(&token_path, "secret-token\n").expect("token file");
        let context = context_with_token_file(&token_path);

        let error = invite_vaultwarden_user_with(
            &context,
            "dsaw",
            |_| Ok(parsed_user(None, &[])),
            |_| panic!("token should not be read"),
            |_, _, _| panic!("status should not be checked"),
            |_, _, _| panic!("invite should not be sent"),
            |_, _, _| panic!("invite should not be resent"),
        )
        .expect_err("missing email");

        assert!(matches!(error, AppError::Config { .. }));
        assert!(error.to_string().contains("does not have a primary email"));
    }

    #[test]
    fn vaultwarden_invite_sends_new_invite_without_kanidm_group_access() {
        let temp = tempfile::tempdir().expect("tempdir");
        let token_path = temp.path().join("vaultwarden-token");
        fs::write(&token_path, "secret-token\n").expect("token file");
        let context = context_with_token_file(&token_path);
        let invite_called = Arc::new(Mutex::new(false));

        let output = invite_vaultwarden_user_with(
            &context,
            "dsaw",
            |_| Ok(parsed_user(Some("dsaw@example.test"), &["users"])),
            read_secret_with_sudo_fallback_unlogged,
            |_, _, _| {
                Ok(VaultwardenUserStatus {
                    state: VaultwardenUserState::Missing,
                    user_uuid: None,
                    sso_linked: false,
                })
            },
            {
                let invite_called = Arc::clone(&invite_called);
                move |url, token, email| {
                    assert_eq!(url, "https://passwords.example.test");
                    assert_eq!(token, "secret-token");
                    assert_eq!(email, "dsaw@example.test");
                    *invite_called.lock().expect("invite lock") = true;
                    Ok(())
                }
            },
            |_, _, _| panic!("invite should not be resent"),
        )
        .expect("invite");

        assert_eq!(output.details["invite_sent"], true);
        assert_eq!(output.details["manual_signup_ready"], true);
        assert_eq!(output.details["invite_action"], "created_manual_signup");
        assert_eq!(output.details["primary_email"], "dsaw@example.test");
        assert_eq!(
            output.details["manual_signup_url"],
            "https://passwords.example.test/#/signup"
        );
        assert!(!output.human.contains("vaultwarden-users"));
        assert!(output.human.contains("Manual Signup URL"));
        assert!(output.details.get("group_added").is_none());
        assert!(output.details.get("groups").is_none());
        assert!(*invite_called.lock().expect("invite lock"));
    }

    #[test]
    fn vaultwarden_invite_skips_new_invite_when_account_is_already_active() {
        let temp = tempfile::tempdir().expect("tempdir");
        let token_path = temp.path().join("vaultwarden-token");
        fs::write(&token_path, "secret-token\n").expect("token file");
        let context = context_with_token_file(&token_path);

        let output = invite_vaultwarden_user_with(
            &context,
            "dsaw",
            |_| Ok(parsed_user(Some("dsaw@example.test"), &["users"])),
            read_secret_with_sudo_fallback_unlogged,
            |_, _, _| {
                Ok(VaultwardenUserStatus {
                    state: VaultwardenUserState::Active,
                    user_uuid: Some("uuid-1".to_string()),
                    sso_linked: true,
                })
            },
            |_, _, _| panic!("new invite should not be sent"),
            |_, _, _| panic!("pending invite should not be resent"),
        )
        .expect("active account");

        assert_eq!(output.details["invite_action"], "skipped_active");
        assert_eq!(output.details["invite_sent"], false);
        assert_eq!(output.details["manual_signup_ready"], false);
        assert!(output.human.contains("already active"));
        assert!(output.human.contains("Legacy SSO Linked: yes"));
    }

    #[test]
    fn vaultwarden_invite_resends_pending_invite() {
        let temp = tempfile::tempdir().expect("tempdir");
        let token_path = temp.path().join("vaultwarden-token");
        fs::write(&token_path, "secret-token\n").expect("token file");
        let context = context_with_token_file(&token_path);
        let resent = Arc::new(Mutex::new(false));

        let output = invite_vaultwarden_user_with(
            &context,
            "dsaw",
            |_| Ok(parsed_user(Some("dsaw@example.test"), &["users"])),
            read_secret_with_sudo_fallback_unlogged,
            |_, _, _| {
                Ok(VaultwardenUserStatus {
                    state: VaultwardenUserState::InvitePending,
                    user_uuid: Some("user-123".to_string()),
                    sso_linked: false,
                })
            },
            |_, _, _| panic!("new invite should not be sent"),
            {
                let resent = Arc::clone(&resent);
                move |url, token, user_uuid| {
                    assert_eq!(url, "https://passwords.example.test");
                    assert_eq!(token, "secret-token");
                    assert_eq!(user_uuid, "user-123");
                    *resent.lock().expect("resent lock") = true;
                    Ok(())
                }
            },
        )
        .expect("resent invite");

        assert_eq!(output.details["invite_action"], "refreshed_manual_signup");
        assert_eq!(output.details["invite_sent"], true);
        assert_eq!(output.details["manual_signup_ready"], true);
        assert!(*resent.lock().expect("resent lock"));
    }

    #[test]
    fn parses_vaultwarden_overview_rows() {
        let pending = parse_vaultwarden_user_status(
            r#"
            <tbody>
              <tr>
                <td>Pending</td>
                <td>
                  <div data-vw-user-email="pending@example.test" data-vw-user-uuid="pending-1">
                    <button vw-resend-user-invite></button>
                  </div>
                </td>
              </tr>
            </tbody>
            "#,
            "pending@example.test",
        )
        .expect("pending status");
        assert_eq!(pending.state, VaultwardenUserState::InvitePending);
        assert_eq!(pending.user_uuid.as_deref(), Some("pending-1"));
        assert!(!pending.sso_linked);

        let active = parse_vaultwarden_user_status(
            r#"
            <tbody>
              <tr>
                <td>Active</td>
                <td>
                  <div data-vw-user-email="active@example.test" data-vw-user-uuid="active-1">
                    <button vw-delete-sso-user></button>
                  </div>
                </td>
              </tr>
            </tbody>
            "#,
            "active@example.test",
        )
        .expect("active status");
        assert_eq!(active.state, VaultwardenUserState::Active);
        assert_eq!(active.user_uuid.as_deref(), Some("active-1"));
        assert!(active.sso_linked);
    }

    #[test]
    fn vaultwarden_invite_request_uses_admin_login_cookie_flow() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("local addr");
        let captured = Arc::new(Mutex::new(Vec::<String>::new()));
        let captured_request = Arc::clone(&captured);

        let server = thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut buffer = [0u8; 4096];
                let read = stream.read(&mut buffer).expect("read request");
                captured_request
                    .lock()
                    .expect("capture lock")
                    .push(String::from_utf8_lossy(&buffer[..read]).to_string());
                if index == 0 {
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nSet-Cookie: VW_ADMIN=test-cookie; Path=/admin; HttpOnly\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                        )
                        .expect("write login response");
                } else {
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                        )
                        .expect("write invite response");
                }
            }
        });

        post_vaultwarden_invite(
            &format!("http://{}", address),
            "secret-token",
            "dsaw@example.test",
        )
        .expect("invite request");
        server.join().expect("server thread");

        let requests = captured.lock().expect("capture lock");
        assert_eq!(requests.len(), 2);

        let login_request = requests[0].to_lowercase();
        assert!(login_request.starts_with("post /admin http/1.1\r\n"));
        assert!(login_request.contains("content-type: application/x-www-form-urlencoded"));
        assert!(login_request.contains("token=secret-token"));

        let invite_request = requests[1].to_lowercase();
        assert!(invite_request.starts_with("post /admin/invite http/1.1\r\n"));
        assert!(invite_request.contains("\r\ncookie: vw_admin=test-cookie\r\n"));
        assert!(invite_request.contains("\"email\":\"dsaw@example.test\""));
    }

    #[test]
    fn vaultwarden_admin_post_smtp_failure_is_actionable_config_error() {
        let message = vaultwarden_admin_post_failure_message(
            "https://passwords.example.test/admin/invite",
            500,
            r#"{"message":"SMTP error: Connection error: failed to lookup address information: Name or service not known"}"#,
        )
        .expect("smtp failure message");

        assert!(message.contains("manual signup onboarding"));
        assert!(message.contains("no-SMTP Vaultwarden config"));
        assert!(message.contains("persisted SMTP settings"));
        assert!(message.contains("Manual Signup URL"));
    }
}
