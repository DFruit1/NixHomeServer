use super::*;
use crate::output::{error_text, success_text};

pub(super) fn render_readiness_human(
    config: &SftpRuntimeConfig,
    account_id: &str,
    user: &UserRecord,
    readiness: &SftpReadiness,
) -> String {
    format!(
        "SFTP diagnosis for '{}':\nSFTP readiness: {}.\nSFTP port: {}\nChroot base: {}\n\n{}\n\nDirect SFTP uses SSH public keys. If these checks pass but SFTP still rejects login, confirm the user's public key is installed in `/persist/appdata/files-sftp-authorized-keys/{}` and that the matching private key is selected by the client.\n\n{}",
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
        format!(
            "Install the user's public key at `{}/{account_id}` and retry `sftp -P {} {account_id}@<server>` with the matching private key.",
            config.user_sftp_authorized_keys_dir, config.files_sftp_port
        ),
    ]
}

pub(super) fn merge_warnings(mut left: Vec<String>, mut right: Vec<String>) -> Vec<String> {
    left.append(&mut right);
    left.sort();
    left.dedup();
    left
}
