use std::{
    collections::BTreeSet,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use clap::{Parser, Subcommand};
use kanidm_admin::{validation::validate_account_id, AppError};

const DEFAULT_ALLOWED_SECRET_PATHS_FILE: &str = "/etc/kanidm-admin-root/allowed-secret-paths";
const ENV_ALLOWED_SECRET_PATHS_FILE: &str = "KANIDM_ADMIN_ROOT_ALLOWED_SECRET_PATHS_FILE";

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
    let mut stdin_payload = String::new();
    io::stdin()
        .read_to_string(&mut stdin_payload)
        .map_err(|error| AppError::Io {
            message: format!("failed to read password from stdin: {error}"),
        })?;
    let stdin_payload = stdin_payload.trim_end_matches(['\r', '\n']);
    if stdin_payload.is_empty() {
        return Err(AppError::Config {
            message: "password stdin must not be empty".to_string(),
        });
    }

    let chpasswd_payload = if let Some((stdin_user, password)) = stdin_payload.split_once(':') {
        if stdin_user != username {
            return Err(AppError::Config {
                message: "chpasswd stdin username does not match requested account".to_string(),
            });
        }
        format!("{stdin_user}:{password}\n")
    } else {
        format!("{username}:{stdin_payload}\n")
    };

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
    let path = std::env::var_os(ENV_ALLOWED_SECRET_PATHS_FILE)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_ALLOWED_SECRET_PATHS_FILE));
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
    use super::*;

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
