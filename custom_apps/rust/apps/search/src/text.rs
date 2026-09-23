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

/// Number of leading bytes of a document body scanned when building a snippet.
/// Bodies can be multi-megabyte (mail threads, OCR output); the snippet only
/// needs the first query match, so scanning is bounded to protect query latency
/// and memory without storing anything extra.
const SNIPPET_SCAN_LIMIT: usize = 400_000;
/// Target number of characters shown in a body snippet.
const SNIPPET_CHARS: usize = 260;

/// Normalises a query into lowercase alphanumeric terms, in order, deduped.
pub fn query_terms(query: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    for word in query.split_whitespace() {
        let term = word
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase();
        if !term.is_empty() && !terms.contains(&term) {
            terms.push(term);
        }
    }
    terms
}

/// Builds a short plain-text snippet around the first query term and wraps every
/// query term present in it in `<em>` tags, the same highlight markup Solr used
/// to emit, so the UI has one rendering path for every source. The text is
/// HTML-escaped before the markers are inserted, so a body that literally
/// contains `<em>` cannot masquerade as a highlight and no other markup can leak
/// through. Returns `None` when no term is present or the text is empty.
pub fn snippet_from_text(text: &str, query: &str) -> Option<String> {
    let terms = query_terms(query);
    let needle = terms.first()?;
    let text = text
        .get(..text.len().min(SNIPPET_SCAN_LIMIT))
        .unwrap_or(text);
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let (position, needle_len) = find_case_insensitive_from(text, 0, needle)?;
    let start = position.saturating_sub(60);
    let end = (position + needle_len + SNIPPET_CHARS).min(text.len());
    let window = &text[snap_to_boundary(text, start)..snap_to_boundary(text, end)];
    let window = window.trim();
    if window.is_empty() {
        None
    } else {
        Some(highlight_terms(window, &terms))
    }
}

/// Converts HTML to text (bounded by `html_limit` bytes) then snippets it. Used
/// by runtime-federated sources that fetch the document body on demand.
pub fn snippet_from_html(html: &str, query: &str, html_limit: usize) -> Option<String> {
    let truncated = html.get(..html.len().min(html_limit)).unwrap_or(html);
    snippet_from_text(&html_to_text(truncated), query)
}

/// Wraps every case-insensitive occurrence of each term in `<em>` tags so
/// snippets render through one UI path. Matches never overlap: terms are applied
/// left to right over plain text. The non-marker text is HTML-escaped, so the
/// returned string is safe to insert as HTML; a literal `<em>` in the source
/// becomes `&lt;em&gt;` and is never mistaken for a highlight.
pub fn highlight_terms(text: &str, terms: &[String]) -> String {
    if terms.is_empty() {
        return escape_html(text);
    }
    let mut marked = String::with_capacity(text.len());
    let mut cursor = 0;
    while let Some((start, end)) = terms
        .iter()
        .filter_map(|term| find_case_insensitive_from(text, cursor, term))
        .min_by_key(|&(start, _)| start)
    {
        marked.push_str(&escape_html(&text[cursor..start]));
        marked.push_str("<em>");
        marked.push_str(&escape_html(&text[start..end]));
        marked.push_str("</em>");
        cursor = end;
    }
    marked.push_str(&escape_html(&text[cursor..]));
    marked
}

/// Escapes the five HTML-significant characters so snippet text can be inserted
/// into markup without carrying any structure of its own.
fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Case-insensitive byte-span search for `needle` at or after `from`, returning
/// (start, end) offsets into `haystack`. Only matches when lowercasing both
/// sides preserves the byte layout, so returned offsets are always valid
/// character boundaries; exotic casing expansions (e.g. 'İ') are skipped as a
/// cosmetic no-op rather than risking misplaced or invalid spans.
fn find_case_insensitive_from(haystack: &str, from: usize, needle: &str) -> Option<(usize, usize)> {
    let hay = haystack.get(from..)?;
    let hay_lower = hay.to_lowercase();
    let needle_lower = needle.to_lowercase();
    if hay_lower.len() != hay.len() || needle_lower.len() != needle.len() {
        return None;
    }
    hay_lower
        .find(&needle_lower)
        .map(|at| (from + at, from + at + needle_lower.len()))
}

/// Clamps a byte offset to a UTF-8 character boundary.
fn snap_to_boundary(value: &str, byte: usize) -> usize {
    let byte = byte.min(value.len());
    let mut boundary = byte;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    boundary
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

    #[test]
    fn normalises_query_terms() {
        assert_eq!(
            query_terms("Quantum  computing!!"),
            vec!["quantum", "computing"]
        );
        assert_eq!(query_terms("a b a"), vec!["a", "b"]);
        assert_eq!(query_terms("!!!"), Vec::<String>::new());
    }

    #[test]
    fn finds_spans_case_insensitively() {
        assert_eq!(
            find_case_insensitive_from("Hello World", 0, "world"),
            Some((6, 11))
        );
        assert_eq!(
            find_case_insensitive_from("Hello World", 0, "WORLD"),
            Some((6, 11))
        );
        assert_eq!(find_case_insensitive_from("Hello World", 0, "xyz"), None);
        assert_eq!(
            find_case_insensitive_from("ab cd ab", 3, "ab"),
            Some((6, 8))
        );
        assert_eq!(find_case_insensitive_from("ab", 2, "ab"), None);
    }

    #[test]
    fn highlights_terms_like_solr() {
        assert_eq!(
            highlight_terms("about quantum physics", &["quantum".to_string()]),
            "about <em>quantum</em> physics"
        );
        assert_eq!(
            highlight_terms(
                "Quantum COMPUTING notes",
                &["quantum".to_string(), "computing".to_string()]
            ),
            "<em>Quantum</em> <em>COMPUTING</em> notes"
        );
        assert_eq!(
            highlight_terms("a b a", &["a".to_string()]),
            "<em>a</em> b <em>a</em>"
        );
        assert_eq!(
            highlight_terms("plain text", &["zebra".to_string()]),
            "plain text"
        );
    }

    #[test]
    fn snaps_to_char_boundaries() {
        let value = "héllo wörld";
        let snapped = snap_to_boundary(value, 3);
        assert!(value.is_char_boundary(snapped));
        assert_eq!(snap_to_boundary(value, 0), 0);
        assert_eq!(snap_to_boundary(value, value.len() + 5), value.len());
    }

    #[test]
    fn builds_plain_text_snippets_around_keyword() {
        let text = "This is a long article about quantum computing and other topics.";
        let snippet = snippet_from_text(text, "quantum").expect("snippet");
        assert!(snippet.contains("<em>quantum</em>"));
        assert!(snippet.contains("computing"));
        assert_eq!(snippet_from_text(text, "zebra"), None);
        assert_eq!(snippet_from_text(text, "!!!"), None);
        assert_eq!(snippet_from_text("", "quantum"), None);
        // Multi-term queries highlight every term present.
        let multi = snippet_from_text(text, "QUANTUM other").expect("multi");
        assert!(multi.contains("<em>quantum</em>") && multi.contains("<em>other</em>"));
    }

    #[test]
    fn snippet_slicing_survives_multibyte_boundary() {
        let filler = "é".repeat(2000);
        let text = format!("about quantum physics {filler}");
        let snippet = snippet_from_text(&text, "quantum").expect("snippet");
        assert!(snippet.contains("quantum"));
    }

    #[test]
    fn snippets_from_html_bounded() {
        let html = "<html><body><p>Quarterly <b>report</b> attached</p></body></html>";
        let snippet = snippet_from_html(html, "report", 200_000).expect("snippet");
        assert!(snippet.contains("<em>report</em>"));
        assert_eq!(snippet_from_html("", "report", 200_000), None);
    }

    #[test]
    fn snippet_escapes_markup_but_keeps_highlights() {
        let text = "literal <em>tag</em> and quantum & more";
        let snippet = snippet_from_text(text, "quantum").expect("snippet");
        // The query term is still highlighted...
        assert!(snippet.contains("<em>quantum</em>"));
        // ...while literal markup and ampersands in the body are escaped so they
        // cannot masquerade as a highlight or inject structure.
        assert!(snippet.contains("&lt;em&gt;tag&lt;/em&gt;"));
        assert!(snippet.contains("&amp; more"));
        assert!(!snippet.contains("literal <em>tag"));
    }
}
