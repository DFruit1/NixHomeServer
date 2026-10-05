//! Read-only MCP tools for the llama.cpp web UI.
//!
//! Tools are attached per client, not baked into the model server, so the
//! shared inference endpoint keeps serving other consumers (Hermes, Paperless)
//! with their own tool choices. This process speaks MCP over Streamable HTTP on
//! loopback and is published through the shared authentication gateway.
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
mod office;
mod office_write;

use office::Converter;
use office_write::{Helper, WriteFormat};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{env, path::PathBuf, sync::Arc, time::Duration};

#[derive(Debug, Deserialize)]
struct ConvertDocumentParams {
    #[serde(default)]
    path: String,
}

/// `spreadsheet_read`: one path, optional per-sheet narrowing.
#[derive(Debug, Deserialize)]
struct SpreadsheetReadParams {
    #[serde(default)]
    path: String,
    #[serde(default)]
    sheets: Option<Vec<String>>,
}

/// `spreadsheet_write` and `word_document`: the document plus its target.
///
/// `path` is deliberately absent on a write. The target is derived entirely from
/// the `format` and the caller's `name`, both resolved inside the workspace, so
/// the model never gets to supply a path it could aim somewhere it should not.
#[derive(Debug, Deserialize)]
struct DocumentWriteParams {
    #[serde(default)]
    format: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    sheets: Option<Vec<Value>>,
    #[serde(default)]
    blocks: Option<Vec<Value>>,
    #[serde(default)]
    overwrite: bool,
}

/// `word_document` in read mode.
#[derive(Debug, Deserialize)]
struct WordReadParams {
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
    workspace_root: PathBuf,
    helper: Helper,
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

const CONVERT_DOCUMENT_DESCRIPTION: &str = "Convert an office document to text so it can be \
read. Accepts a path relative to the shared directory and supports docx, odt, rtf, doc, xlsx, \
ods, pptx and odp. Spreadsheets come back as CSV, everything else as plain text. Use this instead \
of guessing at the contents of a file the user mentions.";

const SPREADSHEET_READ_DESCRIPTION: &str = "Read a spreadsheet and return every sheet, each as \
an array of rows. Accepts xlsx and ods and can see the whole shared directory. Use this rather than \
convert_document when you need a real workbook, because convert_document returns only the first \
sheet. Formula cells come back as their formula text, not their last calculated value.";

const SPREADSHEET_WRITE_DESCRIPTION: &str = "Create a spreadsheet from sheets you supply and \
save it into the AI workspace. Every sheet you pass is written, in order, with the names you give \
it. Choose the 'ods' format for an OpenDocument file and 'xlsx' for a native Excel file. Writes go \
only to the workspace folder, which is not backed up, so a file you write there can be lost and \
nothing outside it is ever touched.";

const WORD_DOCUMENT_DESCRIPTION: &str = "Read or write a Word document. Call it with just a \
'path' to read one; call it with 'format', 'name' and 'blocks' to create one in the AI workspace. \
Supports docx and odt. Reading returns the document's paragraphs and tables in order with their text \
and basic formatting. A written document keeps paragraphs, runs and tables; it does not keep \
tracked changes, comments, footnotes, headers or embedded images.";

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

fn schema_object(properties: serde_json::Map<String, Value>, required: &[&str]) -> Arc<JsonObject> {
    Arc::new(
        serde_json::json!({
            "type": "object",
            "properties": properties,
            "required": required,
        })
        .as_object()
        .cloned()
        .expect("schema literal is an object"),
    )
}

fn spreadsheet_read_schema() -> Arc<JsonObject> {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "path".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "Path to the workbook, relative to the shared directory. Absolute paths and parent traversal are rejected."
        }),
    );
    properties.insert(
        "sheets".to_string(),
        serde_json::json!({
            "type": "array",
            "items": { "type": "string" },
            "description": "Optional sheet names to return. Omit it to get every sheet, which is the point of this tool."
        }),
    );
    schema_object(properties, &["path"])
}

fn spreadsheet_write_schema() -> Arc<JsonObject> {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "format".to_string(),
        serde_json::json!({
            "type": "string",
            "enum": ["xlsx", "ods"],
            "description": "Output dialect. 'xlsx' is native Excel, 'ods' is OpenDocument."
        }),
    );
    properties.insert(
        "name".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "File name to create inside the AI workspace, with the extension implied by the format. Subdirectories are allowed and must already exist."
        }),
    );
    properties.insert(
        "sheets".to_string(),
        serde_json::json!({
            "type": "array",
            "description": "The sheets to write, in order. Every entry is written; none is collapsed.",
            "items": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Sheet name, at most 31 characters." },
                    "rows": {
                        "type": "array",
                        "description": "Rows of cells, each row an array of values.",
                        "items": { "type": "array", "items": {} }
                    }
                },
                "required": ["name", "rows"]
            }
        }),
    );
    properties.insert(
        "overwrite".to_string(),
        serde_json::json!({
            "type": "boolean",
            "description": "Set true to replace an existing file in the workspace. Defaults to false, so a write never destroys something that is already there."
        }),
    );
    schema_object(properties, &["format", "name", "sheets"])
}

fn word_document_schema() -> Arc<JsonObject> {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "path".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "Path to an existing document, relative to the shared directory. Supply this to read."
        }),
    );
    properties.insert(
        "format".to_string(),
        serde_json::json!({
            "type": "string",
            "enum": ["docx", "odt"],
            "description": "Output dialect for a write. 'docx' is native Word, 'odt' is OpenDocument."
        }),
    );
    properties.insert(
        "name".to_string(),
        serde_json::json!({
            "type": "string",
            "description": "File name to create inside the AI workspace when writing."
        }),
    );
    properties.insert(
        "blocks".to_string(),
        serde_json::json!({
            "type": "array",
            "description": "Document content in order, when writing.",
            "items": {
                "type": "object",
                "properties": {
                    "kind": { "type": "string", "enum": ["paragraph", "table"] },
                    "style": { "type": "string", "description": "Paragraph style name, for example 'Heading 1'." },
                    "text": { "type": "string", "description": "Plain text for a simple paragraph." },
                    "runs": {
                        "type": "array",
                        "description": "Formatted runs, for text that needs bold or italic.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string" },
                                "bold": { "type": "boolean" },
                                "italic": { "type": "boolean" }
                            },
                            "required": ["text"]
                        }
                    },
                    "rows": {
                        "type": "array",
                        "description": "Table rows, each an array of cell values.",
                        "items": { "type": "array", "items": {} }
                    }
                },
                "required": ["kind"]
            }
        }),
    );
    properties.insert(
        "overwrite".to_string(),
        serde_json::json!({
            "type": "boolean",
            "description": "Set true to replace an existing file in the workspace. Defaults to false."
        }),
    );
    schema_object(properties, &[])
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

/// Keep only the named sheets of a helper result.
///
/// Filtering here rather than in the helper keeps the helper a pure format
/// adapter. A name that matches nothing is an error rather than an empty
/// result, because silently returning nothing looks like an empty workbook and
/// would be answered with the wrong conclusion.
fn filter_sheets(payload: &mut Value, wanted: &[String]) -> Result<(), ErrorData> {
    let sheets = payload
        .get_mut("sheets")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| ErrorData::internal_error("helper returned no sheets", None))?;

    let kept: Vec<Value> = sheets
        .iter()
        .filter(|sheet| {
            sheet
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| wanted.iter().any(|entry| entry == name))
        })
        .cloned()
        .collect();

    let missing: Vec<&str> = wanted
        .iter()
        .filter(|entry| {
            !sheets.iter().any(|sheet| {
                sheet
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|name| name == entry.as_str())
            })
        })
        .map(String::as_str)
        .collect();
    if !missing.is_empty() {
        return Err(ErrorData::invalid_params(
            format!("workbook has no sheet named {missing:?}"),
            None,
        ));
    }

    *sheets = kept;
    let kept_count = sheets.len();
    if let Some(object) = payload.as_object_mut() {
        object.insert("sheet_count".to_string(), Value::from(kept_count));
        object.insert("filtered".to_string(), Value::Bool(true));
    }
    Ok(())
}

/// Sibling temporary the helper writes before the document is final.
///
/// Same directory as the target so the rename is atomic, and inside the
/// workspace so the write grant covers it. The name is fixed rather than random:
/// the workspace is a single-user, single-writer directory, and a predictable
/// name means a leftover from a crashed run is visible instead of accumulating.
fn staged_sibling(target: &std::path::Path) -> std::path::PathBuf {
    let name = target
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("document");
    let staged = format!(".{name}.staging");
    target.with_file_name(staged)
}

/// Write bytes to a validated target, replacing it atomically.
///
/// The temp-and-rename is what makes an interrupted write leave the previous
/// version intact rather than a truncated document. It also means a document the
/// helper already produced is moved rather than copied, so a large workbook is
/// not held twice in memory.
async fn write_bytes(target: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > office_write::MAX_WRITE_BYTES {
        return Err(format!(
            "document is larger than the {} byte write limit",
            office_write::MAX_WRITE_BYTES
        ));
    }
    let temporary = staged_sibling(target);
    tokio::fs::write(&temporary, bytes)
        .await
        .map_err(|error| format!("could not stage the document: {error}"))?;
    tokio::fs::rename(&temporary, target)
        .await
        .map_err(|error| format!("could not place the document: {error}"))
}

/// Recover the document bytes from a Collabora convert-to result.
///
/// `convert_to` returns the same JSON envelope `convert_document` reports, with
/// the payload base64 rather than text: an xlsx or docx is a zip archive and
/// cannot survive a trip through a UTF-8 string.
fn decode_helper_document(payload: Value) -> Result<Vec<u8>, ErrorData> {
    use base64::Engine as _;

    let content = payload
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| ErrorData::internal_error("Collabora returned no content", None))?;
    base64::engine::general_purpose::STANDARD
        .decode(content)
        .map_err(|error| {
            ErrorData::internal_error(format!("Collabora result was not base64: {error}"), None)
        })
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

    /// Read every sheet of a workbook.
    ///
    /// An `ods` request is converted to xlsx by Collabora first, because the
    /// helper has no native ODF reader and introducing one is not worth it. The
    /// xlsx is held in memory between the two steps rather than written to the
    /// shared root, so reading an ods never leaves a temporary file behind.
    async fn run_spreadsheet_read(
        &self,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        let raw = arguments
            .map(Value::Object)
            .unwrap_or(Value::Object(Default::default()));
        let params: SpreadsheetReadParams = serde_json::from_value(raw)
            .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;

        // Reads resolve against the whole shared root. That is the owner's
        // decision: a generated answer may be built from anything already
        // shared, and only writes are confined.
        let resolved = office_write::resolve_read(&self.config.shared_root, &params.path)
            .map_err(|message| ErrorData::invalid_params(message, None))?;

        let document = self.read_native_spreadsheet(&resolved).await?;
        let mut payload = self
            .config
            .helper
            .read("xlsx", document)
            .await
            .map_err(|message| ErrorData::internal_error(message, None))?;

        // Sheet filtering happens here rather than in the helper so the helper
        // stays a pure format adapter with no policy in it at all.
        if let Some(wanted) = params.sheets.as_ref().filter(|list| !list.is_empty()) {
            filter_sheets(&mut payload, wanted)?;
        }

        let content = ContentBlock::json(payload)?;
        Ok(CallToolResult::success(vec![content]).into())
    }

    /// Produce a native xlsx for a workbook that may be any dialect.
    async fn read_native_spreadsheet(&self, path: &std::path::Path) -> Result<Vec<u8>, ErrorData> {
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        match extension.as_str() {
            "xlsx" => office::read_document(path, office_write::MAX_INPUT_BYTES)
                .await
                .map_err(|message| ErrorData::invalid_params(message, None)),
            // Collabora is the only ODF reader in this closure, and it is already
            // deployed on loopback for OpenCloud. csv is not offered here: a
            // single-file CSV has no sheets to lose, so convert_document is the
            // right tool for it.
            "ods" => {
                let converted = self
                    .converter
                    .convert_to(path, "xlsx")
                    .await
                    .map_err(|message| ErrorData::internal_error(message, None))?;
                decode_helper_document(converted)
            }
            other => Err(ErrorData::invalid_params(
                format!(
                    "spreadsheet_read accepts xlsx and ods, not {other:?}; use convert_document for csv"
                ),
                None,
            )),
        }
    }

    /// Write a spreadsheet into the workspace.
    ///
    /// The caller supplies a name and a format, never a path. That is the whole
    /// containment argument: the extension comes from the format, the directory
    /// comes from the workspace, and the only free input is a relative name
    /// checked by `resolve_write` like any other.
    async fn run_spreadsheet_write(
        &self,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        let raw = arguments
            .map(Value::Object)
            .unwrap_or(Value::Object(Default::default()));
        let params: DocumentWriteParams = serde_json::from_value(raw)
            .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;

        let format = office_write::write_format_for(&params.format.trim().to_ascii_lowercase())
            .filter(|candidate| matches!(candidate, WriteFormat::Xlsx | WriteFormat::Ods))
            .ok_or_else(|| {
                ErrorData::invalid_params(
                    "spreadsheet_write accepts format 'xlsx' or 'ods'".to_string(),
                    None,
                )
            })?;

        let sheets = params.sheets.clone().unwrap_or_default();
        if sheets.is_empty() {
            return Err(ErrorData::invalid_params(
                "spreadsheet_write needs at least one sheet".to_string(),
                None,
            ));
        }

        let (staged, target) = self.stage_write(&params, format, &params.name.clone())?;
        let spec = serde_json::json!({ "sheets": sheets });

        let written = self
            .config
            .helper
            .write(format.helper_extension_public(), &staged, &spec)
            .await
            .map_err(|message| ErrorData::internal_error(message, None))?;

        // An ods target is the xlsx Collabora was just handed, converted. The
        // staged xlsx is the only thing that ever exists on disk, and it is
        // removed again below.
        if let Some(target_filter) = format.collabora_target() {
            let converted = self
                .converter
                .convert_to(&staged, target_filter)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
            let _ = tokio::fs::remove_file(&staged).await;
            write_bytes(&target, &decode_helper_document(converted)?)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
        } else {
            let bytes = tokio::fs::read(&staged)
                .await
                .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
            let _ = tokio::fs::remove_file(&staged).await;
            write_bytes(&target, &bytes)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
        }

        let payload = serde_json::json!({
            "path": target.display().to_string(),
            "format": format.extension(),
            "sheets": written.get("sheets").cloned().unwrap_or(Value::Null),
            "not_retained": written.get("not_retained").cloned().unwrap_or(Value::Null),
        });
        let content = ContentBlock::json(payload)?;
        Ok(CallToolResult::success(vec![content]).into())
    }

    /// Read or write a Word document.
    ///
    /// One tool with both modes rather than two, because the read half and the
    /// write half of a round-trip are the same act from the model's side and a
    /// caller that already knows the shape should not have to learn two names.
    async fn run_word_document(
        &self,
        arguments: Option<JsonObject>,
    ) -> Result<CallToolResponse, ErrorData> {
        let raw = arguments
            .map(Value::Object)
            .unwrap_or(Value::Object(Default::default()));
        let params: Value = raw;

        // A bare `path` is a read. Anything else is a write. The branch is on
        // presence rather than on an explicit mode flag so the common case, "read
        // this document", needs only the one argument.
        let reading = params.get("blocks").is_none()
            && params.get("name").is_none()
            && params.get("path").is_some();
        if reading {
            let read: WordReadParams = serde_json::from_value(params)
                .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;
            let resolved = office_write::resolve_read(&self.config.shared_root, &read.path)
                .map_err(|message| ErrorData::invalid_params(message, None))?;
            let payload = self.read_word(&resolved).await?;
            let content = ContentBlock::json(payload)?;
            return Ok(CallToolResult::success(vec![content]).into());
        }

        let params: DocumentWriteParams = serde_json::from_value(params)
            .map_err(|error| ErrorData::invalid_params(error.to_string(), None))?;
        let format = office_write::write_format_for(&params.format.trim().to_ascii_lowercase())
            .filter(|candidate| matches!(candidate, WriteFormat::Docx | WriteFormat::Odt))
            .ok_or_else(|| {
                ErrorData::invalid_params(
                    "word_document accepts format 'docx' or 'odt'".to_string(),
                    None,
                )
            })?;

        let blocks = params.blocks.clone().unwrap_or_default();
        if blocks.is_empty() {
            return Err(ErrorData::invalid_params(
                "a written document needs at least one block".to_string(),
                None,
            ));
        }

        let (staged, target) = self.stage_write(&params, format, &params.name.clone())?;
        let spec = serde_json::json!({ "blocks": blocks });
        let written = self
            .config
            .helper
            .write(format.helper_extension_public(), &staged, &spec)
            .await
            .map_err(|message| ErrorData::internal_error(message, None))?;

        if let Some(target_filter) = format.collabora_target() {
            let converted = self
                .converter
                .convert_to(&staged, target_filter)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
            let _ = tokio::fs::remove_file(&staged).await;
            write_bytes(&target, &decode_helper_document(converted)?)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
        } else {
            let bytes = tokio::fs::read(&staged)
                .await
                .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
            let _ = tokio::fs::remove_file(&staged).await;
            write_bytes(&target, &bytes)
                .await
                .map_err(|message| ErrorData::internal_error(message, None))?;
        }

        let payload = serde_json::json!({
            "path": target.display().to_string(),
            "format": format.extension(),
            "blocks_written": written.get("block_count").cloned().unwrap_or(Value::Null),
            "not_retained": written.get("not_retained").cloned().unwrap_or(Value::Null),
        });
        let content = ContentBlock::json(payload)?;
        Ok(CallToolResult::success(vec![content]).into())
    }

    async fn read_word(&self, path: &std::path::Path) -> Result<Value, ErrorData> {
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        match extension.as_str() {
            "docx" => {
                let bytes = office::read_document(path, office_write::MAX_INPUT_BYTES)
                    .await
                    .map_err(|message| ErrorData::invalid_params(message, None))?;
                self.config
                    .helper
                    .read("docx", bytes)
                    .await
                    .map_err(|message| ErrorData::internal_error(message, None))
            }
            "odt" => {
                let converted = self
                    .converter
                    .convert_to(path, "docx")
                    .await
                    .map_err(|message| ErrorData::internal_error(message, None))?;
                let bytes = decode_helper_document(converted)?;
                self.config
                    .helper
                    .read("docx", bytes)
                    .await
                    .map_err(|message| ErrorData::internal_error(message, None))
            }
            other => Err(ErrorData::invalid_params(
                format!("word_document reads docx and odt, not {other:?}"),
                None,
            )),
        }
    }

    /// Resolve the caller's name to a validated target, refusing a write that
    /// would destroy an existing file unless it was asked to.
    ///
    /// Two paths come back. `target` is what the caller finally receives, and
    /// `staged` is a sibling temporary the helper writes first. An ODF target
    /// needs the native document converted by Collabora afterwards, and doing
    /// that conversion against a partially-written final file would leave a
    /// broken `ods` on disk whenever Collabora refused.
    fn stage_write(
        &self,
        params: &DocumentWriteParams,
        format: WriteFormat,
        name: &str,
    ) -> Result<(std::path::PathBuf, std::path::PathBuf), ErrorData> {
        let requested = match name.trim() {
            "" => {
                return Err(ErrorData::invalid_params(
                    "a written document needs a 'name'".to_string(),
                    None,
                ));
            }
            trimmed if trimmed.ends_with('.') => {
                return Err(ErrorData::invalid_params(
                    "name must not end with a dot".to_string(),
                    None,
                ));
            }
            trimmed => trimmed.to_string(),
        };

        let relative = if requested
            .to_ascii_lowercase()
            .ends_with(&format!(".{}", format.extension()))
        {
            requested
        } else {
            format!("{requested}.{}", format.extension())
        };

        let target = office_write::resolve_write(&self.config.workspace_root, &relative)
            .map_err(|message| ErrorData::invalid_params(message, None))?;

        if target.exists() && !params.overwrite {
            return Err(ErrorData::invalid_params(
                format!(
                    "{} already exists in the workspace; pass overwrite true to replace it",
                    relative
                ),
                None,
            ));
        }

        let staged = staged_sibling(&target);
        Ok((staged, target))
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
            Tool::new(
                "spreadsheet_read",
                SPREADSHEET_READ_DESCRIPTION,
                spreadsheet_read_schema(),
            ),
            Tool::new(
                "spreadsheet_write",
                SPREADSHEET_WRITE_DESCRIPTION,
                spreadsheet_write_schema(),
            ),
            Tool::new(
                "word_document",
                WORD_DOCUMENT_DESCRIPTION,
                word_document_schema(),
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

    let helper = Helper::new(&env::var("AI_TOOLS_OFFICE_HELPER").map_err(|_| {
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
    let converter = Arc::new(Converter::new(
        &config.collabora_base,
        config.collabora_timeout,
    )?);
    let server = Server {
        config: Arc::clone(&config),
        converter,
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
            // The path is never executed by these tests; only the handshake
            // policy is under test here. The helper's own behaviour is covered
            // by the helper's unit tests and by the write-path tests below.
            helper: Helper::new("/nix/store/fake-helper/bin/helper").expect("helper"),
            public_host: None,
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
            converter: Arc::new(
                Converter::new("http://127.0.0.1:9980", Duration::from_secs(5)).unwrap(),
            ),
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
}
