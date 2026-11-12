//! Admin tools are hidden from other users and independently authorized again
//! by the Caddy-only privileged backend. The ordinary AI process has no grant
//! to that socket and cannot turn a claimed username into administrator access.

use rmcp::{
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Tool,
        ToolAnnotations,
    },
    service::RequestContext,
    ErrorData, RoleServer,
};
use serde_json::{json, Value};
use std::sync::Arc;

#[derive(Clone)]
pub(super) struct Config {
    pub username: String,
    pub host: String,
}

impl Config {
    pub fn from_env() -> Result<Option<Self>, String> {
        match (
            std::env::var("AI_TOOLS_ADMIN_USERNAME").ok(),
            std::env::var("AI_TOOLS_ADMIN_HOST").ok(),
        ) {
            (None, None) => Ok(None),
            (Some(username), Some(host)) if valid_admin(&username) => {
                let host = crate::parse_public_host(Some(host))?.ok_or("Admin host is required")?;
                Ok(Some(Self { username, host }))
            }
            _ => Err("Admin tools require an explicit administrator username and hostname".into()),
        }
    }
}

pub(super) fn valid_admin(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

pub(super) fn denied() -> ErrorData {
    ErrorData::invalid_request(
        "Server administration tools require the configured server-admin login",
        None,
    )
}

pub(super) fn is_tool(name: &str) -> bool {
    matches!(
        name,
        "server_health" | "server_services" | "server_service_status" | "server_restart_service"
    )
}

pub(super) fn definitions() -> Vec<Tool> {
    [
        ("server_health", "Read server uptime, load averages and memory availability. Server-admin login only.", false),
        ("server_services", "List configured diagnostic services, currently failed services and the explicit restart allowlist. Server-admin login only.", false),
        ("server_service_status", "Inspect a configured systemd service's safe state/resource/exit properties. Does not return environment variables, commands or raw journal contents. Use the exact .service name from server_services.", true),
        ("server_restart_service", "Request a restart of ONE application service from the configured restart allowlist, only when the user explicitly asks for that restart. May interrupt that app. A queued request is not successful recovery: check server_service_status afterwards. Do not repeat an uncertain request automatically. No shutdown, deployment, identity, routing, storage or arbitrary commands.", true),
    ].into_iter().map(|(name,description,service)| {
        let schema = if service { json!({"type":"object","properties":{"service":{"type":"string"}},"required":["service"],"additionalProperties":false}) } else { json!({"type":"object","properties":{},"additionalProperties":false}) };
        let write = name=="server_restart_service";
        Tool::new(name, description, Arc::new(schema.as_object().unwrap().clone()))
            .with_annotations(ToolAnnotations::new().read_only(!write).destructive(write).idempotent(!write).open_world(false))
    }).collect()
}

pub(super) fn tools(config: &Option<Config>, context: &RequestContext<RoleServer>) -> Vec<Tool> {
    if let (Some(config), Ok(caller)) = (
        config.as_ref(),
        crate::gateway::AuthenticatedCaller::require(context),
    ) && caller.username() == config.username
    {
        return definitions();
    }
    Vec::new()
}

pub(super) async fn call(
    server: &crate::Server,
    request: &CallToolRequestParams,
    context: &RequestContext<RoleServer>,
) -> Option<Result<CallToolResponse, ErrorData>> {
    if !is_tool(request.name.as_ref()) {
        return None;
    }
    Some(forward(server, request, context).await)
}

async fn forward(
    server: &crate::Server,
    request: &CallToolRequestParams,
    context: &RequestContext<RoleServer>,
) -> Result<CallToolResponse, ErrorData> {
    let caller = crate::gateway::AuthenticatedCaller::require(context)?;
    let config = server.config.admin.as_ref().ok_or_else(denied)?;
    if caller.username() != config.username {
        return Err(denied());
    }
    let session = crate::app_tools::AppSession::from_context(context)?;
    let client = crate::app_tools::app_client(&config.host)?;
    let url =
        reqwest::Url::parse(&format!("https://{}/admin", config.host)).map_err(|_| denied())?;
    let body = json!({"name":request.name,"arguments":request.arguments.as_ref().cloned().unwrap_or_default()});
    let payload: Value =
        crate::app_tools::request_json(&client, &session, reqwest::Method::POST, url, Some(body))
            .await?;
    Ok(CallToolResult::success(vec![ContentBlock::json(payload)?]).into())
}
