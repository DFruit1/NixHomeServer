use super::*;

// https://www.wikidata.org/wiki/Wikidata:Data_access#MediaWiki_API
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let id = request.id.as_deref().or_else(|| {
        request
            .query
            .starts_with('Q')
            .then_some(request.query.as_str())
    });
    let mut params = vec![("format", "json".to_string()), ("maxlag", "5".into())];
    if let Some(id) = id {
        if !id.starts_with('Q') || id.len() < 2 || !id[1..].bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        params.extend([
            ("action", "wbgetentities".into()),
            ("ids", id.into()),
            ("props", "labels|descriptions|claims".into()),
            ("languages", "en".into()),
        ]);
        let body = json_request(
            state,
            identity,
            "wikidata",
            state.client.get(url(state, "wikidata", "")?).query(&params),
        )
        .await?;
        let entity = &body["entities"][id];
        if entity.get("missing").is_some() {
            return Ok(vec![]);
        }
        let title = entity
            .pointer("/labels/en/value")
            .and_then(Value::as_str)
            .unwrap_or(id);
        let mut c = Candidate::new("wikidata", id, title);
        c.subtitle = entity
            .pointer("/descriptions/en/value")
            .and_then(Value::as_str)
            .unwrap_or("")
            .into();
        c.identifier("wikidata", id);
        for (property, provider) in [
            ("P345", "imdb"),
            ("P4835", "tvdb"),
            ("P4947", "tmdb"),
            ("P4983", "tmdb-series"),
            ("P434", "musicbrainz-artist"),
            ("P436", "musicbrainz-release-group"),
            ("P5813", "musicbrainz-release"),
            ("P212", "isbn13"),
            ("P957", "isbn10"),
        ] {
            let values = entity["claims"][property]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|v| text(v, "rank") != "deprecated")
                .filter_map(|v| {
                    v.pointer("/mainsnak/datavalue/value")
                        .and_then(Value::as_str)
                })
                .collect::<BTreeSet<_>>();
            if values.len() == 1 {
                let value = values.into_iter().next().unwrap_or_default();
                let valid = match provider {
                    "imdb" => {
                        value.starts_with("tt") && value[2..].bytes().all(|b| b.is_ascii_digit())
                    }
                    "tvdb" | "tmdb" | "tmdb-series" => {
                        !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())
                    }
                    v if v.starts_with("musicbrainz") => valid_mbid(value),
                    _ => value.bytes().all(|b| b.is_ascii_digit() || b == b'-'),
                };
                if valid {
                    c.identifier(provider, value);
                }
            } else if values.len() > 1 {
                c.evidence.insert(
                    format!("Conflicting {provider} IDs"),
                    values.into_iter().collect::<Vec<_>>().join(", "),
                );
            }
        }
        return Ok(vec![c]);
    }
    params.extend([
        ("action", "wbsearchentities".into()),
        ("search", request.query.clone()),
        ("language", "en".into()),
        ("type", "item".into()),
        ("limit", "20".into()),
        (
            "continue",
            ((request.page.unwrap_or(1).max(1) - 1) * 20).to_string(),
        ),
    ]);
    let body = json_request(
        state,
        identity,
        "wikidata",
        state.client.get(url(state, "wikidata", "")?).query(&params),
    )
    .await?;
    if body.get("error").is_some() {
        return Err(Failure::unavailable());
    }
    Ok(body
        .get("search")
        .and_then(Value::as_array)
        .ok_or_else(Failure::unavailable)?
        .iter()
        .take(MAX_RESULTS)
        .map(|value| {
            let mut c = Candidate::new("wikidata", text(value, "id"), text(value, "label"));
            c.subtitle = text(value, "description").into();
            c.drill_down("entity");
            c
        })
        .collect())
}
