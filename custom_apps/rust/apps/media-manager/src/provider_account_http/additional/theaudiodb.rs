use super::*;

// v1 remains available to free/personal keys; v2 requires premium access.
// https://www.theaudiodb.com/free_music_api
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let key = credentials
        .get("apiKey")
        .filter(|v| !v.is_empty() && v.len() <= 128 && v.bytes().all(|b| b.is_ascii_alphanumeric()))
        .ok_or_else(Failure::rejected)?;
    let reference = request.id.as_deref().unwrap_or(request.query.trim());
    let mut params = Vec::new();
    let artist = reference.starts_with("artist:");
    let script = if let Some(id) = reference.strip_prefix("album:") {
        if !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        params.push(("m", id.to_string()));
        "album.php"
    } else if let Some(id) = reference.strip_prefix("musicbrainz-release-group:") {
        if !valid_mbid(id) {
            return Err(Failure::invalid());
        }
        params.push(("i", id.to_string()));
        "album-mb.php"
    } else if let Some(id) = reference.strip_prefix("artist:") {
        if id.bytes().all(|b| b.is_ascii_digit()) {
            params.push(("i", id.to_string()));
            "artist.php"
        } else {
            params.push(("s", id.to_string()));
            "search.php"
        }
    } else {
        params.push(("a", request.query.clone()));
        if let Some(artist) = &request.artist {
            params.push(("s", artist.clone()));
        }
        "searchalbum.php"
    };
    let body = json_request(
        state,
        identity,
        "theaudiodb",
        state
            .client
            .get(url(state, "theaudiodb", &format!("{key}/{script}"))?)
            .query(&params),
    )
    .await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    let records = body
        .get(if artist { "artists" } else { "album" })
        .ok_or_else(Failure::unavailable)?;
    if records.is_null() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for v in records
        .as_array()
        .ok_or_else(Failure::unavailable)?
        .iter()
        .take(MAX_RESULTS)
    {
        let id = text(v, if artist { "idArtist" } else { "idAlbum" });
        let mut c = Candidate::new(
            "theaudiodb",
            format!("{}:{id}", if artist { "artist" } else { "album" }),
            text(v, if artist { "strArtist" } else { "strAlbum" }),
        );
        c.subtitle = text(v, "strArtist").into();
        if artist {
            c.evidence.insert(
                "Artist biography (reference only)".into(),
                text(v, "strBiographyEN").chars().take(20_000).collect(),
            );
        } else {
            for (field, source) in [
                ("title", "strAlbum"),
                ("authors", "strArtist"),
                ("year", "intYearReleased"),
                ("description", "strDescriptionEN"),
                ("genres", "strGenre"),
                ("publisher", "strLabel"),
            ] {
                c.field(field, text(v, source));
            }
            c.identifier("theaudiodb-album", id);
            if valid_mbid(text(v, "strMusicBrainzID")) {
                c.identifier("musicbrainz-release-group", text(v, "strMusicBrainzID"));
            }
        }
        for (source, role) in if artist {
            vec![
                ("strArtistThumb", "cover"),
                ("strArtistLogo", "logo"),
                ("strArtistFanart", "background"),
            ]
        } else {
            vec![("strAlbumThumb", "cover")]
        } {
            artwork(state, identity, &mut c, text(v, source), role, "").await;
        }
        out.push(c);
    }
    Ok(out)
}
