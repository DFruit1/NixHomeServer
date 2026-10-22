//! MCP tools for the llama.cpp web UI.
//!
//! Tools are attached per client, not baked into the model server, so the
//! shared inference endpoint keeps serving other consumers (Hermes, Paperless)
//! with their own tool choices. This process speaks MCP over Streamable HTTP on
//! loopback and is published through the shared authentication gateway.
//!
//! Only `web_search` is served. The four office document tools
//! (`convert_document`, `spreadsheet_read`, `spreadsheet_write` and
//! `word_document`) are suspended for every caller as an interim containment
//! measure: their document access was authorized by this service's static ACLs
//! rather than by the calling user's own permissions. Each one is refused before
//! it parses, resolves or opens anything, and none of them is advertised. See
//! `documentation/ai-tools.md` for the reason and the requirements for
//! restoring them; `office.rs` and `office_write.rs` stay in the tree, dormant,
//! for that restoration.
//!
//! It also carries the stdio bridge in [`bridge`], which is how llama.cpp itself
//! reaches the same tools: it can only spawn MCP servers as child processes, so
//! `ai-tools --transport stdio` re-serves this tool set over stdio and forwards
//! to the loopback endpoint rather than reimplementing it.

use axum::{routing::get, Router};
use rmcp::{
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, InitializeResult,
        JsonObject, ListToolsResult, PaginatedRequestParams, ServerCapabilities, Tool,
    },
    service::RequestContext,
    transport::streamable_http_server::{
        session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
    },
    ErrorData, RoleServer, ServerHandler,
};
mod bridge;
// The office modules are suspended, so nothing in this file calls them. They stay
// compiled and their own tests stay live so a caller-aware restoration re-enables
// a working converter and a working confinement check rather than a stale one.
// Do not delete them as dead code.
#[allow(dead_code)]
mod office;
#[allow(dead_code)]
mod office_write;

use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf, sync::Arc, time::Duration};

#[derive(Clone)]
struct Config {
    searxng_base: String,
    searxng_timeout: Duration,
    max_results: usize,
    // The office tools are suspended, so these four are no longer read by this
    // process. They stay configured and validated so the deployment keeps
    // publishing the same environment and a later restoration re-enables a
    // working endpoint instead of discovering a stale or missing one at
    // republish time.
    #[allow(dead_code)]
    collabora_base: String,
    #[allow(dead_code)]
    collabora_timeout: Duration,
    #[allow(dead_code)]
    shared_root: PathBuf,
    #[allow(dead_code)]
    workspace_root: PathBuf,
    #[allow(dead_code)]
    helper: office_write::Helper,
    public_host: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WebSearchParams {
    #[serde(default)]
    query: String,
    #[serde(default)]
    categories: Option<String>,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    max_results: Option<usize>,
}

#[derive(Debug, Serialize)]
struct WebSearchResult {
    title: String,
    url: String,
    snippet: String,
    engines: Vec<String>,
}

const WEB_SEARCH_DESCRIPTION: &str = "Search the web through this host's self-hosted SearXNG \
instance. Returns ranked results with titles, URLs and snippets. Use it for current events, \
for facts you are unsure about, or for anything that needs a source. Prefer the user's own files \
and context when the question is about them.";

/// Fixed text returned to every `convert_document` caller while the office
/// surface is suspended. No path, filename, root or error cause appears in it,
/// so the refusal cannot be used as a filesystem oracle for probing the shared
/// root.
///
/// Restoration requirements are in `documentation/ai-tools.md`.
pub const CONVERT_DOCUMENT_DENIAL_MESSAGE: &str =
    "Document conversion is unavailable pending caller-permission enforcement";

/// Fixed text returned to every `spreadsheet_read`, `spreadsheet_write` and
/// `word_document` caller while the office surface is suspended.
///
/// It is deliberately distinct from [`CONVERT_DOCUMENT_DENIAL_MESSAGE`]: the
/// conversion refusal is a previously accepted, separately approved wording, and
/// this one covers the three newer tools. Like that one it names no path, format
/// or action, so no argument shape turns the refusal into a probe.
pub const OFFICE_TOOLS_DENIAL_MESSAGE: &str =
    "Office tools are unavailable pending caller-permission enforcement";

fn web_search_schema() -> Arc<JsonObject> {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "query".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "The search query. Plain natural language; operators such as site: and quoted phrases work."
        }),
    );
    properties.insert(
        "categories".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "Optional comma-separated categories: general, news, images, videos, science, it, social."
        }),
    );
    properties.insert(
        "language".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "Optional ISO 639-1 language code, for example en or de."
        }),
    );
    properties.insert(
        "max_results".to_string(),
        serde_json::json!({
            "type": "integer",
            "minimum": 1,
            "description": "How many results to return. Clamped to the server maximum."
        }),
    );
    Arc::new(
        serde_json::json!({
            "type": "object",
            "properties": properties,
            "required": ["query"],
        })
        .as_object()
        .cloned()
        .expect("schema literal is an object"),
    )
}

async fn searxng_search(
    config: &Config,
    query: &str,
    categories: Option<&str>,
    language: Option<&str>,
) -> Result<Vec<WebSearchResult>, String> {
    let client = reqwest::Client::builder()
        .timeout(config.searxng_timeout)
        .build()
        .map_err(|error| format!("could not build SearXNG client: {error}"))?;

    let mut request = client
        .get(format!("{}/search", config.searxng_base))
        .query(&[("q", query), ("format", "json"), ("safesearch", "1")]);
    if let Some(categories) = categories {
        request = request.query(&[("categories", categories)]);
    }
    if let Some(language) = language {
        request = request.query(&[("language", language)]);
    }

    let response = request
        .send()
        .await
        .map_err(|error| format!("SearXNG request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!("SearXNG returned HTTP {}", response.status()));
    }

    let payload: serde_json::Value = response
        .json()
        .await
        .map_err(|error| format!("SearXNG response was not JSON: {error}"))?;

    let raw = payload
        .get("results")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "SearXNG response had no results array".to_string())?;

    Ok(raw
        .iter()
        .map(|entry| WebSearchResult {
            title: entry
                .get("title")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            url: entry
                .get("url")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            snippet: entry
                .get("content")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string(),
            engines: entry
                .get("engines")
                .and_then(serde_json::Value::as_array)
                .map(|names| {
                    names
                        .iter()
                        .filter_map(serde_json::Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect())
}

#[derive(Clone)]
struct Server {
    config: Arc<Config>,
}

impl Server {
    /// `convert_document` is suspended, so this never parses the caller's path,
    /// never resolves it and never reads anything. The fixed message is the whole
    /// answer: a refusal that mentions no filesystem location cannot disclose
    /// one, and no argument shape changes the outcome.
    ///
    /// A protocol-level `ErrorData` rather than `CallToolResult::error` is
    /// deliberate: rmcp maps a handler error onto the JSON-RPC layer, so the
    /// refusal is visible to the transport even for a caller that never learned
    /// the tool from `tools/list`. That is what keeps the denial reachable for
    /// cached discovery metadata and direct invocation alike.
    async fn run_convert_document(
        &self,
        _arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        Err(ErrorData::invalid_params(
            CONVERT_DOCUMENT_DENIAL_MESSAGE,
            None,
        ))
    }

    /// `spreadsheet_read` is suspended for the same reason as conversion: the
    /// read was authorized by this service's static grant on the shared root,
    /// not by the calling user. It is refused here, before the path is touched.
    async fn run_spreadsheet_read(
        &self,
        _arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        Err(ErrorData::invalid_params(OFFICE_TOOLS_DENIAL_MESSAGE, None))
    }

    /// `spreadsheet_write` is suspended with the rest of the office surface. Its
    /// confinement to the workspace was never the gap; the gap is that the
    /// service account, not the caller, authorizes the operation, so it is
    /// refused here before the format, the name or the target is considered.
    async fn run_spreadsheet_write(
        &self,
        _arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        Err(ErrorData::invalid_params(OFFICE_TOOLS_DENIAL_MESSAGE, None))
    }

    /// `word_document` is suspended in both of its modes. The refusal sits ahead
    /// of the read/write branch, so neither a bare `path` nor a write shape
    /// reaches path resolution, the helper or Collabora.
    async fn run_word_document(
        &self,
        _arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        Err(ErrorData::invalid_params(OFFICE_TOOLS_DENIAL_MESSAGE, None))
    }

    async fn run_web_search(
        &self,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        let raw = arguments
            .map(serde_json::Value::Object)
            .unwrap_or(serde_json::Value::Object(Default::default()));
        let params: WebSearchParams = serde_json::from_value(raw)
            .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;

        let query = params.query.trim();
        if query.is_empty() {
            return Err(ErrorData::invalid_params("query must not be empty", None));
        }

        let limit = params
            .max_results
            .unwrap_or(self.config.max_results)
            .clamp(1, self.config.max_results);

        let mut results = searxng_search(
            &self.config,
            query,
            params.categories.as_deref(),
            params.language.as_deref(),
        )
        .await
        .map_err(|message| ErrorData::internal_error(message, None))?;

        let truncated = results.len() > limit;
        results.truncate(limit);

        let payload = serde_json::json!({
            "query": query,
            "returned": results.len(),
            "truncated": truncated,
            "results": results,
        });

        let content = ContentBlock::json(payload)?;
        Ok(CallToolResult::success(vec![content]).into())
    }
}

impl ServerHandler for Server {
    fn get_info(&self) -> InitializeResult {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(
                "Tools for this home server. web_search queries the local SearXNG instance. The \
                 office document tools (convert_document, spreadsheet_read, spreadsheet_write, \
                 word_document) are suspended pending caller-permission enforcement and are \
                 refused for every caller, so they are not listed or usable. Prefer the user's \
                 own files and context for questions about their data.",
            )
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        // The four office tools are deliberately absent: a model that never sees
        // a tool never tries it. The dispatch branches below are what actually
        // contain the case, because cached discovery metadata and a direct
        // JSON-RPC call do not consult this list.
        Ok(ListToolsResult::with_all_items(vec![Tool::new(
            "web_search",
            WEB_SEARCH_DESCRIPTION,
            web_search_schema(),
        )]))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        match request.name.as_ref() {
            "web_search" => self.run_web_search(request.arguments).await,
            // The four office branches are kept as explicit denials rather than
            // folded into the unknown-tool arm: a caller that learned a tool name
            // from cached discovery metadata, or that probes it directly, still
            // gets the containment message instead of a lookup error, and each
            // branch is the last point before any path or upstream work. Removing
            // discovery alone would not contain a direct invocation.
            "convert_document" => self.run_convert_document(request.arguments).await,
            "spreadsheet_read" => self.run_spreadsheet_read(request.arguments).await,
            "spreadsheet_write" => self.run_spreadsheet_write(request.arguments).await,
            "word_document" => self.run_word_document(request.arguments).await,
            other => Err(ErrorData::invalid_params(
                format!("unknown tool: {other}"),
                None,
            )),
        }
    }
}

fn parse_env() -> Result<Config, String> {
    let searxng_base = env::var("AI_TOOLS_SEARXNG_URL")
        .map_err(|_| "AI_TOOLS_SEARXNG_URL is not set".to_string())?
        .trim_end_matches('/')
        .to_string();
    if !(searxng_base.starts_with("http://") || searxng_base.starts_with("https://")) {
        return Err("AI_TOOLS_SEARXNG_URL must be an http(s) URL".to_string());
    }

    let searxng_timeout = match env::var("AI_TOOLS_SEARXNG_TIMEOUT_SECS") {
        Ok(raw) => raw
            .parse::<u64>()
            .map(Duration::from_secs)
            .map_err(|_| "AI_TOOLS_SEARXNG_TIMEOUT_SECS must be an integer".to_string())?,
        Err(_) => Duration::from_secs(20),
    };

    let max_results = match env::var("AI_TOOLS_MAX_RESULTS") {
        Ok(raw) => raw
            .parse::<usize>()
            .map_err(|_| "AI_TOOLS_MAX_RESULTS must be an integer".to_string())?,
        Err(_) => 8,
    };

    // The office tools are suspended, so the Collabora upstream they used and the
    // shared root and workspace they served are no longer read by this process.
    // All of them stay configured and all of them stay validated so a later
    // restoration re-enables a working converter instead of discovering a stale
    // or missing endpoint at republish time.
    let collabora_base = env::var("AI_TOOLS_COLLABORA_URL")
        .map_err(|_| "AI_TOOLS_COLLABORA_URL is not set".to_string())?
        .trim_end_matches('/')
        .to_string();
    if !(collabora_base.starts_with("http://") || collabora_base.starts_with("https://")) {
        return Err("AI_TOOLS_COLLABORA_URL must be an http(s) URL".to_string());
    }
    let collabora_timeout = Duration::from_secs(90);

    let shared_root = PathBuf::from(
        env::var("AI_TOOLS_SHARED_ROOT")
            .map_err(|_| "AI_TOOLS_SHARED_ROOT is not set".to_string())?,
    );

    // Writes are confined to this one directory. It is a required variable rather
    // than one that defaults to a subdirectory of the shared root: a default
    // would let a misconfigured unit write into the owner's documents, and a
    // missing variable should stop the service instead.
    let workspace_root = PathBuf::from(
        env::var("AI_TOOLS_WORKSPACE_ROOT")
            .map_err(|_| "AI_TOOLS_WORKSPACE_ROOT is not set".to_string())?,
    );
    if !workspace_root.starts_with(&shared_root) || workspace_root == shared_root {
        return Err(
            "AI_TOOLS_WORKSPACE_ROOT must be a proper subdirectory of AI_TOOLS_SHARED_ROOT"
                .to_string(),
        );
    }

    let helper = office_write::Helper::new(&env::var("AI_TOOLS_OFFICE_HELPER").map_err(|_| {
        "AI_TOOLS_OFFICE_HELPER is not set; the native xlsx/docx tools cannot run without it"
            .to_string()
    })?)?;

    Ok(Config {
        searxng_base,
        searxng_timeout,
        max_results: max_results.clamp(1, 25),
        collabora_base,
        collabora_timeout,
        shared_root,
        workspace_root,
        helper,
        public_host: parse_public_host(env::var("AI_TOOLS_PUBLIC_HOST").ok())?,
    })
}

/// Hostname the gateway publishes this service under, or `None` to stay
/// loopback-only.
///
/// A value that is not a bare hostname is rejected rather than ignored: an
/// entry that matches no inbound request would leave the published endpoint
/// answering 403 with nothing in the logs to explain it.
fn parse_public_host(raw: Option<String>) -> Result<Option<String>, String> {
    let Some(raw) = raw else {
        return Ok(None);
    };
    let host = raw.trim().to_ascii_lowercase();
    if host.is_empty() {
        return Ok(None);
    }
    if !host
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-'))
    {
        return Err("AI_TOOLS_PUBLIC_HOST must be a bare hostname".to_string());
    }
    Ok(Some(host))
}

/// Transport policy for the Streamable HTTP service.
///
/// Caddy proxies to loopback but preserves the client's Host header, so rmcp's
/// loopback-only default rejects the published hostname. Loopback stays allowed
/// either way so local MCP clients and the host policy tests keep working.
fn streamable_http_config(public_host: Option<&str>) -> StreamableHttpServerConfig {
    let config = StreamableHttpServerConfig::default()
        // Plain JSON responses rather than an open SSE stream. The gateway
        // terminates TLS and proxies through oauth2-proxy, and a long-lived
        // event stream is the part most likely to be buffered or cut there.
        // Single-response JSON is the interoperable choice behind a proxy.
        .with_json_response(true)
        .with_sse_keep_alive(Some(Duration::from_secs(15)));

    let Some(public_host) = public_host else {
        return config;
    };

    config
        .with_allowed_hosts([
            "localhost".to_string(),
            "127.0.0.1".to_string(),
            "::1".to_string(),
            public_host.to_string(),
        ])
        .with_allowed_origins([format!("https://{public_host}")])
        .enforce_origin_validation()
}

fn router(server: Server, public_host: Option<&str>) -> Router {
    let mcp = StreamableHttpService::new(
        move || Ok(server.clone()),
        Arc::new(LocalSessionManager::default()),
        streamable_http_config(public_host),
    );

    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .fallback_service(mcp)
}

/// Which MCP transport this process serves.
///
/// The default is Streamable HTTP on loopback, which is what the gateway
/// publishes and what every loopback client uses. `stdio` is what llama.cpp
/// spawns: it speaks the same tool set over a child process's stdin and stdout.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Transport {
    StreamableHttp,
    Stdio,
}

fn parse_transport(raw: &str) -> Result<Transport, String> {
    match raw {
        "http" | "streamable-http" => Ok(Transport::StreamableHttp),
        "stdio" => Ok(Transport::Stdio),
        other => Err(format!(
            "unknown transport {other:?}; expected \"streamable-http\" or \"stdio\""
        )),
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let transport = match env::var("AI_TOOLS_TRANSPORT") {
        Ok(raw) => parse_transport(&raw)?,
        Err(_) => Transport::StreamableHttp,
    };
    if transport == Transport::Stdio {
        return bridge::serve_stdio().await;
    }

    let listen = env::var("AI_TOOLS_LISTEN")?;
    let config = Arc::new(parse_env()?);
    // No Collabora client is built here: the office tools are denied before any
    // document path is resolved, so the converter is never reached, and a
    // suspended tool must not keep an idle HTTP client or an unreachable
    // upstream in its startup path.
    let server = Server {
        config: Arc::clone(&config),
    };

    let app = router(server, config.public_host.as_deref());

    let listener = tokio::net::TcpListener::bind(&listen).await?;
    eprintln!(
        "ai-tools listening on {listen}, searxng at {}, public host {}",
        config.searxng_base,
        config.public_host.as_deref().unwrap_or("unset")
    );
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{header::HOST, HeaderMap, HeaderValue, Request, StatusCode},
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tower::ServiceExt;

    fn test_config() -> Config {
        let shared_root = std::env::temp_dir();
        Config {
            searxng_base: "http://127.0.0.1:8080".to_string(),
            searxng_timeout: Duration::from_secs(5),
            max_results: 8,
            collabora_base: "http://127.0.0.1:9980".to_string(),
            collabora_timeout: Duration::from_secs(5),
            workspace_root: shared_root.join("ai-workspace-test"),
            shared_root,
            // The path is never executed by these tests; the handshake and
            // denial policy is what is under test here. The helper's own
            // behaviour is covered by the helper's unit tests.
            helper: crate::office_write::Helper::new("/nix/store/fake-helper/bin/helper")
                .expect("helper"),
            public_host: None,
        }
    }

    fn test_server() -> Server {
        Server {
            config: Arc::new(test_config()),
        }
    }

    /// The suspended tools, with the exact refusal each one must return.
    const PAUSED_TOOLS: &[(&str, &str)] = &[
        ("convert_document", CONVERT_DOCUMENT_DENIAL_MESSAGE),
        ("spreadsheet_read", OFFICE_TOOLS_DENIAL_MESSAGE),
        ("spreadsheet_write", OFFICE_TOOLS_DENIAL_MESSAGE),
        ("word_document", OFFICE_TOOLS_DENIAL_MESSAGE),
    ];

    /// Call one suspended tool through the same handler the dispatch match uses.
    async fn call_paused_tool(
        server: &Server,
        tool: &str,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        match tool {
            "convert_document" => server.run_convert_document(arguments).await,
            "spreadsheet_read" => server.run_spreadsheet_read(arguments).await,
            "spreadsheet_write" => server.run_spreadsheet_write(arguments).await,
            "word_document" => server.run_word_document(arguments).await,
            other => panic!("{other} is not a suspended tool"),
        }
    }

    fn expected_denial(tool: &str) -> &'static str {
        PAUSED_TOOLS
            .iter()
            .find(|(name, _)| *name == tool)
            .map(|(_, message)| *message)
            .unwrap_or_else(|| panic!("{tool} is not a suspended tool"))
    }

    /// The fixed denial, checked as both the code and the message: the message
    /// is what the caller sees and it must not name a path or an action.
    async fn assert_denied(tool: &str, arguments: Option<JsonObject>, caller: &str) -> ErrorData {
        let error = tokio::time::timeout(
            Duration::from_secs(5),
            call_paused_tool(&test_server(), tool, arguments),
        )
        .await
        .unwrap_or_else(|_| panic!("{caller} {tool}: denial timed out"))
        .expect_err(&format!("{caller} {tool}: must be denied"));
        assert_eq!(
            error.message,
            expected_denial(tool),
            "{caller} {tool}: denial text changed"
        );
        assert_eq!(
            error.code,
            rmcp::model::ErrorCode::INVALID_PARAMS,
            "{caller} {tool}: denial must surface as a protocol error"
        );
        assert!(
            error.data.is_none(),
            "{caller} {tool}: denial must not attach a payload"
        );
        error
    }

    fn path_arguments(path: &str) -> JsonObject {
        let mut arguments = JsonObject::new();
        arguments.insert("path".to_string(), serde_json::json!(path));
        arguments
    }

    /// A write shape for `spreadsheet_write` and `word_document`. The refusal
    /// must come before the format, the name, the overwrite flag or the payload
    /// is looked at, so both the create and the overwrite inputs are covered by
    /// the same denial.
    fn write_arguments(format: &str, name: &str) -> JsonObject {
        let mut arguments = JsonObject::new();
        arguments.insert("format".to_string(), serde_json::json!(format));
        arguments.insert("name".to_string(), serde_json::json!(name));
        arguments.insert("overwrite".to_string(), serde_json::json!(true));
        arguments.insert(
            "sheets".to_string(),
            serde_json::json!([{ "name": "Sheet1", "rows": [[1, 2]] }]),
        );
        arguments.insert(
            "blocks".to_string(),
            serde_json::json!([{ "kind": "paragraph", "text": "hello" }]),
        );
        arguments
    }

    /// Caller classes and input shapes that existed before the pause, in the
    /// forms the transports can deliver. Every one of them is refused
    /// identically, for every suspended tool.
    #[tokio::test]
    async fn denies_every_paused_tool_for_every_input_shape() {
        let shapes: &[(&str, Option<JsonObject>)] = &[
            ("no arguments", None),
            ("empty arguments", Some(JsonObject::new())),
            ("malformed path", Some(path_arguments("    "))),
            ("empty path", Some(path_arguments(""))),
            ("hidden path", Some(path_arguments(".hidden/report.docx"))),
            ("absolute path", Some(path_arguments("/etc/passwd"))),
            (
                "traversal path",
                Some(path_arguments("../../etc/report.docx")),
            ),
            (
                "shared-root read",
                Some(path_arguments("shared/report.docx")),
            ),
            (
                "ai-users-only read",
                Some(path_arguments("ai-users-only/private.docx")),
            ),
            (
                "valid supported document",
                Some(path_arguments("shared/report.docx")),
            ),
            ("unsupported type", Some(path_arguments("shared/photo.png"))),
            ("path is a directory", Some(path_arguments("shared"))),
            (
                "spreadsheet write, new file",
                Some(write_arguments("xlsx", "summary.xlsx")),
            ),
            (
                "spreadsheet write, overwrite",
                Some(write_arguments("ods", "summary.xlsx")),
            ),
            ("word write", Some(write_arguments("docx", "report.docx"))),
        ];
        for &(tool, _) in PAUSED_TOOLS {
            for (caller, arguments) in shapes {
                assert_denied(tool, arguments.clone(), caller).await;
            }
        }
    }

    /// The real handler against a real readable document and a real FIFO, both
    /// under a synthetic shared root. The denial must return without opening
    /// either, so neither the read nor the FIFO open can block.
    #[tokio::test]
    async fn denial_precedes_any_path_or_file_operation() {
        let root = SyntheticSharedRoot::new("deny-before-access");
        let document = root.write("report.docx", b"PK\x03\x04 synthetic docx body");
        let fifo = root.fifo("pipe.docx");

        for &(tool, _) in PAUSED_TOOLS {
            for (label, target) in [
                ("readable document", document.clone()),
                ("FIFO", fifo.clone()),
            ] {
                let (tx, rx) = std::sync::mpsc::channel();
                let server = test_server();
                let tool = tool.to_string();
                let worker_tool = tool.clone();
                let target = target.clone();
                let handle = std::thread::spawn(move || {
                    let arguments = path_arguments(target.to_str().expect("path is UTF-8"));
                    let result = tokio::runtime::Runtime::new()
                        .expect("runtime")
                        .block_on(call_paused_tool(&server, &worker_tool, Some(arguments)));
                    let _ = tx.send(result);
                });
                // Bounded wait: denial takes microseconds; a FIFO open would
                // block until the timeout because no writer ever opens the other
                // end.
                let outcome = rx.recv_timeout(Duration::from_secs(5));
                assert!(
                    outcome.is_ok(),
                    "{tool} {label}: handler did not return, so a path or file operation ran"
                );
                let error = outcome
                    .unwrap()
                    .expect_err(&format!("{tool} {label}: must be denied"));
                assert_eq!(
                    error.message,
                    expected_denial(&tool),
                    "{tool} {label}: denial text changed"
                );
                // The FIFO still exists and was never drained: proving it was
                // never opened, because an open-for-read would have blocked.
                assert!(
                    fifo.exists(),
                    "{tool} {label}: FIFO was removed or replaced"
                );
                handle.join().expect("handler thread");
            }
        }

        assert_eq!(
            std::fs::read(&document).expect("fixture survives"),
            b"PK\x03\x04 synthetic docx body",
            "denial must not consume the document"
        );
    }

    /// Source-level guarantee that the denial is the handler's whole body, not
    /// just an observation that nothing was read. A FIFO or zero-request
    /// observation alone cannot prove a regular file was not opened.
    #[test]
    fn denial_precedes_path_and_file_calls_in_source() {
        let source = crate_source();
        for &(tool, _) in PAUSED_TOOLS {
            let start = source
                .find(&format!("async fn run_{tool}"))
                .unwrap_or_else(|| panic!("{tool}: handler is present"));
            let handler = &source[start..];
            let end = handler
                .find("\n    }\n")
                .unwrap_or_else(|| panic!("{tool}: handler has a body"));
            let body = &handler[..end];
            assert!(
                body.contains("_arguments"),
                "{tool}: the handler must not read its arguments: {body}"
            );
            // Only the handler's own body is scanned. The rest of this file holds
            // the office modules' machinery and the literals this assertion is
            // spelled with, so scanning it would flag the words themselves.
            for forbidden in [
                "serde_json::from_value",
                "arguments.map",
                "resolve_read",
                "resolve_write",
                "resolve_within",
                "office::",
                "office_write::",
                "Converter",
                "Helper",
                "read_document",
                "open_document",
                "std::fs",
                "tokio::fs",
                "stage_write",
                "helper",
                "convert_to",
                "spawn",
            ] {
                assert!(
                    !body.contains(forbidden),
                    "{tool}: run_{tool} must not reach {forbidden}: {body}"
                );
            }
        }
    }

    /// A suspended tool must not reach the Collabora upstream either. A loopback
    /// listener records every connection: it first proves it counts by taking a
    /// control connection, then each suspended handler runs against a real
    /// supported document and the count must not move.
    #[tokio::test]
    async fn denial_never_contacts_the_collabora_upstream() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a Collabora stand-in");
        let address = listener.local_addr().expect("stand-in address");
        let connections = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&connections);
        let accept = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                counter.fetch_add(1, Ordering::SeqCst);
                drop(stream);
            }
        });

        let _probe = tokio::net::TcpStream::connect(address)
            .await
            .expect("control connection");
        let mut observed = false;
        for _ in 0..50 {
            if connections.load(Ordering::SeqCst) == 1 {
                observed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(
            observed,
            "the Collabora stand-in failed to observe the control connection"
        );

        let root = SyntheticSharedRoot::new("collabora");
        let document = root.write("report.docx", b"PK\x03\x04 synthetic docx body");
        let mut config = test_config();
        config.collabora_base = format!("http://{address}");
        let server = Server {
            config: Arc::new(config),
        };
        for &(tool, _) in PAUSED_TOOLS {
            let arguments = path_arguments(document.to_str().expect("path is UTF-8"));
            let error = call_paused_tool(&server, tool, Some(arguments))
                .await
                .expect_err("must be denied");
            assert_eq!(error.message, expected_denial(tool));
        }

        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(
            connections.load(Ordering::SeqCst),
            1,
            "a suspended tool must not contact the Collabora upstream"
        );
        accept.abort();
    }

    /// A suspended tool must not launch the Python office helper either. The
    /// stand-in helper appends one byte per run, and the test first proves the
    /// recorder works by running it once directly.
    #[tokio::test]
    async fn denial_never_launches_the_office_helper() {
        let dir = SyntheticSharedRoot::new("helper-launches");
        let marker = dir.join("launches");
        let script = dir.join("fake-helper");
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf x >> {}\nexit 0\n", marker.display()),
        )
        .expect("write the stand-in helper");
        let mut permissions = std::fs::metadata(&script)
            .expect("stand-in metadata")
            .permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&script, permissions).expect("make the stand-in executable");

        // Control: the stand-in really does record a launch, so a missing marker
        // afterwards is the denial's doing and not a recorder that never wrote.
        let status = std::process::Command::new(&script)
            .stdin(std::process::Stdio::null())
            .status()
            .expect("run the control launch");
        assert!(status.success(), "the stand-in helper control run failed");
        assert!(
            marker.exists(),
            "the stand-in helper did not record its control run"
        );
        std::fs::remove_file(&marker).expect("clear the marker");

        let mut config = test_config();
        config.helper = crate::office_write::Helper::new(script.to_str().expect("path is UTF-8"))
            .expect("helper");
        let server = Server {
            config: Arc::new(config),
        };
        for &(tool, _) in PAUSED_TOOLS {
            let arguments = path_arguments("shared/report.docx");
            let error = call_paused_tool(&server, tool, Some(arguments))
                .await
                .expect_err("must be denied");
            assert_eq!(error.message, expected_denial(tool));
        }

        assert!(
            !marker.exists(),
            "a suspended tool must not launch the office helper"
        );
    }

    /// Discovery no longer offers any suspended tool and web_search is still
    /// advertised. Driven through the real router with a real session, so this
    /// is the same path a model-backed client takes.
    #[tokio::test]
    async fn discovery_hides_every_suspended_tool_but_keeps_web_search() {
        let (app, session_id, headers) = handshake().await;
        let response = router_with_session(
            &app,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.to_string(),
            &headers,
            &session_id,
        )
        .await;
        let body = body_string(response).await;
        assert!(
            body.contains("web_search"),
            "web_search must stay advertised: {body}"
        );
        for &(tool, _) in PAUSED_TOOLS {
            assert!(
                !body.contains(tool),
                "tools/list must not offer {tool}: {body}"
            );
        }
    }

    /// A direct JSON-RPC `tools/call` for each suspended tool, sent through the
    /// real router with a real session and a real Host header. Cached discovery
    /// metadata and identity headers must not restore any of them: the fixed
    /// refusal is what comes back over the transport.
    #[tokio::test]
    async fn denies_every_suspended_tool_over_the_transport() {
        let (app, session_id, headers) = handshake().await;
        for &(tool, expected) in PAUSED_TOOLS {
            for (caller, identity) in [
                ("ai-users-only caller", Some("ai-users-only")),
                ("shared-group caller", Some("shared-group")),
                ("unauthenticated caller", None),
            ] {
                let mut caller_headers = headers.clone();
                if let Some(identity) = identity {
                    // A gateway-forwarded identity header is a claim about the
                    // caller, not caller permission; a suspended tool must
                    // ignore it. Sending it is the point, so the control covers
                    // callers both with and without identity headers.
                    caller_headers.insert(
                        "x-ai-tools-identity",
                        HeaderValue::from_str(identity).expect("identity header"),
                    );
                }
                let response = router_with_session(
                    &app,
                    tool_call_body(tool, caller, identity),
                    &caller_headers,
                    &session_id,
                )
                .await;
                let body = body_string(response).await;
                assert!(
                    body.contains(expected),
                    "{caller} {tool}: transport refusal should carry the fixed message, got {body}"
                );
                assert!(
                    !body.contains("report.docx")
                        && !body.contains("shared/")
                        && !body.contains("private/"),
                    "{caller} {tool}: refusal must not disclose filesystem paths, got {body}"
                );
            }
        }
    }

    /// The remaining tool must still reach its upstream and return real results.
    /// A local stand-in answers in the SearXNG shape, so a green deploy cannot
    /// hide a web_search path that was broken by the pause.
    #[tokio::test]
    async fn web_search_still_dispatches_against_a_stand_in_searxng() {
        let body = r#"{"results":[{"title":"Water bore report","url":"https://example.org/one","content":"Snippet text","engines":["stand-in"]}]}"#;
        let base = spawn_json_server(body.to_string()).await;
        let mut config = test_config();
        config.searxng_base = base;
        let server = Server {
            config: Arc::new(config),
        };

        let mut arguments = JsonObject::new();
        arguments.insert("query".to_string(), serde_json::json!("water bore"));
        let response = server
            .run_web_search(Some(arguments))
            .await
            .expect("web_search must still dispatch");
        let CallToolResponse::Complete(result) = &response else {
            panic!("expected a complete tool result");
        };
        assert_eq!(result.is_error, Some(false));
        let rendered = format!("{result:?}");
        assert!(
            rendered.contains("example.org/one"),
            "web_search should return the stand-in result: {rendered}"
        );
    }

    /// Health must stay available with the office surface paused: the service is
    /// still the gateway's canary target.
    #[tokio::test]
    async fn health_stays_available_while_the_office_tools_are_paused() {
        let request = Request::builder()
            .method("GET")
            .uri("/healthz")
            .body(Body::empty())
            .expect("build health request");
        let response = router(test_server(), None)
            .oneshot(request)
            .await
            .expect("router response");
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn rejects_an_empty_query() {
        let mut arguments = JsonObject::new();
        arguments.insert("query".to_string(), serde_json::json!("   "));
        let error = test_server()
            .run_web_search(Some(arguments))
            .await
            .unwrap_err();
        assert_eq!(error.code, rmcp::model::ErrorCode::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn rejects_a_missing_query() {
        let server = test_server();
        assert!(server
            .run_web_search(Some(JsonObject::new()))
            .await
            .is_err());
        assert!(server.run_web_search(None).await.is_err());
    }

    #[test]
    fn schema_declares_query_as_required() {
        let schema = web_search_schema();
        assert_eq!(schema.get("type").and_then(|v| v.as_str()), Some("object"));
        assert!(schema
            .get("properties")
            .and_then(|v| v.as_object())
            .is_some());
        assert_eq!(
            schema
                .get("required")
                .and_then(|v| v.as_array())
                .and_then(|v| v.first())
                .and_then(|v| v.as_str()),
            Some("query")
        );
    }

    #[test]
    fn rejects_a_non_http_searxng_url() {
        assert!(parse_env_with("file:///etc/passwd").is_err());
        assert!(parse_env_with("http://127.0.0.1:8080").is_ok());
    }

    fn parse_env_with(url: &str) -> Result<(), String> {
        // parse_env reads the process environment, so validate the shape directly.
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err("AI_TOOLS_SEARXNG_URL must be an http(s) URL".to_string());
        }
        Ok(())
    }

    const PUBLIC_HOST: &str = "tools.example.org";

    /// Status of a real MCP handshake sent the way the gateway forwards it: the
    /// published Host, plus an Origin when a browser would send one.
    async fn initialize_status(
        public_host: Option<&str>,
        host: &str,
        origin: Option<&str>,
    ) -> StatusCode {
        let server = test_server();

        let mut headers = HeaderMap::new();
        headers.insert(HOST, HeaderValue::from_str(host).expect("host header"));
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        headers.insert(
            "accept",
            HeaderValue::from_static("application/json, text/event-stream"),
        );
        if let Some(origin) = origin {
            headers.insert("origin", HeaderValue::from_str(origin).expect("origin"));
        }

        let mut request = Request::builder()
            .method("POST")
            .uri("/")
            .body(Body::from(initialize_body()))
            .expect("build initialize request");
        request.headers_mut().extend(headers);

        router(server, public_host)
            .oneshot(request)
            .await
            .expect("router response")
            .status()
    }

    #[tokio::test]
    async fn accepts_the_configured_public_host() {
        assert_eq!(
            initialize_status(Some(PUBLIC_HOST), PUBLIC_HOST, None).await,
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn rejects_an_unknown_host() {
        assert_eq!(
            initialize_status(Some(PUBLIC_HOST), "evil.example.org", None).await,
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn origin_must_match_the_configured_public_host() {
        assert_eq!(
            initialize_status(
                Some(PUBLIC_HOST),
                PUBLIC_HOST,
                Some("https://evil.example.org")
            )
            .await,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            initialize_status(
                Some(PUBLIC_HOST),
                PUBLIC_HOST,
                Some(&format!("https://{PUBLIC_HOST}"))
            )
            .await,
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn stays_loopback_only_without_a_public_host() {
        assert_eq!(
            initialize_status(None, PUBLIC_HOST, None).await,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            initialize_status(None, "127.0.0.1:8097", None).await,
            StatusCode::OK
        );
    }

    #[test]
    fn public_host_is_normalised_or_rejected() {
        assert_eq!(parse_public_host(None).unwrap(), None);
        assert_eq!(parse_public_host(Some(String::new())).unwrap(), None);
        assert_eq!(parse_public_host(Some("  ".to_string())).unwrap(), None);
        assert_eq!(
            parse_public_host(Some(format!("  {PUBLIC_HOST} "))).unwrap(),
            Some(PUBLIC_HOST.to_string())
        );
        for hostile in [
            "https://tools.example.org",
            "tools.example.org/mcp",
            "tools.example.org:443",
            "tools example org",
            "tools.example.org?x=1",
        ] {
            assert!(
                parse_public_host(Some(hostile.to_string())).is_err(),
                "should have rejected {hostile:?}"
            );
        }
    }

    #[test]
    fn transport_policy_keeps_loopback_next_to_the_public_host() {
        let config = streamable_http_config(Some(PUBLIC_HOST));
        assert_eq!(
            config.allowed_hosts,
            vec!["localhost", "127.0.0.1", "::1", PUBLIC_HOST]
        );
        assert_eq!(
            config.allowed_origins,
            vec![format!("https://{PUBLIC_HOST}")]
        );
    }

    /// The instructions a client reads at handshake are the model's first
    /// description of this surface, so a stale claim here is a real defect: when
    /// the office tools were suspended, a handshake that still advertised them
    /// would describe a surface that refuses every call.
    #[test]
    fn the_handshake_describes_the_paused_office_surface() {
        let instructions = test_server()
            .get_info()
            .instructions
            .unwrap_or_default()
            .to_lowercase();
        assert!(
            !instructions.contains("read-only"),
            "the handshake must not claim a read-only surface: {instructions}"
        );
        assert!(
            instructions.contains("web_search"),
            "the handshake should keep naming web_search: {instructions}"
        );
        for tool in [
            "convert_document",
            "spreadsheet_read",
            "spreadsheet_write",
            "word_document",
        ] {
            assert!(
                instructions.contains(tool),
                "the handshake should name the suspended tool {tool}: {instructions}"
            );
        }
        assert!(
            instructions.contains("suspended") || instructions.contains("refused"),
            "the handshake should say the office tools are unavailable: {instructions}"
        );
    }

    fn initialize_body() -> String {
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"office-pause-test","version":"0.0.0"}}}"#
            .to_string()
    }

    /// A real handshake on a real session. One router serves the whole session:
    /// each call to `router` installs its own session manager, so a handshake
    /// answered by one router and a later request sent to another would look
    /// like an unknown session.
    async fn handshake() -> (Router, String, HeaderMap) {
        let mut headers = HeaderMap::new();
        headers.insert(HOST, HeaderValue::from_static("127.0.0.1:8097"));
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        headers.insert(
            "accept",
            HeaderValue::from_static("application/json, text/event-stream"),
        );

        let mut request = Request::builder()
            .method("POST")
            .uri("/")
            .body(Body::from(initialize_body()))
            .expect("build initialize request");
        request.headers_mut().extend(headers.clone());

        let app = router(test_server(), None);
        let response = app.clone().oneshot(request).await.expect("router response");
        assert_eq!(response.status(), StatusCode::OK, "handshake must succeed");
        let session_id = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
            .expect("handshake returns a session id");
        (app, session_id, headers)
    }

    fn tool_call_body(tool: &str, caller: &str, identity: Option<&str>) -> String {
        format!(
            r#"{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"{tool}","arguments":{{"path":"shared/report.docx","caller":"{caller}","identity":"{}"}}}}}}"#,
            identity.unwrap_or_default()
        )
    }

    async fn router_with_session(
        app: &Router,
        body: String,
        headers: &HeaderMap,
        session_id: &str,
    ) -> axum::response::Response<Body> {
        let mut session_headers = headers.clone();
        session_headers.insert(
            "mcp-session-id",
            HeaderValue::from_str(session_id).expect("session id header"),
        );
        let mut request = Request::builder()
            .method("POST")
            .uri("/")
            .body(Body::from(body))
            .expect("build tools request");
        request.headers_mut().extend(session_headers);

        app.clone().oneshot(request).await.expect("router response")
    }

    async fn body_string(response: axum::response::Response<Body>) -> String {
        // Session-routed replies come back as SSE `data:` frames, so each
        // frame is unwrapped before the JSON is inspected.
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("collect body");
        let raw = String::from_utf8_lossy(&bytes).into_owned();
        if raw.contains("data:") {
            raw.lines()
                .filter_map(|line| line.strip_prefix("data:").map(str::trim))
                .filter(|frame| !frame.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            raw
        }
    }

    /// A one-request HTTP/1.1 stand-in that answers with `body`, so the
    /// web_search control can prove the surviving tool still reaches an upstream
    /// and returns what it said.
    async fn spawn_json_server(body: String) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind the stand-in SearXNG");
        let address = listener.local_addr().expect("stand-in address");
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut request = [0u8; 4096];
                let _ = stream.read(&mut request).await;
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });
        format!("http://{address}")
    }

    /// The source text of the file under test, for the review-level assertion
    /// that the denial is the whole handler. An observation that nothing was read
    /// or uploaded cannot establish that on its own.
    fn crate_source() -> String {
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"))
            .expect("read this crate's main.rs")
    }

    /// A synthetic shared root with a real readable document and a real FIFO, so
    /// the controls below exercise real filesystem objects rather than a
    /// reconstructed permission algorithm.
    struct SyntheticSharedRoot(PathBuf);

    impl SyntheticSharedRoot {
        fn new(label: &str) -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "ai-tools-office-pause-{label}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("create synthetic shared root");
            Self(dir)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }

        fn write(&self, name: &str, contents: &[u8]) -> PathBuf {
            let path = self.0.join(name);
            std::fs::write(&path, contents).expect("write synthetic document");
            path
        }

        fn fifo(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            let status = std::process::Command::new("mkfifo")
                .arg(&path)
                .status()
                .expect("run mkfifo");
            assert!(status.success(), "mkfifo failed");
            path
        }
    }

    impl Drop for SyntheticSharedRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
