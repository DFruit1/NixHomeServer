use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Manager};
use tauri_plugin_opener::OpenerExt;

const CALLBACK_PATH: &str = "/callback";
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);
const TOKEN_SKEW_SECONDS: u64 = 30;
// Kanidm rotates refresh tokens, so two concurrent refreshes would invalidate
// each other and surface as invalid_grant; serialise them.
static REFRESH_LOCK: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();

fn refresh_lock() -> &'static tokio::sync::Mutex<()> {
    REFRESH_LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

const DEFAULT_SCOPE: &str = "openid profile email groups_name";
const CUSTOM_SCHEME_REDIRECT: &str = "org.sydneybasiniot.youtubedownloader://auth/callback";
#[cfg(target_os = "android")]
const CALLBACK_FILE: &str = "oauth-callback.txt";

fn build_authorize_url(
    endpoint: &str,
    client_id: &str,
    redirect_uri: &str,
    scope: &str,
    state: &str,
    challenge: &str,
) -> Result<url::Url, String> {
    let mut url = url::Url::parse(endpoint).map_err(|error| error.to_string())?;
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", client_id)
        .append_pair("redirect_uri", redirect_uri)
        .append_pair("scope", scope)
        .append_pair("state", state)
        .append_pair("code_challenge", challenge)
        .append_pair("code_challenge_method", "S256");
    Ok(url)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredTokens {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub id_token: Option<String>,
    pub expires_at: u64,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub issuer: String,
    #[serde(default)]
    pub client_id: String,
    /// Set when the token endpoint rejects the refresh token (`invalid_grant`).
    /// The stored session is kept so the app stays on the main screen and keeps
    /// queuing locally, but refresh is not retried until an explicit sign-in.
    #[serde(default)]
    pub refresh_invalid: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatus {
    pub signed_in: bool,
    /// A stored session exists but its refresh token is no longer usable, so a
    /// fresh sign-in is required before downloads can be sent to the server.
    pub session_expired: bool,
    pub username: Option<String>,
    pub expires_at: Option<u64>,
}

impl From<&StoredTokens> for AuthStatus {
    fn from(tokens: &StoredTokens) -> Self {
        Self {
            signed_in: !tokens.refresh_invalid,
            session_expired: tokens.refresh_invalid,
            username: tokens.username.clone(),
            expires_at: Some(tokens.expires_at),
        }
    }
}

#[derive(Deserialize)]
struct Discovery {
    authorization_endpoint: String,
    token_endpoint: String,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    id_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    error_description: Option<String>,
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn random_urlsafe(byte_count: usize) -> String {
    let mut buffer = vec![0u8; byte_count];
    rand::thread_rng().fill_bytes(&mut buffer);
    URL_SAFE_NO_PAD.encode(buffer)
}

fn code_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn tokens_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|error| error.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    Ok(dir.join("auth.json"))
}

fn load_tokens(app: &AppHandle) -> Option<StoredTokens> {
    let path = tokens_path(app).ok()?;
    let contents = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

fn store_tokens(app: &AppHandle, tokens: &StoredTokens) -> Result<(), String> {
    let path = tokens_path(app)?;
    let serialised = serde_json::to_string(tokens).map_err(|error| error.to_string())?;
    std::fs::write(&path, serialised).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let permissions = std::fs::Permissions::from_mode(0o600);
        let _ = std::fs::set_permissions(&path, permissions);
    }
    Ok(())
}

fn clear_tokens(app: &AppHandle) -> Result<(), String> {
    let path = tokens_path(app)?;
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

fn id_token_claims(id_token: &str) -> Option<serde_json::Value> {
    let payload = id_token.split('.').nth(1)?;
    let decoded = URL_SAFE_NO_PAD.decode(payload).ok()?;
    serde_json::from_slice(&decoded).ok()
}

fn id_token_expiry(id_token: &str) -> Option<u64> {
    id_token_claims(id_token)?.get("exp").and_then(|exp| exp.as_u64())
}

fn username_from_id_token(id_token: &str) -> Option<String> {
    let value = id_token_claims(id_token)?;
    for key in ["preferred_username", "name", "email"] {
        if let Some(candidate) = value.get(key).and_then(|entry| entry.as_str()) {
            let local = candidate.split('@').next().unwrap_or(candidate).split(',').next()?.trim();
            if !local.is_empty() {
                return Some(local.to_string());
            }
        }
    }
    None
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .build()
        .map_err(|error| error.to_string())
}

async fn discover(client: &reqwest::Client, issuer: &str) -> Result<Discovery, String> {
    let url = format!("{issuer}/.well-known/openid-configuration");
    let response = get_with_retry(client, &url).await?;
    response.json::<Discovery>().await.map_err(|error| error.to_string())
}

/// Phone networks drop connections mid-request; retry a couple of times before
/// surfacing a transport failure to the user.
async fn get_with_retry(client: &reqwest::Client, url: &str) -> Result<reqwest::Response, String> {
    let mut last_error = String::new();
    for attempt in 0..3u64 {
        match client.get(url).send().await {
            Ok(response) => return Ok(response),
            Err(error) => {
                last_error = error.to_string();
                if attempt < 2 {
                    std::thread::sleep(Duration::from_secs(attempt + 1));
                }
            }
        }
    }
    Err(last_error)
}

async fn post_form_with_retry(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
) -> Result<reqwest::Response, String> {
    let mut last_error = String::new();
    for attempt in 0..3u64 {
        match client.post(url).form(form).send().await {
            Ok(response) => return Ok(response),
            Err(error) => {
                last_error = error.to_string();
                if attempt < 2 {
                    std::thread::sleep(Duration::from_secs(attempt + 1));
                }
            }
        }
    }
    Err(last_error)
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    );
    let _ = stream.write_all(response.as_bytes());
}

fn await_callback(listener: TcpListener, expected_state: &str) -> Result<String, String> {
    listener
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let deadline = Instant::now() + CALLBACK_TIMEOUT;
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                // A connected browser that never sends a request must not block
                // the callback loop forever.
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let mut reader = match stream.try_clone() {
                    Ok(clone) => BufReader::new(clone),
                    Err(error) => return Err(error.to_string()),
                };
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    continue;
                }
                let target = request_line.split_whitespace().nth(1).unwrap_or("/");
                if !target.starts_with(CALLBACK_PATH) {
                    respond(&mut stream, "404 Not Found", "<html><body>Not found</body></html>");
                    continue;
                }
                let parsed = url::Url::parse(&format!("http://127.0.0.1{target}"))
                    .map_err(|error| error.to_string())?;
                let params: HashMap<String, String> = parsed
                    .query_pairs()
                    .map(|(key, value)| (key.into_owned(), value.into_owned()))
                    .collect();

                let body = "<html><body><h3>Signed in</h3><p>You can close this window and return to the app.</p></body></html>";
                if let Some(error) = params.get("error") {
                    respond(&mut stream, "400 Bad Request", body);
                    let description = params
                        .get("error_description")
                        .cloned()
                        .unwrap_or_default();
                    return Err(format!("authorisation failed: {error} {description}"));
                }
                match params.get("state") {
                    Some(state) if state == expected_state => {}
                    _ => {
                        respond(&mut stream, "400 Bad Request", body);
                        return Err("authorisation state mismatch".into());
                    }
                }
                let code = params
                    .get("code")
                    .cloned()
                    .ok_or_else(|| "authorisation response had no code".to_string())?;
                respond(&mut stream, "200 OK", body);
                return Ok(code);
            }
            Err(ref error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() > deadline {
                    return Err("timed out waiting for the browser sign-in".into());
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(error) => return Err(error.to_string()),
        }
    }
}

#[cfg(target_os = "android")]
fn callback_candidates(app: &AppHandle) -> Vec<std::path::PathBuf> {
    match app.path().app_data_dir() {
        Ok(dir) => vec![
            dir.join("files").join(CALLBACK_FILE),
            dir.join(CALLBACK_FILE),
        ],
        Err(_) => Vec::new(),
    }
}

/// Drop any callback left behind by an earlier attempt before starting again.
#[cfg(target_os = "android")]
fn clear_callback_files(app: &AppHandle) {
    for candidate in callback_candidates(app) {
        let _ = std::fs::remove_file(candidate);
    }
}

/// Read and remove every callback file. AuthCallbackActivity writes the same
/// content to several candidate directories, and a file from a previous
/// attempt can outlive the one Rust already consumed.
#[cfg(target_os = "android")]
fn take_callback_files(app: &AppHandle) -> Vec<String> {
    let mut contents = Vec::new();
    for candidate in callback_candidates(app) {
        if let Ok(content) = std::fs::read_to_string(&candidate) {
            let _ = std::fs::remove_file(&candidate);
            contents.push(content);
        }
    }
    contents
}

/// Wait for AuthCallbackActivity to hand back the custom-scheme redirect.
#[cfg(target_os = "android")]
fn await_android_callback(app: &AppHandle, expected_state: &str) -> Result<String, String> {
    let deadline = Instant::now() + CALLBACK_TIMEOUT;
    loop {
        if Instant::now() > deadline {
            return Err("timed out waiting for the browser sign-in".into());
        }
        for content in take_callback_files(app) {
            let params: HashMap<String, String> = url::form_urlencoded::parse(
                content.trim().trim_start_matches('?').as_bytes(),
            )
            .into_owned()
            .collect();
            if let Some(error) = params.get("error") {
                let description = params.get("error_description").cloned().unwrap_or_default();
                return Err(format!("authorisation failed: {error} {description}"));
            }
            // A mismatched state is a stale file from a previous attempt, not a
            // live response; keep waiting for the matching one.
            if params.get("state").map(String::as_str) == Some(expected_state) {
                if let Some(code) = params.get("code") {
                    return Ok(code.clone());
                }
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn to_stored_tokens(
    issuer: &str,
    client_id: &str,
    response: TokenResponse,
) -> Result<StoredTokens, String> {
    if let Some(error) = response.error {
        let description = response.error_description.unwrap_or_default();
        return Err(format!("token exchange failed: {error} {description}"));
    }
    let access_token = response
        .access_token
        .ok_or_else(|| "token response had no access token".to_string())?;
    // The ID token is what we send to the API, so refresh before whichever of
    // the access and ID tokens expires first.
    let access_expiry = now_seconds() + response.expires_in.unwrap_or(300).saturating_sub(TOKEN_SKEW_SECONDS);
    let id_expiry = response
        .id_token
        .as_deref()
        .and_then(id_token_expiry)
        .map(|exp| exp.saturating_sub(TOKEN_SKEW_SECONDS))
        .unwrap_or(u64::MAX);
    let expires_at = access_expiry.min(id_expiry);
    let username = response
        .id_token
        .as_deref()
        .and_then(username_from_id_token);
    Ok(StoredTokens {
        access_token,
        refresh_token: response.refresh_token,
        id_token: response.id_token,
        expires_at,
        username,
        issuer: issuer.to_string(),
        client_id: client_id.to_string(),
        refresh_invalid: false,
    })
}

#[tauri::command]
pub async fn oauth_status(app: AppHandle) -> AuthStatus {
    if load_tokens(&app).is_some() {
        // Renew an expired access token so a returning user stays signed in
        // without interacting. Failures leave the stored session intact and are
        // reported through the returned status instead of forcing a sign-out.
        let _ = authorization_token(&app).await;
    }
    match load_tokens(&app) {
        Some(tokens) => AuthStatus::from(&tokens),
        None => AuthStatus {
            signed_in: false,
            session_expired: false,
            username: None,
            expires_at: None,
        },
    }
}

#[tauri::command]
pub fn oauth_logout(app: AppHandle) -> Result<(), String> {
    clear_tokens(&app)
}

#[tauri::command]
pub async fn oauth_login(
    app: AppHandle,
    issuer: String,
    client_id: String,
    scope: Option<String>,
) -> Result<AuthStatus, String> {
    let issuer = issuer.trim_end_matches('/').to_string();
    let scope = scope.unwrap_or_else(|| DEFAULT_SCOPE.to_string());
    let client = client()?;
    let discovery = discover(&client, &issuer).await?;

    let verifier = random_urlsafe(32);
    let challenge = code_challenge(&verifier);
    let state = random_urlsafe(16);

    // Android returns through the app scheme so the browser never shows the
    // loopback page; desktop uses a loopback listener.
    #[cfg(target_os = "android")]
    let (redirect_uri, code) = {
        clear_callback_files(&app);
        let redirect_uri = CUSTOM_SCHEME_REDIRECT.to_string();
        let authorize_url = build_authorize_url(
            &discovery.authorization_endpoint,
            &client_id,
            &redirect_uri,
            &scope,
            &state,
            &challenge,
        )?;
        app.opener()
            .open_url(authorize_url.as_str(), None::<&str>)
            .map_err(|error| error.to_string())?;
        let handle = app.clone();
        let expected_state = state.clone();
        let code =
            tauri::async_runtime::spawn_blocking(move || await_android_callback(&handle, &expected_state))
                .await
                .map_err(|error| error.to_string())??;
        (redirect_uri, code)
    };

    #[cfg(not(target_os = "android"))]
    let (redirect_uri, code) = {
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| error.to_string())?;
        let port = listener
            .local_addr()
            .map_err(|error| error.to_string())?
            .port();
        let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");
        let authorize_url = build_authorize_url(
            &discovery.authorization_endpoint,
            &client_id,
            &redirect_uri,
            &scope,
            &state,
            &challenge,
        )?;
        app.opener()
            .open_url(authorize_url.as_str(), None::<&str>)
            .map_err(|error| error.to_string())?;
        let expected_state = state.clone();
        let code = tauri::async_runtime::spawn_blocking(move || await_callback(listener, &expected_state))
            .await
            .map_err(|error| error.to_string())??;
        (redirect_uri, code)
    };

    let form = [
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("redirect_uri", redirect_uri.as_str()),
        ("client_id", client_id.as_str()),
        ("code_verifier", verifier.as_str()),
    ];
    let response = post_form_with_retry(&client, &discovery.token_endpoint, &form)
        .await?
        .json::<TokenResponse>()
        .await
        .map_err(|error| error.to_string())?;

    let tokens = to_stored_tokens(&issuer, &client_id, response)?;
    store_tokens(&app, &tokens)?;
    Ok(AuthStatus::from(&tokens))
}

/// Kanidm carries identity claims such as `groups` in the ID token (this is
/// what oauth2-proxy consumes), so prefer it for API authorisation and fall
/// back to the access token only when no ID token was issued.
fn authorization_value(tokens: &StoredTokens) -> String {
    tokens
        .id_token
        .clone()
        .unwrap_or_else(|| tokens.access_token.clone())
}

pub async fn authorization_token(app: &AppHandle) -> Result<Option<String>, String> {
    let tokens = match load_tokens(app) {
        Some(tokens) => tokens,
        None => return Ok(None),
    };
    if tokens.expires_at > now_seconds() && !tokens.refresh_invalid {
        return Ok(Some(authorization_value(&tokens)));
    }
    if tokens.refresh_invalid {
        // The refresh token was already rejected; ask for an explicit sign-in
        // instead of retrying the token endpoint on every request.
        return Ok(None);
    }

    let _guard = refresh_lock().lock().await;
    // Another request may have refreshed while we waited for the lock.
    let tokens = match load_tokens(app) {
        Some(tokens) => tokens,
        None => return Ok(None),
    };
    if tokens.expires_at > now_seconds() && !tokens.refresh_invalid {
        return Ok(Some(authorization_value(&tokens)));
    }
    if tokens.refresh_invalid {
        return Ok(None);
    }

    let refresh_token = match tokens.refresh_token.clone() {
        Some(refresh_token) => refresh_token,
        None => return Ok(None),
    };
    let issuer = tokens.issuer.clone();
    let client_id = tokens.client_id.clone();
    let client = client()?;
    let discovery = discover(&client, &issuer).await?;
    let form = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token.as_str()),
        ("client_id", client_id.as_str()),
    ];
    let response = post_form_with_retry(&client, &discovery.token_endpoint, &form)
        .await?
        .json::<TokenResponse>()
        .await
        .map_err(|error| error.to_string())?;

    if let Some(error) = response.error.clone() {
        if error == "invalid_grant" {
            // The refresh token has expired or been revoked. Keep the stored
            // session so the app stays usable and only asks for a fresh
            // sign-in when the user requests one.
            let mut invalidated = tokens.clone();
            invalidated.refresh_invalid = true;
            store_tokens(app, &invalidated)?;
            return Ok(None);
        }
        let description = response.error_description.clone().unwrap_or_default();
        return Err(format!("token refresh failed: {error} {description}"));
    }

    match to_stored_tokens(&issuer, &client_id, response) {
        Ok(mut refreshed) => {
            // A refresh response may omit the ID or refresh token; keep the
            // previous ones so the groups claim and rotation stay available.
            if refreshed.id_token.is_none() {
                refreshed.id_token = tokens.id_token.clone();
            }
            if refreshed.refresh_token.is_none() {
                refreshed.refresh_token = tokens.refresh_token.clone();
            }
            if refreshed.username.is_none() {
                refreshed.username = tokens.username.clone();
            }
            store_tokens(app, &refreshed)?;
            Ok(Some(authorization_value(&refreshed)))
        }
        Err(error) => Err(error),
    }
}
