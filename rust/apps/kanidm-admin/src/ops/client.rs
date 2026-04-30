use serde_json::{json, Value};

use crate::{
    inventory::clients::{parse_client_list, parse_client_record, ClientRecord},
    kanidm_cli::{verify_with_retry, KanidmCli, VerificationCheck},
    output::CommandOutput,
    AppError,
};

pub fn list_clients(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let clients = parse_client_list(&cli.oauth2_list::<Value>()?)?;
    let human = if clients.value.is_empty() {
        "No Kanidm oauth2 clients found.".to_string()
    } else {
        let mut lines = vec![format!(
            "{:<28} {:<20} {}",
            "CLIENT", "DISPLAY NAME", "LANDING URL"
        )];
        lines.extend(clients.value.iter().map(|client| {
            format!(
                "{:<28} {:<20} {}",
                client.name,
                client.display_name.as_deref().unwrap_or("-"),
                client.landing_url.as_deref().unwrap_or("-")
            )
        }));
        lines.join("\n")
    };
    Ok(CommandOutput {
        message: format!("listed {} Kanidm oauth2 client(s)", clients.value.len()),
        human,
        details: json!({ "clients": clients.value }),
        warnings: clients.warnings,
    })
}

pub fn show_client(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    let client = load_client(cli, client)?;
    Ok(CommandOutput {
        message: format!("loaded Kanidm oauth2 client '{}'", client.value.name),
        human: human_client_summary(&client.value),
        details: json!({ "client": client.value }),
        warnings: client.warnings,
    })
}

pub fn client_secret_show(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    let stdout = cli.oauth2_show_basic_secret(client)?;
    Ok(raw_client_command_output(
        format!("shown oauth2 basic secret for '{client}'"),
        format!("OAuth2 basic secret for '{client}':\n\n{}", stdout.trim()),
        json!({ "client": client, "raw_output": stdout.trim() }),
    ))
}

pub fn client_secret_reset(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    let stdout = cli.oauth2_reset_basic_secret(client)?;
    Ok(raw_client_command_output(
        format!("reset oauth2 basic secret for '{client}'"),
        format!(
            "Reset the oauth2 basic secret for '{client}'.\n\n{}",
            stdout.trim()
        ),
        json!({ "client": client, "raw_output": stdout.trim() }),
    ))
}

pub fn client_redirect_add(
    cli: &KanidmCli,
    client: &str,
    url: &str,
) -> Result<CommandOutput, AppError> {
    cli.oauth2_add_redirect_url(client, url)?;
    let client = verify_redirect_presence(cli, client, url, true)?;
    Ok(CommandOutput {
        message: format!("added oauth2 redirect URL to '{}'", client.value.name),
        human: format!(
            "Added redirect URL to '{}'.\n\n{}",
            client.value.name,
            human_client_summary(&client.value)
        ),
        details: json!({ "client": client.value, "changed_redirect_url": url }),
        warnings: client.warnings,
    })
}

pub fn client_redirect_remove(
    cli: &KanidmCli,
    client: &str,
    url: &str,
) -> Result<CommandOutput, AppError> {
    cli.oauth2_remove_redirect_url(client, url)?;
    let client = verify_redirect_presence(cli, client, url, false)?;
    Ok(CommandOutput {
        message: format!("removed oauth2 redirect URL from '{}'", client.value.name),
        human: format!(
            "Removed redirect URL from '{}'.\n\n{}",
            client.value.name,
            human_client_summary(&client.value)
        ),
        details: json!({ "client": client.value, "changed_redirect_url": url }),
        warnings: client.warnings,
    })
}

pub fn client_pkce_enable(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    cli.oauth2_enable_pkce(client)?;
    let client = verify_bool_flag(cli, client, "pkce_enabled", Some(true))?;
    Ok(CommandOutput {
        message: format!("enabled PKCE for oauth2 client '{}'", client.value.name),
        human: human_client_summary(&client.value),
        details: json!({ "client": client.value }),
        warnings: client.warnings,
    })
}

pub fn client_pkce_disable(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    cli.oauth2_disable_pkce(client)?;
    let client = verify_bool_flag(cli, client, "pkce_enabled", Some(false))?;
    Ok(CommandOutput {
        message: format!("disabled PKCE for oauth2 client '{}'", client.value.name),
        human: human_client_summary(&client.value),
        details: json!({ "client": client.value }),
        warnings: client.warnings,
    })
}

pub fn client_consent_enable(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    cli.oauth2_enable_consent(client)?;
    let client = verify_bool_flag(cli, client, "consent_prompt_enabled", Some(true))?;
    Ok(CommandOutput {
        message: format!(
            "enabled the consent prompt for oauth2 client '{}'",
            client.value.name
        ),
        human: human_client_summary(&client.value),
        details: json!({ "client": client.value }),
        warnings: client.warnings,
    })
}

pub fn client_consent_disable(cli: &KanidmCli, client: &str) -> Result<CommandOutput, AppError> {
    cli.oauth2_disable_consent(client)?;
    let client = verify_bool_flag(cli, client, "consent_prompt_enabled", Some(false))?;
    Ok(CommandOutput {
        message: format!(
            "disabled the consent prompt for oauth2 client '{}'",
            client.value.name
        ),
        human: human_client_summary(&client.value),
        details: json!({ "client": client.value }),
        warnings: client.warnings,
    })
}

pub fn load_client(
    cli: &KanidmCli,
    client: &str,
) -> Result<crate::inventory::Parsed<ClientRecord>, AppError> {
    parse_client_record(&cli.oauth2_get::<Value>(client)?, client)
}

pub fn human_client_summary(client: &ClientRecord) -> String {
    format!(
        "Client: {}\nDisplay Name: {}\nLanding URL: {}\nPKCE Enabled: {}\nConsent Prompt Enabled: {}\n\nRedirect URLs:\n{}\n\nScope Maps:\n{}\n\nClaim Maps:\n{}",
        client.name,
        client.display_name.as_deref().unwrap_or("-"),
        client.landing_url.as_deref().unwrap_or("-"),
        render_optional_bool(client.pkce_enabled),
        render_optional_bool(client.consent_prompt_enabled),
        render_strings(&client.redirect_urls),
        render_scope_maps(&client.scope_maps),
        render_claim_maps(&client.claim_maps),
    )
}

fn verify_redirect_presence(
    cli: &KanidmCli,
    client: &str,
    url: &str,
    expected_present: bool,
) -> Result<crate::inventory::Parsed<ClientRecord>, AppError> {
    verify_with_retry(
        &format!("redirect URL verification failed for oauth2 client '{client}'"),
        json!({
            "client": client,
            "redirect_url": url,
            "expected_present": expected_present,
        }),
        true,
        || {
            let client = load_client(cli, client)?;
            let actual_present = client
                .value
                .redirect_urls
                .iter()
                .any(|candidate| candidate == url);
            let observed = json!({
                "actual_present": actual_present,
                "redirect_urls": &client.value.redirect_urls,
                "warnings": &client.warnings,
            });
            if actual_present == expected_present {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: client,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn verify_bool_flag(
    cli: &KanidmCli,
    client: &str,
    field: &str,
    expected: Option<bool>,
) -> Result<crate::inventory::Parsed<ClientRecord>, AppError> {
    verify_with_retry(
        &format!("boolean flag verification failed for oauth2 client '{client}'"),
        json!({
            "client": client,
            "field": field,
            "expected": expected,
        }),
        true,
        || {
            let client = load_client(cli, client)?;
            let actual = match field {
                "pkce_enabled" => client.value.pkce_enabled,
                "consent_prompt_enabled" => client.value.consent_prompt_enabled,
                _ => None,
            };
            let observed = json!({
                "actual": actual,
                "warnings": &client.warnings,
            });
            if actual == expected {
                Ok(VerificationCheck::Matched {
                    observed,
                    value: client,
                })
            } else {
                Ok(VerificationCheck::Mismatch { observed })
            }
        },
    )
}

fn raw_client_command_output(message: String, human: String, details: Value) -> CommandOutput {
    CommandOutput {
        message,
        human,
        details,
        warnings: Vec::new(),
    }
}

fn render_optional_bool(value: Option<bool>) -> &'static str {
    match value {
        Some(true) => "yes",
        Some(false) => "no",
        None => "unknown",
    }
}

fn render_strings(values: &[String]) -> String {
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values
            .iter()
            .map(|value| format!("- {value}"))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn render_scope_maps(values: &[crate::inventory::clients::GroupScopeMap]) -> String {
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values
            .iter()
            .map(|value| format!("- {} => {}", value.group, value.scopes.join(", ")))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn render_claim_maps(values: &[crate::inventory::clients::GroupClaimMap]) -> String {
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values
            .iter()
            .map(|value| format!("- {} => {}", value.group, value.claims.join(", ")))
            .collect::<Vec<_>>()
            .join("\n")
    }
}
