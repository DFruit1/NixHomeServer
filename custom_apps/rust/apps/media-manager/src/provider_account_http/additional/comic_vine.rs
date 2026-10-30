use super::*;

// https://comicvine.gamespot.com/api/documentation (JSON resources, explicit field lists).
pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    let key = credentials.get("apiKey").ok_or_else(Failure::rejected)?;
    let mut params = vec![
        ("api_key", key.clone()),
        ("format", "json".into()),
        ("limit", "20".into()),
        (
            "offset",
            ((request.page.unwrap_or(1).max(1) - 1) * 20).to_string(),
        ),
    ];
    let (path, kind) = if let Some(id) = &request.id {
        let (kind, number) = id.split_once(':').ok_or_else(Failure::invalid)?;
        if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::invalid());
        }
        match kind {
            "volume" => {
                params.push(("filter", format!("volume:{number}")));
                ("issues/".into(), "issues")
            }
            "issue" => (format!("issue/4000-{number}/"), "issue"),
            _ => return Err(Failure::invalid()),
        }
    } else {
        params.push(("query", request.query.clone()));
        params.push(("resources", "volume".into()));
        ("search/".into(), "volumes")
    };
    params.push(("field_list","id,name,volume,issue_number,start_year,publisher,cover_date,description,person_credits,image,site_detail_url".into()));
    let body = json_request(
        state,
        identity,
        "comic-vine",
        state
            .client
            .get(url(state, "comic-vine", &path)?)
            .query(&params),
    )
    .await?;
    match body.get("status_code").and_then(Value::as_u64) {
        Some(1) => {}
        Some(100) => return Err(Failure::rejected()),
        Some(107) => return Err(Failure::limited()),
        _ => return Err(Failure::unavailable()),
    }
    let values = if kind == "issue" {
        vec![&body["results"]]
    } else {
        body["results"]
            .as_array()
            .ok_or_else(Failure::unavailable)?
            .iter()
            .take(MAX_RESULTS)
            .collect()
    };
    let mut out = Vec::new();
    for v in values {
        let id = number(v, "id");
        let title = if text(v, "name").is_empty() {
            text(&v["volume"], "name")
        } else {
            text(v, "name")
        };
        let mut c = Candidate::new(
            "comic-vine",
            format!(
                "{}:{id}",
                if kind == "volumes" { "volume" } else { "issue" }
            ),
            title,
        );
        c.subtitle = if kind == "volumes" {
            format!(
                "{} · {}",
                number(v, "start_year"),
                text(&v["publisher"], "name")
            )
        } else {
            format!(
                "{} #{} · {}",
                text(&v["volume"], "name"),
                text(v, "issue_number"),
                text(v, "cover_date")
            )
        };
        if kind != "issue" {
            c.drill_down(if kind == "volumes" { "volume" } else { "issue" });
        } else {
            c.field("title", title);
            c.field("series", text(&v["volume"], "name"));
            c.field("volumeNumber", text(v, "issue_number"));
            c.field("publisher", text(&v["publisher"], "name"));
            let volume_id = number(&v["volume"], "id");
            if !volume_id.is_empty() && !c.fields.contains_key("publisher") {
                let volume = json_request(
                    state,
                    identity,
                    "comic-vine",
                    state
                        .client
                        .get(url(
                            state,
                            "comic-vine",
                            &format!("volume/4050-{volume_id}/"),
                        )?)
                        .query(&[
                            ("api_key", key.as_str()),
                            ("format", "json"),
                            ("field_list", "id,name,publisher,start_year"),
                        ]),
                )
                .await?;
                c.field("publisher", text(&volume["results"]["publisher"], "name"));
                c.evidence.insert(
                    "Publisher volume".into(),
                    format!(
                        "{} ({})",
                        text(&volume["results"], "name"),
                        number(&volume["results"], "start_year")
                    ),
                );
                c.identifier("comic-vine-volume", volume_id);
            }
            date(&mut c, text(v, "cover_date"));
            c.field(
                "description",
                html2text::from_read(text(v, "description").as_bytes(), 100).unwrap_or_default(),
            );
            let writers = v
                .get("person_credits")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|p| text(p, "role").to_ascii_lowercase().contains("writer"))
                .take(32)
                .map(|p| text(p, "name"))
                .collect::<Vec<_>>()
                .join(", ");
            c.field("authors", &writers);
            c.field("writers", writers);
            c.identifier("comic-vine-issue", id);
            let link = text(v, "site_detail_url");
            if link.starts_with("https://comicvine.gamespot.com/") {
                c.identifier("web", link);
            }
            artwork(
                state,
                identity,
                &mut c,
                text(&v["image"], "original_url"),
                "cover",
                "",
            )
            .await;
        }
        out.push(c);
    }
    Ok(out)
}
