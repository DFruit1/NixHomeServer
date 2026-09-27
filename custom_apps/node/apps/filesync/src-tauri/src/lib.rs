use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::StreamExt;
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Runtime};
use tauri_plugin_mobile_files::MobileFilesExt;
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;
use url::Url;

const CALLBACK_URI: &str = "filesync://oauth/callback";
const APP_USER_AGENT: &str = "NixHomeServer-FileSync/0.1";

#[derive(Serialize, Deserialize)]
struct PendingAuth {
    state: String,
    verifier: String,
    nonce: String,
    issuer: String,
    client_id: String,
    token_endpoint: String,
    jwks_uri: String,
    revocation_endpoint: Option<String>,
    api_base: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApiConfig {
    issuer: String,
    client_id: String,
    redirect_uri: String,
}

#[derive(Debug, Deserialize)]
struct ProviderMetadata {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    jwks_uri: String,
    revocation_endpoint: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    token_type: String,
    expires_in: u64,
    id_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OAuthErrorResponse {
    error: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RemoteEntry {
    name: String,
    path: String,
    kind: String,
    size: u64,
    modified_unix_ms: u64,
    sha256: String,
}

#[derive(Debug, Deserialize)]
struct RemoteListing {
    data: Vec<RemoteEntry>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncPair {
    local: tauri_plugin_mobile_files::PickedFolder,
    server_path: String,
    #[serde(default = "default_root")]
    server_root: String,
    #[serde(default)]
    local_subpath: String,
    direction: String,
    #[serde(default)]
    server: Option<String>,
    #[serde(default)]
    account: Option<String>,
}

fn default_root() -> String {
    "files".into()
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncPreset {
    id: String,
    folder: String,
    service: String,
    service_title: String,
    title: String,
    description: String,
    server_path: String,
    local_subpath: String,
    direction: String,
}

#[derive(Debug, Deserialize)]
struct PresetListing {
    data: Vec<SyncPreset>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncResult {
    transferred: usize,
    skipped: usize,
    direction: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredSession {
    access_token: String,
    refresh_token: String,
    expires_at: u64,
    token_endpoint: String,
    revocation_endpoint: Option<String>,
    client_id: String,
    issuer: String,
    api_base: String,
}

#[derive(Debug, Deserialize)]
struct IdTokenClaims {
    iss: String,
    aud: Audience,
    exp: u64,
    nonce: String,
    azp: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

impl Audience {
    fn contains(&self, expected: &str) -> bool {
        match self {
            Self::One(value) => value == expected,
            Self::Many(values) => values.iter().any(|value| value == expected),
        }
    }
}

#[tauri::command]
async fn begin_login<R: Runtime>(app: AppHandle<R>, server_url: String) -> Result<String, String> {
    let api_base = normalize_api_base(&server_url)?;
    let client = http_client()?;
    let config: ApiConfig = client
        .get(format!("{api_base}/api/v1/config"))
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json()
        .await
        .map_err(network_error)?;
    if config.redirect_uri != CALLBACK_URI {
        return Err("The sync server is configured with a different app redirect URI.".into());
    }
    if config.client_id != "filesync-native" {
        return Err("The sync server is configured with an unsupported Kanidm client.".into());
    }
    ensure_https_url(&config.issuer)?;
    let discovery_url = format!(
        "{}/.well-known/openid-configuration",
        config.issuer.trim_end_matches('/')
    );
    let provider: ProviderMetadata = client
        .get(discovery_url)
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json()
        .await
        .map_err(network_error)?;
    if provider.issuer.trim_end_matches('/') != config.issuer.trim_end_matches('/') {
        return Err(
            "Kanidm discovery returned a different issuer than the sync server advertised.".into(),
        );
    }
    for endpoint in [
        &provider.issuer,
        &provider.authorization_endpoint,
        &provider.token_endpoint,
        &provider.jwks_uri,
    ] {
        ensure_https_url(endpoint)?;
    }
    if let Some(endpoint) = provider.revocation_endpoint.as_deref() {
        ensure_https_url(endpoint)?;
    }

    let state_value = random_urlsafe(32);
    let nonce = random_urlsafe(32);
    let verifier = random_urlsafe(32);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut authorization = Url::parse(&provider.authorization_endpoint)
        .map_err(|_| "Kanidm returned an invalid authorization URL.")?;
    authorization
        .query_pairs_mut()
        .append_pair("client_id", &config.client_id)
        .append_pair("response_type", "code")
        .append_pair("redirect_uri", CALLBACK_URI)
        .append_pair("scope", "openid profile email offline_access")
        .append_pair("state", &state_value)
        .append_pair("nonce", &nonce)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256");

    let pending = PendingAuth {
        state: state_value,
        verifier,
        nonce,
        issuer: provider.issuer,
        client_id: config.client_id,
        token_endpoint: provider.token_endpoint,
        jwks_uri: provider.jwks_uri,
        revocation_endpoint: provider.revocation_endpoint,
        api_base,
    };
    let serialized =
        serde_json::to_string(&pending).map_err(|_| "Sign-in state could not be saved.")?;
    app.mobile_files()
        .store_secret("pending-login".into(), serialized)
        .map_err(|_| "Secure sign-in storage is unavailable.".to_owned())?;
    Ok(authorization.into())
}

#[tauri::command]
async fn pick_local_folder<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Option<tauri_plugin_mobile_files::PickedFolder>, String> {
    let folder = app
        .mobile_files()
        .pick_local_folder()
        .map_err(|_| "The native folder picker could not be opened.".to_owned())?;
    if let Some(folder) = folder.as_ref() {
        app.mobile_files()
            .store_secret(folder_secret_slot(&folder.uri), folder.uri.clone())
            .map_err(|_| {
                "Secure storage is unavailable, so this folder cannot be used by File Sync."
                    .to_owned()
            })?;
    }
    Ok(folder)
}

#[tauri::command]
fn forget_local_folder<R: Runtime>(app: AppHandle<R>, folder_uri: String) -> Result<(), String> {
    let slot = folder_secret_slot(&folder_uri);
    let selected = app
        .mobile_files()
        .load_secret(slot.clone())
        .map_err(|_| "Secure folder authorization is unavailable.".to_owned())?;
    if selected.as_deref() == Some(folder_uri.as_str()) {
        app.mobile_files()
            .clear_secret(slot)
            .map_err(|_| "Secure folder authorization could not be cleared.".to_owned())?;
        app.mobile_files()
            .release_local_folder(folder_uri)
            .map_err(|_| "Access to the selected folder could not be released.".to_owned())?;
    }
    Ok(())
}

#[tauri::command]
async fn finish_login<R: Runtime>(
    app: AppHandle<R>,
    callback_url: String,
) -> Result<String, String> {
    let callback = Url::parse(&callback_url).map_err(|_| "The Kanidm callback URL is invalid.")?;
    if callback.scheme() != "filesync"
        || callback.host_str() != Some("oauth")
        || callback.path() != "/callback"
    {
        return Err("The callback URL does not belong to File Sync.".into());
    }
    let query: std::collections::HashMap<String, String> =
        callback.query_pairs().into_owned().collect();
    if let Some(error) = query.get("error") {
        return Err(format!("Kanidm sign-in was not completed ({error})."));
    }
    let code = query
        .get("code")
        .ok_or("Kanidm did not return an authorization code.")?
        .clone();
    let returned_state = query
        .get("state")
        .ok_or("Kanidm did not return sign-in state.")?;
    let pending_raw = app
        .mobile_files()
        .load_secret("pending-login".into())
        .map_err(|_| "Secure sign-in storage is unavailable.")?
        .ok_or("This sign-in request has expired. Start again.")?;
    app.mobile_files()
        .clear_secret("pending-login".into())
        .map_err(|_| "Secure sign-in storage is unavailable.")?;
    let pending: PendingAuth = serde_json::from_str(&pending_raw)
        .map_err(|_| "This sign-in request is invalid. Start again.")?;
    if !constant_time_equal(returned_state.as_bytes(), pending.state.as_bytes()) {
        return Err("The sign-in response did not match the request. Start again.".into());
    }

    let client = http_client()?;
    let token_response: TokenResponse = client
        .post(&pending.token_endpoint)
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", pending.client_id.as_str()),
            ("code", code.as_str()),
            ("redirect_uri", CALLBACK_URI),
            ("code_verifier", pending.verifier.as_str()),
        ])
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json()
        .await
        .map_err(network_error)?;
    if !token_response.token_type.eq_ignore_ascii_case("bearer") {
        return Err("Kanidm returned an unsupported token type.".into());
    }
    let refresh_token = token_response.refresh_token.ok_or(
        "Kanidm did not issue a refresh token. Check that offline_access is granted for this app.",
    )?;
    let id_token = token_response
        .id_token
        .as_deref()
        .ok_or("Kanidm did not issue an OpenID Connect identity token.")?;
    validate_id_token(&client, id_token, &pending).await?;

    let session = StoredSession {
        access_token: token_response.access_token,
        refresh_token,
        expires_at: now_seconds().saturating_add(token_response.expires_in),
        token_endpoint: pending.token_endpoint,
        revocation_endpoint: pending.revocation_endpoint,
        client_id: pending.client_id,
        issuer: pending.issuer,
        api_base: pending.api_base,
    };
    let username = fetch_current_user(&client, &session).await?;
    #[cfg(target_os = "android")]
    app.mobile_files()
        .acquire_sync_lock()
        .map_err(|_| "Android could not coordinate the new sign-in session.".to_owned())?;
    let store_result = (|| {
        store_session(&app, &session)?;
        app.mobile_files()
            .store_secret(
                "settings-auth-until".into(),
                now_seconds().saturating_add(24 * 60 * 60).to_string(),
            )
            .map_err(|_| {
                "The sign-in worked, but the settings access window could not be saved securely."
                    .to_owned()
            })
    })();
    #[cfg(target_os = "android")]
    if let Err(error) = app.mobile_files().release_sync_lock() {
        if store_result.is_ok() {
            return Err(format!(
                "Android could not release the background sync lock: {error}"
            ));
        }
    }
    store_result?;
    Ok(username)
}

#[tauri::command]
fn settings_authorized<R: Runtime>(app: AppHandle<R>) -> Result<bool, String> {
    let value = app
        .mobile_files()
        .load_secret("settings-auth-until".into())
        .map_err(|_| "Secure settings authorization is unavailable.".to_owned())?;
    Ok(value
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|until| until > now_seconds()))
}

#[tauri::command]
async fn current_user<R: Runtime>(app: AppHandle<R>) -> Result<Option<String>, String> {
    let Some(session) = load_session(&app)? else {
        return Ok(None);
    };
    let client = http_client()?;
    let session = refresh_if_needed(&client, &app, session).await?;
    fetch_current_user(&client, &session).await.map(Some)
}

#[tauri::command]
async fn logout<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    #[cfg(target_os = "android")]
    let sync_lock_held = app.mobile_files().acquire_sync_lock().is_ok();
    let _ = app.mobile_files().schedule_background_sync(false);
    let logout_result = async {
        if let Some(session) = load_session(&app)? {
            if let Some(endpoint) = session.revocation_endpoint.as_deref() {
                let _ = tokio::time::timeout(std::time::Duration::from_secs(5), async {
                    http_client()?
                        .post(endpoint)
                        .form(&[
                            ("client_id", session.client_id.as_str()),
                            ("token", session.refresh_token.as_str()),
                            ("token_type_hint", "refresh_token"),
                        ])
                        .send()
                        .await
                        .map_err(network_error)
                })
                .await;
            }
        }
        app.mobile_files()
            .clear_session()
            .and_then(|_| app.mobile_files().clear_secret("pending-login".into()))
            .and_then(|_| {
                app.mobile_files()
                    .clear_secret("settings-auth-until".into())
            })
            .map_err(|error| error.to_string())
    }
    .await;
    #[cfg(target_os = "android")]
    if sync_lock_held {
        if let Err(error) = app.mobile_files().release_sync_lock() {
            if logout_result.is_ok() {
                return Err(format!(
                    "Android could not release the background sync lock: {error}"
                ));
            }
        }
    }
    logout_result
}

#[tauri::command]
async fn server_tree<R: Runtime>(
    app: AppHandle<R>,
    path: String,
    root: Option<String>,
) -> Result<Vec<RemoteEntry>, String> {
    let session = authenticated_session(&app).await?;
    let client = http_client()?;
    fetch_tree(
        &client,
        &session,
        &path,
        root.as_deref().unwrap_or("files"),
        false,
    )
    .await
}

#[tauri::command]
async fn server_presets<R: Runtime>(app: AppHandle<R>) -> Result<Vec<SyncPreset>, String> {
    let session = authenticated_session(&app).await?;
    http_client()?
        .get(format!("{}/api/v1/presets", session.api_base))
        .bearer_auth(&session.access_token)
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json::<PresetListing>()
        .await
        .map(|listing| listing.data)
        .map_err(network_error)
}

#[tauri::command]
async fn sync_pair<R: Runtime>(app: AppHandle<R>, pair: SyncPair) -> Result<SyncResult, String> {
    #[cfg(target_os = "android")]
    {
        let pair_json = serde_json::to_string(&pair)
            .map_err(|_| "The folder pair could not be prepared for Android sync.")?;
        let result = app
            .mobile_files()
            .run_sync_pair(pair_json)
            .map_err(|error| format!("Android sync could not start: {error}"))?;
        return serde_json::from_value(result)
            .map_err(|_| "Android sync returned an invalid result.".to_owned());
    }
    #[cfg(not(target_os = "android"))]
    sync_pair_rust(app, pair).await
}

#[tauri::command]
fn update_background_syncs<R: Runtime>(
    app: AppHandle<R>,
    pairs: Vec<SyncPair>,
) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        let enabled = !pairs.is_empty();
        let config = serde_json::to_string(&pairs)
            .map_err(|_| "The folder pairs could not be saved for background sync.")?;
        app.mobile_files()
            .update_background_syncs(config, enabled)
            .map_err(|_| "Android could not schedule background sync.".to_owned())
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, pairs);
        Ok(())
    }
}

#[tauri::command]
fn background_sync_status<R: Runtime>(app: AppHandle<R>) -> Result<Option<String>, String> {
    app.mobile_files()
        .background_sync_status()
        .map_err(|_| "Android background sync status is unavailable.".to_owned())
}

async fn sync_pair_rust<R: Runtime>(
    app: AppHandle<R>,
    pair: SyncPair,
) -> Result<SyncResult, String> {
    if pair.direction == "two-way" {
        return Err(
            "Two-way sync is not available yet. Choose one direction for this pair.".into(),
        );
    }
    if pair.direction != "phone-to-server" && pair.direction != "server-to-phone" {
        return Err("Choose a supported sync direction.".into());
    }
    let base = safe_sync_path(&pair.server_path)?;
    let local_subpath = safe_sync_path(&pair.local_subpath)?;
    let root = safe_root_id(&pair.server_root)?;
    let session = authenticated_session(&app).await?;
    let account = pair.account.as_deref().ok_or(
        "This older folder pair is not linked to a Kanidm account. Recreate it before syncing.",
    )?;
    let signed_in = fetch_current_user(&http_client()?, &session).await?;
    if account != signed_in {
        return Err("This folder pair belongs to another Kanidm account. Sign in as that account or create a new pair.".into());
    }
    if pair
        .server
        .as_deref()
        .filter(|server| !server.is_empty())
        .is_some_and(|server| {
            normalize_api_base(server).ok().as_deref() != Some(session.api_base.as_str())
        })
    {
        return Err("This folder pair belongs to a different sync server. Edit or recreate it before syncing.".into());
    }
    let client = http_client()?;
    let folder_slot = folder_secret_slot(&pair.local.uri);
    let authorized_folder = app
        .mobile_files()
        .load_secret(folder_slot)
        .map_err(|_| "Secure folder authorization is unavailable.".to_owned())?;
    if authorized_folder.as_deref() != Some(pair.local.uri.as_str()) {
        return Err("Choose this local folder again before syncing; File Sync no longer has permission to use it.".into());
    }
    let local = app
        .mobile_files()
        .list_local_files(pair.local.uri.clone())
        .map_err(|_| {
            "The selected local folder is no longer available. Choose it again in folder settings."
                .to_owned()
        })?;
    let mut local_files = std::collections::HashMap::new();
    for mut item in local.into_iter().filter(|entry| entry.kind == "file") {
        if !local_subpath.is_empty() {
            let Some(relative) = item.path.strip_prefix(&format!("{local_subpath}/")) else {
                continue;
            };
            item.path = relative.to_owned();
        }
        local_files.insert(item.path.clone(), item);
    }
    let remote = fetch_tree_recursive(&client, &session, &base, &root).await?;
    let mut remote_files = std::collections::HashMap::new();
    for item in remote.into_iter().filter(|entry| entry.kind == "file") {
        remote_files.insert(item.path.clone(), item);
    }
    let mut transferred = 0;
    let mut skipped = 0;
    if pair.direction == "phone-to-server" {
        for (relative, local_entry) in local_files {
            if remote_files
                .get(&relative)
                .is_some_and(|entry| entry.sha256 == local_entry.sha256)
            {
                skipped += 1;
                continue;
            }
            let staged = app
                .mobile_files()
                .stage_local_file(
                    pair.local.uri.clone(),
                    join_sync_path(&local_subpath, &relative),
                )
                .map_err(|_| format!("Could not read local file: {relative}"))?;
            let file = match tokio::fs::File::open(&staged).await {
                Ok(file) => file,
                Err(_) => {
                    #[cfg(target_os = "android")]
                    let _ = tokio::fs::remove_file(&staged).await;
                    return Err(format!("Could not open local file: {relative}"));
                }
            };
            let body = reqwest::Body::wrap_stream(ReaderStream::new(file));
            let target = join_sync_path(&base, &relative);
            let response = client
                .put(file_url(&session.api_base, &target, &root)?)
                .bearer_auth(&session.access_token)
                .header("x-filesync-sha256", &local_entry.sha256)
                .body(body)
                .send()
                .await;
            #[cfg(target_os = "android")]
            let _ = tokio::fs::remove_file(&staged).await;
            let response = response.map_err(network_error)?;
            if !response.status().is_success() {
                return Err(format!(
                    "The server could not save {relative} (HTTP {}).",
                    response.status().as_u16()
                ));
            }
            transferred += 1;
        }
    } else {
        for (relative, remote_entry) in remote_files {
            if local_files
                .get(&relative)
                .is_some_and(|entry| entry.sha256 == remote_entry.sha256)
            {
                skipped += 1;
                continue;
            }
            let source = join_sync_path(&base, &relative);
            let response = client
                .get(file_url(&session.api_base, &source, &root)?)
                .bearer_auth(&session.access_token)
                .send()
                .await
                .map_err(network_error)?
                .error_for_status()
                .map_err(network_error)?;
            let staged = app
                .mobile_files()
                .create_temp_file()
                .map_err(|_| "Could not create a temporary download file.".to_owned())?;
            let mut options = tokio::fs::OpenOptions::new();
            options.write(true);
            #[cfg(target_os = "android")]
            options.truncate(true);
            #[cfg(not(target_os = "android"))]
            options.create_new(true);
            let mut output = options
                .open(&staged)
                .await
                .map_err(|_| "Could not create a temporary download file.".to_owned())?;
            let mut stream = response.bytes_stream();
            let mut hasher = Sha256::new();
            while let Some(chunk) = stream.next().await {
                let bytes = match chunk {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        drop(output);
                        let _ = tokio::fs::remove_file(&staged).await;
                        return Err(network_error(error));
                    }
                };
                if output.write_all(&bytes).await.is_err() {
                    drop(output);
                    let _ = tokio::fs::remove_file(&staged).await;
                    return Err("The file download could not be written.".into());
                }
                hasher.update(&bytes);
            }
            if format!("{:x}", hasher.finalize()) != remote_entry.sha256 {
                drop(output);
                let _ = tokio::fs::remove_file(&staged).await;
                return Err(format!(
                    "The downloaded file did not match the server's checksum: {relative}"
                ));
            }
            if output.flush().await.is_err() {
                drop(output);
                let _ = tokio::fs::remove_file(&staged).await;
                return Err("The downloaded file could not be finalized.".into());
            }
            drop(output);
            let result = app.mobile_files().install_local_file(
                pair.local.uri.clone(),
                join_sync_path(&local_subpath, &relative),
                staged.clone(),
            );
            let _ = tokio::fs::remove_file(&staged).await;
            if result.is_err() {
                return Err(format!(
                    "Could not write server file to the selected folder: {relative}"
                ));
            }
            transferred += 1;
        }
    }
    Ok(SyncResult {
        transferred,
        skipped,
        direction: pair.direction,
    })
}

async fn authenticated_session<R: Runtime>(app: &AppHandle<R>) -> Result<StoredSession, String> {
    let session = load_session(app)?.ok_or("Sign in with Kanidm before syncing.")?;
    refresh_if_needed(&http_client()?, app, session).await
}

async fn fetch_tree(
    client: &reqwest::Client,
    session: &StoredSession,
    path: &str,
    root: &str,
    include_hashes: bool,
) -> Result<Vec<RemoteEntry>, String> {
    let mut url = Url::parse(&format!("{}/api/v1/tree", session.api_base))
        .map_err(|_| "The server address is invalid.")?;
    url.query_pairs_mut().append_pair("path", path);
    url.query_pairs_mut().append_pair("root", root);
    if include_hashes {
        url.query_pairs_mut().append_pair("hashes", "true");
    }
    client
        .get(url)
        .bearer_auth(&session.access_token)
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json::<RemoteListing>()
        .await
        .map(|value| value.data)
        .map_err(network_error)
}

async fn fetch_tree_recursive(
    client: &reqwest::Client,
    session: &StoredSession,
    path: &str,
    root: &str,
) -> Result<Vec<RemoteEntry>, String> {
    let mut result = Vec::new();
    let mut pending = vec![path.to_owned()];
    while let Some(directory) = pending.pop() {
        for entry in fetch_tree(client, session, &directory, root, true).await? {
            let absolute = if directory.is_empty() {
                entry.name.clone()
            } else {
                format!("{directory}/{}", entry.name)
            };
            if entry.kind == "directory" {
                pending.push(absolute.clone());
            }
            let relative = if path.is_empty() {
                absolute
            } else {
                absolute
                    .strip_prefix(&format!("{path}/"))
                    .unwrap_or(&absolute)
                    .to_owned()
            };
            result.push(RemoteEntry {
                path: relative,
                ..entry
            });
        }
    }
    Ok(result)
}

fn safe_sync_path(value: &str) -> Result<String, String> {
    let value = value.trim_matches('/');
    if value.is_empty() {
        return Ok(String::new());
    }
    if value
        .split('/')
        .any(|part| part.is_empty() || part == "." || part == "..")
        || value.contains('\\')
        || value.contains('\0')
    {
        return Err("The server folder path is invalid.".into());
    }
    Ok(value.to_owned())
}

fn safe_root_id(value: &str) -> Result<String, String> {
    if value.is_empty()
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_' | b'.')
        })
    {
        return Err("The server folder root is invalid.".into());
    }
    Ok(value.to_owned())
}

fn join_sync_path(base: &str, relative: &str) -> String {
    if base.is_empty() {
        relative.to_owned()
    } else {
        format!("{base}/{relative}")
    }
}

fn file_url(api_base: &str, path: &str, root: &str) -> Result<Url, String> {
    let mut url = Url::parse(&format!("{api_base}/api/v1/file"))
        .map_err(|_| "The server address is invalid.")?;
    url.query_pairs_mut().append_pair("path", path);
    url.query_pairs_mut().append_pair("root", root);
    Ok(url)
}

async fn validate_id_token(
    client: &reqwest::Client,
    raw: &str,
    pending: &PendingAuth,
) -> Result<(), String> {
    let header = decode_header(raw).map_err(|_| "Kanidm returned an invalid identity token.")?;
    if header.alg != Algorithm::ES256 {
        return Err("Kanidm returned an unsupported identity-token algorithm.".into());
    }
    let kid = header
        .kid
        .as_deref()
        .ok_or("Kanidm identity token has no signing key id.")?;
    let jwks: JwkSet = client
        .get(&pending.jwks_uri)
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?
        .json()
        .await
        .map_err(network_error)?;
    let jwk = jwks
        .find(kid)
        .ok_or("Kanidm identity token uses an unknown signing key.")?;
    let key = DecodingKey::from_jwk(jwk).map_err(|_| "Kanidm identity-token key is invalid.")?;
    let mut validation = Validation::new(Algorithm::ES256);
    validation.set_issuer(&[pending.issuer.as_str()]);
    validation.set_audience(&[pending.client_id.as_str()]);
    let claims = decode::<IdTokenClaims>(raw, &key, &validation)
        .map_err(|_| "Kanidm identity token failed signature or claim validation.")?
        .claims;
    if claims.iss.trim_end_matches('/') != pending.issuer.trim_end_matches('/')
        || !claims.aud.contains(&pending.client_id)
        || claims.exp <= now_seconds()
        || !constant_time_equal(claims.nonce.as_bytes(), pending.nonce.as_bytes())
        || matches!(&claims.aud, Audience::Many(values) if values.len() > 1 && claims.azp.as_deref() != Some(pending.client_id.as_str()))
    {
        return Err("Kanidm identity token did not match the sign-in request.".into());
    }
    Ok(())
}

async fn fetch_current_user(
    client: &reqwest::Client,
    session: &StoredSession,
) -> Result<String, String> {
    let response = client
        .get(format!("{}/api/v1/me", session.api_base))
        .bearer_auth(&session.access_token)
        .send()
        .await
        .map_err(network_error)?
        .error_for_status()
        .map_err(network_error)?;
    let value: Value = response.json().await.map_err(network_error)?;
    value
        .get("username")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "The sync API returned an invalid identity response.".into())
}

async fn refresh_if_needed<R: Runtime>(
    client: &reqwest::Client,
    app: &AppHandle<R>,
    mut session: StoredSession,
) -> Result<StoredSession, String> {
    if session.expires_at > now_seconds().saturating_add(60) {
        return Ok(session);
    }
    #[cfg(target_os = "android")]
    {
        app.mobile_files()
            .acquire_sync_lock()
            .map_err(|_| "Android could not coordinate a background token refresh.".to_owned())?;
        match load_session(app) {
            Ok(Some(latest)) => session = latest,
            Ok(None) => {
                let _ = app.mobile_files().release_sync_lock();
                return Err("Sign in with Kanidm before syncing.".into());
            }
            Err(error) => {
                let _ = app.mobile_files().release_sync_lock();
                return Err(error);
            }
        }
        if session.expires_at > now_seconds().saturating_add(60) {
            app.mobile_files()
                .release_sync_lock()
                .map_err(|_| "Android could not release the background sync lock.".to_owned())?;
            return Ok(session);
        }
    }

    let refresh_result = async {
        let response = client
            .post(&session.token_endpoint)
            .form(&[
                ("grant_type", "refresh_token"),
                ("client_id", session.client_id.as_str()),
                ("refresh_token", session.refresh_token.as_str()),
            ])
            .send()
            .await
            .map_err(network_error)?;
        if !response.status().is_success() {
            let error = response.json::<OAuthErrorResponse>().await.ok();
            if error
                .as_ref()
                .is_some_and(|value| value.error == "invalid_grant")
            {
                app.mobile_files()
                    .clear_session()
                    .map_err(|_| "Kanidm rejected the saved session, and it could not be cleared securely. Sign in again.")?;
                let _ = app.mobile_files().schedule_background_sync(false);
                return Err(
                    "Your Kanidm session expired or was revoked. Sign in again to reconnect File Sync."
                        .into(),
                );
            }
            return Err(
                "Kanidm could not refresh this session. Check your connection or sign in again."
                    .into(),
            );
        }
        let response: TokenResponse = response.json().await.map_err(network_error)?;
        if !response.token_type.eq_ignore_ascii_case("bearer") {
            return Err("Kanidm returned an unsupported token type during refresh.".into());
        }
        session.access_token = response.access_token;
        if let Some(refresh_token) = response.refresh_token {
            session.refresh_token = refresh_token;
        }
        session.expires_at = now_seconds().saturating_add(response.expires_in);
        store_session(app, &session)?;
        Ok(session)
    }
    .await;

    #[cfg(target_os = "android")]
    if let Err(error) = app.mobile_files().release_sync_lock() {
        if refresh_result.is_ok() {
            return Err(format!(
                "Android could not release the background sync lock: {error}"
            ));
        }
    }
    refresh_result
}

fn store_session<R: Runtime>(app: &AppHandle<R>, session: &StoredSession) -> Result<(), String> {
    let value = serde_json::to_string(session).map_err(|_| "The session could not be saved.")?;
    app.mobile_files()
        .store_session(value)
        .map_err(|error| format!("Secure session storage is unavailable: {error}"))
}

fn load_session<R: Runtime>(app: &AppHandle<R>) -> Result<Option<StoredSession>, String> {
    let Some(value) = app
        .mobile_files()
        .load_session()
        .map_err(|error| format!("Secure session storage is unavailable: {error}"))?
    else {
        return Ok(None);
    };
    serde_json::from_str(&value)
        .map(Some)
        .map_err(|_| "The stored session is invalid; sign in again.".into())
}

fn normalize_api_base(value: &str) -> Result<String, String> {
    let url = Url::parse(value.trim()).map_err(|_| "Enter a valid HTTPS sync server address.")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("The sync server address must be an HTTPS origin without credentials, query, or fragment.".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

fn folder_secret_slot(folder_uri: &str) -> String {
    let digest = format!("{:x}", Sha256::digest(folder_uri.as_bytes()));
    format!("folder-{}", &digest[..32])
}

fn ensure_https_url(value: &str) -> Result<(), String> {
    let url = Url::parse(value).map_err(|_| "Kanidm returned an invalid endpoint URL.")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("Kanidm returned an endpoint that is not a secure HTTPS URL.".into());
    }
    Ok(())
}

fn random_urlsafe(length: usize) -> String {
    let mut bytes = vec![0_u8; length];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(APP_USER_AGENT)
        .connect_timeout(std::time::Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "A secure HTTP client could not be created.".into())
}

fn network_error(error: reqwest::Error) -> String {
    if error.is_timeout() {
        "The server request timed out. Check the connection and try again.".into()
    } else if error.is_status() {
        format!(
            "The server rejected the request (HTTP {}).",
            error
                .status()
                .map(|status| status.as_u16())
                .unwrap_or_default()
        )
    } else {
        "The server could not be reached securely. Check the server address and network.".into()
    }
}

#[tauri::command]
fn platform_name() -> &'static str {
    if cfg!(target_os = "android") {
        "android"
    } else {
        "linux"
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_mobile_files::init())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            #[cfg(desktop)]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                app.deep_link().register_all()?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            platform_name,
            begin_login,
            finish_login,
            current_user,
            settings_authorized,
            logout,
            server_tree,
            server_presets,
            sync_pair,
            update_background_syncs,
            background_sync_status,
            pick_local_folder,
            forget_local_folder
        ])
        .run(tauri::generate_context!())
        .expect("error while running File Sync");
}
