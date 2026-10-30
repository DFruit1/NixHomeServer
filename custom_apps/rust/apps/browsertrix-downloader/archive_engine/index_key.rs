//! Compatible with the crawler's warcio 2.4.11 getSurt/appendRequestQuery.
//! Primary source: https://github.com/webrecorder/warcio.js/blob/v2.4.11/src/lib/utils.ts
use serde_json::{Map, Value};

pub(super) fn surt(input: &str) -> String {
    // Upstream leaves non-HTTP targets (native screenshot/text URNs) intact.
    if !input.starts_with("http:") && !input.starts_with("https:") {
        return input.into();
    }
    let normalized = if let Some((scheme, rest)) = input.split_once("://") {
        let rest = rest
            .strip_prefix("www")
            .and_then(|s| {
                let digits = s.bytes().take_while(u8::is_ascii_digit).count();
                s[digits..].strip_prefix('.')
            })
            .unwrap_or(rest);
        format!("{scheme}://{rest}")
    } else {
        input.into()
    };
    let lower = normalized.to_lowercase();
    let Ok(url) = url::Url::parse(&lower) else {
        return input.into();
    };
    let Some(host) = url.host_str() else {
        return input.into();
    };
    let mut key = host.split('.').rev().collect::<Vec<_>>().join(",");
    if let Some(port) = url.port() {
        key.push_str(&format!(":{port}"));
    }
    key.push(')');
    key.push_str(url.path());
    if let Some(query) = url.query().filter(|q| !q.is_empty()) {
        let mut args: Vec<_> = query.split('&').collect();
        // URL serialization is ASCII, matching JavaScript's lexical sort.
        args.sort_unstable();
        key.push('?');
        key.push_str(&args.join("&"));
    }
    key
}

// decodeURI preserves reserved escapes, unlike form or component decoding.
// warcio clears malformed percent/UTF-8 sequences before appendRequestQuery.
fn decode_uri(input: &str) -> Option<String> {
    let mut out = Vec::with_capacity(input.len());
    let data = input.as_bytes();
    let mut p = 0;
    while p < data.len() {
        if data[p] != b'%' {
            out.push(data[p]);
            p += 1;
            continue;
        }
        let hex = std::str::from_utf8(data.get(p + 1..p + 3)?).ok()?;
        let byte = u8::from_str_radix(hex, 16).ok()?;
        if b";/?:@&=+$,#".contains(&byte) {
            out.extend_from_slice(&data[p..p + 3]);
        } else {
            out.push(byte);
        }
        p += 3;
    }
    String::from_utf8(out).ok()
}

pub(super) fn expected(url: &str, row: &Map<String, Value>) -> Result<String, String> {
    let method = match row.get("method") {
        None => "GET",
        Some(Value::String(s))
            if !s.is_empty() && s.bytes().all(|b| b.is_ascii_uppercase() || b == b'-') =>
        {
            s
        }
        _ => return Err("Unsupported CDX request method layout".into()),
    };
    let body = match row.get("requestBody") {
        None => "",
        Some(Value::String(s)) => s,
        _ => return Err("Unsupported CDX requestBody layout".into()),
    };
    if method == "GET" {
        if !body.is_empty() {
            return Err("CDX requestBody without non-GET method unsupported".into());
        }
        return Ok(surt(url));
    }
    if !url.starts_with("http:") && !url.starts_with("https:") {
        return Err("Non-HTTP request-variant CDX layout unsupported".into());
    }
    let query = decode_uri(body).unwrap_or_default();
    let separator = if url.contains('?') { '&' } else { '?' };
    Ok(surt(&format!(
        "{url}{separator}__wb_method={method}&{query}"
    )))
}
