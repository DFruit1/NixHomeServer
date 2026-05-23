use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::Deserialize;

use crate::AppError;

pub const ENV_REPO_ROOT: &str = "KANIDM_ADMIN_REPO_ROOT";
pub const ENV_SERVER_URL: &str = "KANIDM_ADMIN_SERVER_URL";
pub const ENV_ADMIN_NAME: &str = "KANIDM_ADMIN_NAME";
pub const ENV_KANIDM_BIN: &str = "KANIDM_ADMIN_KANIDM_BIN";
pub const ENV_NIX_BIN: &str = "KANIDM_ADMIN_NIX_BIN";
pub const ENV_VAULTWARDEN_URL: &str = "KANIDM_ADMIN_VAULTWARDEN_URL";
pub const ENV_VAULTWARDEN_ADMIN_TOKEN_FILE: &str = "KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE";

const NIX_EVAL_TIMEOUT: Duration = Duration::from_secs(20);
const POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextOverrides {
    pub repo_root: Option<PathBuf>,
    pub server_url: Option<String>,
    pub admin_name: Option<String>,
    pub kanidm_bin: Option<OsString>,
    pub nix_bin: Option<OsString>,
    pub vaultwarden_url: Option<String>,
    pub vaultwarden_admin_token_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedContext {
    pub repo_root: Option<PathBuf>,
    pub server_url: String,
    pub admin_name: String,
    pub kanidm_bin: OsString,
    pub vaultwarden_url: Option<String>,
    pub vaultwarden_admin_token_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct RepoDefaults {
    #[serde(rename = "serverUrl")]
    server_url: String,
    #[serde(rename = "adminName")]
    admin_name: String,
    #[serde(rename = "vaultwardenUrl")]
    vaultwarden_url: Option<String>,
}

pub fn resolve_context(overrides: ContextOverrides) -> Result<ResolvedContext, AppError> {
    let repo_root = overrides
        .repo_root
        .or_else(|| env::var_os(ENV_REPO_ROOT).map(PathBuf::from));
    let server_url = overrides
        .server_url
        .or_else(|| env::var(ENV_SERVER_URL).ok());
    let admin_name = overrides
        .admin_name
        .or_else(|| env::var(ENV_ADMIN_NAME).ok());
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
        .or_else(|| env::var(ENV_VAULTWARDEN_URL).ok());
    let vaultwarden_admin_token_file = overrides
        .vaultwarden_admin_token_file
        .or_else(|| env::var_os(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE).map(PathBuf::from));

    if let (Some(server_url), Some(admin_name)) = (&server_url, &admin_name) {
        return Ok(ResolvedContext {
            repo_root: repo_root.or_else(find_repo_root_optional),
            server_url: server_url.clone(),
            admin_name: admin_name.clone(),
            kanidm_bin,
            vaultwarden_url,
            vaultwarden_admin_token_file,
        });
    }

    let repo_root = match repo_root.or_else(find_repo_root_optional) {
        Some(path) => path,
        None => {
            return Err(AppError::Config {
                message: format!(
                    "could not resolve repository root containing vars.nix; pass --repo-root or set {ENV_REPO_ROOT}"
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
        vaultwarden_admin_token_file,
    })
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
        "let repo = {repo_literal}; flake = builtins.getFlake repo; vars = import (builtins.toPath (repo + \"/vars.nix\")) {{ lib = flake.inputs.nixpkgs.lib; }}; in {{ serverUrl = vars.kanidmBaseUrl; adminName = vars.kanidmAdminUser; vaultwardenUrl = \"https://passwords.${{vars.domain}}\"; }}"
    );

    let output = run_nix_eval(nix_bin, &expr)?;

    if !output.status.success() {
        return Err(AppError::Config {
            message: format!(
                "failed to derive defaults from vars.nix via nix eval\n\nstderr:\n{}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }

    serde_json::from_slice(&output.stdout).map_err(|error| AppError::Json {
        message: "failed to decode nix-derived defaults".to_string(),
        details: serde_json::json!({
            "error": error.to_string(),
            "stdout": String::from_utf8_lossy(&output.stdout),
        }),
    })
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
        })
        .expect("resolve context");

        assert_eq!(resolved.server_url, "https://flag.example.test");
        assert_eq!(resolved.admin_name, "flag-admin");

        match original_server {
            Some(value) => env::set_var(ENV_SERVER_URL, value),
            None => env::remove_var(ENV_SERVER_URL),
        }
        match original_admin {
            Some(value) => env::set_var(ENV_ADMIN_NAME, value),
            None => env::remove_var(ENV_ADMIN_NAME),
        }
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
printf '{"serverUrl":"https://id.example.test","adminName":"admindsaw","vaultwardenUrl":"https://passwords.example.test"}'
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
        })
        .expect("resolve defaults");

        assert_eq!(resolved.server_url, "https://id.example.test");
        assert_eq!(resolved.admin_name, "admindsaw");
        assert_eq!(
            resolved.vaultwarden_url.as_deref(),
            Some("https://passwords.example.test")
        );
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

        match original_url {
            Some(value) => env::set_var(ENV_VAULTWARDEN_URL, value),
            None => env::remove_var(ENV_VAULTWARDEN_URL),
        }
        match original_token {
            Some(value) => env::set_var(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE, value),
            None => env::remove_var(ENV_VAULTWARDEN_ADMIN_TOKEN_FILE),
        }
    }

    #[test]
    fn nix_eval_timeout_is_reported() {
        let temp = tempdir().expect("tempdir");
        let script = temp.path().join("sleep.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
sleep 1
"#,
        );

        let error =
            run_nix_eval_with_timeout(&script.into_os_string(), "1", Duration::from_millis(10))
                .expect_err("timeout");

        assert!(matches!(error, AppError::BackendTimeout { .. }));
    }
}
