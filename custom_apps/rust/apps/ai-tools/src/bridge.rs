//! stdio-to-loopback MCP bridge.
//!
//! The pinned llama.cpp build can only reach an MCP server by spawning it as a
//! child process and speaking newline-delimited JSON-RPC to it over stdin and
//! stdout. `ai-tools` speaks MCP over Streamable HTTP on loopback instead, and
//! is published through the authentication gateway, so llama.cpp cannot dial it
//! directly. This module closes that gap: it speaks the stdio framing on the
//! side llama.cpp drives and forwards to the same loopback endpoint every other
//! client uses.
//!
//! The point of routing through ai-tools rather than giving llama.cpp the tool
//! implementations is that ai-tools keeps sole ownership of the shared-root
//! grant, its service account and its sandbox. The bridge holds no grant of its
//! own, reaches nothing but loopback, and re-validates nothing itself: every
//! path a tool receives is resolved by ai-tools against the shared root before
//! it is opened.

use std::{borrow::Cow, sync::Arc, time::Duration};

use rmcp::{
    ClientServiceExt, ErrorData, RoleClient, RoleServer, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, InitializeResult,
        JsonObject, ListToolsResult, PaginatedRequestParams, ProtocolVersion, ServerCapabilities,
        Tool,
    },
    service::RequestContext,
    transport::{
        StreamableHttpClientTransport, streamable_http_client::StreamableHttpClientTransportConfig,
        stdio,
    },
};

/// MCP revision the pinned llama.cpp build names in its stdio handshake, and the
/// only one this bridge accepts.
///
/// It is a hard requirement rather than a preference. llama.cpp's stdio client
/// sends bare `initialize`, `tools/list` and `tools/call` with no per-request
/// `_meta`, so the revisions that moved the lifecycle into per-request metadata
/// cannot be served at all.
pub const STDIO_PROTOCOL_VERSION: ProtocolVersion = ProtocolVersion::V_2024_11_05;

/// llama.cpp prefixes every tool with the name its MCP config gave the server,
/// so the host sees `ai_tools_web_search` and `ai_tools_convert_document`. Those
/// prefixed names are what makes the tools visible to every client of the shared
/// inference endpoint, so the prefix is what the bridge restores on the way out
/// and strips on the way in.
pub const TOOL_NAME_PREFIX: &str = "ai_tools_";

fn wire_name(bare: &str) -> String {
    format!("{TOOL_NAME_PREFIX}{bare}")
}

/// Reject an upstream URL that is not loopback.
///
/// ai-tools is reachable only over loopback and behind a gateway that mints its
/// own auth; a non-loopback upstream would put the shared-root policy one
/// network hop from whoever answered that address. Refusing the value at startup
/// is cheaper than discovering it from a tool call.
fn parse_upstream_url(raw: &str) -> Result<String, String> {
    let url = raw.trim();
    let authority = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .ok_or_else(|| "AI_TOOLS_BRIDGE_UPSTREAM_URL must be an http(s) URL".to_string())?;
    let host = authority
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(authority);
    // Drop an optional port; an IPv6 literal keeps its brackets.
    let host = match host.rsplit_once(':') {
        Some((name, port)) if port.chars().all(|c| c.is_ascii_digit()) => name,
        _ => host,
    };
    let is_loopback = matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]")
        || host.starts_with("127.");
    if !is_loopback {
        return Err(format!(
            "AI_TOOLS_BRIDGE_UPSTREAM_URL must stay on loopback, got {host:?}"
        ));
    }
    Ok(url.to_string())
}

/// Loopback endpoint derived from `AI_TOOLS_LISTEN`, which the service already
/// owns, so the bridge cannot be pointed at a different port by accident.
fn upstream_url_from_env() -> Result<String, String> {
    match std::env::var("AI_TOOLS_BRIDGE_UPSTREAM_URL") {
        Ok(raw) => parse_upstream_url(&raw),
        Err(_) => match std::env::var("AI_TOOLS_LISTEN") {
            Ok(listen) if !listen.trim().is_empty() => {
                let listen = listen.trim();
                if !(listen.starts_with("127.") || listen.starts_with("localhost") || listen.starts_with("[::1]"))
                {
                    return Err(format!(
                        "AI_TOOLS_LISTEN must stay on loopback, got {listen:?}"
                    ));
                }
                Ok(format!("http://{listen}/"))
            }
            _ => Ok("http://127.0.0.1:8097/".to_string()),
        },
    }
}

fn env_duration(name: &str, fallback_secs: u64) -> Duration {
    match std::env::var(name) {
        Ok(raw) => raw
            .parse::<u64>()
            .map(Duration::from_secs)
            .ok()
            .filter(|duration| !duration.is_zero())
            .unwrap_or_else(|| Duration::from_secs(fallback_secs)),
        Err(_) => Duration::from_secs(fallback_secs),
    }
}

/// MCP client session held open against the loopback endpoint.
///
/// A type alias rather than the full path at three use sites: the
/// `RunningService` generics nest deeply enough that inlining them is a line
/// over the wrap width and easy to miscount.
type UpstreamSession = rmcp::service::RunningService<RoleClient, ()>;

#[derive(Clone)]
struct Bridge {
    upstream_url: Arc<str>,
    /// One MCP session for the process lifetime, so ai-tools serves the bridge
    /// from a single handler instead of re-handshaking per tool call.
    session: Arc<tokio::sync::Mutex<Option<Arc<UpstreamSession>>>>,
    connect_timeout: Duration,
    call_timeout: Duration,
}

impl Bridge {
    fn new(upstream_url: String, connect_timeout: Duration, call_timeout: Duration) -> Self {
        Self {
            upstream_url: Arc::from(upstream_url),
            session: Arc::new(tokio::sync::Mutex::new(None)),
            connect_timeout,
            call_timeout,
        }
    }

    fn from_env() -> Result<Self, String> {
        Ok(Self::new(
            upstream_url_from_env()?,
            env_duration("AI_TOOLS_BRIDGE_CONNECT_TIMEOUT_SECS", 10),
            env_duration("AI_TOOLS_BRIDGE_CALL_TIMEOUT_SECS", 120),
        ))
    }

    async fn list_tools(&self) -> Result<Vec<Tool>, String> {
        let session = self.open_session().await?;
        let tools = tokio::time::timeout(self.call_timeout, session.list_all_tools())
            .await
            .map_err(|_| "timed out listing ai-tools tools".to_string())?
            .map_err(|error| format!("could not list ai-tools tools: {error}"))?;
        Ok(tools
            .into_iter()
            .map(|mut tool| {
                tool.name = Cow::Owned(wire_name(&tool.name));
                tool
            })
            .collect())
    }

    async fn open_session(&self) -> Result<Arc<UpstreamSession>, String> {
        let mut guard = tokio::time::timeout(self.connect_timeout, self.session.lock())
            .await
            .map_err(|_| "timed out waiting for the bridge session lock".to_string())?;

        if let Some(session) = guard.as_ref() {
            if !session.is_closed() {
                return Ok(Arc::clone(session));
            }
        }

        let transport = StreamableHttpClientTransport::with_client(
            reqwest::Client::builder()
                .no_proxy()
                .build()
                .map_err(|error| format!("could not build the bridge HTTP client: {error}"))?,
            StreamableHttpClientTransportConfig::with_uri(self.upstream_url.as_ref()),
        );
        let session = tokio::time::timeout(
            self.connect_timeout,
            // The initialize/initialized handshake, not the discover lifecycle:
            // 2024-11-05 predates server/discover.
            ().serve_with_lifecycle(transport, rmcp::ClientLifecycleMode::Initialize),
        )
        .await
        .map_err(|_| {
            format!(
                "timed out connecting to the ai-tools endpoint at {}",
                self.upstream_url
            )
        })?
        .map_err(|error| format!("could not reach the ai-tools endpoint: {error}"))?;

        *guard = Some(Arc::new(session));
        Ok(Arc::clone(guard.as_ref().expect("just assigned")))
    }

    async fn call_tool(&self, name: &str, arguments: Option<JsonObject>) -> CallToolResponse {
        let refused = |message: String| {
            CallToolResponse::Complete(CallToolResult::error(vec![ContentBlock::text(message)]))
        };

        let Some(bare) = bare_tool_name(name) else {
            return refused(format!(
                "unknown tool: {name}; this server only serves {TOOL_NAME_PREFIX}* tools"
            ));
        };

        match self.forward(bare, arguments).await {
            Ok(result) => CallToolResponse::Complete(result),
            Err(message) => refused(message),
        }
    }

    async fn forward(
        &self,
        bare: &str,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResult, String> {
        let session = self.open_session().await?;
        let params = CallToolRequestParams::new(bare.to_string())
            .with_arguments(arguments.unwrap_or_default());
        tokio::time::timeout(self.call_timeout, session.call_tool(params))
            .await
            .map_err(|_| format!("{bare} did not answer within the bridge timeout"))?
            .map_err(|error| format!("{bare} failed: {error}"))
    }
}

/// Reduce a tool result to plain text.
///
/// The pinned llama.cpp build reads only `content[].text` back from an MCP tool:
/// it concatenates text parts and errors on `isError`. A tool that answers with
/// `structuredContent` alone would therefore reach the model as an empty string,
/// so structured content is rendered as JSON here. Both current ai-tools tools
/// return exactly that, which is why this is not a theoretical path.
fn flatten(result: CallToolResult) -> CallToolResult {
    if let Some(structured) = result.structured_content.clone() {
        let rendered = serde_json::to_string(&structured).unwrap_or_else(|_| structured.to_string());
        if result.is_error == Some(true) {
            return CallToolResult::error(vec![ContentBlock::text(rendered)]);
        }
        return CallToolResult::success(vec![ContentBlock::text(rendered)]);
    }

    let mut text = String::new();
    let mut push = |chunk: &str| {
        if chunk.is_empty() {
            return;
        }
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(chunk);
    };
    for block in &result.content {
        match block {
            ContentBlock::Text(block) => push(&block.text),
            ContentBlock::Resource(embedded) => push(&embedded.get_text()),
            // Image, audio and resource-link blocks are not shapes these tools
            // emit. Rendering them as JSON keeps an unexpected shape visible in
            // the transcript instead of silently dropping content.
            other => push(&serde_json::to_string(other).unwrap_or_default()),
        }
    }

    if result.is_error == Some(true) {
        return CallToolResult::error(vec![ContentBlock::text(text)]);
    }
    CallToolResult::success(vec![ContentBlock::text(text)])
}

/// The stdio half of the bridge.
#[derive(Clone)]
struct StdioBridge {
    bridge: Bridge,
}

impl ServerHandler for StdioBridge {
    fn get_info(&self) -> InitializeResult {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(
                "Tools from this host's ai-tools MCP endpoint: web_search over the local \
                 SearXNG instance, and document conversion. They are forwarded to that endpoint, \
                 which owns the file access policy. Prefer the user's own files and context for \
                 questions about their data.",
            )
    }

    fn supported_protocol_versions(&self) -> std::borrow::Cow<'static, [ProtocolVersion]> {
        std::borrow::Cow::Borrowed(std::slice::from_ref(&STDIO_PROTOCOL_VERSION))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let tools = self
            .bridge
            .list_tools()
            .await
            .map_err(|message| ErrorData::internal_error(message, None))?;
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        Ok(self
            .bridge
            .call_tool(request.name.as_ref(), request.arguments)
            .await)
    }
}

/// The upstream tool name a wire name maps to, or `None` for anything this
/// bridge does not serve.
///
/// A name outside the prefix is refused rather than forwarded: the bridge exists
/// to publish ai-tools' tools, so accepting an arbitrary name would turn it into
/// a pass-through for whatever else a caller decides to spell.
fn bare_tool_name(name: &str) -> Option<&str> {
    name.strip_prefix(TOOL_NAME_PREFIX)
        .filter(|bare| !bare.is_empty())
}

/// Run the bridge on stdin/stdout until llama.cpp closes the pipes.
///
/// The only names the bridge forwards are the ones llama.cpp advertised with its
/// own `ai_tools_` prefix, and the check lives in [`StdioBridge::call_tool`] on
/// the single path that reaches ai-tools. A refusal there is an ordinary tool
/// error, which llama.cpp renders to the model, rather than a transport failure
/// that would be invisible.
pub async fn serve_stdio() -> Result<(), Box<dyn std::error::Error>> {
    let bridge = Bridge::from_env()?;
    eprintln!(
        "ai-tools bridge on stdio, forwarding to {}",
        bridge.upstream_url
    );
    let running = StdioBridge { bridge }
        .serve(stdio())
        .await
        .map_err(|error| format!("stdio transport failed: {error}"))?;
    running
        .waiting()
        .await
        .map_err(|error| format!("stdio bridge task failed: {error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bridge() -> Bridge {
        Bridge::new(
            "http://127.0.0.1:8097/".to_string(),
            Duration::from_millis(200),
            Duration::from_millis(200),
        )
    }

    #[test]
    fn tool_names_carry_the_prefix_llama_expects() {
        assert_eq!(wire_name("web_search"), "ai_tools_web_search");
        assert_eq!(
            wire_name("convert_document"),
            "ai_tools_convert_document"
        );
    }

    #[test]
    fn only_prefixed_non_empty_names_are_forwarded() {
        assert_eq!(
            bare_tool_name("ai_tools_web_search"),
            Some("web_search")
        );
        assert_eq!(bare_tool_name("ai_tools_"), None);
        assert_eq!(bare_tool_name("web_search"), None);
        assert_eq!(
            bare_tool_name("ai_tools_exec_shell_command"),
            Some("exec_shell_command")
        );
    }

    #[tokio::test]
    async fn a_name_outside_the_prefix_is_refused_without_an_upstream_call() {
        let response = bridge().call_tool("exec_shell_command", None).await;
        assert_error(&response);
    }

    #[tokio::test]
    async fn a_bare_prefix_with_no_tool_is_refused() {
        assert_error(&bridge().call_tool("ai_tools_", None).await);
    }

    #[tokio::test]
    async fn an_unreachable_upstream_becomes_a_tool_error_not_a_hang() {
        // Nothing listens on this port, so the connect timeout is what ends the
        // call. A bridge that panicked or blocked instead would take llama.cpp's
        // worker down rather than returning an error.
        let response = bridge().call_tool("ai_tools_web_search", None).await;
        assert_error(&response);
    }

    fn assert_error(response: &CallToolResponse) {
        let CallToolResponse::Complete(result) = response else {
            panic!("expected a complete tool result");
        };
        assert_eq!(result.is_error, Some(true));
        let CallToolResponse::Complete(_) = response else {
            unreachable!()
        };
    }

    #[test]
    fn upstream_url_must_be_loopback() {
        assert_eq!(
            parse_upstream_url("http://127.0.0.1:8097").unwrap(),
            "http://127.0.0.1:8097"
        );
        assert!(parse_upstream_url("http://localhost:8097/mcp").is_ok());
        assert!(parse_upstream_url("http://127.5.5.5:8097").is_ok());
        assert!(parse_upstream_url("http://10.0.0.5:8097").is_err());
        assert!(parse_upstream_url("http://tools.example.org").is_err());
        assert!(parse_upstream_url("http://169.254.169.254").is_err());
        assert!(parse_upstream_url("file:///etc/passwd").is_err());
    }

    #[test]
    fn the_bridge_serves_only_the_revision_llama_speaks() {
        assert_eq!(STDIO_PROTOCOL_VERSION.as_str(), "2024-11-05");
    }

    #[test]
    fn a_structured_tool_result_reaches_the_model_as_text() {
        let flattened = flatten(CallToolResult::success(vec![ContentBlock::json(
            serde_json::json!({ "returned": 1 }),
        )
        .unwrap()]));
        assert_eq!(flattened.is_error, Some(false));
        assert!(
            flattened
                .content
                .iter()
                .any(|block| matches!(block, ContentBlock::Text(text) if text.text.contains("returned")))
        );
    }

    #[test]
    fn a_text_tool_result_is_passed_through() {
        let flattened = flatten(CallToolResult::success(vec![ContentBlock::text("hello")]));
        assert_eq!(flattened.content.len(), 1);
        assert!(matches!(
            &flattened.content[0],
            ContentBlock::Text(text) if text.text == "hello"
        ));
    }

    #[test]
    fn several_text_blocks_are_joined() {
        let flattened = flatten(CallToolResult::success(vec![
            ContentBlock::text("one"),
            ContentBlock::text("two"),
        ]));
        assert!(matches!(
            &flattened.content[0],
            ContentBlock::Text(text) if text.text == "one\ntwo"
        ));
    }

    #[test]
    fn an_upstream_error_stays_an_error() {
        let flattened = flatten(CallToolResult::error(vec![ContentBlock::text("refused")]));
        assert_eq!(flattened.is_error, Some(true));
        assert!(matches!(
            &flattened.content[0],
            ContentBlock::Text(text) if text.text == "refused"
        ));
    }

    #[test]
    fn an_empty_result_is_still_a_successful_tool_call() {
        // ai-tools with no tools registered answers tools/list with an empty
        // set; that must not read as an error to llama.cpp.
        let flattened = flatten(CallToolResult::success(vec![]));
        assert_eq!(flattened.is_error, Some(false));
    }
}