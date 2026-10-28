/// Truncates text by bytes without splitting a UTF-8 character.
pub fn truncate_text(text: &str, limit: usize) -> String {
    text[..text.floor_char_boundary(limit.min(text.len()))].to_string()
}

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

/// Maximum number of leading document bytes examined when building a snippet.
/// Bodies can be multi-megabyte (mail threads, OCR output); matching is bounded
/// to protect query latency and memory. The bound is applied *before* matching
/// and rounded down to a UTF-8 boundary, so no match outside it can be returned
/// and nothing beyond it is ever scanned.
const SNIPPET_SCAN_LIMIT: usize = 400_000;
/// Maximum number of Unicode scalar values shown in a body snippet.
const SNIPPET_CHARS: usize = 260;
/// Maximum number of scalar values of context shown before the selected match.
const SNIPPET_LEAD: usize = 60;

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

/// Returns at most `limit` bytes of `text`, rounded down to a character
/// boundary. The scan bound is a hard input limit, never a hint: a document that
/// does not slice cleanly inside the limit is truncated rather than scanned in
/// full.
fn bounded_prefix(text: &str, limit: usize) -> &str {
    &text[..snap_to_boundary(text, limit)]
}

/// Finds the first query-order term that actually occurs in `body`, with its
/// (start, end) byte span. Terms absent from the body are skipped so a body that
/// only mentions a later term still gets a snippet; query order still wins when
/// several terms are present. The bounded body is lowercased once for the whole
/// selection instead of once per term.
fn first_present_term_span<'a>(body: &str, terms: &'a [String]) -> Option<(&'a str, usize, usize)> {
    // `to_lowercase` can expand a scalar value, which would shift byte offsets
    // away from `body`. In that case fall back to the per-call helper, which
    // declines to match such text exactly as before.
    let lowered = body.to_lowercase();
    let aligned = lowered.len() == body.len();
    for term in terms {
        if aligned {
            if let Some(at) = lowered.find(term.as_str()) {
                return Some((term.as_str(), at, at + term.len()));
            }
        } else if let Some((start, end)) = find_case_insensitive_from(body, 0, term) {
            return Some((term.as_str(), start, end));
        }
    }
    None
}

/// Byte range of the presentation window: at most `SNIPPET_CHARS` scalar values
/// of the original plain text, starting at most `SNIPPET_LEAD` scalar values
/// before `match_start` (near the start only the available prefix is used).
/// Both boundaries fall on UTF-8 character boundaries.
fn snippet_window_bounds(text: &str, match_start: usize) -> (usize, usize) {
    let match_start = snap_to_boundary(text, match_start);
    let first = text[..match_start]
        .chars()
        .count()
        .saturating_sub(SNIPPET_LEAD);
    let mut start = 0;
    let mut end = text.len();
    for (index, (byte, _)) in text.char_indices().enumerate() {
        if index == first {
            start = byte;
        }
        if index == first + SNIPPET_CHARS {
            end = byte;
            break;
        }
    }
    (start, end)
}

/// Builds a short plain-text snippet around the first query-order term present
/// in the bounded body and wraps every query term present in the window in
/// `<em>` tags, the same highlight markup Solr used to emit, so the UI has one
/// rendering path for every source. The visible window is at most
/// `SNIPPET_CHARS` scalar values, never grows to fit a long term, and the text is
/// HTML-escaped before the markers are inserted, so a body that literally
/// contains `<em>` cannot masquerade as a highlight and no other markup can leak
/// through. Returns `None` when no eligible term is present in the bounded body
/// or the text is empty.
pub fn snippet_from_text(text: &str, query: &str) -> Option<String> {
    let terms = query_terms(query);
    if terms.is_empty() {
        return None;
    }
    let body = bounded_prefix(text, SNIPPET_SCAN_LIMIT).trim();
    if body.is_empty() {
        return None;
    }
    let (term, match_start, match_end) = first_present_term_span(body, &terms)?;
    let match_end = snap_to_boundary(body, match_end);
    let (start, end) = snippet_window_bounds(body, match_start);
    let window = body[start..end].trim();
    if window.is_empty() {
        return None;
    }
    if match_end > end {
        // A term longer than the window is truncated at the window edge. It is
        // not marked up as a partial highlight and the window is not extended.
        let others: Vec<String> = terms
            .iter()
            .filter(|candidate| candidate.as_str() != term)
            .cloned()
            .collect();
        return Some(highlight_terms(window, &others));
    }
    Some(highlight_terms(window, &terms))
}

/// Converts HTML to text (bounded by `html_limit` bytes, rounded down to a
/// character boundary) then snippets it. Used by runtime-federated sources that
/// fetch the document body on demand.
pub fn snippet_from_html(html: &str, query: &str, html_limit: usize) -> Option<String> {
    snippet_from_text(&html_to_text(bounded_prefix(html, html_limit)), query)
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

    /// Visible characters of a snippet: the generated markers removed, escaped
    /// entities still counted as the characters their source form occupies here
    /// (this helper is only used on snippet text without escapable characters).
    fn visible_text(snippet: &str) -> String {
        snippet.replace("<em>", "").replace("</em>", "")
    }

    #[test]
    fn snippet_uses_first_query_term_present_in_body() {
        // Regression: only the first query term was tried, so a body that only
        // contains a later term returned no snippet at all.
        let snippet =
            snippet_from_text("A computing report", "quantum computing").expect("snippet");
        assert!(snippet.contains("<em>computing</em>"), "got: {snippet}");

        let snippet = snippet_from_text("A quantum report", "quantum computing").expect("snippet");
        assert!(snippet.contains("<em>quantum</em>"), "got: {snippet}");

        // Single-term, mixed-case, no-match and no-eligible-term controls keep
        // their existing semantics.
        let upper = snippet_from_text("A QUANTUM report", "quantum").expect("snippet");
        assert!(upper.contains("<em>QUANTUM</em>"), "got: {upper}");
        assert_eq!(snippet_from_text("A quantum report", "zebra"), None);
        assert_eq!(snippet_from_text("A quantum report", "!!!"), None);
        assert_eq!(snippet_from_text("", "quantum"), None);
    }

    #[test]
    fn snippet_prefers_earlier_query_order_term_when_both_present() {
        let text = format!("quantum {}computing", "filler ".repeat(100));
        let forward = snippet_from_text(&text, "quantum computing").expect("snippet");
        assert!(forward.contains("<em>quantum</em>"), "got: {forward}");
        assert!(
            !visible_text(&forward).contains("computing"),
            "window must centre on the first query-order term: {forward}"
        );
        // Reversing the query order centres on the term that is now first.
        let reversed = snippet_from_text(&text, "computing quantum").expect("snippet");
        assert!(reversed.contains("<em>computing</em>"), "got: {reversed}");
        assert!(
            !visible_text(&reversed).contains("quantum"),
            "got: {reversed}"
        );
    }

    #[test]
    fn snippet_window_bounds_late_ascii_match() {
        // Regression: a late match produced a window measured from the match end
        // as if the match-end offset were a length, inflating the snippet.
        let text = format!("{}needle {}", "line ".repeat(200), "trailing ".repeat(300));
        let snippet = snippet_from_text(&text, "needle").expect("snippet");
        assert!(snippet.contains("<em>needle</em>"), "got: {snippet}");
        let visible = visible_text(&snippet);
        assert!(
            visible.chars().count() <= 260,
            "visible length {} exceeded the window: {visible}",
            visible.chars().count()
        );
        // The window keeps context on both sides of a late match.
        assert!(visible.starts_with("line"), "got: {visible}");
        assert!(visible.contains("needle trailing"), "got: {visible}");
    }

    #[test]
    fn snippet_window_handles_multibyte_context_and_edges() {
        // A match at the very start shows only the available prefix.
        let at_start = snippet_from_text("needle at the start", "needle").expect("snippet");
        assert!(at_start.starts_with("<em>needle</em>"), "got: {at_start}");

        // Multibyte context stays valid UTF-8 and inside the scalar budget, with
        // at most 60 scalar values of lead context.
        let text = format!("{}needle{}", "é".repeat(300), "ü".repeat(300));
        let snippet = snippet_from_text(&text, "needle").expect("snippet");
        let visible = visible_text(&snippet);
        assert!(snippet.contains("<em>needle</em>"), "got: {snippet}");
        assert!(
            !visible.contains('\u{fffd}'),
            "invalid UTF-8 leaked: {visible}"
        );
        assert_eq!(
            visible.chars().count(),
            260,
            "window should use the full budget: {visible}"
        );
        let lead = visible.chars().take_while(|ch| *ch == 'é').count();
        assert!(lead <= 60, "lead context {lead} exceeded 60: {visible}");

        // A match at the very end still shows trailing-free context.
        let at_end = format!("{}needle", "é".repeat(300));
        let snippet = snippet_from_text(&at_end, "needle").expect("snippet");
        assert!(snippet.contains("<em>needle</em>"), "got: {snippet}");
    }

    #[test]
    fn snippet_truncates_overlong_match_without_extending_window() {
        let term = "n".repeat(400);
        let text = format!("prefix {term} suffix");
        let snippet = snippet_from_text(&text, &term).expect("snippet");
        let visible = visible_text(&snippet);
        assert_eq!(
            visible.chars().count(),
            260,
            "window must not grow for an overlong term: {visible}"
        );
        assert!(visible.starts_with("prefix nnn"), "got: {visible}");
        assert_eq!(
            snippet.matches("<em>").count(),
            snippet.matches("</em>").count(),
            "unbalanced emphasis: {snippet}"
        );
        // The truncated match is not presented as a partial highlight.
        assert!(
            !snippet.contains("<em>"),
            "partial-match emphasis: {snippet}"
        );
    }

    #[test]
    fn snippet_scan_limit_rejects_split_multibyte_boundary() {
        // Regression: a two-byte character straddling the scan cap made the
        // scanner fall back to the unbounded body, exposing beyond-cap matches.
        let mut text = "a".repeat(SNIPPET_SCAN_LIMIT - 1);
        text.push('é');
        text.push_str(&"z".repeat(1_000));
        text.push_str("needle");
        assert!(text.len() > SNIPPET_SCAN_LIMIT);
        assert_eq!(snippet_from_text(&text, "needle"), None);
    }

    #[test]
    fn snippet_scan_limit_keeps_matches_inside_cap() {
        let mut text = "a".repeat(SNIPPET_SCAN_LIMIT - 6);
        text.push_str("needle");
        text.push_str(&"z".repeat(2_000));
        let snippet = snippet_from_text(&text, "needle").expect("snippet");
        assert!(snippet.contains("<em>needle</em>"), "got: {snippet}");
        assert!(visible_text(&snippet).chars().count() <= 260);
    }

    #[test]
    fn snippet_from_html_respects_html_limit_boundaries() {
        // Zero limit converts nothing, so there is nothing to match.
        let plain = format!("<p>{}</p>", "a".repeat(200));
        assert_eq!(snippet_from_html(&plain, "a", 0), None);

        let mut html = "<p>".to_string();
        html.push_str(&"a".repeat(100));
        html.push('é');
        html.push_str("needle</p>");

        // Limit landing inside the multibyte character rounds down instead of
        // converting the unbounded document.
        let split_limit = 3 + 100 + 1;
        assert!(html.is_char_boundary(3 + 100));
        assert!(!html.is_char_boundary(split_limit));
        assert_eq!(snippet_from_html(&html, "needle", split_limit), None);

        // Exact boundary before the term: the term is still outside the bound.
        assert_eq!(snippet_from_html(&html, "needle", 3 + 100 + 2), None);

        // Exact boundary that includes the whole term.
        let inside =
            snippet_from_html(&html, "needle", 3 + 100 + 2 + "needle".len()).expect("snippet");
        assert!(inside.contains("<em>needle</em>"), "got: {inside}");
    }

    #[test]
    fn snippet_escapes_script_and_literal_markup() {
        let text = "<script>alert('x')</script> quantum & \"quoted\" <em>fake</em>";
        let snippet = snippet_from_text(text, "quantum").expect("snippet");
        assert!(snippet.contains("<em>quantum</em>"), "got: {snippet}");
        assert!(snippet.contains("&lt;script&gt;"), "got: {snippet}");
        assert!(snippet.contains("&amp;"), "got: {snippet}");
        assert!(snippet.contains("&quot;quoted&quot;"), "got: {snippet}");
        assert!(
            snippet.contains("&lt;em&gt;fake&lt;/em&gt;"),
            "got: {snippet}"
        );
        assert!(
            !snippet.contains("<script>"),
            "raw script leaked: {snippet}"
        );
        assert!(
            !snippet.contains("<em>fake"),
            "literal em promoted: {snippet}"
        );
    }

    #[test]
    fn snippet_escapes_tag_like_query_terms() {
        let snippet = snippet_from_text("the <script> tag body", "<script>").expect("snippet");
        assert!(
            snippet.contains("&lt;<em>script</em>&gt;"),
            "got: {snippet}"
        );
        assert!(!snippet.contains("<script>"), "raw tag leaked: {snippet}");
    }
}
