use std::{
    collections::BTreeSet,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use clap::{Parser, Subcommand};
use kanidm_admin::{validation::validate_account_id, AppError};
use zeroize::{Zeroize, Zeroizing};

const DEFAULT_ALLOWED_SECRET_PATHS_FILE: &str = "/etc/kanidm-admin-root/allowed-secret-paths";
#[cfg(test)]
const ENV_ALLOWED_SECRET_PATHS_FILE: &str = "KANIDM_ADMIN_ROOT_ALLOWED_SECRET_PATHS_FILE";
const DEFAULT_CHPASSWD_GROUP: &str = "files-local-sftp-users";
const DEFAULT_CHPASSWD_GROUP_FILE: &str = "/etc/kanidm-admin-root/chpasswd-group";
#[cfg(test)]
const ENV_CHPASSWD_GROUP_FILE: &str = "KANIDM_ADMIN_ROOT_CHPASSWD_GROUP_FILE";

const ALLOWED_UNITS: &[&str] = &[
    "kanidm-files-posix-groups.service",
    "fileshare-user-root-sync.service",
    "jellyfin.service",
    "jellyfin-password-reconcile.service",
];

#[derive(Debug, Parser)]
#[command(name = "kanidm-admin-root")]
#[command(about = "Least-privilege root helper for kanidm-admin local runtime actions.")]
struct Cli {
    #[command(subcommand)]
    command: RootCommand,
}

#[derive(Debug, Subcommand)]
enum RootCommand {
    #[command(about = "Start an allowlisted systemd unit.")]
    SystemdStart { unit: String },
    #[command(about = "Set a local Unix password for an allowlisted account id through chpasswd.")]
    Chpasswd { username: String },
    #[command(about = "Print an allowlisted secret file to stdout.")]
    ReadSecret { path: PathBuf },
}

fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("{}", error.human_message());
        std::process::exit(error.exit_code());
    }
}

fn run(cli: Cli) -> Result<(), AppError> {
    match cli.command {
        RootCommand::SystemdStart { unit } => systemd_start(&unit),
        RootCommand::Chpasswd { username } => chpasswd(&username),
        RootCommand::ReadSecret { path } => read_secret(&path),
    }
}

fn systemd_start(unit: &str) -> Result<(), AppError> {
    if !ALLOWED_UNITS.contains(&unit) {
        return Err(AppError::Config {
            message: format!("unit '{unit}' is not allowlisted for kanidm-admin-root"),
        });
    }

    let output = Command::new("systemctl")
        .args(["start", unit])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| AppError::Io {
            message: format!("failed to execute systemctl: {error}"),
        })?;

    if !output.status.success() {
        return Err(AppError::Io {
            message: format!(
                "systemctl start '{}' failed: {}",
                unit,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }

    Ok(())
}

fn chpasswd(username: &str) -> Result<(), AppError> {
    let username = validate_account_id(username)?;
    ensure_chpasswd_target_allowed(&username)?;
    let mut stdin_payload = String::new();
    io::stdin()
        .read_to_string(&mut stdin_payload)
        .map_err(|error| AppError::Io {
            message: format!("failed to read password from stdin: {error}"),
        })?;
    let stdin_payload = {
        let trimmed = Zeroizing::new(stdin_payload.trim_end_matches(['\r', '\n']).to_string());
        stdin_payload.zeroize();
        trimmed
    };
    if stdin_payload.is_empty() {
        return Err(AppError::Config {
            message: "password stdin must not be empty".to_string(),
        });
    }

    let chpasswd_payload = Zeroizing::new(normalize_chpasswd_payload(&username, &stdin_payload)?);

    let mut child = Command::new("chpasswd")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| AppError::Io {
            message: format!("failed to execute chpasswd: {error}"),
        })?;
    child
        .stdin
        .take()
        .ok_or_else(|| AppError::Io {
            message: "failed to open chpasswd stdin".to_string(),
        })?
        .write_all(chpasswd_payload.as_bytes())
        .map_err(|error| AppError::Io {
            message: format!("failed to write chpasswd stdin: {error}"),
        })?;
    let output = child.wait_with_output().map_err(|error| AppError::Io {
        message: format!("failed to wait for chpasswd: {error}"),
    })?;
    if !output.status.success() {
        return Err(AppError::Io {
            message: format!(
                "chpasswd failed for '{}': {}",
                username,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }

    Ok(())
}

fn ensure_chpasswd_target_allowed(username: &str) -> Result<(), AppError> {
    let group = load_chpasswd_group()?;
    let passwd = command_output("getent", &["passwd", username])?;
    let groups = command_output("id", &["-nG", username])?;
    chpasswd_target_allowed(username, &group, &passwd, &groups).map(|_| ())
}

fn load_chpasswd_group() -> Result<String, AppError> {
    let path = chpasswd_group_file();
    match fs::read_to_string(&path) {
        Ok(contents) => {
            let group = contents.trim();
            if group.is_empty() {
                return Err(AppError::Config {
                    message: format!(
                        "kanidm-admin-root chpasswd group file '{}' is empty",
                        path.display()
                    ),
                });
            }
            validate_account_id(group)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(DEFAULT_CHPASSWD_GROUP.to_string())
        }
        Err(error) => Err(AppError::Io {
            message: format!(
                "failed to read kanidm-admin-root chpasswd group file '{}': {error}",
                path.display()
            ),
        }),
    }
}

fn command_output(program: &str, args: &[&str]) -> Result<String, AppError> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| AppError::Io {
            message: format!("failed to execute {program}: {error}"),
        })?;
    if !output.status.success() {
        return Err(AppError::Config {
            message: format!(
                "{} {} did not resolve an allowlisted chpasswd target: {}",
                program,
                args.join(" "),
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn chpasswd_target_allowed(
    username: &str,
    group: &str,
    passwd_output: &str,
    groups_output: &str,
) -> Result<(), AppError> {
    let uid = passwd_uid(passwd_output).ok_or_else(|| AppError::Config {
        message: format!("getent passwd did not return a parseable UID for '{username}'"),
    })?;
    if uid == 0 {
        return Err(AppError::Config {
            message: format!("refusing to set a local password for root account '{username}'"),
        });
    }
    if !groups_output
        .split_whitespace()
        .any(|candidate| candidate == group)
    {
        return Err(AppError::Config {
            message: format!(
                "local account '{username}' is not a member of required chpasswd group '{group}'"
            ),
        });
    }
    Ok(())
}

fn passwd_uid(passwd_output: &str) -> Option<u32> {
    passwd_output
        .lines()
        .next()?
        .split(':')
        .nth(2)?
        .parse::<u32>()
        .ok()
}

fn normalize_chpasswd_payload(username: &str, stdin_payload: &str) -> Result<String, AppError> {
    let stdin_payload = stdin_payload.trim_end_matches(['\r', '\n']);
    if stdin_payload.is_empty() {
        return Err(AppError::Config {
            message: "password stdin must not be empty".to_string(),
        });
    }

    if let Some((stdin_user, password)) = stdin_payload.split_once(':') {
        if stdin_user != username {
            return Err(AppError::Config {
                message: "chpasswd stdin username does not match requested account".to_string(),
            });
        }
        Ok(format!("{stdin_user}:{password}\n"))
    } else {
        Ok(format!("{username}:{stdin_payload}\n"))
    }
}

fn read_secret(path: &Path) -> Result<(), AppError> {
    let allowed_paths = load_allowed_secret_paths()?;
    if !path_is_allowed(path, &allowed_paths) {
        return Err(AppError::Config {
            message: format!(
                "secret path '{}' is not allowlisted for kanidm-admin-root",
                path.display()
            ),
        });
    }
    let contents = fs::read(path).map_err(|error| AppError::Io {
        message: format!("failed to read secret file '{}': {error}", path.display()),
    })?;
    io::stdout()
        .write_all(&contents)
        .map_err(|error| AppError::Io {
            message: format!("failed to write secret to stdout: {error}"),
        })
}

fn load_allowed_secret_paths() -> Result<BTreeSet<PathBuf>, AppError> {
    let path = allowed_secret_paths_file();
    let contents = fs::read_to_string(&path).map_err(|error| AppError::Io {
        message: format!(
            "failed to read kanidm-admin-root allowed secret path file '{}': {error}",
            path.display()
        ),
    })?;
    Ok(contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(PathBuf::from)
        .collect())
}

fn allowed_secret_paths_file() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = std::env::var_os(ENV_ALLOWED_SECRET_PATHS_FILE) {
        return PathBuf::from(path);
    }
    PathBuf::from(DEFAULT_ALLOWED_SECRET_PATHS_FILE)
}

fn chpasswd_group_file() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = std::env::var_os(ENV_CHPASSWD_GROUP_FILE) {
        return PathBuf::from(path);
    }
    PathBuf::from(DEFAULT_CHPASSWD_GROUP_FILE)
}

fn path_is_allowed(path: &Path, allowed_paths: &BTreeSet<PathBuf>) -> bool {
    if allowed_paths.contains(path) {
        return true;
    }
    let Ok(canonical_path) = fs::canonicalize(path) else {
        return false;
    };
    allowed_paths.iter().any(|allowed| {
        allowed == path
            || fs::canonicalize(allowed)
                .ok()
                .is_some_and(|canonical_allowed| canonical_allowed == canonical_path)
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn rejects_unknown_units() {
        let error = systemd_start("not-allowed.service").expect_err("unknown unit");
        assert!(error.to_string().contains("not allowlisted"));
    }

    #[test]
    fn rejects_invalid_usernames_before_chpasswd() {
        let error = chpasswd("../bad").expect_err("invalid username");
        assert!(matches!(error, AppError::Config { .. }));
    }

    #[test]
    fn allows_bridge_group_chpasswd_target() {
        chpasswd_target_allowed(
            "alice",
            "files-local-sftp-users",
            "alice:x:1000:100:Alice:/home/alice:/run/current-system/sw/bin/bash\n",
            "users files-local-sftp-users",
        )
        .expect("target allowed");
    }

    #[test]
    fn rejects_root_chpasswd_target() {
        let error = chpasswd_target_allowed(
            "root",
            "files-local-sftp-users",
            "root:x:0:0:System administrator:/root:/run/current-system/sw/bin/bash\n",
            "root files-local-sftp-users",
        )
        .expect_err("root rejected");
        assert!(error.to_string().contains("root account"));
    }

    #[test]
    fn rejects_chpasswd_target_without_bridge_group() {
        let error = chpasswd_target_allowed(
            "alice",
            "files-local-sftp-users",
            "alice:x:1000:100:Alice:/home/alice:/run/current-system/sw/bin/bash\n",
            "users wheel",
        )
        .expect_err("group rejected");
        assert!(error.to_string().contains("required chpasswd group"));
    }

    #[test]
    fn rejects_unknown_chpasswd_target() {
        let error = chpasswd_target_allowed("alice", "files-local-sftp-users", "", "users")
            .expect_err("unknown user rejected");
        assert!(error.to_string().contains("parseable UID"));
    }

    #[test]
    fn loads_chpasswd_group_from_root_helper_config_file() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original = std::env::var_os(ENV_CHPASSWD_GROUP_FILE);
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("chpasswd-group");
        fs::write(&path, "custom-local-sftp\n").expect("group file");
        std::env::set_var(ENV_CHPASSWD_GROUP_FILE, &path);

        let group = load_chpasswd_group().expect("load group");

        assert_eq!(group, "custom-local-sftp");
        match original {
            Some(value) => std::env::set_var(ENV_CHPASSWD_GROUP_FILE, value),
            None => std::env::remove_var(ENV_CHPASSWD_GROUP_FILE),
        }
    }

    #[test]
    fn rejects_chpasswd_stdin_username_mismatch() {
        let error = normalize_chpasswd_payload("alice", "bob:secret\n")
            .expect_err("stdin username rejected");
        assert!(error.to_string().contains("does not match"));
    }

    #[test]
    fn allowed_secret_paths_require_exact_or_canonical_match() {
        let dir = tempfile::tempdir().expect("tempdir");
        let secret = dir.path().join("secret");
        fs::write(&secret, "value").expect("secret");
        let symlink = dir.path().join("secret-link");
        std::os::unix::fs::symlink(&secret, &symlink).expect("symlink");
        let allowed = BTreeSet::from([secret]);

        assert!(path_is_allowed(&symlink, &allowed));
        assert!(!path_is_allowed(&dir.path().join("other"), &allowed));
    }
}
