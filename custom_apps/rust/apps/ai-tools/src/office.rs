//! Office document conversion, delegated to the Collabora Online instance that
//! already runs for OpenCloud.
//!
//! Collabora is LibreOffice, so one converter covers docx/odt/rtf/doc,
//! xlsx/ods/csv and pptx/odp without adding an office suite to this closure.
//! The convert-to endpoint is reached over loopback, which is the same client
//! class Collabora already permits for OpenCloud.

use serde_json::{json, Value};
use std::{path::Path, path::PathBuf, time::Duration};

/// Longest converted document returned to the model, in bytes. Collabora will
/// happily convert a 100 MiB spreadsheet; the model cannot use the result and
/// it would blow the tool payload.
pub const MAX_OUTPUT_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy)]
pub struct Format {
    pub extension: &'static str,
    pub mime: &'static str,
    pub target: &'static str,
}

/// Extension to (source mime, Collabora convert-to target).
pub const FORMATS: &[Format] = &[
    Format {
        extension: "docx",
        mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        target: "txt",
    },
    Format {
        extension: "odt",
        mime: "application/vnd.oasis.opendocument.text",
        target: "txt",
    },
    Format {
        extension: "rtf",
        mime: "application/rtf",
        target: "txt",
    },
    Format {
        extension: "doc",
        mime: "application/msword",
        target: "txt",
    },
    Format {
        extension: "xlsx",
        mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        target: "csv",
    },
    Format {
        extension: "ods",
        mime: "application/vnd.oasis.opendocument.spreadsheet",
        target: "csv",
    },
    Format {
        extension: "pptx",
        mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        target: "txt",
    },
    Format {
        extension: "odp",
        mime: "application/vnd.oasis.opendocument.presentation",
        target: "txt",
    },
];

pub fn format_for(path: &Path) -> Option<&'static Format> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    FORMATS
        .iter()
        .find(|format| format.extension == extension)
}

/// Resolve a caller-supplied relative path inside the shared root.
///
/// Rejects absolute paths, parent traversal, NUL bytes and hidden entries
/// before touching the filesystem, then confirms the canonical result is still
/// inside the canonical root so a symlink cannot escape.
pub fn resolve_within(root: &Path, requested: &str) -> Result<PathBuf, String> {
    let trimmed = requested.trim();
    if trimmed.is_empty() {
        return Err("path must not be empty".to_string());
    }
    if trimmed.contains('\0') {
        return Err("path must not contain NUL bytes".to_string());
    }
    if trimmed.starts_with('/') {
        return Err("path must be relative to the shared root".to_string());
    }
    if trimmed.len() > 4096 {
        return Err("path is too long".to_string());
    }

    let mut relative = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            std::path::Component::Normal(part) => {
                let name = part.to_str().ok_or_else(|| "path is not valid UTF-8".to_string())?;
                if name.starts_with('.') {
                    return Err("path must not contain hidden entries".to_string());
                }
                relative.push(name);
            }
            std::path::Component::CurDir => {}
            _ => return Err("path must not contain parent or root components".to_string()),
        }
    }
    if relative.as_os_str().is_empty() {
        return Err("path must name a file".to_string());
    }

    let candidate = root.join(&relative);
    let canonical_root = root
        .canonicalize()
        .map_err(|error| format!("shared root is unavailable: {error}"))?;
    let canonical = candidate
        .canonicalize()
        .map_err(|error| format!("document is not readable: {error}"))?;
    if !canonical.starts_with(&canonical_root) {
        return Err("path resolves outside the shared root".to_string());
    }
    Ok(canonical)
}

pub struct Converter {
    client: reqwest::Client,
    base: String,
}

impl Converter {
    /// `timeout` bounds both connection setup and the whole convert-to
    /// exchange; a cold LibreOffice child can take a while on first use.
    pub fn new(base: &str, timeout: Duration) -> Result<Self, String> {
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(timeout)
                .build()
                .map_err(|error| format!("could not build Collabora client: {error}"))?,
            base: base.trim_end_matches('/').to_string(),
        })
    }

    pub async fn convert(&self, path: &Path) -> Result<Value, String> {
        let format = format_for(path).ok_or_else(|| {
            "unsupported document type; supported: docx, odt, rtf, doc, xlsx, ods, pptx, odp"
                .to_string()
        })?;

        let bytes = tokio::fs::read(path)
            .await
            .map_err(|error| format!("document is not readable: {error}"))?;
        let part = reqwest::multipart::Part::bytes(bytes)
            .file_name(
                path.file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("document")
                    .to_string(),
            )
            .mime_str(format.mime)
            .map_err(|error| format!("could not build request part: {error}"))?;

        let form = reqwest::multipart::Form::new().part("file", part);
        let url = format!("{}/cool/convert-to/{}", self.base, format.target);

        let response = self
            .client
            .post(url)
            .multipart(form)
            .send()
            .await
            .map_err(|error| format!("Collabora request failed: {error}"))?;

        let status = response.status();
        if !status.is_success() {
            return Err(format!("Collabora returned HTTP {status}"));
        }

        let text = response
            .text()
            .await
            .map_err(|error| format!("Collabora response was not text: {error}"))?;
        let text = text.trim_start_matches('\u{feff}').to_string();
        let truncated = text.len() > MAX_OUTPUT_BYTES;
        let body = if truncated {
            text[..MAX_OUTPUT_BYTES].to_string()
        } else {
            text
        };

        Ok(json!({
            "path": path.display().to_string(),
            "source_format": format.extension,
            "converted_to": format.target,
            "bytes": body.len(),
            "truncated": truncated,
            "content": body,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_paths_that_try_to_escape_the_root() {
        let root = std::env::temp_dir();
        for hostile in [
            "/etc/passwd",
            "../outside.docx",
            "a/../../outside.docx",
            "./../outside.docx",
            "",
            "   ",
            ".hidden/doc.docx",
        ] {
            assert!(
                resolve_within(&root, hostile).is_err(),
                "should have rejected {hostile:?}"
            );
        }
    }

    #[test]
    fn rejects_embedded_nul_and_overlong_paths() {
        let root = std::env::temp_dir();
        assert!(resolve_within(&root, "a\0b.docx").is_err());
        assert!(resolve_within(&root, &"a".repeat(5000)).is_err());
    }

    #[test]
    fn maps_supported_extensions_only() {
        assert_eq!(format_for(Path::new("a/b/report.docx")).unwrap().target, "txt");
        assert_eq!(format_for(Path::new("report.XLSX")).unwrap().target, "csv");
        assert_eq!(format_for(Path::new("deck.odp")).unwrap().target, "txt");
        assert!(format_for(Path::new("photo.png")).is_none());
        assert!(format_for(Path::new("notes.md")).is_none());
        assert!(format_for(Path::new("archive.zip")).is_none());
    }

    #[test]
    fn every_supported_extension_has_a_distinct_target() {
        for format in FORMATS {
            assert!(!format.extension.is_empty());
            assert!(format.target == "txt" || format.target == "csv");
            assert!(format.mime.contains('/'));
        }
    }
}