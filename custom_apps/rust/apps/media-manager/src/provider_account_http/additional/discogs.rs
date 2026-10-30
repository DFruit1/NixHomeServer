use super::*;

// https://www.discogs.com/developers#page:database
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let token = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let mut params = vec![
        ("per_page", "20".to_string()),
        ("page", request.page.unwrap_or(1).max(1).to_string()),
    ];
    let supplied = request
        .id
        .as_deref()
        .or_else(|| {
            request
                .query
                .starts_with("release:")
                .then_some(request.query.as_str())
        })
        .or_else(|| {
            request
                .query
                .starts_with("master:")
                .then_some(request.query.as_str())
        });
    let (path, kind) = if let Some(id) = supplied {
        let (kind, id) = id.split_once(':').ok_or_else(Failure::invalid)?;
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        match kind {
            "release" => (format!("releases/{id}"), "release"),
            "master" => (format!("masters/{id}/versions"), "versions"),
            _ => return Err(Failure::invalid()),
        }
    } else {
        params.push(("type", "release".into()));
        if let Some(barcode) = request.query.strip_prefix("barcode:") {
            params.push(("barcode", barcode.into()));
        } else if let Some(catalog) = request.query.strip_prefix("catalog:") {
            params.push(("catno", catalog.into()));
        } else {
            params.push(("release_title", request.query.clone()));
        }
        if let Some(artist) = &request.artist {
            params.push(("artist", artist.clone()));
        }
        ("database/search".into(), "search")
    };
    let body = json_request(
        state,
        identity,
        "discogs",
        state
            .client
            .get(url(state, "discogs", &path)?)
            .header("authorization", format!("Discogs token={token}"))
            .query(&params),
    )
    .await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    if kind == "release" {
        let id = number(&body, "id");
        if id.is_empty() {
            return Err(Failure::unavailable());
        }
        let mut c = Candidate::new("discogs", format!("release:{id}"), text(&body, "title"));
        c.subtitle = format!(
            "{} · {} · {}",
            text(&body, "country"),
            text(&body, "released"),
            list(&body, "formats")
        );
        c.field("title", text(&body, "title"));
        c.field("authors", list(&body, "artists"));
        c.field("publisher", list(&body, "labels"));
        c.field("genres", list(&body, "genres"));
        date(&mut c, text(&body, "released"));
        c.identifier("discogs-release", id);
        let master = number(&body, "master_id");
        if master != "0" {
            c.identifier("discogs-master", master);
        }
        let catalogs = body
            .get("labels")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(10)
            .map(|v| format!("{} {}", text(v, "name"), text(v, "catno")))
            .collect::<Vec<_>>()
            .join(" · ");
        c.evidence.insert("Label / catalogue".into(), catalogs);
        c.evidence
            .insert("Country / format".into(), c.subtitle.clone());
        for code in body
            .get("identifiers")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(12)
        {
            if text(code, "type") == "Barcode" {
                c.evidence
                    .insert("Barcode".into(), text(code, "value").into());
            }
        }
        let tracks = body
            .get("tracklist")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(60)
            .map(|v| format!("{} {}", text(v, "position"), text(v, "title")))
            .collect::<Vec<_>>()
            .join("; ");
        c.evidence.insert("Tracks (reference only)".into(), tracks);
        for image in body
            .get("images")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(8)
        {
            artwork(state, identity, &mut c, text(image, "uri"), "cover", "").await;
        }
        return Ok(vec![c]);
    }
    let values = body
        .get(if kind == "versions" {
            "versions"
        } else {
            "results"
        })
        .and_then(Value::as_array)
        .ok_or_else(Failure::unavailable)?;
    Ok(values
        .iter()
        .take(MAX_RESULTS)
        .filter_map(|v| {
            let id = number(v, "id");
            if id.is_empty() {
                return None;
            }
            let mut c = Candidate::new("discogs", format!("release:{id}"), text(v, "title"));
            c.subtitle = format!(
                "{} · {} · {} · {}",
                number(v, "year"),
                text(v, "country"),
                text(v, "catno"),
                list(v, "format")
            );
            c.drill_down("release");
            Some(c)
        })
        .collect())
}
