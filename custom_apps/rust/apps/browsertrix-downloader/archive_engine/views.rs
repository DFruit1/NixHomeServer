use super::read::{self, Record, MAX_BYTES};
use super::*;
use html2text::Element;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

#[derive(Clone, Debug)]
pub struct PreviewDocument {
    pub html: String,
    /// Send this exact value as the HTTP Content-Security-Policy header.
    pub content_security_policy: String,
}

pub fn preview_page(path: &Path, url: &str) -> Result<String, String> {
    Ok(preview_document(path, url)?.html)
}

pub fn preview_document(path: &Path, url: &str) -> Result<PreviewDocument, String> {
    preview_document_authorized(path, url, &[])
}

/// The caller authorizes owner/visibility; the engine verifies every immutable
/// dependency binding and resolves revisits without writing payload files.
pub fn preview_document_authorized(
    path: &Path,
    url: &str,
    dependencies: &[AuthorizedDependency],
) -> Result<PreviewDocument, String> {
    if url.len() > 8192 {
        return Err("Preview URL exceeds limit".into());
    }
    let archive = transform::authorized_archive(path, dependencies)?;
    let record = archive
        .records
        .iter()
        .filter(|r| r.url() == url && r.mime == "text/html" && r.resolved)
        .max_by_key(|r| r.field("warc-date"))
        .ok_or("Captured HTML page not found or requires standalone materialization")?;
    let dom = content::dom(&content::payload_limited(record, content::MAX_HTML)?)?;
    let mut base = url::Url::parse(url).map_err(|_| "Invalid preview URL")?;
    let mut resources = HashMap::<String, &Record>::new();
    let capture = chrono::DateTime::parse_from_rfc3339(record.field("warc-date"))
        .map(|d| d.timestamp_millis())
        .unwrap_or(0);
    let score = |resource: &Record| {
        let stamp = chrono::DateTime::parse_from_rfc3339(resource.field("warc-date"))
            .map(|d| d.timestamp_millis())
            .unwrap_or(0);
        (
            !record.field("warc-page-id").is_empty()
                && record.field("warc-page-id") == resource.field("warc-page-id"),
            std::cmp::Reverse(stamp.abs_diff(capture)),
        )
    };
    for resource in &archive.records {
        if resource.resolved {
            resources
                .entry(resource.url().into())
                .and_modify(|current| {
                    if score(resource) > score(current) {
                        *current = resource;
                    }
                })
                .or_insert(resource);
        }
    }
    let scaffold = content::dom(b"<div data-archive-selector='' src='' poster=''></div>")?;
    let mut templates = Vec::new();
    let mut nodes = vec![scaffold.document.clone()];
    while let Some(node) = nodes.pop() {
        if let Element { attrs, .. } = &node.data {
            templates.extend(attrs.borrow().iter().cloned());
        }
        nodes.extend(node.children.borrow().iter().cloned());
    }
    let mut ids = HashMap::<String, usize>::new();
    let mut saw_base = false;
    let mut stack = vec![dom.document.clone()];
    while let Some(node) = stack.pop() {
        if !saw_base && node.element_name().as_deref() == Some("base") {
            if let Some(next) = content::attr(&node, "href")
                .and_then(|s| base.join(&s).ok())
                .filter(|u| matches!(u.scheme(), "http" | "https"))
            {
                base = next;
                saw_base = true;
            }
        }
        if let Some(id) = content::attr(&node, "id") {
            *ids.entry(id).or_default() += 1;
        }
        stack.extend(node.children.borrow().iter().cloned());
    }
    let mut stack = vec![(dom.document.clone(), String::new())];
    let mut drop_nodes = vec![];
    let mut css = String::new();
    let mut image_bytes = 0;
    while let Some((node, parent_path)) = stack.pop() {
        let mut own_path = parent_path.clone();
        if let Element { name, attrs, .. } = &node.data {
            let tag = name.local.to_string();
            if name.ns.as_ref() != "http://www.w3.org/1999/xhtml"
                || matches!(
                    tag.as_str(),
                    "script"
                        | "iframe"
                        | "frame"
                        | "frameset"
                        | "object"
                        | "embed"
                        | "template"
                        | "base"
                        | "meta"
                        | "noscript"
                )
            {
                drop_nodes.push(node.clone());
                continue;
            }
            let ordinal = node
                .get_parent()
                .map(|p| {
                    p.children
                        .borrow()
                        .iter()
                        .filter(|n| n.element_name().is_some())
                        .position(|n| Rc::ptr_eq(n, &node))
                        .unwrap_or(0)
                        + 1
                })
                .unwrap_or(1);
            own_path = if parent_path.is_empty() {
                format!("{tag}:nth-child({ordinal})")
            } else {
                format!("{parent_path} > {tag}:nth-child({ordinal})")
            };
            let id = content::attr(&node, "id")
                .filter(|id| ids.get(id) == Some(&1) && simple_identifier(id));
            let selector = id
                .map(|id| format!("#{id}"))
                .unwrap_or_else(|| own_path.clone());
            if selector.len() > 512 {
                return Err("Original selector path exceeds preview bridge limit".into());
            }
            let source = content::attr(&node, "src").or_else(|| content::attr(&node, "poster"));
            let image = source
                .and_then(|s| base.join(&s).ok())
                .and_then(|u| resources.get(u.as_str()).copied())
                .filter(|r| {
                    matches!(
                        r.mime.as_str(),
                        "image/png" | "image/jpeg" | "image/gif" | "image/webp" | "image/avif"
                    )
                });
            let image = if let Some(image) = image.filter(|r| r.payload_length <= 512 * 1024) {
                let bytes = content::payload(image)?;
                if bytes.len() <= 512 * 1024 && image_bytes + bytes.len() <= 4 * 1024 * 1024 {
                    image_bytes += bytes.len();
                    Some(format!("data:{};base64,{}", image.mime, base64(&bytes)))
                } else {
                    None
                }
            } else {
                None
            };
            if tag == "link" {
                if content::attr(&node, "rel").is_some_and(|r| {
                    r.split_whitespace()
                        .any(|s| s.eq_ignore_ascii_case("stylesheet"))
                }) {
                    if let Some(sheet) = content::attr(&node, "href")
                        .and_then(|s| base.join(&s).ok())
                        .and_then(|u| resources.get(u.as_str()).copied())
                        .filter(|r| r.mime == "text/css")
                    {
                        let bytes = content::payload(sheet)?;
                        if css.len() + bytes.len() > 1024 * 1024 {
                            return Err("Preview captured CSS exceeds 1 MiB".into());
                        }
                        let text = std::str::from_utf8(&bytes)
                            .map_err(|_| "Non-UTF8 captured CSS unsupported")?;
                        css.push_str(&text.replace('<', "\\3c "));
                        css.push('\n');
                    }
                }
                drop_nodes.push(node.clone());
                continue;
            }
            // Security is the opaque iframe plus strict CSP, not an ad-hoc
            // promise that arbitrary HTML/CSS can safely run on the app origin.
            // Keep visual attributes, remove network/event/navigation surfaces.
            attrs.borrow_mut().retain(|a| {
                a.name.ns.as_ref().is_empty()
                    && matches!(
                        a.name.local.as_ref(),
                        "id" | "class"
                            | "style"
                            | "title"
                            | "lang"
                            | "dir"
                            | "role"
                            | "aria-label"
                            | "colspan"
                            | "rowspan"
                            | "width"
                            | "height"
                            | "alt"
                            | "hidden"
                    )
            });
            // Attribute's concrete type is public via the DOM even though the
            // parser crate itself is deliberately not a new direct dependency.
            let add = |key: &str, value: String| {
                let mut attribute = templates
                    .iter()
                    .find(|a| a.name.local.as_ref() == key)
                    .expect("trusted attribute scaffold")
                    .clone();
                attribute.value = value.into();
                attrs.borrow_mut().push(attribute);
            };
            add("data-archive-selector", selector);
            if let Some(image) = image {
                if tag == "img" {
                    add("src", image);
                } else if tag == "video" {
                    add("poster", image);
                }
            }
        }
        for child in node.children.borrow().iter().rev() {
            stack.push((child.clone(), own_path.clone()));
        }
    }
    for node in drop_nodes {
        if let Some(parent) = node.get_parent() {
            parent
                .children
                .borrow_mut()
                .retain(|child| !Rc::ptr_eq(child, &node));
        }
    }
    let nonce = format!("{:032x}", rand::random::<u128>());
    let csp=format!("default-src 'none'; sandbox allow-scripts; script-src 'nonce-{nonce}'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'");
    let meta = format!(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"{}\"><style>{css}</style>",
        content::escape(&csp)
    );
    let encoded_url = serde_json::to_string(url)
        .map_err(|e| e.to_string())?
        .replace('<', "\\u003c");
    let script = format!(
        r#"<script nonce="{nonce}">(()=>{{'use strict';const url={encoded_url};document.addEventListener('click',e=>{{e.preventDefault();e.stopImmediatePropagation();const n=e.target.closest('[data-archive-selector]');if(!n)return;const selector=n.dataset.archiveSelector;if(typeof selector!=='string'||selector.length>512)return;parent.postMessage({{type:'web-archives:selection',selector,url,matches:1}},'*');}},true);document.addEventListener('mouseover',e=>{{const n=e.target.closest('[data-archive-selector]');if(n)n.style.outline='2px solid #1d70b8';}},true);document.addEventListener('mouseout',e=>{{const n=e.target.closest('[data-archive-selector]');if(n)n.style.outline='';}},true);}})();</script>"#
    );
    // Insert trusted nodes through the public DOM. String searches for '>' are
    // incorrect when original selector attributes contain child combinators.
    let trusted =
        content::dom(format!("<html><head>{meta}</head><body>{script}</body></html>").as_bytes())?;
    let element = |root: &html2text::RcDom, tag: &str| {
        let mut stack = vec![root.document.clone()];
        while let Some(node) = stack.pop() {
            if node.element_name().as_deref() == Some(tag) {
                return Some(node);
            }
            stack.extend(node.children.borrow().iter().cloned());
        }
        None
    };
    for tag in ["head", "body"] {
        let target = element(&dom, tag).ok_or("Preview has no HTML head/body")?;
        let source = element(&trusted, tag).ok_or("Trusted preview scaffold invalid")?;
        let children: Vec<_> = source.children.borrow_mut().drain(..).collect();
        for child in &children {
            child.parent.set(Some(Rc::downgrade(&target)));
        }
        if tag == "head" {
            target.children.borrow_mut().splice(0..0, children);
        } else {
            target.children.borrow_mut().extend(children);
        }
    }
    let mut bytes = vec![];
    dom.serialize(&mut bytes).map_err(|e| e.to_string())?;
    let html = String::from_utf8(bytes).map_err(|e| e.to_string())?;
    if html.len() > 8 * 1024 * 1024 {
        return Err("Preview output exceeds 8 MiB".into());
    }
    Ok(PreviewDocument {
        html,
        content_security_policy: csp,
    })
}
fn simple_identifier(s: &str) -> bool {
    s.as_bytes()
        .first()
        .is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let a = c[0];
        let b = *c.get(1).unwrap_or(&0);
        let d = *c.get(2).unwrap_or(&0);
        out.push(ALPHABET[(a >> 2) as usize] as char);
        out.push(ALPHABET[(((a & 3) << 4) | (b >> 4)) as usize] as char);
        out.push(if c.len() > 1 {
            ALPHABET[(((b & 15) << 2) | (d >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            ALPHABET[(d & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

pub fn reader_export(path: &Path, format: &str) -> Result<String, String> {
    reader_export_authorized(path, format, &[])
}

pub fn reader_export_authorized(
    path: &Path,
    format: &str,
    dependencies: &[AuthorizedDependency],
) -> Result<String, String> {
    reader_export_impl(path, format, dependencies, MAX_BYTES, false)
}

/// Caller-sized response limit, capped at the legacy 256 MiB ceiling. Checks
/// escaped output length before allocating it. This entry point also caps
/// retained source/dependency metadata and optional analysis at the smaller of
/// max_output_bytes and 32 MiB; it returns an error rather than truncating.
/// This does not replace the caller's aggregate response-lifetime permit.
pub fn reader_export_authorized_limited(
    path: &Path,
    format: &str,
    dependencies: &[AuthorizedDependency],
    max_output_bytes: usize,
) -> Result<String, String> {
    reader_export_impl(
        path,
        format,
        dependencies,
        max_output_bytes.min(MAX_BYTES),
        true,
    )
}

fn reader_export_impl(
    path: &Path,
    format: &str,
    dependencies: &[AuthorizedDependency],
    max_output_bytes: usize,
    limited_analysis: bool,
) -> Result<String, String> {
    if !matches!(format, "markdown" | "html") {
        return Err("Reader format must be markdown or html".into());
    }
    if max_output_bytes == 0 {
        return Err("Reader output exceeds bounded size".into());
    }
    let pages = {
        let budget = max_output_bytes.min(super::streaming::MAX_METADATA);
        let archive = if limited_analysis {
            transform::authorized_archive_limited(path, dependencies, budget)?
        } else {
            transform::authorized_archive(path, dependencies)?
        };
        // Drop archive inventories and report resources before allocating the
        // response; only the reader's page data remains live here.
        if limited_analysis {
            archive.report_with_analysis_budget(budget, true)?.pages
        } else {
            archive.report()?.pages
        }
    };
    if pages.is_empty() {
        return Err("No captured readable pages".into());
    }
    let mut length = 0usize;
    reader_parts(&pages, format, |value, escaping| {
        let remaining = max_output_bytes - length;
        let count = if escaping == ReaderEscaping::Plain {
            value.len()
        } else {
            value.chars().try_fold(0usize, |count, ch| {
                count
                    .checked_add(reader_escape(ch, escaping).map_or(ch.len_utf8(), str::len))
                    .filter(|count| *count <= remaining)
                    .ok_or("Reader output exceeds bounded size")
            })?
        };
        length = length
            .checked_add(count)
            .filter(|n| *n <= max_output_bytes)
            .ok_or("Reader output exceeds bounded size")?;
        Ok(())
    })?;
    let mut out = String::new();
    out.try_reserve_exact(length)
        .map_err(|_| "Reader output allocation failed")?;
    reader_parts(&pages, format, |value, escaping| {
        if escaping == ReaderEscaping::Plain {
            out.push_str(value);
        } else {
            for ch in value.chars() {
                if let Some(escaped) = reader_escape(ch, escaping) {
                    out.push_str(escaped);
                } else {
                    out.push(ch);
                }
            }
        }
        Ok(())
    })?;
    debug_assert_eq!(out.len(), length);
    Ok(out)
}

#[derive(Clone, Copy, PartialEq)]
enum ReaderEscaping {
    Plain,
    Html,
    Markdown,
}
fn reader_parts(
    pages: &[PageRecord],
    format: &str,
    mut emit: impl FnMut(&str, ReaderEscaping) -> Result<(), String>,
) -> Result<(), String> {
    use ReaderEscaping::{Html, Markdown, Plain};
    if format == "html" {
        emit("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><title>Archived reading export</title><style>body{max-width:76ch;margin:2rem auto;padding:1rem;font:18px/1.6 system-ui}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body><h1>Archived reading export</h1><p>Derived reading copy; scripts, layout, images and interactions are omitted.</p>", Plain)?;
    } else {
        emit("# Archived reading export\n\nDerived reading copy; layout, images and interactions are omitted.\n\n", Plain)?;
    }
    for page in pages {
        if format == "html" {
            for (value, escaping) in [
                ("<article><h2>", Plain),
                (&*page.title, Html),
                ("</h2><p>Source: ", Plain),
                (&*page.url, Html),
                ("<br>Capture: ", Plain),
                (&*page.ts, Html),
                ("</p><pre>", Plain),
                (&*page.text, Html),
                ("</pre></article>", Plain),
            ] {
                emit(value, escaping)?;
            }
        } else {
            for (value, escaping) in [
                ("## ", Plain),
                (&*page.title, Markdown),
                ("\n\nSource: ", Plain),
                (&*page.url, Markdown),
                ("\nCapture: ", Plain),
                (&*page.ts, Markdown),
                ("\n\n", Plain),
                (&*page.text, Markdown),
                ("\n\n", Plain),
            ] {
                emit(value, escaping)?;
            }
        }
    }
    if format == "html" {
        emit("</body></html>", Plain)?;
    }
    Ok(())
}
fn reader_escape(ch: char, escaping: ReaderEscaping) -> Option<&'static str> {
    use ReaderEscaping::{Html, Markdown};
    match (escaping, ch) {
        (Html | Markdown, '&') => Some("&amp;"),
        (Html | Markdown, '<') => Some("&lt;"),
        (Html | Markdown, '>') => Some("&gt;"),
        (Html, '"') => Some("&quot;"),
        (Html, '\'') => Some("&#39;"),
        (Markdown, '\\') => Some("\\\\"),
        (Markdown, '[') => Some("\\["),
        (Markdown, ']') => Some("\\]"),
        (Markdown, '!') => Some("\\!"),
        (Markdown, '*') => Some("\\*"),
        (Markdown, '_') => Some("\\_"),
        (Markdown, '#') => Some("\\#"),
        (Markdown, '`') => Some("\\`"),
        (Markdown, '|') => Some("\\|"),
        _ => None,
    }
}

pub fn compare_archives(left: &Path, right: &Path) -> Result<ComparisonReport, String> {
    compare_archives_authorized(left, &[], right, &[])
}

pub fn compare_archives_authorized(
    left: &Path,
    left_dependencies: &[AuthorizedDependency],
    right: &Path,
    right_dependencies: &[AuthorizedDependency],
) -> Result<ComparisonReport, String> {
    let left = transform::authorized_archive(left, left_dependencies)?.report()?;
    let right = transform::authorized_archive(right, right_dependencies)?.report()?;
    let mut report = ComparisonReport::default();
    let pages = |a: ArchiveReport| -> (
        BTreeMap<String, BTreeSet<String>>,
        BTreeMap<String, BTreeSet<String>>,
    ) {
        let mut pages = BTreeMap::<String, BTreeSet<String>>::new();
        let mut resources = BTreeMap::<String, BTreeSet<String>>::new();
        for p in a.pages {
            pages.entry(p.url).or_default().insert(read::hash(
                format!("{}\n{}\n{}", p.title, p.text, p.status).as_bytes(),
            ));
        }
        for r in a.resources {
            resources
                .entry(r.url)
                .or_default()
                .insert(format!("{}:{}:{}", r.digest, r.status, r.mime));
        }
        (pages, resources)
    };
    let (lp, lr) = pages(left);
    let (rp, rr) = pages(right);
    for (url, fingerprints) in &rp {
        match lp.get(url) {
            None => report.added_pages.push(url.clone()),
            Some(old) if old != fingerprints => report.changed_pages.push(url.clone()),
            _ => report.unchanged_pages.push(url.clone()),
        }
    }
    for url in lp.keys() {
        if !rp.contains_key(url) {
            report.removed_pages.push(url.clone());
        }
    }
    for (url, fingerprints) in &rr {
        match lr.get(url) {
            None => report.added_resources.push(url.clone()),
            Some(old) if old != fingerprints => report.changed_resources.push(url.clone()),
            _ => {}
        }
    }
    for url in lr.keys() {
        if !rr.contains_key(url) {
            report.removed_resources.push(url.clone());
        }
    }
    report.warnings.push("Added/removed means captured coverage differs; missing coverage does not prove a website deletion. Text changes and resource changes are reported separately.".into());
    Ok(report)
}

pub fn estimate_size(
    samples: &[PageSample],
    discovered_pages: u64,
    page_limit: u32,
    unknown_scope: bool,
) -> Estimate {
    let measured: Vec<_> = samples.iter().filter(|s| s.measured).take(1024).collect();
    let unbounded = page_limit == 0 && unknown_scope;
    let mut out = Estimate {
        discovered_pages,
        unknown_scope,
        ..Default::default()
    };
    if measured.is_empty() {
        out.upper_bytes = u64::MAX;
        out.peak_disk_bytes = u64::MAX;
        out.assumptions.push("Discovery estimate only: no measured browser samples; stored/transfer/peak bytes are unknown".into());
        out.warnings
            .push("Run a bounded browser sampling job before choosing byte/disk budgets".into());
        return out;
    }
    out.measured = true;
    out.sample_pages = measured.len() as u64;
    let mut digests = BTreeMap::<&str, (u64, u64)>::new();
    for sample in &measured {
        for (digest, bytes) in &sample.resource_digests {
            let entry = digests.entry(digest).or_default();
            entry.0 += 1;
            entry.1 = entry.1.max(*bytes);
        }
    }
    let shared: BTreeMap<_, _> = digests.into_iter().filter(|(_, v)| v.0 > 1).collect();
    out.shared_bytes = shared
        .values()
        .fold(0u64, |total, (_, bytes)| total.saturating_add(*bytes));
    out.shared_bytes = out
        .shared_bytes
        .max(measured.iter().map(|s| s.shared_bytes).max().unwrap_or(0));
    let mut marginal: Vec<u64> = measured
        .iter()
        .map(|s| {
            let common = s
                .resource_digests
                .iter()
                .filter(|(digest, _)| shared.contains_key(digest.as_str()))
                .fold(0u64, |n, (_, b)| n.saturating_add(*b))
                .max(s.shared_bytes);
            s.bytes.saturating_sub(common)
        })
        .collect();
    marginal.sort_unstable();
    out.marginal_page_bytes = marginal[marginal.len() / 2];
    let known = discovered_pages.max(out.sample_pages);
    let cap = if page_limit == 0 {
        known
    } else {
        u64::from(page_limit)
    };
    let target = known.min(cap);
    out.expected_bytes = out
        .shared_bytes
        .saturating_add(out.marginal_page_bytes.saturating_mul(target));
    out.lower_bytes = out
        .shared_bytes
        .saturating_add(marginal[0].saturating_mul(target) / 2);
    let upper_pages = if unknown_scope { cap } else { target };
    out.upper_bytes = if unbounded {
        u64::MAX
    } else {
        out.shared_bytes
            .saturating_add(
                marginal[marginal.len() - 1]
                    .saturating_mul(upper_pages)
                    .saturating_mul(2),
            )
            .max(out.expected_bytes)
    };
    out.peak_disk_bytes = out.upper_bytes.saturating_mul(3);
    out.assumptions.push(format!("Browser-measured stored samples: {}; shared payloads counted once; marginal median projected onto {target} bounded pages",out.sample_pages));
    out.assumptions.push("Range is a heuristic, not a capture guarantee; transfer bytes are not measured by stored-byte samples; peak disk reserves 3x upper stored estimate for scratch and publication".into());
    if unknown_scope {
        out.warnings.push("Discovered links do not bound a dynamic website; page/time/byte budgets remain mandatory".into());
    }
    if unbounded {
        out.warnings.push(
            "Unknown scope without a page bound: upper and peak bytes are unbounded (u64::MAX)"
                .into(),
        );
    }
    if samples.len() > 1024 {
        out.warnings
            .push("Estimate uses at most 1024 measured samples".into());
    }
    out
}
