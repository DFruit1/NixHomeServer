//! Bounded extraction for ebook and office formats, shared with mail attachments.
use std::io::{Read, Seek};

use zip::ZipArchive;

use crate::text::{decode_document_text, html_to_text, truncate_text};

pub(crate) const TEXT_LIMIT: usize = 2_000_000;
pub(crate) const XML_LIMIT: u64 = 8_000_000;

fn parse_xml(raw: &str) -> Option<roxmltree::Document<'_>> {
    if raw.len() as u64 > XML_LIMIT {
        return None;
    }
    roxmltree::Document::parse_with_options(
        raw,
        roxmltree::ParsingOptions {
            nodes_limit: 250_000,
            ..Default::default()
        },
    )
    .ok()
}

pub(crate) fn xml_text(raw: &str) -> Option<String> {
    let document = parse_xml(raw)?;
    let mut body = String::new();
    for node in document.descendants() {
        // FB2 and OpenDocument embed images as base64; those are not prose.
        if node.ancestors().any(|ancestor| {
            ancestor.is_element() && matches!(ancestor.tag_name().name(), "binary" | "binary-data")
        }) {
            continue;
        }
        if node.is_text() {
            let text = node.text().unwrap_or_default();
            body.push_str(&truncate_text(text, TEXT_LIMIT - body.len()));
        } else if node.is_element()
            && matches!(
                node.tag_name().name(),
                "p" | "h" | "title" | "subtitle" | "br" | "tab" | "table-row"
            )
        {
            body.push('\n');
        } else if node.is_element() && node.tag_name().name() == "table" {
            if let Some(name) = node
                .attributes()
                .find(|attribute| attribute.name() == "name")
            {
                body.push_str(&truncate_text(name.value(), TEXT_LIMIT - body.len()));
                if body.len() < TEXT_LIMIT {
                    body.push('\n');
                }
            }
        } else if node.is_element()
            && node.tag_name().name() == "table-cell"
            && !node.descendants().any(|child| {
                child.is_text() && child.text().is_some_and(|text| !text.trim().is_empty())
            })
        {
            // ODS cells may carry only a cached attribute value, without a
            // rendered <text:p>. Keep these useful values too.
            if let Some(value) = node.attributes().find(|attribute| {
                matches!(
                    attribute.name(),
                    "value" | "string-value" | "date-value" | "time-value" | "boolean-value"
                )
            }) {
                body.push_str(&truncate_text(value.value(), TEXT_LIMIT - body.len()));
                if body.len() < TEXT_LIMIT {
                    body.push('\n');
                }
            }
        }
        if body.len() >= TEXT_LIMIT {
            break;
        }
    }
    (!body.trim().is_empty()).then_some(body)
}

fn spreadsheet_text(raw: &str, shared: &[String], workbook: bool) -> Option<String> {
    let document = parse_xml(raw)?;
    let mut body = String::new();
    for node in document.descendants().filter(|node| node.is_element()) {
        let value = match node.tag_name().name() {
            "sheet" if workbook => node.attribute("name").unwrap_or_default().to_string(),
            "c" if !workbook => {
                let cached = node
                    .children()
                    .find(|child| child.is_element() && child.tag_name().name() == "v")
                    .and_then(|child| child.text())
                    .unwrap_or_default();
                match node.attribute("t") {
                    Some("s") => cached
                        .parse::<usize>()
                        .ok()
                        .and_then(|index| shared.get(index))
                        .cloned()
                        .unwrap_or_default(),
                    Some("inlineStr") => node
                        .descendants()
                        .filter(|child| child.is_element() && child.tag_name().name() == "t")
                        .filter_map(|child| child.text())
                        .collect(),
                    _ => cached.to_string(),
                }
            }
            _ => continue,
        };
        if !value.is_empty() {
            body.push_str(&truncate_text(&value, TEXT_LIMIT - body.len()));
            if body.len() >= TEXT_LIMIT {
                break;
            }
            body.push('\n');
        }
    }
    (!body.trim().is_empty()).then_some(body)
}

pub(crate) fn zip_text<R: Read + Seek>(reader: R, format: &str) -> Option<String> {
    let mut archive = ZipArchive::new(reader).ok()?;
    let spreadsheet = matches!(format, "xlsx" | "xlsm");
    let mut input_bytes = 0;
    let mut shared = Vec::new();
    // XLSX cells often hold numeric offsets into a shared-string table. Index
    // only strings actually referenced by cells, rather than orphaned strings
    // from deleted cells or the raw offsets themselves.
    if spreadsheet
        && let Ok(entry) = archive.by_name("xl/sharedStrings.xml")
        && entry.size() <= XML_LIMIT
    {
        input_bytes += entry.size();
        let mut bytes = Vec::new();
        if entry.take(XML_LIMIT + 1).read_to_end(&mut bytes).is_ok()
            && let raw = decode_document_text(&bytes)
            && let Some(document) = parse_xml(&raw)
        {
            for item in document
                .descendants()
                .filter(|node| node.is_element() && node.tag_name().name() == "si")
            {
                shared.push(
                    item.descendants()
                        .filter(|node| node.is_element() && node.tag_name().name() == "t")
                        .filter_map(|node| node.text())
                        .collect(),
                );
            }
        }
    }
    let mut names: Vec<String> = archive
        .file_names()
        .filter(|name| {
            let lower = name.to_ascii_lowercase();
            match format {
                "epub" | "htmlz" => [".xhtml", ".html", ".htm"]
                    .iter()
                    .any(|ext| lower.ends_with(ext)),
                "txtz" => lower.ends_with(".txt"),
                "docx" | "docm" => {
                    lower == "word/document.xml"
                        || lower == "word/footnotes.xml"
                        || lower == "word/endnotes.xml"
                        || (lower.starts_with("word/header") && lower.ends_with(".xml"))
                        || (lower.starts_with("word/footer") && lower.ends_with(".xml"))
                }
                "odt" | "ods" | "odp" => lower == "content.xml",
                "pptx" | "pptm" | "ppsx" => {
                    (lower.starts_with("ppt/slides/slide")
                        || lower.starts_with("ppt/notesslides/notesslide"))
                        && lower.ends_with(".xml")
                }
                "xlsx" | "xlsm" => {
                    lower == "xl/workbook.xml"
                        || (lower.starts_with("xl/worksheets/sheet") && lower.ends_with(".xml"))
                }
                _ => false,
            }
        })
        .map(str::to_string)
        .collect();
    // Keep primary document content ahead of notes and running headers.
    names.sort_by_key(|name| {
        (
            name != "word/document.xml"
                && name != "xl/workbook.xml"
                && !name.starts_with("ppt/slides/"),
            name.clone(),
        )
    });
    let mut body = String::new();
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
        if !matches!(format, "epub" | "htmlz" | "txtz") && entry.size() > XML_LIMIT {
            continue;
        }
        input_bytes += read_limit;
        let mut bytes = Vec::new();
        if entry.take(read_limit).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let raw = decode_document_text(&bytes);
        let text = match format {
            "xlsx" | "xlsm" => match spreadsheet_text(&raw, &shared, name == "xl/workbook.xml") {
                Some(text) => text,
                None => continue,
            },
            "docx" | "docm" | "odt" | "ods" | "odp" | "pptx" | "pptm" | "ppsx" => {
                match xml_text(&raw) {
                    Some(text) => text,
                    None => continue,
                }
            }
            "txtz" => raw,
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
