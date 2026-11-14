use super::*;

// https://docs.anilist.co/ (public GraphQL; no key for read-only queries).
// Results are complete candidates, so anime and manga need no drill-down.
const MEDIA_FIELDS: &str = "id idMal type format status title{romaji english native} startDate{year month day} episodes duration chapters volumes genres averageScore description(asHtml:true) coverImage{extraLarge} bannerImage studios(isMain:true){nodes{name}} staff(perPage:12){edges{role node{name{full}}}}";

pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let kind = match request.media_type.as_deref() {
        Some("manga") => "MANGA",
        Some("anime") | None => "ANIME",
        Some(_) => return Err(Failure::invalid()),
    };
    let (query, variables) = if let Some(id) = &request.id {
        let id = id
            .strip_prefix("anilist:")
            .unwrap_or(id)
            .parse::<u64>()
            .map_err(|_| Failure::invalid())?;
        (
            format!("query($id:Int){{Page(perPage:1){{media(id:$id){{{MEDIA_FIELDS}}}}}}}"),
            json!({"id": id}),
        )
    } else {
        (
            format!(
                "query($s:String,$t:MediaType,$p:Int){{Page(page:$p,perPage:{MAX_RESULTS}){{media(search:$s,type:$t,sort:SEARCH_MATCH){{{MEDIA_FIELDS}}}}}}}"
            ),
            json!({"s": request.query.trim(), "t": kind, "p": request.page.unwrap_or(1).max(1)}),
        )
    };
    let body = json_request(
        state,
        identity,
        "anilist",
        state
            .client
            .post(url(state, "anilist", "")?)
            .json(&json!({"query": query, "variables": variables})),
    )
    .await?;
    if body.get("errors").is_some_and(|e| !e.is_null()) && body.pointer("/data/Page").is_none() {
        return Err(Failure::unavailable());
    }
    let mut out = Vec::new();
    for media in body
        .pointer("/data/Page/media")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_RESULTS)
    {
        let id = number(media, "id");
        let titles = &media["title"];
        let title = [
            text(titles, "english"),
            text(titles, "romaji"),
            text(titles, "native"),
        ]
        .into_iter()
        .find(|v| !v.is_empty())
        .unwrap_or("");
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let manga = text(media, "type") == "MANGA";
        let format = text(media, "format");
        let mut c = Candidate::new("anilist", format!("anilist:{id}"), title);
        let start = &media["startDate"];
        c.subtitle = [
            number(start, "year"),
            format.replace('_', " "),
            text(media, "status").replace('_', " ").to_lowercase(),
        ]
        .into_iter()
        .filter(|v| !v.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");
        if !manga {
            c.field(
                "mediaType",
                if format == "MOVIE" { "movie" } else { "series" },
            );
            c.field("runtimeMinutes", number(media, "duration"));
            c.field("publisher", list(&media["studios"], "nodes"));
        }
        c.field("title", title);
        if manga {
            c.field("series", title);
        }
        c.field("year", number(start, "year"));
        if let (Some(y), Some(m), Some(d)) = (
            start["year"].as_u64(),
            start["month"].as_u64(),
            start["day"].as_u64(),
        ) {
            c.field("premiereDate", format!("{y:04}-{m:02}-{d:02}"));
        }
        c.field("genres", list(media, "genres"));
        if let Some(score) = media["averageScore"].as_u64() {
            c.field("communityRating", format!("{:.1}", score as f64 / 10.0));
        }
        c.field(
            "description",
            html2text::from_read(text(media, "description").as_bytes(), 100).unwrap_or_default(),
        );
        let staff = |roles: &[&str]| {
            media
                .pointer("/staff/edges")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|e| roles.iter().any(|r| text(e, "role").starts_with(r)))
                .filter_map(|e| e.pointer("/node/name/full").and_then(Value::as_str))
                .take(16)
                .collect::<Vec<_>>()
                .join(", ")
        };
        if manga {
            c.field("authors", staff(&["Story", "Original Creator"]));
            c.field("writers", staff(&["Story"]));
        } else {
            c.field(
                "writers",
                staff(&["Original Creator", "Series Composition"]),
            );
        }
        for (label, value) in [
            ("Native title", text(titles, "native").to_string()),
            ("Romaji title", text(titles, "romaji").to_string()),
            ("Episodes", number(media, "episodes")),
            ("Chapters", number(media, "chapters")),
            ("Volumes", number(media, "volumes")),
        ] {
            if !value.is_empty() {
                c.evidence
                    .insert(label.into(), value.chars().take(500).collect());
            }
        }
        c.identifier("anilist", &id);
        c.identifier("myanimelist", number(media, "idMal"));
        artwork(
            state,
            identity,
            &mut c,
            text(&media["coverImage"], "extraLarge"),
            "cover",
            "",
        )
        .await;
        artwork(
            state,
            identity,
            &mut c,
            text(media, "bannerImage"),
            "background",
            "",
        )
        .await;
        out.push(c);
    }
    Ok(out)
}
