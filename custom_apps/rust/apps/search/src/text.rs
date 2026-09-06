/// Extracts the raw contents of the first `<title>` element in an HTML document.
pub fn html_title(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let start = lower.find("<title")?;
    let open_end = lower[start..].find('>')? + start + 1;
    if lower[start..open_end].ends_with("/>") {
        return None;
    }
    let end = lower[open_end..].find("</title")? + open_end;
    let raw = html.get(open_end..end)?.trim();
    let decoded = decode_entities(raw);
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

/// Converts an HTML document into readable plain text.
pub fn html_to_text(html: &str) -> String {
    let converted = match html2text::from_read(html.as_bytes(), 120) {
        Ok(text) => text,
        Err(_) => return decode_entities(&strip_tags(html)),
    };
    if converted.trim().is_empty() {
        decode_entities(&strip_tags(html))
    } else {
        converted
    }
}

fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut in_comment = false;
    let bytes = html.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if in_comment {
            if html[index..].starts_with("-->") {
                in_comment = false;
                index += 3;
            } else {
                index += 1;
            }
            continue;
        }
        if in_tag {
            if html[index..].starts_with("<!--") {
                in_comment = true;
                index += 4;
                continue;
            }
            if bytes[index] == b'>' {
                in_tag = false;
            }
            index += 1;
            continue;
        }
        if bytes[index] == b'<' {
            if html[index..].starts_with("<!--") {
                in_comment = true;
                index += 4;
                continue;
            }
            in_tag = true;
            index += 1;
            continue;
        }
        out.push(bytes[index] as char);
        index += 1;
    }
    out
}
fn decode_entities(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(pos) = rest.find('&') {
        out.push_str(&rest[..pos]);
        rest = &rest[pos..];
        let end = rest.find(';').unwrap_or(rest.len());
        let entity = &rest[1..end.min(rest.len())];
        let replacement = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            _ => None,
        };
        match replacement {
            Some(ch) if end <= rest.len() && !rest[end..].is_empty() => {
                out.push(ch);
                rest = &rest[end + 1..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Decodes a small set of common HTML entities in already-extracted text.
pub fn decode_html_entities(input: &str) -> String {
    decode_entities(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_title_from_html() {
        assert_eq!(
            html_title("<html><head><TITLE>Hello &amp; World</title></head></html>"),
            Some("Hello & World".to_string())
        );
        assert_eq!(html_title("<html><body>no title</body></html>"), None);
        assert_eq!(html_title("<title>   </title>"), None);
    }

    #[test]
    fn strips_tags_and_comments() {
        let html = "<!-- comment <b>ignored</b> --><p>One</p><style>x{}</style><b>Two</b>";
        let text = html_to_text(html);
        assert!(text.contains("One"));
        assert!(text.contains("Two"));
        assert!(!text.contains("comment"));
        assert!(!text.contains("ignored"));
        assert!(!text.contains("x{}"));
    }

    #[test]
    fn decodes_entities_in_fallback() {
        let text = html_to_text("<div>Fish &amp; Chips</div>");
        assert!(text.contains("Fish & Chips"), "got: {text}");
    }
}
