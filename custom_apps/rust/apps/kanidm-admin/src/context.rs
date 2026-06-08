use std::{
    env,
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};

use crate::AppError;

pub const ENV_REPO_ROOT: &str = "KANIDM_ADMIN_REPO_ROOT";
pub const ENV_SERVER_URL: &str = "KANIDM_ADMIN_SERVER_URL";
pub const ENV_ADMIN_NAME: &str = "KANIDM_ADMIN_NAME";
pub const ENV_KANIDM_BIN: &str = "KANIDM_ADMIN_KANIDM_BIN";
pub const ENV_NIX_BIN: &str = "KANIDM_ADMIN_NIX_BIN";
pub const ENV_VAULTWARDEN_URL: &str = "KANIDM_ADMIN_VAULTWARDEN_URL";
pub const ENV_VAULTWARDEN_ADMIN_TOKEN_FILE: &str = "KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE";
pub const ENV_BACKEND_TIMEOUT_SECONDS: &str = "KANIDM_ADMIN_BACKEND_TIMEOUT_SECONDS";
pub const ENV_CONTEXT_FILE: &str = "KANIDM_ADMIN_CONTEXT_FILE";

const NIX_EVAL_TIMEOUT: Duration = Duration::from_secs(20);
const POLL_INTERVAL: Duration = Duration::from_millis(50);
const DEFAULT_BACKEND_TIMEOUT_SECONDS: u64 = 20;
const MIN_BACKEND_TIMEOUT_SECONDS: u64 = 1;
const MAX_BACKEND_TIMEOUT_SECONDS: u64 = 300;
const DEFAULT_CONTEXT_FILE: &str = "/etc/kanidm-admin/context.json";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextOverrides {
    pub repo_root: Option<PathBuf>,
    pub server_url: Option<String>,
    pub admin_name: Option<String>,
    pub kanidm_bin: Option<OsString>,
    pub nix_bin: Option<OsString>,
    pub vaultwarden_url: Option<String>,
    pub vaultwarden_admin_token_file: Option<PathBuf>,
    pub backend_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedContext {
    pub repo_root: Option<PathBuf>,
    pub server_url: String,
    pub admin_name: String,
    pub kanidm_bin: OsString,
    pub vaultwarden_url: Option<String>,
    pub vaultwarden_admin_token_file: Option<PathBuf>,
    pub sftp_runtime: SftpRuntimeConfig,
    pub runtime_policy: RuntimePolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpRuntimeConfig {
    pub sftp_access_group: String,
    pub local_sftp_access_group: String,
    pub web_access_group: String,
    pub shared_access_group: String,
    pub usb_access_group: String,
    pub backup_storage_access_group: String,
    pub sftp_chroot_base: String,
    pub user_sftp_authorized_keys_dir: String,
    pub users_root: String,
    pub shared_root: String,
    pub usb_root: String,
    pub backup_root: String,
    pub shared_mount_name: String,
    pub usb_mount_name: String,
    pub backup_storage_mount_name: String,
    pub files_sftp_port: u16,
    pub files_sftp_sshd_service: String,
    pub kanidm_unixd_service: String,
    pub posix_groups_service: String,
    pub user_root_sync_service: String,
    pub user_root_bind_template: String,
    pub shared_bind_template: String,
    pub usb_bind_template: String,
    pub backup_bind_template: String,
}

impl Default for SftpRuntimeConfig {
    fn default() -> Self {
        Self {
            sftp_access_group: "files-sftp-users".to_string(),
            local_sftp_access_group: "files-local-sftp-users".to_string(),
            web_access_group: "user-files".to_string(),
            shared_access_group: "files-shared-users".to_string(),
            usb_access_group: "usb-access".to_string(),
            backup_storage_access_group: "admin-backups".to_string(),
            sftp_chroot_base: "/srv/files-sftp/chroots".to_string(),
            user_sftp_authorized_keys_dir: "/persist/appdata/files-sftp-authorized-keys"
                .to_string(),
            users_root: "/mnt/data/users".to_string(),
            shared_root: "/mnt/data/shared".to_string(),
            usb_root: "/mnt/external-usb".to_string(),
            backup_root: "/mnt/data/backups".to_string(),
            shared_mount_name: "_Shared".to_string(),
            usb_mount_name: "_USB".to_string(),
            backup_storage_mount_name: "_Backups".to_string(),
            files_sftp_port: 2222,
            files_sftp_sshd_service: "files-sftp-sshd.service".to_string(),
            kanidm_unixd_service: "kanidm-unixd.service".to_string(),
            posix_groups_service: "kanidm-files-posix-groups.service".to_string(),
            user_root_sync_service: "fileshare-user-root-sync.service".to_string(),
            user_root_bind_template: "files-sftp-user-root@.service".to_string(),
            shared_bind_template: "files-shared-bindfs@.service".to_string(),
            usb_bind_template: "files-usb-bindfs@.service".to_string(),
            backup_bind_template: "files-backups-bindfs@.service".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimePolicy {
    pub backend_timeout: Duration,
}

impl Default for RuntimePolicy {
    fn default() -> Self {
        Self {
            backend_timeout: Duration::from_secs(DEFAULT_BACKEND_TIMEOUT_SECONDS),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct RepoDefaults {
    #[serde(rename = "serverUrl")]
    server_url: String,
    #[serde(rename = "adminName")]
    admin_name: String,
    #[serde(rename = "vaultwardenUrl")]
    vaultwarden_url: Option<String>,
    #[serde(rename = "vaultwardenAdminTokenFile")]
    vaultwarden_admin_token_file: Option<PathBuf>,
    #[serde(rename = "sftpRuntime", default)]
    sftp_runtime: SftpRuntimeConfig,
}

pub fn resolve_context(overrides: ContextOverrides) -> Result<ResolvedContext, AppError> {
    let cli_repo_root = overrides.repo_root;
    let env_repo_root = env::var_os(ENV_REPO_ROOT).map(PathBuf::from);
    let repo_root_override = cli_repo_root.clone().or(env_repo_root);
    let installed_defaults = installed_context_defaults()?;
    let server_url = overrides
        .server_url
        .or_else(|| env::var(ENV_SERVER_URL).ok())
        .or_else(|| {
            installed_defaults
                .as_ref()
                .map(|defaults| defaults.server_url.clone())
        });
    let admin_name = overrides
        .admin_name
        .or_else(|| env::var(ENV_ADMIN_NAME).ok())
        .or_else(|| {
            installed_defaults
                .as_ref()
                .map(|defaults| defaults.admin_name.clone())
        });
    let kanidm_bin = overrides
        .kanidm_bin
        .or_else(|| env::var_os(ENV_KANIDM_BIN))
        .unwrap_or_else(|| OsString::from("kanidm"));
    let nix_bin = overrides
        .nix_bin
        .or_else(|| env::var_os(ENV_NIX_BIN))
        .unwrap_or_else(|| OsString::from("nix"));
    let vaultwarden_url = overrides
        .vaultwarden_url
        .or_else(|| env::var(ENV_VAULTWARDEN_URL).ok())
        .or_else(|| {
            installed_defaults
                .as_ref()
                .and_then(|defaults| defaults.vaultwarden_url.clone())
        });
    let vaultwarden_admin_token_file = overrides
        .vaultwarden_admin_token_file
        .or_else(|| env::var_os(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE).map(PathBuf::from))
        .or_else(|| {
            installed_defaults
                .as_ref()
                .and_then(|defaults| defaults.vaultwarden_admin_token_file.clone())
        });
    let runtime_policy = RuntimePolicy {
        backend_timeout: Duration::from_secs(resolve_backend_timeout_seconds(
            overrides.backend_timeout_seconds,
        )?),
    };

    if let (Some(server_url), Some(admin_name)) = (&server_url, &admin_name) {
        let resolved_repo_root = repo_root_override
            .as_deref()
            .filter(|path| path.join("vars.nix").is_file())
            .map(Path::to_path_buf)
            .or_else(find_repo_root_optional);
        let sftp_runtime = if let Some(defaults) = installed_defaults.as_ref() {
            defaults.sftp_runtime.clone()
        } else if let Some(repo_root) = repo_root_override
            .as_deref()
            .filter(|path| path.join("vars.nix").is_file())
        {
            nix_repo_defaults(&nix_bin, repo_root)?.sftp_runtime
        } else {
            SftpRuntimeConfig::default()
        };
        return Ok(ResolvedContext {
            repo_root: resolved_repo_root,
            server_url: server_url.clone(),
            admin_name: admin_name.clone(),
            kanidm_bin,
            vaultwarden_url,
            vaultwarden_admin_token_file,
            sftp_runtime,
            runtime_policy,
        });
    }

    if let Some(defaults) = installed_defaults {
        return Ok(ResolvedContext {
            repo_root: repo_root_override
                .as_deref()
                .filter(|path| path.join("vars.nix").is_file())
                .map(Path::to_path_buf)
                .or_else(find_repo_root_optional),
            server_url: server_url.unwrap_or(defaults.server_url),
            admin_name: admin_name.unwrap_or(defaults.admin_name),
            kanidm_bin,
            vaultwarden_url: vaultwarden_url.or(defaults.vaultwarden_url),
            vaultwarden_admin_token_file: vaultwarden_admin_token_file
                .or(defaults.vaultwarden_admin_token_file),
            sftp_runtime: defaults.sftp_runtime,
            runtime_policy,
        });
    }

    let repo_root = match repo_root_override
        .filter(|path| path.join("vars.nix").is_file())
        .or_else(find_repo_root_optional)
    {
        Some(path) => path,
        None => {
            return Err(AppError::Config {
                message: format!(
                    "could not resolve kanidm-admin context; install {DEFAULT_CONTEXT_FILE}, pass --repo-root, or set {ENV_SERVER_URL} and {ENV_ADMIN_NAME}"
                ),
            });
        }
    };

    let defaults = nix_repo_defaults(&nix_bin, &repo_root)?;
    Ok(ResolvedContext {
        repo_root: Some(repo_root),
        server_url: server_url.unwrap_or(defaults.server_url),
        admin_name: admin_name.unwrap_or(defaults.admin_name),
        kanidm_bin,
        vaultwarden_url: vaultwarden_url.or(defaults.vaultwarden_url),
        vaultwarden_admin_token_file: vaultwarden_admin_token_file
            .or(defaults.vaultwarden_admin_token_file),
        sftp_runtime: defaults.sftp_runtime,
        runtime_policy,
    })
}

fn installed_context_defaults() -> Result<Option<RepoDefaults>, AppError> {
    match env::var_os(ENV_CONTEXT_FILE) {
        Some(path) => read_context_defaults_file(PathBuf::from(path)).map(Some),
        None => {
            let path = Path::new(DEFAULT_CONTEXT_FILE);
            if path.exists() {
                read_context_defaults_file(path.to_path_buf()).map(Some)
            } else {
                Ok(None)
            }
        }
    }
}

fn read_context_defaults_file(path: PathBuf) -> Result<RepoDefaults, AppError> {
    let contents = fs::read_to_string(&path).map_err(|error| AppError::Io {
        message: format!(
            "failed to read kanidm-admin context file '{}': {error}",
            path.display()
        ),
    })?;
    serde_json::from_str(&contents).map_err(|error| AppError::Json {
        message: format!(
            "failed to decode kanidm-admin context file '{}'",
            path.display()
        ),
        details: serde_json::json!({ "error": error.to_string() }),
    })
}

fn resolve_backend_timeout_seconds(override_value: Option<u64>) -> Result<u64, AppError> {
    let value = match override_value {
        Some(value) => value,
        None => match env::var(ENV_BACKEND_TIMEOUT_SECONDS) {
            Ok(raw) => raw.parse::<u64>().map_err(|error| AppError::Config {
                message: format!(
                    "invalid {ENV_BACKEND_TIMEOUT_SECONDS} value '{raw}': expected whole seconds ({error})"
                ),
            })?,
            Err(env::VarError::NotPresent) => DEFAULT_BACKEND_TIMEOUT_SECONDS,
            Err(env::VarError::NotUnicode(_)) => {
                return Err(AppError::Config {
                    message: format!("{ENV_BACKEND_TIMEOUT_SECONDS} must be valid UTF-8"),
                });
            }
        },
    };

    if !(MIN_BACKEND_TIMEOUT_SECONDS..=MAX_BACKEND_TIMEOUT_SECONDS).contains(&value) {
        return Err(AppError::Config {
            message: format!(
                "invalid backend timeout '{value}': expected {MIN_BACKEND_TIMEOUT_SECONDS}-{MAX_BACKEND_TIMEOUT_SECONDS} seconds"
            ),
        });
    }

    Ok(value)
}

fn find_repo_root_optional() -> Option<PathBuf> {
    let cwd = env::current_dir().ok()?;
    find_repo_root_from(&cwd)
}

fn find_repo_root_from(start: &Path) -> Option<PathBuf> {
    let mut current = Some(start);
    while let Some(path) = current {
        if path.join("vars.nix").is_file() {
            return Some(path.to_path_buf());
        }
        current = path.parent();
    }
    None
}

fn nix_repo_defaults(nix_bin: &OsString, repo_root: &Path) -> Result<RepoDefaults, AppError> {
    let repo_str = repo_root.to_string_lossy().to_string();
    let repo_literal = serde_json::to_string(&repo_str).map_err(|error| AppError::Json {
        message: "failed to encode repo path for nix eval".to_string(),
        details: serde_json::json!({ "error": error.to_string(), "repo_root": repo_str }),
    })?;
    let expr = format!(
        r#"let
  repo = {repo_literal};
  flake = builtins.getFlake repo;
  lib = flake.inputs.nixpkgs.lib;
  vars = import (builtins.toPath (repo + "/vars.nix")) {{ inherit lib; }};
  fileAccess = vars.fileAccess or {{}};
  backupAccess = vars.backupAccess or {{}};
  networkingPorts = vars.networking.ports or {{}};
  dataRoot = vars.dataRoot or "/mnt/data";
in {{
  serverUrl = vars.kanidmBaseUrl;
  adminName = vars.kanidmAdminUser;
  vaultwardenUrl = "https://passwords.${{vars.domain}}";
  sftpRuntime = {{
    sftpAccessGroup = fileAccess.sftpAccessGroup or "files-sftp-users";
    localSftpAccessGroup = fileAccess.localSftpAccessGroup or "files-local-sftp-users";
    webAccessGroup = fileAccess.webAccessGroup or "user-files";
    sharedAccessGroup = fileAccess.sharedAccessGroup or "files-shared-users";
    usbAccessGroup = fileAccess.usbAccessGroup or "usb-access";
    backupStorageAccessGroup = backupAccess.storageGroup or "admin-backups";
    sftpChrootBase = fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
    userSftpAuthorizedKeysDir = fileAccess.userSftpAuthorizedKeysDir or "/persist/appdata/files-sftp-authorized-keys";
    usersRoot = vars.usersRoot or "${{dataRoot}}/users";
    sharedRoot = vars.sharedRoot or "${{dataRoot}}/shared";
    usbRoot = vars.externalUsbMountRoot or "/mnt/external-usb";
    backupRoot = vars.backupRoot or "${{dataRoot}}/backups";
    sharedMountName = fileAccess.sharedMountName or "_Shared";
    usbMountName = fileAccess.usbMountName or "_USB";
    backupStorageMountName = backupAccess.storageMountName or "_Backups";
    filesSftpPort = networkingPorts.filesSftp or 2222;
    filesSftpSshdService = "files-sftp-sshd.service";
    kanidmUnixdService = "kanidm-unixd.service";
    posixGroupsService = "kanidm-files-posix-groups.service";
    userRootSyncService = "fileshare-user-root-sync.service";
    userRootBindTemplate = "files-sftp-user-root@.service";
    sharedBindTemplate = "files-shared-bindfs@.service";
    usbBindTemplate = "files-usb-bindfs@.service";
    backupBindTemplate = "files-backups-bindfs@.service";
  }};
}}"#
    );

    let output = run_nix_eval(nix_bin, &expr)?;

    if !output.status.success() {
        return Err(nix_eval_failed_error(
            repo_root,
            String::from_utf8_lossy(&output.stderr).trim(),
        ));
    }

    serde_json::from_slice(&output.stdout).map_err(|error| AppError::Json {
        message: "failed to decode nix-derived defaults".to_string(),
        details: serde_json::json!({
            "error": error.to_string(),
            "stdout": String::from_utf8_lossy(&output.stdout),
        }),
    })
}

fn nix_eval_failed_error(repo_root: &Path, stderr: &str) -> AppError {
    let missing_vars = stderr.contains("vars.nix") && stderr.contains("does not exist");
    let message = if missing_vars {
        format!(
            "Installed context points at {}, but {}/vars.nix does not exist.",
            repo_root.display(),
            repo_root.display()
        )
    } else {
        format!(
            "failed to derive defaults from vars.nix via nix eval for repo '{}'",
            repo_root.display()
        )
    };
    AppError::Verification {
        message,
        details: serde_json::json!({
            "failure_kind": "context_eval_failed",
            "repo_root": repo_root.display().to_string(),
            "stderr": stderr,
            "diagnostic": stderr,
            "next_actions": [
                "Run the guarded rebuild/deploy helper so /etc/kanidm-admin/context.json is installed.",
                "If running from a checkout, pass --repo-root or set KANIDM_ADMIN_REPO_ROOT to the repo containing vars.nix.",
                "Set KANIDM_ADMIN_CONTEXT_FILE to a valid context JSON file when running outside the repo."
            ],
        }),
    }
}

fn run_nix_eval(nix_bin: &OsString, expr: &str) -> Result<std::process::Output, AppError> {
    run_nix_eval_with_timeout(nix_bin, expr, NIX_EVAL_TIMEOUT)
}

fn run_nix_eval_with_timeout(
    nix_bin: &OsString,
    expr: &str,
    timeout: Duration,
) -> Result<std::process::Output, AppError> {
    let args = vec![
        "eval".to_string(),
        "--extra-experimental-features".to_string(),
        "nix-command".to_string(),
        "--extra-experimental-features".to_string(),
        "flakes".to_string(),
        "--json".to_string(),
        "--impure".to_string(),
        "--expr".to_string(),
        expr.to_string(),
    ];
    let mut child = Command::new(nix_bin)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AppError::MissingDependency {
                    binary: nix_bin.to_string_lossy().to_string(),
                }
            } else {
                AppError::Io {
                    message: format!("failed to execute nix eval: {error}"),
                }
            }
        })?;

    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child.wait_with_output().map_err(|error| AppError::Io {
                    message: format!("failed to collect nix eval output: {error}"),
                });
            }
            Ok(None) if start.elapsed() >= timeout => {
                let _ = child.kill();
                let output = child.wait_with_output().map_err(|error| AppError::Io {
                    message: format!("failed to collect timed-out nix eval output: {error}"),
                })?;
                return Err(AppError::BackendTimeout {
                    message: format!(
                        "failed to derive defaults from vars.nix via nix eval: command timed out after {} second(s)",
                        timeout.as_secs()
                    ),
                    details: serde_json::json!({
                        "program": nix_bin.to_string_lossy(),
                        "args": args,
                        "elapsed_ms": start.elapsed().as_millis(),
                        "stdout": String::from_utf8_lossy(&output.stdout),
                        "stderr": String::from_utf8_lossy(&output.stderr),
                    }),
                });
            }
            Ok(None) => sleep(POLL_INTERVAL),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(AppError::Io {
                    message: format!("failed while waiting on nix eval: {error}"),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, sync::Mutex};

    use tempfile::tempdir;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn restore_env_var(name: &str, original: Option<std::ffi::OsString>) {
        match original {
            Some(value) => env::set_var(name, value),
            None => env::remove_var(name),
        }
    }

    fn write_script(path: &Path, body: &str) {
        let shell = std::process::Command::new("bash")
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

    #[test]
    fn flags_override_env() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_server = env::var_os(ENV_SERVER_URL);
        let original_admin = env::var_os(ENV_ADMIN_NAME);
        env::set_var(ENV_SERVER_URL, "https://env.example.test");
        env::set_var(ENV_ADMIN_NAME, "env-admin");

        let resolved = resolve_context(ContextOverrides {
            repo_root: None,
            server_url: Some("https://flag.example.test".to_string()),
            admin_name: Some("flag-admin".to_string()),
            kanidm_bin: None,
            nix_bin: None,
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            backend_timeout_seconds: None,
        })
        .expect("resolve context");

        assert_eq!(resolved.server_url, "https://flag.example.test");
        assert_eq!(resolved.admin_name, "flag-admin");

        restore_env_var(ENV_SERVER_URL, original_server);
        restore_env_var(ENV_ADMIN_NAME, original_admin);
    }

    #[test]
    fn resolves_defaults_from_nix_once_repo_root_is_known() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempdir().expect("tempdir");
        fs::write(temp.path().join("vars.nix"), "{}").expect("vars");
        let nix = temp.path().join("nix-stub.sh");
        write_script(
            &nix,
            r#"#!/usr/bin/env bash
case " $* " in
  *" eval --extra-experimental-features nix-command --extra-experimental-features flakes "*) ;;
  *) echo "missing explicit nix feature flags: $*" >&2; exit 1 ;;
esac
printf '{"serverUrl":"https://id.example.test","adminName":"admindsaw","vaultwardenUrl":"https://passwords.example.test","sftpRuntime":{"sftpAccessGroup":"renamed-sftp-users","localSftpAccessGroup":"renamed-local-sftp-users","webAccessGroup":"renamed-web-users","sharedAccessGroup":"renamed-shared-users","usbAccessGroup":"renamed-usb-users","backupStorageAccessGroup":"renamed-backup-users","sftpChrootBase":"/srv/renamed-chroots","usersRoot":"/srv/renamed-users","sharedRoot":"/srv/renamed-shared","usbRoot":"/srv/renamed-usb","backupRoot":"/srv/renamed-backups","sharedMountName":"SharedRenamed","usbMountName":"UsbRenamed","backupStorageMountName":"BackupsRenamed","filesSftpPort":2202,"filesSftpSshdService":"renamed-sftp.service","kanidmUnixdService":"renamed-unixd.service","posixGroupsService":"renamed-posix.service","userRootSyncService":"renamed-root-sync.service","userRootBindTemplate":"renamed-sftp-user-root@.service","sharedBindTemplate":"renamed-shared@.service","usbBindTemplate":"renamed-usb@.service","backupBindTemplate":"renamed-backup@.service"}}'
"#,
        );

        let resolved = resolve_context(ContextOverrides {
            repo_root: Some(temp.path().to_path_buf()),
            server_url: None,
            admin_name: None,
            kanidm_bin: None,
            nix_bin: Some(nix.into_os_string()),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            backend_timeout_seconds: None,
        })
        .expect("resolve defaults");

        assert_eq!(resolved.server_url, "https://id.example.test");
        assert_eq!(resolved.admin_name, "admindsaw");
        assert_eq!(
            resolved.vaultwarden_url.as_deref(),
            Some("https://passwords.example.test")
        );
        assert_eq!(
            resolved.sftp_runtime.sftp_access_group,
            "renamed-sftp-users"
        );
        assert_eq!(resolved.sftp_runtime.files_sftp_port, 2202);
        assert_eq!(
            resolved.sftp_runtime.files_sftp_sshd_service,
            "renamed-sftp.service"
        );
        assert_eq!(
            resolved.sftp_runtime.backup_storage_access_group,
            "renamed-backup-users"
        );
        assert_eq!(resolved.sftp_runtime.usb_root, "/srv/renamed-usb");
    }

    #[test]
    fn resolves_vaultwarden_values_from_environment() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_url = env::var_os(ENV_VAULTWARDEN_URL);
        let original_token = env::var_os(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE);
        let temp = tempdir().expect("tempdir");
        let token_path = temp.path().join("vaultwarden-admin-token");

        env::set_var(ENV_VAULTWARDEN_URL, "https://passwords.example.test");
        env::set_var(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE, &token_path);

        let resolved = resolve_context(ContextOverrides {
            repo_root: None,
            server_url: Some("https://id.example.test".to_string()),
            admin_name: Some("admindsaw".to_string()),
            kanidm_bin: None,
            nix_bin: None,
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            backend_timeout_seconds: None,
        })
        .expect("resolve");

        assert_eq!(
            resolved.vaultwarden_url.as_deref(),
            Some("https://passwords.example.test")
        );
        assert_eq!(
            resolved.vaultwarden_admin_token_file.as_deref(),
            Some(token_path.as_path())
        );

        restore_env_var(ENV_VAULTWARDEN_URL, original_url);
        restore_env_var(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE, original_token);
    }

    #[test]
    fn resolves_installed_context_without_source_repo() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_context_file = env::var_os(ENV_CONTEXT_FILE);
        let original_repo = env::var_os(ENV_REPO_ROOT);
        let original_server = env::var_os(ENV_SERVER_URL);
        let original_admin = env::var_os(ENV_ADMIN_NAME);
        let temp = tempdir().expect("tempdir");
        let context_file = temp.path().join("context.json");
        let missing_repo = temp.path().join("missing-repo");
        let noisy_nix = temp.path().join("nix-should-not-run.sh");
        write_script(
            &noisy_nix,
            r#"#!/usr/bin/env bash
echo "nix should not run when installed context is available" >&2
exit 1
"#,
        );
        fs::write(
            &context_file,
            r#"{
  "serverUrl": "https://id.example.test",
  "adminName": "admindsaw",
  "vaultwardenUrl": "https://passwords.example.test",
  "vaultwardenAdminTokenFile": "/run/agenix/vaultwardenAdminToken",
  "sftpRuntime": {
    "sftpAccessGroup": "installed-sftp-users",
    "filesSftpPort": 2223
  }
}"#,
        )
        .expect("context file");

        env::set_var(ENV_CONTEXT_FILE, &context_file);
        env::set_var(ENV_REPO_ROOT, &missing_repo);
        env::remove_var(ENV_SERVER_URL);
        env::remove_var(ENV_ADMIN_NAME);

        let resolved = resolve_context(ContextOverrides {
            repo_root: None,
            server_url: None,
            admin_name: None,
            kanidm_bin: None,
            nix_bin: Some(noisy_nix.into_os_string()),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            backend_timeout_seconds: None,
        })
        .expect("resolve from installed context");

        assert_eq!(resolved.server_url, "https://id.example.test");
        assert_eq!(resolved.admin_name, "admindsaw");
        assert_eq!(
            resolved.vaultwarden_admin_token_file.as_deref(),
            Some(Path::new("/run/agenix/vaultwardenAdminToken"))
        );
        assert_eq!(
            resolved.sftp_runtime.sftp_access_group,
            "installed-sftp-users"
        );
        assert_eq!(resolved.sftp_runtime.files_sftp_port, 2223);
        assert_eq!(
            resolved.sftp_runtime.files_sftp_sshd_service,
            "files-sftp-sshd.service"
        );

        restore_env_var(ENV_CONTEXT_FILE, original_context_file);
        restore_env_var(ENV_REPO_ROOT, original_repo);
        restore_env_var(ENV_SERVER_URL, original_server);
        restore_env_var(ENV_ADMIN_NAME, original_admin);
    }

    #[test]
    fn env_server_and_admin_do_not_require_env_repo_root() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_context_file = env::var_os(ENV_CONTEXT_FILE);
        let original_repo = env::var_os(ENV_REPO_ROOT);
        let original_server = env::var_os(ENV_SERVER_URL);
        let original_admin = env::var_os(ENV_ADMIN_NAME);
        let temp = tempdir().expect("tempdir");
        let missing_repo = temp.path().join("missing-repo");
        let noisy_nix = temp.path().join("nix-should-not-run.sh");
        write_script(
            &noisy_nix,
            r#"#!/usr/bin/env bash
echo "nix should not run when server and admin are already configured" >&2
exit 1
"#,
        );

        env::remove_var(ENV_CONTEXT_FILE);
        env::set_var(ENV_REPO_ROOT, &missing_repo);
        env::set_var(ENV_SERVER_URL, "https://id.example.test");
        env::set_var(ENV_ADMIN_NAME, "admindsaw");

        let resolved = resolve_context(ContextOverrides {
            repo_root: None,
            server_url: None,
            admin_name: None,
            kanidm_bin: None,
            nix_bin: Some(noisy_nix.into_os_string()),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            backend_timeout_seconds: None,
        })
        .expect("resolve from env context");

        assert_eq!(resolved.server_url, "https://id.example.test");
        assert_eq!(resolved.admin_name, "admindsaw");
        assert_eq!(
            resolved.sftp_runtime,
            SftpRuntimeConfig::default(),
            "missing env repo root should fall back to built-in runtime defaults"
        );

        restore_env_var(ENV_CONTEXT_FILE, original_context_file);
        restore_env_var(ENV_REPO_ROOT, original_repo);
        restore_env_var(ENV_SERVER_URL, original_server);
        restore_env_var(ENV_ADMIN_NAME, original_admin);
    }

    #[test]
    fn nix_eval_timeout_is_reported() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempdir().expect("tempdir");
        let script = temp.path().join("sleep.sh");
        let sleep_bin = std::process::Command::new("bash")
            .args(["-lc", "command -v sleep"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .map(|stdout| stdout.trim().to_string())
            .filter(|stdout| !stdout.is_empty())
            .unwrap_or_else(|| "/bin/sleep".to_string());
        write_script(
            &script,
            &format!(
                r#"#!/usr/bin/env bash
{} 1
"#,
                sleep_bin
            ),
        );

        let error =
            run_nix_eval_with_timeout(&script.into_os_string(), "1", Duration::from_millis(10))
                .expect_err("timeout");

        assert!(matches!(error, AppError::BackendTimeout { .. }));
    }

    #[test]
    fn missing_vars_nix_eval_error_is_actionable() {
        let error = nix_eval_failed_error(
            Path::new("/etc/nixos"),
            "error: path '/etc/nixos/vars.nix' does not exist",
        );

        match &error {
            AppError::Verification { details, .. } => {
                assert_eq!(details["failure_kind"], "context_eval_failed");
            }
            other => panic!("unexpected error: {other:?}"),
        }
        let rendered = error.human_message();
        assert!(rendered.contains(
            "Installed context points at /etc/nixos, but /etc/nixos/vars.nix does not exist."
        ));
        assert!(rendered.contains("KANIDM_ADMIN_CONTEXT_FILE"));
    }
}
