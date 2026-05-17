use std::io::{stdin, stdout, IsTerminal};

use serde_json::json;

use crate::{
    kanidm_cli::{
        BaseSessionState, KanidmCli, ParseConfidence, ParsedExpiry, PrivilegedWriteState,
        SessionSnapshot,
    },
    ops::executor::{recovery_command_output, verify_session_recovery, RecoveryTarget},
    output::{CommandOutput, OutputFormat},
    session_state::concise_session_message,
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
    let snapshot = cli.session_snapshot()?;
    Ok(match (
        snapshot.base_session_state,
        snapshot.privileged_write_state,
    ) {
        (BaseSessionState::Present, PrivilegedWriteState::Ready) => CommandOutput {
            message: "authenticated Kanidm CLI session is active".to_string(),
            human: format!(
                "Authenticated base session is active for '{}'.\nPrivileged write commands are ready.\n\n{}",
                cli.admin_name(),
                snapshot.diagnostic_raw.trim()
            ),
            details: json!({
                "authenticated": true,
                "state": "authenticated",
                "snapshot": session_snapshot_details(&snapshot),
            }),
            warnings: Vec::new(),
        },
        (BaseSessionState::Expired, _) => CommandOutput {
            message: "Kanidm CLI session has expired".to_string(),
            human: concise_session_message(cli.admin_name(), &snapshot)
                .expect("expired session copy"),
            details: json!({
                "authenticated": false,
                "state": "expired",
                "snapshot": session_snapshot_details(&snapshot),
            }),
            warnings: Vec::new(),
        },
        (BaseSessionState::Missing | BaseSessionState::Unknown, _) => CommandOutput {
            message: "no valid Kanidm CLI session is active".to_string(),
            human: concise_session_message(cli.admin_name(), &snapshot).unwrap_or_else(|| {
                format!(
                    "No active admin session was found for '{}'. Run `kanidm-admin session login` to log in.",
                    cli.admin_name()
                )
            }),
            details: json!({
                "authenticated": false,
                "state": "missing",
                "snapshot": session_snapshot_details(&snapshot),
            }),
            warnings: Vec::new(),
        },
        (BaseSessionState::Present, _) => CommandOutput {
            message: "Kanidm CLI session requires privileged reauthentication".to_string(),
            human: concise_session_message(cli.admin_name(), &snapshot)
                .expect("reauth-required session copy"),
            details: json!({
                "authenticated": true,
                "state": "reauth_required",
                "snapshot": session_snapshot_details(&snapshot),
            }),
            warnings: Vec::new(),
        },
    })
}

pub fn session_login(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    match verify_session_recovery(cli, RecoveryTarget::BaseSession, || cli.login()) {
        Ok(verification) => {
            let mut output = recovery_command_output(cli, "Login", verification.clone());
            output.details["snapshot"] = session_snapshot_details(&verification.snapshot);
            Ok(output)
        }
        Err(AppError::Verification { message, details }) => {
            Ok(login_verification_warning_output(cli, &message, details))
        }
        Err(error) => Err(error),
    }
}

pub fn session_reauth(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let verification =
        verify_session_recovery(cli, RecoveryTarget::PrivilegedWrites, || cli.reauth())?;
    let mut output = recovery_command_output(cli, "Reauthenticate", verification.clone());
    output.details["reauth_command_completed"] = json!(true);
    output.details["snapshot"] = session_snapshot_details(&verification.snapshot);
    Ok(output)
}

pub fn session_login_refresh_privileged(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let verification =
        verify_session_recovery(cli, RecoveryTarget::PrivilegedWrites, || cli.login())?;
    let mut output = recovery_command_output(
        cli,
        "Refresh Login For Privileged Writes",
        verification.clone(),
    );
    output.details["login_command_completed"] = json!(true);
    output.details["snapshot"] = session_snapshot_details(&verification.snapshot);
    Ok(output)
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

fn login_verification_warning_output(
    cli: &KanidmCli,
    verification_message: &str,
    verification_details: serde_json::Value,
) -> CommandOutput {
    CommandOutput {
        message: "Kanidm login command completed, but session verification was inconclusive"
            .to_string(),
        human: format!(
            "Login completed for '{}', but the follow-up session check could not confirm the cached session yet.\n\nRun `kanidm-admin session status` before making changes if you want to confirm the session state.",
            cli.admin_name()
        ),
        details: json!({
            "authenticated": null,
            "base_session_present": null,
            "state": "verification_inconclusive",
            "privileged_write_access": "unknown",
            "verification": {
                "message": verification_message,
                "details": verification_details,
            },
        }),
        warnings: vec![
            "The upstream `kanidm login` command exited successfully; only the post-login verification failed.".to_string(),
            "If the next Kanidm operation still reports a missing session, rerun `kanidm-admin session login` from a plain terminal.".to_string(),
        ],
    }
}

fn session_snapshot_details(snapshot: &SessionSnapshot) -> serde_json::Value {
    json!({
        "admin_name": snapshot.admin_name,
        "server_url": snapshot.server_url,
        "matched_principal": snapshot.matched_principal,
        "base_session_state": base_session_state_label(snapshot.base_session_state),
        "privileged_write_state": privileged_write_state_label(snapshot.privileged_write_state),
        "base_expiry": parsed_expiry_label(&snapshot.base_expiry),
        "privileged_expiry": parsed_expiry_label(&snapshot.privileged_expiry),
        "parse_confidence": parse_confidence_label(snapshot.parse_confidence),
        "diagnostic": snapshot.diagnostic_raw.trim(),
    })
}

fn base_session_state_label(state: BaseSessionState) -> &'static str {
    match state {
        BaseSessionState::Present => "present",
        BaseSessionState::Expired => "expired",
        BaseSessionState::Missing => "missing",
        BaseSessionState::Unknown => "unknown",
    }
}

fn privileged_write_state_label(state: PrivilegedWriteState) -> &'static str {
    match state {
        PrivilegedWriteState::Ready => "ready",
        PrivilegedWriteState::ReauthRequired => "reauth_required",
        PrivilegedWriteState::Unavailable => "unavailable",
        PrivilegedWriteState::Unknown => "unknown",
    }
}

fn parse_confidence_label(confidence: ParseConfidence) -> &'static str {
    match confidence {
        ParseConfidence::High => "high",
        ParseConfidence::Heuristic => "heuristic",
    }
}

fn parsed_expiry_label(expiry: &ParsedExpiry) -> String {
    match expiry {
        ParsedExpiry::Never => "never".to_string(),
        ParsedExpiry::At(expiry) => expiry
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| expiry.to_string()),
        ParsedExpiry::Unknown(value) => format!("unknown:{value}"),
    }
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsString, fs, os::unix::fs::PermissionsExt, path::Path,
        process::Command as ProcessCommand, sync::Arc,
    };

    use crate::backend::{
        BackendCrashKind, BackendExecError, ExitStatusSummary, KanidmBackend, RawCommandRequest,
        RawCommandResult,
    };
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

    #[derive(Debug)]
    struct LoginSucceedsButStatusProbeFails;

    impl KanidmBackend for LoginSucceedsButStatusProbeFails {
        fn exec(&self, request: RawCommandRequest) -> Result<RawCommandResult, BackendExecError> {
            if request.args.first().map(String::as_str) == Some("login") {
                return Ok(RawCommandResult {
                    status: ExitStatusSummary {
                        success: true,
                        code: Some(0),
                    },
                    stdout: "Login Success for admindsaw@example.test\n".to_string(),
                    stderr: String::new(),
                });
            }

            Err(BackendExecError::Io {
                message: "session status probe failed".to_string(),
                crash_kind: Some(BackendCrashKind::UnexpectedFailure),
            })
        }
    }

    #[test]
    fn session_status_reports_reauth_required_for_heuristic_base_session() {
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
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let output = session_status(&cli).expect("session status");
        assert!(output.human.contains("requires reauthentication"));
        assert!(output.human.contains("kanidm-admin session reauth"));
        assert_eq!(output.details["state"], "reauth_required");
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
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let output = session_status(&cli).expect("session status");
        assert!(output.human.contains("has expired"));
        assert!(output.human.contains("kanidm-admin session login"));
        assert_eq!(output.details["state"], "expired");
    }

    #[test]
    fn session_status_reports_reauth_required_state() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
cat <<'EOF'
---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: 2030-01-01T00:00:00Z
purpose: read only
EOF
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let output = session_status(&cli).expect("session status");
        assert!(output
            .human
            .contains("Privileged write access for 'admindsaw' requires reauthentication"));
        assert_eq!(output.details["state"], "reauth_required");
        assert_eq!(output.details["authenticated"], true);
    }

    #[test]
    fn session_login_accepts_never_expiring_privileged_session() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "login" ]]; then
  printf 'Login Success for admindsaw@example.test\n'
  exit 0
fi
if [[ "$1" == "session" && "$2" == "list" ]]; then
  cat <<'EOF'
---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: 2030-01-01T00:00:00Z
purpose: read write (expiry: none)
EOF
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let output = session_login(&cli).expect("session login");
        assert_eq!(output.details["state"], "authenticated");
        assert_eq!(output.details["base_session_present"], true);
        assert!(output.human.contains("Login succeeded for 'admindsaw'."));
        assert_eq!(output.details["privileged_write_access"], "ready");
        assert_eq!(output.warnings.len(), 0);
    }

    #[test]
    fn session_login_warns_when_post_login_verification_is_inconclusive() {
        let cli = KanidmCli::with_backend(
            OsString::from("kanidm"),
            "https://id.example.test".to_string(),
            "admindsaw".to_string(),
            Arc::new(LoginSucceedsButStatusProbeFails),
        );

        let output = session_login(&cli).expect("login should complete with warning");

        assert_eq!(output.details["state"], "verification_inconclusive");
        assert_eq!(
            output.details["base_session_present"],
            serde_json::Value::Null
        );
        assert!(output.human.contains("Login completed for 'admindsaw'"));
        assert!(output
            .warnings
            .iter()
            .any(|warning| warning.contains("exited successfully")));
    }
}
