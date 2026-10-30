use super::*;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub(super) struct Token {
    pub owner: String,
    value: Zeroizing<String>,
    expires: Instant,
}

// https://github.com/thetvdb/v4-api/blob/master/docs/swagger.yml
pub(super) async fn token(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
) -> Result<Zeroizing<String>, Failure> {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let mut hasher = Sha256::new();
    hasher.update(identity.subject.as_bytes());
    for (name, value) in credentials {
        hasher.update(name.as_bytes());
        hasher.update([0]);
        hasher.update(value.as_bytes());
        hasher.update([0]);
    }
    let version = format!("{:x}", hasher.finalize());
    {
        let mut tokens = state.additional.tokens.lock().await;
        tokens.retain(|_, v| v.expires > Instant::now());
        if let Some(token) = tokens.get(&version) {
            return Ok(Zeroizing::new(token.value.to_string()));
        }
    }
    let mut login = json!({"apikey":key});
    if let Some(pin) = credentials.get("pin").filter(|v| !v.trim().is_empty()) {
        login["pin"] = json!(pin);
    }
    let result = json_request(
        state,
        identity,
        "tvdb",
        state.client.post(url(state, "tvdb", "login")?).json(&login),
    )
    .await;
    // The owned JSON request contains credentials too; overwrite its strings after send.
    if let Some(fields) = login.as_object_mut() {
        for value in fields.values_mut() {
            if let Value::String(v) = value {
                v.zeroize();
            }
        }
    }
    let mut body = result?;
    let value = body
        .pointer("/data/token")
        .and_then(Value::as_str)
        .map(str::to_string)
        .filter(|v| !v.is_empty())
        .ok_or_else(Failure::unavailable)?;
    if let Some(Value::String(token)) = body.pointer_mut("/data/token") {
        token.zeroize();
    }
    let mut tokens = state.additional.tokens.lock().await;
    if tokens.len() >= 256 {
        tokens.clear();
    }
    tokens.insert(
        version,
        Token {
            owner: identity.subject.clone(),
            value: Zeroizing::new(value.clone()),
            expires: Instant::now() + Duration::from_secs(20 * 86400),
        },
    );
    Ok(Zeroizing::new(value))
}

async fn get(
    state: &ProviderBrokerState,
    identity: &Identity,
    token: &str,
    path: &str,
) -> Result<Value, Failure> {
    json_request(
        state,
        identity,
        "tvdb",
        state
            .client
            .get(url(state, "tvdb", path)?)
            .bearer_auth(token),
    )
    .await
}

pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let bearer = token(state, identity, credentials).await?;
    let language = request.language.as_deref().unwrap_or("eng");
    let order = request.order.as_deref().unwrap_or("official");
    if language.len() != 3
        || !language.bytes().all(|b| b.is_ascii_lowercase())
        || !matches!(order, "official" | "dvd" | "absolute")
    {
        return Err(Failure::invalid());
    }
    if request.id.is_none() {
        let params = [
            ("query", request.query.clone()),
            ("limit", "20".into()),
            (
                "offset",
                ((request.page.unwrap_or(1).max(1) - 1) * 20).to_string(),
            ),
        ];
        let body = json_request(
            state,
            identity,
            "tvdb",
            state
                .client
                .get(url(state, "tvdb", "search")?)
                .bearer_auth(&*bearer)
                .query(&params),
        )
        .await?;
        let values = body
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(Failure::unavailable)?;
        return Ok(values
            .iter()
            .filter_map(|v| {
                let kind = text(v, "type");
                if !matches!(kind, "series" | "movie") {
                    return None;
                }
                let id = text(v, "tvdb_id");
                if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                let mut c = Candidate::new("tvdb", format!("{kind}:{id}"), text(v, "name"));
                c.subtitle = format!("{} · {} · {}", kind, text(v, "year"), text(v, "country"));
                c.drill_down(kind);
                Some(c)
            })
            .take(MAX_RESULTS)
            .collect());
    }
    let pieces = request
        .id
        .as_deref()
        .unwrap_or_default()
        .split(':')
        .collect::<Vec<_>>();
    if pieces.len() < 2
        || !matches!(pieces[0], "movie" | "series" | "episode")
        || !pieces[1].bytes().all(|b| b.is_ascii_digit())
    {
        return Err(Failure::invalid());
    }
    let kind = pieces[0];
    let id = pieces[1];
    let path = format!(
        "{}{id}/extended",
        match kind {
            "movie" => "movies/",
            "series" => "series/",
            _ => "episodes/",
        }
    );
    let body = get(state, identity, &bearer, &path).await?;
    if body.is_null() {
        return Ok(vec![]);
    }
    let data = body
        .get("data")
        .filter(|v| v.is_object())
        .ok_or_else(Failure::unavailable)?;
    let mut c = Candidate::new(
        "tvdb",
        request.id.as_deref().unwrap_or_default(),
        text(data, "name"),
    );
    c.subtitle = format!("TheTVDB {kind} {id} · {order} · {language}");
    c.field("title", text(data, "name"));
    c.field("mediaType", kind);
    c.field("description", text(data, "overview"));
    c.field("genres", list(data, "genres"));
    date(
        &mut c,
        text(
            data,
            if kind == "movie" {
                "year"
            } else {
                "firstAired"
            },
        ),
    );
    c.identifier(
        if kind == "episode" {
            "tvdb-episode"
        } else {
            "tvdb"
        },
        id,
    );
    for remote in data
        .get("remoteIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let source = text(remote, "sourceName").to_ascii_lowercase();
        let value = text(remote, "id");
        if source.contains("imdb") && value.starts_with("tt") {
            c.identifier("imdb", value);
        }
        if source.contains("themoviedb") && value.bytes().all(|b| b.is_ascii_digit()) {
            c.identifier(
                if kind == "series" {
                    "tmdb-series"
                } else {
                    "tmdb"
                },
                value,
            );
        }
    }
    if language != "eng" {
        let translated = get(
            state,
            identity,
            &bearer,
            &format!(
                "{}{id}/translations/{language}",
                match kind {
                    "series" => "series/",
                    "movie" => "movies/",
                    _ => "episodes/",
                }
            ),
        )
        .await?;
        if let Some(trans) = translated.get("data") {
            c.field("title", text(trans, "name"));
            c.field("description", text(trans, "overview"));
        }
    }
    if kind == "episode" {
        let series = number(data, "seriesId");
        if !series.is_empty() {
            let series_body = get(state, identity, &bearer, &format!("series/{series}")).await?;
            c.field(
                "episodeTitle",
                c.fields.get("title").cloned().unwrap_or_default(),
            );
            c.field("title", text(&series_body["data"], "name"));
            c.field("series", text(&series_body["data"], "name"));
            c.identifier("tvdb", series);
        }
        c.field("season", pieces.get(2).copied().unwrap_or_else(|| ""));
        c.field("episode", pieces.get(3).copied().unwrap_or_else(|| ""));
        if !c.fields.contains_key("season") {
            c.field("season", number(data, "seasonNumber"));
        }
        if !c.fields.contains_key("episode") {
            c.field("episode", number(data, "number"));
        }
        date(&mut c, text(data, "aired"));
    }
    for art in data
        .get("artworks")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(12)
    {
        // Only cover types are installed here; fanart offers explicit role choices.
        if art
            .get("type")
            .and_then(Value::as_u64)
            .is_some_and(|v| matches!(v, 2 | 7 | 14))
        {
            artwork(
                state,
                identity,
                &mut c,
                text(art, "image"),
                "cover",
                text(art, "language"),
            )
            .await;
        }
    }
    let mut results = vec![c];
    if kind == "series" {
        let offset = pieces
            .get(2)
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        let page = pieces
            .get(3)
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(request.page.unwrap_or(1).max(1) - 1);
        if offset > 5000 || page > 100 {
            return Err(Failure::invalid());
        }
        let episodes = get(
            state,
            identity,
            &bearer,
            &format!("series/{id}/episodes/{order}/{language}?page={page}"),
        )
        .await?;
        for ep in episodes
            .pointer("/data/episodes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .skip(offset)
            .take(MAX_RESULTS - 2)
        {
            let ep_id = number(ep, "id");
            if ep_id.is_empty() {
                continue;
            }
            let season = number(ep, "seasonNumber");
            let episode = number(ep, "number");
            let mut child = Candidate::new(
                "tvdb",
                format!("episode:{ep_id}:{season}:{episode}"),
                text(ep, "name"),
            );
            child.subtitle = format!("S{season} E{episode} · {order}");
            child.drill_down("episode");
            results.push(child);
        }
        let count = episodes
            .pointer("/data/episodes")
            .and_then(Value::as_array)
            .map(Vec::len)
            .unwrap_or(0);
        let more = if offset + MAX_RESULTS - 2 < count {
            Some((offset + MAX_RESULTS - 2, page))
        } else if episodes
            .pointer("/links/next")
            .and_then(Value::as_str)
            .is_some_and(|v| !v.is_empty())
            && page < 100
        {
            Some((0, page + 1))
        } else {
            None
        };
        if let Some((offset, page)) = more {
            let mut more = Candidate::new(
                "tvdb",
                format!("series:{id}:{offset}:{page}"),
                "More episodes",
            );
            more.subtitle = format!("Continue {order} order");
            more.drill_down("page");
            results.push(more);
        }
    }
    Ok(results)
}
