use super::read::{self, Record, MAX_ITEMS, MAX_RECORD};
use html2text::{Element, Handle, RcDom};
use std::collections::BTreeSet;

pub(super) fn payload(record: &Record) -> Result<Vec<u8>, String> {
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
    if let Some(encoding) = headers.get("content-encoding") {
        bytes = match encoding.to_ascii_lowercase().as_str() {
            "identity" => bytes,
            "gzip" | "x-gzip" => read::bounded(
                flate2::read::MultiGzDecoder::new(bytes.as_slice()),
                MAX_RECORD,
            )?,
            "deflate" => {
                read::bounded(flate2::read::ZlibDecoder::new(bytes.as_slice()), MAX_RECORD)?
            }
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
pub(super) fn extract(record: &Record) -> Result<(String, String, Vec<String>), String> {
    if record.kind() == "revisit" && record.payload.is_empty() {
        return Ok((String::new(), String::new(), vec![]));
    }
    let dom = dom(&payload(record)?)?;
    let mut stack = vec![dom.document.clone()];
    let mut title = String::new();
    let mut links = BTreeSet::new();
    let mut base = url::Url::parse(record.url()).ok();
    while let Some(node) = stack.pop() {
        if node.element_name().as_deref() == Some("base") {
            if let (Some(current), Some(href)) = (&base, attr(&node, "href")) {
                base = current.join(&href).ok();
            }
        }
        if node.element_name().as_deref() == Some("title") {
            title = text(&node)?.trim().into();
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
