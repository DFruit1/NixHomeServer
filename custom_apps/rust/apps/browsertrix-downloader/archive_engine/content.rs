use super::read::{self, Record, MAX_ITEMS, MAX_RECORD};
use html2text::{Element, Handle, RcDom};
use std::collections::BTreeSet;

pub(super) fn transfer_payload(record: &Record) -> Result<Vec<u8>, String> {
    let mut bytes = record.payload.clone();
    if record.kind() == "resource" {
        return Ok(bytes);
    }
    let split = record
        .block
        .windows(4)
        .position(|s| s == b"\r\n\r\n")
        .ok_or("HTTP header missing")?;
    let (_, headers) = read::headers(&record.block[..split])?;
    if let Some(encoding) = headers.get("transfer-encoding") {
        if !encoding.eq_ignore_ascii_case("chunked") {
            return Err("Unsupported HTTP transfer encoding".into());
        }
        let mut decoded = vec![];
        let mut p = 0;
        loop {
            let end = bytes[p..]
                .windows(2)
                .position(|s| s == b"\r\n")
                .ok_or("Invalid HTTP chunk")?
                + p;
            let line = std::str::from_utf8(&bytes[p..end]).map_err(|_| "Invalid chunk size")?;
            let size = usize::from_str_radix(line.split(';').next().unwrap_or(""), 16)
                .map_err(|_| "Invalid chunk size")?;
            p = end + 2;
            if size == 0 {
                let tail = &bytes[p..];
                if tail != b"\r\n" && (!tail.ends_with(b"\r\n\r\n") || tail.len() > 65536) {
                    return Err("Invalid chunk trailer".into());
                }
                break;
            }
            let end = p
                .checked_add(size)
                .filter(|end| *end <= bytes.len() && size <= MAX_RECORD - decoded.len())
                .ok_or("HTTP chunk limit/truncation")?;
            decoded.extend_from_slice(&bytes[p..end]);
            if bytes.get(end..end + 2) != Some(b"\r\n") {
                return Err("Invalid HTTP chunk delimiter".into());
            }
            p = end + 2;
        }
        bytes = decoded;
    }
    Ok(bytes)
}
pub(super) const MAX_HTML: usize = 2 * 1024 * 1024;
pub(super) fn payload(record: &Record) -> Result<Vec<u8>, String> {
    payload_limited(record, MAX_RECORD)
}
pub(super) fn payload_limited(record: &Record, limit: usize) -> Result<Vec<u8>, String> {
    if record.payload_length > limit as u64 {
        return Err(format!(
            "Resource decoding exceeds {limit} byte analysis bound"
        ));
    }
    let loaded = record.eager_body_limited(limit.saturating_add(64 * 1024))?;
    let record = &loaded;
    let mut bytes = transfer_payload(record)?;
    if record.kind() == "resource" {
        return Ok(bytes);
    }
    let split = record
        .block
        .windows(4)
        .position(|s| s == b"\r\n\r\n")
        .ok_or("HTTP header missing")?;
    let (_, headers) = read::headers(&record.block[..split])?;
    if let Some(encoding) = headers.get("content-encoding") {
        bytes = match encoding.to_ascii_lowercase().as_str() {
            "identity" => bytes,
            "gzip" | "x-gzip" => {
                read::bounded(flate2::read::MultiGzDecoder::new(bytes.as_slice()), limit)?
            }
            "deflate" => read::bounded(flate2::read::ZlibDecoder::new(bytes.as_slice()), limit)?,
            _ => return Err("Unsupported HTTP content encoding for text transformation".into()),
        };
    }
    if headers.get("content-type").is_some_and(|s| {
        let lower = s.to_ascii_lowercase();
        lower.contains("charset=")
            && !lower.contains("charset=utf-8")
            && !lower.contains("charset=\"utf-8\"")
            && !lower.contains("charset=us-ascii")
    }) {
        return Err("Non-UTF8 HTML transformation unsupported".into());
    }
    Ok(bytes)
}

pub(super) fn dom(bytes: &[u8]) -> Result<RcDom, String> {
    if bytes.len() > 2 * 1024 * 1024 {
        return Err("HTML analysis exceeds 2 MiB limit".into());
    }
    std::str::from_utf8(bytes).map_err(|_| "Non-UTF8 HTML unsupported")?;
    let dom = html2text::config::plain()
        .parse_html(bytes)
        .map_err(|e| e.to_string())?;
    let mut stack = vec![(dom.document.clone(), 0)];
    let mut count = 0;
    while let Some((node, depth)) = stack.pop() {
        count += 1;
        if count > MAX_ITEMS || depth > 128 {
            return Err("HTML DOM node/depth limit exceeded".into());
        }
        for child in node.children.borrow().iter() {
            stack.push((child.clone(), depth + 1));
        }
    }
    Ok(dom)
}
pub(super) fn attr(node: &Handle, key: &str) -> Option<String> {
    if let Element { attrs, .. } = &node.data {
        attrs
            .borrow()
            .iter()
            .find(|a| a.name.local.as_ref() == key)
            .map(|a| a.value.to_string())
    } else {
        None
    }
}
pub(super) fn text(node: &Handle) -> Result<String, String> {
    let mut fragment = html2text::config::plain()
        .parse_html(&b""[..])
        .map_err(|e| e.to_string())?;
    fragment.document = node.clone();
    let config = html2text::config::plain();
    config
        .render_to_string(
            config
                .dom_to_render_tree(&fragment)
                .map_err(|e| e.to_string())?,
            100,
        )
        .map_err(|e| e.to_string())
}
pub(super) struct HtmlAnalysis {
    pub content: Option<(String, String, Vec<String>)>,
    pub omitted: Option<String>,
}
/// Only embedded documents create page-selection dependencies; navigation links
/// do not. An unavailable/oversized analysis asks the caller to retain pages
/// conservatively rather than silently break a frame or dynamic dependency.
pub(super) fn embedded_documents(record: &Record) -> Result<Option<Vec<String>>, String> {
    if record.payload_length > MAX_HTML as u64 {
        return Ok(None);
    }
    let loaded = record.eager_body_limited(MAX_HTML + 64 * 1024)?;
    let document = match payload_limited(&loaded, MAX_HTML).and_then(|b| dom(&b)) {
        Ok(document) => document,
        Err(_) => return Ok(None),
    };
    let Some(mut base) = url::Url::parse(record.url()).ok() else {
        return Ok(None);
    };
    let mut nodes = vec![document.document.clone()];
    while let Some(node) = nodes.pop() {
        if node.element_name().as_deref() == Some("base") {
            if let Some(next) = attr(&node, "href").and_then(|s| base.join(&s).ok()) {
                base = next;
                break;
            }
        }
        nodes.extend(node.children.borrow().iter().rev().cloned());
    }
    let mut links = BTreeSet::new();
    let mut nodes = vec![document.document.clone()];
    while let Some(node) = nodes.pop() {
        let attribute = match node.element_name().as_deref() {
            Some("iframe" | "frame" | "embed") => Some("src"),
            Some("object") => Some("data"),
            _ => None,
        };
        if let Some(link) = attribute
            .and_then(|key| attr(&node, key))
            .and_then(|s| base.join(&s).ok())
            .filter(|u| matches!(u.scheme(), "http" | "https"))
        {
            links.insert(link.to_string());
        }
        // srcdoc and scripts can introduce documents unavailable to static
        // dependency analysis, including URLs also listed as standalone pages.
        let event_handler = if let Element { attrs, .. } = &node.data {
            attrs
                .borrow()
                .iter()
                .any(|a| a.name.local.as_ref().starts_with("on"))
        } else {
            false
        };
        if attr(&node, "srcdoc").is_some()
            || node.element_name().as_deref() == Some("script")
            || event_handler
        {
            return Ok(None);
        }
        nodes.extend(node.children.borrow().iter().cloned());
    }
    Ok(Some(links.into_iter().collect()))
}
/// Optional analysis cannot invalidate fixity. Lazy source IO/fixity remains
/// fatal; decode/DOM limits retain the original and bounded crawler metadata.
pub(super) fn analyse(record: &Record) -> Result<HtmlAnalysis, String> {
    if record.payload_length > MAX_HTML as u64 {
        return Ok(HtmlAnalysis {
            content: None,
            omitted: Some("HTML entity exceeds 2 MiB optional DOM bound".into()),
        });
    }
    let loaded = record.eager_body_limited(MAX_HTML + 64 * 1024)?;
    Ok(match extract(&loaded) {
        Ok(content) => HtmlAnalysis {
            content: Some(content),
            omitted: None,
        },
        Err(reason) => HtmlAnalysis {
            content: None,
            omitted: Some(reason),
        },
    })
}
pub(super) fn extract(record: &Record) -> Result<(String, String, Vec<String>), String> {
    if record.kind() == "revisit" && !record.resolved {
        return Ok((String::new(), String::new(), vec![]));
    }
    let dom = dom(&payload_limited(record, MAX_HTML)?)?;
    let mut stack = vec![dom.document.clone()];
    let mut title = String::new();
    let mut links = BTreeSet::new();
    let mut base = url::Url::parse(record.url()).ok();
    let mut base_nodes = vec![dom.document.clone()];
    while let Some(node) = base_nodes.pop() {
        if node.element_name().as_deref() == Some("base") {
            if let (Some(current), Some(href)) = (&base, attr(&node, "href")) {
                if let Ok(next) = current.join(&href) {
                    if matches!(next.scheme(), "http" | "https") {
                        base = Some(next);
                        break;
                    }
                }
            }
        }
        for child in node.children.borrow().iter().rev() {
            base_nodes.push(child.clone());
        }
    }
    while let Some(node) = stack.pop() {
        if node.element_name().as_deref() == Some("title") {
            title = node
                .children
                .borrow()
                .iter()
                .map(text)
                .collect::<Result<Vec<_>, _>>()?
                .join("")
                .trim()
                .into();
        }
        for key in ["src", "href", "poster", "data"] {
            if let (Some(base), Some(value)) = (&base, attr(&node, key)) {
                if let Ok(mut url) = base.join(&value) {
                    if matches!(url.scheme(), "http" | "https") {
                        url.set_fragment(None);
                        links.insert(url.to_string());
                    }
                }
            }
        }
        if let (Some(base), Some(value)) = (&base, attr(&node, "srcset")) {
            for entry in value.split(',') {
                if let Some(first) = entry.split_whitespace().next() {
                    if let Ok(url) = base.join(first) {
                        if matches!(url.scheme(), "http" | "https") {
                            links.insert(url.to_string());
                        }
                    }
                }
            }
        }
        stack.extend(node.children.borrow().iter().cloned());
    }
    let text = text(&dom.document)?;
    if text.len() > MAX_RECORD {
        return Err("Extracted text limit exceeded".into());
    }
    Ok((text, title, links.into_iter().collect()))
}
pub(super) fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
