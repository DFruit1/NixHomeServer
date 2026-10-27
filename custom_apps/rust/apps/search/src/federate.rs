use serde_json::{json, Value};

use crate::indexer::SHARED_OWNER;
use crate::solr::SearchFilters;
use crate::timeutil;
use crate::zim_search::ZimHit;

/// A search result produced by querying a source's own index at request time,
/// as opposed to a document stored in Solr. Both paths are projected into the
/// same JSON shape so the UI never needs to know which backend answered.
#[derive(Debug, Clone)]
pub struct FederatedHit {
    pub source: String,
    pub kind: String,
    pub remote_id: String,
    pub title: String,
    pub snippet: Option<String>,
    pub origin_url: String,
    pub app_url: String,
    pub content_type: String,
    pub owner: String,
    pub score: f64,
    pub created: Option<i64>,
    pub metadata: Value,
}

impl FederatedHit {
    pub fn id(&self) -> String {
        format!("{}:{}", self.source, self.remote_id)
    }

    /// Converts a Kiwix native-index hit. ZIM articles carry no per-user owner
    /// or timestamp, so they are grouped under the shared sentinel.
    pub fn from_zim(source_id: &str, hit: ZimHit) -> Self {
        Self {
            source: source_id.to_string(),
            kind: "zim-article".to_string(),
            remote_id: timeutil::sha256_hex(&[&hit.origin_url]),
            title: hit.title,
            snippet: hit.snippet,
            origin_url: hit.origin_url,
            app_url: hit.app_url,
            content_type: "text/html".to_string(),
            owner: SHARED_OWNER.to_string(),
            score: 0.0,
            created: None,
            metadata: hit.metadata,
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id(),
            "source": self.source,
            "kind": self.kind,
            "title": self.title,
            "snippet": self.snippet,
            "originUrl": self.origin_url,
            "appUrl": self.app_url,
            "contentType": self.content_type,
            "owner": self.owner,
            "score": self.score,
            "created": self.created,
            "metadata": presented_metadata(&self.metadata),
        })
    }

    /// Applies the admin-selected filters to a federated hit. Hits without a
    /// timestamp are excluded by any date filter, and hits without a per-user
    /// owner are excluded by any owner filter. This mirrors how the ZIM
    /// federator has always behaved and keeps federated results consistent with
    /// the Solr facet filtering they sit beside.
    pub fn matches_filters(&self, filters: &SearchFilters) -> bool {
        if let Some(kind) = &filters.kind
            && kind != &self.kind
        {
            return false;
        }
        if let Some(source) = &filters.source
            && source != &self.source
        {
            return false;
        }
        if let Some(content_type) = &filters.content_type
            && content_type != &self.content_type
        {
            return false;
        }
        if let Some(owner) = &filters.owner
            && owner != &self.owner
        {
            return false;
        }
        // Author/tag/series/year filters are applied against the same
        // normalisation the indexed path uses, so a federated hit without the
        // requested value is excluded rather than silently included.
        let derived = crate::facets::extract(&self.metadata, self.created);
        if let Some(author) = &filters.author
            && !derived.authors.iter().any(|value| value == author)
        {
            return false;
        }
        if let Some(tag) = &filters.tag
            && !derived.tags.iter().any(|value| value == tag)
        {
            return false;
        }
        if let Some(series) = &filters.series
            && !derived.series.iter().any(|value| value == series)
        {
            return false;
        }
        if let Some(year) = filters.year
            && derived.year != Some(year)
        {
            return false;
        }
        if filters.created_after.is_some() || filters.created_before.is_some() {
            let Some(created) = self.created else {
                return false;
            };
            let date: String = timeutil::epoch_to_solr_date(created)
                .chars()
                .take(10)
                .collect();
            if let Some(after) = &filters.created_after
                && date.as_str() < after.as_str()
            {
                return false;
            }
            if let Some(before) = &filters.created_before
                && date.as_str() > before.as_str()
            {
                return false;
            }
        }
        true
    }
}

/// Drill-sideways counts over the fetched live sample. Each dimension ignores
/// its own filter while retaining the others, just like the indexed facets.
/// Counts are explicitly a sample, never an estimate of upstream totals.
pub fn facet_counts(hits: &[FederatedHit], filters: &SearchFilters) -> Value {
    let mut result = serde_json::Map::new();
    for dimension in [
        "kind",
        "contentType",
        "owner",
        "author",
        "tag",
        "series",
        "year",
    ] {
        let mut relaxed = filters.clone();
        match dimension {
            "kind" => relaxed.kind = None,
            "contentType" => relaxed.content_type = None,
            "owner" => relaxed.owner = None,
            "author" => relaxed.author = None,
            "tag" => relaxed.tag = None,
            "series" => relaxed.series = None,
            _ => relaxed.year = None,
        }
        let mut counts = std::collections::BTreeMap::<String, u64>::new();
        for hit in hits.iter().filter(|hit| hit.matches_filters(&relaxed)) {
            let facets = crate::facets::extract(&hit.metadata, hit.created);
            let values = match dimension {
                "kind" => vec![hit.kind.clone()],
                "contentType" => vec![hit.content_type.clone()],
                "owner" => vec![hit.owner.clone()],
                "author" => facets.authors,
                "tag" => facets.tags,
                "series" => facets.series,
                _ => facets
                    .year
                    .map(|year| year.to_string())
                    .into_iter()
                    .collect(),
            };
            for value in values.into_iter().filter(|value| !value.is_empty()) {
                *counts.entry(value).or_default() += 1;
            }
        }
        let mut counts: Vec<_> = counts.into_iter().collect();
        counts.sort_by(|(a, ac), (b, bc)| bc.cmp(ac).then(a.cmp(b)));
        result.insert(
            format!("{dimension}Facets"),
            json!(counts
                .into_iter()
                .take(50)
                .map(|(name, count)| json!({"name":name,"count":count}))
                .collect::<Vec<_>>()),
        );
    }
    Value::Object(result)
}

/// Projects hit metadata into the shape the API presents. Paperless resolves
/// tags into a structured list so the shared facet filter can match each tag
/// exactly; the outward contract still presents tags as the historical
/// ", "-joined string, mirroring the indexed path's metadata projection. Only
/// the top-level `tags` array is projected, and only when it is composed
/// entirely of strings: legacy string tags, unrelated arrays, malformed tag
/// arrays and non-object metadata all pass through unchanged.
fn presented_metadata(metadata: &Value) -> Value {
    let Some(entries) = metadata.as_object() else {
        return metadata.clone();
    };
    let Some(Value::Array(items)) = entries.get("tags") else {
        return metadata.clone();
    };
    let mut names = Vec::with_capacity(items.len());
    for item in items {
        match item.as_str() {
            Some(name) => names.push(name),
            None => return metadata.clone(),
        }
    }
    let mut projected = entries.clone();
    projected.insert("tags".to_string(), Value::String(names.join(", ")));
    Value::Object(projected)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit() -> FederatedHit {
        FederatedHit {
            source: "paperless".to_string(),
            kind: "document".to_string(),
            remote_id: "42".to_string(),
            title: "Invoice".to_string(),
            snippet: None,
            origin_url: String::new(),
            app_url: "https://paperless.example.org/documents/42".to_string(),
            content_type: "application/pdf".to_string(),
            owner: "ACME".to_string(),
            score: 0.5,
            created: Some(1_706_745_600),
            metadata: json!({ "correspondent": "ACME" }),
        }
    }

    #[test]
    fn live_facets_keep_literal_values_and_ignore_only_their_own_filter() {
        let mut first = hit();
        first.metadata = json!({"author":"Ada", "tags":["science, fiction", "science, fiction"]});
        let mut second = hit();
        second.metadata = json!({"author":"Ada", "tags":["other"]});
        let mut third = hit();
        third.metadata = json!({"author":"Bob", "tags":["excluded"]});
        let filters = SearchFilters {
            author: Some("Ada".into()),
            tag: Some("science, fiction".into()),
            ..Default::default()
        };
        let result = facet_counts(&[first, second, third], &filters);
        assert_eq!(
            result["tagFacets"],
            json!([{"name":"other","count":1},{"name":"science, fiction","count":1}])
        );
        assert_eq!(result["authorFacets"], json!([{"name":"Ada","count":1}]));
    }

    #[test]
    fn builds_ids_and_json() {
        let hit = hit();
        assert_eq!(hit.id(), "paperless:42");
        let json = hit.to_json();
        assert_eq!(json["source"], json!("paperless"));
        assert_eq!(json["created"], json!(1_706_745_600));
        assert_eq!(json["metadata"]["correspondent"], json!("ACME"));
    }

    #[test]
    fn filters_by_source_type_owner_and_date() {
        let hit = hit();
        assert!(hit.matches_filters(&SearchFilters::default()));

        let source = SearchFilters {
            source: Some("paperless".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&source));
        let other = SearchFilters {
            source: Some("mail-archive".to_string()),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&other));

        let content_type = SearchFilters {
            content_type: Some("application/pdf".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&content_type));

        let owner = SearchFilters {
            owner: Some("ACME".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&owner));
        let other_owner = SearchFilters {
            owner: Some("dsaw".to_string()),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&other_owner));

        let in_range = SearchFilters {
            created_after: Some("2024-01-01".to_string()),
            created_before: Some("2024-12-31".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&in_range));
        let after_range = SearchFilters {
            created_after: Some("2025-01-01".to_string()),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&after_range));
    }

    #[test]
    fn undated_hits_are_excluded_by_date_filters() {
        let mut hit = hit();
        hit.created = None;
        let dated = SearchFilters {
            created_after: Some("2024-01-01".to_string()),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&dated));
    }

    #[test]
    fn kind_filter_excludes_unrelated_live_results() {
        let hit = hit();
        assert!(hit.matches_filters(&SearchFilters {
            kind: Some("document".into()),
            ..Default::default()
        }));
        assert!(!hit.matches_filters(&SearchFilters {
            kind: Some("email".into()),
            ..Default::default()
        }));
    }

    #[test]
    fn filters_by_normalised_facets() {
        let mut hit = hit();
        hit.metadata = json!({
            "correspondent": "ACME",
            "tags": ["invoice"],
            "series": "Fees"
        });

        // The Paperless correspondent doubles as the author facet.
        let author = SearchFilters {
            author: Some("ACME".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&author));
        let other_author = SearchFilters {
            author: Some("Bob".to_string()),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&other_author));

        let tag = SearchFilters {
            tag: Some("invoice".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&tag));
        let series = SearchFilters {
            series: Some("Fees".to_string()),
            ..Default::default()
        };
        assert!(hit.matches_filters(&series));

        // Year is derived from the created timestamp when metadata omits it.
        let year = SearchFilters {
            year: Some(2024),
            ..Default::default()
        };
        assert!(hit.matches_filters(&year));
        let other_year = SearchFilters {
            year: Some(1999),
            ..Default::default()
        };
        assert!(!hit.matches_filters(&other_year));

        // A tag filter excludes a hit whose metadata carries no tags.
        let mut untagged = hit.clone();
        untagged.metadata = json!({ "correspondent": "ACME" });
        assert!(!untagged.matches_filters(&tag));
    }

    #[test]
    fn serialises_tag_arrays_as_the_historical_joined_string() {
        let mut hit = hit();
        hit.metadata = json!({ "correspondent": "ACME", "tags": ["invoice", "2024"] });

        let presentation = hit.to_json();
        assert_eq!(presentation["metadata"]["tags"], json!("invoice, 2024"));
        // Projection is presentation-only: the hit keeps its structured tags.
        assert_eq!(hit.metadata["tags"], json!(["invoice", "2024"]));
        assert_eq!(hit.to_json(), presentation);

        // Filtering observes the original list both before and after serialising.
        assert!(hit.matches_filters(&SearchFilters {
            tag: Some("invoice".to_string()),
            ..Default::default()
        }));
        assert!(hit.matches_filters(&SearchFilters {
            tag: Some("2024".to_string()),
            ..Default::default()
        }));
        assert!(!hit.matches_filters(&SearchFilters {
            tag: Some("invoice, 2024".to_string()),
            ..Default::default()
        }));
    }

    #[test]
    fn serialisation_leaves_legacy_and_unrelated_metadata_untouched() {
        let mut hit = hit();
        let metadata = json!({
            "correspondent": "ACME",
            "tags": "invoice",
            "cc": ["bob@example.org", "carol@example.org"],
            "page_count": 4,
            "nested": { "tags": ["a", "b"] }
        });
        hit.metadata = metadata.clone();

        let presentation = hit.to_json();
        // A legacy string tag is already the presentation form.
        assert_eq!(presentation["metadata"]["tags"], json!("invoice"));
        // Unrelated arrays, scalars and nested objects are not coerced.
        assert_eq!(
            presentation["metadata"]["cc"],
            json!(["bob@example.org", "carol@example.org"])
        );
        assert_eq!(presentation["metadata"]["page_count"], json!(4));
        assert_eq!(
            presentation["metadata"]["nested"]["tags"],
            json!(["a", "b"])
        );
        assert_eq!(hit.metadata, metadata);
    }

    #[test]
    fn malformed_tag_arrays_are_not_coerced_or_dropped() {
        let mut hit = hit();
        hit.metadata = json!({ "tags": ["invoice", 3] });
        assert_eq!(hit.to_json()["metadata"]["tags"], json!(["invoice", 3]));
        assert_eq!(hit.metadata["tags"], json!(["invoice", 3]));
    }

    #[test]
    fn non_object_metadata_passes_through() {
        let mut hit = hit();
        hit.metadata = json!("raw");
        assert_eq!(hit.to_json()["metadata"], json!("raw"));
    }

    #[test]
    fn empty_tag_array_presents_as_empty_string() {
        let mut hit = hit();
        hit.metadata = json!({ "tags": [] });
        assert_eq!(hit.to_json()["metadata"]["tags"], json!(""));
        assert_eq!(hit.metadata["tags"], json!([]));
    }

    #[test]
    fn converts_zim_hits() {
        let zim = ZimHit {
            title: "Heat wave".to_string(),
            snippet: Some("hot".to_string()),
            origin_url: "https://wiki.example.org/content/w/A/Heat_wave.html".to_string(),
            app_url: "https://wiki.example.org".to_string(),
            metadata: json!({ "archive": "w" }),
        };
        let hit = FederatedHit::from_zim("kiwix", zim);
        assert_eq!(hit.source, "kiwix");
        assert_eq!(hit.content_type, "text/html");
        assert_eq!(hit.owner, SHARED_OWNER);
        assert!(hit.created.is_none());
        assert!(hit.id().starts_with("kiwix:"));
    }
}
