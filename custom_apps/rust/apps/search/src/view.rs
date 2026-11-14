//! The terminal equivalent of ui.html's combinedHits/renderFacets. Backends
//! still own filtering and within-source rank; raw engine scores never mix.
use std::collections::{BTreeMap, HashSet};

use serde_json::{json, Value};

const FACETS: [&str; 8] = [
    "sourceFacets",
    "kindFacets",
    "contentTypeFacets",
    "ownerFacets",
    "authorFacets",
    "tagFacets",
    "seriesFacets",
    "yearFacets",
];

pub(crate) fn combine(indexed: &Value, live: &Value, query: &str, newest: bool) -> Value {
    let empty = Vec::new();
    let library = indexed["hits"].as_array().unwrap_or(&empty);
    let connected = live["hits"].as_array().unwrap_or(&empty);
    let mut live_groups: BTreeMap<&str, Vec<&Value>> = BTreeMap::new();
    for hit in connected {
        live_groups
            .entry(hit["source"].as_str().unwrap_or_default())
            .or_default()
            .push(hit);
    }
    let mut live_groups: Vec<_> = live_groups.into_iter().collect();
    live_groups.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
    let groups = std::iter::once(library.iter().collect::<Vec<_>>())
        .chain(live_groups.into_iter().map(|(_, hits)| hits));
    // The browser strips one enclosing pair of quotes before title comparison.
    let query = if !query.contains(['\n', '\r', '\u{2028}', '\u{2029}']) {
        query
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .unwrap_or(query)
    } else {
        query
    };
    let query = trim(query).to_lowercase();
    let mut seen = HashSet::new();
    let mut ranked = Vec::new();
    for (group, hits) in groups.enumerate() {
        for (rank, hit) in hits.into_iter().enumerate() {
            let key = format!(
                "{}:{}",
                hit["source"].as_str().unwrap_or_default(),
                hit["id"].as_str().unwrap_or_default()
            );
            if !seen.insert(key) {
                continue;
            }
            let exact = !query.is_empty()
                && trim(hit["title"].as_str().unwrap_or_default()).to_lowercase() == query;
            let quality = hit["matchQuality"]
                .as_u64()
                .unwrap_or(if exact { 1 } else { 5 });
            let quality = if hit["semanticRank"].as_u64().is_some() {
                quality.min(2)
            } else {
                quality
            };
            ranked.push((hit, group, rank, quality));
        }
    }
    ranked.sort_by(|a, b| {
        let time = |hit: &Value| hit["created"].as_f64().unwrap_or(f64::NEG_INFINITY);
        let primary = if newest {
            time(b.0).total_cmp(&time(a.0))
        } else {
            a.3.cmp(&b.3)
        };
        primary.then(a.2.cmp(&b.2)).then(a.1.cmp(&b.1))
    });
    let hits: Vec<_> = ranked.into_iter().map(|(hit, ..)| hit.clone()).collect();
    let library_total = indexed["total"].as_u64().unwrap_or(0);
    let mut body = indexed.as_object().cloned().unwrap_or_default();
    body.insert("shown".into(), json!(hits.len()));
    body.insert("hits".into(), json!(hits));
    body.insert("libraryTotal".into(), json!(library_total));
    body.insert("liveTotal".into(), json!(connected.len()));
    body.insert(
        "total".into(),
        json!(library_total.saturating_add(connected.len() as u64)),
    );
    body.insert("hasMore".into(), json!(indexed["hasMore"] == true));
    body.insert("limited".into(), json!(live["limited"] == true));
    let warnings: Vec<_> = [indexed, live]
        .into_iter()
        .flat_map(|data| data["warnings"].as_array().into_iter().flatten().cloned())
        .collect();
    body.insert("warnings".into(), json!(warnings));
    let mut indexed_facets = serde_json::Map::new();
    let mut live_facets = serde_json::Map::new();
    for field in FACETS {
        let mut counts: BTreeMap<String, u64> = BTreeMap::new();
        for (data, facets) in [(indexed, &mut indexed_facets), (live, &mut live_facets)] {
            let entries = data[field].as_array().cloned().unwrap_or_default();
            for entry in &entries {
                let name = entry["name"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| entry["name"].to_string());
                let count = counts.entry(name).or_default();
                *count = count.saturating_add(entry["count"].as_u64().unwrap_or(0));
            }
            facets.insert(field.into(), json!(entries));
        }
        body.insert(
            field.into(),
            json!(counts
                .into_iter()
                .map(|(name, count)| json!({"name": name, "count": count}))
                .collect::<Vec<_>>()),
        );
    }
    body.insert("indexedFacets".into(), json!(indexed_facets));
    body.insert("liveFacets".into(), json!(live_facets));
    Value::Object(body)
}

/// ECMAScript String.trim(): unlike Rust trim(), includes BOM and excludes NEL.
pub(crate) fn trim(value: &str) -> &str {
    value.trim_matches(|ch: char| ch == '\u{feff}' || (ch.is_whitespace() && ch != '\u{85}'))
}
