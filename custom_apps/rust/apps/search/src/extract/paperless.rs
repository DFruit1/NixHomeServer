use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::timeutil::parse_date;

/// Extracts documents from the paperless document exporter output.
///
/// The exporter writes a `manifest.json` next to the exported files. Each
/// document entry carries the OCR `content` text when paperless stored it; if
/// the manifest entry lacks text we fall back to `pdftotext` on the exported
/// PDF so the integration never needs paperless's database.
pub struct PaperlessExtractor {
    pub pdftotext: Option<PathBuf>,
}

struct Manifest {
    documents: Vec<Value>,
    tags: HashMap<i64, String>,
    correspondents: HashMap<i64, String>,
}

fn parse_manifest(raw: &str) -> Result<Manifest, String> {
    let parsed: Value = serde_json::from_str(raw)
        .map_err(|err| format!("invalid paperless manifest.json: {err}"))?;
    let entries = parsed
        .as_array()
        .ok_or_else(|| "paperless manifest.json must contain a JSON array".to_string())?;
    let mut manifest = Manifest {
        documents: Vec::new(),
        tags: HashMap::new(),
        correspondents: HashMap::new(),
    };
    for entry in entries {
        let model = entry
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match model {
            "documents.document" => {
                if entry.get("id").is_some() {
                    manifest.documents.push(entry.clone());
                }
            }
            // Some exporter versions emit a bare document array without model tags.
            "" => {
                if entry.get("id").is_some()
                    && (entry.get("content").is_some() || entry.get("title").is_some())
                {
                    manifest.documents.push(entry.clone());
                }
            }
            "documents.tag" => {
                if let (Some(id), Some(name)) = (
                    entry.get("id").and_then(Value::as_i64),
                    entry.get("name").and_then(Value::as_str),
                ) {
                    manifest.tags.insert(id, name.to_string());
                }
            }
            "documents.correspondent" => {
                if let (Some(id), Some(name)) = (
                    entry.get("id").and_then(Value::as_i64),
                    entry.get("name").and_then(Value::as_str),
                ) {
                    manifest.correspondents.insert(id, name.to_string());
                }
            }
            _ => {}
        }
    }
    Ok(manifest)
}

/// Returns candidate document files for a paperless document id, preferring
/// archive PDFs. The exporter names files with zero-padded document ids.
fn candidate_files(export_path: &Path, id: i64) -> Vec<PathBuf> {
    let padded = format!("{id:07}");
    let mut candidates = Vec::new();
    for suffix in ["pdf", "PDF"] {
        candidates.push(export_path.join(format!("{padded}.{suffix}")));
    }
    candidates
}

impl super::Extractor for PaperlessExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let export_path = source.require_setting("exportPath")?;
        let export_dir = PathBuf::from(&export_path);
        let manifest_path = export_dir.join("manifest.json");
        let raw = std::fs::read_to_string(&manifest_path)
            .map_err(|err| format!("failed to read {}: {err}", manifest_path.display()))?;
        let manifest = parse_manifest(&raw)?;
        let app_base = source.app_base.trim_end_matches('/').to_string();

        for document in &manifest.documents {
            let id = document
                .get("id")
                .and_then(Value::as_i64)
                .ok_or_else(|| "paperless document entry missing numeric id".to_string())?;
            let external_id = id.to_string();
            let title = document
                .get("title")
                .and_then(Value::as_str)
                .filter(|title| !title.trim().is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| format!("Paperless document {id}"));
            let created = document
                .get("created")
                .and_then(Value::as_str)
                .and_then(parse_date);
            let modified = document
                .get("modified")
                .and_then(Value::as_str)
                .and_then(parse_date);

            let mut body = document
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let mut size_bytes = 0i64;
            let mut file_path = String::new();
            let candidate = candidate_files(&export_dir, id)
                .into_iter()
                .find(|path| path.is_file());
            if let Some(path) = candidate {
                if let Ok(meta) = std::fs::metadata(&path) {
                    size_bytes = meta.len() as i64;
                }
                file_path = path.display().to_string();
                if body.trim().is_empty() {
                    body = extract_pdf_text(&path, self.pdftotext.as_deref())?;
                }
            }

            let mut metadata = serde_json::Map::new();
            // Paperless has no document owner. The correspondent is the closest
            // meaningful per-document identity, so it doubles as the "user"
            // facet value; documents without one are grouped as shared.
            let mut owner = "shared".to_string();
            if let Some(correspondent) = document.get("correspondent") {
                let name = match correspondent {
                    Value::Number(number) => number
                        .as_i64()
                        .and_then(|key| manifest.correspondents.get(&key).cloned())
                        .unwrap_or_else(|| number.to_string()),
                    Value::String(name) => name.clone(),
                    other => other.to_string(),
                };
                if !name.is_empty() {
                    metadata.insert("correspondent".to_string(), Value::String(name.clone()));
                    owner = name;
                }
            }
            metadata.insert("owner".to_string(), Value::String(owner));
            if let Some(Value::Array(tags)) = document.get("tags") {
                let names: Vec<String> = tags
                    .iter()
                    .filter_map(|tag| match tag {
                        Value::Number(number) => number
                            .as_i64()
                            .and_then(|key| manifest.tags.get(&key).cloned()),
                        Value::String(name) => Some(name.clone()),
                        _ => None,
                    })
                    .collect();
                if !names.is_empty() {
                    metadata.insert("tags".to_string(), Value::from(names));
                }
            }
            if let Some(added) = document.get("added").and_then(Value::as_str) {
                metadata.insert("added".to_string(), Value::String(added.to_string()));
            }

            emit(ExtractedDocument {
                external_id,
                kind: "document".to_string(),
                title,
                body_text: body,
                content_type: "application/pdf".to_string(),
                origin_url: String::new(),
                app_url: format!("{app_base}/documents/{id}"),
                file_path,
                size_bytes,
                content_created_at: created,
                content_modified_at: modified,
                metadata: Value::Object(metadata),
            });
        }
        Ok(())
    }
}

pub(crate) fn extract_pdf_text(path: &Path, pdftotext: Option<&Path>) -> Result<String, String> {
    let pdftotext = pdftotext
        .filter(|path| path.exists())
        .ok_or_else(|| "SEARCH_PDFTOTEXT must point to a pdftotext binary".to_string())?;
    let bytes =
        std::fs::read(path).map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let mut child = Command::new(pdftotext)
        .arg("-q")
        .arg("-")
        .arg("-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .map_err(|err| format!("failed to run pdftotext: {err}"))?;
    if let Some(stdin) = child.stdin.as_mut() {
        use std::io::Write;
        stdin
            .write_all(&bytes)
            .map_err(|err| format!("failed to feed pdftotext: {err}"))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|err| format!("failed to run pdftotext: {err}"))?;
    if !output.status.success() {
        return Ok(String::new());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MANIFEST: &str = r#"[
        {"model": "documents.correspondent", "id": 7, "name": "ACME"},
        {"model": "documents.tag", "id": 3, "name": "invoice"},
        {"model": "documents.document", "id": 42, "title": "Invoice 42",
         "content": "total due 100", "created": "2024-02-01T10:00:00Z",
         "modified": "2024-02-02T10:00:00Z", "correspondent": 7, "tags": [3, 9]},
        {"model": "documents.document", "id": 43, "title": "No text",
         "created": "2024-02-01T10:00:00Z", "modified": null, "correspondent": null}
    ]"#;

    #[test]
    fn parses_manifest_entries_and_name_maps() {
        let manifest = parse_manifest(MANIFEST).expect("manifest");
        assert_eq!(manifest.documents.len(), 2);
        assert_eq!(manifest.tags.get(&3).map(String::as_str), Some("invoice"));
        assert_eq!(
            manifest.correspondents.get(&7).map(String::as_str),
            Some("ACME")
        );
    }

    #[test]
    fn rejects_invalid_manifest() {
        assert!(parse_manifest("{\"a\": 1}").is_err());
        assert!(parse_manifest("not json").is_err());
    }

    #[test]
    fn candidate_files_prefer_archive_pdfs() {
        let dir = Path::new("/data/export");
        let files = candidate_files(dir, 42);
        assert_eq!(files[0], PathBuf::from("/data/export/0000042.pdf"));
    }
}
