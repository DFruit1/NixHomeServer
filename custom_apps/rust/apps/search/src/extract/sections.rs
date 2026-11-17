//! Splits a long work into sections so that all of it is searchable and a
//! result names the part that matched. A whole Bible is several megabytes of
//! text: indexed as one document it was cut at a fixed size, which left
//! everything after Ezekiel unsearchable, and a match could only say "this
//! book". Sections follow the work's own structure (EPUB reading order and
//! contents table, PDF pages) and are sized like a long article.
use std::collections::HashMap;
use std::io::{Read, Seek};
use std::path::Path;

use zip::ZipArchive;

use super::document::{parse_xml, XML_LIMIT};
use super::ExtractedDocument;
use crate::text::{decode_document_text, html_to_text, truncate_text};

/// A section closes once it reaches the target; one unit larger than the
/// maximum is cut at paragraph breaks.
const SECTION_TARGET: usize = 60_000;
const SECTION_MAX: usize = 120_000;
/// Bounds for one work: unpacked input and resulting text.
const WORK_INPUT_LIMIT: u64 = 512_000_000;
const WORK_TEXT_LIMIT: usize = 96_000_000;

/// One structural piece of a work, in reading order.
#[derive(Debug, Default)]
pub(crate) struct Unit {
    /// Its entry in the contents table, when it has one.
    pub label: Option<String>,
    /// Its page number, for paginated formats.
    pub page: Option<usize>,
    pub text: String,
}

#[derive(Debug, PartialEq)]
pub(crate) struct Section {
    /// What to call this part of the work; empty when nothing names it.
    pub label: String,
    pub text: String,
}

#[derive(Default)]
struct Group {
    text: String,
    labels: Vec<String>,
    pages: Option<(usize, usize)>,
    part: Option<(usize, usize)>,
}

impl Group {
    fn push(&mut self, label: Option<&str>, page: Option<usize>, text: &str) {
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        self.text.push_str(text);
        if let Some(label) = label
            && self.labels.last().map(String::as_str) != Some(label)
        {
            self.labels.push(label.to_string());
        }
        if let Some(page) = page {
            self.pages = Some(self.pages.map_or((page, page), |(first, _)| (first, page)));
        }
    }

    fn finish(self) -> Section {
        let mut label = match (self.labels.first(), self.labels.last()) {
            (Some(first), Some(last)) if first != last => format!("{first} – {last}"),
            (Some(first), _) => first.clone(),
            _ => match self.pages {
                Some((first, last)) if first != last => format!("pages {first}–{last}"),
                Some((first, _)) => format!("page {first}"),
                None => String::new(),
            },
        };
        if let Some((index, count)) = self.part {
            let part = format!("part {index} of {count}");
            label = if label.is_empty() {
                part
            } else {
                format!("{label} ({part})")
            };
        }
        Section {
            label,
            text: self.text,
        }
    }
}

/// Cuts text into pieces of about `target` bytes, at a paragraph or line break
/// where there is one, otherwise at whitespace.
fn split_text(text: &str, target: usize) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut rest = text;
    while rest.len() > target + target / 2 {
        let limit = rest.floor_char_boundary(target);
        let window = &rest[..limit];
        let cut = window
            .rfind("\n\n")
            .or_else(|| window.rfind('\n'))
            .or_else(|| window.rfind(char::is_whitespace))
            .filter(|cut| *cut > target / 2)
            .unwrap_or(limit);
        parts.push(rest[..cut].trim_end());
        rest = rest[cut..].trim_start();
    }
    if !rest.is_empty() {
        parts.push(rest);
    }
    parts
}

/// Groups a work's units into sections, keeping the work's own boundaries.
pub(crate) fn sections(units: Vec<Unit>) -> Vec<Section> {
    let mut out = Vec::new();
    let mut current = Group::default();
    let mut total = 0;
    for unit in units {
        let text = unit.text.trim();
        if text.is_empty() {
            continue;
        }
        if total >= WORK_TEXT_LIMIT {
            break;
        }
        total += text.len();
        if text.len() > SECTION_MAX {
            if !current.text.is_empty() {
                out.push(std::mem::take(&mut current).finish());
            }
            let parts = split_text(text, SECTION_TARGET);
            let count = parts.len();
            for (index, part) in parts.into_iter().enumerate() {
                let mut group = Group {
                    part: Some((index + 1, count)),
                    ..Group::default()
                };
                group.push(unit.label.as_deref(), unit.page, part);
                out.push(group.finish());
            }
            continue;
        }
        if !current.text.is_empty()
            && ((unit.page.is_some()
                && unit.label.is_some()
                && current.labels.last() != unit.label.as_ref())
                || current.text.len() >= SECTION_TARGET
                || current.text.len() + text.len() > SECTION_MAX)
        {
            out.push(std::mem::take(&mut current).finish());
        }
        current.push(unit.label.as_deref(), unit.page, text);
    }
    if !current.text.is_empty() {
        out.push(current.finish());
    }
    out
}

/// Emits a work as one document per section. `work.body_text` holds what
/// introduces the work (catalogue details, description) and opens the first
/// section, which keeps the work's own id and title so existing links, exact
/// title matches and stored state carry over. Later sections are titled
/// "Work — Section". A work that fits in one section is emitted as before.
pub(crate) fn emit_work(
    mut work: ExtractedDocument,
    sections: Vec<Section>,
    emit: &mut dyn FnMut(ExtractedDocument),
) {
    if sections.len() <= 1 {
        if let Some(only) = sections.into_iter().next() {
            if !work.body_text.is_empty() {
                work.body_text.push('\n');
            }
            work.body_text.push_str(&only.text);
        }
        emit(work);
        return;
    }
    let id = work.external_id.clone();
    let title = work.title.clone();
    let introduction = std::mem::take(&mut work.body_text);
    for (index, section) in sections.into_iter().enumerate() {
        let mut part = work.clone();
        if let Some(metadata) = part.metadata.as_object_mut() {
            metadata.insert(super::SECTION_OF.to_string(), serde_json::json!(id));
            if !section.label.is_empty() {
                metadata.insert("section".to_string(), serde_json::json!(section.label));
            }
        }
        if index == 0 {
            part.body_text = if introduction.is_empty() {
                section.text
            } else {
                format!("{introduction}\n{}", section.text)
            };
        } else {
            part.external_id = format!("{id}#s{index}");
            let label = if section.label.is_empty() {
                format!("part {}", index + 1)
            } else {
                section.label
            };
            part.title = truncate_text(&format!("{title} — {label}"), 2_000);
            part.body_text = section.text;
        }
        emit(part);
    }
}

fn read_entry<R: Read + Seek>(archive: &mut ZipArchive<R>, name: &str) -> Option<String> {
    let entry = archive.by_name(name).ok()?;
    let mut bytes = Vec::new();
    entry.take(XML_LIMIT).read_to_end(&mut bytes).ok()?;
    Some(decode_document_text(&bytes))
}

/// Resolves a link inside an EPUB against the file that contains it: drops the
/// fragment, decodes percent escapes and folds `..` segments.
fn resolve(base_file: &str, href: &str) -> String {
    let href = href.split('#').next().unwrap_or_default();
    let mut decoded = Vec::with_capacity(href.len());
    let bytes = href.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && let Some(hex) = href.get(index + 1..index + 3)
            && let Ok(value) = u8::from_str_radix(hex, 16)
        {
            decoded.push(value);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    let href = String::from_utf8_lossy(&decoded);
    let mut parts: Vec<&str> = match base_file.rsplit_once('/') {
        Some((folder, _)) => folder.split('/').collect(),
        None => Vec::new(),
    };
    for segment in href.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
}

fn clean_label(raw: &str) -> Option<String> {
    let label = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    (!label.is_empty()).then(|| truncate_text(&label, 120))
}

/// Contents-table entries by the file they point to; the first entry for a
/// file names it. EPUB 3 navigation documents are HTML and often not
/// well-formed XML, so their links are read by scanning.
fn contents_labels<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    navigation: Option<&str>,
    ncx: Option<&str>,
) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    if let Some(name) = navigation
        && let Some(raw) = read_entry(archive, name)
    {
        let mut rest = raw.as_str();
        while let Some(start) = rest.find("<a ") {
            rest = &rest[start..];
            let Some(end) = rest.find("</a>") else { break };
            let anchor = &rest[..end];
            rest = &rest[end..];
            let Some(open_end) = anchor.find('>') else {
                continue;
            };
            let href = anchor[..open_end].split("href=").nth(1).and_then(|value| {
                let quote = value.chars().next()?;
                value[1..].split(quote).next()
            });
            if let Some(href) = href
                && let Some(label) = clean_label(&html_to_text(&anchor[open_end + 1..]))
            {
                labels.entry(resolve(name, href)).or_insert(label);
            }
        }
    }
    if let Some(name) = ncx
        && let Some(raw) = read_entry(archive, name)
        && let Some(document) = parse_xml(&raw)
    {
        for point in document
            .descendants()
            .filter(|node| node.is_element() && node.tag_name().name() == "navPoint")
        {
            let child = |tag: &str| {
                point
                    .children()
                    .find(|node| node.is_element() && node.tag_name().name() == tag)
            };
            let label = child("navLabel").and_then(|node| {
                clean_label(
                    &node
                        .descendants()
                        .filter_map(|text| text.text())
                        .collect::<String>(),
                )
            });
            let target = child("content").and_then(|node| node.attribute("src"));
            if let (Some(label), Some(target)) = (label, target) {
                labels.entry(resolve(name, target)).or_insert(label);
            }
        }
    }
    labels
}

/// An EPUB's text in reading order, one unit per content file, named from the
/// contents table. `None` when the package cannot be read, so the caller can
/// fall back to reading every HTML file.
pub(crate) fn epub_units<R: Read + Seek>(reader: R) -> Option<Vec<Unit>> {
    let mut archive = ZipArchive::new(reader).ok()?;
    let container = read_entry(&mut archive, "META-INF/container.xml")?;
    let package_name = parse_xml(&container)?
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "rootfile")?
        .attribute("full-path")?
        .to_string();
    let package_raw = read_entry(&mut archive, &package_name)?;
    let package = parse_xml(&package_raw)?;
    let mut manifest: HashMap<&str, (String, &str, &str)> = HashMap::new();
    let mut spine = Vec::new();
    let mut ncx = None;
    for node in package.descendants().filter(|node| node.is_element()) {
        match node.tag_name().name() {
            "item" => {
                if let (Some(id), Some(href)) = (node.attribute("id"), node.attribute("href")) {
                    manifest.insert(
                        id,
                        (
                            resolve(&package_name, href),
                            node.attribute("media-type").unwrap_or_default(),
                            node.attribute("properties").unwrap_or_default(),
                        ),
                    );
                }
            }
            "spine" => ncx = node.attribute("toc"),
            "itemref" => spine.extend(node.attribute("idref")),
            _ => {}
        }
    }
    let navigation = manifest
        .values()
        .find(|(_, _, properties)| properties.split_whitespace().any(|value| value == "nav"))
        .map(|(name, _, _)| name.clone());
    let ncx = ncx
        .and_then(|id| manifest.get(id))
        .or_else(|| {
            manifest
                .values()
                .find(|(_, media, _)| *media == "application/x-dtbncx+xml")
        })
        .map(|(name, _, _)| name.clone());
    let labels = contents_labels(&mut archive, navigation.as_deref(), ncx.as_deref());
    let mut units = Vec::new();
    let mut input = 0;
    for id in spine {
        let Some((name, media, _)) = manifest.get(id) else {
            continue;
        };
        // The contents page repeats every heading and is not reading matter.
        if navigation.as_ref() == Some(name) || !(media.contains("html") || media.is_empty()) {
            continue;
        }
        let Ok(entry) = archive.by_name(name) else {
            continue;
        };
        let read_limit = entry.size().min(XML_LIMIT);
        if input + read_limit > WORK_INPUT_LIMIT {
            break;
        }
        input += read_limit;
        let mut bytes = Vec::new();
        if entry.take(read_limit).read_to_end(&mut bytes).is_err() {
            continue;
        }
        units.push(Unit {
            label: labels.get(name).cloned(),
            page: None,
            text: html_to_text(&decode_document_text(&bytes)),
        });
    }
    units
        .iter()
        .any(|unit| !unit.text.trim().is_empty())
        .then_some(units)
}

/// Poppler's XML exporter includes the complete outline even when only the
/// first page is rendered. Use the sibling of the configured pdftotext binary,
/// so this needs no new dependency or deployment allocation. Missing outlines
/// (or an unavailable exporter) retain page-based extraction.
fn pdf_outline(path: &Path, pdftotext: Option<&Path>) -> std::collections::BTreeMap<usize, String> {
    use std::process::{Command, Stdio};
    let mut labels = std::collections::BTreeMap::new();
    let Some(tool) = pdftotext.map(|tool| tool.with_file_name("pdftohtml")) else {
        return labels;
    };
    let Ok(mut child) = Command::new(tool)
        .args(["-q", "-xml", "-stdout", "-i", "-f", "1", "-l", "1"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return labels;
    };
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .unwrap()
        .take(XML_LIMIT + 1)
        .read_to_end(&mut bytes);
    if bytes.len() as u64 > XML_LIMIT || read.is_err() {
        let _ = child.kill();
    }
    let status = child.wait();
    if bytes.len() as u64 > XML_LIMIT || status.is_err() || !status.unwrap().success() {
        return labels;
    }
    let raw = decode_document_text(&bytes);
    // Parse just the outline, excluding Poppler's external DOCTYPE. No DTD or
    // entity resolution is enabled for untrusted files.
    let Some(start) = raw.find("<outline>") else {
        return labels;
    };
    let Some(end) = raw.rfind("</outline>") else {
        return labels;
    };
    if let Some(document) = super::document::parse_xml(&raw[start..end + 10]) {
        for node in document
            .descendants()
            .filter(|node| node.has_tag_name("item"))
        {
            let Some(page) = node
                .attribute("page")
                .and_then(|p| p.parse::<usize>().ok())
                .filter(|p| *p > 0)
            else {
                continue;
            };
            let title = node.text().unwrap_or_default().trim();
            if !title.is_empty() {
                // Later descendants on the same page name a more specific
                // chapter than the enclosing volume or part.
                labels.insert(page, truncate_text(title, 500));
            }
        }
    }
    labels
}

/// A file's text as structural units: EPUB content files, PDF pages, or the
/// whole text for formats without such structure.
pub(crate) fn extract_format_units(
    path: &Path,
    format: &str,
    pdftotext: Option<&Path>,
) -> Result<Vec<Unit>, String> {
    let format = format.to_ascii_lowercase();
    if format == "epub"
        && let Ok(file) = std::fs::File::open(path)
        && let Some(units) = epub_units(std::io::BufReader::new(file))
    {
        return Ok(units);
    }
    if format == "pdf" {
        let text = super::paperless::extract_pdf_text(path, pdftotext)?;
        let outline = pdf_outline(path, pdftotext);
        let mut label = None;
        let mut units: Vec<Unit> = Vec::new();
        for (index, page) in text.split('\u{c}').enumerate() {
            if let Some(next) = outline.get(&(index + 1)) {
                label = Some(next.clone());
            }
            units.push(Unit {
                label: label.clone(),
                page: Some(index + 1),
                text: page.to_string(),
            });
        }
        return Ok(units);
    }
    Ok(
        super::document::extract_format_text(path, &format, pdftotext)
            .map(|text| {
                vec![Unit {
                    text,
                    ..Unit::default()
                }]
            })
            .unwrap_or_default(),
    )
}
