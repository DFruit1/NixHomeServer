use axum::{
    extract::{Form, Path, Query, State},
    http::{
        header::{CONTENT_TYPE, HOST},
        HeaderMap, HeaderValue, StatusCode, Uri,
    },
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Key, Nonce,
};
use chrono::{DateTime, Utc};
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    cmp::Reverse,
    env,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::ErrorKind,
    net::SocketAddr,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path as FsPath, PathBuf},
    process::Output,
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

#[derive(Clone, Debug, Default)]
struct SearchPreferenceRecord {
    last_query: Option<String>,
    default_account_id: Option<i64>,
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
struct TempConfigFile {
    path: PathBuf,
}

impl Drop for TempConfigFile {
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

#[derive(Debug, Serialize)]
struct HealthChecks {
    database: String,
    store_root: String,
    runtime_dir: String,
    lock_dir: String,
    mbsync: String,
    notmuch: String,
}

#[derive(Debug, Serialize)]
struct HealthPayload {
    status: String,
    checks: HealthChecks,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum IndexState {
    NotConfigured,
    ConfiguredNoDatabase,
    Indexed,
}

#[derive(Clone, Copy, Debug)]
enum AccountAction {
    Sync,
    Reindex,
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
    secret: Option<String>,
    sync_enabled: bool,
}

#[derive(Debug)]
struct SearchViewState {
    submitted: bool,
    result_count: usize,
    empty_message: Option<String>,
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
        .route("/accounts/{id}/edit", get(edit_account))
        .route("/accounts/{id}/update", post(update_account))
        .route("/accounts/{id}/toggle-sync", post(toggle_sync))
        .route("/accounts/{id}/sync", post(sync_account))
        .route("/accounts/{id}/reindex", post(reindex_account))
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
            Ok(accounts) => {
                let mut account_views = Vec::new();
                for account in accounts {
                    let account_paths = ensure_account_paths(&state.config, &account);
                    let index_state = match account_paths {
                        Ok(paths) => account_index_state(&paths),
                        Err(_) => IndexState::NotConfigured,
                    };
                    account_views.push((account, index_state));
                }

                html_response(render_dashboard(
                    &identity,
                    &account_views,
                    params.flash.as_deref(),
                    params.error.as_deref(),
                ))
            }
            Err(error) => server_error_page("Failed to load accounts", &error, Some(&identity)),
        },
        Err((status, message)) => auth_error(status, &message),
    }
}

async fn new_account(headers: HeaderMap) -> Response {
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

            html_response(render_account_form(
                &identity,
                "Add Mailbox",
                "Connect a mailbox with an app password or IMAP password.",
                "The UI stores the credential encrypted at rest, generates the sync config on demand, and keeps downloaded mail in your private archive only.",
                "/accounts",
                "Save mailbox",
                true,
                &empty,
                None,
                None,
            ))
        }
        Err((status, message)) => auth_error(status, &message),
    }
}

async fn edit_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    match load_account_for_user(&state.config, &identity.username, account_id) {
        Ok(account) => {
            let form = account_form_from_account(&account);
            html_response(render_account_form(
                &identity,
                "Edit Mailbox",
                "Adjust connection details, folder patterns, and scheduling.",
                "Leave the password field empty to keep the current stored mailbox secret.",
                &format!("/accounts/{}/update", account.id),
                "Save changes",
                false,
                &form,
                Some("Leave blank to keep the current stored password."),
                None,
            ))
        }
        Err(error) => server_error_page("Failed to load mailbox", &error, Some(&identity)),
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

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    match validate_account_form(&form, true) {
        Ok(validated) => match insert_account(&state.config, &identity.username, validated) {
            Ok(_) => redirect_response("/?flash=Mailbox+saved"),
            Err(error) => server_error_page("Failed to save mailbox", &error, Some(&identity)),
        },
        Err(error) => html_response(render_account_form(
            &identity,
            "Add Mailbox",
            "Connect a mailbox with an app password or IMAP password.",
            "The UI stores the credential encrypted at rest, generates the sync config on demand, and keeps downloaded mail in your private archive only.",
            "/accounts",
            "Save mailbox",
            true,
            &form,
            None,
            Some(&error),
        )),
    }
}

async fn update_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
    Form(form): Form<CreateAccountForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    match validate_account_form(&form, false) {
        Ok(validated) => {
            match update_account_for_user(&state.config, &identity.username, account_id, validated)
            {
                Ok(_) => redirect_response("/?flash=Mailbox+updated"),
                Err(error) => {
                    server_error_page("Failed to update mailbox", &error, Some(&identity))
                }
            }
        }
        Err(error) => html_response(render_account_form(
            &identity,
            "Edit Mailbox",
            "Adjust connection details, folder patterns, and scheduling.",
            "Leave the password field empty to keep the current stored mailbox secret.",
            &format!("/accounts/{account_id}/update"),
            "Save changes",
            false,
            &form,
            Some("Leave blank to keep the current stored password."),
            Some(&error),
        )),
    }
}

async fn toggle_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    match toggle_sync_for_user(&state.config, &identity.username, account_id) {
        Ok(true) => redirect_response("/?flash=Scheduled+sync+enabled"),
        Ok(false) => redirect_response("/?flash=Scheduled+sync+disabled"),
        Err(error) => server_error_page("Failed to toggle sync", &error, Some(&identity)),
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

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();

    let sync_result = tokio::task::spawn_blocking(move || {
        run_account_action_for_user(&config, &username, account_id, AccountAction::Sync)
    })
    .await;

    let redirect_target = match sync_result {
        Ok(Ok(())) => "/?flash=Mailbox+sync+completed".to_string(),
        Ok(Err(error)) => format!("/?error={}", url_encode_component(&error)),
        Err(_) => "/?error=Mailbox+sync+task+failed".to_string(),
    };

    redirect_response(&redirect_target)
}

async fn reindex_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();

    let reindex_result = tokio::task::spawn_blocking(move || {
        run_account_action_for_user(&config, &username, account_id, AccountAction::Reindex)
    })
    .await;

    let redirect_target = match reindex_result {
        Ok(Ok(())) => "/?flash=Mailbox+reindex+completed".to_string(),
        Ok(Err(error)) => format!("/?error={}", url_encode_component(&error)),
        Err(_) => "/?error=Mailbox+reindex+task+failed".to_string(),
    };

    redirect_response(&redirect_target)
}

async fn search_page(
    State(state): State<AppState>,
    headers: HeaderMap,
    uri: Uri,
    Query(params): Query<SearchParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let accounts = match list_accounts_for_user(&state.config, &identity.username) {
        Ok(accounts) => accounts,
        Err(error) => {
            return server_error_page("Failed to load mailboxes", &error, Some(&identity))
        }
    };

    let has_params = uri.query().is_some();
    let has_explicit_query = uri.query().is_some_and(has_explicit_query_param);
    let preferences = if has_params {
        SearchPreferenceRecord::default()
    } else {
        match load_search_preferences(&state.config, &identity.username) {
            Ok(preferences) => preferences,
            Err(error) => {
                return server_error_page(
                    "Failed to load saved search preferences",
                    &error,
                    Some(&identity),
                )
            }
        }
    };

    let query_text = if has_params {
        params.q.unwrap_or_default()
    } else {
        preferences.last_query.unwrap_or_default()
    };
    let mut selected_account_id = if has_params {
        params.account_id
    } else {
        preferences.default_account_id
    };
    selected_account_id = normalize_selected_account_id(&accounts, selected_account_id);

    if has_explicit_query {
        if let Err(error) = save_search_preferences(
            &state.config,
            &identity.username,
            query_text.trim(),
            selected_account_id,
        ) {
            return server_error_page("Failed to save search preferences", &error, Some(&identity));
        }
    }

    let should_execute_search = has_explicit_query && !query_text.trim().is_empty();
    let results = if should_execute_search {
        let config = state.config.clone();
        let username = identity.username.clone();
        let query_clone = query_text.clone();
        match tokio::task::spawn_blocking(move || {
            search_mail(&config, &username, selected_account_id, &query_clone)
        })
        .await
        {
            Ok(Ok(results)) => results,
            Ok(Err(error)) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &query_text,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some(error),
                    },
                ))
            }
            Err(_) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &query_text,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some("Search task failed".to_string()),
                    },
                ))
            }
        }
    } else {
        Vec::new()
    };

    let selected_accounts = accounts
        .iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
        .collect::<Vec<_>>();
    let indexed_selected_accounts = selected_accounts
        .iter()
        .filter(|account| {
            ensure_account_paths(&state.config, account)
                .map(|paths| account_index_state(&paths) == IndexState::Indexed)
                .unwrap_or(false)
        })
        .count();

    let empty_message = if !has_explicit_query {
        Some(
            "Saved search defaults are prefilled below. Submit a query to search indexed mail."
                .to_string(),
        )
    } else if query_text.trim().is_empty() {
        Some("Enter a notmuch query to search your indexed archive.".to_string())
    } else if selected_accounts.is_empty() {
        Some("No mailbox is available for this search filter.".to_string())
    } else if indexed_selected_accounts == 0 {
        Some(
            "The selected mailbox archive has not been indexed yet. Run Sync now or Reindex first."
                .to_string(),
        )
    } else if results.is_empty() {
        Some("No indexed messages matched this query.".to_string())
    } else {
        None
    };

    let view_state = SearchViewState {
        submitted: has_explicit_query,
        result_count: results.len(),
        empty_message,
    };

    html_response(render_search(
        &identity,
        &accounts,
        &query_text,
        selected_account_id,
        &results,
        &view_state,
    ))
}

async fn healthz(State(state): State<AppState>) -> Response {
    let (status, payload) = health_payload(&state.config);
    json_response(status, payload)
}

async fn custom_css() -> Response {
    let response = (
        [(CONTENT_TYPE, "text/css; charset=utf-8")],
        CUSTOM_CSS.to_string(),
    )
        .into_response();
    harden_response(response)
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

fn verify_same_origin_request(headers: &HeaderMap) -> Result<(), (StatusCode, String)> {
    let expected_origin = expected_request_origin(headers).ok_or_else(|| {
        (
            StatusCode::FORBIDDEN,
            "Unable to determine the expected request origin".to_string(),
        )
    })?;

    if let Some(origin) = header_value(headers, "origin") {
        if same_origin_value(&origin, &expected_origin) {
            return Ok(());
        }

        return Err((
            StatusCode::FORBIDDEN,
            "Cross-origin state-changing requests are not allowed".to_string(),
        ));
    }

    if let Some(referer) = header_value(headers, "referer") {
        if same_origin_value(&referer, &expected_origin) {
            return Ok(());
        }

        return Err((
            StatusCode::FORBIDDEN,
            "Cross-origin state-changing requests are not allowed".to_string(),
        ));
    }

    Err((
        StatusCode::FORBIDDEN,
        "Origin or Referer is required for state-changing requests".to_string(),
    ))
}

fn expected_request_origin(headers: &HeaderMap) -> Option<String> {
    let host = header_value(headers, "x-forwarded-host").or_else(|| {
        headers
            .get(HOST)
            .and_then(|value| value.to_str().ok().map(ToString::to_string))
    })?;
    let proto = header_value(headers, "x-forwarded-proto").unwrap_or_else(|| "http".to_string());
    let host = host
        .split(',')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    Some(format!("{}://{}", proto, host))
}

fn same_origin_value(candidate: &str, expected: &str) -> bool {
    if !candidate.starts_with(expected) {
        return false;
    }

    let remainder = &candidate[expected.len()..];
    remainder.is_empty()
        || remainder.starts_with('/')
        || remainder.starts_with('?')
        || remainder.starts_with('#')
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

fn validate_account_form(
    form: &CreateAccountForm,
    secret_required: bool,
) -> Result<ValidatedAccount, String> {
    let provider_kind = form.provider_kind.trim();
    if provider_kind != "gmail" && provider_kind != "generic_imap" {
        return Err("Unsupported provider preset".to_string());
    }

    let display_name = form.display_name.trim();
    if display_name.is_empty() {
        return Err("Display name is required".to_string());
    }

    let secret = form.secret.trim();
    if secret_required && secret.is_empty() {
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

    let folder_patterns = parse_folder_patterns(provider_kind, &form.folder_patterns);
    if folder_patterns.is_empty() {
        return Err("At least one folder pattern is required".to_string());
    }

    let folder_mode = if provider_kind == "gmail" && folder_patterns == gmail_default_patterns() {
        "gmail_default"
    } else if provider_kind == "generic_imap" && folder_patterns == generic_default_patterns() {
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
        folder_patterns,
        secret: (!secret.is_empty()).then(|| secret.to_string()),
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

fn account_form_from_account(account: &AccountRecord) -> CreateAccountForm {
    let folder_patterns = decode_folder_patterns(account)
        .unwrap_or_else(|_| generic_default_patterns())
        .join("\n");

    CreateAccountForm {
        provider_kind: account.provider_kind.clone(),
        display_name: account.display_name.clone(),
        imap_host: account.imap_host.clone(),
        imap_port: account.imap_port.to_string(),
        imap_username: account.imap_username.clone(),
        secret: String::new(),
        folder_patterns,
        sync_enabled: account.sync_enabled.then(|| "on".to_string()),
    }
}

fn insert_account(
    config: &AppConfig,
    username: &str,
    account: ValidatedAccount,
) -> Result<(), String> {
    let encryption_key = load_or_create_master_key(config)?;
    let encrypted_secret = encrypt_secret(
        &encryption_key,
        account
            .secret
            .as_deref()
            .ok_or_else(|| "Mailbox password or app password is required".to_string())?,
    )?;
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

fn update_account_for_user(
    config: &AppConfig,
    username: &str,
    account_id: i64,
    account: ValidatedAccount,
) -> Result<(), String> {
    let existing = load_account_for_user(config, username, account_id)?;
    let encryption_key = load_or_create_master_key(config)?;
    let encrypted_secret = if let Some(secret) = account.secret.as_deref() {
        encrypt_secret(&encryption_key, secret)?
    } else {
        existing.encrypted_secret
    };
    let now = Utc::now().to_rfc3339();
    let patterns_json = serde_json::to_string(&account.folder_patterns)
        .map_err(|error| format!("patterns json failed: {error}"))?;

    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            UPDATE accounts
            SET
                provider_kind = ?1,
                display_name = ?2,
                imap_host = ?3,
                imap_port = ?4,
                imap_username = ?5,
                folder_mode = ?6,
                folder_patterns_json = ?7,
                encrypted_secret = ?8,
                sync_enabled = ?9,
                updated_at = ?10
            WHERE username = ?11 AND id = ?12
            "#,
            params![
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
                username,
                account_id,
            ],
        )
        .map_err(|error| format!("failed to update account: {error}"))?;

    Ok(())
}

fn toggle_sync_for_user(
    config: &AppConfig,
    username: &str,
    account_id: i64,
) -> Result<bool, String> {
    let account = load_account_for_user(config, username, account_id)?;
    let new_sync_enabled = !account.sync_enabled;
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            UPDATE accounts
            SET sync_enabled = ?1, updated_at = ?2
            WHERE username = ?3 AND id = ?4
            "#,
            params![
                if new_sync_enabled { 1 } else { 0 },
                Utc::now().to_rfc3339(),
                username,
                account_id
            ],
        )
        .map_err(|error| format!("failed to update sync flag: {error}"))?;

    Ok(new_sync_enabled)
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

fn load_search_preferences(
    config: &AppConfig,
    username: &str,
) -> Result<SearchPreferenceRecord, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            r#"
            SELECT last_query, default_account_id
            FROM search_preferences
            WHERE username = ?1
            "#,
            params![username],
            |row| {
                Ok(SearchPreferenceRecord {
                    last_query: row.get(0)?,
                    default_account_id: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("failed to load search preferences: {error}"))?
        .map_or(Ok(SearchPreferenceRecord::default()), Ok)
}

fn save_search_preferences(
    config: &AppConfig,
    username: &str,
    last_query: &str,
    default_account_id: Option<i64>,
) -> Result<(), String> {
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO search_preferences (username, last_query, default_account_id)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(username) DO UPDATE
            SET
                last_query = excluded.last_query,
                default_account_id = excluded.default_account_id
            "#,
            params![username, last_query, default_account_id],
        )
        .map_err(|error| format!("failed to save search preferences: {error}"))?;

    Ok(())
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

    write_private_file(&key_path, encoded.as_bytes())?;
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
        if let Err(error) = run_account_action(config, &account, AccountAction::Sync) {
            eprintln!(
                "mail-archive-ui sync failed for {}:{}: {error}",
                account.username, account.id
            );
            had_errors = true;
        }
    }

    Ok(had_errors)
}

fn run_account_action_for_user(
    config: &AppConfig,
    username: &str,
    account_id: i64,
    action: AccountAction,
) -> Result<(), String> {
    let account = load_account_for_user(config, username, account_id)?;
    run_account_action(config, &account, action)
}

fn run_account_action(
    config: &AppConfig,
    account: &AccountRecord,
    action: AccountAction,
) -> Result<(), String> {
    let _lock = acquire_account_lock(config, account.id)?;
    update_sync_started(config, account.id)?;

    let result: Result<(), String> = match action {
        AccountAction::Sync => {
            let encryption_key = load_or_create_master_key(config)?;
            let secret = decrypt_secret(&encryption_key, &account.encrypted_secret)?;
            let account_paths = ensure_account_paths(config, account)?;
            ensure_notmuch_config(config, account, &account_paths)?;
            let temp_secret = write_temp_secret(config, account.id, &secret)?;
            let temp_config =
                write_temp_mbsyncrc(config, account, &account_paths, &temp_secret.path)?;

            run_command(
                "mbsync",
                &["-c", temp_config.path.to_string_lossy().as_ref(), "--all"],
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
            )
        }
        AccountAction::Reindex => {
            let account_paths = ensure_account_paths(config, account)?;
            ensure_notmuch_config(config, account, &account_paths)?;
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
            )
        }
    };

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

fn account_notmuch_db_exists(account_paths: &AccountPaths) -> bool {
    account_paths.maildir.join(".notmuch").exists()
}

fn account_index_state(account_paths: &AccountPaths) -> IndexState {
    if account_notmuch_db_exists(account_paths) {
        IndexState::Indexed
    } else if account_paths.notmuch_config.exists() {
        IndexState::ConfiguredNoDatabase
    } else {
        IndexState::NotConfigured
    }
}

fn ensure_notmuch_config(
    config: &AppConfig,
    account: &AccountRecord,
    account_paths: &AccountPaths,
) -> Result<(), String> {
    let tags = config.default_tags.join(";");
    let contents = format!(
        "[database]\npath={}\n\n[user]\nname={}\nprimary_email={}\n\n[new]\ntags={}\nignore=\n\n[search]\nexclude_tags=\n\n[maildir]\nsynchronize_flags=true\n",
        account_paths.maildir.display(),
        account.username,
        account.imap_username,
        tags
    );

    if fs::read_to_string(&account_paths.notmuch_config)
        .ok()
        .as_deref()
        == Some(contents.as_str())
    {
        return Ok(());
    }

    write_private_file(&account_paths.notmuch_config, contents.as_bytes())
}

fn write_temp_secret(
    config: &AppConfig,
    account_id: i64,
    secret: &str,
) -> Result<TempSecretFile, String> {
    let name = format!("account-{account_id}-secret-{}.tmp", random_hex(8));
    let path = PathBuf::from(config.runtime_dir.as_ref()).join(name);
    write_private_file(&path, secret.as_bytes())?;
    Ok(TempSecretFile { path })
}

fn write_temp_mbsyncrc(
    config: &AppConfig,
    account: &AccountRecord,
    account_paths: &AccountPaths,
    secret_path: &FsPath,
) -> Result<TempConfigFile, String> {
    let patterns = decode_folder_patterns(account)?;
    let path = PathBuf::from(config.runtime_dir.as_ref()).join(format!(
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

    write_private_file(&path, rendered.as_bytes())?;
    Ok(TempConfigFile { path })
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

fn execute_command(command: &str, args: &[&str], envs: &[(&str, &str)]) -> Result<Output, String> {
    let mut process = std::process::Command::new(command);
    process.args(args);
    process.env_clear();
    process.env("PATH", env::var("PATH").unwrap_or_default());
    process.env("LANG", "C.UTF-8");

    for (name, value) in envs {
        process.env(name, value);
    }

    process
        .output()
        .map_err(|error| format!("failed to run {command}: {error}"))
}

fn run_command(command: &str, args: &[&str], envs: &[(&str, &str)]) -> Result<(), String> {
    let output = execute_command(command, args, envs)?;

    if output.status.success() {
        return Ok(());
    }

    Err(command_failure_detail(command, &output))
}

fn command_failure_detail(command: &str, output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with {}", output.status)
    }
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
        if account_index_state(&account_paths) != IndexState::Indexed {
            continue;
        }

        let output = execute_command(
            "notmuch",
            &["search", "--format=json", "--output=summary", query],
            &[
                ("HOME", account_paths.state_dir.to_string_lossy().as_ref()),
                (
                    "NOTMUCH_CONFIG",
                    account_paths.notmuch_config.to_string_lossy().as_ref(),
                ),
            ],
        )?;

        if !output.status.success() {
            let detail = command_failure_detail("notmuch", &output);
            if detail.contains("No database found") || detail.contains("not initialized") {
                continue;
            }
            return Err(detail);
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
    accounts: &[(AccountRecord, IndexState)],
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
          <h1>Mailbox sync, repair, and metadata search without turning this into webmail.</h1>
          <p class=\"lede\">Each mailbox stays scoped to your authenticated Kanidm identity. Sync runs through <code>mbsync</code>, indexing runs through <code>notmuch</code>, and downloaded mail stays in your isolated server-side archive.</p>
          <div class=\"nav\">
            <a href=\"/accounts/new\">Add mailbox</a>
            <a class=\"secondary\" href=\"/search\">Search mail</a>
          </div>
        </section>",
    );

    body.push_str("<section class=\"panel stack\"><div class=\"section-head\"><h2>Connected mailboxes</h2><p class=\"meta\">Edit connection details, trigger syncs, or repair indexes without exposing the archive as webmail.</p></div>");
    if accounts.is_empty() {
        body.push_str(
            "<div class=\"empty-state\"><p class=\"meta\">No mailbox is configured yet. Start with Gmail or a generic IMAP account.</p><a class=\"button-link\" href=\"/accounts/new\">Add mailbox</a></div>",
        );
    } else {
        body.push_str("<div class=\"card-grid\">");
        for (account, index_state) in accounts {
            body.push_str(&render_account_card(account, *index_state));
        }
        body.push_str("</div>");
    }
    body.push_str("</section>");

    layout("Mail Archive", Some(identity), "dashboard", &body)
}

fn render_account_card(account: &AccountRecord, index_state: IndexState) -> String {
    let (status_class, status_label) = account_status(account, index_state);
    let schedule_label = if account.sync_enabled {
        "Scheduled"
    } else {
        "Manual only"
    };
    let last_activity = account
        .last_sync_finished_at
        .as_deref()
        .or(account.last_sync_started_at.as_deref())
        .map(escape_html)
        .unwrap_or_else(|| "Never".to_string());
    let mut body = String::new();

    writeln!(
        &mut body,
        "<article class=\"account-card stack\">
          <div class=\"card-header\">
            <div>
              <p class=\"eyebrow\">{}</p>
              <h2>{}</h2>
              <p class=\"meta\">{} · {}:{}</p>
            </div>
            <span class=\"status {}\">{}</span>
          </div>
          <div class=\"card-meta\">
            <span class=\"pill\">{}</span>
            <span class=\"pill\">{}</span>
          </div>
          <div class=\"hint\">Mailbox user: {}</div>
          <div class=\"hint\">Added {} · Updated {}</div>
          <div class=\"hint\">Last activity {}</div>
          <div class=\"action-row\">
            <form method=\"post\" action=\"/accounts/{}/sync\"><button type=\"submit\">Sync now</button></form>
            <form method=\"post\" action=\"/accounts/{}/reindex\"><button class=\"secondary\" type=\"submit\">Reindex</button></form>
            <a class=\"button-link secondary\" href=\"/accounts/{}/edit\">Edit</a>
            <form method=\"post\" action=\"/accounts/{}/toggle-sync\"><button class=\"secondary\" type=\"submit\">{}</button></form>
          </div>",
        escape_html(&account.provider_kind),
        escape_html(&account.display_name),
        escape_html(&account.imap_host),
        account.imap_port,
        account.id,
        status_class,
        escape_html(status_label),
        escape_html(schedule_label),
        escape_html(match index_state {
            IndexState::Indexed => "Indexed",
            IndexState::ConfiguredNoDatabase | IndexState::NotConfigured => "Unindexed",
        }),
        escape_html(&account.imap_username),
        escape_html(&account.created_at),
        escape_html(&account.updated_at),
        last_activity,
        account.id,
        account.id,
        account.id,
        account.id,
        if account.sync_enabled {
            "Disable schedule"
        } else {
            "Enable schedule"
        },
    )
    .ok();

    if let Some(error) = account.last_sync_error.as_deref() {
        writeln!(
            &mut body,
            "<div class=\"error compact\">{}</div>",
            escape_html(error)
        )
        .ok();
    }

    body.push_str("</article>");
    body
}

fn account_status(
    account: &AccountRecord,
    index_state: IndexState,
) -> (&'static str, &'static str) {
    match account.last_sync_status.as_deref() {
        Some("running") => ("pending", "running"),
        Some("error") => ("error", "error"),
        Some("ok") if index_state == IndexState::Indexed => ("ok", "ok"),
        _ if index_state != IndexState::Indexed => ("unindexed", "unindexed"),
        _ => ("idle", "idle"),
    }
}

fn render_account_form(
    identity: &Identity,
    page_title: &str,
    heading: &str,
    lede: &str,
    action_url: &str,
    submit_label: &str,
    secret_required: bool,
    form: &CreateAccountForm,
    secret_help: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&format!(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Mailbox Setup</p>
          <h1>{}</h1>
          <p class=\"lede\">{}</p>
        </section>",
        escape_html(heading),
        escape_html(lede),
    ));

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
        "<form method=\"post\" action=\"{}\" class=\"fields\">
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
              <input type=\"password\" name=\"secret\" value=\"\" autocomplete=\"new-password\" {}>
            </label>
          </div>
          {}
          <label>Folders to archive
            <textarea name=\"folder_patterns\" placeholder=\"One IMAP pattern per line\">{}</textarea>
          </label>
          <label><input type=\"checkbox\" name=\"sync_enabled\" {}> Enable scheduled background sync</label>
          <div class=\"actions\">
            <button type=\"submit\">{}</button>
            <a class=\"button-link secondary\" href=\"/\">Cancel</a>
          </div>
          <ul class=\"muted-list\">
            <li>Gmail defaults to append-only archive folders.</li>
            <li>Generic IMAP keeps TLS on port 993 by default.</li>
            <li>This remains archive and search infrastructure, not a browser mail client.</li>
          </ul>
        </form>",
        escape_html(action_url),
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
        if secret_required { "required" } else { "" },
        secret_help
            .map(|text| format!("<p class=\"hint\">{}</p>", escape_html(text)))
            .unwrap_or_default(),
        escape_html(&form.folder_patterns),
        if form.sync_enabled.is_some() { "checked" } else { "" },
        escape_html(submit_label),
    )
    .ok();
    body.push_str("</section>");

    layout(page_title, Some(identity), "accounts", &body)
}

fn render_search(
    identity: &Identity,
    accounts: &[AccountRecord],
    query: &str,
    selected_account_id: Option<i64>,
    results: &[SearchResult],
    state: &SearchViewState,
) -> String {
    let mut body = String::new();

    body.push_str(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Search Archive</p>
          <h1>Query your downloaded mail with notmuch.</h1>
          <p class=\"lede\">Search runs only across your own archive. Results show metadata only, not message bodies.</p>
        </section>",
    );

    body.push_str("<section class=\"panel stack\">");
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

    if state.submitted {
        writeln!(
            &mut body,
            "<section class=\"panel result-summary\"><strong>{}</strong><span class=\"meta\"> matching messages across indexed mailboxes</span></section>",
            pluralize_results(state.result_count),
        )
        .ok();
    }

    if let Some(message) = state.empty_message.as_deref() {
        writeln!(
            &mut body,
            "<section class=\"panel empty-state\"><p class=\"meta\">{}</p></section>",
            escape_html(message)
        )
        .ok();
    }

    if !results.is_empty() {
        writeln!(
            &mut body,
            "<section class=\"grid\">{}</section>",
            results
                .iter()
                .map(render_search_result)
                .collect::<Vec<_>>()
                .join("")
        )
        .ok();
    }

    layout("Search Mail", Some(identity), "search", &body)
}

fn pluralize_results(count: usize) -> String {
    if count == 1 {
        "1 result".to_string()
    } else {
        format!("{count} results")
    }
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
          <div class=\"result-head\">
            <span class=\"badge\">{}</span>
            <p class=\"meta\">{}</p>
          </div>
          <div>
            <h2>{}</h2>
            <p class=\"meta\">{} · {}</p>
          </div>
          <div class=\"tag-list\">{}</div>
        </article>",
        escape_html(&result.account_name),
        escape_html(&result.date_label),
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

fn layout(title: &str, identity: Option<&Identity>, active_nav: &str, body: &str) -> String {
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
      <header class="topbar">
        <div>
          <p class="eyebrow">Mail Archive</p>
          <strong>Private archive control plane</strong>
          <div class="meta">{}</div>
        </div>
        <nav class="topnav">
          <a class="{}" href="/">Dashboard</a>
          <a class="{}" href="/accounts/new">Add mailbox</a>
          <a class="{}" href="/search">Search</a>
        </nav>
      </header>
      {}
    </main>
  </body>
</html>"#,
        escape_html(title),
        escape_html(&identity_summary(identity)),
        nav_active_class(active_nav == "dashboard"),
        nav_active_class(active_nav == "accounts"),
        nav_active_class(active_nav == "search"),
        body
    )
}

fn identity_summary(identity: Option<&Identity>) -> String {
    identity
        .map(|identity| {
            format!(
                "{} · {} · groups: {}",
                identity.username,
                identity.email.as_deref().unwrap_or("no forwarded email"),
                identity.groups.join(", ")
            )
        })
        .unwrap_or_else(|| "Authentication required".to_string())
}

fn nav_active_class(active: bool) -> &'static str {
    if active {
        "active"
    } else {
        ""
    }
}

fn auth_error(status: StatusCode, message: &str) -> Response {
    let html = layout(
        "Access denied",
        None,
        "",
        &format!(
            "<section class=\"panel stack\"><p class=\"eyebrow\">Access denied</p><h1>Request blocked</h1><div class=\"error\">{}</div></section>",
            escape_html(message)
        ),
    );
    html_response_with_status(status, html)
}

fn server_error_page(title: &str, message: &str, identity: Option<&Identity>) -> Response {
    let html = layout(
        title,
        identity,
        "",
        &format!(
            "<section class=\"panel stack\"><p class=\"eyebrow\">Service error</p><h1>{}</h1><div class=\"error\">{}</div></section>",
            escape_html(title),
            escape_html(message)
        ),
    );
    html_response_with_status(StatusCode::INTERNAL_SERVER_ERROR, html)
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
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.format("%Y-%m-%d %H:%M UTC").to_string())
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

fn normalize_selected_account_id(
    accounts: &[AccountRecord],
    selected_account_id: Option<i64>,
) -> Option<i64> {
    selected_account_id.filter(|selected| accounts.iter().any(|account| account.id == *selected))
}

fn has_explicit_query_param(raw_query: &str) -> bool {
    raw_query
        .split('&')
        .any(|part| part == "q" || part.starts_with("q="))
}

fn html_response(html: String) -> Response {
    harden_response(Html(html).into_response())
}

fn html_response_with_status(status: StatusCode, html: String) -> Response {
    harden_response((status, Html(html)).into_response())
}

fn json_response<T: Serialize>(status: StatusCode, payload: T) -> Response {
    harden_response((status, Json(payload)).into_response())
}

fn redirect_response(location: &str) -> Response {
    harden_response(Redirect::to(location).into_response())
}

fn harden_response(mut response: Response) -> Response {
    let headers = response.headers_mut();
    headers.insert("X-Frame-Options", HeaderValue::from_static("DENY"));
    headers.insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("Referrer-Policy", HeaderValue::from_static("same-origin"));
    headers.insert(
        "Content-Security-Policy",
        HeaderValue::from_static(
            "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'",
        ),
    );
    response
}

fn health_payload(config: &AppConfig) -> (StatusCode, HealthPayload) {
    let checks = HealthChecks {
        database: match open_db(config) {
            Ok(_) => "ok".to_string(),
            Err(error) => error,
        },
        store_root: match fs::metadata(config.store_root.as_ref()) {
            Ok(metadata) if metadata.is_dir() => "ok".to_string(),
            Ok(_) => "mail archive store root is not a directory".to_string(),
            Err(error) => format!("mail archive store root is unavailable: {error}"),
        },
        runtime_dir: writable_directory_status(config.runtime_dir.as_ref()),
        lock_dir: writable_directory_status(config.lock_dir.as_ref()),
        mbsync: command_status("mbsync"),
        notmuch: command_status("notmuch"),
    };

    let ok = [
        &checks.database,
        &checks.store_root,
        &checks.runtime_dir,
        &checks.lock_dir,
        &checks.mbsync,
        &checks.notmuch,
    ]
    .iter()
    .all(|value| value.as_str() == "ok");

    let payload = HealthPayload {
        status: if ok { "ok" } else { "degraded" }.to_string(),
        checks,
    };

    (
        if ok {
            StatusCode::OK
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        payload,
    )
}

fn writable_directory_status(path: &str) -> String {
    let path = PathBuf::from(path);
    match fs::metadata(&path) {
        Ok(metadata) if metadata.is_dir() => {
            let probe_path = path.join(format!(".write-check-{}", random_hex(6)));
            match OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&probe_path)
            {
                Ok(_) => {
                    let _ = fs::remove_file(probe_path);
                    "ok".to_string()
                }
                Err(error) => format!("directory is not writable: {error}"),
            }
        }
        Ok(_) => "path is not a directory".to_string(),
        Err(error) => format!("directory is unavailable: {error}"),
    }
}

fn command_status(command: &str) -> String {
    if command_exists_in_path(command) {
        "ok".to_string()
    } else {
        format!("{command} is not available in PATH")
    }
}

fn command_exists_in_path(command: &str) -> bool {
    find_command_path(command).is_some()
}

fn find_command_path(command: &str) -> Option<PathBuf> {
    env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| env::split_paths(&paths).collect::<Vec<_>>())
        .map(|directory| directory.join(command))
        .find(|candidate| {
            fs::metadata(candidate)
                .map(|metadata| metadata.is_file() && (metadata.mode() & 0o111 != 0))
                .unwrap_or(false)
        })
}

fn write_private_file(path: &FsPath, contents: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    std::io::Write::write_all(&mut file, contents)
        .map_err(|error| format!("failed to write {}: {error}", path.display()))
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};
    use tempfile::TempDir;

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn env_lock() -> &'static Mutex<()> {
        ENV_LOCK.get_or_init(|| Mutex::new(()))
    }

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

    fn prepare_test_layout(config: &AppConfig) {
        ensure_app_layout(config).expect("layout");
        fs::create_dir_all(config.store_root.as_ref()).expect("store root");
        initialize_db(config).expect("db");
    }

    fn example_account() -> AccountRecord {
        AccountRecord {
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
        }
    }

    fn with_stubbed_path<F>(commands: &[(&str, &str)], test: F)
    where
        F: FnOnce(PathBuf),
    {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tempdir = TempDir::new().expect("tempdir");
        let bin_dir = tempdir.path().join("bin");
        fs::create_dir_all(&bin_dir).expect("bin dir");
        let bash_path = find_command_path("bash")
            .or_else(|| env::var_os("SHELL").map(PathBuf::from))
            .expect("bash path");

        for (name, script_body) in commands {
            let path = bin_dir.join(name);
            let script = format!("#!{}\nset -eu\n{}", bash_path.display(), script_body);
            write_private_file(&path, script.as_bytes()).expect("write stub");
            let mut perms = fs::metadata(&path).expect("metadata").permissions();
            use std::os::unix::fs::PermissionsExt;
            perms.set_mode(0o755);
            fs::set_permissions(&path, perms).expect("chmod");
        }

        let original_path = env::var("PATH").unwrap_or_default();
        env::set_var("PATH", format!("{}:{}", bin_dir.display(), original_path));
        test(bin_dir);
        env::set_var("PATH", original_path);
    }

    fn seed_account(config: &AppConfig, username: &str, secret: &str) -> i64 {
        insert_account(
            config,
            username,
            ValidatedAccount {
                provider_kind: "gmail".to_string(),
                display_name: "Personal Gmail".to_string(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: 993,
                imap_username: "alice@gmail.com".to_string(),
                folder_mode: "gmail_default".to_string(),
                folder_patterns: gmail_default_patterns(),
                secret: Some(secret.to_string()),
                sync_enabled: true,
            },
        )
        .expect("insert account");

        let connection = open_db(config).expect("db");
        connection
            .query_row("SELECT id FROM accounts LIMIT 1", [], |row| row.get(0))
            .expect("account id")
    }

    fn read_account(config: &AppConfig, username: &str, account_id: i64) -> AccountRecord {
        load_account_for_user(config, username, account_id).expect("load account")
    }

    fn read_notmuch_config(config: &AppConfig, account: &AccountRecord) -> String {
        let paths = ensure_account_paths(config, account).expect("paths");
        ensure_notmuch_config(config, account, &paths).expect("config");
        fs::read_to_string(paths.notmuch_config).expect("notmuch config")
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
    fn state_changing_requests_require_same_origin() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-host",
            "emails.example.com".parse().expect("host"),
        );
        headers.insert("x-forwarded-proto", "https".parse().expect("proto"));
        headers.insert(
            "origin",
            "https://emails.example.com".parse().expect("origin"),
        );

        verify_same_origin_request(&headers).expect("same origin");
    }

    #[test]
    fn state_changing_requests_reject_cross_origin() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-host",
            "emails.example.com".parse().expect("host"),
        );
        headers.insert("x-forwarded-proto", "https".parse().expect("proto"));
        headers.insert(
            "referer",
            "https://evil.example.net/form".parse().expect("referer"),
        );

        assert_eq!(
            verify_same_origin_request(&headers)
                .expect_err("cross origin should fail")
                .0,
            StatusCode::FORBIDDEN
        );
    }

    #[test]
    fn gmail_defaults_render_expected_sync_config() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account = example_account();
        let paths = ensure_account_paths(&config, &account).expect("paths");
        let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
        let mbsyncrc =
            write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
        let rendered = fs::read_to_string(&mbsyncrc.path).expect("read mbsyncrc");

        assert!(rendered.contains("Host imap.gmail.com"));
        assert!(rendered.contains("\"[Gmail]/All Mail\""));
        assert!(rendered.contains("Sync Pull New Flags"));
    }

    #[test]
    fn generic_imap_defaults_render_expected_sync_config() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let mut account = example_account();
        account.id = 7;
        account.provider_kind = "generic_imap".to_string();
        account.display_name = "Work Mail".to_string();
        account.imap_host = "imap.example.com".to_string();
        account.imap_username = "alice@example.com".to_string();
        account.folder_mode = "generic_default".to_string();
        account.folder_patterns_json =
            serde_json::to_string(&generic_default_patterns()).expect("json");

        let paths = ensure_account_paths(&config, &account).expect("paths");
        let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
        let mbsyncrc =
            write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
        let rendered = fs::read_to_string(&mbsyncrc.path).expect("read mbsyncrc");

        assert!(rendered.contains("Host imap.example.com"));
        assert!(rendered.contains("\"Archive\""));
    }

    #[test]
    fn encrypted_secret_round_trip_restores_plaintext() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        let key = load_or_create_master_key(&config).expect("master key");
        let encrypted = encrypt_secret(&key, "super-secret-value").expect("encrypt");
        let decrypted = decrypt_secret(&key, &encrypted).expect("decrypt");

        assert_eq!(decrypted, "super-secret-value");
    }

    #[test]
    fn temp_secret_cleanup_removes_file() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        let secret_path = {
            let secret = write_temp_secret(&config, 9, "sekret").expect("secret");
            assert!(secret.path.exists());
            secret.path.clone()
        };

        assert!(!secret_path.exists());
    }

    #[test]
    fn temp_config_cleanup_removes_file() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account = example_account();
        let paths = ensure_account_paths(&config, &account).expect("paths");
        let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");

        let config_path = {
            let temp_config =
                write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("config");
            assert!(temp_config.path.exists());
            temp_config.path.clone()
        };

        assert!(!config_path.exists());
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
        prepare_test_layout(&config);

        let first_lock = acquire_account_lock(&config, 9).expect("first lock");
        let second = acquire_account_lock(&config, 9).expect_err("second lock must fail");
        drop(first_lock);

        assert!(second.contains("already running"));
    }

    #[test]
    fn html_page_references_stylesheet_and_security_headers() {
        let identity = Identity {
            username: "alice".to_string(),
            email: Some("alice@example.com".to_string()),
            groups: vec!["mail-archive-users".to_string()],
        };

        let html = layout(
            "Mail Archive",
            Some(&identity),
            "dashboard",
            "<section>Body</section>",
        );
        assert!(html.contains("/static/custom.css"));
        assert!(html.contains("alice@example.com"));

        let response = html_response(html);
        assert_eq!(
            response.headers().get("X-Frame-Options").expect("header"),
            "DENY"
        );
    }

    #[test]
    fn styled_error_page_uses_shared_layout() {
        let response = auth_error(StatusCode::FORBIDDEN, "nope");
        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        let html = layout(
            "Access denied",
            None,
            "",
            "<section class=\"panel stack\"><p class=\"eyebrow\">Access denied</p><h1>Request blocked</h1><div class=\"error\">nope</div></section>",
        );
        assert!(html.contains("Private archive control plane"));
        assert!(html.contains("Request blocked"));
    }

    #[test]
    fn update_with_blank_secret_preserves_encrypted_secret() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "old-secret");
        let before = read_account(&config, "alice", account_id);

        update_account_for_user(
            &config,
            "alice",
            account_id,
            ValidatedAccount {
                provider_kind: "gmail".to_string(),
                display_name: "Updated".to_string(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: 993,
                imap_username: "alice@gmail.com".to_string(),
                folder_mode: "gmail_default".to_string(),
                folder_patterns: gmail_default_patterns(),
                secret: None,
                sync_enabled: false,
            },
        )
        .expect("update");

        let after = read_account(&config, "alice", account_id);
        assert_eq!(before.encrypted_secret, after.encrypted_secret);
        assert!(!after.sync_enabled);
    }

    #[test]
    fn update_with_new_secret_rotates_encrypted_secret() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "old-secret");
        let before = read_account(&config, "alice", account_id);

        update_account_for_user(
            &config,
            "alice",
            account_id,
            ValidatedAccount {
                provider_kind: "gmail".to_string(),
                display_name: "Updated".to_string(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: 993,
                imap_username: "alice@gmail.com".to_string(),
                folder_mode: "gmail_default".to_string(),
                folder_patterns: gmail_default_patterns(),
                secret: Some("new-secret".to_string()),
                sync_enabled: true,
            },
        )
        .expect("update");

        let after = read_account(&config, "alice", account_id);
        assert_ne!(before.encrypted_secret, after.encrypted_secret);
    }

    #[test]
    fn toggle_sync_flips_only_sync_flag() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");

        let enabled = toggle_sync_for_user(&config, "alice", account_id).expect("toggle");
        assert!(!enabled);
        let account = read_account(&config, "alice", account_id);
        assert!(!account.sync_enabled);
    }

    #[test]
    fn notmuch_config_is_reconciled_after_account_update() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");
        let account = read_account(&config, "alice", account_id);
        let initial = read_notmuch_config(&config, &account);
        assert!(initial.contains("primary_email=alice@gmail.com"));

        update_account_for_user(
            &config,
            "alice",
            account_id,
            ValidatedAccount {
                provider_kind: "gmail".to_string(),
                display_name: "Updated".to_string(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: 993,
                imap_username: "archive@example.com".to_string(),
                folder_mode: "gmail_default".to_string(),
                folder_patterns: gmail_default_patterns(),
                secret: None,
                sync_enabled: true,
            },
        )
        .expect("update");

        let updated = read_account(&config, "alice", account_id);
        let reconciled = read_notmuch_config(&config, &updated);
        assert!(reconciled.contains("primary_email=archive@example.com"));
    }

    #[test]
    fn reindex_runs_notmuch_without_mbsync() {
        with_stubbed_path(
            &[
                (
                    "notmuch",
                    "mkdir -p \"$HOME/.reindex-log\"\nprintf '%s\n' \"$*\" >> \"$HOME/.reindex-log/commands\"\nmkdir -p \"$(dirname \"$NOTMUCH_CONFIG\")/../maildir/.notmuch\"\n",
                ),
                (
                    "mbsync",
                    "exit 1\n",
                ),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");
                let account = read_account(&config, "alice", account_id);
                let paths = ensure_account_paths(&config, &account).expect("paths");
                ensure_notmuch_config(&config, &account, &paths).expect("config");

                run_account_action_for_user(&config, "alice", account_id, AccountAction::Reindex)
                    .expect("reindex");

                let log = fs::read_to_string(paths.state_dir.join(".reindex-log/commands")).expect("log");
                assert!(log.contains("new"));
                assert!(paths.maildir.join(".notmuch").exists());
            },
        );
    }

    #[test]
    fn search_preferences_round_trip() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        save_search_preferences(&config, "alice", "from:billing", Some(9)).expect("save prefs");
        let preferences = load_search_preferences(&config, "alice").expect("load prefs");

        assert_eq!(preferences.last_query.as_deref(), Some("from:billing"));
        assert_eq!(preferences.default_account_id, Some(9));
    }

    #[test]
    fn account_index_state_tracks_config_and_database() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account = example_account();
        let paths = ensure_account_paths(&config, &account).expect("paths");

        assert_eq!(account_index_state(&paths), IndexState::NotConfigured);
        ensure_notmuch_config(&config, &account, &paths).expect("config");
        assert_eq!(
            account_index_state(&paths),
            IndexState::ConfiguredNoDatabase
        );
        fs::create_dir_all(paths.maildir.join(".notmuch")).expect("db");
        assert_eq!(account_index_state(&paths), IndexState::Indexed);
    }

    #[test]
    fn health_payload_reports_success_with_stubbed_commands() {
        with_stubbed_path(&[("mbsync", "exit 0\n"), ("notmuch", "exit 0\n")], |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            initialize_db(&config).expect("db");

            let (status, payload) = health_payload(&config);
            assert_eq!(status, StatusCode::OK);
            assert_eq!(payload.status, "ok");
            assert_eq!(payload.checks.mbsync, "ok");
        });
    }

    #[test]
    fn health_payload_reports_missing_tools() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        initialize_db(&config).expect("db");

        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let original_path = env::var("PATH").unwrap_or_default();
        env::set_var("PATH", tempdir.path().join("empty-bin"));
        let (status, payload) = health_payload(&config);
        env::set_var("PATH", original_path);

        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(payload.status, "degraded");
        assert!(payload.checks.notmuch.contains("notmuch"));
    }

    #[test]
    fn search_mail_uses_stubbed_notmuch_and_returns_results() {
        with_stubbed_path(
            &[
                (
                    "notmuch",
                    "printf '[{\"timestamp\":1713412350,\"date_relative\":\"2d\",\"authors\":\"Alice Example\",\"subject\":\"Invoice ready\",\"tags\":[\"inbox\",\"unread\"]}]'\n",
                ),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");
                let account = read_account(&config, "alice", account_id);
                let paths = ensure_account_paths(&config, &account).expect("paths");
                ensure_notmuch_config(&config, &account, &paths).expect("config");
                fs::create_dir_all(paths.maildir.join(".notmuch")).expect("db");

                let results =
                    search_mail(&config, "alice", Some(account_id), "subject:invoice").expect("search");
                assert_eq!(results.len(), 1);
                assert_eq!(results[0].subject, "Invoice ready");
            },
        );
    }

    #[test]
    fn search_empty_state_distinguishes_prefill_from_submitted_no_results() {
        let identity = Identity {
            username: "alice".to_string(),
            email: Some("alice@example.com".to_string()),
            groups: vec!["mail-archive-users".to_string()],
        };
        let html_prefill = render_search(
            &identity,
            &[],
            "",
            None,
            &[],
            &SearchViewState {
                submitted: false,
                result_count: 0,
                empty_message: Some("Saved search defaults are prefilled below. Submit a query to search indexed mail.".to_string()),
            },
        );
        let html_submitted = render_search(
            &identity,
            &[],
            "from:billing",
            None,
            &[],
            &SearchViewState {
                submitted: true,
                result_count: 0,
                empty_message: Some("No indexed messages matched this query.".to_string()),
            },
        );

        assert!(html_prefill.contains("Saved search defaults"));
        assert!(html_submitted.contains("0 results"));
        assert!(html_submitted.contains("No indexed messages matched this query."));
    }

    #[test]
    fn validate_account_form_requires_secret_only_for_create() {
        let form = CreateAccountForm {
            provider_kind: "gmail".to_string(),
            display_name: "Personal".to_string(),
            imap_host: "ignored".to_string(),
            imap_port: "993".to_string(),
            imap_username: "alice@gmail.com".to_string(),
            secret: String::new(),
            folder_patterns: String::new(),
            sync_enabled: Some("on".to_string()),
        };

        assert!(validate_account_form(&form, true).is_err());
        assert!(validate_account_form(&form, false).is_ok());
    }

    #[test]
    fn saved_query_detection_only_runs_on_explicit_q_param() {
        assert!(has_explicit_query_param("q=from%3Abilling"));
        assert!(!has_explicit_query_param("account_id=4"));
    }
}
