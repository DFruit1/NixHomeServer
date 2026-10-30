use super::*;

// https://github.com/laxamentumtech/audnexus -- books are addressed by ASIN.
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let asin = request
        .id
        .as_deref()
        .unwrap_or(request.query.trim())
        .trim_start_matches("asin:")
        .to_ascii_uppercase();
    if asin.len() != 10 || !asin.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(Failure::invalid());
    }
    let region = request.region.as_deref().unwrap_or("us");
    if !["us", "uk", "au", "ca", "de", "fr", "in", "it", "jp", "es"].contains(&region) {
        return Err(Failure::invalid());
    }
    let body = json_request(
        state,
        identity,
        "audnexus",
        state
            .client
            .get(url(state, "audnexus", &format!("books/{asin}"))?)
            .query(&[("region", region)]),
    )
    .await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    if text(&body, "title").is_empty() {
        return Err(Failure::unavailable());
    }
    let mut c = Candidate::new("audnexus", &asin, text(&body, "title"));
    c.subtitle = format!("ASIN {asin} · {region} · {}", text(&body, "formatType"));
    for (field, source) in [("title", "title"), ("publisher", "publisherName")] {
        c.field(field, text(&body, source));
    }
    let language = text(&body, "language").to_ascii_lowercase();
    c.field(
        "language",
        match language.as_str() {
            "english" => "en",
            "german" => "de",
            "french" => "fr",
            "spanish" => "es",
            "italian" => "it",
            "japanese" => "ja",
            "portuguese" => "pt",
            "dutch" => "nl",
            _ => &language,
        },
    );
    c.field(
        "description",
        html2text::from_read(text(&body, "description").as_bytes(), 100).unwrap_or_default(),
    );
    c.field("authors", list(&body, "authors"));
    c.field("narrators", list(&body, "narrators"));
    date(&mut c, text(&body, "releaseDate"));
    let series = body
        .get("seriesPrimary")
        .and_then(|v| v.as_array().and_then(|v| v.first()).or(Some(v)))
        .unwrap_or(&Value::Null);
    c.field("series", text(series, "name"));
    c.field("volumeNumber", text(series, "position"));
    c.identifier("asin", asin);
    c.identifier("audnexus-region", region);
    if let Some(value) = body.get("isAdult") {
        c.evidence.insert("Adult content".into(), value.to_string());
    }
    if let Some(value) = body.get("isAbridged").or_else(|| body.get("abridged")) {
        c.evidence.insert("Abridged".into(), value.to_string());
    }
    artwork(state, identity, &mut c, text(&body, "image"), "cover", "").await;
    Ok(vec![c])
}
