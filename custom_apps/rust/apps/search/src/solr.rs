use std::collections::HashMap;
use std::time::Duration;

use serde_json::{json, Value};

use crate::timeutil::epoch_to_solr_date;
use crate::{db, text};

/// One document rendered for the Solr index.
#[derive(Debug, Clone)]
pub struct SolrDocument {
    pub id: String,
    pub source: String,
    pub title: String,
    pub body: String,
    pub content_type: String,
    pub origin_url: String,
    pub app_url: String,
    pub file_path: String,
    pub size_bytes: i64,
    pub content_created: Option<i64>,
    pub content_modified: Option<i64>,
    /// Owning user for per-user sources, or a shared sentinel for collections
    /// with no per-user ownership. Indexed as `owner_s` for filtering/faceting.
    pub owner: String,
    pub metadata: Value,
}

impl SolrDocument {
    pub fn from_record(source_id: &str, record: &db::DocumentRecord, owner: &str) -> Self {
        Self {
            id: db::full_document_id(source_id, &record.external_id),
            source: source_id.to_string(),
            title: record.title.clone(),
            body: record.body_text.clone(),
            content_type: record.content_type.clone(),
            origin_url: record.origin_url.clone(),
            app_url: record.app_url.clone(),
            file_path: record.file_path.clone(),
            size_bytes: record.size_bytes,
            content_created: record.content_created_at,
            content_modified: record.content_modified_at,
            owner: owner.to_string(),
            metadata: record.metadata.clone(),
        }
    }

    pub(crate) fn to_solr_json(&self) -> Value {
        let mut doc = json!({
            "id": self.id,
            "source": self.source,
            "title": self.title,
            "body": self.body,
            "content_type": self.content_type,
            "origin_url": self.origin_url,
            "app_url": self.app_url,
            "file_path": self.file_path,
            "size_bytes": self.size_bytes,
        });
        if let Some(created) = self.content_created {
            doc["content_created"] = json!(epoch_to_solr_date(created));
        }
        if let Some(modified) = self.content_modified {
            doc["content_modified"] = json!(epoch_to_solr_date(modified));
        }
        if !self.owner.is_empty() {
            doc["owner_s"] = json!(self.owner);
        }
        if let Value::Object(entries) = &self.metadata {
            for (key, value) in entries {
                if value.is_null() {
                    continue;
                }
                let scalar = match value {
                    Value::String(text) => text.clone(),
                    Value::Number(number) => number.to_string(),
                    Value::Bool(flag) => flag.to_string(),
                    _ => continue,
                };
                // Solr string fields reject terms longer than 32,766 bytes;
                // metadata values (mail headers, URLs) can exceed that. The
                // full value lives in Postgres, so cap what is indexed.
                doc[format!("meta_{key}_s")] = json!(truncate_solr_string(&scalar));
            }
        }
        doc
    }
}

/// Solr string terms must stay below 32,766 UTF-8 bytes. Cap metadata
/// values conservatively on a char boundary.
fn truncate_solr_string(value: &str) -> String {
    const MAX_BYTES: usize = 4_000;
    if value.len() <= MAX_BYTES {
        return value.to_string();
    }
    let mut truncated = value[..MAX_BYTES].to_string();
    while !truncated.is_char_boundary(truncated.len()) {
        truncated.pop();
    }
    truncated
}

#[derive(Debug)]
pub struct SearchHit {
    pub id: String,
    pub source: String,
    pub title: String,
    pub snippet: Option<String>,
    pub origin_url: String,
    pub app_url: String,
    pub content_type: String,
    pub owner: String,
    pub score: f64,
    pub created: Option<i64>,
}

#[derive(Debug)]
pub struct SearchResponse {
    pub hits: Vec<SearchHit>,
    pub total: u64,
    pub source_facets: Vec<(String, u64)>,
    pub content_type_facets: Vec<(String, u64)>,
    pub owner_facets: Vec<(String, u64)>,
}

/// Admin-selected filters applied to the Solr query. Every field is optional;
/// an unset filter does not constrain results.
#[derive(Debug, Clone, Default)]
pub struct SearchFilters {
    pub source: Option<String>,
    pub content_type: Option<String>,
    pub owner: Option<String>,
    /// Inclusive lower/upper bounds, `YYYY-MM-DD`, on `content_created`.
    pub created_after: Option<String>,
    pub created_before: Option<String>,
}

impl SearchFilters {
    /// Builds the Solr `fq` clauses for the selected filters.
    fn clauses(&self, selected_sources: &[String]) -> Vec<String> {
        let mut clauses = Vec::new();
        if let Some(source) = &self.source {
            clauses.push(format!("source:{}", solr_string_term(source)));
        } else if !selected_sources.is_empty() {
            let allowed = selected_sources
                .iter()
                .map(|source| solr_string_term(source))
                .collect::<Vec<_>>()
                .join(" OR ");
            clauses.push(format!("source:({allowed})"));
        }
        if let Some(content_type) = &self.content_type {
            clauses.push(format!("content_type:{}", solr_string_term(content_type)));
        }
        if let Some(owner) = &self.owner {
            clauses.push(format!("owner_s:{}", solr_string_term(owner)));
        }
        if self.created_after.is_some() || self.created_before.is_some() {
            let lower = self
                .created_after
                .clone()
                .unwrap_or_else(|| "*".to_string());
            let upper = self
                .created_before
                .clone()
                .unwrap_or_else(|| "*".to_string());
            clauses.push(format!(
                "content_created:[{lower}T00:00:00Z TO {upper}T23:59:59Z]"
            ));
        }
        clauses
    }
}

fn solr_string_term(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

pub struct SolrClient {
    http: reqwest::Client,
    base_url: String,
    core: String,
}

impl SolrClient {
    pub fn new(base_url: &str, core: &str) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .build()
                .expect("reqwest client"),
            base_url: base_url.trim_end_matches('/').to_string(),
            core: core.to_string(),
        }
    }

    pub fn core(&self) -> &str {
        &self.core
    }

    pub async fn core_status(&self, name: &str) -> Result<Option<String>, String> {
        let url = format!(
            "{}/admin/cores?action=STATUS&wt=json&core={}",
            self.base_url, name
        );
        let response: Value = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|err| format!("solr status request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr status response parse failed: {err}"))?;
        let status = response
            .pointer("/status")
            .and_then(Value::as_object)
            .ok_or_else(|| format!("unexpected solr status response: {response}"))?;
        Ok(status.get(name).map(|core| {
            core.get("state")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string()
        }))
    }

    /// Creates the search core from the default configset if it does not exist.
    pub async fn create_core(&self, config_set: &str) -> Result<(), String> {
        let mut url = format!(
            "{}/admin/cores?action=CREATE&name={}&wt=json",
            self.base_url, self.core
        );
        if !config_set.is_empty() {
            url.push_str(&format!("&configSet={config_set}"));
        }
        let response: Value = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|err| format!("solr core create request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr core create response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr refused to create core: {response}"));
        }
        Ok(())
    }

    pub async fn add_documents(&self, docs: &[SolrDocument]) -> Result<(), String> {
        if docs.is_empty() {
            return Ok(());
        }
        let payload: Vec<Value> = docs.iter().map(SolrDocument::to_solr_json).collect();
        let url = format!("{}/{}/update?commit=true", self.base_url, self.core);
        let response: Value = self
            .http
            .post(&url)
            .json(&json!({ "add": payload }))
            .send()
            .await
            .map_err(|err| format!("solr add request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr add response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr rejected document add: {response}"));
        }
        Ok(())
    }

    pub async fn delete_ids(&self, ids: &[String]) -> Result<(), String> {
        if ids.is_empty() {
            return Ok(());
        }
        let url = format!("{}/{}/update?commit=true", self.base_url, self.core);
        let payload: Vec<Value> = ids.iter().map(|id| json!({ "delete": id })).collect();
        let response: Value = self
            .http
            .post(&url)
            .json(&Value::Array(payload))
            .send()
            .await
            .map_err(|err| format!("solr delete request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr delete response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr rejected deletes: {response}"));
        }
        Ok(())
    }

    pub async fn delete_by_source(&self, source: &str) -> Result<(), String> {
        let url = format!("{}/{}/update?commit=true", self.base_url, self.core);
        let response: Value = self
            .http
            .post(&url)
            .json(&json!({ "delete": { "query": format!("source:{source}") } }))
            .send()
            .await
            .map_err(|err| format!("solr delete-by-source request failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr delete-by-source response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr rejected delete-by-source: {response}"));
        }
        Ok(())
    }

    pub async fn search(
        &self,
        query: &str,
        selected_sources: &[String],
        filters: &SearchFilters,
        rows: usize,
        offset: usize,
    ) -> Result<SearchResponse, String> {
        let mut params: Vec<(&str, String)> = vec![
            ("q", query.to_string()),
            // Stored fields only: never leak the stored body into responses.
            (
                "fl",
                "id source title origin_url app_url content_type owner_s content_created score"
                    .to_string(),
            ),
            ("defType", "edismax".to_string()),
            ("qf", "title^4 body".to_string()),
            ("rows", rows.to_string()),
            ("start", offset.to_string()),
            ("facet", "true".to_string()),
            ("facet.field", "{!ex=src}source".to_string()),
            ("facet.field", "{!ex=ct}content_type".to_string()),
            ("facet.field", "{!ex=own}owner_s".to_string()),
            ("facet.mincount", "1".to_string()),
            ("facet.limit", "50".to_string()),
            ("hl", "true".to_string()),
            ("hl.fl", "body".to_string()),
            ("hl.fragsize", "220".to_string()),
            ("hl.snippets", "1".to_string()),
            ("wt", "json".to_string()),
        ];
        for clause in filters.clauses(selected_sources) {
            params.push(("fq", clause));
        }
        let url = format!("{}/{}/select", self.base_url, self.core);
        let response: Value = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await
            .map_err(|err| format!("solr query failed: {err}"))?
            .json()
            .await
            .map_err(|err| format!("solr query response parse failed: {err}"))?;
        if response.get("error").is_some() {
            return Err(format!("solr query rejected: {response}"));
        }
        parse_search_response(&response)
    }
}

fn facet_pairs(facet: &Value) -> Vec<(String, u64)> {
    facet
        .as_object()
        .map(|entries| {
            entries
                .iter()
                .filter_map(|(name, count)| {
                    count.as_u64().and_then(|count| {
                        if count > 0 {
                            Some((name.clone(), count))
                        } else {
                            None
                        }
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_response(response: &Value) -> Result<SearchResponse, String> {
    let body = response
        .pointer("/response")
        .ok_or_else(|| format!("solr response missing /response: {response}"))?;
    let total = body
        .get("numFound")
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("solr response missing numFound: {response}"))?;
    let highlight: HashMap<String, Value> = response
        .pointer("/highlighting")
        .and_then(Value::as_object)
        .map(|entries| {
            entries
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        })
        .unwrap_or_default();

    let mut hits = Vec::new();
    for doc in body
        .get("docs")
        .and_then(Value::as_array)
        .unwrap_or(&Vec::new())
    {
        let id = doc
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let snippet = highlight
            .get(&id)
            .and_then(|entry| entry.get("body"))
            .and_then(Value::as_array)
            .and_then(|snippets| snippets.first())
            .and_then(Value::as_str)
            .map(text::decode_html_entities);
        let score = doc.get("score").and_then(Value::as_f64).unwrap_or_default();
        hits.push(SearchHit {
            source: doc
                .get("source")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            title: doc
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            snippet,
            origin_url: doc
                .get("origin_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            app_url: doc
                .get("app_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            content_type: doc
                .get("content_type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            owner: doc
                .get("owner_s")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            created: doc
                .get("content_created")
                .and_then(Value::as_str)
                .and_then(crate::timeutil::parse_date),
            id,
            score,
        });
    }

    let facet_counts = response.pointer("/facet_counts/facet_fields").cloned();
    let (source_facets, content_type_facets, owner_facets) = match facet_counts {
        Some(Value::Object(fields)) => (
            fields.get("source").map(facet_pairs).unwrap_or_default(),
            fields
                .get("content_type")
                .map(facet_pairs)
                .unwrap_or_default(),
            fields.get("owner_s").map(facet_pairs).unwrap_or_default(),
        ),
        _ => (Vec::new(), Vec::new(), Vec::new()),
    };

    Ok(SearchResponse {
        hits,
        total,
        source_facets,
        content_type_facets,
        owner_facets,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_solr_select_response() {
        let response = json!({
            "response": {
                "numFound": 2,
                "docs": [
                    {
                        "id": "paperless:1",
                        "source": "paperless",
                        "title": "Invoice",
                        "origin_url": "",
                        "app_url": "https://paperless.example.org/documents/1",
                        "content_type": "application/pdf",
                        "score": 1.5,
                        "content_created": "2024-02-01T00:00:00Z"
                    },
                    {
                        "id": "kiwix:A/Help.html",
                        "source": "kiwix",
                        "title": "Help",
                        "origin_url": "https://wiki.example.org/content/w/A/Help.html",
                        "app_url": "https://wiki.example.org",
                        "content_type": "text/html",
                        "score": 0.75
                    }
                ]
            },
            "highlighting": {
                "paperless:1": { "body": ["Invoice <em>total</em> due"] }
            },
            "facet_counts": {
                "facet_fields": {
                    "source": { "paperless": 1, "kiwix": 1 },
                    "content_type": { "application/pdf": 1 },
                    "owner_s": { "acme": 1 }
                }
            }
        });
        let parsed = parse_search_response(&response).expect("parse");
        assert_eq!(parsed.total, 2);
        assert_eq!(parsed.hits.len(), 2);
        assert_eq!(
            parsed.hits[0].snippet.as_deref(),
            Some("Invoice <em>total</em> due")
        );
        assert_eq!(parsed.hits[0].created, Some(1_706_745_600));
        assert_eq!(parsed.source_facets.len(), 2);
        assert_eq!(
            parsed.content_type_facets,
            vec![("application/pdf".to_string(), 1u64)]
        );
        assert_eq!(parsed.owner_facets, vec![("acme".to_string(), 1u64)]);
    }

    #[test]
    fn filters_build_fq_clauses() {
        let selected = vec!["paperless".to_string(), "mail-archive".to_string()];
        let none = SearchFilters::default();
        assert_eq!(
            none.clauses(&selected),
            vec!["source:(\"paperless\" OR \"mail-archive\")"]
        );

        let filtered = SearchFilters {
            source: Some("mail-archive".to_string()),
            content_type: Some("message/rfc822".to_string()),
            owner: Some("dsaw".to_string()),
            created_after: Some("2024-01-01".to_string()),
            created_before: Some("2024-12-31".to_string()),
        };
        let clauses = filtered.clauses(&selected);
        assert!(clauses.contains(&"source:\"mail-archive\"".to_string()));
        assert!(clauses.contains(&"content_type:\"message/rfc822\"".to_string()));
        assert!(clauses.contains(&"owner_s:\"dsaw\"".to_string()));
        assert!(clauses.contains(
            &"content_created:[2024-01-01T00:00:00Z TO 2024-12-31T23:59:59Z]".to_string()
        ));
    }

    #[test]
    fn renders_metadata_as_dynamic_fields() {
        let record = db::DocumentRecord {
            external_id: "1".to_string(),
            kind: "document".to_string(),
            title: "t".to_string(),
            body_text: "b".to_string(),
            content_type: "application/pdf".to_string(),
            origin_url: String::new(),
            app_url: String::new(),
            file_path: String::new(),
            size_bytes: 10,
            checksum: "sum".to_string(),
            content_created_at: Some(0),
            content_modified_at: None,
            metadata: serde_json::json!({ "owner": "acme", "correspondent": "acme", "page_count": 4 }),
        };
        let doc = SolrDocument::from_record("paperless", &record, "acme");
        let rendered = doc.to_solr_json();
        assert_eq!(rendered["meta_correspondent_s"], json!("acme"));
        assert_eq!(rendered["meta_page_count_s"], json!("4"));
        assert_eq!(rendered["owner_s"], json!("acme"));
        assert_eq!(rendered["meta_owner_s"], json!("acme"));
        assert_eq!(rendered["content_created"], json!("1970-01-01T00:00:00Z"));
        assert!(rendered.get("content_modified").is_none());
    }
}
