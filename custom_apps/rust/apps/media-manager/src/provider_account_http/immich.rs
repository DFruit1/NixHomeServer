//! Only saved decision rules may add the assessed photo to a named album or
//! archive it in Immich. Derived EYE tags and scores stay in our private index.
use super::*;
use reqwest::Method;
use std::{path::Path as FilePath, time::Duration};
use zeroize::Zeroizing;

use crate::image_index::{probability, valid_tag, Analysis, Index, Search, MODEL, PAGE_SIZE};
pub(super) mod decisions;
mod indexing;
pub(super) use indexing::{indexed, run_indexer};
const MAX_PREVIEW_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone)]
pub(super) struct Runtime {
    pub(super) managed: bool,
    pub(super) base: reqwest::Url,
    pub(super) eye: reqwest::Client,
    pub(super) decision: reqwest::Client,
    decision_gate: Arc<tokio::sync::Mutex<()>>,
    album_gate: Arc<tokio::sync::Mutex<()>>,
    gate: Arc<tokio::sync::Mutex<()>>,
}

impl Runtime {
    pub(super) fn new(base: &str, socket: &FilePath) -> Result<Self, String> {
        let base = trusted_provider_base(base)?;
        if !base.path().ends_with('/') || !socket.is_absolute() {
            return Err("Immich API base must end in / and EYE socket must be absolute".into());
        }
        let eye = reqwest::Client::builder()
            .unix_socket(socket)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(28))
            .build()
            .map_err(|_| "could not initialize EYE client")?;
        Ok(Self {
            managed: false,
            base,
            eye,
            decision: decision_client(FilePath::new("/run/media-manager-decision/d1.sock"))?,
            decision_gate: Arc::default(),
            album_gate: Arc::default(),
            gate: Arc::default(),
        })
    }
}

pub(super) fn decision_client(socket: &FilePath) -> Result<reqwest::Client, String> {
    if !socket.is_absolute() {
        return Err("d1 socket must be absolute".into());
    }
    reqwest::Client::builder()
        .unix_socket(socket)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(240))
        .build()
        .map_err(|_| "could not initialize d1 client".into())
}

#[derive(Clone)]
pub(super) struct Account {
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
    error(
        StatusCode::BAD_GATEWAY,
        "immich_request_failed",
        "Immich could not complete this request. Try again or check the Photos service.",
        id,
    )
}

fn account(
    state: &ProviderBrokerState,
    identity: &Identity,
    id: &str,
) -> Result<Account, ApiError> {
    let runtime = state.images.clone().ok_or_else(|| unavailable(id))?;
    if runtime.managed && !identity.groups.iter().any(|g| g == "immich-users") {
        return Err(error(
            StatusCode::FORBIDDEN,
            "immich_access_required",
            "Your account does not have access to Photos.",
            id,
        ));
    }
    load_account(state, identity, runtime, id)
}

fn load_account(
    state: &ProviderBrokerState,
    identity: &Identity,
    runtime: Arc<Runtime>,
    id: &str,
) -> Result<Account, ApiError> {
    let mut credentials = state
        .store
        .load_credentials(identity, if runtime.managed { "immich-managed" } else { "immich" })
        .map_err(|e| storage_failure(e, id))?
        .ok_or_else(|| {
            error(
                StatusCode::PRECONDITION_REQUIRED,
                if runtime.managed { "immich_provisioning_pending" } else { "immich_account_required" },
                if runtime.managed { "Sign into Photos once to create your Immich account. Media Manager connects automatically within a few minutes." } else { "Connect your Immich API key in Metadata sources to browse your photos." },
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
    fn scope(&self, identity: &Identity) -> String {
        use sha2::{Digest, Sha256};
        let mut hash = Sha256::new();
        hash.update(identity.subject.as_bytes());
        hash.update([0]);
        hash.update(self.runtime.base.as_str().as_bytes());
        hash.update([0]);
        hash.update(self.key.as_bytes());
        format!("{:x}", hash.finalize())
    }

    async fn send(
        &self,
        state: &ProviderBrokerState,
        method: Method,
        path: &str,
        body: Option<Value>,
        id: &str,
    ) -> Result<reqwest::Response, ApiError> {
        let archive = method == Method::PATCH
            && path.strip_prefix("assets/").is_some_and(valid_mbid)
            && body.as_ref() == Some(&json!({"visibility": "archive"}));
        if method != Method::GET
            && !(method == Method::POST && path == "search/metadata")
            && !archive
        {
            return Err(error(
                StatusCode::FORBIDDEN,
                "immich_read_only",
                "This Immich write is not permitted.",
                id,
            ));
        }
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
            || !matches!(asset.visibility.as_str(), "timeline" | "archive")
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

    /// Immich 3.x updateAsset: PATCH /assets/:id with visibility=archive.
    /// Only the assessed asset is addressed; originals and other metadata stay intact.
    async fn archive(
        &self,
        state: &ProviderBrokerState,
        asset_id: &str,
        id: &str,
    ) -> Result<(), ApiError> {
        let asset = self.asset(state, asset_id, id).await?;
        if asset.visibility == "archive" {
            return Ok(());
        }
        self.send(
            state,
            Method::PATCH,
            &format!("assets/{asset_id}"),
            Some(json!({"visibility":"archive"})),
            id,
        )
        .await?;
        // Check the observed state rather than assuming a successful response applied it.
        if self.asset(state, asset_id, id).await?.visibility != "archive" {
            return Err(upstream_error(id));
        }
        Ok(())
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

    async fn album_response(
        &self,
        state: &ProviderBrokerState,
        method: Method,
        url: reqwest::Url,
        body: Option<Value>,
        id: &str,
    ) -> Result<reqwest::Response, ApiError> {
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
                "immich_album_not_found",
                "This album is no longer available in your Immich library.",
                id,
            )),
            reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN => Err(error(
                StatusCode::FORBIDDEN,
                "immich_permission_denied",
                "Your Immich API key does not permit album actions. Check its permissions in Immich.",
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

    async fn find_album(
        &self,
        state: &ProviderBrokerState,
        name: &str,
        id: &str,
    ) -> Result<Option<String>, ApiError> {
        // Exact-name search stays bounded to the caller's own albums; a shared
        // album with the same name is never selected or modified.
        let mut url = self
            .runtime
            .base
            .join("albums")
            .map_err(|_| unavailable(id))?;
        url.query_pairs_mut()
            .append_pair("name", name)
            .append_pair("isOwned", "true");
        let response = self
            .album_response(state, Method::GET, url, None, id)
            .await?;
        let albums: Vec<Album> = bounded_provider_json(response)
            .await
            .map_err(|_| upstream_error(id))?;
        if albums.len() > 10_000 {
            return Err(upstream_error(id));
        }
        Ok(albums
            .into_iter()
            .find(|album| album.album_name == name && valid_mbid(&album.id))
            .map(|album| album.id))
    }

    async fn create_album(
        &self,
        state: &ProviderBrokerState,
        name: &str,
        asset: &str,
        id: &str,
    ) -> Result<String, ApiError> {
        let url = self
            .runtime
            .base
            .join("albums")
            .map_err(|_| unavailable(id))?;
        let response = self
            .album_response(
                state,
                Method::POST,
                url,
                Some(json!({"albumName": name, "assetIds": [asset]})),
                id,
            )
            .await?;
        let album: Album = bounded_provider_json(response)
            .await
            .map_err(|_| upstream_error(id))?;
        if album.album_name != name || !valid_mbid(&album.id) {
            return Err(upstream_error(id));
        }
        Ok(album.id)
    }

    async fn add_album_asset(
        &self,
        state: &ProviderBrokerState,
        album_id: &str,
        asset: &str,
        id: &str,
    ) -> Result<(), ApiError> {
        if !valid_mbid(album_id) {
            return Err(upstream_error(id));
        }
        let url = self
            .runtime
            .base
            .join(&format!("albums/{album_id}/assets"))
            .map_err(|_| unavailable(id))?;
        let response = self
            .album_response(state, Method::PUT, url, Some(json!({"ids": [asset]})), id)
            .await?;
        let results: Vec<Value> = bounded_provider_json(response)
            .await
            .map_err(|_| upstream_error(id))?;
        // Immich reports individual failures inside an HTTP-success response.
        // A duplicate proves membership and makes retries safe after a lost reply.
        if results.len() != 1 || results[0]["id"].as_str() != Some(asset) {
            return Err(upstream_error(id));
        }
        let result = &results[0];
        if result["success"].as_bool() == Some(true)
            || (result["success"].as_bool() == Some(false)
                && result["error"].as_str() == Some("duplicate"))
        {
            return Ok(());
        }
        if result["error"].as_str() == Some("no_permission") {
            return Err(error(
                StatusCode::FORBIDDEN,
                "immich_album_forbidden",
                "Your Immich API key cannot add this photo to the album.",
                id,
            ));
        }
        Err(upstream_error(id))
    }

    /// Add exactly one assessed photo to the album named by a saved category
    /// rule. Album IDs are cached by name; a vanished album is recreated.
    pub(super) async fn add_to_album(
        &self,
        state: &ProviderBrokerState,
        index: &Index<'_>,
        name: &str,
        asset: &str,
        id: &str,
    ) -> Result<(), ApiError> {
        let _guard = self.runtime.album_gate.lock().await;
        if let Some(album_id) = index.album_id(name).map_err(|_| index_error(id))? {
            match self.add_album_asset(state, &album_id, asset, id).await {
                Ok(()) => return Ok(()),
                Err(err) if err.status() == StatusCode::NOT_FOUND => {
                    index.forget_album(name).map_err(|_| index_error(id))?;
                }
                Err(err) => return Err(err),
            }
        }
        let album_id = match self.find_album(state, name, id).await? {
            Some(album_id) => {
                self.add_album_asset(state, &album_id, asset, id).await?;
                album_id
            }
            None => {
                let album_id = self.create_album(state, name, asset, id).await?;
                // Creation may silently omit assets the caller cannot share.
                self.add_album_asset(state, &album_id, asset, id).await?;
                album_id
            }
        };
        index
            .save_album(name, &album_id)
            .map_err(|_| index_error(id))?;
        Ok(())
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Album {
    id: String,
    album_name: String,
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
        json!({ "items": items, "nextPage": next_page, "canTag": false, "requestId": id }),
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
    let scope = account.scope(&identity);
    let analysis = Index {
        store: &state.store,
        scope: &scope,
    }
    .analysis(&asset_id)
    .map_err(|_| index_error(&id))?;
    let tags = Index {
        store: &state.store,
        scope: &scope,
    }
    .decision_tags(&asset_id)
    .map_err(|_| index_error(&id))?;
    let mut image = asset.public();
    image["decisionTags"] = json!(tags);
    image["tagged"] = json!(Index {
        store: &state.store,
        scope: &scope
    }
    .tagged(&asset_id)
    .map_err(|_| index_error(&id))?);
    Ok(Json(
        json!({ "image": image, "analysis": analysis, "requestId": id }),
    ))
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

fn index_error(id: &str) -> ApiError {
    error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "image_index_failed",
        "The photo index could not be accessed. Try again shortly.",
        id,
    )
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
    let analysis = analyze_asset(&state, &account, &index, &asset_id, &id, false).await?;
    Ok(Json(
        json!({ "assetId": asset_id, "analysis": analysis, "requestId": id }),
    ))
}

pub(super) async fn retag(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    let account = account(&state, &identity, &id)?;
    let asset = account.asset(&state, &asset_id, &id).await?;
    let _guard = account.runtime.gate.try_lock().map_err(|_| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "eye_busy",
            "EYE is analyzing a photo. Wait for it to finish, then mark this photo for retagging.",
            &id,
        )
    })?;
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
    index
        .mark_for_retagging(&asset_id)
        .map_err(|_| index_error(&id))?;
    Ok(Json(
        json!({"assetId":asset_id, "tagged":false, "requestId":id}),
    ))
}

pub(super) async fn analyze_asset(
    state: &ProviderBrokerState,
    account: &Account,
    index: &Index<'_>,
    asset_id: &str,
    id: &str,
    wait: bool,
) -> Result<Analysis, ApiError> {
    let _guard = if wait {
        account.runtime.gate.lock().await
    } else {
        account.runtime.gate.try_lock().map_err(|_| {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "eye_busy",
                "Background analysis is running. Try this photo again shortly.",
                id,
            )
        })?
    };
    let (bytes, mime) = account.image(state, asset_id, id).await?;
    let analysis = eye_image(&account.runtime.eye, bytes, &mime, id).await?;
    // Commit before releasing the shared inference gate so a retag reset cannot
    // be overwritten by an older in-flight analysis.
    index
        .save(asset_id, &analysis)
        .map_err(|_| index_error(id))?;
    Ok(analysis)
}

/// A distinct Unix-socket client carries pixels only, never the user's key.
pub(super) async fn eye_image(
    eye: &reqwest::Client,
    bytes: Vec<u8>,
    mime: &str,
    id: &str,
) -> Result<Analysis, ApiError> {
    let response = eye
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
                id,
            )
        })?;
    if response.status() == reqwest::StatusCode::SERVICE_UNAVAILABLE {
        return Err(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "eye_busy",
            "EYE is analyzing another photo. Try again shortly.",
            id,
        ));
    }
    if !response.status().is_success() {
        return Err(error(
            StatusCode::BAD_GATEWAY,
            "eye_analysis_failed",
            "EYE could not analyze this photo.",
            id,
        ));
    }
    let analysis: Analysis = bounded_provider_json(response).await.map_err(|_| {
        error(
            StatusCode::BAD_GATEWAY,
            "eye_analysis_invalid",
            "EYE returned an invalid analysis.",
            id,
        )
    })?;
    if analysis.model != MODEL
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
            id,
        ));
    }
    Ok(analysis)
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

// Retain a refusal for older clients; this integration cannot mutate Immich.
pub(super) async fn add_tags(headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    identity_from_headers(&headers, &id)?;
    same_origin(&headers, &id)?;
    Err(error(
        StatusCode::FORBIDDEN,
        "image_tagging_disabled",
        "Photo tags are stored only in Media Manager. Immich writes are disabled.",
        &id,
    ))
}
