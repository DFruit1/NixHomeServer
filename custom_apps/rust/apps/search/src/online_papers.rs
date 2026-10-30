//! Opt-in scholarly discovery through the host's loopback SearXNG instance.
//! Results are transient: neither queries nor papers enter the saved index.

use std::collections::HashSet;
use std::time::Duration;

use serde_json::{json, Value};
use url::Url;

use crate::{federate::FederatedHit, text, timeutil};

pub const KIND: &str = "online-paper";
pub const SOURCE: &str = "online-papers";
pub const MAX_RESULTS: usize = 50;
const MAX_RESPONSE_BYTES: usize = 2 * 1024 * 1024;

pub struct OnlinePapers {
    endpoint: Url,
    client: reqwest::Client,
}

impl OnlinePapers {
    pub fn from_env() -> Result<Option<Self>, String> {
        let Some(base) = std::env::var("SEARCH_SEARXNG_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
        else {
            return Ok(None);
        };
        let mut endpoint = Url::parse(&base)
            .map_err(|_| "SEARCH_SEARXNG_URL must be a loopback HTTP URL".to_string())?;
        let loopback = match endpoint.host() {
            Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
            Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
            Some(url::Host::Domain("localhost")) => true,
            _ => false,
        };
        if endpoint.scheme() != "http"
            || !loopback
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || endpoint.path() != "/"
        {
            return Err("SEARCH_SEARXNG_URL must be a loopback HTTP origin".into());
        }
        endpoint.set_path("/search");
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|err| format!("could not build scholarly search client: {err}"))?;
        Ok(Some(Self { endpoint, client }))
    }

    pub async fn search(&self, query: &str) -> Result<Value, String> {
        // SearXNG's !engine/!category and !!redirect syntax can override the
        // requested category. Keep this surface restricted to publications.
        if query.split_whitespace().any(|term| term.starts_with('!')) {
            return Err("Online papers does not support SearXNG ! shortcuts.".into());
        }
        let mut response = self
            .client
            .get(self.endpoint.clone())
            .query(&[
                ("q", query),
                ("categories", "scientific publications"),
                ("format", "json"),
                ("safesearch", "1"),
            ])
            .send()
            .await
            .map_err(|_| "Online paper search is unavailable. Try again shortly.".to_string())?
            .error_for_status()
            .map_err(|_| "Online paper search is unavailable. Try again shortly.".to_string())?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "Online paper search returned an incomplete response.".to_string())?
        {
            if bytes.len() + chunk.len() > MAX_RESPONSE_BYTES {
                return Err(
                    "Online paper search returned too much data. Narrow your search.".into(),
                );
            }
            bytes.extend_from_slice(&chunk);
        }
        let payload: Value = serde_json::from_slice(&bytes)
            .map_err(|_| "Online paper search returned an invalid response.".to_string())?;
        let results = payload
            .get("results")
            .and_then(Value::as_array)
            .ok_or_else(|| "Online paper search returned an invalid response.".to_string())?;
        let mut seen = HashSet::new();
        let hits: Vec<_> = results
            .iter()
            .filter_map(|entry| {
                let url = Url::parse(entry.get("url")?.as_str()?).ok()?;
                if !matches!(url.scheme(), "http" | "https") || !seen.insert(url.to_string()) {
                    return None;
                }
                let title = text::html_to_text(entry.get("title")?.as_str()?);
                let plain = text::html_to_text(
                    text::truncate_text(
                        entry.get("content").and_then(Value::as_str).unwrap_or(""),
                        20_000,
                    )
                    .as_str(),
                );
                let snippet = text::snippet_from_text(&plain, query).or_else(|| {
                    let excerpt: String = plain.chars().take(260).collect();
                    (!excerpt.trim().is_empty()).then(|| text::highlight_terms(&excerpt, &[]))
                });
                let engines = entry
                    .get("engines")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default();
                Some(
                    FederatedHit {
                        source: SOURCE.into(),
                        kind: KIND.into(),
                        remote_id: timeutil::sha256_hex(&[url.as_str()]),
                        title: text::truncate_text(title.trim(), 1000),
                        snippet,
                        origin_url: url.to_string(),
                        app_url: url.to_string(),
                        content_type: "".into(),
                        owner: "shared".into(),
                        score: 0.0,
                        created: entry
                            .get("publishedDate")
                            .and_then(Value::as_str)
                            .and_then(timeutil::parse_date),
                        metadata: json!({"engines": engines}),
                    }
                    .to_json(),
                )
            })
            .take(MAX_RESULTS)
            .collect();
        let warnings: Vec<_> = payload.get("unresponsive_engines").and_then(Value::as_array)
            .into_iter().flatten().filter_map(|entry| entry.get(0)?.as_str())
            .map(|engine| json!({"source": SOURCE, "message": format!("{engine} did not respond; results may be incomplete.")}))
            .collect();
        Ok(json!({"total": hits.len(), "hits": hits, "hasMore": false,
            "limited": true, "warnings": warnings}))
    }
}
