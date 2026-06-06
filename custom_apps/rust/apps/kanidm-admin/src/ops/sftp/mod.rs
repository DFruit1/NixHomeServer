use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

mod checks;
mod output;
mod runtime;

pub use checks::groups_affect_file_runtime;

use self::{
    checks::{
        backup_mount_path, expected_unix_groups, has_group, is_local_passwd_user,
        parse_group_words, removed_runtime_groups, sftp_chroot_path, shared_mount_path,
        usb_mount_path, user_root_path, RemovedRuntimeGroup, RemovedRuntimeKind,
    },
    output::{
        merge_warnings, render_auth_test_line, render_local_shadow_line, render_readiness_human,
        render_readiness_lines, sftp_auth_failure_next_actions, sftp_next_actions,
    },
    runtime::{readiness_from_runtime, ReadinessReport, RuntimeScope},
};
use serde::Serialize;
use serde_json::{json, Value};
use zeroize::Zeroizing;

use crate::{
    context::SftpRuntimeConfig,
    inventory::{users::UserRecord, Parsed},
    kanidm_cli::KanidmCli,
    ops::local_runtime::{
        command_probe_payload, local_command_check, run_local_command, run_root_action,
        status_from_success, CheckStatus, ConvergencePolicy, LocalCommandSpec, RootAction,
        RuntimeCheck, RuntimeCheckResult, RuntimeReport,
    },
    output::CommandOutput,
    validation::validate_account_id,
    AppError,
};

use super::user::{human_user_summary, load_user, PosixPasswordOptions};

#[derive(Debug, Clone, Serialize)]
pub struct SftpReadiness {
    pub ready: bool,
    pub checks: Vec<SftpReadinessCheck>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SftpReadinessCheck {
    pub name: String,
    pub ok: bool,
    pub required: bool,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LocalShadowSync {
    pub required: bool,
    pub completed: bool,
    pub local_passwd_user: bool,
    pub local_bridge_group_present: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub checks: Vec<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthTestOutcome {
    NotRun,
    Succeeded,
    Failed,
    SkippedLocalBridge,
    CompletedUnparseable,
    SpawnFailed,
}

#[derive(Debug, Clone, Serialize)]
pub struct UnixdAuthTest {
    pub completed: bool,
    pub succeeded: Option<bool>,
    pub outcome: AuthTestOutcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SftpSyncReport {
    pub service_steps: Vec<Value>,
    pub warnings: Vec<String>,
}

pub fn set_posix_password_and_verify(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    options: PosixPasswordOptions,
) -> Result<CommandOutput, AppError> {
    set_posix_password_and_verify_with_policy(cli, config, options, ConvergencePolicy::default())
}

pub fn set_posix_password_and_verify_with_policy(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    options: PosixPasswordOptions,
    policy: ConvergencePolicy,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(&options.account_id)?;
    let password = Zeroizing::new(options.password);
    let run_auth_test = options.run_auth_test;
    if password.is_empty() {
        return Err(AppError::Config {
            message: "POSIX password must not be empty".to_string(),
        });
    }

    let person = load_user(cli, &account_id)?;
    let mut warnings = person.warnings.clone();

    let password_update = cli.person_posix_set_password(&account_id, password.as_str())?;
    if let Some(diagnostic) = posix_password_update_rejection(&password_update) {
        return Err(AppError::Verification {
            message: format!(
                "Kanidm did not confirm the POSIX password update for '{}': {}",
                account_id, diagnostic
            ),
            details: json!({
                "account_id": account_id,
                "failure_kind": "posix_password_update_rejected",
                "kanidm_update_accepted": false,
                "backend_steps": [password_update.payload("kanidm person posix set-password")],
                "next_actions": [
                    "Choose a different POSIX/SFTP password that satisfies Kanidm password policy and history requirements.".to_string(),
                    format!("Retry `kanidm-admin user posix-password set {account_id}` and stop if Kanidm reports a policy, history, or complexity error."),
                ],
            }),
        });
    }

    let local_shadow_sync = sync_local_shadow_password(cli, config, &account_id, password.as_str());
    if local_shadow_sync.required && !local_shadow_sync.completed {
        return Err(AppError::Verification {
            message: format!(
                "Kanidm accepted the POSIX password for '{}', but the required local SFTP shadow password sync failed",
                account_id
            ),
            details: json!({
                "account_id": account_id,
                "failure_kind": "local_runtime_not_ready",
                "kanidm_update_accepted": true,
                "local_shadow_sync": local_shadow_sync,
                "runtime": null,
                "sftp_readiness": null,
                "backend_steps": [password_update.payload("kanidm person posix set-password")],
                "next_actions": [
                    format!("Confirm passwordless sudo for `chpasswd` or run the password sync as root for '{}'.", person.value.account_id),
                    format!("Retry `kanidm-admin user posix-password set {}` after fixing local shadow sync.", person.value.account_id),
                ],
            }),
        });
    }

    let unixd_cache_invalidated = match cli.unix_cache_invalidate() {
        Ok(_) => true,
        Err(error) => {
            warnings.push(format!(
                "Kanidm accepted the POSIX password update, but UnixD cache invalidation failed: {}",
                error.human_message()
            ));
            false
        }
    };

    let readiness_report = verify_runtime(
        cli,
        config,
        &account_id,
        &person,
        RuntimeScope::SftpLogin,
        policy,
    );

    let unixd_auth_test = if run_auth_test {
        if local_shadow_sync.required {
            unixd_auth_test_skipped_local_bridge()
        } else {
            let (auth_test, auth_warnings) = run_unixd_auth_test(cli, &account_id);
            warnings.extend(auth_warnings);
            auth_test
        }
    } else {
        unixd_auth_test_not_run()
    };

    let auth_failed = run_auth_test
        && !local_shadow_sync.required
        && unixd_auth_test.outcome != AuthTestOutcome::Succeeded;
    if !readiness_report.runtime.ready || auth_failed {
        let (failure_kind, message, next_actions) = if auth_failed {
            (
                "unixd_auth_failed",
                if readiness_report.runtime.ready {
                    format!(
                        "Kanidm accepted the POSIX password for '{}', but UnixD rejected the password entered for verification",
                        account_id
                    )
                } else {
                    format!(
                        "Kanidm accepted the POSIX password for '{}', but UnixD rejected the password entered for verification and local SFTP readiness is incomplete",
                        account_id
                    )
                },
                sftp_auth_failure_next_actions(config, &account_id),
            )
        } else {
            (
                "sftp_runtime_not_ready",
                format!(
                    "Kanidm accepted the POSIX password for '{}', but the local SFTP login path is not ready",
                    account_id
                ),
                sftp_next_actions(config, &account_id),
            )
        };
        return Err(AppError::Verification {
            message,
            details: json!({
                "account_id": account_id,
                "failure_kind": failure_kind,
                "user": person.value,
                "kanidm_update_accepted": true,
                "unixd_cache_invalidated": unixd_cache_invalidated,
                "local_shadow_sync": local_shadow_sync,
                "unixd_auth_test": unixd_auth_test,
                "runtime": readiness_report.runtime,
                "sftp_readiness": readiness_report.readiness,
                "next_actions": next_actions,
            }),
        });
    }

    let auth_line = render_auth_test_line(&unixd_auth_test);
    let local_shadow_line = render_local_shadow_line(&local_shadow_sync);
    let sftp_auth_description = if local_shadow_sync.required {
        format!(
            "Direct SFTP on port {} uses the synced local shadow password for '{}', because that bare username resolves from /etc/passwd before Kanidm. Domain-qualified Kanidm identities continue to use pam_kanidm.",
            config.files_sftp_port, account_id
        )
    } else {
        format!(
            "Direct SFTP on port {} uses this password through pam_kanidm.",
            config.files_sftp_port
        )
    };
    Ok(CommandOutput {
        message: format!("set or reset Kanidm POSIX password for '{}'", account_id),
        human: format!(
            "Kanidm accepted the POSIX/UNIX password update for '{}'.\nSFTP readiness: ready.\nUnixD cache invalidated: {}.\n{}\n{}\n\n{} The readiness check confirmed the local NSS, group, service, chroot, mount, and authentication path that OpenSSH depends on.\n\n{}",
            account_id,
            if unixd_cache_invalidated { "yes" } else { "no" },
            auth_line,
            local_shadow_line,
            sftp_auth_description,
            human_user_summary(&person.value),
        ),
        details: json!({
            "account_id": account_id,
            "user": person.value,
            "action": "person_posix_set_password",
            "kanidm_update_accepted": true,
            "unixd_cache_invalidated": unixd_cache_invalidated,
            "local_shadow_sync": local_shadow_sync,
            "unixd_auth_test": unixd_auth_test,
            "runtime": readiness_report.runtime,
            "sftp_readiness": readiness_report.readiness,
        }),
        warnings: merge_warnings(warnings, Vec::new()),
    })
}

pub fn diagnose_sftp_login(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    diagnose_sftp_login_with_policy(cli, config, account_id, ConvergencePolicy::default())
}

pub fn diagnose_sftp_login_with_policy(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    policy: ConvergencePolicy,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let person = load_user(cli, &account_id)?;
    let report = verify_runtime(
        cli,
        config,
        &account_id,
        &person,
        RuntimeScope::SftpLogin,
        policy,
    );

    Ok(CommandOutput {
        message: format!("diagnosed Kanidm POSIX/SFTP login path for '{account_id}'"),
        human: render_readiness_human(config, &account_id, &person.value, &report.readiness),
        details: json!({
            "account_id": account_id,
            "user": person.value,
            "sftp_runtime": config,
            "runtime": report.runtime,
            "sftp_readiness": report.readiness,
            "checks": report.readiness.checks,
        }),
        warnings: person.warnings,
    })
}

pub fn reconcile_sftp_login(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    reconcile_sftp_login_with_policy(cli, config, account_id, ConvergencePolicy::default())
}

pub fn reconcile_sftp_login_with_policy(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    policy: ConvergencePolicy,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let person = load_user(cli, &account_id)?;
    let sync_report = trigger_sftp_sync_services(cli, config);
    let sync_service_steps = sync_report.service_steps.clone();
    let readiness_report = verify_runtime(
        cli,
        config,
        &account_id,
        &person,
        RuntimeScope::SftpLogin,
        policy,
    );
    let warnings = merge_warnings(
        merge_warnings(person.warnings.clone(), sync_report.warnings),
        Vec::new(),
    );

    if !readiness_report.runtime.ready {
        return Err(AppError::Verification {
            message: format!(
                "SFTP reconciliation for '{}' completed, but the local login path is not ready",
                account_id
            ),
            details: json!({
                "account_id": account_id,
                "failure_kind": "sftp_runtime_not_ready",
                "user": person.value,
                "sftp_runtime": config,
                "runtime": readiness_report.runtime,
                "sftp_readiness": readiness_report.readiness,
                "sync_services": sync_service_steps,
                "next_actions": sftp_next_actions(config, &account_id),
            }),
        });
    }

    Ok(CommandOutput {
        message: format!("reconciled local SFTP runtime path for '{account_id}'"),
        human: format!(
            "Reconciled local SFTP runtime path for '{}'.\nSFTP readiness: ready.\n\n{}",
            account_id,
            render_readiness_lines(&readiness_report.readiness).join("\n"),
        ),
        details: json!({
            "account_id": account_id,
            "user": person.value,
            "sftp_runtime": config,
            "runtime": readiness_report.runtime,
            "sftp_readiness": readiness_report.readiness,
            "sync_services": sync_service_steps,
        }),
        warnings,
    })
}

pub fn test_sftp_login(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    run_auth_test: bool,
) -> Result<CommandOutput, AppError> {
    test_sftp_login_with_policy(
        cli,
        config,
        account_id,
        run_auth_test,
        ConvergencePolicy::default(),
    )
}

pub fn test_sftp_login_with_policy(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    run_auth_test: bool,
    policy: ConvergencePolicy,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let person = load_user(cli, &account_id)?;
    let readiness_report = verify_runtime(
        cli,
        config,
        &account_id,
        &person,
        RuntimeScope::SftpLogin,
        policy,
    );
    let local_bridge_auth = local_sftp_bridge_present(cli, config, &account_id);
    let (unixd_auth_test, auth_warnings) = if run_auth_test {
        if local_bridge_auth {
            (unixd_auth_test_skipped_local_bridge(), Vec::new())
        } else {
            run_unixd_auth_test(cli, &account_id)
        }
    } else {
        (unixd_auth_test_not_run(), Vec::new())
    };
    let warnings = merge_warnings(person.warnings.clone(), auth_warnings);

    let auth_failed = run_auth_test
        && !local_bridge_auth
        && unixd_auth_test.outcome != AuthTestOutcome::Succeeded;
    if !readiness_report.runtime.ready || auth_failed {
        let failure_kind = if auth_failed {
            "unixd_auth_failed"
        } else {
            "sftp_runtime_not_ready"
        };
        let next_actions = if auth_failed {
            sftp_auth_failure_next_actions(config, &account_id)
        } else {
            sftp_next_actions(config, &account_id)
        };
        return Err(AppError::Verification {
            message: format!("SFTP login test failed for '{account_id}'"),
            details: json!({
                "account_id": account_id,
                "failure_kind": failure_kind,
                "user": person.value,
                "sftp_runtime": config,
                "runtime": readiness_report.runtime,
                "sftp_readiness": readiness_report.readiness,
                "unixd_auth_test": unixd_auth_test,
                "next_actions": next_actions,
            }),
        });
    }

    Ok(CommandOutput {
        message: format!("tested local SFTP runtime path for '{account_id}'"),
        human: format!(
            "SFTP runtime test for '{}': ready.\n{}\n\n{}",
            account_id,
            render_auth_test_line(&unixd_auth_test),
            render_readiness_lines(&readiness_report.readiness).join("\n"),
        ),
        details: json!({
            "account_id": account_id,
            "user": person.value,
            "sftp_runtime": config,
            "runtime": readiness_report.runtime,
            "sftp_readiness": readiness_report.readiness,
            "unixd_auth_test": unixd_auth_test,
        }),
        warnings,
    })
}

pub fn reconcile_file_access_runtime(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let person = load_user(cli, &account_id)?;
    let sync_report = trigger_sftp_sync_services(cli, config);
    let sync_service_steps = sync_report.service_steps.clone();
    let readiness_report = verify_runtime(
        cli,
        config,
        &account_id,
        &person,
        RuntimeScope::FileAccess,
        ConvergencePolicy::default(),
    );
    if !readiness_report.runtime.ready {
        return Err(AppError::Verification {
            message: format!(
                "File-access reconciliation for '{}' completed, but local runtime state is not ready",
                account_id
            ),
            details: json!({
                "account_id": account_id,
                "failure_kind": "local_runtime_not_ready",
                "user": person.value,
                "sftp_runtime": config,
                "runtime": readiness_report.runtime,
                "sftp_readiness": readiness_report.readiness,
                "sync_services": sync_service_steps,
                "next_actions": sftp_next_actions(config, &account_id),
            }),
        });
    }

    Ok(CommandOutput {
        message: format!("reconciled local file-access runtime path for '{account_id}'"),
        human: format!(
            "Reconciled local file-access runtime path for '{}'.\nRuntime readiness: ready.",
            account_id
        ),
        details: json!({
            "account_id": account_id,
            "user": person.value,
            "sftp_runtime": config,
            "runtime": readiness_report.runtime,
            "sftp_readiness": readiness_report.readiness,
            "sync_services": sync_service_steps,
        }),
        warnings: merge_warnings(person.warnings, sync_report.warnings),
    })
}

pub fn verify_removed_file_access(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    removed_groups: &[String],
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let person = load_user(cli, &account_id)?;
    let sync_report = trigger_sftp_sync_services(cli, config);
    let removed = removed_runtime_groups(config, removed_groups);
    let report = verify_removed_runtime(cli, config, &account_id, &removed);

    if !report.ready {
        return Err(AppError::Verification {
            message: format!(
                "File-access removal for '{}' completed, but local runtime state still shows removed access",
                account_id
            ),
            details: json!({
                "account_id": account_id,
                "failure_kind": "local_runtime_not_ready",
                "groups_removed": removed_groups,
                "user": person.value,
                "sftp_runtime": config,
                "runtime": report,
                "sync_services": sync_report.service_steps,
                "next_actions": sftp_next_actions(config, &account_id),
            }),
        });
    }

    Ok(CommandOutput {
        message: format!("verified removed local file-access runtime for '{account_id}'"),
        human: format!(
            "Verified removed local file-access runtime for '{}'.\nRemoved access no longer appears in NSS or mount checks.",
            account_id
        ),
        details: json!({
            "account_id": account_id,
            "groups_removed": removed_groups,
            "user": person.value,
            "sftp_runtime": config,
            "runtime": report,
            "sync_services": sync_report.service_steps,
        }),
        warnings: merge_warnings(person.warnings, sync_report.warnings),
    })
}

pub fn trigger_sftp_sync_services(cli: &KanidmCli, config: &SftpRuntimeConfig) -> SftpSyncReport {
    let mut service_steps = Vec::new();
    let mut warnings = Vec::new();
    for service in [
        config.posix_groups_service.as_str(),
        config.user_root_sync_service.as_str(),
    ] {
        let execution = run_root_action(
            cli,
            &format!("local systemctl start {service}"),
            RootAction::StartSystemdUnit {
                unit: service.to_string(),
            },
            None,
            Duration::from_secs(20),
        );
        if !execution.result.allowed_success(&BTreeSet::from([0])) {
            warnings.push(format!(
                "Failed to start local sync service '{}': {}",
                service,
                execution.result.detail()
            ));
        }
        service_steps.push(execution.backend_payload);
    }
    SftpSyncReport {
        service_steps,
        warnings,
    }
}

fn verify_runtime(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    person: &Parsed<UserRecord>,
    scope: RuntimeScope,
    policy: ConvergencePolicy,
) -> ReadinessReport {
    let report = crate::ops::local_runtime::verify_until("sftp", account_id, policy, || {
        build_runtime_checks(cli, config, account_id, person, scope)
    });
    let readiness = readiness_from_runtime(&report);
    ReadinessReport {
        runtime: report,
        readiness,
    }
}

fn verify_removed_runtime(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    removed: &[RemovedRuntimeGroup],
) -> RuntimeReport {
    crate::ops::local_runtime::verify_until(
        "files_access_removal",
        account_id,
        ConvergencePolicy::default(),
        || build_removed_runtime_checks(cli, config, account_id, removed),
    )
}

fn build_runtime_checks(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    person: &Parsed<UserRecord>,
    scope: RuntimeScope,
) -> Vec<RuntimeCheck> {
    let mut checks = Vec::new();
    let groups = person.value.groups.clone();
    let expected_groups = expected_unix_groups(config, &groups, scope);
    let sftp_member = has_group(&groups, &config.sftp_access_group);
    let any_file_access = !expected_groups.is_empty();

    checks.push(static_check(
        "kanidm.user.exists",
        "Kanidm user is loadable",
        true,
        RuntimeCheckResult::passed(format!("Kanidm user '{}' loaded.", person.value.account_id)),
    ));

    if scope == RuntimeScope::SftpLogin {
        checks.push(static_check(
            "kanidm.membership.sftp_access",
            "Kanidm direct SFTP access membership is present",
            true,
            if sftp_member {
                RuntimeCheckResult::passed(format!(
                    "User is a direct member of '{}'.",
                    config.sftp_access_group
                ))
            } else {
                RuntimeCheckResult::failed(format!(
                    "User is not currently shown as a direct member of '{}'.",
                    config.sftp_access_group
                ))
            },
        ));
    }

    checks.push(kanidm_unix_status_check(cli.clone()));
    checks.push(systemctl_active_check(
        cli.clone(),
        "systemd.kanidm_unixd.active",
        format!("{} service is active", config.kanidm_unixd_service),
        config.kanidm_unixd_service.clone(),
    ));

    if scope == RuntimeScope::SftpLogin || sftp_member {
        checks.push(systemctl_active_check(
            cli.clone(),
            "systemd.files_sftp_sshd.active",
            format!("{} service is active", config.files_sftp_sshd_service),
            config.files_sftp_sshd_service.clone(),
        ));
        checks.push(tcp_port_listening_check(
            cli.clone(),
            "network.files_sftp.port_listening",
            format!(
                "files SFTP TCP port {} is listening",
                config.files_sftp_port
            ),
            config.files_sftp_port,
        ));
    } else {
        checks.push(skipped_check(
            "systemd.files_sftp_sshd.active",
            "SFTP sshd service is active",
            "skipped because direct SFTP access is not expected for this user",
        ));
        checks.push(skipped_check(
            "network.files_sftp.port_listening",
            "files SFTP TCP port is listening",
            "skipped because direct SFTP access is not expected for this user",
        ));
    }

    if scope == RuntimeScope::SftpLogin || any_file_access {
        checks.push(getent_passwd_check(cli.clone(), account_id.to_string()));
        checks.push(unix_groups_check(
            cli.clone(),
            config.clone(),
            account_id.to_string(),
            expected_groups,
            scope,
        ));
    } else {
        checks.push(skipped_check(
            "nss.passwd.exists",
            "NSS passwd entry exists",
            "skipped because no managed file-access group is expected",
        ));
        checks.push(skipped_check(
            "nss.groups.contains_expected",
            "Unix groups include expected file-access groups",
            "skipped because no managed file-access group is expected",
        ));
    }

    checks.push(path_exists_check(
        cli.clone(),
        "filesystem.user_root.exists",
        "personal file root exists",
        any_file_access || scope == RuntimeScope::SftpLogin,
        user_root_path(config, account_id),
    ));

    if sftp_member || scope == RuntimeScope::SftpLogin {
        checks.push(path_exists_check(
            cli.clone(),
            "filesystem.chroot.exists",
            "SFTP chroot directory exists",
            true,
            sftp_chroot_path(config, account_id),
        ));
        checks.push(findmnt_present_check(
            cli.clone(),
            "mount.chroot.mounted",
            "SFTP chroot bind mount is present",
            true,
            sftp_chroot_path(config, account_id),
        ));
    } else {
        checks.push(skipped_check(
            "filesystem.chroot.exists",
            "SFTP chroot directory exists",
            "skipped because direct SFTP access is not expected for this user",
        ));
        checks.push(skipped_check(
            "mount.chroot.mounted",
            "SFTP chroot bind mount is present",
            "skipped because direct SFTP access is not expected for this user",
        ));
    }

    checks.push(conditional_mount_check(
        cli.clone(),
        "mount.shared.mounted",
        "shared files bind mount is present",
        has_group(&groups, &config.shared_access_group),
        shared_mount_path(config, account_id),
        &config.shared_access_group,
    ));
    checks.push(conditional_mount_check(
        cli.clone(),
        "mount.usb.mounted",
        "USB files bind mount is present",
        has_group(&groups, &config.usb_access_group),
        usb_mount_path(config, account_id),
        &config.usb_access_group,
    ));
    checks.push(conditional_mount_check(
        cli.clone(),
        "mount.backups.mounted",
        "backup files bind mount is present",
        has_group(&groups, &config.backup_storage_access_group),
        backup_mount_path(config, account_id),
        &config.backup_storage_access_group,
    ));

    checks
}

fn build_removed_runtime_checks(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    removed: &[RemovedRuntimeGroup],
) -> Vec<RuntimeCheck> {
    let mut checks = Vec::new();
    let removed_groups = removed
        .iter()
        .map(|group| group.group.clone())
        .collect::<Vec<_>>();
    checks.push(unix_groups_absent_check(
        cli.clone(),
        account_id.to_string(),
        removed_groups,
    ));
    for removed_group in removed {
        match removed_group.kind {
            RemovedRuntimeKind::Sftp => checks.push(findmnt_absent_check(
                cli.clone(),
                "mount.chroot.absent",
                "SFTP chroot bind mount is absent after access removal",
                sftp_chroot_path(config, account_id),
            )),
            RemovedRuntimeKind::Shared => checks.push(findmnt_absent_check(
                cli.clone(),
                "mount.shared.absent",
                "shared bind mount is absent after access removal",
                shared_mount_path(config, account_id),
            )),
            RemovedRuntimeKind::Usb => checks.push(findmnt_absent_check(
                cli.clone(),
                "mount.usb.absent",
                "USB bind mount is absent after access removal",
                usb_mount_path(config, account_id),
            )),
            RemovedRuntimeKind::Backup => checks.push(findmnt_absent_check(
                cli.clone(),
                "mount.backups.absent",
                "backup bind mount is absent after access removal",
                backup_mount_path(config, account_id),
            )),
            RemovedRuntimeKind::Web => checks.push(static_check(
                "filesystem.user_root.removal_not_required",
                "personal file root removal is not required",
                false,
                RuntimeCheckResult::skipped(
                    "personal roots are persisted and are not removed when web file access is removed",
                ),
            )),
        }
    }
    checks
}

fn kanidm_unix_status_check(cli: KanidmCli) -> RuntimeCheck {
    RuntimeCheck {
        id: "kanidm_unix.status",
        label: "kanidm-unix status reports online".to_string(),
        required: true,
        command: Some(crate::ops::local_runtime::DisplayCommand {
            program: "kanidm-unix".to_string(),
            args: vec!["status".to_string()],
        }),
        run: Box::new(move || match cli.unix_status() {
            Ok(output) => {
                RuntimeCheckResult::passed("Kanidm UnixD reports online.").with_probe(json!({
                    "success": true,
                    "stdout": output.stdout,
                    "stderr": output.stderr,
                }))
            }
            Err(error) => RuntimeCheckResult::failed("Kanidm UnixD status could not be confirmed.")
                .with_probe(error.json_payload()),
        }),
    }
}

fn systemctl_active_check(
    cli: KanidmCli,
    id: &'static str,
    label: String,
    service: String,
) -> RuntimeCheck {
    let spec = LocalCommandSpec::new("systemctl", ["is-active".to_string(), service.clone()]);
    local_command_check(
        cli,
        id,
        label,
        true,
        format!("local systemctl is-active {service}"),
        spec,
        move |execution| {
            let success = execution.result.allowed_success(&BTreeSet::from([0]))
                && execution.result.stdout.trim() == "active";
            let summary = if success {
                format!("{service} is active.")
            } else {
                format!(
                    "{} is not confirmed active: {}",
                    service,
                    execution.result.detail()
                )
            };
            RuntimeCheckResult {
                status: status_from_success(success),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn tcp_port_listening_check(
    cli: KanidmCli,
    id: &'static str,
    label: String,
    port: u16,
) -> RuntimeCheck {
    let spec = LocalCommandSpec::new("ss", ["-ltn".to_string()]);
    local_command_check(
        cli,
        id,
        label,
        true,
        format!("local ss -ltn port {port}"),
        spec,
        move |execution| {
            let command_success = execution.result.allowed_success(&BTreeSet::from([0]));
            let listening =
                command_success && ss_output_has_listening_port(&execution.result.stdout, port);
            let summary = if listening {
                format!("A TCP listener is present on port {port}.")
            } else if command_success {
                format!("No TCP listener was found on port {port}.")
            } else {
                format!(
                    "Could not inspect TCP listeners for port {port}: {}",
                    execution.result.detail()
                )
            };
            RuntimeCheckResult {
                status: status_from_success(listening),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn ss_output_has_listening_port(output: &str, port: u16) -> bool {
    let suffix = format!(":{port}");
    output.lines().any(|line| {
        let mut fields = line.split_whitespace();
        let state = fields.next();
        let _recv_q = fields.next();
        let _send_q = fields.next();
        let local_address = fields.next();
        matches!(state, Some("LISTEN"))
            && local_address.is_some_and(|address| address.ends_with(&suffix))
    })
}

fn getent_passwd_check(cli: KanidmCli, account_id: String) -> RuntimeCheck {
    let spec = LocalCommandSpec::new("getent", ["passwd".to_string(), account_id.clone()]);
    local_command_check(
        cli,
        "nss.passwd.exists",
        "NSS passwd entry exists",
        true,
        "local getent passwd",
        spec,
        move |execution| {
            let success = execution.result.allowed_success(&BTreeSet::from([0]));
            let summary = if success {
                format!(
                    "NSS resolves '{}': {}",
                    account_id,
                    execution.result.stdout.trim()
                )
            } else {
                format!(
                    "NSS does not resolve '{}': {}",
                    account_id,
                    execution.result.detail()
                )
            };
            RuntimeCheckResult {
                status: status_from_success(success),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn unix_groups_check(
    cli: KanidmCli,
    config: SftpRuntimeConfig,
    account_id: String,
    expected_groups: Vec<String>,
    scope: RuntimeScope,
) -> RuntimeCheck {
    let spec = LocalCommandSpec::new("id", ["-nG".to_string(), account_id.clone()]);
    local_command_check(
        cli,
        "nss.groups.contains_expected",
        "Unix groups include expected file-access groups",
        true,
        "local id -nG",
        spec,
        move |execution| {
            let success = execution.result.allowed_success(&BTreeSet::from([0]));
            let unix_groups = parse_group_words(&execution.result.stdout);
            let local_bridge_satisfies_sftp = scope == RuntimeScope::SftpLogin
                && is_local_passwd_user(&account_id)
                && has_group(&unix_groups, &config.local_sftp_access_group);
            let mut missing = expected_groups
                .iter()
                .filter(|group| !has_group(&unix_groups, group))
                .cloned()
                .collect::<Vec<_>>();
            if !local_bridge_satisfies_sftp
                && scope == RuntimeScope::SftpLogin
                && !has_group(&unix_groups, &config.local_sftp_access_group)
                && !has_group(&unix_groups, &config.sftp_access_group)
                && !missing
                    .iter()
                    .any(|group| group == &config.sftp_access_group)
            {
                missing.push(config.sftp_access_group.clone());
            }
            missing.sort();
            missing.dedup();
            let ok = success && (missing.is_empty() || local_bridge_satisfies_sftp);
            let summary = if ok {
                if local_bridge_satisfies_sftp && !missing.is_empty() {
                    format!(
                        "Local Unix bridge group '{}' permits SFTP login for local account '{}'; Kanidm file-access membership and mounts are checked separately.",
                        config.local_sftp_access_group, account_id
                    )
                } else {
                    format!(
                        "Unix groups include expected file-access groups: {}",
                        unix_groups.join(" ")
                    )
                }
            } else if success {
                format!(
                    "Unix groups are missing expected file-access groups: {}",
                    missing.join(", ")
                )
            } else {
                format!(
                    "Unix groups could not be resolved: {}",
                    execution.result.detail()
                )
            };
            RuntimeCheckResult {
                status: status_from_success(ok),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn unix_groups_absent_check(
    cli: KanidmCli,
    account_id: String,
    removed_groups: Vec<String>,
) -> RuntimeCheck {
    let spec = LocalCommandSpec::new("id", ["-nG".to_string(), account_id.clone()]);
    local_command_check(
        cli,
        "nss.groups.removed_absent",
        "Unix groups no longer include removed file-access groups",
        true,
        "local id -nG after membership removal",
        spec,
        move |execution| {
            let command_success = execution.result.allowed_success(&BTreeSet::from([0]));
            let unix_groups = parse_group_words(&execution.result.stdout);
            let still_present = removed_groups
                .iter()
                .filter(|group| has_group(&unix_groups, group))
                .cloned()
                .collect::<Vec<_>>();
            let ok = !command_success || still_present.is_empty();
            let summary = if ok && command_success {
                "Unix groups no longer include removed file-access groups.".to_string()
            } else if ok {
                "Unix account no longer resolves; removed groups are absent from NSS.".to_string()
            } else {
                format!(
                    "Unix groups still include removed file-access groups: {}",
                    still_present.join(", ")
                )
            };
            RuntimeCheckResult {
                status: status_from_success(ok),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn path_exists_check(
    cli: KanidmCli,
    id: &'static str,
    label: &'static str,
    required: bool,
    path: PathBuf,
) -> RuntimeCheck {
    if !required {
        return skipped_check(id, label, "skipped because this path is not expected");
    }
    let path_string = path.display().to_string();
    let spec = LocalCommandSpec::new("test", ["-d".to_string(), path_string.clone()]);
    local_command_check(
        cli,
        id,
        label,
        true,
        format!("local test -d {path_string}"),
        spec,
        move |execution| {
            let success = execution.result.allowed_success(&BTreeSet::from([0]));
            let summary = if success {
                format!("Directory exists: {path_string}")
            } else {
                format!("Directory is missing: {path_string}")
            };
            RuntimeCheckResult {
                status: status_from_success(success),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn conditional_mount_check(
    cli: KanidmCli,
    id: &'static str,
    label: &'static str,
    expected: bool,
    path: PathBuf,
    group: &str,
) -> RuntimeCheck {
    if expected {
        findmnt_present_check(cli, id, label, true, path)
    } else {
        skipped_check(
            id,
            label,
            format!("skipped because '{group}' membership is not expected for this user"),
        )
    }
}

fn findmnt_present_check(
    cli: KanidmCli,
    id: &'static str,
    label: &'static str,
    required: bool,
    path: PathBuf,
) -> RuntimeCheck {
    let path_string = path.display().to_string();
    let spec = LocalCommandSpec::new("findmnt", [path_string.clone()]);
    local_command_check(
        cli,
        id,
        label,
        required,
        format!("local findmnt {path_string}"),
        spec,
        move |execution| {
            let success = execution.result.allowed_success(&BTreeSet::from([0]));
            let summary = if success {
                format!("Bind mount is present: {path_string}")
            } else {
                format!(
                    "Bind mount is not present for {}: {}",
                    path_string,
                    execution.result.detail()
                )
            };
            RuntimeCheckResult {
                status: status_from_success(success),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn findmnt_absent_check(
    cli: KanidmCli,
    id: &'static str,
    label: &'static str,
    path: PathBuf,
) -> RuntimeCheck {
    let path_string = path.display().to_string();
    let spec = LocalCommandSpec::new("findmnt", [path_string.clone()]);
    local_command_check(
        cli,
        id,
        label,
        true,
        format!("local findmnt absent {path_string}"),
        spec,
        move |execution| {
            let mounted = execution.result.allowed_success(&BTreeSet::from([0]));
            let summary = if mounted {
                format!("Removed bind mount is still present: {path_string}")
            } else {
                format!("Removed bind mount is absent: {path_string}")
            };
            RuntimeCheckResult {
                status: status_from_success(!mounted),
                summary,
                detail: None,
                probe: Some(command_probe_payload(execution)),
            }
        },
    )
}

fn static_check(
    id: &'static str,
    label: &'static str,
    required: bool,
    result: RuntimeCheckResult,
) -> RuntimeCheck {
    RuntimeCheck {
        id,
        label: label.to_string(),
        required,
        command: None,
        run: Box::new(move || result),
    }
}

fn skipped_check(
    id: &'static str,
    label: impl Into<String>,
    summary: impl Into<String>,
) -> RuntimeCheck {
    let summary = summary.into();
    RuntimeCheck {
        id,
        label: label.into(),
        required: false,
        command: None,
        run: Box::new(move || RuntimeCheckResult::skipped(summary)),
    }
}

fn sync_local_shadow_password(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
    password: &str,
) -> LocalShadowSync {
    let mut checks = Vec::new();
    let local_passwd_user = is_local_passwd_user(account_id);
    let id_spec = LocalCommandSpec::new("id", ["-nG".to_string(), account_id.to_string()]);
    let id = run_local_command(cli, "local id -nG for SFTP bridge check", id_spec);
    let groups = parse_group_words(&id.result.stdout);
    let local_bridge_group_present = id.result.allowed_success(&BTreeSet::from([0]))
        && has_group(&groups, &config.local_sftp_access_group);
    checks.push(id.backend_payload);

    let required = local_passwd_user && local_bridge_group_present;
    if !required {
        return LocalShadowSync {
            required,
            completed: false,
            local_passwd_user,
            local_bridge_group_present,
            error: None,
            checks,
        };
    }

    let sync = run_root_action(
        cli,
        "local chpasswd for SFTP bridge user",
        RootAction::Chpasswd {
            username: account_id.to_string(),
        },
        Some(format!("{account_id}:{password}\n")),
        Duration::from_secs(20),
    );
    let completed = sync.result.allowed_success(&BTreeSet::from([0]));
    let error = (!completed).then(|| sync.result.detail());
    checks.push(sync.backend_payload);

    LocalShadowSync {
        required,
        completed,
        local_passwd_user,
        local_bridge_group_present,
        error,
        checks,
    }
}

fn local_sftp_bridge_present(
    cli: &KanidmCli,
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> bool {
    if !is_local_passwd_user(account_id) {
        return false;
    }
    let id_spec = LocalCommandSpec::new("id", ["-nG".to_string(), account_id.to_string()]);
    let id = run_local_command(cli, "local id -nG for SFTP bridge auth check", id_spec);
    let groups = parse_group_words(&id.result.stdout);
    id.result.allowed_success(&BTreeSet::from([0]))
        && has_group(&groups, &config.local_sftp_access_group)
}

fn run_unixd_auth_test(cli: &KanidmCli, account_id: &str) -> (UnixdAuthTest, Vec<String>) {
    eprintln!(
        "{}",
        crate::output::warning_text(&format!(
            "Verification step for '{account_id}': enter the POSIX/SFTP password.\nThis is the password used by direct SFTP through Kanidm UnixD/PAM.\nIt will not set or change the password again; it only confirms that the local login path accepts it."
        ))
    );
    match cli.unix_auth_test(account_id) {
        Ok(output) => {
            let outcome = parse_unixd_auth_outcome(&output.stdout, &output.stderr);
            (
                UnixdAuthTest {
                    completed: true,
                    succeeded: auth_outcome_success(outcome),
                    outcome,
                    detail: (outcome == AuthTestOutcome::CompletedUnparseable).then(|| {
                        "completed, but inherited terminal output was not parseable".to_string()
                    }),
                },
                Vec::new(),
            )
        }
        Err(error) => (
            UnixdAuthTest {
                completed: false,
                succeeded: Some(false),
                outcome: AuthTestOutcome::SpawnFailed,
                detail: Some(error.human_message()),
            },
            vec![format!(
                "Kanidm UnixD auth-test could not run for '{}': {}",
                account_id,
                error.human_message()
            )],
        ),
    }
}

fn unixd_auth_test_not_run() -> UnixdAuthTest {
    UnixdAuthTest {
        completed: false,
        succeeded: None,
        outcome: AuthTestOutcome::NotRun,
        detail: Some("not run".to_string()),
    }
}

fn unixd_auth_test_skipped_local_bridge() -> UnixdAuthTest {
    UnixdAuthTest {
        completed: false,
        succeeded: None,
        outcome: AuthTestOutcome::SkippedLocalBridge,
        detail: Some(
            "local account uses the files SFTP bridge; UnixD-only auth-test does not include pam_unix"
                .to_string(),
        ),
    }
}

fn parse_unixd_auth_outcome(stdout: &str, stderr: &str) -> AuthTestOutcome {
    let combined = format!("{stdout}\n{stderr}").to_ascii_lowercase();
    let auth_success = combined.contains("auth success");
    let account_success = combined.contains("account success");
    if auth_success && account_success {
        return AuthTestOutcome::Succeeded;
    }
    let failure_markers = [
        "auth failed",
        "auth failure",
        "account failed",
        "account failure",
        "denied",
        "invalid",
    ];
    if failure_markers
        .iter()
        .any(|marker| combined.contains(marker))
    {
        return AuthTestOutcome::Failed;
    }
    AuthTestOutcome::CompletedUnparseable
}

fn posix_password_update_rejection(output: &crate::kanidm_cli::BackendSuccess) -> Option<String> {
    let combined = format!("{}\n{}", output.stdout, output.stderr);
    let lower = combined.to_ascii_lowercase();
    let markers = [
        "password history",
        "history requirement",
        "complexity requirement",
        "complexity requirements",
        "password complexity",
        "password quality",
        "quality requirement",
        "quality requirements",
        "minimum length",
        "too short",
        "was rejected",
        "password rejected",
        "policy violation",
        "violates policy",
        "does not meet",
        "failed to set",
        "failed to update",
        "error:",
    ];
    markers
        .iter()
        .any(|marker| lower.contains(marker))
        .then(|| {
            combined
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .unwrap_or("password update was rejected by policy")
                .to_string()
        })
}

fn auth_outcome_success(outcome: AuthTestOutcome) -> Option<bool> {
    match outcome {
        AuthTestOutcome::Succeeded => Some(true),
        AuthTestOutcome::Failed | AuthTestOutcome::SpawnFailed => Some(false),
        AuthTestOutcome::NotRun
        | AuthTestOutcome::SkippedLocalBridge
        | AuthTestOutcome::CompletedUnparseable => None,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        env, fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand,
    };

    use crate::{
        context::{ResolvedContext, RuntimePolicy},
        TEST_ENV_LOCK,
    };

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

    fn prepend_path(bin_dir: &Path) -> Option<std::ffi::OsString> {
        let original_path = env::var_os("PATH");
        let mut entries = vec![bin_dir.to_path_buf()];
        if let Some(path) = &original_path {
            entries.extend(env::split_paths(path));
        }
        env::set_var(
            "PATH",
            env::join_paths(entries).expect("join test PATH entries"),
        );
        original_path
    }

    fn restore_path(original_path: Option<std::ffi::OsString>) {
        match original_path {
            Some(path) => env::set_var("PATH", path),
            None => env::remove_var("PATH"),
        }
    }

    fn cli_for(script: &Path) -> KanidmCli {
        KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.as_os_str().to_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: RuntimePolicy::default(),
        })
    }

    #[test]
    fn group_matching_accepts_exact_and_domain_qualified_values() {
        assert!(has_group(
            &["files-sftp-users".to_string()],
            "files-sftp-users"
        ));
        assert!(has_group(
            &["files-sftp-users@example.test".to_string()],
            "files-sftp-users"
        ));
        assert!(!has_group(
            &["files-sftp-users-extra".to_string()],
            "files-sftp-users"
        ));
    }

    #[test]
    fn auth_test_success_requires_auth_and_account_success() {
        assert_eq!(
            parse_unixd_auth_outcome("auth success!\naccount success!\n", ""),
            AuthTestOutcome::Succeeded
        );
        assert_eq!(
            parse_unixd_auth_outcome("auth success!\n", ""),
            AuthTestOutcome::CompletedUnparseable
        );
        assert_eq!(
            parse_unixd_auth_outcome("auth failed\n", ""),
            AuthTestOutcome::Failed
        );
    }

    #[test]
    fn diagnostics_use_renamed_sftp_runtime_values() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let chroot_base = dir.path().join("renamed-chroots");
        let users_root = dir.path().join("renamed-users");
        fs::create_dir_all(chroot_base.join("alice")).expect("chroot");
        fs::create_dir_all(users_root.join("alice")).expect("user root");
        let script = dir.path().join("kanidm");
        let unix_script = dir.path().join("kanidm-unix");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "get" && "$3" == "alice" ]]; then
  printf '{"attrs":{"name":["alice"],"displayname":["Alice"],"directmemberof":["renamed-sftp-users"]}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );
        write_script(
            &unix_script,
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "status" ]]; then
  printf 'system: online\nKanidm: online\n'
  exit 0
fi
exit 1
"#,
        );
        write_script(
            &dir.path().join("getent"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "passwd" && "$2" == "alice" ]]; then
  printf 'alice:x:2000:2000:Alice:/home/alice:/bin/bash\n'
  exit 0
fi
exit 2
"#,
        );
        write_script(
            &dir.path().join("id"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-nG" && "$2" == "alice" ]]; then
  printf 'users renamed-sftp-users\n'
  exit 0
fi
exit 1
"#,
        );
        write_script(
            &dir.path().join("systemctl"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "is-active" && ( "$2" == "renamed-unixd.service" || "$2" == "renamed-sftp.service" ) ]]; then
  printf 'active\n'
  exit 0
fi
exit 3
"#,
        );
        write_script(
            &dir.path().join("ss"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-ltn" ]]; then
  printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
  printf 'LISTEN 0      128    0.0.0.0:2202       0.0.0.0:*\n'
  exit 0
fi
exit 1
"#,
        );
        write_script(
            &dir.path().join("findmnt"),
            r#"#!/usr/bin/env bash
set -euo pipefail
exit 0
"#,
        );
        let original_path = prepend_path(dir.path());
        let config = SftpRuntimeConfig {
            sftp_access_group: "renamed-sftp-users".to_string(),
            local_sftp_access_group: "renamed-local-sftp-users".to_string(),
            sftp_chroot_base: chroot_base.display().to_string(),
            users_root: users_root.display().to_string(),
            files_sftp_port: 2202,
            files_sftp_sshd_service: "renamed-sftp.service".to_string(),
            kanidm_unixd_service: "renamed-unixd.service".to_string(),
            posix_groups_service: "renamed-posix.service".to_string(),
            user_root_sync_service: "renamed-root-sync.service".to_string(),
            ..SftpRuntimeConfig::default()
        };

        let output = diagnose_sftp_login_with_policy(
            &cli_for(&script),
            &config,
            "alice",
            ConvergencePolicy {
                timeout: Duration::from_millis(0),
                interval: Duration::from_millis(1),
                stable_successes_required: 1,
            },
        )
        .expect("diagnose sftp");
        restore_path(original_path);

        assert_eq!(output.details["runtime"]["ready"], true);
        assert_eq!(output.details["sftp_readiness"]["ready"], true);
        assert_eq!(
            output.details["sftp_runtime"]["sftpAccessGroup"],
            "renamed-sftp-users"
        );
        let rendered = serde_json::to_string(&output.details).expect("details json");
        assert!(rendered.contains("renamed-sftp.service"));
        assert!(rendered.contains("renamed-unixd.service"));
        assert!(!rendered.contains("files-sftp-sshd.service"));
    }

    #[test]
    fn auth_test_completed_unparseable_is_not_success() {
        let auth = UnixdAuthTest {
            completed: true,
            succeeded: auth_outcome_success(AuthTestOutcome::CompletedUnparseable),
            outcome: AuthTestOutcome::CompletedUnparseable,
            detail: None,
        };
        assert_eq!(auth.succeeded, None);
        assert_ne!(auth.outcome, AuthTestOutcome::Succeeded);
    }

    #[test]
    fn ss_listener_parser_requires_listen_on_target_port() {
        let output = "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n\
LISTEN 0      128    127.0.0.1:2222      0.0.0.0:*\n\
ESTAB  0      0      127.0.0.1:2223      127.0.0.1:44444\n";
        assert!(ss_output_has_listening_port(output, 2222));
        assert!(!ss_output_has_listening_port(output, 2223));
        assert!(!ss_output_has_listening_port(output, 22));
    }

    #[test]
    fn local_bridge_shadow_sync_failure_is_fatal_and_redacts_password() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "get" && "$3" == "root" ]]; then
  printf '{"attrs":{"name":["root"],"displayname":["Root"],"directmemberof":["files-sftp-users"]}}'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "posix" && "$3" == "set-password" && "$4" == "root" ]]; then
  cat >/dev/null
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );
        write_script(
            &dir.path().join("id"),
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-nG" && "$2" == "root" ]]; then
  printf 'root files-local-sftp-users\n'
  exit 0
fi
exit 1
"#,
        );
        write_script(
            &dir.path().join("sudo"),
            r#"#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'sudo chpasswd denied\n' >&2
exit 1
"#,
        );
        let original_path = prepend_path(dir.path());
        let error = set_posix_password_and_verify_with_policy(
            &cli_for(&script),
            &SftpRuntimeConfig::default(),
            PosixPasswordOptions {
                account_id: "root".to_string(),
                password: "correct horse battery staple".to_string(),
                run_auth_test: false,
            },
            ConvergencePolicy {
                timeout: Duration::from_millis(0),
                interval: Duration::from_millis(1),
                stable_successes_required: 1,
            },
        )
        .expect_err("shadow sync failure");
        restore_path(original_path);

        match &error {
            AppError::Verification { details, .. } => {
                assert_eq!(details["local_shadow_sync"]["required"], true);
                assert_eq!(details["local_shadow_sync"]["completed"], false);
            }
            other => panic!("unexpected error: {other:?}"),
        }
        let rendered = serde_json::to_string(&error.json_payload()).expect("error json");
        assert!(!rendered.contains("correct horse battery staple"));
    }
}
