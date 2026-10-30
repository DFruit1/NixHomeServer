//! Immich owns every photo and tag association. Only its authenticated API is
//! used here; filesystem paths and upstream response bodies never reach clients.
use super::*;
use reqwest::Method;
use std::{path::Path as FilePath, time::Duration};
use zeroize::Zeroizing;

const PAGE_SIZE: usize = 48;
const MAX_PREVIEW_BYTES: usize = 16 * 1024 * 1024;

pub(super) struct Runtime {
    pub(super) base: reqwest::Url,
    eye: reqwest::Client,
    editor_group: String,
    mutations_enabled: bool,
}

impl Runtime {
    pub(super) fn new(
        base: &str,
        socket: &FilePath,
        editor_group: &str,
        mutations_enabled: bool,
    ) -> Result<Self, String> {
        let base = trusted_provider_base(base)?;
        if !base.path().ends_with('/') || !socket.is_absolute() {
            return Err("Immich API base must end in / and EYE socket must be absolute".into());
        }
        let eye = reqwest::Client::builder()
            .unix_socket(socket)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|_| "could not initialize EYE client")?;
        Ok(Self {
            base,
            eye,
            editor_group: editor_group.into(),
            mutations_enabled,
        })
    }
}

struct Account {
    runtime: Arc<Runtime>,
    key: Zeroizing<String>,
}

fn error(status: StatusCode, code: &'static str, message: &str, id: &str) -> ApiError {
    ApiError::new(status, code, message, id.to_owned())
}

fn unavailable(id: &str) -> ApiError {
    error(
        StatusCode::SERVICE_UNAVAILABLE,
        "immich_unavailable",
        "The Immich image integration is not enabled.",
        id,
    )
}

fn upstream_error(id: &str) -> ApiError {
    error(StatusCode::BAD_GATEWAY, "immich_request_failed", "Immich could not complete this request. Check the connection and your API key permissions.", id)
}

fn account(
    state: &ProviderBrokerState,
    identity: &Identity,
    id: &str,
) -> Result<Account, ApiError> {
    let runtime = state.images.clone().ok_or_else(|| unavailable(id))?;
    let mut credentials = state
        .store
        .load_credentials(identity, "immich")
        .map_err(|e| storage_failure(e, id))?
        .ok_or_else(|| {
            error(
                StatusCode::PRECONDITION_REQUIRED,
                "immich_account_required",
                "Connect your Immich API key in Metadata sources to browse your photos.",
                id,
            )
        })?;
    let key = credentials
        .remove("apiKey")
        .filter(|key| !key.trim().is_empty());
    zeroize_credentials(&mut credentials);
    let key = Zeroizing::new(key.ok_or_else(|| {
        error(
            StatusCode::PRECONDITION_REQUIRED,
            "immich_account_required",
            "Replace your saved Immich API key in Metadata sources.",
            id,
        )
    })?);
    Ok(Account { runtime, key })
}

impl Account {
    async fn send(
        &self,
        state: &ProviderBrokerState,
        method: Method,
        path: &str,
        body: Option<Value>,
        id: &str,
    ) -> Result<reqwest::Response, ApiError> {
        let url = self.runtime.base.join(path).map_err(|_| unavailable(id))?;
        let mut key = HeaderValue::from_str(&self.key).map_err(|_| upstream_error(id))?;
        key.set_sensitive(true);
        let mut request = state.client.request(method, url).header("x-api-key", key);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|_| upstream_error(id))?;
        match response.status() {
            status if status.is_success() => Ok(response),
            reqwest::StatusCode::NOT_FOUND => Err(error(
                StatusCode::NOT_FOUND,
                "immich_photo_not_found",
                "This photo is no longer available in your Immich library.",
                id,
            )),
            reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN => Err(error(
                StatusCode::FORBIDDEN,
                "immich_permission_denied",
                "Your Immich API key does not permit this action. Check its permissions in Immich.",
                id,
            )),
            reqwest::StatusCode::TOO_MANY_REQUESTS => Err(error(
                StatusCode::TOO_MANY_REQUESTS,
                "immich_rate_limited",
                "Immich is busy. Try again shortly.",
                id,
            )),
            _ => Err(upstream_error(id)),
        }
    }

    async fn json<T: DeserializeOwned>(
        &self,
        state: &ProviderBrokerState,
        method: Method,
        path: &str,
        body: Option<Value>,
        id: &str,
    ) -> Result<T, ApiError> {
        let response = self.send(state, method, path, body, id).await?;
        bounded_provider_json(response)
            .await
            .map_err(|_| upstream_error(id))
    }

    async fn asset(
        &self,
        state: &ProviderBrokerState,
        asset_id: &str,
        id: &str,
    ) -> Result<Asset, ApiError> {
        if !valid_mbid(asset_id) {
            return Err(error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "immich_photo_invalid",
                "Supply a valid Immich photo ID.",
                id,
            ));
        }
        let asset: Asset = self
            .json(state, Method::GET, &format!("assets/{asset_id}"), None, id)
            .await?;
        if asset.id != asset_id
            || asset.kind != "IMAGE"
            || asset.is_trashed
            || asset.visibility != "timeline"
        {
            return Err(error(
                StatusCode::NOT_FOUND,
                "immich_photo_not_found",
                "This photo is not available in the Immich timeline.",
                id,
            ));
        }
        if !asset.valid() {
            return Err(upstream_error(id));
        }
        Ok(asset)
    }

    async fn image(
        &self,
        state: &ProviderBrokerState,
        asset_id: &str,
        id: &str,
    ) -> Result<(Vec<u8>, String), ApiError> {
        // Preview is sufficient for EYE and never requests original downloads.
        let response = self
            .send(
                state,
                Method::GET,
                &format!("assets/{asset_id}/thumbnail?size=preview"),
                None,
                id,
            )
            .await?;
        let bytes = bounded_provider_bytes(response, MAX_PREVIEW_BYTES)
            .await
            .map_err(|_| upstream_error(id))?;
        let mime = sniff_image_content_type(&bytes).ok_or_else(|| upstream_error(id))?;
        Ok((bytes, mime))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Tag {
    id: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asset {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    original_file_name: String,
    file_created_at: String,
    is_trashed: bool,
    visibility: String,
    #[serde(default)]
    tags: Vec<Tag>,
}

impl Asset {
    fn valid(&self) -> bool {
        valid_mbid(&self.id)
            && self.original_file_name.len() <= 4096
            && self.file_created_at.len() <= 64
            && self.tags.len() <= 4096
            && self
                .tags
                .iter()
                .all(|tag| valid_mbid(&tag.id) && tag.value.len() <= 1024)
    }
    fn public(self) -> Value {
        json!({ "id": self.id, "filename": self.original_file_name, "capturedAt": self.file_created_at, "tags": self.tags })
    }
}

#[derive(Deserialize)]
pub(super) struct ListQuery {
    #[serde(default = "first_page")]
    page: u32,
    #[serde(default)]
    query: String,
}
fn first_page() -> u32 {
    1
}

#[derive(Deserialize)]
struct SearchResponse {
    assets: AssetPage,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssetPage {
    items: Vec<Asset>,
    next_page: Option<String>,
}

pub(super) async fn list(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    query: Result<Query<ListQuery>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let Query(query) = query.map_err(|_| {
        error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "immich_query_invalid",
            "Supply a valid page and filename search.",
            &id,
        )
    })?;
    if !(1..=100_000).contains(&query.page)
        || query.query.len() > 200
        || query.query.chars().any(char::is_control)
    {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "immich_query_invalid",
            "Supply a valid page and a filename search of at most 200 characters.",
            &id,
        ));
    }
    let account = account(&state, &identity, &id)?;
    let mut body = json!({ "type": "IMAGE", "visibility": "timeline", "page": query.page, "size": PAGE_SIZE, "withExif": false, "withPeople": false });
    if !query.query.trim().is_empty() {
        body["originalFileName"] = json!(query.query.trim());
    }
    let response: SearchResponse = account
        .json(&state, Method::POST, "search/metadata", Some(body), &id)
        .await?;
    if response.assets.items.len() > PAGE_SIZE
        || response.assets.items.iter().any(|asset| !asset.valid())
    {
        return Err(upstream_error(&id));
    }
    let next_page = response
        .assets
        .next_page
        .map(|page| page.parse::<u32>())
        .transpose()
        .map_err(|_| upstream_error(&id))?;
    if next_page.is_some_and(|page| page <= query.page || page > 100_000) {
        return Err(upstream_error(&id));
    }
    let items = response
        .assets
        .items
        .into_iter()
        .filter(|asset| {
            asset.kind == "IMAGE" && !asset.is_trashed && asset.visibility == "timeline"
        })
        .map(Asset::public)
        .collect::<Vec<_>>();
    Ok(Json(
        json!({ "items": items, "nextPage": next_page, "canTag": account.runtime.mutations_enabled && identity.can_edit(&account.runtime.editor_group), "requestId": id }),
    ))
}

pub(super) async fn details(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let asset = account.asset(&state, &asset_id, &id).await?;
    Ok(Json(json!({ "image": asset.public(), "requestId": id })))
}

pub(super) async fn preview(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Response, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    account.asset(&state, &asset_id, &id).await?;
    let (bytes, mime) = account.image(&state, &asset_id, &id).await?;
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_string()),
        ],
        bytes,
    )
        .into_response())
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Suggestion {
    tag: String,
    confidence: f64,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Scores {
    aesthetic: f64,
    keeper: f64,
    cover: f64,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Analysis {
    model: String,
    suggestions: Vec<Suggestion>,
    scores: Scores,
}

fn valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag.len() <= 96
        && tag
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
}
fn probability(n: f64) -> bool {
    n.is_finite() && (0.0..=1.0).contains(&n)
}

pub(super) async fn analyze(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    account.asset(&state, &asset_id, &id).await?;
    let (bytes, mime) = account.image(&state, &asset_id, &id).await?;
    // A distinct Unix-socket client carries pixels only, never the user's key.
    let response = account
        .runtime
        .eye
        .post("http://localhost/analyze")
        .header(header::CONTENT_TYPE, mime)
        .body(bytes)
        .send()
        .await
        .map_err(|_| {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "eye_unavailable",
                "EYE is not ready. Try the photo again shortly.",
                &id,
            )
        })?;
    if response.status() == reqwest::StatusCode::SERVICE_UNAVAILABLE {
        return Err(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "eye_busy",
            "EYE is analyzing another photo. Try again shortly.",
            &id,
        ));
    }
    if !response.status().is_success() {
        return Err(error(
            StatusCode::BAD_GATEWAY,
            "eye_analysis_failed",
            "EYE could not analyze this photo.",
            &id,
        ));
    }
    let analysis: Analysis = bounded_provider_json(response).await.map_err(|_| {
        error(
            StatusCode::BAD_GATEWAY,
            "eye_analysis_invalid",
            "EYE returned an invalid analysis.",
            &id,
        )
    })?;
    if analysis.model != "eye@v1.0.0"
        || analysis.suggestions.len() > 64
        || analysis
            .suggestions
            .iter()
            .any(|s| !valid_tag(&s.tag) || !probability(s.confidence))
        || ![
            analysis.scores.aesthetic,
            analysis.scores.keeper,
            analysis.scores.cover,
        ]
        .into_iter()
        .all(probability)
    {
        return Err(error(
            StatusCode::BAD_GATEWAY,
            "eye_analysis_invalid",
            "EYE returned an invalid analysis.",
            &id,
        ));
    }
    Ok(Json(
        json!({ "assetId": asset_id, "analysis": analysis, "requestId": id }),
    ))
}

fn same_origin(headers: &HeaderMap, id: &str) -> Result<(), ApiError> {
    homelab_common::assert_same_origin(headers).map_err(|_| {
        error(
            StatusCode::FORBIDDEN,
            "same_origin_required",
            "Use this action from Media Manager.",
            id,
        )
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AddTagsRequest {
    tags: Vec<String>,
}
#[derive(Deserialize)]
struct TagCount {
    count: u64,
}

pub(super) async fn add_tags(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
    payload: Result<Json<AddTagsRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    if !identity.can_edit(&account.runtime.editor_group) || !account.runtime.mutations_enabled {
        return Err(error(
            StatusCode::FORBIDDEN,
            "image_tagging_disabled",
            "Image tagging requires editor access and enabled changes in Media Manager.",
            &id,
        ));
    }
    let Json(request) = payload.map_err(|_| invalid_json(&id))?;
    if request.tags.is_empty()
        || request.tags.len() > 32
        || request.tags.iter().any(|tag| !valid_tag(tag))
    {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "image_tags_invalid",
            "Choose between 1 and 32 EYE tags.",
            &id,
        ));
    }
    account.asset(&state, &asset_id, &id).await?;
    let names = request
        .tags
        .into_iter()
        .map(|tag| format!("EYE/{tag}"))
        .collect::<BTreeSet<_>>();
    // Immich's upsert and bulk-add are additive and idempotent. Never replace an
    // asset's tag set, manipulate the DB, write EXIF or create image sidecars.
    let tags: Vec<Tag> = account
        .json(
            &state,
            Method::PUT,
            "tags",
            Some(json!({ "tags": names })),
            &id,
        )
        .await?;
    if tags.len() != names.len()
        || tags
            .iter()
            .any(|tag| !valid_mbid(&tag.id) || !names.contains(&tag.value))
        || tags
            .iter()
            .map(|tag| &tag.value)
            .collect::<BTreeSet<_>>()
            .len()
            != names.len()
    {
        return Err(upstream_error(&id));
    }
    let tag_ids = tags.iter().map(|tag| &tag.id).collect::<Vec<_>>();
    let result: TagCount = account
        .json(
            &state,
            Method::PUT,
            "tags/assets",
            Some(json!({ "assetIds": [asset_id], "tagIds": tag_ids })),
            &id,
        )
        .await?;
    if result.count > tags.len() as u64 {
        return Err(upstream_error(&id));
    }
    let asset = account.asset(&state, &asset_id, &id).await?;
    if !tag_ids
        .iter()
        .all(|id| asset.tags.iter().any(|tag| &tag.id == *id))
    {
        return Err(error(StatusCode::BAD_GATEWAY, "image_tags_incomplete", "Some tags were not confirmed in Immich. Refresh this photo before retrying; existing tags are preserved.", &id));
    }
    eprintln!(
        "{}",
        json!({ "level": "info", "service": "media-manager-provider-broker", "event": "immich_tags_added", "requestId": id, "tagCount": tags.len() })
    );
    Ok(Json(json!({ "image": asset.public(), "requestId": id })))
}
