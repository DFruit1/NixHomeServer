use super::*;

// https://www.omdbapi.com/#parameters
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let mut params = vec![("apikey", key.clone()), ("r", "json".into())];
    if let Some(id) = &request.id {
        if id.len() <= 2 || !id.starts_with("tt") || !id[2..].bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        params.push(("i", id.clone()));
        params.push(("plot", "full".into()));
    } else {
        params.push(("s", request.query.clone()));
        params.push(("page", request.page.unwrap_or(1).max(1).to_string()));
    }
    if let Some(year) = request.year {
        params.push(("y", year.to_string()));
    }
    if let Some(kind) = &request.media_type {
        if !matches!(kind.as_str(), "movie" | "series" | "episode") {
            return Err(Failure::invalid());
        }
        params.push(("type", kind.clone()));
    }
    let body = json_request(
        state,
        identity,
        "omdb",
        state.client.get(url(state, "omdb", "")?).query(&params),
    )
    .await?;
    if text(&body, "Response") == "False" {
        let error = text(&body, "Error").to_ascii_lowercase();
        return if error.contains("key") {
            Err(Failure::rejected())
        } else if error.contains("limit") {
            Err(Failure::limited())
        } else if error.contains("not found") {
            Ok(vec![])
        } else {
            Err(Failure::unavailable())
        };
    }
    let values = if request.id.is_some() {
        vec![&body]
    } else {
        body.get("Search")
            .and_then(Value::as_array)
            .ok_or_else(Failure::unavailable)?
            .iter()
            .take(MAX_RESULTS)
            .collect()
    };
    let mut out = Vec::new();
    for value in values {
        let id = text(value, "imdbID");
        let title = text(value, "Title");
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let mut c = Candidate::new("omdb", id, title);
        c.subtitle = format!("{} · {}", text(value, "Year"), text(value, "Type"));
        if request.id.is_some() {
            for (field, source) in [
                ("title", "Title"),
                ("description", "Plot"),
                ("genres", "Genre"),
                ("writers", "Writer"),
                ("officialRating", "Rated"),
                ("communityRating", "imdbRating"),
            ] {
                c.field(field, text(value, source));
            }
            c.field(
                "year",
                text(value, "Year").split(['–', '-']).next().unwrap_or(""),
            );
            c.field(
                "runtimeMinutes",
                text(value, "Runtime")
                    .split_whitespace()
                    .next()
                    .unwrap_or(""),
            );
            c.identifier("imdb", id);
            c.field(
                "mediaType",
                if text(value, "Type") == "series" {
                    "series"
                } else {
                    text(value, "Type")
                },
            );
            if text(value, "Type") == "episode" {
                let series = text(value, "seriesID");
                if series.starts_with("tt")
                    && series.len() > 2
                    && series[2..].bytes().all(|b| b.is_ascii_digit())
                {
                    let parent = json_request(
                        state,
                        identity,
                        "omdb",
                        state.client.get(url(state, "omdb", "")?).query(&[
                            ("apikey", key.as_str()),
                            ("i", series),
                            ("r", "json"),
                        ]),
                    )
                    .await?;
                    c.field("episodeTitle", title);
                    c.field("title", text(&parent, "Title"));
                    c.field("series", text(&parent, "Title"));
                    c.field("season", text(value, "Season"));
                    c.field("episode", text(value, "Episode"));
                    c.identifier("imdb-series", series);
                }
            }
            for source in ["Actors", "Director"] {
                let value = text(value, source);
                if !value.is_empty() && value != "N/A" {
                    c.evidence
                        .insert(source.into(), value.chars().take(2000).collect());
                }
            }
            for rating in value
                .get("Ratings")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .take(10)
            {
                c.evidence
                    .insert(text(rating, "Source").into(), text(rating, "Value").into());
            }
            artwork(state, identity, &mut c, text(value, "Poster"), "cover", "").await;
        } else {
            c.drill_down(text(value, "Type"));
        }
        out.push(c);
    }
    Ok(out)
}
