use std::path::Path;

use super::*;

pub(super) fn expected_unix_groups(
    config: &SftpRuntimeConfig,
    groups: &[String],
    scope: RuntimeScope,
) -> Vec<String> {
    let mut expected = Vec::new();
    for group in file_runtime_group_names(config) {
        if has_group(groups, group) {
            expected.push(group.to_string());
        }
    }
    if scope == RuntimeScope::SftpLogin
        && !expected
            .iter()
            .any(|group| group == &config.sftp_access_group)
    {
        expected.push(config.sftp_access_group.clone());
    }
    expected.sort();
    expected.dedup();
    expected
}

pub(super) fn file_runtime_group_names(config: &SftpRuntimeConfig) -> Vec<&str> {
    vec![
        &config.web_access_group,
        &config.shared_access_group,
        &config.sftp_access_group,
        &config.usb_access_group,
        &config.backup_storage_access_group,
    ]
}

pub fn groups_affect_file_runtime(config: &SftpRuntimeConfig, groups: &[String]) -> bool {
    file_runtime_group_names(config)
        .iter()
        .any(|expected| has_group(groups, expected))
}

pub(super) fn removed_runtime_groups(
    config: &SftpRuntimeConfig,
    groups: &[String],
) -> Vec<RemovedRuntimeGroup> {
    let mappings = [
        (&config.web_access_group, RemovedRuntimeKind::Web),
        (&config.shared_access_group, RemovedRuntimeKind::Shared),
        (&config.sftp_access_group, RemovedRuntimeKind::Sftp),
        (&config.usb_access_group, RemovedRuntimeKind::Usb),
        (
            &config.backup_storage_access_group,
            RemovedRuntimeKind::Backup,
        ),
    ];
    mappings
        .into_iter()
        .filter(|(expected, _)| {
            groups
                .iter()
                .any(|group| has_group(std::slice::from_ref(group), expected))
        })
        .map(|(group, kind)| RemovedRuntimeGroup {
            group: group.clone(),
            kind,
        })
        .collect()
}

#[derive(Debug, Clone)]
pub(super) struct RemovedRuntimeGroup {
    pub(super) group: String,
    pub(super) kind: RemovedRuntimeKind,
}

#[derive(Debug, Clone, Copy)]
pub(super) enum RemovedRuntimeKind {
    Web,
    Shared,
    Sftp,
    Usb,
    Backup,
}

pub(super) fn has_group(groups: &[String], expected: &str) -> bool {
    groups.iter().any(|group| {
        group == expected
            || group
                .strip_prefix(expected)
                .is_some_and(|suffix| suffix.starts_with('@'))
    })
}

pub(super) fn parse_group_words(groups: &str) -> Vec<String> {
    groups
        .split_whitespace()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
}

pub(super) fn is_local_passwd_user(account_id: &str) -> bool {
    fs::read_to_string("/etc/passwd")
        .ok()
        .is_some_and(|passwd| {
            passwd.lines().any(|line| {
                line.split(':')
                    .next()
                    .is_some_and(|candidate| candidate == account_id)
            })
        })
}

pub(super) fn sftp_chroot_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    Path::new(&config.sftp_chroot_base).join(account_id)
}

pub(super) fn sftp_authorized_keys_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    Path::new(&config.user_sftp_authorized_keys_dir).join(account_id)
}

pub(super) fn user_root_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    Path::new(&config.users_root).join(account_id)
}

pub(super) fn shared_mount_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    user_root_path(config, account_id).join(&config.shared_mount_name)
}

pub(super) fn usb_mount_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    user_root_path(config, account_id).join(&config.usb_mount_name)
}

pub(super) fn backup_mount_path(config: &SftpRuntimeConfig, account_id: &str) -> PathBuf {
    user_root_path(config, account_id).join(&config.backup_storage_mount_name)
}
