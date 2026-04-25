use serde_json::json;

use crate::{
    kanidm_cli::{KanidmCli, SessionState},
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
        },
    })
}

pub fn auth_login(cli: &KanidmCli) -> Result<CommandOutput, crate::AppError> {
    cli.login()?;
    let verified = cli.session_status()?;

    let human = match verified {
        SessionState::Authenticated { stdout } => format!(
            "Authentication succeeded for '{}'.\n\n{}",
            cli.admin_name(),
            stdout.trim()
        ),
        SessionState::Missing { diagnostic } => {
            return Err(crate::AppError::Verification {
                message: format!(
                    "kanidm login exited successfully but no active session was detected for '{}'",
                    cli.admin_name()
                ),
                details: json!({
                    "admin_name": cli.admin_name(),
                    "server_url": cli.server_url(),
                    "diagnostic": diagnostic.trim(),
                }),
            });
        }
    };

    Ok(CommandOutput {
        message: "authenticated with Kanidm".to_string(),
        human,
        details: json!({
            "authenticated": true,
            "admin_name": cli.admin_name(),
            "server_url": cli.server_url(),
        }),
    })
}

pub fn auth_reauth(cli: &KanidmCli) -> Result<CommandOutput, crate::AppError> {
    cli.reauth()?;
    Ok(CommandOutput {
        message: "reauthenticated privileged Kanidm access".to_string(),
        human: format!(
            "Privileged Kanidm access was refreshed for '{}'.",
            cli.admin_name()
        ),
        details: json!({
            "reauthenticated": true,
            "admin_name": cli.admin_name(),
            "server_url": cli.server_url(),
        }),
    })
}
