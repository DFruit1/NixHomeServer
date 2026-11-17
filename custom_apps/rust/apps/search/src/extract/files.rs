//! Indexes the documents and transcripts people keep in their own folders.
//! A personal folder holds far more than documents (source trees, photos,
//! application data), so only document formats are read, and the notes and
//! text files of a software project are left out: a thousand READMEs would
//! bury the letters and reports the folder is searched for.
use std::path::{Path, PathBuf};

use serde_json::json;

use super::sections::{emit_work, extract_format_units, sections, Unit};
use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::truncate_text;
use crate::timeutil::sha256_hex;

const MAX_DEPTH: usize = 16;
/// Bounds one user's walk and what it may add to the index.
const MAX_ENTRIES: usize = 400_000;
const MAX_FILES: usize = 50_000;
const MAX_PDF_BYTES: u64 = 64_000_000;
const MAX_FILE_BYTES: u64 = 16_000_000;

/// Folders that hold tooling output rather than someone's documents.
const SKIPPED_FOLDERS: [&str; 10] = [
    "node_modules",
    "target",
    "dist",
    "build",
    "vendor",
    "__pycache__",
    "venv",
    "site-packages",
    "bower_components",
    "Pods",
];
/// A folder containing one of these is a software project.
const PROJECT_MARKERS: [&str; 9] = [
    "package.json",
    "Cargo.toml",
    "pyproject.toml",
    "go.mod",
    "pom.xml",
    "Makefile",
    "CMakeLists.txt",
    "flake.nix",
    "composer.json",
];

pub struct FilesExtractor {
    pub pdftotext: Option<PathBuf>,
}

#[derive(Clone, Copy, PartialEq)]
enum Folder {
    Documents,
    Transcripts,
}

struct Found {
    path: PathBuf,
    owner: String,
    /// Path below the owner's root, e.g. `_Files/Tax/2024/return.pdf`.
    relative: String,
    folder: Folder,
}

/// Formats read as documents; the second value marks plain notes, which are
/// skipped inside a software project.
fn document_format(extension: &str) -> Option<(&'static str, bool)> {
    Some(match extension {
        "pdf" => ("pdf", false),
        "docx" => ("docx", false),
        "docm" => ("docm", false),
        "odt" => ("odt", false),
        "ods" => ("ods", false),
        "odp" => ("odp", false),
        "xlsx" => ("xlsx", false),
        "xlsm" => ("xlsm", false),
        "pptx" => ("pptx", false),
        "pptm" => ("pptm", false),
        "ppsx" => ("ppsx", false),
        "epub" => ("epub", false),
        "fb2" => ("fb2", false),
        "txt" => ("txt", true),
        "md" => ("md", true),
        "html" => ("html", true),
        "htm" => ("htm", true),
        _ => return None,
    })
}

fn walk(
    dir: &Path,
    depth: usize,
    in_project: bool,
    folder: Folder,
    budget: &mut usize,
    out: &mut Vec<PathBuf>,
) {
    if depth > MAX_DEPTH || *budget == 0 || out.len() >= MAX_FILES {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.filter_map(|entry| entry.ok()).collect();
    entries.sort_by_key(|entry| entry.file_name());
    let in_project = in_project
        || entries.iter().any(|entry| {
            let name = entry.file_name();
            name == ".git"
                || PROJECT_MARKERS.iter().any(|marker| name == *marker)
                || entry.file_type().is_ok_and(|kind| kind.is_file())
                    && entry
                        .path()
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .is_some_and(|ext| {
                            matches!(
                                ext.to_ascii_lowercase().as_str(),
                                "rs" | "py"
                                    | "js"
                                    | "ts"
                                    | "tsx"
                                    | "jsx"
                                    | "c"
                                    | "cpp"
                                    | "h"
                                    | "ino"
                                    | "go"
                                    | "java"
                                    | "cs"
                            )
                        })
        });
    for entry in entries {
        if *budget == 0 || out.len() >= MAX_FILES {
            return;
        }
        *budget -= 1;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // Never follow links out of the folder being indexed.
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if name.starts_with('.') || kind.is_symlink() {
            continue;
        }
        let path = entry.path();
        if kind.is_dir() {
            if !SKIPPED_FOLDERS.contains(&name.as_ref()) {
                walk(&path, depth + 1, in_project, folder, budget, out);
            }
            continue;
        }
        let extension = path
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let wanted = match folder {
            // A proofread job keeps the recognised text as transcript.original.txt
            // beside the cleaned transcript; only the cleaned one is searched.
            Folder::Transcripts => {
                matches!(extension.as_str(), "txt" | "md" | "srt" | "vtt")
                    && !name.to_ascii_lowercase().contains(".original.")
            }
            Folder::Documents => {
                document_format(&extension).is_some_and(|(_, note)| !(note && in_project))
            }
        };
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let project_note = matches!(
            stem.as_str(),
            "readme"
                | "license"
                | "licence"
                | "copying"
                | "keywords"
                | "changelog"
                | "authors"
                | "contributing"
        );
        let tooling_note = folder == Folder::Documents
            && project_note
            && document_format(&extension).is_some_and(|(_, note)| note);
        if wanted && !tooling_note {
            out.push(path);
        }
    }
}

fn discover(source: &SourceConfig) -> Vec<Found> {
    let Some(users_root) = source.setting_str("usersRoot") else {
        return Vec::new();
    };
    let mut owners: Vec<PathBuf> = std::fs::read_dir(users_root)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    owners.sort();
    let mut found = Vec::new();
    for root in owners {
        let Some(owner) = root
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|owner| homelab_common::is_safe_single_component(owner))
            .map(str::to_string)
        else {
            continue;
        };
        let mut budget = MAX_ENTRIES;
        for (setting, folder) in [
            ("documentDirs", Folder::Documents),
            ("transcriptDirs", Folder::Transcripts),
        ] {
            for name in source.setting_str_list(setting) {
                if !homelab_common::is_safe_single_component(&name) {
                    continue;
                }
                let mut paths = Vec::new();
                walk(&root.join(&name), 0, false, folder, &mut budget, &mut paths);
                for path in paths {
                    let Ok(relative) = path.strip_prefix(&root) else {
                        continue;
                    };
                    found.push(Found {
                        relative: relative.to_string_lossy().into_owned(),
                        path,
                        owner: owner.clone(),
                        folder,
                    });
                }
            }
        }
    }
    found
}

/// Every candidate file (path, size, mtime) plus the settings: an unchanged
/// inventory means no document was added, edited or removed.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let files: Vec<PathBuf> = discover(source).into_iter().map(|file| file.path).collect();
    if files.is_empty() {
        return None;
    }
    super::file_inventory_fingerprint(source, files)
}

/// Spoken words from a subtitle-style transcript, without cue numbers and
/// timing lines.
fn spoken(raw: &str) -> String {
    raw.lines()
        .map(str::trim)
        .filter(|line| {
            !line.contains("-->")
                && *line != "WEBVTT"
                && !(!line.is_empty() && line.chars().all(|c| c.is_ascii_digit()))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

impl super::Extractor for FilesExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let app_base = source.app_base.trim_end_matches('/').to_string();
        for file in discover(source) {
            let Ok(details) = std::fs::metadata(&file.path) else {
                continue;
            };
            let extension = file
                .path
                .extension()
                .and_then(|extension| extension.to_str())
                .unwrap_or_default()
                .to_ascii_lowercase();
            let limit = if extension == "pdf" {
                MAX_PDF_BYTES
            } else {
                MAX_FILE_BYTES
            };
            if details.len() > limit {
                continue;
            }
            let stem = file
                .path
                .file_stem()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let (kind, title, units, content_type) = match file.folder {
                Folder::Transcripts => {
                    let Ok(bytes) = std::fs::read(&file.path) else {
                        continue;
                    };
                    let raw = crate::text::decode_document_text(&bytes);
                    let text = if matches!(extension.as_str(), "srt" | "vtt") {
                        spoken(&raw)
                    } else {
                        raw
                    };
                    // A job writes "transcript.txt" into a folder named for
                    // the recording.
                    let title = file
                        .path
                        .parent()
                        .and_then(Path::file_name)
                        .map(|name| name.to_string_lossy().into_owned())
                        .filter(|_| stem.eq_ignore_ascii_case("transcript"))
                        .unwrap_or(stem);
                    let unit = Unit {
                        text,
                        ..Unit::default()
                    };
                    ("transcript", title, vec![unit], "text/plain".to_string())
                }
                Folder::Documents => {
                    let Some((format, _)) = document_format(&extension) else {
                        continue;
                    };
                    // One unreadable file must not fail a whole folder.
                    let units =
                        match extract_format_units(&file.path, format, self.pdftotext.as_deref()) {
                            Ok(units) => units,
                            Err(err) => {
                                eprintln!("search: skipping unreadable document: {err}");
                                continue;
                            }
                        };
                    (
                        "document",
                        stem,
                        units,
                        super::document::content_type_for_format(format),
                    )
                }
            };
            let found = sections(units);
            // A file with no readable text is still findable by its name.
            let modified = details
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs() as i64);
            let mut metadata = json!({ "owner": file.owner });
            if file.folder == Folder::Transcripts {
                if let Some(base) = source.setting_str("mediaManagerBase") {
                    let query = form_urlencoded::Serializer::new(String::new())
                        .append_pair("view", "transcript")
                        .append_pair("path", &file.relative)
                        .finish();
                    metadata["transcript_url"] =
                        json!(format!("{}?{query}", base.trim_end_matches('/')));
                }
            }
            let work = ExtractedDocument {
                incidental_text: String::new(),
                external_id: sha256_hex(&[&file.owner, &file.relative]),
                kind: kind.to_string(),
                title: truncate_text(&title, 2_000),
                body_text: String::new(),
                content_type,
                origin_url: String::new(),
                app_url: app_base.clone(),
                // Relative to the owner's folder: its folder names are worth
                // searching, the server's layout is not.
                file_path: file.relative,
                size_bytes: details.len() as i64,
                content_created_at: modified,
                content_modified_at: modified,
                metadata,
            };
            emit_work(work, found, emit);
        }
        Ok(())
    }
}
