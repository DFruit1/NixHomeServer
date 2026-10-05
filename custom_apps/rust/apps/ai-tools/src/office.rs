//! Office document conversion, delegated to the Collabora Online instance that
//! already runs for OpenCloud.
//!
//! Collabora is LibreOffice, so one converter covers docx/odt/rtf/doc,
//! xlsx/ods/csv and pptx/odp without adding an office suite to this closure.
//! The convert-to endpoint is reached over loopback, which is the same client
//! class Collabora already permits for OpenCloud.

use base64::Engine as _;
use serde_json::{json, Value};
use std::{path::Path, path::PathBuf, time::Duration};
use tokio::io::AsyncReadExt;

/// Longest converted document returned to the model, in bytes. Collabora will
/// happily convert a 100 MiB spreadsheet; the model cannot use the result and
/// it would blow the tool payload.
pub const MAX_OUTPUT_BYTES: usize = 256 * 1024;

/// Largest document loaded into memory for conversion, in bytes. The shared
/// root is writable by the user and the unit has a hard MemoryMax, so an
/// oversized file is refused before its bytes are read.
pub const MAX_INPUT_BYTES: u64 = 32 * 1024 * 1024;

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
    FORMATS.iter().find(|format| format.extension == extension)
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
                let name = part
                    .to_str()
                    .ok_or_else(|| "path is not valid UTF-8".to_string())?;
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

/// Open a validated document once and check its size on the open handle.
///
/// The caller reads from the returned handle, so the file that was size-checked
/// is the file that gets uploaded even though the shared root is writable
/// between the caller's containment check and this read.
pub async fn open_document(path: &Path, limit: u64) -> Result<tokio::fs::File, String> {
    let file = tokio::fs::File::open(path)
        .await
        .map_err(|error| format!("document is not readable: {error}"))?;
    let declared = file
        .metadata()
        .await
        .map_err(|error| format!("document is not readable: {error}"))?
        .len();
    if declared > limit {
        return Err(format!(
            "document is too large: {declared} bytes exceeds the {limit} byte limit"
        ));
    }
    Ok(file)
}

/// Read a whole document, refusing anything over `limit`.
pub async fn read_document(path: &Path, limit: u64) -> Result<Vec<u8>, String> {
    let mut file = open_document(path, limit).await?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .await
        .map_err(|error| format!("document is not readable: {error}"))?;
    // A writable path can grow between the size check and the read, so the
    // bytes that actually arrived are bounded too.
    if bytes.len() as u64 > limit {
        return Err(format!(
            "document grew past the {limit} byte limit while it was read"
        ));
    }
    Ok(bytes)
}

/// Filename for the Collabora upload part.
///
/// The name comes from a user-writable directory and is interpolated into a
/// multipart header, so anything outside a conservative character set becomes
/// an underscore instead of being escaped.
fn upload_name(path: &Path) -> String {
    let raw = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("document");
    let sanitized: String = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect();
    if sanitized.is_empty() || sanitized.chars().all(|character| character == '.') {
        return "document".to_string();
    }
    sanitized
}

/// Clamp converted output to `MAX_OUTPUT_BYTES` without splitting a character.
fn clamp_output(text: &str) -> (String, bool) {
    if text.len() <= MAX_OUTPUT_BYTES {
        return (text.to_string(), false);
    }
    let mut boundary = MAX_OUTPUT_BYTES;
    while !text.is_char_boundary(boundary) {
        boundary -= 1;
    }
    (text[..boundary].to_string(), true)
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
        self.convert_to(path, format.target).await
    }

    /// Convert a document to an arbitrary Collabora target.
    ///
    /// `convert_to` is also the ODF half of every office write: no native ODF
    /// writer exists in Rust or Python, so an `ods` or `odt` is produced by
    /// handing Collabora the native document and asking it to convert. Binary
    /// targets come back base64-encoded in `content`, because an xlsx or docx is
    /// a zip archive and cannot survive a trip through a UTF-8 string.
    pub async fn convert_to(&self, path: &Path, target: &str) -> Result<Value, String> {
        if !target
            .chars()
            .all(|character| character.is_ascii_alphanumeric())
            || target.is_empty()
        {
            return Err(format!("unsupported conversion target: {target:?}"));
        }
        let format = format_for(path).ok_or_else(|| {
            "unsupported document type; supported: docx, odt, rtf, doc, xlsx, ods, pptx, odp"
                .to_string()
        })?;

        let bytes = read_document(path, MAX_INPUT_BYTES).await?;
        let part = reqwest::multipart::Part::bytes(bytes)
            .file_name(upload_name(path))
            .mime_str(format.mime)
            .map_err(|error| format!("could not build request part: {error}"))?;

        let form = reqwest::multipart::Form::new().part("file", part);
        let url = format!("{}/cool/convert-to/{target}", self.base);

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

        let envelope = response
            .bytes()
            .await
            .map_err(|error| format!("Collabora response was not readable: {error}"))?;
        let raw = &envelope;
        let (body, truncated) = if is_binary_target(target) {
            if raw.len() as u64 > MAX_OUTPUT_BYTES as u64 * 4 {
                return Err(format!(
                    "converted document exceeds the {MAX_OUTPUT_BYTES} byte limit"
                ));
            }
            (base64::engine::general_purpose::STANDARD.encode(raw), false)
        } else {
            let text = String::from_utf8_lossy(raw)
                .trim_start_matches('\u{feff}')
                .to_string();
            clamp_output(&text)
        };

        Ok(json!({
            "path": path.display().to_string(),
            "source_format": format.extension,
            "converted_to": target,
            "bytes": raw.len(),
            "truncated": truncated,
            "content": body,
        }))
    }
}

/// Whether a convert-to target is a binary container rather than text.
///
/// xlsx and docx are zip archives. Handing them to the caller as a UTF-8 string
/// would corrupt them, so the binary targets are base64-encoded in the envelope
/// while `txt` and `csv` stay plain text for readability.
fn is_binary_target(target: &str) -> bool {
    matches!(target, "xlsx" | "docx" | "ods" | "odt" | "pptx" | "odp")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct ScratchDir(PathBuf);

    impl ScratchDir {
        fn new(label: &str) -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "ai-tools-{label}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("create scratch directory");
            Self(dir)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

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
        assert_eq!(
            format_for(Path::new("a/b/report.docx")).unwrap().target,
            "txt"
        );
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

    #[test]
    fn clamps_multi_byte_output_on_a_character_boundary() {
        let three_byte = "a".repeat(MAX_OUTPUT_BYTES - 1);
        let (body, truncated) = clamp_output(&format!("{three_byte}\u{20ac}{}", "b".repeat(8)));
        assert!(truncated);
        assert_eq!(body, three_byte);

        let four_byte = "a".repeat(MAX_OUTPUT_BYTES - 2);
        let (body, truncated) = clamp_output(&format!("{four_byte}\u{1f9ea}tail"));
        assert!(truncated);
        assert_eq!(body, four_byte);
    }

    #[test]
    fn leaves_output_at_or_below_the_limit_untouched() {
        let exact = "a".repeat(MAX_OUTPUT_BYTES);
        let (body, truncated) = clamp_output(&exact);
        assert!(!truncated);
        assert_eq!(body, exact);

        let (body, truncated) = clamp_output("h\u{e9}llo");
        assert!(!truncated);
        assert_eq!(body, "h\u{e9}llo");
    }

    #[tokio::test]
    async fn refuses_a_document_over_the_input_limit() {
        let dir = ScratchDir::new("oversize");
        let path = dir.join("big.docx");
        std::fs::File::create(&path)
            .expect("create sparse document")
            .set_len(MAX_INPUT_BYTES + 1)
            .expect("size sparse document");
        let error = read_document(&path, MAX_INPUT_BYTES).await.unwrap_err();
        assert!(error.contains("too large"), "{error}");
    }

    #[tokio::test]
    async fn reads_a_document_at_the_input_limit() {
        let dir = ScratchDir::new("atlimit");
        let path = dir.join("exact.docx");
        std::fs::write(&path, b"01234567").expect("write document");
        let bytes = read_document(&path, 8).await.expect("read document");
        assert_eq!(bytes, b"01234567");
        assert!(read_document(&path, 7).await.is_err());
    }

    #[tokio::test]
    async fn reads_the_opened_handle_rather_than_reopening_the_path() {
        let dir = ScratchDir::new("toctou");
        let path = dir.join("swapped.docx");
        std::fs::write(&path, b"original").expect("write document");
        let mut file = open_document(&path, 64).await.expect("open document");
        std::fs::remove_file(&path).expect("remove document");
        std::fs::write(&path, b"swapped").expect("replace document");

        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).await.expect("read handle");
        assert_eq!(bytes, b"original");
    }

    #[test]
    fn sanitizes_upload_filenames() {
        assert_eq!(
            upload_name(Path::new("/srv/shared/report.docx")),
            "report.docx"
        );
        assert_eq!(
            upload_name(Path::new("/srv/shared/my report (final).docx")),
            "my_report__final_.docx"
        );
        assert_eq!(
            upload_name(Path::new("/srv/shared/a\"b\r\nc;d.docx")),
            "a_b__c_d.docx"
        );
        assert_eq!(
            upload_name(Path::new("/srv/shared/na\u{ef}ve.docx")),
            "na_ve.docx"
        );
        assert_eq!(upload_name(Path::new("/srv/shared/..")), "document");
        assert_eq!(upload_name(Path::new("/")), "document");
    }
}
