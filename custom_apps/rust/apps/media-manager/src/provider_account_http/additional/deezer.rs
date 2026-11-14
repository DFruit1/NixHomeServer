use super::*;

// https://developers.deezer.com/api (public catalogue reads need no key).
// Search lists albums; an album ID returns the reviewable release with tracks.
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let Some(id) = &request.id else {
        let query = match request.artist.as_deref().map(str::trim) {
            Some(artist) if !artist.is_empty() => format!("{artist} {}", request.query.trim()),
            _ => request.query.trim().to_string(),
        };
        let body = json_request(
            state,
            identity,
            "deezer",
            state
                .client
                .get(url(state, "deezer", "search/album")?)
                .query(&[
                    ("q", query),
                    ("limit", MAX_RESULTS.to_string()),
                    (
                        "index",
                        ((request.page.unwrap_or(1).max(1) as usize - 1) * MAX_RESULTS).to_string(),
                    ),
                ]),
        )
        .await?;
        check(&body)?;
        let mut out = Vec::new();
        for album in body["data"]
            .as_array()
            .into_iter()
            .flatten()
            .take(MAX_RESULTS)
        {
            let album_id = number(album, "id");
            if album_id.is_empty() || text(album, "title").is_empty() {
                continue;
            }
            let mut c = Candidate::new("deezer", format!("album:{album_id}"), text(album, "title"));
            c.subtitle = format!(
                "{} · {} · {} tracks",
                text(&album["artist"], "name"),
                text(album, "record_type"),
                number(album, "nb_tracks")
            );
            c.drill_down("album");
            out.push(c);
        }
        return Ok(out);
    };
    let album_id = id.strip_prefix("album:").ok_or_else(Failure::invalid)?;
    if album_id.is_empty() || album_id.len() > 20 || !album_id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Failure::invalid());
    }
    let album = json_request(
        state,
        identity,
        "deezer",
        state
            .client
            .get(url(state, "deezer", &format!("album/{album_id}"))?),
    )
    .await?;
    if album.is_null() || album["error"]["code"].as_u64() == Some(800) {
        return Ok(vec![]);
    }
    check(&album)?;
    let title = text(&album, "title");
    if title.is_empty() {
        return Ok(vec![]);
    }
    let mut c = Candidate::new("deezer", format!("album:{album_id}"), title);
    c.subtitle = format!(
        "{} · {} · {}",
        text(&album["artist"], "name"),
        text(&album, "release_date"),
        text(&album, "label")
    );
    c.field("title", title);
    let contributors = list(&album, "contributors");
    c.field(
        "authors",
        if contributors.is_empty() {
            text(&album["artist"], "name").to_string()
        } else {
            contributors
        },
    );
    date(&mut c, text(&album, "release_date"));
    c.field("genres", list(&album["genres"], "data"));
    c.field("publisher", text(&album, "label"));
    c.identifier("deezer-album", album_id);
    c.identifier("barcode", text(&album, "upc"));
    for (label, value) in [
        ("Record type", text(&album, "record_type").to_string()),
        ("UPC", text(&album, "upc").to_string()),
        ("Tracks", number(&album, "nb_tracks")),
    ] {
        if !value.is_empty() {
            c.evidence.insert(label.into(), value);
        }
    }
    let tracks = album["tracks"]["data"]
        .as_array()
        .into_iter()
        .flatten()
        .take(100)
        .enumerate()
        .map(|(index, track)| {
            let seconds = track["duration"].as_u64().unwrap_or(0);
            format!(
                "{}. {} ({}:{:02})",
                index + 1,
                text(track, "title"),
                seconds / 60,
                seconds % 60
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    if !tracks.is_empty() {
        c.evidence
            .insert("Track list".into(), tracks.chars().take(2000).collect());
    }
    artwork(
        state,
        identity,
        &mut c,
        text(&album, "cover_xl"),
        "cover",
        "",
    )
    .await;
    Ok(vec![c])
}

/// Deezer reports quota and parameter errors in a 200 response body.
fn check(body: &Value) -> Result<(), Failure> {
    match body["error"]["code"].as_u64() {
        None => Ok(()),
        Some(4) => Err(Failure::limited()),
        Some(800) => Ok(()),
        Some(_) => Err(Failure::unavailable()),
    }
}
