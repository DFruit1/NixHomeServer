//! Confined native xlsx/docx reads and writes.
//!
//! Three properties drive the design here, and each one is why a piece is where
//! it is:
//!
//! * **Reads span the shared root, writes do not.** The owner's decision is one
//!   top-level shared content subdirectory for writes. [`resolve_read`] and
//!   [`resolve_write`] are deliberately separate rather than one function with a
//!   flag: a single `root` parameter that a call site can pass the wrong value
//!   to is exactly the mistake this card is guarding against.
//! * **Paths are validated in Rust, before anything is opened.** The systemd
//!   unit's `ReadWritePaths` is what makes the refusal real against a future
//!   tool that forgets; this module is what makes it correct now.
//! * **Collabora does the ODF and legacy halves.** Producing an `ods` or `odt`
//!   is a convert-to call on the instance that already runs for OpenCloud, and
//!   no native ODF writer exists in either language. The Python helper is
//!   reached only for native xlsx/docx edits, which is why [`format_for`] maps
//!   an ods request to a Collabora target rather than to the helper.
//!
//! The helper is invoked as a child process with the validated absolute path on
//! its command line for writes and the document on stdin for reads. Reads
//! deliberately do not hand it a path: nothing in the helper can then open
//! something the caller did not validate, and there is no path for a
//! prompt-injected call to redirect.

use base64::Engine as _;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::io::AsyncWriteExt;

/// Longest helper result returned to the model, in bytes. Same reasoning as
/// `office::MAX_OUTPUT_BYTES`: a workbook with a million rows is cheap to
/// produce and useless to the model.
pub const MAX_OUTPUT_BYTES: usize = 512 * 1024;

/// Largest document handed to the helper, in bytes. Bounds the child's peak
/// memory, which is why the input check happens before the process is spawned
/// rather than after it has already parsed the file.
pub const MAX_INPUT_BYTES: u64 = 32 * 1024 * 1024;

/// Longest single write the helper will accept, in bytes. A document this tool
/// writes is generated content, not an upload; anything larger is a mistake.
pub const MAX_WRITE_BYTES: usize = 64 * 1024 * 1024;

/// Wall-clock ceiling on one helper invocation. The helper is parsing one
/// document, so a slow run means a pathological document rather than useful
/// work, and the unit has `MemoryMax` to protect.
pub const HELPER_TIMEOUT: Duration = Duration::from_secs(60);

/// A write target, with the extension that decides the dialect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteFormat {
    /// Native SpreadsheetML, via the helper.
    Xlsx,
    /// OpenDocument spreadsheet, via a Collabora convert-to of the xlsx the
    /// helper produced.
    Ods,
    /// Native WordprocessingML, via the helper.
    Docx,
    /// OpenDocument text, via a Collabora convert-to of the docx.
    Odt,
}

impl WriteFormat {
    /// Extension a document of this dialect must carry.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Xlsx => "xlsx",
            Self::Ods => "ods",
            Self::Docx => "docx",
            Self::Odt => "odt",
        }
    }

    /// Extension the helper is asked for before any conversion happens.
    ///
    /// ODF output is produced by converting the native document Collabora is
    /// given, so the helper never writes `ods` or `odt` directly.
    pub fn helper_extension_public(self) -> &'static str {
        match self {
            Self::Xlsx | Self::Ods => "xlsx",
            Self::Docx | Self::Odt => "docx",
        }
    }

    /// Collabora convert-to target, when this dialect needs one.
    pub fn collabora_target(self) -> Option<&'static str> {
        match self {
            Self::Ods => Some("ods"),
            Self::Odt => Some("odt"),
            Self::Xlsx | Self::Docx => None,
        }
    }
}

/// Dialect for a caller-supplied extension, for a write.
pub fn write_format_for(extension: &str) -> Option<WriteFormat> {
    match extension {
        "xlsx" => Some(WriteFormat::Xlsx),
        "ods" => Some(WriteFormat::Ods),
        "docx" => Some(WriteFormat::Docx),
        "odt" => Some(WriteFormat::Odt),
        _ => None,
    }
}

/// Resolve a read path inside the shared root.
///
/// Reads are allowed over the whole shared root: the model may be asked to
/// analyse something the owner has already shared. Absolute paths, parent
/// traversal, NUL bytes and hidden entries are refused before the filesystem is
/// touched, then the canonical result is re-checked so a symlink cannot escape.
///
/// Existence is *not* required here. A read resolves a file that must already
/// exist, so `canonicalize` failing is a real error; this function is used for
/// both reads and write-source documents, and a write source must exist.
pub fn resolve_read(root: &Path, requested: &str) -> Result<PathBuf, String> {
    resolve_existing(root, requested)
}

/// Resolve a write path inside the workspace.
///
/// Two things are refused that a read would accept. A path naming an existing
/// file that is itself a symlink is refused outright rather than followed: the
/// write would land wherever the link points, and `canonicalize` on the parent
/// cannot detect that on its own. And the parent directory must already exist
/// and be a real directory, so a write can never create a path structure
/// outside the workspace.
pub fn resolve_write(workspace: &Path, requested: &str) -> Result<PathBuf, String> {
    let relative = relative_path(requested)?;

    let workspace = workspace
        .canonicalize()
        .map_err(|error| format!("workspace is unavailable: {error}"))?;

    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    let parent = if parent.as_os_str().is_empty() {
        workspace.clone()
    } else {
        workspace
            .join(parent)
            .canonicalize()
            .map_err(|error| format!("directory is not usable for a write: {error}"))?
    };
    if !parent.starts_with(&workspace) || !parent.is_dir() {
        return Err("write directory resolves outside the workspace".to_string());
    }

    let candidate = parent.join(relative.file_name().unwrap_or_default());
    // A symlink at the final component is the one case the parent check cannot
    // see, so it is refused here rather than resolved.
    if std::fs::symlink_metadata(&candidate)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("write target must not be a symlink".to_string());
    }
    if !candidate.starts_with(&workspace) {
        return Err("write path resolves outside the workspace".to_string());
    }
    Ok(candidate)
}

/// Shared lexical checks, kept separate from the containment half so both
/// [`resolve_read`] and [`resolve_write`] reject the same hostile strings.
fn relative_path(requested: &str) -> Result<PathBuf, String> {
    let trimmed = requested.trim();
    if trimmed.is_empty() {
        return Err("path must not be empty".to_string());
    }
    if trimmed.contains('\0') {
        return Err("path must not contain NUL bytes".to_string());
    }
    if trimmed.starts_with('/') {
        return Err("path must be relative to its root".to_string());
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
    Ok(relative)
}

/// Resolve a path that must name an existing, readable document.
fn resolve_existing(root: &Path, requested: &str) -> Result<PathBuf, String> {
    let relative = relative_path(requested)?;
    let canonical_root = root
        .canonicalize()
        .map_err(|error| format!("root is unavailable: {error}"))?;
    let canonical = canonical_root
        .join(&relative)
        .canonicalize()
        .map_err(|error| format!("document is not readable: {error}"))?;
    if !canonical.starts_with(&canonical_root) {
        return Err("path resolves outside its root".to_string());
    }
    Ok(canonical)
}

/// Clamp helper output without splitting a character.
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

/// What the helper is asked to do.
#[derive(Debug)]
enum Request<'a> {
    Read {
        format: &'static str,
        document: Vec<u8>,
    },
    Write {
        format: &'static str,
        path: &'a Path,
        spec: &'a Value,
    },
}

/// The pinned Python helper, invoked as a child of this process.
///
/// It holds no filesystem grant of its own: it runs as the same user in the
/// same sandbox, it is given only a path this module validated, and it never
/// opens a document itself.
#[derive(Clone)]
pub struct Helper {
    command: String,
}

impl Helper {
    pub fn new(command: &str) -> Result<Self, String> {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            return Err("AI_TOOLS_OFFICE_HELPER must name an executable".to_string());
        }
        Ok(Self {
            command: trimmed.to_string(),
        })
    }

    async fn call(&self, request: Request<'_>) -> Result<Value, String> {
        let payload = match &request {
            Request::Read { format, document } => json!({
                "op": "read",
                "format": format,
                // Base64 because the document is a zip archive and a JSON string
                // cannot carry raw bytes.
                "document": base64::engine::general_purpose::STANDARD.encode(document),
            }),
            Request::Write { format, path, spec } => json!({
                "op": "write",
                "format": format,
                "path": path.display().to_string(),
                "spec": *spec,
            }),
        };
        let encoded = serde_json::to_vec(&payload)
            .map_err(|error| format!("helper request could not be encoded: {error}"))?;
        drop(payload);

        // The request goes over stdin, never argv, so a multi-megabyte document
        // cannot exceed the exec argument limit and no path ever appears in a
        // process listing.
        let mut command = tokio::process::Command::new(&self.command);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Nothing is inherited: the helper has no configuration of its own,
            // and a PYTHONPATH from the parent must not reach it.
            .env_clear()
            .kill_on_drop(true);

        let mut child = command
            .spawn()
            .map_err(|error| format!("office helper could not start: {error}"))?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(&encoded)
                .await
                .map_err(|error| format!("office helper stopped reading its request: {error}"))?;
            let _ = stdin.shutdown().await;
        }
        drop(encoded);

        let output = tokio::time::timeout(HELPER_TIMEOUT, child.wait_with_output())
            .await
            .map_err(|_| "office helper timed out".to_string())?
            .map_err(|error| format!("office helper failed: {error}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // The helper's own failure is already a JSON object with a short
            // message; anything else is an unexpected failure and is reported
            // as it arrived rather than discarded.
            let reason = serde_json::from_str::<Value>(stderr.trim())
                .ok()
                .and_then(|value| {
                    value
                        .get("error")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .unwrap_or_else(|| stderr.trim().to_string());
            let reason = if reason.is_empty() {
                format!("office helper exited with {}", output.status)
            } else {
                reason
            };
            return Err(reason);
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let (body, truncated) = clamp_output(stdout.trim());
        let parsed: Value = serde_json::from_str(&body).map_err(|error| {
            format!(
                "office helper returned unreadable JSON: {error}; output began: {}",
                body.chars().take(120).collect::<String>()
            )
        })?;
        // A clamped response is no longer valid JSON, so the truncation flag is
        // the only honest thing to return; the helper's own `truncated` field
        // covers the case where the *document* was clamped inside the helper.
        if truncated {
            return Err(format!(
                "office helper produced more than {MAX_OUTPUT_BYTES} bytes of JSON"
            ));
        }
        Ok(parsed)
    }

    /// Read every sheet of a native workbook, or the structure of a native
    /// document.
    pub async fn read(&self, format: &'static str, document: Vec<u8>) -> Result<Value, String> {
        self.call(Request::Read { format, document }).await
    }

    /// Write a document of `format` at an already-validated absolute path.
    pub async fn write(
        &self,
        format: &'static str,
        path: &Path,
        spec: &Value,
    ) -> Result<Value, String> {
        self.call(Request::Write { format, path, spec }).await
    }
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
                "ai-tools-write-{label}-{}-{}",
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
    fn rejects_paths_that_try_to_escape_the_workspace() {
        let root = std::env::temp_dir();
        for hostile in [
            "/etc/passwd",
            "../outside.xlsx",
            "a/../../outside.xlsx",
            "./../outside.xlsx",
            "",
            "   ",
            ".hidden/doc.xlsx",
            "a\0b.xlsx",
        ] {
            assert!(
                resolve_write(&root, hostile).is_err(),
                "should have rejected {hostile:?}"
            );
        }
    }

    #[test]
    fn accepts_a_plain_workspace_relative_path() {
        let dir = ScratchDir::new("plain");
        let resolved = resolve_write(&dir.0, "report.xlsx").expect("resolve");
        assert_eq!(resolved, dir.join("report.xlsx"));
    }

    #[test]
    fn refuses_a_write_into_a_directory_outside_the_workspace() {
        let outside = ScratchDir::new("outside");
        let workspace = ScratchDir::new("workspace");
        std::fs::create_dir_all(outside.join("inner")).expect("create outer directory");
        // A symlinked directory inside the workspace that points out of it: the
        // lexical path is clean, so only canonicalization catches this.
        std::os::unix::fs::symlink(outside.join("inner"), workspace.join("escape"))
            .expect("create escaping symlink");
        let error = resolve_write(&workspace.0, "escape/report.xlsx").unwrap_err();
        assert!(error.contains("outside the workspace"), "{error}");
    }

    #[test]
    fn refuses_to_overwrite_a_symlinked_file() {
        let dir = ScratchDir::new("symfile");
        let target = dir.join("target.xlsx");
        std::fs::write(&target, b"real").expect("write target");
        std::os::unix::fs::symlink(&target, dir.join("link.xlsx")).expect("create symlink");

        let error = resolve_write(&dir.0, "link.xlsx").unwrap_err();
        assert!(error.contains("symlink"), "{error}");
    }

    #[test]
    fn refuses_a_write_whose_directory_does_not_exist() {
        let dir = ScratchDir::new("missingdir");
        let error = resolve_write(&dir.0, "absent/report.xlsx").unwrap_err();
        assert!(error.contains("not usable for a write"), "{error}");
        assert!(!dir.join("absent").exists());
    }

    #[test]
    fn a_write_may_overwrite_a_regular_file_it_created() {
        let dir = ScratchDir::new("overwrite");
        let path = dir.join("twice.xlsx");
        std::fs::write(&path, b"old").expect("write first");
        let resolved = resolve_write(&dir.0, "twice.xlsx").expect("resolve overwrite");
        assert_eq!(resolved, path);
    }

    #[test]
    fn reads_require_an_existing_document() {
        let dir = ScratchDir::new("reads");
        let error = resolve_read(&dir.0, "absent.xlsx").unwrap_err();
        assert!(error.contains("not readable"), "{error}");
        std::fs::write(dir.join("present.xlsx"), b"x").expect("write document");
        assert!(resolve_read(&dir.0, "present.xlsx").is_ok());
    }

    #[test]
    fn a_read_outside_the_shared_root_is_refused() {
        let dir = ScratchDir::new("readover");
        let outside = ScratchDir::new("readover-target");
        std::fs::write(outside.join("secret.xlsx"), b"x").expect("write target");
        std::os::unix::fs::symlink(outside.join("secret.xlsx"), dir.join("secret.xlsx"))
            .expect("create symlink");
        let error = resolve_read(&dir.0, "secret.xlsx").unwrap_err();
        assert!(error.contains("outside its root"), "{error}");
    }

    #[test]
    fn maps_write_extensions_to_dialects_and_helper_formats() {
        assert_eq!(write_format_for("xlsx"), Some(WriteFormat::Xlsx));
        assert_eq!(write_format_for("ods"), Some(WriteFormat::Ods));
        assert_eq!(write_format_for("docx"), Some(WriteFormat::Docx));
        assert_eq!(write_format_for("odt"), Some(WriteFormat::Odt));
        assert_eq!(write_format_for("XLSX"), None);
        assert_eq!(write_format_for("csv"), None);
        assert_eq!(write_format_for("pptx"), None);
    }

    #[test]
    fn odf_output_is_produced_by_collabora_not_by_the_helper() {
        // The helper must never be handed an ODF target: no ODF writer exists in
        // either language, and Collabora already converts for us.
        assert_eq!(WriteFormat::Xlsx.helper_extension_public(), "xlsx");
        assert_eq!(WriteFormat::Docx.helper_extension_public(), "docx");
        assert_eq!(WriteFormat::Ods.helper_extension_public(), "xlsx");
        assert_eq!(WriteFormat::Odt.helper_extension_public(), "docx");

        assert_eq!(WriteFormat::Xlsx.collabora_target(), None);
        assert_eq!(WriteFormat::Docx.collabora_target(), None);
        assert_eq!(WriteFormat::Ods.collabora_target(), Some("ods"));
        assert_eq!(WriteFormat::Odt.collabora_target(), Some("odt"));
        assert_eq!(WriteFormat::Ods.extension(), "ods");
        assert_eq!(WriteFormat::Odt.extension(), "odt");
    }

    #[test]
    fn clamps_helper_output_on_a_character_boundary() {
        let (body, truncated) = clamp_output(&"a".repeat(MAX_OUTPUT_BYTES + 10));
        assert!(truncated);
        assert_eq!(body.len(), MAX_OUTPUT_BYTES);

        let euro = format!("{}{}", "a".repeat(MAX_OUTPUT_BYTES - 1), "\u{20ac}");
        let (body, truncated) = clamp_output(&euro);
        assert!(truncated);
        assert!(body.ends_with('a'));
    }

    #[test]
    fn refuses_an_empty_helper_command() {
        assert!(Helper::new("  ").is_err());
        assert!(Helper::new("/nix/store/x/bin/helper").is_ok());
    }
}
