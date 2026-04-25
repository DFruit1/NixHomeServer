use serde_json::json;

use crate::{
    kanidm_cli::{verify_with_retry, KanidmCli, SessionState, VerificationCheck},
    output::CommandOutput,
};

pub fn auth_status(cli: &KanidmCli) -> Result<CommandOutput, crate::AppError> {
    let status = cli.session_status()?;
    Ok(match status {
        SessionState::Authenticated { stdout } => CommandOutput {
            message: "authenticated Kanidm CLI session is active".to_string(),
            human: format!(
                "Authenticated session is active for '{}'.\n\n{}",
                cli.admin_name(),
                stdout.trim()
            ),
            details: json!({
                "authenticated": true,
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "stdout": stdout.trim(),
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
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
                "diagnostic": diagnostic.trim(),
            }),
            warnings: Vec::new(),
        },
    })
}

pub fn auth_login(cli: &KanidmCli) -> Result<CommandOutput, crate::AppError> {
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
                SessionState::Authenticated { stdout } => VerificationCheck {
                    matched: true,
                    observed: json!({
                        "session_present": true,
                        "stdout": stdout.trim(),
                    }),
                    value: stdout,
                },
                SessionState::Missing { diagnostic } => VerificationCheck {
                    matched: false,
                    observed: json!({
                        "session_present": false,
                        "diagnostic": diagnostic.trim(),
                    }),
                    value: diagnostic,
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

pub fn auth_reauth(cli: &KanidmCli) -> Result<CommandOutput, crate::AppError> {
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
