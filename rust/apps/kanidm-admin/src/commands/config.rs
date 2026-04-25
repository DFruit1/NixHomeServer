use serde_json::json;

use crate::{config::ResolvedConfig, output::CommandOutput};

pub fn show_config(config: &ResolvedConfig) -> CommandOutput {
    let repo_root = config
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());
    let kanidm_bin = config.kanidm_bin.to_string_lossy().to_string();

    CommandOutput {
        message: "loaded kanidm-admin configuration".to_string(),
        human: format!(
            "Repository Root: {}\nServer URL: {}\nAdmin Name: {}\nKanidm Binary: {}",
            repo_root.as_deref().unwrap_or("(not resolved)"),
            config.server_url,
            config.admin_name,
            kanidm_bin,
        ),
        details: json!({
            "repo_root": repo_root,
            "server_url": config.server_url,
            "admin_name": config.admin_name,
            "kanidm_bin": kanidm_bin,
        }),
        warnings: Vec::new(),
    }
}
