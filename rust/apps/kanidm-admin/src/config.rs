use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
};

use serde::Deserialize;

use crate::AppError;

pub const ENV_REPO_ROOT: &str = "KANIDM_ADMIN_REPO_ROOT";
pub const ENV_SERVER_URL: &str = "KANIDM_ADMIN_SERVER_URL";
pub const ENV_ADMIN_NAME: &str = "KANIDM_ADMIN_NAME";
pub const ENV_KANIDM_BIN: &str = "KANIDM_ADMIN_KANIDM_BIN";
pub const ENV_NIX_BIN: &str = "KANIDM_ADMIN_NIX_BIN";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigOverrides {
    pub repo_root: Option<PathBuf>,
    pub server_url: Option<String>,
    pub admin_name: Option<String>,
    pub kanidm_bin: Option<OsString>,
    pub nix_bin: Option<OsString>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedConfig {
    pub repo_root: Option<PathBuf>,
    pub server_url: String,
    pub admin_name: String,
    pub kanidm_bin: OsString,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct RepoDefaults {
    #[serde(rename = "serverUrl")]
    server_url: String,
    #[serde(rename = "adminName")]
    admin_name: String,
}

pub fn resolve_config(overrides: ConfigOverrides) -> Result<ResolvedConfig, AppError> {
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

    if let (Some(server_url), Some(admin_name)) = (&server_url, &admin_name) {
        return Ok(ResolvedConfig {
            repo_root: repo_root.or_else(find_repo_root_optional),
            server_url: server_url.clone(),
            admin_name: admin_name.clone(),
            kanidm_bin,
        });
    }

    let repo_root = match repo_root.or_else(find_repo_root_optional) {
        Some(path) => path,
        None => {
            return Err(AppError::Config {
                message: format!(
                    "could not resolve repository root containing vars.nix; pass --repo-root or set {ENV_REPO_ROOT}"
                ),
            })
        }
    };

    let defaults = nix_repo_defaults(&nix_bin, &repo_root)?;
    Ok(ResolvedConfig {
        repo_root: Some(repo_root),
        server_url: server_url.unwrap_or(defaults.server_url),
        admin_name: admin_name.unwrap_or(defaults.admin_name),
        kanidm_bin,
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
        "let repo = {repo_literal}; flake = builtins.getFlake repo; vars = import (builtins.toPath (repo + \"/vars.nix\")) {{ lib = flake.inputs.nixpkgs.lib; }}; in {{ serverUrl = vars.kanidmBaseUrl; adminName = vars.kanidmAdminUser; }}"
    );

    let output = Command::new(nix_bin)
        .args(["eval", "--json", "--impure", "--expr", &expr])
        .output()
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

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, sync::Mutex};

    use tempfile::tempdir;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn write_script(path: &Path, body: &str) {
        fs::write(path, body).expect("write script");
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

        let resolved = resolve_config(ConfigOverrides {
            repo_root: None,
            server_url: Some("https://flag.example.test".to_string()),
            admin_name: Some("flag-admin".to_string()),
            kanidm_bin: None,
            nix_bin: None,
        })
        .expect("resolve config");

        assert_eq!(resolved.server_url, "https://flag.example.test");
        assert_eq!(resolved.admin_name, "flag-admin");

        restore_env(ENV_SERVER_URL, original_server);
        restore_env(ENV_ADMIN_NAME, original_admin);
    }

    #[test]
    fn env_overrides_repo_defaults() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_server = env::var_os(ENV_SERVER_URL);
        let original_admin = env::var_os(ENV_ADMIN_NAME);
        env::set_var(ENV_SERVER_URL, "https://env.example.test");
        env::set_var(ENV_ADMIN_NAME, "env-admin");

        let resolved = resolve_config(ConfigOverrides {
            repo_root: Some(PathBuf::from("/tmp/does-not-matter")),
            server_url: None,
            admin_name: None,
            kanidm_bin: None,
            nix_bin: None,
        })
        .expect("resolve config");

        assert_eq!(resolved.server_url, "https://env.example.test");
        assert_eq!(resolved.admin_name, "env-admin");

        restore_env(ENV_SERVER_URL, original_server);
        restore_env(ENV_ADMIN_NAME, original_admin);
    }

    #[test]
    fn resolves_defaults_from_nix_once_repo_root_is_known() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let original_server = env::var_os(ENV_SERVER_URL);
        let original_admin = env::var_os(ENV_ADMIN_NAME);
        env::remove_var(ENV_SERVER_URL);
        env::remove_var(ENV_ADMIN_NAME);

        let temp = tempdir().expect("tempdir");
        fs::write(temp.path().join("vars.nix"), "{}").expect("vars");
        let nix_script = temp.path().join("fake-nix.sh");
        write_script(
            &nix_script,
            r#"#!/usr/bin/env bash
printf '{"serverUrl":"https://id.example.test","adminName":"admindsaw"}'
"#,
        );

        let resolved = resolve_config(ConfigOverrides {
            repo_root: Some(temp.path().to_path_buf()),
            server_url: None,
            admin_name: None,
            kanidm_bin: None,
            nix_bin: Some(nix_script.into_os_string()),
        })
        .expect("resolve defaults");

        assert_eq!(resolved.server_url, "https://id.example.test");
        assert_eq!(resolved.admin_name, "admindsaw");

        restore_env(ENV_SERVER_URL, original_server);
        restore_env(ENV_ADMIN_NAME, original_admin);
    }

    fn restore_env(key: &str, value: Option<OsString>) {
        match value {
            Some(value) => env::set_var(key, value),
            None => env::remove_var(key),
        }
    }
}
