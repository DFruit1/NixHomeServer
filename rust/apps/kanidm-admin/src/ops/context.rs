use serde_json::{json, Value};

use crate::{
    context::ResolvedContext,
    inventory::{clients::parse_client_list, groups::parse_group_list, users::parse_user_list},
    kanidm_cli::{KanidmCli, SessionState},
    output::CommandOutput,
    AppError,
};

pub fn show_context(context: &ResolvedContext) -> CommandOutput {
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());
    let kanidm_bin = context.kanidm_bin.to_string_lossy().to_string();

    CommandOutput {
        message: "loaded kanidm-admin context".to_string(),
        human: format!(
            "Repository Root: {}\nServer URL: {}\nAdmin Name: {}\nKanidm Binary: {}",
            repo_root.as_deref().unwrap_or("(not resolved)"),
            context.server_url,
            context.admin_name,
            kanidm_bin,
        ),
        details: json!({
            "repo_root": repo_root,
            "server_url": context.server_url,
            "admin_name": context.admin_name,
            "kanidm_bin": kanidm_bin,
        }),
        warnings: Vec::new(),
    }
}

pub fn doctor(context: &ResolvedContext, cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let session = match cli.session_status()? {
        SessionState::Authenticated { stdout } => json!({
            "authenticated": true,
            "state": "authenticated",
            "diagnostic": stdout.trim(),
        }),
        SessionState::Expired { diagnostic } => json!({
            "authenticated": false,
            "state": "expired",
            "diagnostic": diagnostic.trim(),
        }),
        SessionState::Missing { diagnostic } => json!({
            "authenticated": false,
            "state": "missing",
            "diagnostic": diagnostic.trim(),
        }),
        SessionState::ReauthRequired { diagnostic } => json!({
            "authenticated": true,
            "state": "reauth_required",
            "diagnostic": diagnostic.trim(),
        }),
    };

    let users = parse_user_list(&cli.person_list::<Value>()?)?;
    let groups = parse_group_list(&cli.group_list::<Value>()?)?;
    let clients = parse_client_list(&cli.oauth2_list::<Value>()?)?;

    let warnings = merge_warnings(vec![
        users.warnings.clone(),
        groups.warnings.clone(),
        clients.warnings.clone(),
    ]);
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());

    Ok(CommandOutput {
        message: "completed kanidm-admin doctor checks".to_string(),
        human: format!(
            "Server URL: {}\nAdmin Name: {}\nAuthenticated: {}\nUsers: {}\nGroups: {}\nOAuth2 Clients: {}",
            context.server_url,
            context.admin_name,
            if session["authenticated"] == Value::Bool(true) {
                "yes"
            } else {
                "no"
            },
            users.value.len(),
            groups.value.len(),
            clients.value.len()
        ),
        details: json!({
            "context": {
                "repo_root": repo_root,
                "server_url": context.server_url,
                "admin_name": context.admin_name,
                "kanidm_bin": context.kanidm_bin.to_string_lossy().to_string(),
            },
            "session": session,
            "counts": {
                "users": users.value.len(),
                "groups": groups.value.len(),
                "clients": clients.value.len(),
            },
            "warnings_by_inventory": {
                "users": users.warnings,
                "groups": groups.warnings,
                "clients": clients.warnings,
            },
        }),
        warnings,
    })
}

fn merge_warnings(inventories: Vec<Vec<String>>) -> Vec<String> {
    let mut warnings = inventories.into_iter().flatten().collect::<Vec<_>>();
    warnings.sort();
    warnings.dedup();
    warnings
}
