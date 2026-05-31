use super::*;

pub(super) fn render_readiness_human(
    config: &SftpRuntimeConfig,
    account_id: &str,
    user: &UserRecord,
    readiness: &SftpReadiness,
) -> String {
    format!(
        "POSIX/SFTP diagnosis for '{}':\nSFTP readiness: {}.\nSFTP port: {}\nChroot base: {}\n\n{}\n\nIf these checks pass but SFTP still rejects the password, run `kanidm-admin local sftp test {}` and include `--auth-test` when you can interactively enter the current POSIX/SFTP password.\n\n{}",
        account_id,
        if readiness.ready { "ready" } else { "not ready" },
        config.files_sftp_port,
        config.sftp_chroot_base,
        render_readiness_lines(readiness).join("\n"),
        account_id,
        human_user_summary(user),
    )
}

pub(super) fn render_readiness_lines(readiness: &SftpReadiness) -> Vec<String> {
    readiness
        .checks
        .iter()
        .map(|check| {
            format!(
                "- {}: {} ({})",
                check.name,
                if check.ok { "ok" } else { "failed" },
                check.detail
            )
        })
        .collect::<Vec<_>>()
}

pub(super) fn render_auth_test_line(auth_test: &UnixdAuthTest) -> String {
    match auth_test.outcome {
        AuthTestOutcome::Succeeded => {
            "UnixD auth-test: auth success and account success observed.".to_string()
        }
        AuthTestOutcome::Failed => {
            "UnixD auth-test: completed, but failure output was observed.".to_string()
        }
        AuthTestOutcome::CompletedUnparseable => {
            "UnixD auth-test: completed; success was not parseable from captured output."
                .to_string()
        }
        AuthTestOutcome::SpawnFailed => "UnixD auth-test: not completed.".to_string(),
        AuthTestOutcome::NotRun => "UnixD auth-test: not run.".to_string(),
    }
}

pub(super) fn render_local_shadow_line(sync: &LocalShadowSync) -> String {
    match (sync.required, sync.completed) {
        (true, true) => "Local SFTP shadow password sync: completed.".to_string(),
        (true, false) => "Local SFTP shadow password sync: failed.".to_string(),
        (false, _) => "Local SFTP shadow password sync: not required.".to_string(),
    }
}

pub(super) fn sftp_next_actions(config: &SftpRuntimeConfig, account_id: &str) -> Vec<String> {
    vec![
        format!(
            "Run `kanidm-admin local sftp reconcile {account_id}` to restart `{}` and `{}`.",
            config.posix_groups_service, config.user_root_sync_service
        ),
        format!(
            "Check `systemctl status {}` and `systemctl status {}` on the server.",
            config.kanidm_unixd_service, config.files_sftp_sshd_service
        ),
        format!(
            "Confirm NSS and chroot state with `getent passwd {account_id}` and `findmnt {}/{account_id}`.",
            config.sftp_chroot_base
        ),
    ]
}

pub(super) fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}
