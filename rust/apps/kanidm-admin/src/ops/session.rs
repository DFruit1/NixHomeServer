use std::io::{stdin, stdout, IsTerminal};

use serde_json::json;

use crate::{
    kanidm_cli::{verify_with_retry, KanidmCli, SessionState, VerificationCheck},
    output::{CommandOutput, OutputFormat},
    AppError,
};

pub fn ensure_interactive_session_allowed(format: OutputFormat) -> Result<(), AppError> {
    if format != OutputFormat::Human {
        return Err(AppError::Config {
            message: "interactive session commands only support --output human".to_string(),
        });
    }
    if !stdin().is_terminal() || !stdout().is_terminal() {
        return Err(AppError::Config {
            message: "interactive session commands require a terminal on stdin and stdout"
                .to_string(),
        });
    }
    Ok(())
}

pub fn session_status(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let status = cli.session_status()?;
    Ok(match status {
        SessionState::Authenticated { stdout } => CommandOutput {
            message: "authenticated Kanidm CLI session is active".to_string(),
            human: format!(
                "Authenticated base session is active for '{}'.\nPrivileged write commands may still require `kanidm reauth --url {} --name {}`.\n\n{}",
                cli.admin_name(),
                cli.server_url(),
                cli.admin_name(),
                stdout.trim()
            ),
            details: json!({
                "authenticated": true,
                "state": "authenticated",
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "stdout": stdout.trim(),
            }),
            warnings: Vec::new(),
        },
        SessionState::Expired { diagnostic } => CommandOutput {
            message: "Kanidm CLI session has expired".to_string(),
            human: format!(
                "Session for '{}' has expired.\nRun `kanidm login --url {} --name {}` first.\n\nDiagnostic:\n{}",
                cli.admin_name(),
                cli.server_url(),
                cli.admin_name(),
                diagnostic.trim()
            ),
            details: json!({
                "authenticated": false,
                "state": "expired",
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "diagnostic": diagnostic.trim(),
            }),
            warnings: Vec::new(),
        },
        SessionState::Missing { diagnostic } => CommandOutput {
            message: "no valid Kanidm CLI session is active".to_string(),
            human: format!(
                "No valid Kanidm CLI session is active for '{}'.\nRun `kanidm login --url {} --name {}` first.\n\nDiagnostic:\n{}",
                cli.admin_name(),
                cli.server_url(),
                cli.admin_name(),
                diagnostic.trim()
            ),
            details: json!({
                "authenticated": false,
                "state": "missing",
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "diagnostic": diagnostic.trim(),
            }),
            warnings: Vec::new(),
        },
        SessionState::ReauthRequired { diagnostic } => CommandOutput {
            message: "Kanidm CLI session requires privileged reauthentication".to_string(),
            human: format!(
                "Session for '{}' is authenticated, but privileged reauthentication is required.\nRun `kanidm reauth --url {} --name {}` first.\n\nDiagnostic:\n{}",
                cli.admin_name(),
                cli.server_url(),
                cli.admin_name(),
                diagnostic.trim()
            ),
            details: json!({
                "authenticated": true,
                "state": "reauth_required",
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "diagnostic": diagnostic.trim(),
            }),
            warnings: Vec::new(),
        },
    })
}

pub fn session_login(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    cli.login()?;
    let session_stdout = verify_with_retry(
        &format!(
            "kanidm login exited successfully but no active session was detected for '{}'",
            cli.admin_name()
        ),
        json!({
            "session_present": true,
            "admin_name": cli.admin_name(),
            "server_url": cli.server_url(),
        }),
        true,
        || {
            let status = cli.session_status()?;
            Ok(match status {
                SessionState::Authenticated { stdout } => VerificationCheck::Matched {
                    observed: json!({
                        "session_present": true,
                        "state": "authenticated",
                        "stdout": stdout.trim(),
                    }),
                    value: stdout,
                },
                SessionState::Expired { diagnostic }
                | SessionState::Missing { diagnostic }
                | SessionState::ReauthRequired { diagnostic } => VerificationCheck::Mismatch {
                    observed: json!({
                        "session_present": false,
                        "state": "not_authenticated",
                        "diagnostic": diagnostic.trim(),
                    }),
                },
            })
        },
    )?;

    Ok(CommandOutput {
        message: "authenticated with Kanidm".to_string(),
        human: format!(
            "Authentication succeeded for '{}'.\n\n{}",
            cli.admin_name(),
            session_stdout.trim()
        ),
        details: json!({
            "authenticated": true,
            "admin_name": cli.admin_name(),
            "server_url": cli.server_url(),
            "stdout": session_stdout.trim(),
        }),
        warnings: Vec::new(),
    })
}

pub fn session_reauth(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    cli.reauth()?;
    Ok(CommandOutput {
        message: "Kanidm reauthentication command completed".to_string(),
        human: format!(
            "The Kanidm reauthentication command completed for '{}'.\nPrivileged state will be confirmed by the next privileged operation.",
            cli.admin_name()
        ),
        details: json!({
            "reauth_command_completed": true,
            "admin_name": cli.admin_name(),
            "server_url": cli.server_url(),
            "privileged_state_confirmed": false,
        }),
        warnings: vec![
            "Privileged access is not independently verified here; the next privileged command will confirm it.".to_string(),
        ],
    })
}

pub fn session_logout(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    cli.logout()?;
    Ok(CommandOutput {
        message: "logged out of the Kanidm CLI session".to_string(),
        human: "Logged out of the current Kanidm CLI session.".to_string(),
        details: json!({
            "logged_out": true,
            "server_url": cli.server_url(),
            "admin_name": cli.admin_name(),
        }),
        warnings: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

    use crate::context::ResolvedContext;

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

    #[test]
    fn session_status_reports_authenticated_state() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'active token for admindsaw\n'
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
        });

        let output = session_status(&cli).expect("session status");
        assert!(output
            .human
            .contains("Authenticated base session is active"));
        assert!(output.human.contains("kanidm reauth"));
        assert_eq!(output.details["state"], "authenticated");
    }

    #[test]
    fn session_status_reports_expired_state() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'session has expired\n' >&2
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
        });

        let output = session_status(&cli).expect("session status");
        assert!(output.human.contains("has expired"));
        assert!(output.human.contains("kanidm login"));
        assert_eq!(output.details["state"], "expired");
    }
}
