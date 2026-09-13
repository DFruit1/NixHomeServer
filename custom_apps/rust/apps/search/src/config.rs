use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;

use homelab_common::env_required;

const KNOWN_SOURCE_TYPES: [&str; 8] = [
    "paperless",
    "paperless-api",
    "kiwix",
    "browsertrix",
    "mail-archive",
    "freshrss",
    "calibre",
    "media-snapshot",
];

/// Source types that are queried live at search time instead of being copied
/// into the index. They are still registered so the UI lists them and the
/// reconciler keeps them, but the indexer extracts no documents from them.
pub fn is_federated(source_type: &str) -> bool {
    matches!(source_type, "paperless-api")
}

#[derive(Debug, Clone)]
pub struct SourceConfig {
    pub id: String,
    pub display_name: String,
    pub source_type: String,
    pub app_base: String,
    pub settings: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone)]
pub struct Settings {
    pub database_url: String,
    pub solr_url: String,
    pub solr_core: String,
    pub sources: Vec<SourceConfig>,
    pub zimdump: Option<PathBuf>,
    pub kiwix_search: Option<PathBuf>,
    pub pdftotext: Option<PathBuf>,
    /// File holding the Paperless REST API token used by runtime-federated
    /// Paperless sources. Read lazily so a missing token degrades to
    /// "no Paperless results" rather than failing startup.
    pub paperless_token_file: Option<PathBuf>,
}

impl Settings {
    pub fn from_env() -> Result<Self, String> {
        let database_url = env_string("SEARCH_DATABASE_URL")?;
        let solr_url = env_string("SEARCH_SOLR_URL")?;
        let solr_core = env_string("SEARCH_SOLR_CORE")?;
        let zimdump = std::env::var("SEARCH_ZIMDUMP").ok().map(PathBuf::from);
        let kiwix_search = std::env::var("SEARCH_KIWIXSEARCH").ok().map(PathBuf::from);
        let pdftotext = std::env::var("SEARCH_PDFTOTEXT").ok().map(PathBuf::from);
        let paperless_token_file = std::env::var("SEARCH_PAPERLESS_TOKEN_FILE")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from);

        let mut sources = Vec::new();
        if let Some(path) = std::env::var("SEARCH_SOURCES_FILE").ok().map(PathBuf::from) {
            sources = load_sources_file(&path)?;
        } else if std::env::var("SEARCH_SOURCES_JSON").is_ok() {
            let raw = env_string("SEARCH_SOURCES_JSON")?;
            sources = parse_sources(&raw)?;
        }

        Ok(Self {
            database_url,
            solr_url,
            solr_core,
            sources,
            zimdump,
            kiwix_search,
            pdftotext,
            paperless_token_file,
        })
    }
}

impl SourceConfig {
    pub fn setting_str(&self, key: &str) -> Option<&str> {
        self.settings.get(key).and_then(|value| value.as_str())
    }

    pub fn setting_str_list(&self, key: &str) -> Vec<String> {
        match self.settings.get(key) {
            Some(serde_json::Value::Array(items)) => items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect(),
            Some(serde_json::Value::String(single)) => vec![single.clone()],
            _ => Vec::new(),
        }
    }

    pub fn require_setting(&self, key: &str) -> Result<String, String> {
        self.setting_str(key)
            .map(str::to_string)
            .ok_or_else(|| format!("source '{}' is missing required setting '{key}'", self.id))
    }
}

#[derive(Debug, Deserialize)]
struct RawSource {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
    source_type: String,
    #[serde(default)]
    app_base: String,
    #[serde(default)]
    settings: BTreeMap<String, serde_json::Value>,
}

pub fn load_sources_file(path: &PathBuf) -> Result<Vec<SourceConfig>, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read sources file {}: {err}", path.display()))?;
    parse_sources(&raw)
}

pub fn parse_sources(raw: &str) -> Result<Vec<SourceConfig>, String> {
    let raw_sources: Vec<RawSource> =
        serde_json::from_str(raw).map_err(|err| format!("invalid sources definition: {err}"))?;
    let mut seen = std::collections::HashSet::new();
    let mut sources = Vec::new();
    for raw_source in raw_sources {
        if !seen.insert(raw_source.id.clone()) {
            return Err(format!("duplicate source id '{}'", raw_source.id));
        }
        if raw_source.id.is_empty() {
            return Err("source id must not be empty".to_string());
        }
        if !KNOWN_SOURCE_TYPES.contains(&raw_source.source_type.as_str()) {
            return Err(format!(
                "source '{}' has unknown source_type '{}'",
                raw_source.id, raw_source.source_type
            ));
        }
        if raw_source.app_base.is_empty() {
            return Err(format!(
                "source '{}' is missing required field 'app_base'",
                raw_source.id
            ));
        }
        let display_name = raw_source
            .display_name
            .unwrap_or_else(|| raw_source.id.clone());
        let source_type = raw_source.source_type;
        let app_base = raw_source.app_base;
        let settings = raw_source.settings;
        sources.push(SourceConfig {
            id: raw_source.id,
            display_name,
            source_type,
            app_base,
            settings,
        });
    }
    Ok(sources)
}

fn env_string(name: &str) -> Result<String, String> {
    env_required(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_source() {
        let raw = r#"[{
            "id": "paperless",
            "source_type": "paperless",
            "app_base": "https://paperless.example.org",
            "settings": { "exportPath": "/mnt/data/paperless/export" }
        }]"#;
        let sources = parse_sources(raw).expect("sources parse");
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].display_name, "paperless");
        assert_eq!(
            sources[0].require_setting("exportPath").unwrap(),
            "/mnt/data/paperless/export"
        );
        assert!(sources[0].setting_str("missing").is_none());
        assert!(sources[0].setting_str_list("missing").is_empty());
    }

    #[test]
    fn parses_named_source_and_lists() {
        let raw = r#"[{
            "id": "kiwix",
            "display_name": "Wiki",
            "source_type": "kiwix",
            "app_base": "https://wiki.example.org",
            "settings": {
                "libraryRoot": "/mnt/data/kiwix",
                "fulltextZims": ["wikipedia_en"]
            }
        }]"#;
        let sources = parse_sources(raw).expect("sources parse");
        assert_eq!(sources[0].display_name, "Wiki");
        assert_eq!(
            sources[0].setting_str_list("fulltextZims"),
            ["wikipedia_en"]
        );
    }

    #[test]
    fn rejects_unknown_type_and_duplicate_ids() {
        assert!(
            parse_sources(r#"[{"id":"x","source_type":"nope","app_base":"https://a"}]"#).is_err()
        );
        assert!(parse_sources(
            r#"[{"id":"x","source_type":"kiwix","app_base":"https://a"},{"id":"x","source_type":"kiwix","app_base":"https://b"}]"#
        )
        .is_err());
        assert!(
            parse_sources(r#"[{"id":"","source_type":"kiwix","app_base":"https://a"}]"#).is_err()
        );
    }
}
