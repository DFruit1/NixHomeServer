//! Indexes Paperless documents through its REST API. Paperless has already
//! read every scan, so its stored text is taken as it is: nothing is
//! re-extracted here. Indexed documents take part in the same ranking, related
//! passages and reranking as everything else, which a live query against
//! Paperless's own index could not offer.
use std::path::PathBuf;

use serde_json::Value;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::paperless_search::{
    fetch_json, load_taxonomy, taxonomy_page_url, PaperlessSearchConfig,
};
use crate::text::truncate_text;
use crate::timeutil::parse_date;

const PAGE_SIZE: usize = 100;
/// Bounds one pass at 100,000 documents.
const MAX_PAGES: usize = 1_000;

pub struct PaperlessApiExtractor {
    pub token_file: Option<PathBuf>,
}

fn text(document: &Value, key: &str) -> Option<String> {
    document
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

impl super::Extractor for PaperlessApiExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let base_url = source.require_setting("baseUrl")?;
        let token_file = self
            .token_file
            .as_ref()
            .ok_or("SEARCH_PAPERLESS_TOKEN_FILE must be set for the Paperless source")?;
        let token = std::fs::read_to_string(token_file)
            .map_err(|err| format!("failed to read the Paperless API token: {err}"))?
            .trim()
            .to_string();
        let config = PaperlessSearchConfig {
            source_id: source.id.clone(),
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .map_err(|err| format!("failed to build the Paperless client: {err}"))?,
            base_url: base_url.clone(),
            token,
            app_base: source.app_base.trim_end_matches('/').to_string(),
            max_results: 0,
        };
        // Extraction runs on a blocking thread of the indexer's runtime.
        let documents = tokio::runtime::Handle::current().block_on(async {
            let taxonomy = load_taxonomy(&config.client, &config).await?;
            let first = url::Url::parse(&format!(
                "{}/api/documents/?page_size={PAGE_SIZE}&ordering=id",
                base_url.trim_end_matches('/')
            ))
            .map_err(|_| "The Paperless documents endpoint is invalid.".to_string())?;
            let mut next = Some(first.clone());
            let mut pages = 0;
            let mut documents = Vec::new();
            while let Some(url) = next {
                pages += 1;
                if pages > MAX_PAGES {
                    return Err("Paperless document listing exceeded its safety limit.".into());
                }
                let page = fetch_json(&config.client, &config.token, url.as_str())
                    .await
                    .map_err(|status| format!("Paperless document listing failed ({status})"))?;
                documents.extend(
                    page.get("results")
                        .and_then(Value::as_array)
                        .ok_or("Paperless returned an invalid document listing.")?
                        .iter()
                        .cloned(),
                );
                next = page
                    .get("next")
                    .and_then(Value::as_str)
                    .map(|next| taxonomy_page_url(&first, next))
                    .transpose()?;
            }
            Ok::<_, String>((taxonomy, documents))
        });
        let (taxonomy, documents) = documents?;

        for document in documents {
            let Some(id) = document.get("id").and_then(Value::as_i64) else {
                continue;
            };
            let correspondent = taxonomy.correspondent(document.get("correspondent"));
            let mut metadata = serde_json::Map::new();
            // As in the live results this source replaces: a document is filed
            // under whoever it came from.
            metadata.insert(
                "owner".to_string(),
                Value::String(
                    correspondent
                        .clone()
                        .unwrap_or_else(|| crate::indexer::SHARED_OWNER.to_string()),
                ),
            );
            if let Some(correspondent) = correspondent {
                metadata.insert("correspondent".to_string(), Value::String(correspondent));
            }
            if let Some(kind) = taxonomy.document_type(document.get("document_type")) {
                metadata.insert("document_type".to_string(), Value::String(kind));
            }
            let tags = taxonomy.tag_names(document.get("tags"));
            if !tags.is_empty() {
                metadata.insert("tags".to_string(), serde_json::json!(tags));
            }
            if let Some(file) = text(&document, "original_file_name") {
                metadata.insert("file".to_string(), Value::String(file));
            }
            if let Some(added) = text(&document, "added") {
                metadata.insert("added".to_string(), Value::String(added));
            }
            if let Some(serial) = document
                .get("archive_serial_number")
                .and_then(Value::as_i64)
            {
                metadata.insert(
                    "identifiers".to_string(),
                    serde_json::json!({ "asn": serial.to_string() }),
                );
            }
            if let Some(pages) = document.get("page_count").and_then(Value::as_i64) {
                metadata.insert("pages".to_string(), Value::from(pages));
            }
            let mut body = text(&document, "content").unwrap_or_default();
            // What someone wrote about the document is part of finding it.
            let notes: Vec<String> = document
                .get("notes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|note| text(note, "note"))
                .collect();
            if !notes.is_empty() {
                body = format!("Notes: {}\n{body}", notes.join("\n"));
            }
            let fields: Vec<String> = document
                .get("custom_fields")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|field| match field.get("value") {
                    Some(Value::String(value)) if !value.trim().is_empty() => {
                        Some(value.trim().to_string())
                    }
                    Some(Value::Number(value)) => Some(value.to_string()),
                    _ => None,
                })
                .collect();
            if !fields.is_empty() {
                body = format!("{}\n{body}", fields.join("\n"));
            }
            emit(ExtractedDocument {
                incidental_text: String::new(),
                external_id: id.to_string(),
                kind: "document".to_string(),
                title: text(&document, "title").unwrap_or_else(|| format!("Document {id}")),
                body_text: truncate_text(&body, super::document::TEXT_LIMIT),
                content_type: text(&document, "mime_type")
                    .unwrap_or_else(|| "application/pdf".to_string()),
                origin_url: String::new(),
                app_url: format!("{}/documents/{id}", config.app_base),
                file_path: String::new(),
                size_bytes: 0,
                content_created_at: text(&document, "created").as_deref().and_then(parse_date),
                content_modified_at: text(&document, "modified").as_deref().and_then(parse_date),
                metadata: Value::Object(metadata),
            });
        }
        Ok(())
    }
}
