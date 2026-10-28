//! Read book files referenced by Kavita's metadata snapshot, within its roots.
use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value};

use super::{document, ExtractedDocument};
use crate::config::SourceConfig;
use crate::text::{html_to_text, truncate_text};
use crate::timeutil::{parse_date, sha256_hex};

fn supported(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "epub"
            | "pdf"
            | "cbz"
            | "fb2"
            | "txt"
            | "md"
            | "html"
            | "htm"
            | "htmlz"
            | "txtz"
            | "docx"
            | "docm"
            | "odt"
            | "ods"
            | "odp"
            | "xlsx"
            | "xlsm"
            | "pptx"
            | "pptm"
            | "ppsx"
    )
}

fn walk(path: &Path, depth: usize, files: &mut Vec<PathBuf>) -> Result<(), String> {
    if depth > 16 {
        return Err("book directory exceeds the scan depth limit".to_string());
    }
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|err| format!("cannot inspect book path {}: {err}", path.display()))?;
    if metadata.file_type().is_symlink() {
        return Ok(());
    }
    if metadata.is_file() {
        if supported(path) {
            files.push(path.to_path_buf());
        }
    } else if metadata.is_dir() {
        let entries = std::fs::read_dir(path)
            .map_err(|err| format!("cannot read book directory {}: {err}", path.display()))?;
        for entry in entries {
            let entry = entry.map_err(|err| format!("cannot list book directory: {err}"))?;
            walk(&entry.path(), depth + 1, files)?;
        }
    }
    Ok(())
}

pub(crate) struct BookFiles<'a> {
    source: &'a SourceConfig,
    pdftotext: Option<&'a Path>,
    seen: HashSet<PathBuf>,
}

impl<'a> BookFiles<'a> {
    pub(crate) fn new(source: &'a SourceConfig, pdftotext: Option<&'a Path>) -> Self {
        Self {
            source,
            pdftotext,
            seen: HashSet::new(),
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        self.source.setting_str("sharedBooksRoot").is_some()
            || self.source.setting_str("usersRoot").is_some()
    }

    pub(crate) fn paths(&self, entry: &Value) -> Result<Vec<PathBuf>, String> {
        if !self.enabled() {
            return Ok(Vec::new());
        }
        let relative = entry
            .get("relativePath")
            .and_then(Value::as_str)
            .filter(|path| !path.is_empty())
            .ok_or("book snapshot entry has no relative path")?;
        if Path::new(relative)
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err("book snapshot path must stay within its configured root".to_string());
        }
        let root = match entry.get("rootId").and_then(Value::as_str) {
            Some("shared-books") => PathBuf::from(self.source.require_setting("sharedBooksRoot")?),
            Some("personal-books") => {
                let owner = entry
                    .get("ownerUsername")
                    .and_then(Value::as_str)
                    .filter(|owner| homelab_common::is_safe_single_component(owner))
                    .ok_or("personal book snapshot has no valid owner")?;
                let users = PathBuf::from(self.source.require_setting("usersRoot")?);
                let owner_root = users.join(owner);
                if std::fs::symlink_metadata(&owner_root)
                    .map_err(|err| err.to_string())?
                    .file_type()
                    .is_symlink()
                {
                    return Err("personal book owner directory must not be a symlink".to_string());
                }
                owner_root.join("_Books")
            }
            _ => return Err("book snapshot has an unknown root".to_string()),
        };
        if !root.is_absolute()
            || std::fs::symlink_metadata(&root)
                .map_err(|err| format!("book root unavailable: {err}"))?
                .file_type()
                .is_symlink()
        {
            return Err("book root must be an absolute directory, not a symlink".to_string());
        }
        let root = root
            .canonicalize()
            .map_err(|err| format!("book root unavailable: {err}"))?;
        let requested = root.join(relative);
        let folder = requested
            .canonicalize()
            .map_err(|err| format!("book snapshot path unavailable: {err}"))?;
        if !folder.starts_with(&root) {
            return Err("book snapshot path resolves outside its configured root".to_string());
        }
        let mut files = Vec::new();
        walk(&requested, 0, &mut files)?;
        files.sort();
        Ok(files)
    }

    pub(crate) fn extract(
        &mut self,
        entry: &Value,
        series_title: &str,
        series_metadata: &Map<String, Value>,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let paths = self.paths(entry)?;
        let multiple = paths.len() > 1;
        for path in paths {
            if !self.seen.insert(path.clone()) {
                continue;
            }
            let file = std::fs::File::open(&path)
                .map_err(|err| format!("cannot open book {}: {err}", path.display()))?;
            let file_metadata = file.metadata().map_err(|err| err.to_string())?;
            let format = path
                .extension()
                .and_then(|extension| extension.to_str())
                .unwrap_or_default()
                .to_ascii_lowercase();
            let mut embedded = document::embedded_book_metadata(&path, &format);
            let title = embedded
                .remove("title")
                .and_then(|title| title.as_str().map(str::to_string))
                .unwrap_or_else(|| {
                    let name = path
                        .file_stem()
                        .and_then(|name| name.to_str())
                        .unwrap_or(series_title);
                    if multiple {
                        format!("{series_title} — {name}")
                    } else {
                        series_title.to_string()
                    }
                });
            let mut metadata = series_metadata.clone();
            for (key, value) in embedded {
                if let (Some(Value::Array(existing)), Value::Array(additional)) =
                    (metadata.get_mut(&key), &value)
                {
                    for item in additional {
                        if !existing.contains(item) {
                            existing.push(item.clone());
                        }
                    }
                } else {
                    metadata.insert(key, value);
                }
            }
            let text = if format == "pdf" {
                super::paperless::extract_pdf_text(&path, self.pdftotext)?
            } else {
                document::extract_format_text(&path, &format, self.pdftotext).unwrap_or_default()
            };
            let body = match metadata.get("description").and_then(Value::as_str) {
                Some(description) => format!("{}\n{text}", html_to_text(description)),
                None => text,
            };
            emit(ExtractedDocument {
                external_id: format!("file:{}", sha256_hex(&[path.to_string_lossy().as_ref()])),
                kind: "book".to_string(),
                title: truncate_text(&title, 2_000),
                body_text: truncate_text(&body, document::TEXT_LIMIT),
                content_type: document::content_type_for_format(&format),
                origin_url: String::new(),
                app_url: self.source.app_base.trim_end_matches('/').to_string(),
                file_path: path.display().to_string(),
                size_bytes: file_metadata.len() as i64,
                content_created_at: metadata
                    .get("year")
                    .and_then(Value::as_str)
                    .and_then(|year| parse_date(&format!("{year}-01-01"))),
                content_modified_at: file_metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|duration| duration.as_secs() as i64),
                metadata: Value::Object(metadata),
            });
        }
        Ok(())
    }
}
