use super::*;

// https://thediscdb.com/graphql (public HotChocolate schema; no key).
// Titles search media items; an item lists its disc releases. Each release is a
// reviewable candidate whose evidence maps disc playlists/files to episodes.
const ITEM_FIELDS: &str = "id slug title year type imageUrl plot directors writers stars genres runtimeMinutes contentRating releaseDate externalids { tmdb imdb tvdb }";

pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    request: &LookupRequest,
) -> LookupResult {
    let (query, variables) = if let Some(id) = &request.id {
        let slug = id.strip_prefix("item:").ok_or_else(Failure::invalid)?;
        if slug.is_empty() || !slug.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(Failure::invalid());
        }
        (
            format!(
                "query($s:String){{mediaItems(first:1,where:{{slug:{{eq:$s}}}}){{nodes{{{ITEM_FIELDS} releases{{slug title year regionCode locale upc asin imageUrl releaseDate discs{{index name format titles{{index duration sourceFile itemType season episode description hasItem}}}}}}}}}}}}"
            ),
            json!({"s": slug}),
        )
    } else {
        (
            format!(
                "query($t:String){{mediaItems(first:{MAX_RESULTS},where:{{title:{{contains:$t}}}},order:[{{year:DESC}}]){{nodes{{{ITEM_FIELDS} releases{{slug}}}}}}}}"
            ),
            json!({"t": request.query.trim()}),
        )
    };
    let body = json_request(
        state,
        identity,
        "thediscdb",
        state
            .client
            .post(url(state, "thediscdb", "")?)
            .json(&json!({"query": query, "variables": variables})),
    )
    .await?;
    if body.get("errors").is_some_and(|e| !e.is_null()) {
        return Err(Failure::unavailable());
    }
    let items = body
        .pointer("/data/mediaItems/nodes")
        .and_then(Value::as_array)
        .ok_or_else(Failure::unavailable)?;
    let mut out = Vec::new();
    for item in items.iter().take(MAX_RESULTS) {
        let slug = text(item, "slug");
        let title = text(item, "title");
        if slug.is_empty() || title.is_empty() {
            continue;
        }
        if request.id.is_none() {
            let mut c = Candidate::new("thediscdb", format!("item:{slug}"), title);
            let releases = item["releases"].as_array().map_or(0, Vec::len);
            c.subtitle = format!(
                "{} · {} · {releases} disc release{}",
                number(item, "year"),
                text(item, "type"),
                if releases == 1 { "" } else { "s" }
            );
            c.drill_down("item");
            out.push(c);
            continue;
        }
        for release in item["releases"]
            .as_array()
            .into_iter()
            .flatten()
            .take(MAX_RESULTS)
        {
            let release_slug = text(release, "slug");
            if release_slug.is_empty() {
                continue;
            }
            let mut c =
                Candidate::new("thediscdb", format!("release:{slug}:{release_slug}"), title);
            c.subtitle = [
                text(release, "title").to_string(),
                number(release, "year"),
                region(text(release, "regionCode")),
            ]
            .into_iter()
            .filter(|v| !v.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
            item_fields(&mut c, item);
            for (label, key) in [("Release", "title"), ("UPC", "upc"), ("ASIN", "asin")] {
                let value = text(release, key);
                if !value.is_empty() {
                    c.evidence
                        .insert(label.into(), value.chars().take(200).collect());
                }
            }
            c.identifier("thediscdb-release", format!("{slug}/{release_slug}"));
            for disc in release["discs"].as_array().into_iter().flatten().take(40) {
                let map = disc["titles"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|t| t["hasItem"].as_bool() == Some(true))
                    .take(64)
                    .map(|t| {
                        let target = if text(t, "itemType") == "Episode" {
                            format!(
                                "S{}E{} {}",
                                text(t, "season"),
                                text(t, "episode"),
                                text(t, "description")
                            )
                        } else {
                            format!("{} {}", text(t, "itemType"), text(t, "description"))
                        };
                        format!(
                            "{} ({}) → {}",
                            text(t, "sourceFile"),
                            text(t, "duration"),
                            target.trim()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                if !map.is_empty() {
                    c.evidence.insert(
                        format!("{} · {}", text(disc, "name"), text(disc, "format")),
                        map.chars().take(2000).collect(),
                    );
                }
            }
            let image = text(release, "imageUrl");
            let image = if image.is_empty() {
                text(item, "imageUrl")
            } else {
                image
            };
            if !image.is_empty() && !image.contains("..") {
                artwork(
                    state,
                    identity,
                    &mut c,
                    &format!("https://thediscdb.com/images/{image}"),
                    "cover",
                    "",
                )
                .await;
            }
            out.push(c);
        }
    }
    Ok(out)
}

fn item_fields(c: &mut Candidate, item: &Value) {
    let series = text(item, "type") == "Series";
    c.field("mediaType", if series { "series" } else { "movie" });
    c.field("title", text(item, "title"));
    c.field("year", number(item, "year"));
    c.field("description", text(item, "plot"));
    c.field("genres", text(item, "genres"));
    c.field("writers", text(item, "writers"));
    c.field("officialRating", text(item, "contentRating"));
    if item["runtimeMinutes"].as_u64().is_some_and(|m| m > 0) {
        c.field("runtimeMinutes", number(item, "runtimeMinutes"));
    }
    if let Some(date) = text(item, "releaseDate").get(..10) {
        c.field("premiereDate", date);
    }
    for (label, key) in [("Directors", "directors"), ("Stars", "stars")] {
        let value = text(item, key);
        if !value.is_empty() {
            c.evidence
                .insert(label.into(), value.chars().take(2000).collect());
        }
    }
    let ids = &item["externalids"];
    c.identifier("imdb", text(ids, "imdb"));
    c.identifier(
        if series { "tmdb-series" } else { "tmdb" },
        text(ids, "tmdb"),
    );
    c.identifier("tvdb", text(ids, "tvdb"));
    c.identifier("thediscdb", text(item, "slug"));
}

fn region(code: &str) -> String {
    match code {
        "" => String::new(),
        "0" => "Region free".into(),
        code => format!("Region {code}"),
    }
}
