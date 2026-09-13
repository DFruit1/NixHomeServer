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
            "title": self.title,
            "snippet": self.snippet,
            "originUrl": self.origin_url,
            "appUrl": self.app_url,
            "contentType": self.content_type,
            "owner": self.owner,
            "score": self.score,
            "created": self.created,
            "metadata": self.metadata,
        })
    }

    /// Applies the admin-selected filters to a federated hit. Hits without a
    /// timestamp are excluded by any date filter, and hits without a per-user
    /// owner are excluded by any owner filter. This mirrors how the ZIM
    /// federator has always behaved and keeps federated results consistent with
    /// the Solr facet filtering they sit beside.
    pub fn matches_filters(&self, filters: &SearchFilters) -> bool {
        if let Some(source) = &filters.source {
            if source != &self.source {
                return false;
            }
        }
        if let Some(content_type) = &filters.content_type {
            if content_type != &self.content_type {
                return false;
            }
        }
        if let Some(owner) = &filters.owner {
            if owner != &self.owner {
                return false;
            }
        }
        // Author/tag/series/year filters are applied against the same
        // normalisation the indexed path uses, so a federated hit without the
        // requested value is excluded rather than silently included.
        let derived = crate::facets::extract(&self.metadata, self.created);
        if let Some(author) = &filters.author {
            if !derived.authors.iter().any(|value| value == author) {
                return false;
            }
        }
        if let Some(tag) = &filters.tag {
            if !derived.tags.iter().any(|value| value == tag) {
                return false;
            }
        }
        if let Some(series) = &filters.series {
            if !derived.series.iter().any(|value| value == series) {
                return false;
            }
        }
        if let Some(year) = filters.year {
            if derived.year != Some(year) {
                return false;
            }
        }
        if filters.created_after.is_some() || filters.created_before.is_some() {
            let Some(created) = self.created else {
                return false;
            };
            let date: String = timeutil::epoch_to_solr_date(created)
                .chars()
                .take(10)
                .collect();
            if let Some(after) = &filters.created_after {
                if date.as_str() < after.as_str() {
                    return false;
                }
            }
            if let Some(before) = &filters.created_before {
                if date.as_str() > before.as_str() {
                    return false;
                }
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit() -> FederatedHit {
        FederatedHit {
            source: "paperless".to_string(),
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
