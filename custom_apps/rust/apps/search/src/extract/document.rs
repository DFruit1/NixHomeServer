//! Bounded extraction for ebook and office formats, shared with mail attachments.
use std::io::{Read, Seek};
use std::path::Path;

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
                "cbz" => lower.rsplit('/').next() == Some("comicinfo.xml"),
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
            "docx" | "docm" | "odt" | "ods" | "odp" | "pptx" | "pptm" | "ppsx" | "cbz" => {
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

pub(crate) fn content_type_for_format(format: &str) -> String {
    match format.to_ascii_lowercase().as_str() {
        "epub" => "application/epub+zip".to_string(),
        "cbz" => "application/vnd.comicbook+zip".to_string(),
        "pdf" => "application/pdf".to_string(),
        "txt" => "text/plain".to_string(),
        "html" | "htm" => "text/html".to_string(),
        "docx" => {
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document".to_string()
        }
        "odt" => "application/vnd.oasis.opendocument.text".to_string(),
        "ods" => "application/vnd.oasis.opendocument.spreadsheet".to_string(),
        "odp" => "application/vnd.oasis.opendocument.presentation".to_string(),
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".to_string(),
        "pptx" => {
            "application/vnd.openxmlformats-officedocument.presentationml.presentation".to_string()
        }
        "ppsx" => {
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow".to_string()
        }
        "docm" => "application/vnd.ms-word.document.macroEnabled.12".to_string(),
        "xlsm" => "application/vnd.ms-excel.sheet.macroEnabled.12".to_string(),
        "pptm" => "application/vnd.ms-powerpoint.presentation.macroEnabled.12".to_string(),
        "fb2" => "application/x-fictionbook+xml".to_string(),
        "md" => "text/markdown".to_string(),
        "mobi" => "application/x-mobipocket-ebook".to_string(),
        "azw3" => "application/vnd.amazon.ebook".to_string(),
        _ => "application/octet-stream".to_string(),
    }
}

fn read_text_prefix(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take(XML_LIMIT).read_to_end(&mut bytes).ok()?;
    Some(decode_document_text(&bytes))
}

pub(crate) fn extract_format_text(
    path: &Path,
    format: &str,
    pdftotext: Option<&Path>,
) -> Option<String> {
    match format.to_ascii_lowercase().as_str() {
        format @ ("epub" | "cbz" | "docx" | "docm" | "odt" | "ods" | "odp" | "xlsx" | "xlsm"
        | "pptx" | "pptm" | "ppsx" | "htmlz" | "txtz") => {
            let file = std::fs::File::open(path).ok()?;
            zip_text(std::io::BufReader::new(file), format)
        }
        "fb2" => {
            let file = std::fs::File::open(path).ok()?;
            let mut bytes = Vec::new();
            file.take(XML_LIMIT + 1).read_to_end(&mut bytes).ok()?;
            xml_text(&decode_document_text(&bytes))
        }
        "pdf" => super::paperless::extract_pdf_text(path, pdftotext)
            .ok()
            .filter(|text| !text.trim().is_empty()),
        "txt" | "md" => read_text_prefix(path).filter(|text| !text.trim().is_empty()),
        "html" | "htm" => read_text_prefix(path)
            .map(|raw| html_to_text(&raw))
            .filter(|text| !text.trim().is_empty()),
        _ => None,
    }
}

/// Reads catalogue metadata embedded in an EPUB package or ComicInfo.xml.
/// ZIP entries stay in memory and use the same XML/input bounds as body text.
pub(crate) fn embedded_book_metadata(
    path: &Path,
    format: &str,
) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::Value;
    let mut metadata = serde_json::Map::new();
    if !matches!(format, "epub" | "cbz") {
        return metadata;
    }
    let Some(mut archive) = std::fs::File::open(path)
        .ok()
        .and_then(|file| ZipArchive::new(file).ok())
    else {
        return metadata;
    };
    let mut names: Vec<String> = archive
        .file_names()
        .filter(|name| {
            let lower = name.to_ascii_lowercase();
            if format == "epub" {
                lower.ends_with(".opf")
            } else {
                lower.rsplit('/').next() == Some("comicinfo.xml")
            }
        })
        .map(str::to_string)
        .collect();
    let preferred = if format == "epub" {
        archive
            .by_name("META-INF/container.xml")
            .ok()
            .and_then(|entry| {
                if entry.size() > XML_LIMIT {
                    return None;
                }
                let mut bytes = Vec::new();
                entry.take(XML_LIMIT + 1).read_to_end(&mut bytes).ok()?;
                let raw = decode_document_text(&bytes);
                let document = parse_xml(&raw)?;
                document
                    .descendants()
                    .find(|node| node.is_element() && node.tag_name().name() == "rootfile")
                    .and_then(|node| node.attribute("full-path"))
                    .map(str::to_string)
            })
    } else {
        None
    };
    names.sort_by_key(|name| (preferred.as_ref() != Some(name), name.clone()));
    for name in names {
        let Ok(entry) = archive.by_name(&name) else {
            continue;
        };
        if entry.size() > XML_LIMIT {
            continue;
        }
        let mut bytes = Vec::new();
        if entry.take(XML_LIMIT + 1).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let raw = decode_document_text(&bytes);
        let Some(document) = parse_xml(&raw) else {
            continue;
        };
        for node in document.descendants().filter(|node| node.is_element()) {
            let key = match node.tag_name().name() {
                "title" | "Title" => "title",
                "creator" | "Writer" => "authors",
                "subject" | "Genre" => "tags",
                "publisher" | "Publisher" => "publisher",
                "language" | "LanguageISO" => "language",
                "identifier" | "ISBN" => "identifiers",
                "description" | "Summary" => "description",
                _ => continue,
            };
            let text = truncate_text(node.text().unwrap_or_default().trim(), 4_096);
            if text.is_empty() {
                continue;
            }
            if matches!(key, "authors" | "tags" | "identifiers") {
                let values = metadata
                    .entry(key)
                    .or_insert_with(|| Value::Array(Vec::new()))
                    .as_array_mut()
                    .unwrap();
                if values.len() < 32 && !values.contains(&Value::String(text.clone())) {
                    values.push(Value::String(text));
                }
            } else {
                metadata.entry(key).or_insert(Value::String(text));
            }
        }
        if !metadata.is_empty() {
            break;
        }
    }
    metadata
}
