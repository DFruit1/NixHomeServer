//! Bonsai checks each photo's EYE tags against the photo and removes tags
//! that do not describe it. It can only remove EYE's own tags: the answer
//! schema lists exactly those tags, and EYE's confidence is kept for the rest.
//! A later EYE retag replaces the reviewed tags and queues a fresh review.
use super::*;
use base64::Engine;

/// Changing the prompt or reviewer model changes this identity.
const REVIEW_VERSION: &str = "tag-review-v1";
/// The gate rejects bodies over 15 MiB; base64 adds a third.
const MAX_REVIEW_IMAGE_BYTES: usize = 10 * 1024 * 1024;
const PROMPT: &str = "An automatic photo tagger proposed the tags below for this photo. \
For each tag, answer true if it describes something visible in the photo, or the photo's \
scene, setting, activity, subject or style. Answer false only if the tag is wrong or \
unrelated to this photo. If a tag is plausible but you are unsure, answer true.\n\nTags:";

#[derive(Clone)]
pub(in crate::provider_account_http) struct Bonsai {
    client: reqwest::Client,
    url: reqwest::Url,
    model: String,
}

impl Bonsai {
    /// `base` is the deployment's loopback Bonsai gate, e.g. `http://127.0.0.1:8094/v1`.
    pub(in crate::provider_account_http) fn new(base: &str, model: &str) -> Result<Self, String> {
        let base = reqwest::Url::parse(base.trim_end_matches('/'))
            .map_err(|_| "Bonsai URL is invalid".to_string())?;
        let loopback = base
            .host_str()
            .map(|host| host.trim_start_matches('[').trim_end_matches(']'))
            .and_then(|host| host.parse::<std::net::IpAddr>().ok())
            .is_some_and(|ip| ip.is_loopback());
        if base.scheme() != "http" || !loopback || model.is_empty() {
            return Err("Bonsai URL must be a loopback http address and its model named".into());
        }
        Ok(Self {
            url: reqwest::Url::parse(&format!("{base}/chat/completions"))
                .map_err(|_| "Bonsai URL is invalid".to_string())?,
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                // The gate queues for up to a minute, then allows ten minutes upstream.
                .timeout(Duration::from_secs(690))
                .build()
                .map_err(|_| "could not initialize Bonsai client")?,
            model: model.to_string(),
        })
    }

    fn reviewer(&self) -> String {
        format!("{}/{REVIEW_VERSION}", self.model)
    }
}

enum ReviewError {
    /// Bonsai is serving someone else or not ready; retry the same photo.
    Busy,
    /// This photo could not be reviewed; skip it for a while.
    Photo(i64),
    /// The account or index is unavailable; try the account again later.
    Account,
}

pub(in crate::provider_account_http) async fn run_tag_review(state: ProviderBrokerState) {
    let Some(runtime) = state.images.clone() else {
        return;
    };
    let Some(bonsai) = runtime.bonsai.clone() else {
        return;
    };
    loop {
        let mut reviewed = false;
        let mut busy = false;
        match state.store.image_accounts(runtime.managed) {
            Ok(identities) => {
                for identity in identities {
                    match review_next(&state, &runtime, &bonsai, &identity).await {
                        Ok(done) => reviewed |= done,
                        Err(ReviewError::Busy) => {
                            busy = true;
                            break;
                        }
                        Err(_) => eprintln!(
                            "{}",
                            json!({"service":"media-manager-provider-broker","event":"photo_tag_review_retry"})
                        ),
                    }
                }
            }
            Err(_) => eprintln!(
                "{}",
                json!({"service":"media-manager-provider-broker","event":"image_accounts_unavailable"})
            ),
        }
        // A short pause between photos lets queued interactive Bonsai
        // requests take the single slot before the next review.
        let pause = if busy {
            120
        } else if reviewed {
            5
        } else {
            300
        };
        tokio::time::sleep(Duration::from_secs(pause)).await;
    }
}

/// Review one photo for this account. Ok(false) means nothing was pending.
async fn review_next(
    state: &ProviderBrokerState,
    runtime: &Arc<Runtime>,
    bonsai: &Bonsai,
    identity: &Identity,
) -> Result<bool, ReviewError> {
    let id = request_id();
    let account =
        load_account(state, identity, runtime.clone(), &id).map_err(|_| ReviewError::Account)?;
    let scope = account.scope(identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    let now = unix_timestamp();
    let Some((asset_id, stored)) = index
        .next_tag_review(now)
        .map_err(|_| ReviewError::Account)?
    else {
        return Ok(false);
    };
    let result = review(state, &account, bonsai, &index, &asset_id, &stored, &id).await;
    match result {
        Err(ReviewError::Photo(delay)) => {
            index
                .retry_tag_review(&asset_id, now + delay)
                .map_err(|_| ReviewError::Account)?;
            eprintln!(
                "{}",
                json!({"service":"media-manager-provider-broker","event":"photo_tag_review_failed","requestId":id})
            );
            Ok(true)
        }
        other => other.map(|()| true),
    }
}

async fn review(
    state: &ProviderBrokerState,
    account: &Account,
    bonsai: &Bonsai,
    index: &Index<'_>,
    asset_id: &str,
    stored: &str,
    id: &str,
) -> Result<(), ReviewError> {
    const DAY: i64 = 86_400;
    let analysis: Analysis = serde_json::from_str(stored)
        .ok()
        .filter(|a: &Analysis| a.model == MODEL)
        .ok_or(ReviewError::Photo(30 * DAY))?;
    let tags: Vec<String> = analysis.suggestions.iter().map(|s| s.tag.clone()).collect();
    let removed = if tags.is_empty() {
        Vec::new()
    } else {
        // The owner's key reads the preview, so lost access stops the review.
        let (bytes, mime) = match account.image(state, asset_id, id).await {
            Ok(image) => image,
            Err(err) if err.status() == StatusCode::NOT_FOUND => {
                return Err(ReviewError::Photo(DAY))
            }
            Err(_) => return Err(ReviewError::Account),
        };
        if bytes.len() > MAX_REVIEW_IMAGE_BYTES || mime == "image/webp" {
            return Err(ReviewError::Photo(30 * DAY));
        }
        let verdict = ask(bonsai, &bytes, &mime, &tags).await?;
        let removed: Vec<String> = tags
            .iter()
            .filter(|tag| verdict.get(*tag) == Some(&false))
            .cloned()
            .collect();
        // Rejecting every tag of a well-tagged photo is more likely a failed
        // reading than a photo EYE got entirely wrong; keep EYE's tags.
        if removed.len() == tags.len() && tags.len() >= 4 {
            eprintln!(
                "{}",
                json!({"service":"media-manager-provider-broker","event":"photo_tag_review_rejected_all","requestId":id})
            );
            Vec::new()
        } else {
            removed
        }
    };
    let mut kept = analysis.clone();
    kept.suggestions.retain(|s| !removed.contains(&s.tag));
    let saved = index
        .save_tag_review(asset_id, stored, &kept, &removed, &bonsai.reviewer())
        .map_err(|_| ReviewError::Account)?;
    eprintln!(
        "{}",
        json!({"service":"media-manager-provider-broker","event":if saved {"photo_tags_reviewed"} else {"photo_tag_review_superseded"},
            "kept":kept.suggestions.len(),"removed":removed.len(),"requestId":id})
    );
    Ok(())
}

/// One verdict per proposed tag. The schema admits only the proposed tags,
/// so Bonsai cannot add or rename one.
async fn ask(
    bonsai: &Bonsai,
    bytes: &[u8],
    mime: &str,
    tags: &[String],
) -> Result<std::collections::BTreeMap<String, bool>, ReviewError> {
    let properties: serde_json::Map<String, Value> = tags
        .iter()
        .map(|tag| (tag.clone(), json!({"type":"boolean"})))
        .collect();
    let schema = json!({"type":"object","properties":properties,"required":tags,"additionalProperties":false});
    let list: String = tags.iter().map(|tag| format!("\n- {tag}")).collect();
    let image = base64::engine::general_purpose::STANDARD.encode(bytes);
    let body = json!({
        "model": bonsai.model,
        "temperature": 0,
        "max_tokens": 64 + 16 * tags.len(),
        // A visual check gains little from long reasoning, and the
        // reasoning budget would multiply the time for every photo.
        "chat_template_kwargs": {"enable_thinking": false},
        "response_format": {"type":"json_schema","json_schema":{"name":"tag_review","schema":schema}},
        "messages": [{"role":"user","content":[
            {"type":"image_url","image_url":{"url":format!("data:{mime};base64,{image}")}},
            {"type":"text","text":format!("{PROMPT}{list}")}
        ]}],
    });
    let response = bonsai
        .client
        .post(bonsai.url.clone())
        .json(&body)
        .send()
        .await
        .map_err(|err| {
            if err.is_timeout() {
                ReviewError::Photo(6 * 3600)
            } else {
                ReviewError::Busy
            }
        })?;
    match response.status().as_u16() {
        429 | 503 | 504 => return Err(ReviewError::Busy),
        status if !(200..300).contains(&status) => return Err(ReviewError::Photo(6 * 3600)),
        _ => {}
    }
    let reply: Value = response
        .json()
        .await
        .map_err(|_| ReviewError::Photo(86_400))?;
    let text = reply["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .trim();
    let text = text
        .find('{')
        .zip(text.rfind('}'))
        .and_then(|(start, end)| text.get(start..=end))
        .unwrap_or_default();
    let verdict: std::collections::BTreeMap<String, bool> =
        serde_json::from_str(text).map_err(|_| ReviewError::Photo(86_400))?;
    if verdict.len() != tags.len() || tags.iter().any(|tag| !verdict.contains_key(tag)) {
        return Err(ReviewError::Photo(86_400));
    }
    Ok(verdict)
}
