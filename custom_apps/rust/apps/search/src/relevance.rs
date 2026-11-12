//! Comparable evidence tiers for all backends. Backend scores remain useful
//! within a source; their magnitudes never decide cross-source ordering.
use serde_json::Value;

fn normalise(value: &str) -> String {
    value
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn quality(title: &str, metadata: &Value, body: &str, query: &str) -> u8 {
    let phrase = query
        .trim()
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .filter(|value| !value.contains('"'));
    let raw = phrase.unwrap_or(query.trim());
    if raw.is_empty() || raw == "*:*" {
        return 5;
    }
    let terms = crate::text::discovery_words(raw);
    if let Some(ids) = metadata.get("identifiers") {
        let values: Vec<_> = match ids {
            Value::Object(map) => map.values().collect(),
            Value::Array(list) => list.iter().collect(),
            _ => vec![ids],
        };
        if values.iter().any(|v| {
            v.as_str()
                .is_some_and(|id| id.trim().eq_ignore_ascii_case(raw))
        }) {
            return 0;
        }
    }
    // Explicit operators retain their backend meaning; do not reinterpret OR,
    // field names or exclusions as evidence of a literal title/content match.
    if phrase.is_none()
        && (raw.contains([':', '*', '~', '^', '[', ']', '(', ')', '"'])
            || raw.split_whitespace().any(|word| {
                matches!(word, "AND" | "OR" | "NOT" | "TO") || word.starts_with(['-', '+'])
            }))
    {
        return 5;
    }
    let normalized = normalise(raw);
    if normalized.is_empty() {
        return 5;
    }
    let title = normalise(title);
    if title == normalized {
        return 1;
    }
    let words =
        terms.unwrap_or_else(|| normalized.split_whitespace().map(str::to_string).collect());
    let contains_all = |value: &str| {
        let value = format!(" {} ", normalise(value));
        words
            .iter()
            .all(|word| value.contains(&format!(" {} ", normalise(word))))
    };
    if contains_all(&title) {
        return 2;
    }
    let facets = crate::facets::extract(metadata, None);
    if facets
        .authors
        .iter()
        .chain(&facets.series)
        .any(|value| contains_all(value))
    {
        return 3;
    }
    // Keep per-result work bounded, including a very long mail/PDF body.
    let body = &body[..body.floor_char_boundary(body.len().min(400_000))];
    if contains_all(body) {
        return 4;
    }
    5
}

pub(crate) fn annotate(hit: &mut Value, query: &str) {
    if hit.get("matchQuality").is_some() {
        return;
    }
    let text = crate::text::html_to_text(hit["snippet"].as_str().unwrap_or_default());
    hit["matchQuality"] = Value::from(quality(
        hit["title"].as_str().unwrap_or_default(),
        &hit["metadata"],
        &text,
        query,
    ));
}
