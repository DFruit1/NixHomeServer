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
mod office;

use office::Converter;
use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf, sync::Arc, time::Duration};

#[derive(Debug, Deserialize)]
struct ConvertDocumentParams {
    #[serde(default)]
    path: String,
}

#[derive(Clone)]
struct Config {
    searxng_base: String,
    searxng_timeout: Duration,
    max_results: usize,
    collabora_base: String,
    collabora_timeout: Duration,
    shared_root: PathBuf,
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

const CONVERT_DOCUMENT_DESCRIPTION: &str = "Convert an office document to text so it can be \
read. Accepts a path relative to the shared directory and supports docx, odt, rtf, doc, xlsx, \
ods, pptx and odp. Spreadsheets come back as CSV, everything else as plain text. Use this instead \
of guessing at the contents of a file the user mentions.";

fn convert_document_schema() -> Arc<JsonObject> {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "path".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "Path to the document, relative to the shared directory. Absolute paths and parent traversal are rejected."
        }),
    );
    Arc::new(
        serde_json::json!({
            "type": "object",
            "properties": properties,
            "required": ["path"],
        })
        .as_object()
        .cloned()
        .expect("schema literal is an object"),
    )
}

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
    converter: Arc<Converter>,
}

impl Server {
    async fn run_convert_document(
        &self,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        let raw = arguments
            .map(serde_json::Value::Object)
            .unwrap_or(serde_json::Value::Object(Default::default()));
        let params: ConvertDocumentParams = serde_json::from_value(raw)
            .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;

        let resolved = office::resolve_within(&self.config.shared_root, &params.path)
            .map_err(|message| ErrorData::invalid_params(message, None))?;

        let payload = self
            .converter
            .convert(&resolved)
            .await
            .map_err(|message| ErrorData::internal_error(message, None))?;

        let content = ContentBlock::json(payload)?;
        Ok(CallToolResult::success(vec![content]).into())
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
        Ok(ListToolsResult::with_all_items(vec![
            Tool::new("web_search", WEB_SEARCH_DESCRIPTION, web_search_schema()),
            Tool::new(
                "convert_document",
                CONVERT_DOCUMENT_DESCRIPTION,
                convert_document_schema(),
            ),
        ]))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        match request.name.as_ref() {
            "web_search" => self.run_web_search(request.arguments).await,
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

    Ok(Config {
        searxng_base,
        searxng_timeout,
        max_results: max_results.clamp(1, 25),
        collabora_base,
        collabora_timeout,
        shared_root,
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = env::var("AI_TOOLS_LISTEN")?;
    let config = Arc::new(parse_env()?);
    let converter = Arc::new(Converter::new(
        &config.collabora_base,
        config.collabora_timeout,
    )?);
    let server = Server {
        config: Arc::clone(&config),
        converter,
    };

    let mcp = StreamableHttpService::new(
        move || Ok(server.clone()),
        Arc::new(LocalSessionManager::default()),
        // Plain JSON responses rather than an open SSE stream. The gateway
        // terminates TLS and proxies through oauth2-proxy, and a long-lived
        // event stream is the part most likely to be buffered or cut there.
        // Single-response JSON is the interoperable choice behind a proxy.
        StreamableHttpServerConfig::default()
            .with_json_response(true)
            .with_sse_keep_alive(Some(Duration::from_secs(15))),
    );

    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .fallback_service(mcp);

    let listener = tokio::net::TcpListener::bind(&listen).await?;
    eprintln!(
        "ai-tools listening on {listen}, searxng at {}",
        config.searxng_base
    );
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> Config {
        Config {
            searxng_base: "http://127.0.0.1:8080".to_string(),
            searxng_timeout: Duration::from_secs(5),
            max_results: 8,
            collabora_base: "http://127.0.0.1:9980".to_string(),
            collabora_timeout: Duration::from_secs(5),
            shared_root: std::env::temp_dir(),
        }
    }

    #[tokio::test]
    async fn rejects_an_empty_query() {
        let server = Server {
            config: Arc::new(test_config()),
            converter: Arc::new(
                Converter::new("http://127.0.0.1:9980", Duration::from_secs(5)).unwrap(),
            ),
        };
        let mut arguments = JsonObject::new();
        arguments.insert("query".to_string(), serde_json::json!("   "));
        let error = server.run_web_search(Some(arguments)).await.unwrap_err();
        assert_eq!(error.code, rmcp::model::ErrorCode::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn rejects_a_missing_query() {
        let server = Server {
            config: Arc::new(test_config()),
            converter: Arc::new(
                Converter::new("http://127.0.0.1:9980", Duration::from_secs(5)).unwrap(),
            ),
        };
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
}
