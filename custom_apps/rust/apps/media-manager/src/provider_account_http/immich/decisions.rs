//! d1 receives bounded pixels/text only; credentials never leave the broker.
use super::*;
use crate::decision_index::{Rule, RuleKind, ScoreBounds};
use crate::image_index::Scores;
use base64::{engine::general_purpose::STANDARD, Engine};
use sha2::{Digest, Sha256};

fn decision_error(id: &str) -> ApiError {
    error(
        StatusCode::SERVICE_UNAVAILABLE,
        "decision_unavailable",
        "Local d1 assessment is unavailable or busy. Try again shortly; no tags were changed.",
        id,
    )
}
pub(in crate::provider_account_http) async fn rules(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let scope = account.scope(&identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    Ok(Json(
        json!({"rules":index.rules().map_err(|_|index_error(&id))?,"requestId":id}),
    ))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(in crate::provider_account_http) struct RulesInput {
    rules: Vec<Rule>,
}
pub(in crate::provider_account_http) async fn save_rules(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    body: Result<Json<RulesInput>, axum::extract::rejection::JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let Json(input) = body.map_err(|_| invalid(&id))?;
    let unique: std::collections::BTreeSet<_> = input.rules.iter().map(|r| &r.id).collect();
    // One proposition per Yes/No rule and per album category. Bound the total so
    // a saved question set always fits one local d1 request.
    let propositions: usize = input
        .rules
        .iter()
        .map(|rule| match rule.kind {
            RuleKind::YesNo => 1,
            RuleKind::Category => rule.categories.len(),
        })
        .sum();
    if input.rules.len() > 16
        || propositions > 24
        || input.rules.iter().any(|r| !r.valid())
        || unique.len() != input.rules.len()
    {
        return Err(invalid(&id));
    }
    let scope = account.scope(&identity);
    Index {
        store: &state.store,
        scope: &scope,
    }
    .save_rules(&input.rules)
    .map_err(|_| index_error(&id))?;
    Ok(Json(json!({"rules":input.rules,"requestId":id})))
}
fn invalid(id: &str) -> ApiError {
    error(StatusCode::UNPROCESSABLE_ENTITY, "decision_invalid", "Save up to 16 questions and 24 total d1 propositions (one per yes/no question and per album). Use unique IDs, questions up to 1000 bytes, tags up to 96 bytes without commas or control characters, two to twelve unique album categories up to 96 bytes, and score bounds between 0 and 1.", id)
}

fn requires_scores(rules: &[Rule]) -> bool {
    rules
        .iter()
        .any(|rule| rule.bounds.as_ref().is_some_and(ScoreBounds::any))
}

/// Bound the prompt to the question's own inputs: a short filename plus up to a
/// few existing Immich tag values. Tag text is private metadata and never
/// leaves this local d1 socket.
fn photo_state(asset: &Asset) -> String {
    let filename: String = asset.original_file_name.chars().take(512).collect();
    let mut tags = String::new();
    for tag in asset.tags.iter().take(32) {
        let value: String = tag.value.chars().take(48).collect();
        if !tags.is_empty() {
            tags.push_str(", ");
        }
        tags.push_str(&value);
        if tags.len() >= 1024 {
            break;
        }
    }
    if tags.is_empty() {
        tags.push_str("none");
    }
    format!("Assess this personal photo: {filename}. Immich tags: {tags}.")
}

async fn asset_scores(
    state: &ProviderBrokerState,
    account: &Account,
    index: &Index<'_>,
    asset_id: &str,
    id: &str,
    wait: bool,
) -> Result<Scores, ApiError> {
    if let Some(analysis) = index.analysis(asset_id).map_err(|_| index_error(id))? {
        return Ok(analysis.scores);
    }
    let analysis = analyze_asset(state, account, asset_id, id, wait).await?;
    index
        .save(asset_id, &analysis)
        .map_err(|_| index_error(id))?;
    Ok(analysis.scores)
}

pub(in crate::provider_account_http) async fn assess(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let asset = account.asset(&state, &asset_id, &id).await?;
    let scope = account.scope(&identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    let (_, generation, _) = index.scan().map_err(|_| index_error(&id))?;
    index
        .observe(
            &asset_id,
            &asset.original_file_name,
            &asset.file_created_at,
            generation,
        )
        .map_err(|_| index_error(&id))?;
    let rules = index.rules().map_err(|_| index_error(&id))?;
    if rules.is_empty() {
        return Err(invalid(&id));
    }
    let scores = if requires_scores(&rules) {
        Some(asset_scores(&state, &account, &index, &asset_id, &id, false).await?)
    } else {
        None
    };
    let (bytes, mime) = account.image(&state, &asset_id, &id).await?;
    let input = json!({"state":photo_state(&asset),"images":[format!("data:{mime};base64,{}",STANDARD.encode(bytes))]});
    let album = AlbumTarget {
        state: &state,
        account: &account,
        asset_id: &asset_id,
    };
    let result = evaluate(Evaluation {
        runtime: &account.runtime,
        index: &index,
        target: &asset_id,
        rules: &rules,
        input,
        scores: scores.as_ref(),
        album: Some(&album),
        id: &id,
    })
    .await?;
    Ok(Json(result))
}

// Files are uploaded only for assessment, never stored or modified. Tags are
// persisted by content hash so repeated uploads recover previous additive tags.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in crate::provider_account_http) struct FileInput {
    name: String,
    content: String,
    image: bool,
}
fn file_invalid(id: &str) -> ApiError {
    error(StatusCode::UNPROCESSABLE_ENTITY, "decision_file_invalid", "Choose a JPEG, PNG or WebP image, or a UTF-8 text file. PDFs and other binary files are unsupported.", id)
}
pub(in crate::provider_account_http) async fn assess_file(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    body: Result<Json<FileInput>, axum::extract::rejection::JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let Json(file) = body.map_err(|_| invalid(&id))?;
    if file.name.is_empty() || file.name.len() > 4096 || file.name.chars().any(char::is_control) {
        return Err(invalid(&id));
    }
    let bytes = STANDARD.decode(&file.content).map_err(|_| invalid(&id))?;
    let target = format!("file:{:x}", Sha256::digest(&bytes));
    let input = if file.image {
        if bytes.len() > MAX_PREVIEW_BYTES {
            return Err(invalid(&id));
        }
        let mime = sniff_image_content_type(&bytes).ok_or_else(|| file_invalid(&id))?;
        json!({"state":format!("Assess this personal image: {}",file.name),"images":[format!("data:{mime};base64,{}",file.content)]})
    } else {
        if bytes.len() > 16 * 1024 {
            return Err(error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "decision_file_too_large",
                "Text files must be at most 16 KiB. No partial-file assessment was performed.",
                &id,
            ));
        }
        let text = std::str::from_utf8(&bytes).map_err(|_| file_invalid(&id))?;
        if text.contains('\0') {
            return Err(file_invalid(&id));
        }
        json!({"state":format!("Assess this personal text file: {}\n\n{}",file.name,text)})
    };
    let scope = account.scope(&identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    let rules = index.rules().map_err(|_| index_error(&id))?;
    if rules.is_empty() {
        return Err(invalid(&id));
    }
    // Uploads have no Immich asset, so category results never write an album.
    // An image can still satisfy EYE score bounds; text files cannot.
    let scores = if requires_scores(&rules) && file.image {
        let mime = sniff_image_content_type(&bytes).ok_or_else(|| file_invalid(&id))?;
        Some(
            eye_image(&account.runtime.eye, bytes.clone(), &mime, &id)
                .await?
                .scores,
        )
    } else {
        None
    };
    Ok(Json(
        evaluate(Evaluation {
            runtime: &account.runtime,
            index: &index,
            target: &target,
            rules: &rules,
            input,
            scores: scores.as_ref(),
            album: None,
            id: &id,
        })
        .await?,
    ))
}

pub(super) struct AlbumTarget<'a> {
    state: &'a ProviderBrokerState,
    account: &'a Account,
    asset_id: &'a str,
}

pub(super) struct Evaluation<'a, 'b> {
    runtime: &'a Runtime,
    index: &'a Index<'b>,
    target: &'a str,
    rules: &'a [Rule],
    input: Value,
    scores: Option<&'a Scores>,
    album: Option<&'a AlbumTarget<'a>>,
    id: &'a str,
}

pub(super) async fn background(
    state: &ProviderBrokerState,
    account: &Account,
    index: &Index<'_>,
    asset: &Asset,
    id: &str,
) -> Result<(), ApiError> {
    let rules: Vec<Rule> = index
        .rules()
        .map_err(|_| index_error(id))?
        .into_iter()
        .filter(|r| r.automatic)
        .collect();
    let mut pending = Vec::new();
    for rule in rules {
        if index
            .needs_decision(&asset.id, &rule)
            .map_err(|_| index_error(id))?
        {
            pending.push(rule);
        }
    }
    if pending.is_empty() {
        return Ok(());
    }
    // Recheck current access before sending pixels, including cached assets.
    account.asset(state, &asset.id, id).await?;
    let scores = if requires_scores(&pending) {
        Some(asset_scores(state, account, index, &asset.id, id, true).await?)
    } else {
        None
    };
    let (bytes, mime) = account.image(state, &asset.id, id).await?;
    let input = json!({"state":photo_state(asset),"images":[format!("data:{mime};base64,{}",STANDARD.encode(bytes))]});
    let album = AlbumTarget {
        state,
        account,
        asset_id: &asset.id,
    };
    evaluate(Evaluation {
        runtime: &account.runtime,
        index,
        target: &asset.id,
        rules: &pending,
        input,
        scores: scores.as_ref(),
        album: Some(&album),
        id,
    })
    .await?;
    Ok(())
}

struct Probe {
    id: String,
    category: Option<usize>,
}

enum Outcome<'a> {
    Skipped {
        rule: &'a Rule,
        reason: &'static str,
    },
    YesNo {
        rule: &'a Rule,
        probability: f64,
    },
    Category {
        rule: &'a Rule,
        probability: f64,
        category: Option<&'a str>,
    },
}

pub(super) async fn evaluate(evaluation: Evaluation<'_, '_>) -> Result<Value, ApiError> {
    let Evaluation {
        runtime,
        index,
        target,
        rules,
        mut input,
        scores,
        album,
        id,
    } = evaluation;
    let guard = runtime
        .decision_gate
        .try_lock()
        .map_err(|_| decision_error(id))?;
    let mut questions = serde_json::Map::new();
    let mut prepared: Vec<(&Rule, Vec<Probe>, Option<&'static str>)> = Vec::new();
    for rule in rules {
        let skip = rule.bounds.as_ref().and_then(|bounds| {
            if !bounds.any() {
                return None;
            }
            match scores {
                Some(scores) if bounds.allows(scores) => None,
                Some(_) => Some("EYE scores are outside this question's bounds."),
                None => {
                    Some("EYE scores are unavailable, so this question's bounds cannot be checked.")
                }
            }
        });
        if skip.is_some() {
            prepared.push((rule, Vec::new(), skip));
            continue;
        }
        let mut probes = Vec::new();
        match rule.kind {
            RuleKind::YesNo => probes.push(Probe {
                id: rule.id.clone(),
                category: None,
            }),
            RuleKind::Category => {
                for (position, _) in rule.categories.iter().enumerate() {
                    probes.push(Probe {
                        id: format!("{}#{}", rule.id, position),
                        category: Some(position),
                    });
                }
            }
        }
        for probe in &probes {
            let instructions = match probe.category {
                None => rule.question.clone(),
                Some(position) => format!(
                    "{} If the best matching category is \"{}\", answer yes; otherwise answer no.",
                    rule.question, rule.categories[position]
                ),
            };
            questions.insert(
                probe.id.clone(),
                json!({"type":"noul","instructions":instructions}),
            );
        }
        if probes.is_empty() {
            prepared.push((
                rule,
                Vec::new(),
                Some("This question has no album categories."),
            ));
            continue;
        }
        prepared.push((rule, probes, None));
    }
    let mut probabilities = std::collections::BTreeMap::new();
    if !questions.is_empty() {
        input["questions"] = json!(questions);
        let response = runtime
            .decision
            .post("http://localhost/v1/systemone")
            .json(&input)
            .send()
            .await
            .map_err(|_| decision_error(id))?;
        if !response.status().is_success() {
            return Err(decision_error(id));
        }
        let response: Value = bounded_provider_json(response)
            .await
            .map_err(|_| decision_error(id))?;
        for (_, probes, skip) in &prepared {
            if skip.is_some() {
                continue;
            }
            for probe in probes {
                probabilities.insert(
                    probe.id.clone(),
                    response["answers"][&probe.id]["noul"]
                        .as_f64()
                        .filter(|p| probability(*p))
                        .ok_or_else(|| decision_error(id))?,
                );
            }
        }
    }
    let mut outcomes = Vec::with_capacity(prepared.len());
    for (rule, probes, skip) in prepared {
        if let Some(reason) = skip {
            outcomes.push(Outcome::Skipped { rule, reason });
            continue;
        }
        match rule.kind {
            RuleKind::YesNo => outcomes.push(Outcome::YesNo {
                rule,
                probability: probabilities[&rule.id],
            }),
            RuleKind::Category => {
                let mut best: Option<(usize, f64)> = None;
                for probe in &probes {
                    let position = probe
                        .category
                        .expect("category rules only build category probes");
                    let probability = probabilities[&probe.id];
                    if best.is_none_or(|(_, current)| probability > current) {
                        best = Some((position, probability));
                    }
                }
                match best {
                    Some((position, probability)) => outcomes.push(Outcome::Category {
                        rule,
                        probability,
                        category: (probability >= 0.5).then(|| rule.categories[position].as_str()),
                    }),
                    None => outcomes.push(Outcome::Skipped {
                        rule,
                        reason: "This question has no album categories.",
                    }),
                }
            }
        }
    }
    let timestamp = chrono::Local::now().format("%Y%m%d %H:%M").to_string();
    let evaluated: Vec<Rule> = outcomes
        .iter()
        .filter_map(|outcome| match outcome {
            Outcome::Skipped { .. } => None,
            Outcome::YesNo { rule, .. } | Outcome::Category { rule, .. } => Some((*rule).clone()),
        })
        .collect();
    if !evaluated.is_empty() {
        let evaluated_probabilities: Vec<f64> = outcomes
            .iter()
            .filter_map(|outcome| match outcome {
                Outcome::Skipped { .. } => None,
                Outcome::YesNo { probability, .. } | Outcome::Category { probability, .. } => {
                    Some(*probability)
                }
            })
            .collect();
        if !index
            .save_decisions(target, &evaluated, &evaluated_probabilities, &timestamp)
            .map_err(|_| index_error(id))?
        {
            return Err(error(
                StatusCode::CONFLICT,
                "decision_rules_changed",
                "Questions changed during assessment. Assess again using the saved questions.",
                id,
            ));
        }
    }
    // Album writes happen after d1 is released; a failed album assignment keeps
    // applied tags and is reported per question.
    drop(guard);
    struct Applied<'a> {
        rule: &'a Rule,
        probability: f64,
        answer: &'static str,
        category: Option<String>,
        skip: Option<&'static str>,
        album: Option<String>,
        album_error: Option<&'static str>,
    }
    let mut applied = Vec::with_capacity(outcomes.len());
    for outcome in outcomes {
        match outcome {
            Outcome::Skipped { rule, reason } => applied.push(Applied {
                rule,
                probability: 0.0,
                answer: "skipped",
                category: None,
                skip: Some(reason),
                album: None,
                album_error: None,
            }),
            Outcome::YesNo { rule, probability } => applied.push(Applied {
                rule,
                probability,
                answer: if probability >= 0.5 { "yes" } else { "no" },
                category: None,
                skip: None,
                album: None,
                album_error: None,
            }),
            Outcome::Category {
                rule,
                probability,
                category,
            } => {
                let mut album_added = None;
                let mut album_error = None;
                if let (Some(category), Some(album)) = (category, album) {
                    match album
                        .account
                        .add_to_album(album.state, index, category, album.asset_id, id)
                        .await
                    {
                        Ok(()) => album_added = Some(category.to_owned()),
                        Err(err) => {
                            album_error = Some(if err.status() == StatusCode::FORBIDDEN {
                                "Your Immich API key cannot update albums. Check album permissions."
                            } else {
                                "Immich could not add this photo to the album."
                            })
                        }
                    }
                }
                applied.push(Applied {
                    rule,
                    probability,
                    answer: if category.is_some() { "yes" } else { "no" },
                    category: category.map(str::to_owned),
                    skip: None,
                    album: album_added,
                    album_error,
                });
            }
        }
    }
    let results: Vec<Value> = applied
        .into_iter()
        .map(|applied| {
            let tag = if applied.rule.kind == RuleKind::YesNo && applied.probability >= 0.5 {
                applied.rule.yes_tag.clone()
            } else if applied.rule.kind == RuleKind::YesNo {
                applied.rule.no_tag.clone()
            } else {
                String::new()
            };
            json!({
                "id": applied.rule.id,
                "kind": if applied.rule.kind == RuleKind::YesNo { "yesNo" } else { "category" },
                "question": applied.rule.question,
                "yesProbability": applied.probability,
                "answer": applied.answer,
                "tag": tag,
                "category": applied.category,
                "album": applied.album,
                "skipReason": applied.skip,
                "albumError": applied.album_error,
            })
        })
        .collect();
    Ok(
        json!({"target":target,"model":"LiquidAI/d1-2B","assessedAt":timestamp,"results":results,"tags":index.decision_tags(target).map_err(|_|index_error(id))?,"requestId":id}),
    )
}
