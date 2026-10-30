use super::*;

// https://isbndb.com/apidocs/v2 -- credentials are headers, not returned in candidates.
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let reference = request.id.as_deref().unwrap_or(request.query.trim());
    let cleaned = reference.replace(['-', ' '], "").to_ascii_uppercase();
    let exact = matches!(cleaned.len(), 10 | 13)
        && cleaned.bytes().all(|b| b.is_ascii_digit() || b == b'X');
    if exact && !valid_isbn(&cleaned) {
        return Err(Failure::invalid());
    }
    let mut target = url(state, "isbndb", if exact { "book/" } else { "books/" })?;
    if matches!(reference, "." | "..") {
        return Err(Failure::invalid());
    }
    target
        .path_segments_mut()
        .map_err(|_| Failure::invalid())?
        .pop_if_empty()
        .push(if exact { &cleaned } else { reference });
    let body = json_request(
        state,
        identity,
        "isbndb",
        state
            .client
            .get(target)
            .header("authorization", key)
            .query(&[
                ("pageSize", "20".to_string()),
                ("page", request.page.unwrap_or(1).max(1).to_string()),
            ]),
    )
    .await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    let values = if exact {
        vec![body.get("book").ok_or_else(Failure::unavailable)?]
    } else {
        body.get("books")
            .and_then(Value::as_array)
            .ok_or_else(Failure::unavailable)?
            .iter()
            .take(MAX_RESULTS)
            .collect()
    };
    Ok(values
        .into_iter()
        .filter_map(|v| {
            let isbn = if valid_isbn(text(v, "isbn13")) {
                text(v, "isbn13")
            } else {
                text(v, "isbn")
            };
            if !valid_isbn(isbn) {
                return None;
            }
            let mut c = Candidate::new("isbndb", isbn, text(v, "title"));
            c.subtitle = format!(
                "{} · {} · {}",
                text(v, "publisher"),
                text(v, "edition"),
                text(v, "binding")
            );
            for (field, source) in [
                ("title", "title"),
                ("publisher", "publisher"),
                ("language", "language"),
                ("description", "synopsis"),
            ] {
                c.field(field, text(v, source));
            }
            c.field("authors", list(v, "authors"));
            c.field("isbn", isbn);
            date(&mut c, text(v, "date_published"));
            c.identifier(if isbn.len() == 13 { "isbn13" } else { "isbn10" }, isbn);
            c.evidence
                .insert("Edition / binding".into(), c.subtitle.clone());
            Some(c)
        })
        .collect())
}

fn valid_isbn(value: &str) -> bool {
    let bytes = value.as_bytes();
    match bytes.len() {
        13 if bytes.iter().all(u8::is_ascii_digit) => {
            bytes
                .iter()
                .enumerate()
                .map(|(i, b)| u32::from(b - b'0') * if i % 2 == 0 { 1 } else { 3 })
                .sum::<u32>()
                % 10
                == 0
        }
        10 => {
            let mut sum = 0;
            for (i, b) in bytes.iter().enumerate() {
                let digit = if i == 9 && *b == b'X' {
                    10
                } else if b.is_ascii_digit() {
                    u32::from(b - b'0')
                } else {
                    return false;
                };
                sum += (10 - i as u32) * digit;
            }
            sum % 11 == 0
        }
        _ => false,
    }
}
