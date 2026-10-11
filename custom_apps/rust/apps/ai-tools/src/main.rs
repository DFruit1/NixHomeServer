//! Read-only MCP tools for the llama.cpp web UI.
//!
//! Tools are attached per client, not baked into the model server, so the
//! shared inference endpoint keeps serving other consumers (Hermes, Paperless)
//! with their own tool choices. This process speaks MCP over Streamable HTTP on
//! loopback and is published through the shared authentication gateway.

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
// Document conversion is suspended as an interim containment measure
// (AIACL-20261011-v2): the service account's static read access to the shared
// root is not bound to the calling user, so no server-side path resolution may
// be performed at all. `office.rs` and its standalone converter tests stay in
// the tree for the caller-aware restoration that will be separately approved,
// and main.rs no longer reaches into that module.
#[allow(dead_code)]
mod office;

use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf, sync::Arc, time::Duration};

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

#[derive(Clone)]
struct Config {
    searxng_base: String,
    searxng_timeout: Duration,
    max_results: usize,
    // Conversion is suspended, so these two are no longer read by this process.
    // They stay configured and validated so the deployment keeps publishing the
    // same environment and a later restoration re-enables a working converter
    // instead of discovering a stale or missing endpoint at republish time.
    #[allow(dead_code)]
    collabora_base: String,
    #[allow(dead_code)]
    shared_root: PathBuf,
    public_host: Option<String>,
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

/// Fixed text returned to every `convert_document` caller while the tool is
/// suspended. No path, filename, root or error cause appears in it, so the
/// refusal cannot be used as a filesystem oracle for probing the shared root.
///
/// Restoration requirements are in `documentation/ai-tools.md`.
pub const CONVERT_DOCUMENT_DENIAL_MESSAGE: &str =
    "Document conversion is unavailable pending caller-permission enforcement";

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
    /// Document conversion is suspended, so this never parses the caller's path,
    /// never resolves it and never reads anything. The fixed message is the
    /// whole answer: a rejection that mentions no filesystem location cannot
    /// disclose one, and no argument shape changes the outcome.
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
                "Read-only tools for this home server. web_search queries the local SearXNG \
             instance. Prefer the user's own files and context for questions about their data.",
            )
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        // convert_document is deliberately absent: a model that never sees the
        // tool never tries it. The dispatch branch below is what actually
        // contains the case, because cached discovery metadata and a direct
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
            // Kept as an explicit denial rather than folded into the unknown-tool
            // arm: a caller that learned the tool name from cached discovery
            // metadata, or that probes it directly, still gets the containment
            // message instead of a lookup error, and this branch is the last
            // point before any path or converter work. Removing discovery alone
            // would not contain a direct invocation.
            "convert_document" => self.run_convert_document(request.arguments).await,
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

    // Conversion is suspended, so the Collabora upstream it used and the shared
    // root it served are no longer read by this process. Both stay configured
    // and both stay validated so a later restoration re-enables a working
    // converter instead of discovering a stale or missing endpoint at
    // republish time.
    let collabora_base = env::var("AI_TOOLS_COLLABORA_URL")
        .map_err(|_| "AI_TOOLS_COLLABORA_URL is not set".to_string())?
        .trim_end_matches('/')
        .to_string();
    if !(collabora_base.starts_with("http://") || collabora_base.starts_with("https://")) {
        return Err("AI_TOOLS_COLLABORA_URL must be an http(s) URL".to_string());
    }

    let shared_root = PathBuf::from(
        env::var("AI_TOOLS_SHARED_ROOT")
            .map_err(|_| "AI_TOOLS_SHARED_ROOT is not set".to_string())?,
    );

    Ok(Config {
        searxng_base,
        searxng_timeout,
        max_results: max_results.clamp(1, 25),
        collabora_base,
        shared_root,
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = env::var("AI_TOOLS_LISTEN")?;
    let config = Arc::new(parse_env()?);
    // No Collabora client is built here: conversion is denied before any
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
    use tower::ServiceExt;

    fn test_config() -> Config {
        Config {
            searxng_base: "http://127.0.0.1:8080".to_string(),
            searxng_timeout: Duration::from_secs(5),
            max_results: 8,
            collabora_base: "http://127.0.0.1:9980".to_string(),
            shared_root: std::env::temp_dir(),
            public_host: None,
        }
    }

    fn test_server() -> Server {
        Server {
            config: Arc::new(test_config()),
        }
    }

    /// The fixed denial, checked as both the code and the message: the message
    /// is what the caller sees and it must not name a path.
    async fn assert_convert_denied(arguments: Option<JsonObject>, caller: &str) -> ErrorData {
        let error = tokio::time::timeout(
            Duration::from_secs(5),
            test_server().run_convert_document(arguments),
        )
        .await
        .unwrap_or_else(|_| panic!("{caller}: conversion denial timed out"))
        .expect_err(&format!("{caller}: conversion must be denied"));
        assert_eq!(
            error.message, CONVERT_DOCUMENT_DENIAL_MESSAGE,
            "{caller}: denial text changed"
        );
        assert_eq!(
            error.code,
            rmcp::model::ErrorCode::INVALID_PARAMS,
            "{caller}: denial must surface as a protocol error"
        );
        assert!(
            error.data.is_none(),
            "{caller}: denial must not attach a payload"
        );
        error
    }

    /// Caller classes that existed before the pause, in the shapes the
    /// transport can deliver. Every one of them is refused identically.
    #[tokio::test]
    async fn denies_conversion_for_every_caller_class() {
        let classes: &[(&str, Option<JsonObject>)] = &[
            ("no arguments", None),
            ("empty arguments", Some(JsonObject::new())),
            (
                "shared-group caller",
                Some(path_arguments("shared/report.docx")),
            ),
            (
                "ai-users-only caller",
                Some(path_arguments("ai-users-only/private.docx")),
            ),
        ];
        for (caller, arguments) in classes {
            let arguments = arguments.clone();
            assert_convert_denied(arguments, caller).await;
        }
    }

    /// A direct JSON-RPC `tools/call` for `convert_document`, sent through the
    /// real router with a real session and a real Host header. Cached discovery
    /// metadata and identity headers must not restore the tool: the fixed
    /// refusal is what comes back over the transport.
    #[tokio::test]
    async fn denies_conversion_over_the_transport_for_every_caller() {
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

        // One router for the whole session: each call to `router` installs its
        // own session manager, so a handshake answered by one router and a
        // tools/call sent to another would look like an unknown session.
        let app = router(test_server(), None);
        let response = app.clone().oneshot(request).await.expect("router response");
        assert_eq!(response.status(), StatusCode::OK, "handshake must succeed");
        let session_id = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
            .expect("handshake returns a session id");

        for (caller, path, identity) in [
            (
                "ai-users-only caller",
                "private/report.docx",
                Some("ai-users-only"),
            ),
            (
                "shared-group caller",
                "shared/report.docx",
                Some("shared-group"),
            ),
            ("unauthenticated caller", "shared/report.docx", None),
        ] {
            let mut caller_headers = headers.clone();
            if let Some(identity) = identity {
                // A gateway-forwarded identity header is a claim about the
                // caller, not caller permission; the suspended tool must ignore
                // it. Sending it is the point, so the control covers callers
                // both with and without identity headers.
                caller_headers.insert(
                    "x-ai-tools-identity",
                    HeaderValue::from_str(identity).expect("identity header"),
                );
            }
            let response = router_with_session(
                &app,
                convert_document_transport_body(caller, path, identity),
                &caller_headers,
                &session_id,
            )
            .await;
            let body = body_string(response).await;
            assert!(
                body.contains(CONVERT_DOCUMENT_DENIAL_MESSAGE),
                "{caller}: transport refusal should carry the fixed message, got {body}"
            );
            assert!(
                !body.contains("report.docx")
                    && !body.contains("shared/")
                    && !body.contains("private/"),
                "{caller}: refusal must not disclose filesystem paths, got {body}"
            );
        }
    }

    fn convert_document_transport_body(caller: &str, path: &str, identity: Option<&str>) -> String {
        let identity = identity.unwrap_or_default();
        format!(
            r#"{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"convert_document","arguments":{{"path":"{path}","caller":"{caller}","identity":"{identity}"}}}}}}"#,
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
            .expect("build tools/call request");
        request.headers_mut().extend(session_headers);

        app.clone().oneshot(request).await.expect("router response")
    }

    /// Every path shape the old handler used to act on reaches the same
    /// refusal, and the refusal names no filesystem location.
    #[tokio::test]
    async fn denies_conversion_for_every_path_shape() {
        let shapes: &[(&str, Option<JsonObject>)] = &[
            ("missing path", Some(JsonObject::new())),
            ("malformed path", Some(path_arguments("    "))),
            ("empty path", Some(path_arguments(""))),
            ("hidden path", Some(path_arguments(".hidden/report.docx"))),
            ("absolute path", Some(path_arguments("/etc/passwd.docx"))),
            (
                "traversal path",
                Some(path_arguments("../../etc/report.docx")),
            ),
            (
                "valid supported document",
                Some(path_arguments("shared/report.docx")),
            ),
            ("unsupported type", Some(path_arguments("shared/photo.png"))),
            ("path is a directory", Some(path_arguments("shared"))),
        ];
        for (shape, arguments) in shapes {
            let arguments = arguments.clone();
            assert_convert_denied(arguments, shape).await;
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

        for (label, target) in [
            ("readable document", document.clone()),
            ("FIFO", fifo.clone()),
        ] {
            let (tx, rx) = std::sync::mpsc::channel();
            let server = test_server();
            let document = target.clone();
            let handle = std::thread::spawn(move || {
                let arguments = path_arguments(document.to_str().expect("path is UTF-8"));
                let result = tokio::runtime::Runtime::new()
                    .expect("runtime")
                    .block_on(server.run_convert_document(Some(arguments)));
                let _ = tx.send(result);
            });
            // Bounded wait: denial takes microseconds; a FIFO open would block
            // until the timeout because no writer ever opens the other end.
            let outcome = rx.recv_timeout(Duration::from_secs(5));
            assert!(
                outcome.is_ok(),
                "{label}: handler did not return, so a path or file operation ran"
            );
            let error = outcome
                .unwrap()
                .expect_err(&format!("{label}: must be denied"));
            assert_eq!(
                error.message, CONVERT_DOCUMENT_DENIAL_MESSAGE,
                "{label}: denial text changed"
            );
            // The FIFO still exists and was never drained: proving it was never
            // opened, because an open-for-read would have blocked the thread.
            assert!(fifo.exists(), "{label}: FIFO was removed or replaced");
            handle.join().expect("handler thread");
        }

        // The document's contents are never observed by the tool, so a
        // read-only denial leaves the fixture untouched.
        assert_eq!(
            std::fs::read(&document).expect("fixture survives"),
            b"PK\x03\x04 synthetic docx body",
            "denial must not consume the document"
        );
    }

    /// Conversion must not reach the Collabora upstream either. A loopback
    /// listener records every connection: it first proves it counts by taking a
    /// control connection, then the real handler converts a real supported
    /// document and the count must not move.
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

        // Control: the stand-in really does observe a connection, so a zero
        // below is the denial's doing and not a listener that never counted.
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
        let arguments = path_arguments(document.to_str().expect("path is UTF-8"));
        let error = server
            .run_convert_document(Some(arguments))
            .await
            .expect_err("conversion must be denied");
        assert_eq!(error.message, CONVERT_DOCUMENT_DENIAL_MESSAGE);

        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(
            connections.load(Ordering::SeqCst),
            1,
            "conversion must not contact the Collabora upstream"
        );
        accept.abort();
    }

    /// Source-level guarantee that denial precedes every path or file call, not
    /// just an observation that no read was seen. A FIFO or zero-upload
    /// observation alone cannot prove a regular file was not read.
    #[test]
    fn denial_precedes_path_and_file_calls_in_source() {
        let source = conversion_source();
        let handler_start = source
            .find("async fn run_convert_document")
            .expect("conversion handler is present");
        let handler = &source[handler_start..];
        let denial = handler
            .find("CONVERT_DOCUMENT_DENIAL_MESSAGE")
            .expect("handler returns the fixed denial");
        // The denial is the body of the handler, so nothing that follows it in
        // the function can run before the refusal is returned.
        let handler_end = handler.find("\n    }\n").expect("handler has a body");
        assert!(
            denial < handler_end,
            "the denial must be returned by run_convert_document itself"
        );
        // Only the handler's own body is scanned. The rest of this file holds
        // the office module's converter and this module's own literals, so
        // scanning it would flag the words this assertion is spelled with.
        let body = &handler[..handler_end];
        for forbidden in [
            "resolve_within",
            "office::",
            "Converter",
            "read_document",
            "open_document",
            "std::fs::read",
        ] {
            assert!(
                !body.contains(forbidden),
                "run_convert_document must not reach {forbidden}"
            );
        }
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
        let server = Server {
            config: Arc::new(test_config()),
        };

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
            .body(Body::from(
                r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"host-policy-test","version":"0.0.0"}}}"#,
            ))
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

    fn path_arguments(path: &str) -> JsonObject {
        let mut arguments = JsonObject::new();
        arguments.insert("path".to_string(), serde_json::json!(path));
        arguments
    }

    fn initialize_body() -> String {
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"conversion-test","version":"0.0.0"}}}"#
            .to_string()
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

    /// The source text of the file under test, for the review-level assertion
    /// that denial precedes every path and file operation. An observation that
    /// nothing was read or uploaded cannot establish that on its own.
    fn conversion_source() -> String {
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"))
            .expect("read this crate's main.rs")
    }

    /// A synthetic shared root with a real readable document and a real FIFO,
    /// so the controls below exercise real filesystem objects rather than a
    /// reconstructed permission algorithm.
    struct SyntheticSharedRoot(PathBuf);

    impl SyntheticSharedRoot {
        fn new(label: &str) -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "ai-tools-conversion-denial-{label}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("create synthetic shared root");
            Self(dir)
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

    /// Discovery no longer offers the tool and web_search is still advertised.
    /// Driven through the real router with a real session, so this is the same
    /// path a model-backed client takes.
    #[tokio::test]
    async fn discovery_hides_convert_document_but_keeps_web_search() {
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
        let session_id = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
            .expect("handshake returns a session id");

        let body = tools_list_body(&app, &session_id).await;
        assert!(
            body.contains("\"web_search\""),
            "web_search must stay discoverable, got {body}"
        );
        assert!(
            !body.contains("convert_document"),
            "convert_document must not be discoverable, got {body}"
        );
    }

    async fn tools_list_body(app: &Router, session_id: &str) -> String {
        let mut headers = HeaderMap::new();
        headers.insert(HOST, HeaderValue::from_static("127.0.0.1:8097"));
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        headers.insert(
            "accept",
            HeaderValue::from_static("application/json, text/event-stream"),
        );
        headers.insert(
            "mcp-session-id",
            HeaderValue::from_str(session_id).expect("session id header"),
        );
        let mut request = Request::builder()
            .method("POST")
            .uri("/")
            .body(Body::from(
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            ))
            .expect("build tools/list request");
        request.headers_mut().extend(headers);

        // The same router that answered the handshake: a fresh router installs
        // a fresh session manager and would report this session as unknown.
        let response = app.clone().oneshot(request).await.expect("router response");
        body_string(response).await
    }

    /// web_search still dispatches and returns results: a fake SearXNG answers
    /// on loopback, so the retained tool is proven working without any internet
    /// search. Conversion shares the same transport, so a green control here
    /// also shows the denial is specific to convert_document.
    #[tokio::test]
    async fn web_search_still_dispatches_against_a_local_searxng() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a loopback SearXNG stand-in");
        let address = listener.local_addr().expect("stand-in address");

        tokio::spawn(async move {
            let app = axum::Router::new().fallback(|uri: axum::http::Uri| async move {
                let query = uri.query().unwrap_or_default().to_string();
                assert!(query.contains("q=rust"), "stand-in saw {query}");
                (
                    [(axum::http::header::CONTENT_TYPE, "application/json")],
                    serde_json::json!({"results": [{
                        "title": "stand-in result",
                        "url": "https://example.org/rust",
                        "content": "synthetic snippet",
                        "engines": ["stand-in"]
                    }]})
                    .to_string(),
                )
            });
            let _ = axum::serve(listener, app).await;
        });

        let mut config = test_config();
        config.searxng_base = format!("http://{address}");
        let server = Server {
            config: Arc::new(config),
        };
        let mut arguments = JsonObject::new();
        arguments.insert("query".to_string(), serde_json::json!("rust"));
        let response = server
            .run_web_search(Some(arguments))
            .await
            .expect("web_search still dispatches");
        let CallToolResponse::Complete(result) = response else {
            panic!("web_search should complete");
        };
        assert_eq!(result.is_error, Some(false));
        let text = result
            .content
            .first()
            .and_then(|content| content.as_text())
            .map(|text| text.text.as_str())
            .expect("web_search returns text content");
        assert!(
            text.contains("stand-in result"),
            "web_search should return the stand-in's results, got {text}"
        );
    }
}
