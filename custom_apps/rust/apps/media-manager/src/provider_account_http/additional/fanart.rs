use super::*;

// https://api.fanart.tv/ (v3.2 supports explicit source namespaces).
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let reference = request.id.as_deref().unwrap_or(request.query.trim());
    let (namespace, id) = reference.split_once(':').ok_or_else(Failure::invalid)?;
    if !valid_id(id) {
        return Err(Failure::invalid());
    }
    if matches!(namespace, "tmdb" | "tvdb") && !id.bytes().all(|b| b.is_ascii_digit())
        || namespace == "imdb"
            && (!id.starts_with("tt")
                || id.len() <= 2
                || !id[2..].bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(Failure::invalid());
    }
    let (path, source) = match namespace {
        "tmdb" => (format!("movies/{id}"), "tmdb"),
        "imdb" => (format!("movies/{id}"), "imdb"),
        "tvdb" => (format!("tv/{id}"), "tvdb"),
        "musicbrainz-artist" if valid_mbid(id) => (format!("music/{id}"), "musicbrainz"),
        "musicbrainz-release-group" if valid_mbid(id) => {
            (format!("music/albums/{id}"), "musicbrainz")
        }
        _ => return Err(Failure::invalid()),
    };
    let mut call = state
        .client
        .get(url(state, "fanart", &path)?)
        .query(&[("source", source)]);
    if let Some(key) = credentials.get("apiKey").filter(|v| !v.is_empty()) {
        call = call.header("api-key", key);
    }
    if let Some(key) = credentials.get("clientKey").filter(|v| !v.is_empty()) {
        call = call.header("client-key", key);
    }
    let body = json_request(state, identity, "fanart", call).await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    if !body.is_object()
        || body.as_object().is_none_or(|v| v.is_empty())
        || body.get("error").is_some()
    {
        return Err(Failure::unavailable());
    }
    let mut c = Candidate::new("fanart", reference, text(&body, "name"));
    if c.title.is_empty() {
        c.title = reference.into();
    }
    c.subtitle = format!("Artwork for {namespace} {id}");
    let containers = std::iter::once(&body).chain(
        body.get("albums")
            .and_then(Value::as_object)
            .into_iter()
            .flat_map(|a| a.values()),
    );
    for container in containers {
        let Some(fields) = container.as_object() else {
            continue;
        };
        for (kind, values) in fields {
            let role = if kind.contains("background") {
                "background"
            } else if kind.contains("logo") || kind.contains("clearart") {
                "logo"
            } else if kind.contains("poster") || kind == "albumcover" {
                "cover"
            } else {
                continue;
            };
            for image in values.as_array().into_iter().flatten().take(12) {
                if c.artwork.len() >= 36 {
                    break;
                }
                artwork(
                    state,
                    identity,
                    &mut c,
                    text(image, "url"),
                    role,
                    text(image, "lang"),
                )
                .await;
            }
        }
    }
    Ok(vec![c])
}
