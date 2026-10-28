//! Bounded extraction for ebook and office formats, shared with mail attachments.
use std::io::{Read, Seek};

use zip::ZipArchive;

use crate::text::{html_to_text, truncate_text};

pub(crate) const TEXT_LIMIT: usize = 2_000_000;
pub(crate) const XML_LIMIT: u64 = 8_000_000;

pub(crate) fn xml_text(raw: &str) -> Option<String> {
    if raw.len() as u64 > XML_LIMIT {
        return None;
    }
    let document = roxmltree::Document::parse_with_options(
        raw,
        roxmltree::ParsingOptions {
            nodes_limit: 250_000,
            ..Default::default()
        },
    )
    .ok()?;
    let mut body = String::new();
    for node in document.descendants() {
        // FB2 embeds cover images as base64 in <binary>; those are not prose.
        if node
            .ancestors()
            .any(|ancestor| ancestor.is_element() && ancestor.tag_name().name() == "binary")
        {
            continue;
        }
        if node.is_text() {
            let text = node.text().unwrap_or_default();
            body.push_str(&truncate_text(text, TEXT_LIMIT - body.len()));
        } else if node.is_element()
            && matches!(
                node.tag_name().name(),
                "p" | "h" | "title" | "subtitle" | "br" | "tab"
            )
        {
            body.push('\n');
        }
        if body.len() >= TEXT_LIMIT {
            break;
        }
    }
    (!body.trim().is_empty()).then_some(body)
}

pub(crate) fn zip_text<R: Read + Seek>(reader: R, format: &str) -> Option<String> {
    let mut archive = ZipArchive::new(reader).ok()?;
    let mut names: Vec<String> = archive
        .file_names()
        .filter(|name| {
            let lower = name.to_ascii_lowercase();
            match format {
                "epub" | "htmlz" => [".xhtml", ".html", ".htm"]
                    .iter()
                    .any(|ext| lower.ends_with(ext)),
                "txtz" => lower.ends_with(".txt"),
                "docx" => {
                    lower == "word/document.xml"
                        || lower == "word/footnotes.xml"
                        || lower == "word/endnotes.xml"
                        || (lower.starts_with("word/header") && lower.ends_with(".xml"))
                        || (lower.starts_with("word/footer") && lower.ends_with(".xml"))
                }
                "odt" => lower == "content.xml",
                _ => false,
            }
        })
        .map(str::to_string)
        .collect();
    // Keep the main Word document ahead of its notes and running headers.
    names.sort_by_key(|name| (name != "word/document.xml", name.clone()));
    let mut body = String::new();
    let mut input_bytes = 0;
    for name in names {
        let entry = archive.by_name(&name).ok()?;
        // Bound expanded ZIP data as well as the resulting text. Never unpack
        // archive paths onto disk, and retain a bounded prefix of large books.
        let read_limit = entry.size().min(XML_LIMIT);
        if input_bytes + read_limit > XML_LIMIT * 4 {
            continue;
        }
        // XML needs its closing tags, while EPUB/HTML/plain text can still
        // contribute a useful prefix when a chapter exceeds the input bound.
        if matches!(format, "docx" | "odt") && entry.size() > XML_LIMIT {
            continue;
        }
        input_bytes += read_limit;
        let mut bytes = Vec::new();
        if entry.take(read_limit).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let raw = String::from_utf8_lossy(&bytes);
        let text = match format {
            "docx" | "odt" => match xml_text(&raw) {
                Some(text) => text,
                None => continue,
            },
            "txtz" => raw.into_owned(),
            _ => html_to_text(&raw),
        };
        if !text.trim().is_empty() {
            body.push_str(&truncate_text(&text, TEXT_LIMIT - body.len()));
            if body.len() >= TEXT_LIMIT {
                break;
            }
            body.push('\n');
        }
    }
    (!body.trim().is_empty()).then_some(body)
}
