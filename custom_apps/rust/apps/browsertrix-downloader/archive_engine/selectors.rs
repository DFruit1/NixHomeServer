//! Explicit, bounded CSS subset. Unsupported selectors are rejected, never
//! approximated: lists, descendants, children, tag/#id/.class, attributes and
//! numeric :nth-child(). This is DOM selection, not an HTML sanitizer.
use super::content;
use html2text::Handle;
use std::rc::Rc;

#[derive(Clone)]
struct Compound {
    tag: Option<String>,
    id: Option<String>,
    classes: Vec<String>,
    attrs: Vec<(String, Option<String>)>,
    nth: Option<usize>,
}
#[derive(Clone)]
pub(super) struct Selector(Vec<(Compound, bool)>);
fn identifier(bytes: &[u8], p: &mut usize) -> Result<String, String> {
    let start = *p;
    while *p < bytes.len()
        && (bytes[*p].is_ascii_alphanumeric() || matches!(bytes[*p], b'_' | b'-'))
    {
        *p += 1;
    }
    if *p == start {
        return Err("CSS selector requires a simple ASCII identifier".into());
    }
    Ok(String::from_utf8(bytes[start..*p].to_vec()).unwrap())
}
fn compound(s: &str) -> Result<Compound, String> {
    let b = s.as_bytes();
    let mut p = 0;
    let mut c = Compound {
        tag: None,
        id: None,
        classes: vec![],
        attrs: vec![],
        nth: None,
    };
    if b.first() == Some(&b'*') {
        p += 1;
    } else if b.first().is_some_and(|x| x.is_ascii_alphabetic()) {
        c.tag = Some(identifier(b, &mut p)?.to_ascii_lowercase());
    }
    while p < b.len() {
        match b[p] {
            b'#' => {
                p += 1;
                if c.id.is_some() {
                    return Err("Multiple IDs in CSS selector".into());
                }
                c.id = Some(identifier(b, &mut p)?);
            }
            b'.' => {
                p += 1;
                c.classes.push(identifier(b, &mut p)?);
            }
            b'[' => {
                p += 1;
                let name = identifier(b, &mut p)?.to_ascii_lowercase();
                while b.get(p) == Some(&b' ') {
                    p += 1;
                }
                let mut value = None;
                if b.get(p) == Some(&b'=') {
                    p += 1;
                    while b.get(p) == Some(&b' ') {
                        p += 1;
                    }
                    if matches!(b.get(p), Some(b'\'' | b'"')) {
                        let quote = b[p];
                        p += 1;
                        let start = p;
                        while p < b.len() && b[p] != quote {
                            p += 1;
                        }
                        if p == b.len() {
                            return Err("Unterminated CSS attribute value".into());
                        }
                        value = Some(s[start..p].into());
                        p += 1;
                    } else {
                        value = Some(identifier(b, &mut p)?);
                    }
                }
                while b.get(p) == Some(&b' ') {
                    p += 1;
                }
                if b.get(p) != Some(&b']') {
                    return Err("Unsupported CSS attribute selector".into());
                }
                p += 1;
                c.attrs.push((name, value));
            }
            b':' => {
                if !s[p..].starts_with(":nth-child(") {
                    return Err("Only numeric :nth-child() is supported".into());
                }
                p += 11;
                let start = p;
                while b.get(p).is_some_and(u8::is_ascii_digit) {
                    p += 1;
                }
                let n = s[start..p]
                    .parse::<usize>()
                    .map_err(|_| "Invalid :nth-child index")?;
                if n == 0 || n > 50_000 || b.get(p) != Some(&b')') {
                    return Err("Invalid :nth-child index".into());
                }
                p += 1;
                c.nth = Some(n);
            }
            _ => return Err("Unsupported CSS selector syntax".into()),
        }
    }
    Ok(c)
}
pub(super) fn parse(selectors: &[String]) -> Result<Vec<Selector>, String> {
    if selectors.len() > 32 {
        return Err("At most 32 selector rules".into());
    }
    let mut out = vec![];
    for source in selectors {
        if source.is_empty() || source.len() > 512 || !source.is_ascii() {
            return Err("CSS selector must be 1..512 ASCII bytes".into());
        }
        let mut parts = vec![];
        let mut token = String::new();
        let mut bracket = 0;
        let mut quote = None;
        let mut child = false;
        let flush = |token: &mut String,
                     parts: &mut Vec<(Compound, bool)>,
                     child: &mut bool|
         -> Result<(), String> {
            if !token.is_empty() {
                parts.push((compound(token)?, *child));
                token.clear();
                *child = false;
            }
            Ok(())
        };
        for ch in source.chars().chain(std::iter::once(',')) {
            if let Some(q) = quote {
                token.push(ch);
                if ch == q {
                    quote = None;
                }
                continue;
            }
            if bracket > 0 && matches!(ch, '\'' | '"') {
                quote = Some(ch);
                token.push(ch);
                continue;
            }
            if ch == '[' {
                bracket += 1;
            }
            if ch == ']' {
                bracket -= 1;
            }
            if bracket < 0 || bracket > 1 {
                return Err("Invalid selector brackets".into());
            }
            if bracket == 0 && (ch.is_ascii_whitespace() || ch == '>' || ch == ',') {
                flush(&mut token, &mut parts, &mut child)?;
                if ch == '>' {
                    if parts.is_empty() || child {
                        return Err("Invalid child selector".into());
                    }
                    child = true;
                }
                if ch == ',' {
                    if parts.is_empty() || parts.len() > 16 || child {
                        return Err("Invalid selector list/depth".into());
                    }
                    out.push(Selector(std::mem::take(&mut parts)));
                    if out.len() > 32 {
                        return Err("At most 32 selector alternatives".into());
                    }
                }
            } else {
                token.push(ch);
            }
        }
        if bracket != 0 || quote.is_some() {
            return Err("Unterminated selector".into());
        }
    }
    Ok(out)
}
fn matches_compound(c: &Compound, node: &Handle) -> bool {
    let Some(tag) = node.element_name() else {
        return false;
    };
    if c.tag.as_ref().is_some_and(|t| t != &tag) {
        return false;
    }
    if c.id
        .as_ref()
        .is_some_and(|id| content::attr(node, "id").as_ref() != Some(id))
    {
        return false;
    }
    let classes = content::attr(node, "class").unwrap_or_default();
    if c.classes
        .iter()
        .any(|class| !classes.split_whitespace().any(|s| s == class))
    {
        return false;
    }
    for (name, value) in &c.attrs {
        let actual = content::attr(node, name);
        if actual.is_none() || value.as_ref().is_some_and(|v| actual.as_ref() != Some(v)) {
            return false;
        }
    }
    if let Some(n) = c.nth {
        let Some(parent) = node.get_parent() else {
            return false;
        };
        let index = parent
            .children
            .borrow()
            .iter()
            .filter(|n| n.element_name().is_some())
            .position(|n| Rc::ptr_eq(n, node));
        if index.map(|i| i + 1) != Some(n) {
            return false;
        }
    }
    true
}
fn matches_at(
    parts: &[(Compound, bool)],
    node: &Handle,
    budget: &mut usize,
) -> Result<bool, String> {
    if *budget == 0 {
        return Err("CSS matching work limit exceeded".into());
    }
    *budget -= 1;
    let (last, child) = parts.last().unwrap();
    if !matches_compound(last, node) {
        return Ok(false);
    }
    if parts.len() == 1 {
        return Ok(true);
    }
    let mut parent = node.get_parent();
    while let Some(node) = parent {
        if matches_at(&parts[..parts.len() - 1], &node, budget)? {
            return Ok(true);
        }
        if *child {
            return Ok(false);
        }
        parent = node.get_parent();
    }
    Ok(false)
}
pub(super) fn remove(dom: &html2text::RcDom, rules: &[Selector]) -> Result<usize, String> {
    let mut stack = vec![dom.document.clone()];
    let mut targets = vec![];
    let mut budget = 2_000_000;
    while let Some(node) = stack.pop() {
        for rule in rules {
            if matches_at(&rule.0, &node, &mut budget)? {
                targets.push(node.clone());
                break;
            }
        }
        stack.extend(node.children.borrow().iter().cloned());
    }
    for node in &targets {
        if let Some(parent) = node.get_parent() {
            parent
                .children
                .borrow_mut()
                .retain(|child| !Rc::ptr_eq(child, node));
        }
    }
    Ok(targets.len())
}
