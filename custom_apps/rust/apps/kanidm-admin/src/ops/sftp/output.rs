use super::*;
use crate::output::{dim_text, error_text, success_text};

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
                if check.ok {
                    success_text("ok")
                } else {
                    error_text("failed")
                },
                check.detail
            )
        })
        .collect::<Vec<_>>()
}

pub(super) fn render_auth_test_line(auth_test: &UnixdAuthTest) -> String {
    match auth_test.outcome {
        AuthTestOutcome::Succeeded => {
            format!(
                "UnixD auth-test: {}",
                success_text("auth success and account success observed.")
            )
        }
        AuthTestOutcome::Failed => {
            format!(
                "UnixD auth-test: {}",
                error_text("password authentication failed; account access was allowed.")
            )
        }
        AuthTestOutcome::SkippedLocalBridge => {
            format!(
                "UnixD auth-test: {}",
                dim_text("skipped for local SFTP bridge; this login uses the synced local shadow password through PAM.")
            )
        }
        AuthTestOutcome::CompletedUnparseable => {
            format!(
                "UnixD auth-test: {}",
                error_text("could not confirm success from terminal output; treated as failed.")
            )
        }
        AuthTestOutcome::SpawnFailed => {
            format!("UnixD auth-test: {}", error_text("not completed."))
        }
        AuthTestOutcome::NotRun => format!("UnixD auth-test: {}", dim_text("not run.")),
    }
}

pub(super) fn render_local_shadow_line(sync: &LocalShadowSync) -> String {
    match (sync.required, sync.completed) {
        (true, true) => format!(
            "Local SFTP shadow password sync: {}",
            success_text("completed.")
        ),
        (true, false) => format!("Local SFTP shadow password sync: {}", error_text("failed.")),
        (false, _) => format!(
            "Local SFTP shadow password sync: {}",
            dim_text("not required.")
        ),
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
            "Confirm the dedicated SFTP listener with `ss -ltn 'sport = :{}'` on the server.",
            config.files_sftp_port
        ),
        format!(
            "Confirm NSS and chroot state with `getent passwd {account_id}` and `findmnt {}/{account_id}`.",
            config.sftp_chroot_base
        ),
    ]
}

pub(super) fn sftp_auth_failure_next_actions(
    config: &SftpRuntimeConfig,
    account_id: &str,
) -> Vec<String> {
    vec![
        format!(
            "Re-run the password test and enter the exact POSIX/SFTP password you just set: `kanidm-admin local sftp test {account_id} --auth-test`."
        ),
        format!(
            "If the password may have been mistyped during setup, run `kanidm-admin user posix-password set {account_id}` and use the same value during the verification prompt."
        ),
        format!(
            "If authentication still fails, inspect `journalctl -u {}` for the matching `Authentication Denied` entry.",
            config.kanidm_unixd_service
        ),
        format!(
            "Confirm the dedicated SFTP endpoint is listening with `ss -ltn 'sport = :{}'`, then retry `sftp -P {} {account_id}@<server>`.",
            config.files_sftp_port, config.files_sftp_port
        ),
    ]
}

pub(super) fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}
