//! d1 receives bounded pixels/text only; credentials never leave the broker.
use super::*;
use crate::decision_index::Rule;
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
    if input.rules.len() > 16
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
    error(StatusCode::UNPROCESSABLE_ENTITY,"decision_invalid", "Save up to 16 questions. Use unique IDs, questions up to 1000 bytes and tags up to 96 bytes without commas or control characters.",id)
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
    let (bytes, mime) = account.image(&state, &asset_id, &id).await?;
    let input = json!({"state":format!("Assess this personal photo: {}",asset.original_file_name),"images":[format!("data:{mime};base64,{}",STANDARD.encode(bytes))]});
    let result = evaluate(&account.runtime, &index, &asset_id, &rules, input, &id).await?;
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
    Ok(Json(
        evaluate(&account.runtime, &index, &target, &rules, input, &id).await?,
    ))
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
    let (bytes, mime) = account.image(state, &asset.id, id).await?;
    let input = json!({"state":format!("Assess this personal photo: {}",asset.original_file_name),"images":[format!("data:{mime};base64,{}",STANDARD.encode(bytes))]});
    evaluate(&account.runtime, index, &asset.id, &pending, input, id).await?;
    Ok(())
}

pub(super) async fn evaluate(
    runtime: &Runtime,
    index: &Index<'_>,
    target: &str,
    rules: &[Rule],
    mut input: Value,
    id: &str,
) -> Result<Value, ApiError> {
    let _guard = runtime
        .decision_gate
        .try_lock()
        .map_err(|_| decision_error(id))?;
    let mut questions = serde_json::Map::new();
    for rule in rules {
        questions.insert(
            rule.id.clone(),
            json!({"type":"noul","instructions":rule.question}),
        );
    }
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
    let probabilities: Vec<f64> = rules
        .iter()
        .map(|r| {
            response["answers"][&r.id]["noul"]
                .as_f64()
                .filter(|p| probability(*p))
                .ok_or_else(|| decision_error(id))
        })
        .collect::<Result<_, _>>()?;
    let timestamp = chrono::Local::now().format("%Y%m%d %H:%M").to_string();
    if !index
        .save_decisions(target, rules, &probabilities, &timestamp)
        .map_err(|_| index_error(id))?
    {
        return Err(error(
            StatusCode::CONFLICT,
            "decision_rules_changed",
            "Questions changed during assessment. Assess again using the saved questions.",
            id,
        ));
    }
    let results:Vec<Value>=rules.iter().zip(probabilities).map(|(r,p)|json!({"id":r.id,"question":r.question,"yesProbability":p,"answer":if p>=0.5{"yes"}else{"no"},"tag":if p>=0.5{&r.yes_tag}else{&r.no_tag}})).collect();
    Ok(
        json!({"target":target,"model":"LiquidAI/d1-2B","assessedAt":timestamp,"results":results,"tags":index.decision_tags(target).map_err(|_|index_error(id))?,"requestId":id}),
    )
}
