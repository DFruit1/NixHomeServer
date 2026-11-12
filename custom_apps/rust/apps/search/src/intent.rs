//! Conservative English query instructions. Quoted titles and explicit search
//! syntax stay literal; inferred filters are suggestions, never hidden state.
use std::collections::BTreeMap;

#[derive(Debug, Default)]
pub(crate) struct Intent {
    pub query: String,
    pub filters: BTreeMap<String, String>,
}

pub(crate) fn parse(raw: &str, year: i32) -> Intent {
    let original = raw.trim();
    let mut out = Intent {
        query: original.into(),
        ..Default::default()
    };
    if original.starts_with('"')
        || original.contains([':', '*', '~', '^', '[', ']', '(', ')'])
        || original
            .split_whitespace()
            .any(|s| matches!(s, "AND" | "OR" | "NOT") || s.starts_with(['-', '+']))
    {
        return out;
    }
    let mut rest = original;
    let mut command = false;
    for prefix in [
        "can you find ",
        "could you find ",
        "please find ",
        "show me ",
        "find ",
        "show ",
    ] {
        if rest.to_ascii_lowercase().starts_with(prefix) {
            rest = rest[prefix.len()..].trim();
            command = true;
            break;
        }
    }
    let first_end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let kind = match rest[..first_end].to_ascii_lowercase().as_str() {
        "books" => Some("book"),
        "audiobooks" => Some("audiobook"),
        "emails" | "messages" => Some("email"),
        "movies" | "films" => Some("movie"),
        "videos" => Some("video"),
        "documents" => Some("document"),
        "articles" | "webpages" => Some("web-page"),
        _ => None,
    };
    // A bare noun is also a possible title: only an instruction suffix is clear.
    let tail = rest[first_end..].trim();
    let type_instruction = kind.is_some()
        && (["by ", "from ", "about "]
            .iter()
            .any(|prefix| tail.to_ascii_lowercase().starts_with(prefix))
            || ["last year", "this year"]
                .iter()
                .any(|date| tail.eq_ignore_ascii_case(date)));
    if !command && !type_instruction {
        return out;
    }
    if let Some(kind_name) = kind.filter(|_| command || type_instruction) {
        out.filters.insert("kind".into(), kind_name.into());
        rest = tail;
    }
    if command || type_instruction {
        rest = rest.trim_end_matches(['?', '!']).trim();
    }
    // Calendar years, resolved in the server's local timezone. Date-only titles
    // without an instruction are never reinterpreted.
    for (suffix, target) in [("last year", year - 1), ("this year", year)] {
        let lower = rest.to_ascii_lowercase();
        if lower == suffix || lower.ends_with(&format!(" {suffix}")) {
            let prefix = rest[..rest.len() - suffix.len()].trim_end();
            if prefix.eq_ignore_ascii_case("about") {
                continue;
            }
            rest = prefix;
            if ["from", "during", "in"]
                .iter()
                .any(|word| rest.eq_ignore_ascii_case(word))
            {
                rest = "";
            }

            for word in [" from", " during", " in"] {
                if rest.to_ascii_lowercase().ends_with(word) {
                    rest = rest[..rest.len() - word.len()].trim_end();
                    break;
                }
            }
            out.filters
                .insert("after".into(), format!("{target:04}-01-01"));
            out.filters
                .insert("before".into(), format!("{target:04}-12-31"));
            break;
        }
    }
    for relation in ["by ", "from "] {
        if rest.to_ascii_lowercase().starts_with(relation) && kind.is_some() {
            let value = rest[relation.len()..].trim();
            let about = value.to_ascii_lowercase().find(" about ");
            let creator = about
                .map_or(value, |index| &value[..index])
                .trim()
                .trim_matches('"');
            if !creator.is_empty() && creator.chars().count() <= 160 {
                out.filters.insert("creator".into(), creator.into());
                rest = about.map_or("", |index| value[index + 7..].trim());
            }
            break;
        }
    }
    if rest.to_ascii_lowercase().starts_with("about ") {
        rest = rest[6..].trim();
    }
    // Strip a conversational lead even when it introduced no typed filter.
    out.query = rest.into();
    out
}
