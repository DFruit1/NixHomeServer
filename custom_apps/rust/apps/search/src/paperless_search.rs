use std::collections::HashMap;

use serde_json::Value;

use crate::federate::FederatedHit;
use crate::text;
use crate::timeutil::parse_date;

/// Default page size requested from the Paperless search endpoint.
pub const DEFAULT_MAX_RESULTS: usize = 20;
/// Page size used when enumerating taxonomy objects.
const TAXONOMY_PAGE_SIZE: usize = 100;
/// Safety bound on taxonomy pagination so an oversized instance cannot make a
/// single search walk an unbounded number of pages.
const TAXONOMY_MAX_PAGES: usize = 50;

/// Everything needed to query one Paperless instance. The HTTP client is shared
/// so connections are pooled across queries.
#[derive(Debug, Clone)]
pub struct PaperlessSearchConfig {
    pub source_id: String,
    pub client: reqwest::Client,
    pub base_url: String,
    pub token: String,
    pub app_base: String,
    pub max_results: usize,
}

/// Names for the document relationships Paperless returns as numeric ids.
#[derive(Debug, Clone, Default)]
pub struct Taxonomy {
    correspondents: HashMap<i64, String>,
    document_types: HashMap<i64, String>,
    tags: HashMap<i64, String>,
}

impl Taxonomy {
    fn name(map: &HashMap<i64, String>, value: Option<&Value>) -> Option<String> {
        let id = value?.as_i64()?;
        map.get(&id).cloned()
    }

    pub fn correspondent(&self, value: Option<&Value>) -> Option<String> {
        Self::name(&self.correspondents, value)
    }

    pub fn document_type(&self, value: Option<&Value>) -> Option<String> {
        Self::name(&self.document_types, value)
    }

    pub fn tag_names(&self, value: Option<&Value>) -> Vec<String> {
        value
            .and_then(Value::as_array)
            .map(|ids| {
                ids.iter()
                    .filter_map(|id| id.as_i64())
                    .filter_map(|id| self.tags.get(&id).cloned())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Loads correspondent, document-type, and tag names so numeric ids from a
/// search hit can be presented as readable metadata.
pub async fn load_taxonomy(client: &reqwest::Client, config: &PaperlessSearchConfig) -> Taxonomy {
    let mut taxonomy = Taxonomy::default();
    let base = config.base_url.as_str();
    load_names(
        client,
        config,
        &format!("{base}/api/correspondents/?page_size={TAXONOMY_PAGE_SIZE}"),
        &mut taxonomy.correspondents,
    )
    .await;
    load_names(
        client,
        config,
        &format!("{base}/api/document_types/?page_size={TAXONOMY_PAGE_SIZE}"),
        &mut taxonomy.document_types,
    )
    .await;
    load_names(
        client,
        config,
        &format!("{base}/api/tags/?page_size={TAXONOMY_PAGE_SIZE}"),
        &mut taxonomy.tags,
    )
    .await;
    taxonomy
}

async fn load_names(
    client: &reqwest::Client,
    config: &PaperlessSearchConfig,
    first_url: &str,
    out: &mut HashMap<i64, String>,
) {
    let mut next = Some(first_url.to_string());
    let mut pages = 0;
    while let Some(url) = next {
        if pages >= TAXONOMY_MAX_PAGES {
            break;
        }
        pages += 1;
        let Ok(value) = fetch_json(client, &config.token, &url).await else {
            break;
        };
        if let Some(results) = value.get("results").and_then(Value::as_array) {
            for item in results {
                if let (Some(id), Some(name)) = (
                    item.get("id").and_then(Value::as_i64),
                    item.get("name").and_then(Value::as_str),
                ) {
                    out.insert(id, name.to_string());
                }
            }
        }
        next = value
            .get("next")
            .and_then(Value::as_str)
            .map(str::to_string);
    }
}

/// Runs a query against Paperless's own full-text index and maps the hits into
/// the unified federated shape. Never copies document content; only the query
/// result page is fetched.
pub async fn search(
    config: &PaperlessSearchConfig,
    taxonomy: &Taxonomy,
    query: &str,
) -> Vec<FederatedHit> {
    let query = query.trim();
    if query.is_empty() {
        return Vec::new();
    }
    let url = format!("{}/api/documents/", config.base_url);
    let page_size = config.max_results.max(1).to_string();
    let advanced = [
        ("query", query),
        ("page_size", page_size.as_str()),
        ("truncate_content", "true"),
    ];
    // Prefer Paperless's advanced query parser (boolean operators, field
    // filters, natural dates). Fall back to the simple text search when
    // Paperless rejects the user's input as an invalid advanced query.
    let mut response = request_json(config, &url, &advanced).await;
    if matches!(response, Err(400)) {
        let simple = [
            ("text", query),
            ("page_size", page_size.as_str()),
            ("truncate_content", "true"),
        ];
        response = request_json(config, &url, &simple).await;
    }
    let Ok(value) = response else {
        return Vec::new();
    };
    value
        .get("results")
        .and_then(Value::as_array)
        .map(|results| {
            results
                .iter()
                .map(|document| map_document(config, taxonomy, document, query))
                .collect()
        })
        .unwrap_or_default()
}

fn map_document(
    config: &PaperlessSearchConfig,
    taxonomy: &Taxonomy,
    document: &Value,
    query: &str,
) -> FederatedHit {
    let remote_id = document
        .get("id")
        .and_then(Value::as_i64)
        .map(|id| id.to_string())
        .unwrap_or_default();
    let title = document
        .get("title")
        .and_then(Value::as_str)
        .filter(|title| !title.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("Document {remote_id}"));
    let content_type = document
        .get("mime_type")
        .and_then(Value::as_str)
        .filter(|mime| !mime.trim().is_empty())
        .unwrap_or("application/pdf")
        .to_string();
    let created = document
        .get("created")
        .and_then(Value::as_str)
        .and_then(parse_date);
    let score = document
        .pointer("/__search_hit__/score")
        .and_then(Value::as_f64)
        .unwrap_or_default();
    let snippet = snippet_for(document, query);

    let correspondent = taxonomy.correspondent(document.get("correspondent"));
    let owner = correspondent
        .clone()
        .unwrap_or_else(|| crate::indexer::SHARED_OWNER.to_string());

    let mut metadata = serde_json::Map::new();
    if let Some(correspondent) = &correspondent {
        metadata.insert(
            "correspondent".to_string(),
            Value::String(correspondent.clone()),
        );
    }
    if let Some(document_type) = taxonomy.document_type(document.get("document_type")) {
        metadata.insert("document_type".to_string(), Value::String(document_type));
    }
    let tags = taxonomy.tag_names(document.get("tags"));
    if !tags.is_empty() {
        metadata.insert("tags".to_string(), Value::String(tags.join(", ")));
    }
    if let Some(file_name) = document
        .get("original_file_name")
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
    {
        metadata.insert("file".to_string(), Value::String(file_name.to_string()));
    }
    if let Some(added) = document.get("added").and_then(Value::as_str) {
        metadata.insert("added".to_string(), Value::String(added.to_string()));
    }

    FederatedHit {
        source: config.source_id.clone(),
        app_url: format!("{}/documents/{}", config.app_base, remote_id),
        remote_id,
        title,
        snippet,
        origin_url: String::new(),
        content_type,
        owner,
        score,
        created,
        metadata: Value::Object(metadata),
    }
}

/// Builds a snippet from Paperless's highlighted excerpt (falling back to the
/// truncated content), stripping Paperless's `<span class="match">` markup and
/// reusing the shared text highlighter so every source renders identically.
fn snippet_for(document: &Value, query: &str) -> Option<String> {
    let highlight = document
        .pointer("/__search_hit__/highlights")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let content = document
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let raw = if highlight.trim().is_empty() {
        content
    } else {
        highlight
    };
    if raw.trim().is_empty() {
        return None;
    }
    let plain = text::html_to_text(raw);
    let plain = plain.trim();
    if plain.is_empty() {
        return None;
    }
    text::snippet_from_text(plain, query).or_else(|| {
        let truncated: String = plain.chars().take(260).collect();
        (!truncated.trim().is_empty()).then_some(truncated)
    })
}

async fn request_json(
    config: &PaperlessSearchConfig,
    url: &str,
    params: &[(&str, &str)],
) -> Result<Value, u16> {
    let response = config
        .client
        .get(url)
        .header(
            reqwest::header::AUTHORIZATION,
            format!("Token {}", config.token),
        )
        .query(params)
        .send()
        .await
        .map_err(|_| 0u16)?;
    if !response.status().is_success() {
        return Err(response.status().as_u16());
    }
    response.json().await.map_err(|_| 0u16)
}

async fn fetch_json(client: &reqwest::Client, token: &str, url: &str) -> Result<Value, u16> {
    let response = client
        .get(url)
        .header(reqwest::header::AUTHORIZATION, format!("Token {token}"))
        .send()
        .await
        .map_err(|_| 0u16)?;
    if !response.status().is_success() {
        return Err(response.status().as_u16());
    }
    response.json().await.map_err(|_| 0u16)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn config() -> PaperlessSearchConfig {
        PaperlessSearchConfig {
            source_id: "paperless".to_string(),
            client: reqwest::Client::new(),
            base_url: "http://127.0.0.1:8000".to_string(),
            token: "t".to_string(),
            app_base: "https://paperless.example.org".to_string(),
            max_results: 20,
        }
    }

    fn taxonomy() -> Taxonomy {
        let mut taxonomy = Taxonomy::default();
        taxonomy.correspondents.insert(7, "ACME".to_string());
        taxonomy.document_types.insert(2, "Invoice".to_string());
        taxonomy.tags.insert(3, "finance".to_string());
        taxonomy.tags.insert(4, "2024".to_string());
        taxonomy
    }

    #[test]
    fn maps_a_search_result_to_a_unified_hit() {
        let document = json!({
            "id": 42,
            "title": "Invoice 42",
            "content": "total due 100",
            "created": "2024-02-01",
            "added": "2024-02-02T10:00:00Z",
            "correspondent": 7,
            "document_type": 2,
            "tags": [3, 4],
            "original_file_name": "invoice.pdf",
            "mime_type": "application/pdf",
            "__search_hit__": { "score": 0.75, "highlights": "total <span class=\"match\">due</span> 100" }
        });
        let hit = map_document(&config(), &taxonomy(), &document, "due");
        assert_eq!(hit.source, "paperless");
        assert_eq!(hit.remote_id, "42");
        assert_eq!(hit.title, "Invoice 42");
        assert_eq!(hit.content_type, "application/pdf");
        assert_eq!(hit.owner, "ACME");
        assert_eq!(hit.created, Some(1_706_745_600));
        assert_eq!(hit.score, 0.75);
        assert_eq!(hit.app_url, "https://paperless.example.org/documents/42");
        assert_eq!(hit.metadata["correspondent"], json!("ACME"));
        assert_eq!(hit.metadata["document_type"], json!("Invoice"));
        assert_eq!(hit.metadata["tags"], json!("finance, 2024"));
        assert_eq!(hit.metadata["file"], json!("invoice.pdf"));
        let snippet = hit.snippet.expect("snippet");
        assert!(snippet.contains("<em>due</em>"), "got: {snippet}");
    }

    #[test]
    fn maps_documents_without_correspondent_as_shared() {
        let document = json!({ "id": 1, "title": "", "__search_hit__": { "score": 0.1 } });
        let hit = map_document(&config(), &taxonomy(), &document, "anything");
        assert_eq!(hit.title, "Document 1");
        assert_eq!(hit.owner, "shared");
        assert_eq!(hit.app_url, "https://paperless.example.org/documents/1");
        assert_eq!(hit.content_type, "application/pdf");
        assert!(hit.snippet.is_none());
    }

    #[test]
    fn resolves_tag_names_and_ignores_unknown_ids() {
        let taxonomy = taxonomy();
        let names = taxonomy.tag_names(Some(&json!([3, 99, "x"])));
        assert_eq!(names, vec!["finance".to_string()]);
        assert!(taxonomy.tag_names(None).is_empty());
        assert_eq!(
            taxonomy.correspondent(Some(&json!(7))).as_deref(),
            Some("ACME")
        );
        assert!(taxonomy.correspondent(Some(&json!(99))).is_none());
    }

    #[tokio::test]
    async fn empty_query_returns_no_hits() {
        let hits = search(&config(), &taxonomy(), "   ").await;
        assert!(hits.is_empty());
    }
}
