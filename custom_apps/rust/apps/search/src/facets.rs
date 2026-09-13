use serde_json::Value;

/// Canonical, cross-source facets derived from each document's free-form
/// metadata bag.
///
/// Extractors each choose their own metadata keys (`authors` vs `author` vs
/// `from`, `tags` vs `genres`, `series` vs `feed`). Normalising them into a
/// small fixed vocabulary here is what lets every source participate in the
/// same Author / Tag / Series / Year facets without rewriting each extractor.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facets {
    pub authors: Vec<String>,
    pub tags: Vec<String>,
    pub series: Vec<String>,
    pub year: Option<i64>,
}

/// Metadata keys that identify a creator, sender, or contributor.
const AUTHOR_KEYS: [&str; 5] = ["authors", "author", "narrators", "from", "correspondent"];
/// Metadata keys that identify a category label.
const TAG_KEYS: [&str; 2] = ["tags", "genres"];
/// Metadata keys that identify a collection or series of works.
const SERIES_KEYS: [&str; 2] = ["series", "feed"];

/// Keeps a runaway metadata list (e.g. a long mail thread's recipients) from
/// bloating a Solr document's facet fields.
const MAX_VALUES_PER_FIELD: usize = 32;
/// Long values (mail headers, full author strings) are truncated, not dropped,
/// so the facet stays usable without indexing megabytes of header text.
const MAX_VALUE_CHARS: usize = 160;

/// Appends one metadata value, splitting arrays and accepting both plain
/// strings and `{ "name": … }` objects (the Audiobookshelf/Kavita shape).
fn collect_value(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::String(text) => push_trimmed(text, out),
        Value::Number(number) => push_trimmed(&number.to_string(), out),
        Value::Array(items) => {
            for item in items {
                collect_value(item, out);
            }
        }
        Value::Object(map) => {
            if let Some(name) = map.get("name") {
                collect_value(name, out);
            }
        }
        _ => {}
    }
}

fn push_trimmed(value: &str, out: &mut Vec<String>) {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return;
    }
    let bounded: String = trimmed.chars().take(MAX_VALUE_CHARS).collect();
    if !out.iter().any(|existing| existing == &bounded) {
        out.push(bounded);
    }
}

fn collect_keys(metadata: &Value, keys: &[&str]) -> Vec<String> {
    let mut values = Vec::new();
    for key in keys {
        if let Some(value) = metadata.get(*key) {
            collect_value(value, &mut values);
        }
        if values.len() >= MAX_VALUES_PER_FIELD {
            break;
        }
    }
    values.truncate(MAX_VALUES_PER_FIELD);
    values
}

fn metadata_year(metadata: &Value) -> Option<i64> {
    match metadata.get("year") {
        Some(Value::Number(number)) => number.as_i64(),
        Some(Value::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Derives the canonical facets for one document. `year` falls back to the
/// document timestamp only if the metadata carries no explicit publication
/// year, so media keeps its release year while other sources still contribute
/// a usable year facet.
pub fn extract(metadata: &Value, content_created_at: Option<i64>) -> Facets {
    let year = metadata_year(metadata).or_else(|| {
        content_created_at
            .and_then(|epoch| chrono::DateTime::from_timestamp(epoch, 0))
            .map(|datetime| datetime.format("%Y").to_string())
            .and_then(|year| year.parse().ok())
    });
    Facets {
        authors: collect_keys(metadata, &AUTHOR_KEYS),
        tags: collect_keys(metadata, &TAG_KEYS),
        series: collect_keys(metadata, &SERIES_KEYS),
        year,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalises_creator_keys_across_sources() {
        let media = json!({
            "authors": ["Brandon Sanderson"],
            "narrators": [{"name": "Michael Kramer"}],
            "owner": "shared",
        });
        let facets = extract(&media, None);
        assert_eq!(facets.authors, ["Brandon Sanderson", "Michael Kramer"]);

        let mail = json!({ "from": "Alice <alice@example.org>", "owner": "dsaw" });
        assert_eq!(
            extract(&mail, None).authors,
            ["Alice <alice@example.org>".to_string()]
        );

        let calibre =
            json!({ "authors": ["Ursula K. Le Guin"], "series": "Earthsea", "tags": ["fantasy"] });
        let facets = extract(&calibre, None);
        assert_eq!(facets.authors, ["Ursula K. Le Guin"]);
        assert_eq!(facets.series, ["Earthsea"]);
        assert_eq!(facets.tags, ["fantasy"]);
    }

    #[test]
    fn accepts_string_and_array_metadata() {
        let single = json!({ "author": "Ada Lovelace", "tags": "computing" });
        let facets = extract(&single, None);
        assert_eq!(facets.authors, ["Ada Lovelace"]);
        assert_eq!(facets.tags, ["computing"]);
    }

    #[test]
    fn deduplicates_and_bounds_values() {
        let long = "x".repeat(500);
        let metadata = json!({ "authors": ["Ada", "Ada", long], "tags": ["a", "a"] });
        let facets = extract(&metadata, None);
        assert_eq!(facets.authors.len(), 2);
        assert_eq!(facets.authors[0], "Ada");
        assert_eq!(facets.authors[1].chars().count(), MAX_VALUE_CHARS);
        assert_eq!(facets.tags, ["a"]);
    }

    #[test]
    fn year_prefers_metadata_then_timestamp() {
        assert_eq!(extract(&json!({ "year": 2011 }), None).year, Some(2011));
        assert_eq!(extract(&json!({ "year": "2006" }), None).year, Some(2006));
        // 2024-02-01T00:00:00Z
        assert_eq!(extract(&json!({}), Some(1_706_745_600)).year, Some(2024));
        assert_eq!(extract(&json!({}), None).year, None);
        // Explicit metadata year wins over the document timestamp.
        assert_eq!(
            extract(&json!({ "year": 1999 }), Some(1_706_745_600)).year,
            Some(1999)
        );
    }

    #[test]
    fn missing_metadata_yields_empty_facets() {
        assert_eq!(extract(&json!({}), None), Facets::default());
        assert_eq!(
            extract(&json!({ "owner": "shared" }), None),
            Facets::default()
        );
    }
}
