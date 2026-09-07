pub mod browsertrix;
pub mod freshrss;
pub mod kiwix;
pub mod mail;
pub mod paperless;

use serde_json::Value;

use crate::config::{Settings, SourceConfig};

/// A single extracted document ready for persistence and indexing.
#[derive(Debug, Clone)]
pub struct ExtractedDocument {
    pub external_id: String,
    pub kind: String,
    pub title: String,
    pub body_text: String,
    pub content_type: String,
    pub origin_url: String,
    pub app_url: String,
    pub file_path: String,
    pub size_bytes: i64,
    pub content_created_at: Option<i64>,
    pub content_modified_at: Option<i64>,
    pub metadata: Value,
}

impl ExtractedDocument {
    pub fn checksum(&self) -> String {
        let metadata = self.metadata.to_string();
        let created = self
            .content_created_at
            .map(|value| value.to_string())
            .unwrap_or_default();
        let modified = self
            .content_modified_at
            .map(|value| value.to_string())
            .unwrap_or_default();
        crate::timeutil::sha256_hex(&[
            &self.kind,
            &self.title,
            &self.body_text,
            &self.content_type,
            &self.origin_url,
            &self.app_url,
            &self.file_path,
            &metadata,
            &created,
            &modified,
        ])
    }

    pub fn into_record(self) -> crate::db::DocumentRecord {
        let checksum = self.checksum();
        crate::db::DocumentRecord {
            external_id: self.external_id,
            kind: self.kind,
            title: self.title,
            body_text: self.body_text,
            content_type: self.content_type,
            origin_url: self.origin_url,
            app_url: self.app_url,
            file_path: self.file_path,
            size_bytes: self.size_bytes,
            checksum,
            content_created_at: self.content_created_at,
            content_modified_at: self.content_modified_at,
            metadata: self.metadata,
        }
    }
}

/// Push-based extraction so large sources never hold the whole index in memory.
pub trait Extractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String>;
}

pub fn run(
    source: &SourceConfig,
    settings: &Settings,
    emit: &mut dyn FnMut(ExtractedDocument),
) -> Result<(), String> {
    let extractor: Box<dyn Extractor> = match source.source_type.as_str() {
        "paperless" => Box::new(paperless::PaperlessExtractor {
            pdftotext: settings.pdftotext.clone(),
        }),
        "kiwix" => Box::new(kiwix::KiwixExtractor {
            zimdump: settings
                .zimdump
                .clone()
                .ok_or_else(|| "SEARCH_ZIMDUMP must be set for the kiwix source".to_string())?,
        }),
        "browsertrix" => Box::new(browsertrix::BrowsertrixExtractor),
        "mail-archive" => Box::new(mail::MailExtractor),
        "freshrss" => Box::new(freshrss::FreshRssExtractor),
        other => return Err(format!("no extractor for source type '{other}'")),
    };
    extractor.extract(source, emit)
}
