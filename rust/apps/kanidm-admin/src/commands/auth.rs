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
