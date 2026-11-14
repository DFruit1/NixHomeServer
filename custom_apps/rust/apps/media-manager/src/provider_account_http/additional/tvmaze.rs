use super::*;

// https://www.tvmaze.com/api (public, no key; about 20 calls per 10 seconds per IP).
// Search lists shows; a show lists itself plus seasons; a season lists episodes.
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let Some(id) = &request.id else {
        let body = json_request(
            state,
            identity,
            "tvmaze",
            state
                .client
                .get(url(state, "tvmaze", "search/shows")?)
                .query(&[("q", request.query.trim())]),
        )
        .await?;
        let mut out = Vec::new();
        for show in body
            .as_array()
            .into_iter()
            .flatten()
            .take(MAX_RESULTS)
            .map(|v| &v["show"])
        {
            let show_id = number(show, "id");
            if show_id.is_empty() || text(show, "name").is_empty() {
                continue;
            }
            let mut c = Candidate::new("tvmaze", format!("show:{show_id}"), text(show, "name"));
            c.subtitle = subtitle(show);
            c.drill_down("show");
            out.push(c);
        }
        return Ok(out);
    };
    let (kind, rest) = id.split_once(':').ok_or_else(Failure::invalid)?;
    let (show_id, season) = match kind {
        "show" => (rest, None),
        "season" => {
            let (show, season) = rest.split_once(':').ok_or_else(Failure::invalid)?;
            (
                show,
                Some(season.parse::<u32>().map_err(|_| Failure::invalid())?),
            )
        }
        _ => return Err(Failure::invalid()),
    };
    if show_id.is_empty() || show_id.len() > 12 || !show_id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Failure::invalid());
    }
    let show = json_request(
        state,
        identity,
        "tvmaze",
        state
            .client
            .get(url(state, "tvmaze", &format!("shows/{show_id}"))?)
            .query(&[("embed", "episodes")]),
    )
    .await?;
    let name = text(&show, "name");
    if name.is_empty() {
        return Ok(vec![]);
    }
    let episodes = show
        .pointer("/_embedded/episodes")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut out = Vec::new();
    let Some(season) = season else {
        let mut c = Candidate::new("tvmaze", format!("show:{show_id}"), name);
        c.subtitle = subtitle(&show);
        c.field("mediaType", "series");
        c.field("title", name);
        c.field("series", name);
        date(&mut c, text(&show, "premiered"));
        c.field("genres", list(&show, "genres"));
        c.field("language", text(&show, "language"));
        c.field("publisher", network(&show));
        c.field("runtimeMinutes", number(&show, "averageRuntime"));
        c.field("communityRating", number(&show["rating"], "average"));
        c.field("description", plain(text(&show, "summary")));
        series_ids(&mut c, &show, false);
        c.evidence
            .insert("Status".into(), text(&show, "status").into());
        c.evidence
            .insert("Episodes".into(), episodes.len().to_string());
        artwork(
            state,
            identity,
            &mut c,
            text(&show["image"], "original"),
            "cover",
            "",
        )
        .await;
        out.push(c);
        let mut seasons = episodes
            .iter()
            .filter_map(|e| e["season"].as_u64())
            .collect::<Vec<_>>();
        seasons.dedup();
        for number in seasons.into_iter().take(MAX_RESULTS - 1) {
            let count = episodes
                .iter()
                .filter(|e| e["season"].as_u64() == Some(number))
                .count();
            let mut c = Candidate::new("tvmaze", format!("season:{show_id}:{number}"), name);
            c.subtitle = format!("Season {number} · {count} episodes");
            c.drill_down("season");
            out.push(c);
        }
        return Ok(out);
    };
    let skip = (request.page.unwrap_or(1).max(1) as usize - 1) * MAX_RESULTS;
    for episode in episodes
        .iter()
        .filter(|e| e["season"].as_u64() == Some(u64::from(season)))
        .skip(skip)
        .take(MAX_RESULTS)
    {
        let episode_title = text(episode, "name");
        let mut c = Candidate::new("tvmaze", format!("episode:{}", number(episode, "id")), name);
        c.subtitle = format!(
            "S{season}E{} · {episode_title} · {}",
            number(episode, "number"),
            text(episode, "airdate")
        );
        c.field("mediaType", "episode");
        c.field("title", name);
        c.field("series", name);
        c.field("episodeTitle", episode_title);
        c.field("season", season);
        c.field("episode", number(episode, "number"));
        date(&mut c, text(episode, "airdate"));
        c.field("runtimeMinutes", number(episode, "runtime"));
        c.field("communityRating", number(&episode["rating"], "average"));
        c.field("description", plain(text(episode, "summary")));
        c.field("genres", list(&show, "genres"));
        c.field("publisher", network(&show));
        series_ids(&mut c, &show, true);
        c.identifier("tvmaze-episode", number(episode, "id"));
        artwork(
            state,
            identity,
            &mut c,
            text(&episode["image"], "original"),
            "background",
            "",
        )
        .await;
        out.push(c);
    }
    Ok(out)
}

fn subtitle(show: &Value) -> String {
    [
        text(show, "premiered").get(..4).unwrap_or("").to_string(),
        network(show),
        text(show, "status").to_string(),
    ]
    .into_iter()
    .filter(|v| !v.is_empty())
    .collect::<Vec<_>>()
    .join(" · ")
}

fn network(show: &Value) -> String {
    let network = text(&show["network"], "name");
    if network.is_empty() {
        text(&show["webChannel"], "name").into()
    } else {
        network.into()
    }
}

fn plain(html: &str) -> String {
    html2text::from_read(html.as_bytes(), 100).unwrap_or_default()
}

/// Episodes carry their series identifiers under series-scoped keys.
fn series_ids(c: &mut Candidate, show: &Value, episode: bool) {
    let ids = &show["externals"];
    c.identifier("tvmaze", number(show, "id"));
    c.identifier(
        if episode { "imdb-series" } else { "imdb" },
        text(ids, "imdb"),
    );
    c.identifier("tvdb", number(ids, "thetvdb"));
}
