use axum::{
    extract::{Form, Path, Query, State},
    http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
    Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Key, Nonce,
};
use chrono::Utc;
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use std::{
    cmp::Reverse,
    env,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::ErrorKind,
    net::SocketAddr,
    os::unix::fs::OpenOptionsExt,
    path::{Path as FsPath, PathBuf},
    process::Command,
    sync::Arc,
};

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 9011;
const DEFAULT_DATA_DIR: &str = ".";
const DEFAULT_STORE_ROOT: &str = ".";
const DEFAULT_RUNTIME_DIR: &str = "/tmp";
const DEFAULT_LOCK_DIR: &str = ".";
const MASTER_KEY_FILENAME: &str = "master.key";
const DB_FILENAME: &str = "mail-archive-ui.sqlite3";
const CUSTOM_CSS: &str = include_str!("../static/custom.css");
const GROUP_NAME: &str = "mail-archive-users";

#[derive(Clone, Debug)]
struct AppConfig {
    address: Arc<str>,
    port: u16,
    data_dir: Arc<str>,
    store_root: Arc<str>,
    runtime_dir: Arc<str>,
    lock_dir: Arc<str>,
    default_tags: Arc<[String]>,
}

#[derive(Clone, Debug)]
struct AppState {
    config: AppConfig,
}

#[derive(Clone, Debug)]
struct Identity {
    username: String,
    email: Option<String>,
    groups: Vec<String>,
}

#[derive(Clone, Debug)]
struct AccountRecord {
    id: i64,
    username: String,
    provider_kind: String,
    display_name: String,
    imap_host: String,
    imap_port: u16,
    imap_username: String,
    folder_mode: String,
    folder_patterns_json: String,
    encrypted_secret: String,
    sync_enabled: bool,
    created_at: String,
    updated_at: String,
    last_sync_started_at: Option<String>,
    last_sync_finished_at: Option<String>,
    last_sync_status: Option<String>,
    last_sync_error: Option<String>,
}

#[derive(Debug)]
struct SearchResult {
    account_name: String,
    timestamp: i64,
    date_label: String,
    from: String,
    subject: String,
    tags: Vec<String>,
}

#[derive(Debug)]
struct AccountPaths {
    maildir: PathBuf,
    state_dir: PathBuf,
    notmuch_config: PathBuf,
    sync_state_dir: PathBuf,
}

#[derive(Debug)]
struct TempSecretFile {
    path: PathBuf,
}

impl Drop for TempSecretFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Debug)]
struct SyncLock {
    path: PathBuf,
}

impl Drop for SyncLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Debug, Deserialize)]
struct CreateAccountForm {
    provider_kind: String,
    display_name: String,
    imap_host: String,
    imap_port: String,
    imap_username: String,
    secret: String,
    folder_patterns: String,
    sync_enabled: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DashboardParams {
    flash: Option<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SearchParams {
    q: Option<String>,
    account_id: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RawNotmuchSummary {
    timestamp: Option<i64>,
    date_relative: Option<String>,
    authors: Option<String>,
    subject: Option<String>,
    tags: Option<Vec<String>>,
}

#[tokio::main]
async fn main() {
    let config = load_config();
    ensure_app_layout(&config).expect("failed to prepare mail archive ui paths");
    initialize_db(&config).expect("failed to initialize sqlite schema");

    if let Some(mode) = env::args().nth(1) {
        if mode == "sync-due" {
            let had_errors = sync_due(&config).expect("mail archive sync-due failed");
            if had_errors {
                std::process::exit(1);
            }
            return;
        }
    }

    let app = router(AppState {
        config: config.clone(),
    });

    let listener = tokio::net::TcpListener::bind(format!("{}:{}", config.address, config.port))
        .await
        .expect("failed to bind mail archive ui");

    let socket_addr: SocketAddr = listener
        .local_addr()
        .expect("failed to read mail archive ui socket");

    eprintln!("mail-archive-ui listening on http://{socket_addr}");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("mail archive ui exited unexpectedly");
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(dashboard))
        .route("/accounts/new", get(new_account))
        .route("/accounts", post(create_account))
        .route("/accounts/{id}/sync", post(sync_account))
        .route("/search", get(search_page))
        .route("/healthz", get(healthz))
        .route("/static/custom.css", get(custom_css))
        .with_state(state)
}

async fn dashboard(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<DashboardParams>,
) -> Response {
    match identity_from_headers(&headers) {
        Ok(identity) => match list_accounts_for_user(&state.config, &identity.username) {
            Ok(accounts) => Html(render_dashboard(
                &identity,
                &accounts,
                params.flash.as_deref(),
                params.error.as_deref(),
            ))
            .into_response(),
            Err(error) => server_error_page("Failed to load accounts", &error),
        },
        Err((status, message)) => auth_error(status, &message),
    }
}

async fn new_account(State(_state): State<AppState>, headers: HeaderMap) -> Response {
    match identity_from_headers(&headers) {
        Ok(identity) => {
            let empty = CreateAccountForm {
                provider_kind: "gmail".to_string(),
                display_name: String::new(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: "993".to_string(),
                imap_username: identity.email.clone().unwrap_or_default(),
                secret: String::new(),
                folder_patterns: gmail_default_patterns().join("\n"),
                sync_enabled: Some("on".to_string()),
            };

            Html(render_new_account(&identity, &empty, None)).into_response()
        }
        Err((status, message)) => auth_error(status, &message),
    }
}

async fn create_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<CreateAccountForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    match validate_account_form(&form) {
        Ok(validated) => match insert_account(&state.config, &identity.username, validated) {
            Ok(_) => Redirect::to("/?flash=Mailbox+saved").into_response(),
            Err(error) => server_error_page("Failed to save mailbox", &error),
        },
        Err(error) => Html(render_new_account(&identity, &form, Some(&error))).into_response(),
    }
}

async fn sync_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();

    let sync_result =
        tokio::task::spawn_blocking(move || sync_account_for_user(&config, &username, account_id))
            .await;

    let redirect_target = match sync_result {
        Ok(Ok(())) => "/?flash=Mailbox+sync+completed".to_string(),
        Ok(Err(error)) => format!("/?error={}", url_encode_component(&error)),
        Err(_) => "/?error=Mailbox+sync+task+failed".to_string(),
    };

    Redirect::to(&redirect_target).into_response()
}

async fn search_page(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let accounts = match list_accounts_for_user(&state.config, &identity.username) {
        Ok(accounts) => accounts,
        Err(error) => return server_error_page("Failed to load mailboxes", &error),
    };

    let query_text = params.q.unwrap_or_default();
    let result = if query_text.trim().is_empty() {
        Ok(Vec::new())
    } else {
        let config = state.config.clone();
        let username = identity.username.clone();
        let query_clone = query_text.clone();
        let account_id = params.account_id;

        match tokio::task::spawn_blocking(move || {
            search_mail(&config, &username, account_id, &query_clone)
        })
        .await
        {
            Ok(result) => result,
            Err(_) => Err("Search task failed".to_string()),
        }
    };

    match result {
        Ok(results) => Html(render_search(
            &identity,
            &accounts,
            &query_text,
            params.account_id,
            &results,
            None,
        ))
        .into_response(),
        Err(error) => Html(render_search(
            &identity,
            &accounts,
            &query_text,
            params.account_id,
            &[],
            Some(&error),
        ))
        .into_response(),
    }
}

async fn healthz() -> &'static str {
    "ok"
}

async fn custom_css() -> Response {
    ([(CONTENT_TYPE, "text/css; charset=utf-8")], CUSTOM_CSS).into_response()
}

fn load_config() -> AppConfig {
    let address =
        env::var("MAIL_ARCHIVE_UI_ADDRESS").unwrap_or_else(|_| DEFAULT_ADDRESS.to_string());
    let port = env::var("MAIL_ARCHIVE_UI_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);
    let data_dir =
        env::var("MAIL_ARCHIVE_UI_DATA_DIR").unwrap_or_else(|_| DEFAULT_DATA_DIR.to_string());
    let store_root =
        env::var("MAIL_ARCHIVE_UI_STORE_ROOT").unwrap_or_else(|_| DEFAULT_STORE_ROOT.to_string());
    let runtime_dir =
        env::var("MAIL_ARCHIVE_UI_RUNTIME_DIR").unwrap_or_else(|_| DEFAULT_RUNTIME_DIR.to_string());
    let lock_dir =
        env::var("MAIL_ARCHIVE_UI_LOCK_DIR").unwrap_or_else(|_| DEFAULT_LOCK_DIR.to_string());
    let default_tags = env::var("MAIL_ARCHIVE_UI_DEFAULT_TAGS")
        .ok()
        .map(|value| {
            value
                .split(';')
                .map(str::trim)
                .filter(|tag| !tag.is_empty())
                .map(ToString::to_string)
                .collect::<Vec<_>>()
        })
        .filter(|tags| !tags.is_empty())
        .unwrap_or_else(|| vec!["new".to_string()]);

    AppConfig {
        address: Arc::<str>::from(address),
        port,
        data_dir: Arc::<str>::from(data_dir),
        store_root: Arc::<str>::from(store_root),
        runtime_dir: Arc::<str>::from(runtime_dir),
        lock_dir: Arc::<str>::from(lock_dir),
        default_tags: Arc::from(default_tags),
    }
}

fn ensure_app_layout(config: &AppConfig) -> Result<(), String> {
    for directory in [
        config.data_dir.as_ref(),
        config.runtime_dir.as_ref(),
        config.lock_dir.as_ref(),
    ] {
        fs::create_dir_all(directory)
            .map_err(|error| format!("failed to create {directory}: {error}"))?;
    }

    Ok(())
}

fn initialize_db(config: &AppConfig) -> Result<(), String> {
    let connection = open_db(config)?;

    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;

            CREATE TABLE IF NOT EXISTS accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                provider_kind TEXT NOT NULL,
                display_name TEXT NOT NULL,
                imap_host TEXT NOT NULL,
                imap_port INTEGER NOT NULL,
                imap_username TEXT NOT NULL,
                folder_mode TEXT NOT NULL,
                folder_patterns_json TEXT NOT NULL,
                encrypted_secret TEXT NOT NULL,
                sync_enabled INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_sync_started_at TEXT,
                last_sync_finished_at TEXT,
                last_sync_status TEXT,
                last_sync_error TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts (username);

            CREATE TABLE IF NOT EXISTS search_preferences (
                username TEXT PRIMARY KEY,
                last_query TEXT,
                default_account_id INTEGER
            );
            "#,
        )
        .map_err(|error| format!("failed to initialize sqlite schema: {error}"))?;

    Ok(())
}

fn open_db(config: &AppConfig) -> Result<Connection, String> {
    let db_path = PathBuf::from(config.data_dir.as_ref()).join(DB_FILENAME);
    Connection::open(db_path).map_err(|error| format!("failed to open sqlite database: {error}"))
}

fn identity_from_headers(headers: &HeaderMap) -> Result<Identity, (StatusCode, String)> {
    let username = header_value(headers, "x-forwarded-preferred-username")
        .or_else(|| header_value(headers, "x-forwarded-user"))
        .ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                "Missing authenticated username".to_string(),
            )
        })?;

    let email = header_value(headers, "x-forwarded-email");
    let groups = split_groups(
        header_value(headers, "x-forwarded-groups")
            .unwrap_or_default()
            .as_str(),
    );

    if !groups.iter().any(|group| group == GROUP_NAME) {
        return Err((
            StatusCode::FORBIDDEN,
            "mail-archive-users membership is required".to_string(),
        ));
    }

    Ok(Identity {
        username,
        email,
        groups,
    })
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn split_groups(raw: &str) -> Vec<String> {
    raw.split(|character: char| character == ',' || character == ';' || character.is_whitespace())
        .map(str::trim)
        .filter(|group| !group.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn validate_account_form(form: &CreateAccountForm) -> Result<ValidatedAccount, String> {
    let provider_kind = form.provider_kind.trim();
    if provider_kind != "gmail" && provider_kind != "generic_imap" {
        return Err("Unsupported provider preset".to_string());
    }

    let display_name = form.display_name.trim();
    if display_name.is_empty() {
        return Err("Display name is required".to_string());
    }

    let secret = form.secret.trim();
    if secret.is_empty() {
        return Err("Mailbox password or app password is required".to_string());
    }

    let imap_host = if provider_kind == "gmail" {
        "imap.gmail.com".to_string()
    } else {
        let host = form.imap_host.trim();
        if host.is_empty() {
            return Err("IMAP host is required for generic IMAP".to_string());
        }
        host.to_string()
    };

    let imap_port = if provider_kind == "gmail" && form.imap_port.trim().is_empty() {
        993
    } else {
        form.imap_port
            .trim()
            .parse::<u16>()
            .map_err(|_| "IMAP port must be a valid number".to_string())?
    };

    let imap_username = form.imap_username.trim();
    if imap_username.is_empty() {
        return Err("Mailbox username is required".to_string());
    }

    let patterns = parse_folder_patterns(provider_kind, &form.folder_patterns);
    let folder_mode = if provider_kind == "gmail" && patterns == gmail_default_patterns() {
        "gmail_default"
    } else if provider_kind == "generic_imap" && patterns == generic_default_patterns() {
        "generic_default"
    } else {
        "custom"
    };

    Ok(ValidatedAccount {
        provider_kind: provider_kind.to_string(),
        display_name: display_name.to_string(),
        imap_host,
        imap_port,
        imap_username: imap_username.to_string(),
        folder_mode: folder_mode.to_string(),
        folder_patterns: patterns,
        secret: secret.to_string(),
        sync_enabled: form.sync_enabled.is_some(),
    })
}

fn parse_folder_patterns(provider_kind: &str, raw: &str) -> Vec<String> {
    let parsed = raw
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToString::to_string)
        .collect::<Vec<_>>();

    if !parsed.is_empty() {
        return parsed;
    }

    if provider_kind == "gmail" {
        gmail_default_patterns()
    } else {
        generic_default_patterns()
    }
}

fn gmail_default_patterns() -> Vec<String> {
    [
        "INBOX",
        "[Gmail]/All Mail",
        "[Gmail]/Sent Mail",
        "[Gmail]/Drafts",
        "[Gmail]/Important",
    ]
    .into_iter()
    .map(ToString::to_string)
    .collect()
}

fn generic_default_patterns() -> Vec<String> {
    ["INBOX", "Sent", "Drafts", "Archive"]
        .into_iter()
        .map(ToString::to_string)
        .collect()
}

#[derive(Debug)]
struct ValidatedAccount {
    provider_kind: String,
    display_name: String,
    imap_host: String,
    imap_port: u16,
    imap_username: String,
    folder_mode: String,
    folder_patterns: Vec<String>,
    secret: String,
    sync_enabled: bool,
}

fn insert_account(
    config: &AppConfig,
    username: &str,
    account: ValidatedAccount,
) -> Result<(), String> {
    let encryption_key = load_or_create_master_key(config)?;
    let encrypted_secret = encrypt_secret(&encryption_key, &account.secret)?;
    let now = Utc::now().to_rfc3339();
    let patterns_json = serde_json::to_string(&account.folder_patterns)
        .map_err(|error| format!("patterns json failed: {error}"))?;

    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO accounts (
                username,
                provider_kind,
                display_name,
                imap_host,
                imap_port,
                imap_username,
                folder_mode,
                folder_patterns_json,
                encrypted_secret,
                sync_enabled,
                created_at,
                updated_at,
                last_sync_status,
                last_sync_error
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            "#,
            params![
                username,
                account.provider_kind,
                account.display_name,
                account.imap_host,
                i64::from(account.imap_port),
                account.imap_username,
                account.folder_mode,
                patterns_json,
                encrypted_secret,
                if account.sync_enabled { 1 } else { 0 },
                now,
                now,
                "idle",
                Option::<String>::None,
            ],
        )
        .map_err(|error| format!("failed to insert account: {error}"))?;

    Ok(())
}

fn list_accounts_for_user(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<AccountRecord>, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                id,
                username,
                provider_kind,
                display_name,
                imap_host,
                imap_port,
                imap_username,
                folder_mode,
                folder_patterns_json,
                encrypted_secret,
                sync_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error
            FROM accounts
            WHERE username = ?1
            ORDER BY display_name COLLATE NOCASE, id ASC
            "#,
        )
        .map_err(|error| format!("failed to prepare account query: {error}"))?;

    let rows = statement
        .query_map(params![username], map_account_row)
        .map_err(|error| format!("failed to query accounts: {error}"))?;

    let mut accounts = Vec::new();
    for row in rows {
        accounts.push(row.map_err(|error| format!("failed to decode account row: {error}"))?);
    }

    Ok(accounts)
}

fn load_account_for_user(
    config: &AppConfig,
    username: &str,
    account_id: i64,
) -> Result<AccountRecord, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            r#"
            SELECT
                id,
                username,
                provider_kind,
                display_name,
                imap_host,
                imap_port,
                imap_username,
                folder_mode,
                folder_patterns_json,
                encrypted_secret,
                sync_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error
            FROM accounts
            WHERE username = ?1 AND id = ?2
            "#,
            params![username, account_id],
            map_account_row,
        )
        .optional()
        .map_err(|error| format!("failed to load account: {error}"))?
        .ok_or_else(|| "Mailbox not found".to_string())
}

fn map_account_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AccountRecord> {
    Ok(AccountRecord {
        id: row.get(0)?,
        username: row.get(1)?,
        provider_kind: row.get(2)?,
        display_name: row.get(3)?,
        imap_host: row.get(4)?,
        imap_port: row.get::<_, u16>(5)?,
        imap_username: row.get(6)?,
        folder_mode: row.get(7)?,
        folder_patterns_json: row.get(8)?,
        encrypted_secret: row.get(9)?,
        sync_enabled: row.get::<_, i64>(10)? != 0,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
        last_sync_started_at: row.get(13)?,
        last_sync_finished_at: row.get(14)?,
        last_sync_status: row.get(15)?,
        last_sync_error: row.get(16)?,
    })
}

fn load_or_create_master_key(config: &AppConfig) -> Result<Vec<u8>, String> {
    let key_path = PathBuf::from(config.data_dir.as_ref()).join(MASTER_KEY_FILENAME);

    if let Ok(existing) = fs::read_to_string(&key_path) {
        let decoded = BASE64
            .decode(existing.trim())
            .map_err(|error| format!("failed to decode master key: {error}"))?;
        if decoded.len() != 32 {
            return Err("master key has the wrong length".to_string());
        }
        return Ok(decoded);
    }

    let mut key_bytes = vec![0_u8; 32];
    OsRng.fill_bytes(&mut key_bytes);

    let encoded = BASE64.encode(&key_bytes);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&key_path)
        .map_err(|error| format!("failed to create master key: {error}"))?;
    std::io::Write::write_all(&mut file, encoded.as_bytes())
        .map_err(|error| format!("failed to write master key: {error}"))?;

    Ok(key_bytes)
}

fn encrypt_secret(key_bytes: &[u8], secret: &str) -> Result<String, String> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key_bytes));
    let mut nonce_bytes = [0_u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut ciphertext = cipher
        .encrypt(nonce, secret.as_bytes())
        .map_err(|_| "failed to encrypt secret".to_string())?;
    let mut combined = nonce_bytes.to_vec();
    combined.append(&mut ciphertext);
    Ok(BASE64.encode(combined))
}

fn decrypt_secret(key_bytes: &[u8], encoded: &str) -> Result<String, String> {
    let payload = BASE64
        .decode(encoded)
        .map_err(|error| format!("failed to decode encrypted secret: {error}"))?;
    if payload.len() < 13 {
        return Err("encrypted secret payload is too short".to_string());
    }

    let (nonce_bytes, ciphertext) = payload.split_at(12);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key_bytes));
    let plaintext = cipher
        .decrypt(Nonce::from_slice(nonce_bytes), ciphertext)
        .map_err(|_| "failed to decrypt secret".to_string())?;

    String::from_utf8(plaintext).map_err(|error| format!("failed to decode plaintext: {error}"))
}

fn sync_due(config: &AppConfig) -> Result<bool, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                id,
                username,
                provider_kind,
                display_name,
                imap_host,
                imap_port,
                imap_username,
                folder_mode,
                folder_patterns_json,
                encrypted_secret,
                sync_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error
            FROM accounts
            WHERE sync_enabled = 1
            ORDER BY username ASC, display_name COLLATE NOCASE ASC, id ASC
            "#,
        )
        .map_err(|error| format!("failed to prepare sync query: {error}"))?;

    let rows = statement
        .query_map([], map_account_row)
        .map_err(|error| format!("failed to query sync accounts: {error}"))?;

    let mut had_errors = false;

    for row in rows {
        let account = row.map_err(|error| format!("failed to decode sync account: {error}"))?;
        if let Err(error) = sync_loaded_account(config, &account) {
            eprintln!(
                "mail-archive-ui sync failed for {}:{}: {error}",
                account.username, account.id
            );
            had_errors = true;
        }
    }

    Ok(had_errors)
}

fn sync_account_for_user(
    config: &AppConfig,
    username: &str,
    account_id: i64,
) -> Result<(), String> {
    let account = load_account_for_user(config, username, account_id)?;
    sync_loaded_account(config, &account)
}

fn sync_loaded_account(config: &AppConfig, account: &AccountRecord) -> Result<(), String> {
    let _lock = acquire_account_lock(config, account.id)?;
    update_sync_started(config, account.id)?;

    let result: Result<(), String> = (|| {
        let encryption_key = load_or_create_master_key(config)?;
        let secret = decrypt_secret(&encryption_key, &account.encrypted_secret)?;
        let account_paths = ensure_account_paths(config, account)?;
        ensure_notmuch_config(config, account, &account_paths)?;
        let temp_secret = write_temp_secret(config, account.id, &secret)?;
        let temp_config = write_temp_mbsyncrc(config, account, &account_paths, &temp_secret.path)?;

        run_command(
            "mbsync",
            &["-c", temp_config.to_string_lossy().as_ref(), "--all"],
            &[("HOME", account_paths.state_dir.to_string_lossy().as_ref())],
        )?;

        run_command(
            "notmuch",
            &["new"],
            &[
                ("HOME", account_paths.state_dir.to_string_lossy().as_ref()),
                (
                    "NOTMUCH_CONFIG",
                    account_paths.notmuch_config.to_string_lossy().as_ref(),
                ),
            ],
        )?;

        let _ = fs::remove_file(temp_config);
        Ok(())
    })();

    match result {
        Ok(()) => {
            update_sync_finished(config, account.id, "ok", None)?;
            Ok(())
        }
        Err(error) => {
            update_sync_finished(config, account.id, "error", Some(error.clone()))?;
            Err(error)
        }
    }
}

fn acquire_account_lock(config: &AppConfig, account_id: i64) -> Result<SyncLock, String> {
    let lock_path =
        PathBuf::from(config.lock_dir.as_ref()).join(format!("account-{account_id}.lock"));
    match OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&lock_path)
    {
        Ok(mut file) => {
            std::io::Write::write_all(&mut file, account_id.to_string().as_bytes())
                .map_err(|error| format!("failed to write sync lock: {error}"))?;
            Ok(SyncLock { path: lock_path })
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            Err("Mailbox sync is already running".to_string())
        }
        Err(error) => Err(format!("failed to create sync lock: {error}")),
    }
}

fn ensure_account_paths(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<AccountPaths, String> {
    let store_root = PathBuf::from(config.store_root.as_ref());
    let store_root_metadata = fs::metadata(&store_root)
        .map_err(|error| format!("mail archive store root is unavailable: {error}"))?;
    if !store_root_metadata.is_dir() {
        return Err("mail archive store root is not a directory".to_string());
    }

    let root = store_root
        .join("users")
        .join(&account.username)
        .join("accounts")
        .join(account.id.to_string());
    let maildir = root.join("maildir");
    let state_dir = root.join("state");
    let sync_state_dir = state_dir.join("mbsync-state");
    let notmuch_config = state_dir.join("notmuch-config");

    for directory in [&maildir, &state_dir, &sync_state_dir] {
        fs::create_dir_all(directory)
            .map_err(|error| format!("failed to create {}: {error}", directory.display()))?;
    }

    Ok(AccountPaths {
        maildir,
        state_dir,
        notmuch_config,
        sync_state_dir,
    })
}

fn ensure_notmuch_config(
    config: &AppConfig,
    account: &AccountRecord,
    account_paths: &AccountPaths,
) -> Result<(), String> {
    if account_paths.notmuch_config.exists() {
        return Ok(());
    }

    let tags = config.default_tags.join(";");
    let contents = format!(
        "[database]\npath={}\n\n[user]\nname={}\nprimary_email={}\n\n[new]\ntags={}\nignore=\n\n[search]\nexclude_tags=\n\n[maildir]\nsynchronize_flags=true\n",
        account_paths.maildir.display(),
        account.username,
        account.imap_username,
        tags
    );

    fs::write(&account_paths.notmuch_config, contents)
        .map_err(|error| format!("failed to write notmuch config: {error}"))?;

    Ok(())
}

fn write_temp_secret(
    config: &AppConfig,
    account_id: i64,
    secret: &str,
) -> Result<TempSecretFile, String> {
    let name = format!("account-{account_id}-secret-{}.tmp", random_hex(8));
    let path = PathBuf::from(config.runtime_dir.as_ref()).join(name);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .map_err(|error| format!("failed to create temporary secret file: {error}"))?;
    std::io::Write::write_all(&mut file, secret.as_bytes())
        .map_err(|error| format!("failed to write temporary secret file: {error}"))?;
    Ok(TempSecretFile { path })
}

fn write_temp_mbsyncrc(
    config: &AppConfig,
    account: &AccountRecord,
    account_paths: &AccountPaths,
    secret_path: &FsPath,
) -> Result<PathBuf, String> {
    let patterns = decode_folder_patterns(account)?;
    let temp_path = PathBuf::from(config.runtime_dir.as_ref()).join(format!(
        "account-{}-mbsyncrc-{}.conf",
        account.id,
        random_hex(8)
    ));
    let account_alias = format!("account{}", account.id);
    let mut rendered = String::new();

    writeln!(&mut rendered, "IMAPAccount {account_alias}")
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Host {}", account.imap_host)
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Port {}", account.imap_port)
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "User {}", account.imap_username)
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "PassCmd \"cat {}\"", secret_path.display())
        .map_err(|error| format!("failed to render config: {error}"))?;
    rendered.push_str(
        "TLSType IMAPS\nAuthMechs LOGIN\nCertificateFile /etc/ssl/certs/ca-bundle.crt\n\n",
    );
    writeln!(&mut rendered, "IMAPStore {account_alias}-remote")
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Account {account_alias}")
        .map_err(|error| format!("failed to render config: {error}"))?;
    rendered.push('\n');
    writeln!(&mut rendered, "MaildirStore {account_alias}-local")
        .map_err(|error| format!("failed to render config: {error}"))?;
    rendered.push_str("SubFolders Verbatim\n");
    writeln!(
        &mut rendered,
        "Inbox {}",
        account_paths.maildir.join("Inbox").display()
    )
    .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Path {}/", account_paths.maildir.display())
        .map_err(|error| format!("failed to render config: {error}"))?;
    rendered.push('\n');
    writeln!(&mut rendered, "Channel {account_alias}-archive")
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Far :{account_alias}-remote:")
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(&mut rendered, "Near :{account_alias}-local:")
        .map_err(|error| format!("failed to render config: {error}"))?;
    writeln!(
        &mut rendered,
        "Patterns {}",
        patterns
            .iter()
            .map(|pattern| format!("\"{pattern}\""))
            .collect::<Vec<_>>()
            .join(" ")
    )
    .map_err(|error| format!("failed to render config: {error}"))?;
    rendered.push_str(
        "Create Near\nExpunge None\nRemove None\nSync Pull New Flags\nCopyArrivalDate yes\n",
    );
    writeln!(
        &mut rendered,
        "SyncState {}",
        account_paths.sync_state_dir.display()
    )
    .map_err(|error| format!("failed to render config: {error}"))?;

    fs::write(&temp_path, rendered)
        .map_err(|error| format!("failed to write mbsyncrc: {error}"))?;
    Ok(temp_path)
}

fn decode_folder_patterns(account: &AccountRecord) -> Result<Vec<String>, String> {
    serde_json::from_str::<Vec<String>>(&account.folder_patterns_json).map_err(|error| {
        format!(
            "failed to decode folder patterns for {}: {error}",
            account.display_name
        )
    })
}

fn update_sync_started(config: &AppConfig, account_id: i64) -> Result<(), String> {
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            UPDATE accounts
            SET
                last_sync_started_at = ?1,
                updated_at = ?1,
                last_sync_status = 'running',
                last_sync_error = NULL
            WHERE id = ?2
            "#,
            params![Utc::now().to_rfc3339(), account_id],
        )
        .map_err(|error| format!("failed to mark sync start: {error}"))?;
    Ok(())
}

fn update_sync_finished(
    config: &AppConfig,
    account_id: i64,
    status: &str,
    error_message: Option<String>,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let now = Utc::now().to_rfc3339();
    connection
        .execute(
            r#"
            UPDATE accounts
            SET
                last_sync_finished_at = ?1,
                updated_at = ?1,
                last_sync_status = ?2,
                last_sync_error = ?3
            WHERE id = ?4
            "#,
            params![now, status, error_message, account_id],
        )
        .map_err(|error| format!("failed to mark sync finish: {error}"))?;
    Ok(())
}

fn run_command(command: &str, args: &[&str], envs: &[(&str, &str)]) -> Result<(), String> {
    let mut process = Command::new(command);
    process.args(args);
    process.env_clear();
    process.env("PATH", env::var("PATH").unwrap_or_default());
    process.env("LANG", "C.UTF-8");

    for (name, value) in envs {
        process.env(name, value);
    }

    let output = process
        .output()
        .map_err(|error| format!("failed to run {command}: {error}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let detail = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with {}", output.status)
    };

    Err(detail)
}

fn search_mail(
    config: &AppConfig,
    username: &str,
    selected_account_id: Option<i64>,
    query: &str,
) -> Result<Vec<SearchResult>, String> {
    let accounts = list_accounts_for_user(config, username)?;
    let filtered = accounts
        .into_iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
        .collect::<Vec<_>>();

    let mut results = Vec::new();

    for account in filtered {
        let account_paths = ensure_account_paths(config, &account)?;
        if !account_paths.notmuch_config.exists() {
            continue;
        }

        let output = Command::new("notmuch")
            .arg("search")
            .arg("--format=json")
            .arg("--output=summary")
            .arg(query)
            .env("PATH", env::var("PATH").unwrap_or_default())
            .env("LANG", "C.UTF-8")
            .env("HOME", &account_paths.state_dir)
            .env("NOTMUCH_CONFIG", &account_paths.notmuch_config)
            .output()
            .map_err(|error| format!("failed to run notmuch: {error}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if stderr.contains("No database found") || stderr.contains("not initialized") {
                continue;
            }
            return Err(stderr.trim().to_string());
        }

        let parsed: Vec<RawNotmuchSummary> = serde_json::from_slice(&output.stdout)
            .map_err(|error| format!("failed to parse notmuch search output: {error}"))?;

        for item in parsed {
            results.push(SearchResult {
                account_name: account.display_name.clone(),
                timestamp: item.timestamp.unwrap_or_default(),
                date_label: item
                    .date_relative
                    .unwrap_or_else(|| format_timestamp(item.timestamp.unwrap_or_default())),
                from: item.authors.unwrap_or_else(|| "Unknown sender".to_string()),
                subject: item.subject.unwrap_or_else(|| "(no subject)".to_string()),
                tags: item.tags.unwrap_or_default(),
            });
        }
    }

    results.sort_by_key(|result| Reverse(result.timestamp));
    Ok(results)
}

fn render_dashboard(
    identity: &Identity,
    accounts: &[AccountRecord],
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();

    if let Some(flash) = flash {
        writeln!(
            &mut body,
            "<div class=\"flash\">{}</div>",
            escape_html(&flash.replace('+', " "))
        )
        .ok();
    }

    if let Some(error) = error {
        writeln!(
            &mut body,
            "<div class=\"error\">{}</div>",
            escape_html(&error.replace('+', " "))
        )
        .ok();
    }

    body.push_str(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Private Mail Archive</p>
          <h1>Mailbox sync and search, without turning this into webmail.</h1>
          <p class=\"lede\">Mailboxes stay scoped to your authenticated Kanidm identity. Sync runs through <code>mbsync</code>, search runs through <code>notmuch</code>, and downloaded mail stays in your isolated server-side archive.</p>
          <div class=\"nav\">
            <a href=\"/accounts/new\">Add mailbox</a>
            <a class=\"secondary\" href=\"/search\">Search mail</a>
          </div>
        </section>",
    );

    body.push_str("<section class=\"panel\"><h2>Connected mailboxes</h2>");
    if accounts.is_empty() {
        body.push_str(
            "<p class=\"meta\">No mailbox is configured yet. Start with Gmail or a generic IMAP account.</p>",
        );
    } else {
        body.push_str(
            "<table><thead><tr><th>Mailbox</th><th>Status</th><th>Last sync</th><th>Actions</th></tr></thead><tbody>",
        );
        for account in accounts {
            let status_class = match account.last_sync_status.as_deref() {
                Some("ok") => "ok",
                Some("running") => "pending",
                Some("error") => "error",
                _ => "pending",
            };
            let status_label = account.last_sync_status.as_deref().unwrap_or("idle");
            let last_sync = account
                .last_sync_finished_at
                .as_deref()
                .or(account.last_sync_started_at.as_deref())
                .map(escape_html)
                .unwrap_or_else(|| "Never".to_string());
            let sync_hint = account
                .last_sync_error
                .as_deref()
                .map(escape_html)
                .unwrap_or_default();
            writeln!(
                &mut body,
                "<tr><td><strong>{}</strong><div class=\"meta\">{} · {} · {}:{}</div>{}<div class=\"hint\">Added {} · Updated {}</div></td><td><span class=\"status {}\">{}</span></td><td>{}</td><td><form method=\"post\" action=\"/accounts/{}/sync\"><button type=\"submit\">Sync now</button></form></td></tr>",
                escape_html(&account.display_name),
                escape_html(&account.provider_kind),
                escape_html(&account.folder_mode),
                escape_html(&account.imap_host),
                account.imap_port,
                if account.sync_enabled {
                    "<div class=\"hint\">Background sync enabled</div>".to_string()
                } else {
                    "<div class=\"hint\">Background sync disabled</div>".to_string()
                },
                escape_html(&account.created_at),
                escape_html(&account.updated_at),
                status_class,
                escape_html(status_label),
                last_sync,
                account.id,
            )
            .ok();

            if !sync_hint.is_empty() {
                writeln!(
                    &mut body,
                    "<tr><td colspan=\"4\"><div class=\"error\">{}</div></td></tr>",
                    sync_hint
                )
                .ok();
            }
        }
        body.push_str("</tbody></table>");
    }
    body.push_str("</section>");

    layout("Mail Archive", identity, &body)
}

fn render_new_account(
    identity: &Identity,
    form: &CreateAccountForm,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Add Mailbox</p>
          <h1>Connect a mailbox with an app password or IMAP password.</h1>
          <p class=\"lede\">The UI stores the credential encrypted at rest, generates the sync config on demand, and keeps downloaded mail in your private archive only.</p>
        </section>",
    );

    body.push_str("<section class=\"panel stack\">");
    if let Some(error) = error {
        writeln!(
            &mut body,
            "<div class=\"error\">{}</div>",
            escape_html(error)
        )
        .ok();
    }

    writeln!(
        &mut body,
        "<form method=\"post\" action=\"/accounts\" class=\"fields\">
          <div class=\"fields two\">
            <label>Provider preset
              <select name=\"provider_kind\">
                <option value=\"gmail\" {}>Gmail</option>
                <option value=\"generic_imap\" {}>Generic IMAP</option>
              </select>
            </label>
            <label>Display name
              <input name=\"display_name\" value=\"{}\" placeholder=\"Personal Gmail\">
            </label>
          </div>
          <div class=\"fields two\">
            <label>IMAP host
              <input name=\"imap_host\" value=\"{}\" placeholder=\"imap.gmail.com\">
            </label>
            <label>IMAP port
              <input name=\"imap_port\" value=\"{}\" placeholder=\"993\">
            </label>
          </div>
          <div class=\"fields two\">
            <label>Mailbox username
              <input name=\"imap_username\" value=\"{}\" placeholder=\"you@example.com\">
            </label>
            <label>Mailbox password / app password
              <input type=\"password\" name=\"secret\" value=\"{}\" autocomplete=\"new-password\">
            </label>
          </div>
          <label>Folders to archive
            <textarea name=\"folder_patterns\" placeholder=\"One IMAP pattern per line\">{}</textarea>
          </label>
          <label><input type=\"checkbox\" name=\"sync_enabled\" {}> Enable scheduled background sync</label>
          <div class=\"actions\">
            <button type=\"submit\">Save mailbox</button>
            <a class=\"button-link secondary\" href=\"/\">Cancel</a>
          </div>
          <ul class=\"muted-list\">
            <li>Gmail defaults to append-only archive folders.</li>
            <li>Generic IMAP keeps TLS on port 993 by default.</li>
            <li>This is archive/search infrastructure, not a browser mail client.</li>
          </ul>
        </form>",
        if form.provider_kind == "gmail" {
            "selected"
        } else {
            ""
        },
        if form.provider_kind == "generic_imap" {
            "selected"
        } else {
            ""
        },
        escape_html(&form.display_name),
        escape_html(&form.imap_host),
        escape_html(&form.imap_port),
        escape_html(&form.imap_username),
        escape_html(&form.secret),
        escape_html(&form.folder_patterns),
        if form.sync_enabled.is_some() { "checked" } else { "" },
    )
    .ok();
    body.push_str("</section>");

    layout("Add Mailbox", identity, &body)
}

fn render_search(
    identity: &Identity,
    accounts: &[AccountRecord],
    query: &str,
    selected_account_id: Option<i64>,
    results: &[SearchResult],
    error: Option<&str>,
) -> String {
    let mut body = String::new();

    body.push_str(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Search Archive</p>
          <h1>Query your downloaded mail with notmuch.</h1>
          <p class=\"lede\">Search runs only across your own archive. Results show message metadata, not message bodies.</p>
        </section>",
    );

    body.push_str("<section class=\"panel stack\">");
    if let Some(error) = error {
        writeln!(
            &mut body,
            "<div class=\"error\">{}</div>",
            escape_html(error)
        )
        .ok();
    }

    writeln!(
        &mut body,
        "<form method=\"get\" action=\"/search\" class=\"fields\">
          <div class=\"fields two\">
            <label>Search query
              <input name=\"q\" value=\"{}\" placeholder=\"from:billing@example.com subject:invoice\">
            </label>
            <label>Mailbox
              <select name=\"account_id\">
                <option value=\"\">All mailboxes</option>
                {}
              </select>
            </label>
          </div>
          <div class=\"actions\">
            <button type=\"submit\">Search</button>
            <a class=\"button-link secondary\" href=\"/\">Back to dashboard</a>
          </div>
        </form>",
        escape_html(query),
        render_account_options(accounts, selected_account_id),
    )
    .ok();
    body.push_str("</section>");

    if !query.trim().is_empty() {
        writeln!(
            &mut body,
            "<section class=\"grid\">{} </section>",
            if results.is_empty() {
                "<div class=\"panel\"><p class=\"meta\">No indexed messages matched this query yet.</p></div>".to_string()
            } else {
                results
                    .iter()
                    .map(render_search_result)
                    .collect::<Vec<_>>()
                    .join("")
            }
        )
        .ok();
    }

    layout("Search Mail", identity, &body)
}

fn render_account_options(accounts: &[AccountRecord], selected_account_id: Option<i64>) -> String {
    accounts
        .iter()
        .map(|account| {
            format!(
                "<option value=\"{}\" {}>{}</option>",
                account.id,
                if selected_account_id == Some(account.id) {
                    "selected"
                } else {
                    ""
                },
                escape_html(&account.display_name)
            )
        })
        .collect::<Vec<_>>()
        .join("")
}

fn render_search_result(result: &SearchResult) -> String {
    format!(
        "<article class=\"result stack\">
          <div>
            <p class=\"eyebrow\">{}</p>
            <h2>{}</h2>
            <p class=\"meta\">{} · {}</p>
          </div>
          <div class=\"tag-list\">{}</div>
        </article>",
        escape_html(&result.account_name),
        escape_html(&result.subject),
        escape_html(&result.from),
        escape_html(&result.date_label),
        if result.tags.is_empty() {
            "<span class=\"meta\">No tags</span>".to_string()
        } else {
            result
                .tags
                .iter()
                .map(|tag| format!("<span class=\"tag\">{}</span>", escape_html(tag)))
                .collect::<Vec<_>>()
                .join("")
        }
    )
}

fn layout(title: &str, identity: &Identity, body: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{}</title>
    <link rel="stylesheet" href="/static/custom.css">
  </head>
  <body>
    <main class="page">
      <div class="panel" style="margin-bottom: 1rem;">
        <strong>{}</strong>
        <div class="meta">{} · groups: {}</div>
      </div>
      {}
    </main>
  </body>
</html>"#,
        escape_html(title),
        escape_html(&identity.username),
        escape_html(identity.email.as_deref().unwrap_or("no forwarded email")),
        escape_html(&identity.groups.join(", ")),
        body
    )
}

fn auth_error(status: StatusCode, message: &str) -> Response {
    (
        status,
        Html(format!(
            "<!doctype html><html><body><h1>Access denied</h1><p>{}</p></body></html>",
            escape_html(message)
        )),
    )
        .into_response()
}

fn server_error_page(title: &str, message: &str) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Html(format!(
            "<!doctype html><html><body><h1>{}</h1><p>{}</p></body></html>",
            escape_html(title),
            escape_html(message)
        )),
    )
        .into_response()
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn url_encode_component(input: &str) -> String {
    let mut encoded = String::new();
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char)
            }
            b' ' => encoded.push('+'),
            _ => {
                let _ = write!(&mut encoded, "%{byte:02X}");
            }
        }
    }
    encoded
}

fn format_timestamp(timestamp: i64) -> String {
    chrono::DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.to_rfc3339())
        .unwrap_or_else(|| "Unknown date".to_string())
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    OsRng.fill_bytes(&mut buffer);
    buffer
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_config(tempdir: &TempDir) -> AppConfig {
        let data_dir = tempdir.path().join("data");
        let store_root = tempdir.path().join("store");
        let runtime_dir = tempdir.path().join("runtime");
        let lock_dir = tempdir.path().join("locks");

        AppConfig {
            address: Arc::<str>::from("127.0.0.1"),
            port: 9011,
            data_dir: Arc::<str>::from(data_dir.to_string_lossy().to_string()),
            store_root: Arc::<str>::from(store_root.to_string_lossy().to_string()),
            runtime_dir: Arc::<str>::from(runtime_dir.to_string_lossy().to_string()),
            lock_dir: Arc::<str>::from(lock_dir.to_string_lossy().to_string()),
            default_tags: Arc::from(vec!["new".to_string()]),
        }
    }

    #[test]
    fn forwarded_header_identity_requires_group_membership() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-preferred-username",
            "alice".parse().expect("valid username header"),
        );
        headers.insert(
            "x-forwarded-email",
            "alice@example.com".parse().expect("valid email header"),
        );
        headers.insert(
            "x-forwarded-groups",
            "users,mail-archive-users"
                .parse()
                .expect("valid groups header"),
        );

        let identity = identity_from_headers(&headers).expect("identity should be accepted");
        assert_eq!(identity.username, "alice");
        assert_eq!(identity.email.as_deref(), Some("alice@example.com"));
        assert!(identity
            .groups
            .iter()
            .any(|group| group == "mail-archive-users"));
    }

    #[test]
    fn forwarded_header_identity_rejects_missing_access_group() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-preferred-username",
            "alice".parse().expect("valid username header"),
        );
        headers.insert(
            "x-forwarded-groups",
            "users".parse().expect("valid groups header"),
        );

        assert_eq!(
            identity_from_headers(&headers)
                .expect_err("missing group should be rejected")
                .0,
            StatusCode::FORBIDDEN
        );
    }

    #[test]
    fn gmail_defaults_render_expected_sync_config() {
        let account = AccountRecord {
            id: 42,
            username: "alice".to_string(),
            provider_kind: "gmail".to_string(),
            display_name: "Personal Gmail".to_string(),
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            imap_username: "alice@gmail.com".to_string(),
            folder_mode: "gmail_default".to_string(),
            folder_patterns_json: serde_json::to_string(&gmail_default_patterns()).expect("json"),
            encrypted_secret: "ignored".to_string(),
            sync_enabled: true,
            created_at: String::new(),
            updated_at: String::new(),
            last_sync_started_at: None,
            last_sync_finished_at: None,
            last_sync_status: None,
            last_sync_error: None,
        };
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        ensure_app_layout(&config).expect("layout");
        let paths = ensure_account_paths(&config, &account).expect("paths");
        let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
        let mbsyncrc =
            write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
        let rendered = fs::read_to_string(mbsyncrc).expect("read mbsyncrc");

        assert!(rendered.contains("Host imap.gmail.com"));
        assert!(rendered.contains("\"[Gmail]/All Mail\""));
        assert!(rendered.contains("Sync Pull New Flags"));
    }

    #[test]
    fn generic_imap_defaults_render_expected_sync_config() {
        let account = AccountRecord {
            id: 7,
            username: "alice".to_string(),
            provider_kind: "generic_imap".to_string(),
            display_name: "Work Mail".to_string(),
            imap_host: "imap.example.com".to_string(),
            imap_port: 993,
            imap_username: "alice@example.com".to_string(),
            folder_mode: "generic_default".to_string(),
            folder_patterns_json: serde_json::to_string(&generic_default_patterns()).expect("json"),
            encrypted_secret: "ignored".to_string(),
            sync_enabled: true,
            created_at: String::new(),
            updated_at: String::new(),
            last_sync_started_at: None,
            last_sync_finished_at: None,
            last_sync_status: None,
            last_sync_error: None,
        };
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        ensure_app_layout(&config).expect("layout");
        let paths = ensure_account_paths(&config, &account).expect("paths");
        let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
        let mbsyncrc =
            write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
        let rendered = fs::read_to_string(mbsyncrc).expect("read mbsyncrc");

        assert!(rendered.contains("Host imap.example.com"));
        assert!(rendered.contains("\"Archive\""));
    }

    #[test]
    fn encrypted_secret_round_trip_restores_plaintext() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        ensure_app_layout(&config).expect("layout");

        let key = load_or_create_master_key(&config).expect("master key");
        let encrypted = encrypt_secret(&key, "super-secret-value").expect("encrypt");
        let decrypted = decrypt_secret(&key, &encrypted).expect("decrypt");

        assert_eq!(decrypted, "super-secret-value");
    }

    #[test]
    fn notmuch_summary_json_is_parsed_into_search_results() {
        let parsed: Vec<RawNotmuchSummary> = serde_json::from_str(
            r#"[{"timestamp":1713412350,"date_relative":"2d","authors":"Alice Example","subject":"Invoice ready","tags":["inbox","unread"]}]"#,
        )
        .expect("json should parse");

        assert_eq!(parsed[0].authors.as_deref(), Some("Alice Example"));
        assert_eq!(parsed[0].subject.as_deref(), Some("Invoice ready"));
        assert_eq!(parsed[0].tags.as_ref().expect("tags").len(), 2);
    }

    #[test]
    fn per_account_lock_prevents_overlap() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        ensure_app_layout(&config).expect("layout");

        let first_lock = acquire_account_lock(&config, 9).expect("first lock");
        let second = acquire_account_lock(&config, 9).expect_err("second lock must fail");
        drop(first_lock);

        assert!(second.contains("already running"));
    }

    #[test]
    fn html_page_references_stylesheet() {
        let identity = Identity {
            username: "alice".to_string(),
            email: Some("alice@example.com".to_string()),
            groups: vec!["mail-archive-users".to_string()],
        };

        let html = layout("Mail Archive", &identity, "<section>Body</section>");
        assert!(html.contains("/static/custom.css"));
        assert!(html.contains("alice@example.com"));
    }
}
