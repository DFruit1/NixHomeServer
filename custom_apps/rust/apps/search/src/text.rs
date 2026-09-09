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
    let mut rest = html;
    let mut in_tag = false;
    let mut in_comment = false;
    // Slicing only at offsets returned by `find` keeps every slice on a UTF-8
    // char boundary. The previous byte-indexing version panicked on any
    // non-ASCII byte inside a tag or comment, which the indexer surfaced as a
    // failed extraction for the whole source.
    while !rest.is_empty() {
        if in_comment {
            match rest.find("-->") {
                Some(end) => {
                    rest = &rest[end + 3..];
                    in_comment = false;
                }
                None => break,
            }
            continue;
        }
        if in_tag {
            if rest.starts_with("<!--") {
                in_comment = true;
                rest = &rest[4..];
                continue;
            }
            match rest.find('>') {
                Some(end) => {
                    rest = &rest[end + 1..];
                    in_tag = false;
                }
                None => break,
            }
            continue;
        }
        match rest.find('<') {
            Some(start) => {
                out.push_str(&rest[..start]);
                if rest[start..].starts_with("<!--") {
                    in_comment = true;
                    rest = &rest[start + 4..];
                } else {
                    in_tag = true;
                    rest = &rest[start + 1..];
                }
            }
            None => {
                out.push_str(rest);
                break;
            }
        }
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
    fn strip_tags_keeps_non_ascii_text() {
        // The byte-indexing implementation also mangled non-ASCII text into
        // per-byte Latin-1 chars; whole-slice handling must preserve it.
        assert_eq!(strip_tags("<p>El niño está aquí</p>"), "El niño está aquí");
    }

    #[test]
    fn strip_tags_survives_non_ascii_inside_tags_and_comments() {
        // Regression: every one of these panicked before the fix (mid-UTF-8
        // byte slices), which wedged the whole source extraction.
        assert_eq!(strip_tags(r#"<p title="日本語テキスト">x</p>"#), "x");
        assert_eq!(strip_tags("<!-- überspringen --><img src=\"a.png\">"), "");
        assert_eq!(
            strip_tags(
                r#"<html><head><meta content="café"></head><body><img src="a.png"></body></html>"#
            ),
            ""
        );
    }

    #[test]
    fn strip_tags_handles_unterminated_markup() {
        assert_eq!(strip_tags("<p>kept"), "kept");
        assert_eq!(strip_tags("<p unterminated-attr=\"x"), "");
        assert_eq!(strip_tags("<!-- unterminated"), "");
        assert_eq!(strip_tags("trailing <"), "trailing ");
    }

    #[test]
    fn html_to_text_fallback_survives_non_ascii_attributes() {
        // Image-only page: whether html2text renders or the strip_tags fallback
        // runs, neither path may panic or leak per-byte Latin-1 mojibake.
        let text =
            html_to_text(r#"<html><body><img src="a.png" alt="café über 这个"></body></html>"#);
        assert!(!text.contains("Ã©"), "mojibake leaked: {text}");
    }

    #[test]
    fn decodes_entities_in_fallback() {
        let text = html_to_text("<div>Fish &amp; Chips</div>");
        assert!(text.contains("Fish & Chips"), "got: {text}");
    }
}
