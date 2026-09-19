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
const DEFAULT_SCOPE: &str = "openid profile email groups_name";

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
}

#[derive(Debug, Clone, Serialize)]
pub struct AuthStatus {
    pub signed_in: bool,
    pub username: Option<String>,
    pub expires_at: Option<u64>,
}

impl From<&StoredTokens> for AuthStatus {
    fn from(tokens: &StoredTokens) -> Self {
        Self {
            signed_in: true,
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

fn username_from_id_token(id_token: &str) -> Option<String> {
    let payload = id_token.split('.').nth(1)?;
    let decoded = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&decoded).ok()?;
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
    let expires_at = now_seconds() + response.expires_in.unwrap_or(300).saturating_sub(TOKEN_SKEW_SECONDS);
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
    })
}

#[tauri::command]
pub fn oauth_status(app: AppHandle) -> AuthStatus {
    match load_tokens(&app) {
        Some(tokens) => AuthStatus::from(&tokens),
        None => AuthStatus {
            signed_in: false,
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

    let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| error.to_string())?;
    let port = listener
        .local_addr()
        .map_err(|error| error.to_string())?
        .port();
    let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");
    let verifier = random_urlsafe(32);
    let challenge = code_challenge(&verifier);
    let state = random_urlsafe(16);

    let mut authorize_url =
        url::Url::parse(&discovery.authorization_endpoint).map_err(|error| error.to_string())?;
    authorize_url
        .query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", &client_id)
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("scope", &scope)
        .append_pair("state", &state)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256");

    app.opener()
        .open_url(authorize_url.as_str(), None::<&str>)
        .map_err(|error| error.to_string())?;

    let expected_state = state.clone();
    let code = tauri::async_runtime::spawn_blocking(move || await_callback(listener, &expected_state))
        .await
        .map_err(|error| error.to_string())??;

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

pub async fn access_token(app: &AppHandle) -> Result<Option<String>, String> {
    let tokens = match load_tokens(app) {
        Some(tokens) => tokens,
        None => return Ok(None),
    };
    if tokens.expires_at > now_seconds() {
        return Ok(Some(tokens.access_token));
    }
    let refresh_token = match tokens.refresh_token.clone() {
        Some(refresh_token) => refresh_token,
        None => {
            clear_tokens(app)?;
            return Ok(None);
        }
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
    match to_stored_tokens(&issuer, &client_id, response) {
        Ok(refreshed) => {
            store_tokens(app, &refreshed)?;
            Ok(Some(refreshed.access_token))
        }
        Err(error) => {
            clear_tokens(app)?;
            Err(error)
        }
    }
}
