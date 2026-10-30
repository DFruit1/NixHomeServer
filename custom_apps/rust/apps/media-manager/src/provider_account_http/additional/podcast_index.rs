use super::*;
use sha1::{Digest, Sha1};

// The protocol requires SHA-1(key + secret + timestamp); this is request signing,
// never password storage. https://podcastindex-org.github.io/docs-api/
async fn get(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    path: &str,
    params: &[(&str, String)],
) -> Result<Value, Failure> {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let secret = credentials.get("apiSecret").ok_or_else(Failure::rejected)?;
    let timestamp = unix_timestamp().to_string();
    let mut hash = Sha1::new();
    hash.update(key.as_bytes());
    hash.update(secret.as_bytes());
    hash.update(timestamp.as_bytes());
    let signature = format!("{:x}", hash.finalize());
    let body = json_request(
        state,
        identity,
        "podcast-index",
        state
            .client
            .get(url(state, "podcast-index", path)?)
            .query(params)
            .header("X-Auth-Key", key)
            .header("X-Auth-Date", timestamp)
            .header("Authorization", signature),
    )
    .await?;
    if body.get("status") == Some(&json!(false)) || body.get("status") == Some(&json!("false")) {
        return Err(Failure::unavailable());
    }
    Ok(body)
}

pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    if let Some(reference) = &request.id {
        let (kind, id) = reference.split_once(':').ok_or_else(Failure::invalid)?;
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        if kind == "episode" {
            let body = get(
                state,
                identity,
                credentials,
                "episodes/byid",
                &[("id", id.into())],
            )
            .await?;
            let value = body
                .get("episode")
                .filter(|v| v.is_object())
                .ok_or_else(Failure::unavailable)?;
            return Ok(vec![episode(value)]);
        }
        if kind != "feed" {
            return Err(Failure::invalid());
        }
        let body = get(
            state,
            identity,
            credentials,
            "podcasts/byfeedid",
            &[("id", id.into())],
        )
        .await?;
        let value = body
            .get("feed")
            .filter(|v| v.is_object())
            .ok_or_else(Failure::unavailable)?;
        let mut c = feed(value);
        c.next = None;
        let episodes = get(
            state,
            identity,
            credentials,
            "episodes/byfeedid",
            &[("id", id.into()), ("max", "19".into())],
        )
        .await?;
        let mut results = vec![c];
        for value in episodes
            .get("items")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(19)
        {
            results.push(episode(value));
        }
        return Ok(results);
    }
    // The search API has no page cursor; bound results rather than pretending
    // page numbers can advance its result set.
    if request.page.unwrap_or(1) > 1 {
        return Err(Failure::invalid());
    }
    let body = get(
        state,
        identity,
        credentials,
        "search/byterm",
        &[("q", request.query.clone()), ("max", "20".into())],
    )
    .await?;
    Ok(body
        .get("feeds")
        .and_then(Value::as_array)
        .ok_or_else(Failure::unavailable)?
        .iter()
        .take(MAX_RESULTS)
        .map(feed)
        .collect())
}

fn feed(v: &Value) -> Candidate {
    let id = number(v, "id");
    let mut c = Candidate::new("podcast-index", format!("feed:{id}"), text(v, "title"));
    c.subtitle = format!("{} · {}", text(v, "author"), text(v, "language"));
    c.drill_down("feed");
    for (label, source) in [
        ("Author", "author"),
        ("Language", "language"),
        ("Feed URL", "url"),
        ("Podcast GUID", "podcastGuid"),
    ] {
        c.evidence
            .insert(label.into(), text(v, source).chars().take(1000).collect());
    }
    c.evidence.insert(
        "Description".into(),
        html2text::from_read(text(v, "description").as_bytes(), 100)
            .unwrap_or_default()
            .chars()
            .take(4000)
            .collect(),
    );
    c.evidence.insert("Feed ID".into(), id);
    c
}
fn episode(v: &Value) -> Candidate {
    let id = number(v, "id");
    let mut c = Candidate::new("podcast-index", format!("episode:{id}"), text(v, "title"));
    c.subtitle = text(v, "feedTitle").into();
    for (label, source) in [
        ("Episode GUID", "guid"),
        ("Podcast GUID", "podcastGuid"),
        ("Feed URL", "feedUrl"),
    ] {
        c.evidence
            .insert(label.into(), text(v, source).chars().take(1000).collect());
    }
    c.evidence.insert(
        "Description".into(),
        html2text::from_read(text(v, "description").as_bytes(), 100)
            .unwrap_or_default()
            .chars()
            .take(4000)
            .collect(),
    );
    c.evidence.insert("Episode ID".into(), id);
    c.evidence
        .insert("Duration (seconds)".into(), number(v, "duration"));
    c.evidence
        .insert("Published (Unix time)".into(), number(v, "datePublished"));
    for key in ["transcripts", "chaptersUrl", "soundbite", "persons"] {
        if let Some(value) = v.get(key).filter(|v| !v.is_null()) {
            c.evidence
                .insert(key.into(), value.to_string().chars().take(4000).collect());
        }
    }
    c
}
