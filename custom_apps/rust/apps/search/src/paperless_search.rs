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
) -> Result<Vec<FederatedHit>, String> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
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
    let value =
        response.map_err(|_| "The document server could not complete this search.".to_string())?;
    let results = value
        .get("results")
        .and_then(Value::as_array)
        .ok_or("The document server returned an invalid search response.")?;
    Ok(results
        .iter()
        .map(|document| map_document(config, taxonomy, document, query))
        .collect())
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
        // Keep each resolved tag as its own value so the shared facet filter
        // can match it exactly; presentation joins them for the API response.
        metadata.insert(
            "tags".to_string(),
            Value::Array(tags.into_iter().map(Value::String).collect()),
        );
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
        kind: "document".to_string(),
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
        (!truncated.trim().is_empty()).then(|| text::highlight_terms(&truncated, &[]))
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

    #[tokio::test]
    async fn upstream_failure_is_distinct_from_a_successful_empty_search() {
        use axum::{routing::get, Json, Router};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new()
            .route(
                "/ok/api/documents/",
                get(|| async { Json(serde_json::json!({"results":[]})) }),
            )
            .route(
                "/bad/api/documents/",
                get(|| async { axum::http::StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route(
                "/invalid/api/documents/",
                get(|| async { Json(serde_json::json!({})) }),
            );
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let mut config = config();
        config.base_url = format!("http://{address}/ok");
        assert!(search(&config, &Taxonomy::default(), "test")
            .await
            .unwrap()
            .is_empty());
        for path in ["bad", "invalid"] {
            config.base_url = format!("http://{address}/{path}");
            assert!(search(&config, &Taxonomy::default(), "test").await.is_err());
        }
        task.abort();
    }

    #[test]
    fn unmatched_snippet_escapes_decoded_markup() {
        let document = serde_json::json!({"content": "&lt;img src=x onerror=alert(1)&gt; &lt;em&gt;literal&lt;/em&gt;"});
        let snippet = snippet_for(&document, "title-only-match").expect("fallback snippet");
        assert!(!snippet.contains("<img"), "{snippet}");
        assert!(!snippet.contains("<em>"), "{snippet}");
        assert!(snippet.contains("&lt;img"), "{snippet}");
    }
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
        // Resolved tags stay structured internally so each one is its own facet.
        assert_eq!(hit.metadata["tags"], json!(["finance", "2024"]));
        assert_eq!(hit.metadata["file"], json!("invoice.pdf"));
        let snippet = hit.snippet.as_deref().expect("snippet");
        assert!(snippet.contains("<em>due</em>"), "got: {snippet}");

        // The outward JSON presentation keeps the historical joined string.
        let json = hit.to_json();
        assert_eq!(json["metadata"]["tags"], json!("finance, 2024"));
        assert_eq!(json["metadata"]["correspondent"], json!("ACME"));
        assert_eq!(json["metadata"]["document_type"], json!("Invoice"));
        assert_eq!(json["metadata"]["file"], json!("invoice.pdf"));
        assert_eq!(json["id"], json!("paperless:42"));
        assert_eq!(json["source"], json!("paperless"));
        assert_eq!(json["title"], json!("Invoice 42"));
        assert_eq!(json["contentType"], json!("application/pdf"));
        assert_eq!(json["owner"], json!("ACME"));
        assert_eq!(json["score"], json!(0.75));
        assert_eq!(json["created"], json!(1_706_745_600));
        assert_eq!(
            json["appUrl"],
            json!("https://paperless.example.org/documents/42")
        );
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

    fn tag_filter(tag: &str) -> crate::solr::SearchFilters {
        crate::solr::SearchFilters {
            tag: Some(tag.to_string()),
            ..Default::default()
        }
    }

    fn multi_tag_document() -> Value {
        json!({
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
        })
    }

    #[test]
    fn mapped_multi_tag_hit_matches_each_individual_tag() {
        let hit = map_document(&config(), &taxonomy(), &multi_tag_document(), "due");

        // An unfiltered search keeps the hit, exactly as before.
        assert!(hit.matches_filters(&crate::solr::SearchFilters::default()));

        // Every resolved tag is its own exact facet value.
        for tag in ["finance", "2024"] {
            assert!(
                hit.matches_filters(&tag_filter(tag)),
                "tag {tag} should match"
            );
        }
        // The joined presentation is not itself a selectable tag, and unrelated
        // tags stay excluded.
        assert!(!hit.matches_filters(&tag_filter("finance, 2024")));
        assert!(!hit.matches_filters(&tag_filter("tax")));

        // Serialising for presentation must not change filtering or internals.
        let presentation = hit.to_json();
        assert_eq!(presentation["metadata"]["tags"], json!("finance, 2024"));
        assert!(hit.matches_filters(&tag_filter("finance")));
        assert_eq!(hit.to_json(), presentation);
        assert_eq!(hit.metadata["tags"], json!(["finance", "2024"]));
    }

    #[test]
    fn comma_in_a_tag_name_stays_one_exact_tag() {
        let mut taxonomy = taxonomy();
        taxonomy.tags.insert(5, "Research, Development".to_string());
        let document = json!({ "id": 43, "title": "Lab notes", "tags": [5, 3] });
        let hit = map_document(&config(), &taxonomy, &document, "lab");

        // Neither mapping nor presentation splits the punctuation.
        assert_eq!(
            hit.metadata["tags"],
            json!(["Research, Development", "finance"])
        );
        assert_eq!(
            hit.to_json()["metadata"]["tags"],
            json!("Research, Development, finance")
        );

        assert!(hit.matches_filters(&tag_filter("Research, Development")));
        assert!(hit.matches_filters(&tag_filter("finance")));
        // A component of a comma-containing name never becomes its own tag.
        assert!(!hit.matches_filters(&tag_filter("Research")));
        assert!(!hit.matches_filters(&tag_filter("Development")));
    }

    #[test]
    fn omits_tags_when_no_name_resolves() {
        let document = json!({ "id": 44, "title": "Unknown tags", "tags": [99, "x"] });
        let hit = map_document(&config(), &taxonomy(), &document, "unknown");
        assert!(hit.metadata.get("tags").is_none());
        assert!(hit.to_json()["metadata"].get("tags").is_none());

        let mixed = json!({ "id": 45, "title": "Mixed tags", "tags": [3, 99] });
        let hit = map_document(&config(), &taxonomy(), &mixed, "mixed");
        assert_eq!(hit.metadata["tags"], json!(["finance"]));
        assert_eq!(hit.to_json()["metadata"]["tags"], json!("finance"));
        assert!(hit.matches_filters(&tag_filter("finance")));
        assert!(!hit.matches_filters(&tag_filter("99")));
    }

    #[tokio::test]
    async fn empty_query_returns_no_hits() {
        let hits = search(&config(), &taxonomy(), "   ")
            .await
            .expect("empty query");
        assert!(hits.is_empty());
    }
}
