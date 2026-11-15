//! Bonsai checks each photo's EYE tags against the photo and removes tags
//! that do not describe it. It can only remove EYE's own tags: the answer
//! schema lists exactly those tags, and EYE's confidence is kept for the rest.
//! A later EYE retag replaces the reviewed tags and queues a fresh review.
use super::*;
use base64::Engine;

/// Changing the prompt, image size or reviewer model changes this identity.
const REVIEW_VERSION: &str = "tag-review-v2";
/// Previews are reduced to fit this box before review. Measured on Bonsai
/// with hand-labelled photos: the full ~1440 px preview took 27 s a photo
/// (vision encoding runs on the CPU); 768 px took 9 s and caught as many
/// wrong tags, while 512 px started missing them.
const REVIEW_IMAGE_SIZE: u32 = 768;
/// Listing only the wrong tags generated far fewer tokens than a verdict per
/// tag, and removed fewer correct tags. Several photos per request saved no
/// time (each image is still encoded separately) and confused photos.
const PROMPT: &str = "An automatic photo tagger proposed the tags below. Some are mistakes: \
things not in the photo at all, or a wrong kind of scene. List only the tags that are clearly \
wrong for the photo. Keep anything visible, even small or in the background, and anything \
that fairly describes the scene.\n\nTags: ";
/// EYE's photo type, keep/reject, sensitive-content, rotation and face or
/// quality judgements are not things the photo shows, so only its scene tags
/// are reviewed; these pass through unchanged.
const UNREVIEWED: &[&str] = &[
    // type
    "photo",
    "selfie",
    "screenshot",
    "photo_of_screen",
    "receipt",
    "document",
    "id_card",
    "whiteboard",
    "map",
    "chart_or_slide",
    "meme_or_graphic",
    "illustration_or_art",
    "shopping_reference",
    "medical_reference",
    "repair_reference",
    "other",
    "reference",
    // keep / reject
    "keeper",
    "forgettable",
    "accidental",
    "technical_flaw",
    "unusable",
    "bad_framing",
    "bad_lighting",
    "test_or_duplicate_shot",
    "reference_photo",
    "low_content",
    // sensitive
    "sensitive",
    "nsfw_explicit",
    "nsfw_suggestive",
    "blood_injury",
    "medical_hospital",
    "funeral",
    "accident_disaster",
    "violence_protest",
    "weapon",
    // photo, people and face judgements
    "rotated",
    "people",
    "group_shot",
    "portrait",
    "eyes_closed",
    "smiling",
    "everyone_smiling",
    "everyone_looking",
    "candid",
    "sharp",
    "blurry",
    "bokeh",
    "peak_moment",
    "looking_at_camera",
    "looking_away",
    "happy",
    "surprised",
];

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
        // The gate admits waiting requests in arrival order, so anything that
        // queued during a review runs before the next one; a long pause here
        // only idled Bonsai (it was a third of each photo's time live).
        let pause = if busy {
            120
        } else if reviewed {
            1
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
    let tags: Vec<String> = analysis
        .suggestions
        .iter()
        .map(|s| s.tag.clone())
        .filter(|tag| !UNREVIEWED.contains(&tag.as_str()))
        .collect();
    let removed = if tags.is_empty() {
        Vec::new()
    } else {
        // The owner's key reads the preview, so lost access stops the review.
        let (bytes, _) = match account.image(state, asset_id, id).await {
            Ok(image) => image,
            Err(err) if err.status() == StatusCode::NOT_FOUND => {
                return Err(ReviewError::Photo(DAY))
            }
            Err(_) => return Err(ReviewError::Account),
        };
        let jpeg = tokio::task::spawn_blocking(move || reduce(&bytes))
            .await
            .ok()
            .flatten()
            .ok_or(ReviewError::Photo(30 * DAY))?;
        let wrong = ask(bonsai, &jpeg, &tags).await?;
        // Bonsai may reject every scene tag: on close-ups of gadgets and labels
        // EYE's scene tags are often all wrong (a cable on carpet tagged lake,
        // lamp and houseplant), and checked live, those rejections were right.
        tags.iter()
            .filter(|t| wrong.contains(*t))
            .cloned()
            .collect()
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

/// Fit the preview within the review size as a JPEG.
fn reduce(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(12_000);
    limits.max_image_height = Some(12_000);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = image::ImageDecoder::orientation(&mut decoder).ok();
    let mut photo = image::DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        photo.apply_orientation(orientation);
    }
    if photo.width().max(photo.height()) > REVIEW_IMAGE_SIZE {
        photo = photo.thumbnail(REVIEW_IMAGE_SIZE, REVIEW_IMAGE_SIZE);
    }
    let mut out = Vec::new();
    photo
        .to_rgb8()
        .write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(
            &mut out, 85,
        ))
        .ok()?;
    Some(out)
}

/// The tags Bonsai judges wrong. The schema admits only the proposed tags,
/// so Bonsai cannot add or rename one.
async fn ask(bonsai: &Bonsai, jpeg: &[u8], tags: &[String]) -> Result<Vec<String>, ReviewError> {
    let schema = json!({"type":"object","properties":{"wrong":{"type":"array","items":{"type":"string","enum":tags},"uniqueItems":true}},"required":["wrong"]});
    let image = base64::engine::general_purpose::STANDARD.encode(jpeg);
    let body = json!({
        "model": bonsai.model,
        "temperature": 0,
        "max_tokens": 16 + 12 * tags.len(),
        // A visual check gains little from long reasoning, and the
        // reasoning budget would multiply the time for every photo.
        "chat_template_kwargs": {"enable_thinking": false},
        "response_format": {"type":"json_schema","json_schema":{"name":"tag_review","schema":schema}},
        "messages": [{"role":"user","content":[
            {"type":"image_url","image_url":{"url":format!("data:image/jpeg;base64,{image}")}},
            {"type":"text","text":format!("{PROMPT}{}", tags.join(", "))}
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
    #[derive(Deserialize)]
    struct Answer {
        wrong: Vec<String>,
    }
    let answer: Answer = serde_json::from_str(text).map_err(|_| ReviewError::Photo(86_400))?;
    if answer.wrong.iter().any(|tag| !tags.contains(tag)) {
        return Err(ReviewError::Photo(86_400));
    }
    Ok(answer.wrong)
}
