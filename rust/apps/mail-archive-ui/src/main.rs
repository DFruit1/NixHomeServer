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
use serde::{
    de::{self, Deserializer},
    Deserialize, Serialize,
};
use sha2::{Digest, Sha256};
use std::{
    cmp::Reverse,
    env,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::{ErrorKind, Read},
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
const PAPERLESS_REVIEWED_TAG: &str = "paperless-reviewed";
const PAPERLESS_FILED_TAG: &str = "paperless-filed";
const MASTER_KEY_FILENAME: &str = "master.key";
const DB_FILENAME: &str = "mail-archive-ui.sqlite3";
const ATTACHMENT_TEXT_MIME_PATTERNS: &[&str] = &[
    "^application/pdf$",
    "^application/msword$",
    "^application/rtf$",
    "^application/vnd[.]oasis[.]opendocument[.]text$",
    "^application/vnd[.]openxmlformats-officedocument[.]wordprocessingml[.]document$",
    "^text/plain$",
];
const CUSTOM_CSS: &str = include_str!("../static/custom.css");
const DASHBOARD_JS: &str = r#"const DASHBOARD_ROOT = document.querySelector("[data-dashboard-status-root]");

if (DASHBOARD_ROOT) {
  const numberFormatter = new Intl.NumberFormat();
  const RUNNING_INTERVAL_MS = 3000;
  const IDLE_INTERVAL_MS = 15000;
  let pollTimer = null;

  const setText = (element, value) => {
    if (element) {
      element.textContent = value;
    }
  };

  const setVisibility = (element, visible) => {
    if (element) {
      element.classList.toggle("hidden", !visible);
    }
  };

  const setOptionalText = (root, selector, value) => {
    const element = root.querySelector(selector);
    if (!element) {
      return;
    }

    if (value) {
      element.textContent = value;
      element.classList.remove("hidden");
    } else {
      element.textContent = "";
      element.classList.add("hidden");
    }
  };

  const setCount = (root, selector, value, suffix = "") => {
    const element = root.querySelector(selector);
    if (element) {
      element.textContent = `${numberFormatter.format(value)}${suffix}`;
    }
  };

  const updateSummary = (totals) => {
    const summary = document.querySelector("[data-dashboard-summary]");
    if (!summary) {
      return;
    }

    setCount(
      summary,
      '[data-summary-field="downloaded"]',
      totals.downloaded_message_count,
    );
    setCount(
      summary,
      '[data-summary-field="indexed"]',
      totals.indexed_message_count,
    );
    setCount(
      summary,
      '[data-summary-field="pending"]',
      totals.pending_index_count,
    );
    setCount(
      summary,
      '[data-summary-field="coverage"]',
      totals.index_coverage_percent,
      "%",
    );
  };

    const updateAccountCard = (account) => {
    const card = document.querySelector(`[data-account-id="${account.id}"]`);
    if (!card) {
      return;
    }

    const statusBadge = card.querySelector("[data-status-badge]");
    if (statusBadge) {
      statusBadge.className = `status ${account.status_class}`;
      statusBadge.textContent = account.status_label;
    }

    setText(card.querySelector("[data-index-pill]"), account.index_label);
    setText(card.querySelector("[data-paperless-pill]"), account.paperless_label);
    setText(
      card.querySelector('[data-progress-field="downloaded"]'),
      numberFormatter.format(account.downloaded_message_count),
    );
    setText(
      card.querySelector('[data-progress-field="indexed"]'),
      numberFormatter.format(account.indexed_message_count),
    );
    setText(
      card.querySelector('[data-progress-field="pending"]'),
      numberFormatter.format(account.pending_index_count),
    );
    setText(
      card.querySelector('[data-progress-field="coverage"]'),
      `${account.index_coverage_percent}%`,
    );
    setText(card.querySelector("[data-progress-note]"), account.progress_note);
    setText(card.querySelector("[data-last-activity]"), `Last activity ${account.last_activity}`);
    setText(card.querySelector("[data-paperless-note]"), account.paperless_note);

    const progressBar = card.querySelector("[data-progress-bar]");
    if (progressBar) {
      progressBar.style.width = `${account.index_coverage_percent}%`;
    }

    const syncNotice = card.querySelector("[data-sync-diagnostic]");
    if (syncNotice) {
      const metaParts = [];
      if (account.diagnostic_phase) {
        metaParts.push(`Phase ${account.diagnostic_phase}`);
      }
      if (account.diagnostic_code) {
        metaParts.push(`Code ${account.diagnostic_code}`);
      }
      setVisibility(syncNotice, Boolean(account.diagnostic_summary));
      setOptionalText(syncNotice, "[data-diagnostic-summary]", account.diagnostic_summary);
      setOptionalText(syncNotice, "[data-diagnostic-impact]", account.diagnostic_impact);
      setOptionalText(syncNotice, "[data-diagnostic-action]", account.recommended_action);
      setOptionalText(
        syncNotice,
        "[data-diagnostic-meta]",
        metaParts.length > 0 ? metaParts.join(" · ") : "",
      );
      setText(
        syncNotice.querySelector("[data-diagnostic-detail]"),
        account.diagnostic_detail || "",
      );

      const detailWrap = syncNotice.querySelector("[data-diagnostic-details]");
      if (detailWrap) {
        detailWrap.open = false;
        detailWrap.classList.toggle("hidden", !account.diagnostic_detail);
      }
    }

    const progressWarning = card.querySelector("[data-progress-warning]");
    if (progressWarning) {
      setVisibility(progressWarning, Boolean(account.progress_warning));
      setOptionalText(progressWarning, "[data-progress-warning-text]", account.progress_warning);
      setOptionalText(
        progressWarning,
        "[data-progress-warning-action]",
        account.progress_warning_action,
      );
      setText(
        progressWarning.querySelector("[data-progress-warning-detail]"),
        account.progress_warning_detail || "",
      );

      const detailWrap = progressWarning.querySelector("[data-progress-warning-details]");
      if (detailWrap) {
        detailWrap.open = false;
        detailWrap.classList.toggle("hidden", !account.progress_warning_detail);
      }
    }

    const paperlessErrorBox = card.querySelector("[data-paperless-error]");
    if (paperlessErrorBox) {
      if (account.last_paperless_error) {
        paperlessErrorBox.textContent = account.last_paperless_error;
        paperlessErrorBox.classList.remove("hidden");
      } else {
        paperlessErrorBox.textContent = "";
        paperlessErrorBox.classList.add("hidden");
      }
    }
  };

  const scheduleNextPoll = (accounts) => {
    const hasRunningAccount = accounts.some((account) => account.status_label === "syncing");
    const delay = document.hidden || !hasRunningAccount ? IDLE_INTERVAL_MS : RUNNING_INTERVAL_MS;
    pollTimer = window.setTimeout(fetchStatus, delay);
  };

  const fetchStatus = async () => {
    window.clearTimeout(pollTimer);

    try {
      const response = await fetch("/api/accounts/status", {
        cache: "no-store",
        headers: { Accept: "application/json" },
      });

      if (!response.ok) {
        throw new Error(`status ${response.status}`);
      }

      const payload = await response.json();
      updateSummary(payload.totals);
      payload.accounts.forEach(updateAccountCard);
      scheduleNextPoll(payload.accounts);
    } catch (error) {
      console.error("mail archive status refresh failed", error);
      pollTimer = window.setTimeout(fetchStatus, IDLE_INTERVAL_MS);
    }
  };

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      fetchStatus();
    }
  });

  fetchStatus();
}
"#;
const GROUP_NAME: &str = "mail-archive-users";

#[derive(Clone, Debug)]
struct AppConfig {
    address: Arc<str>,
    port: u16,
    data_dir: Arc<str>,
    store_root: Arc<str>,
    runtime_dir: Arc<str>,
    lock_dir: Arc<str>,
    paperless_consume_root: Option<Arc<str>>,
    paperless_staging_dir: Option<Arc<str>>,
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
    paperless_enabled: bool,
    created_at: String,
    updated_at: String,
    last_sync_started_at: Option<String>,
    last_sync_finished_at: Option<String>,
    last_sync_status: Option<String>,
    last_sync_error: Option<String>,
    last_sync_phase: Option<String>,
    last_sync_code: Option<String>,
    last_sync_summary: Option<String>,
    last_sync_detail: Option<String>,
    paperless_last_export_started_at: Option<String>,
    paperless_last_export_finished_at: Option<String>,
    paperless_last_export_status: Option<String>,
    paperless_last_export_error: Option<String>,
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

#[derive(Clone, Debug)]
struct PaperlessPaths {
    consume_root: PathBuf,
    staging_root: PathBuf,
}

#[derive(Clone, Debug)]
struct PaperlessExportSummary {
    exported_count: usize,
    duplicate_count: usize,
    ignored_count: usize,
}

#[derive(Clone, Debug)]
struct CandidateMessage {
    file_path: PathBuf,
    message_key: String,
}

#[derive(Clone, Debug)]
struct MessageMetadata {
    normalized_message_id: Option<String>,
    message_sha256: String,
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
struct TempExtractionDir {
    path: PathBuf,
}

impl Drop for TempExtractionDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
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
    paperless_enabled: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DashboardParams {
    flash: Option<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SearchParams {
    q: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_query_i64")]
    account_id: Option<i64>,
}

#[derive(Clone, Debug)]
struct DashboardAccountView {
    account: AccountRecord,
    status: AccountStatusPayload,
}

#[derive(Clone, Debug, Default)]
struct AccountProgressCounts {
    downloaded_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
}

#[derive(Debug, Serialize)]
struct DashboardStatusPayload {
    generated_at: String,
    totals: DashboardTotals,
    accounts: Vec<AccountStatusPayload>,
}

#[derive(Debug, Serialize)]
struct ErrorPayload {
    error: String,
}

#[derive(Clone, Debug, Default, Serialize)]
struct DashboardTotals {
    downloaded_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
}

#[derive(Clone, Debug, Serialize)]
struct AccountStatusPayload {
    id: i64,
    status_class: String,
    status_label: String,
    index_label: String,
    last_activity: String,
    downloaded_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
    progress_note: String,
    last_sync_error: Option<String>,
    diagnostic_phase: Option<String>,
    diagnostic_code: Option<String>,
    diagnostic_summary: Option<String>,
    diagnostic_detail: Option<String>,
    diagnostic_impact: Option<String>,
    recommended_action: Option<String>,
    progress_warning: Option<String>,
    progress_warning_detail: Option<String>,
    progress_warning_action: Option<String>,
    paperless_label: String,
    paperless_note: String,
    last_paperless_error: Option<String>,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SyncPhase {
    Preflight,
    Download,
    Index,
    Reconcile,
    Metrics,
}

impl SyncPhase {
    fn as_str(self) -> &'static str {
        match self {
            SyncPhase::Preflight => "preflight",
            SyncPhase::Download => "download",
            SyncPhase::Index => "index",
            SyncPhase::Reconcile => "reconcile",
            SyncPhase::Metrics => "metrics",
        }
    }

    fn from_stored(value: &str) -> Option<Self> {
        match value {
            "preflight" => Some(Self::Preflight),
            "download" => Some(Self::Download),
            "index" => Some(Self::Index),
            "reconcile" => Some(Self::Reconcile),
            "metrics" => Some(Self::Metrics),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
struct SyncDiagnostic {
    phase: Option<SyncPhase>,
    code: String,
    summary: String,
    detail: String,
}

#[derive(Clone, Debug)]
struct DashboardSyncNotice {
    diagnostic_phase: Option<String>,
    diagnostic_code: Option<String>,
    diagnostic_summary: Option<String>,
    diagnostic_detail: Option<String>,
    diagnostic_impact: Option<String>,
    recommended_action: Option<String>,
    progress_warning: Option<String>,
    progress_warning_detail: Option<String>,
    progress_warning_action: Option<String>,
}

#[derive(Clone, Copy, Debug)]
enum AccountAction {
    Sync,
    Reindex,
}

impl SyncDiagnostic {
    fn new(
        phase: SyncPhase,
        code: impl Into<String>,
        summary: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            phase: Some(phase),
            code: code.into(),
            summary: summary.into(),
            detail: truncate_diagnostic_detail(&detail.into()),
        }
    }

    fn legacy(detail: impl Into<String>) -> Self {
        let detail = truncate_diagnostic_detail(&detail.into());
        Self {
            phase: None,
            code: "legacy_error".to_string(),
            summary: "The last sync reported an error.".to_string(),
            detail,
        }
    }

    fn interrupted() -> Self {
        Self::new(
            SyncPhase::Reconcile,
            "interrupted",
            "A previous sync stopped before indexing finished.",
            "The account was marked running but no active sync lock remained.",
        )
    }
}

impl std::fmt::Display for SyncDiagnostic {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.detail.is_empty() {
            formatter.write_str(&self.summary)
        } else {
            write!(formatter, "{}: {}", self.summary, self.detail)
        }
    }
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
    paperless_enabled: bool,
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
    reconcile_interrupted_syncs(&config).expect("failed to reconcile interrupted sync state");

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
        .route("/api/accounts/status", get(account_status_api))
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
        .route("/static/dashboard.js", get(dashboard_js))
        .with_state(state)
}

async fn dashboard(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<DashboardParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    match load_dashboard_account_views(&state.config, &identity.username) {
        Ok(account_views) => html_response(render_dashboard(
            &identity,
            &account_views,
            params.flash.as_deref(),
            params.error.as_deref(),
        )),
        Err(error) => server_error_page("Failed to load accounts", &error, Some(&identity)),
    }
}

async fn account_status_api(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let payload = match tokio::task::spawn_blocking(move || {
        load_dashboard_status_payload(&config, &username)
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => {
            return no_store_response(json_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                ErrorPayload { error },
            ))
        }
        Err(_) => {
            return no_store_response(json_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                ErrorPayload {
                    error: "status task failed".to_string(),
                },
            ))
        }
    };

    no_store_response(json_response(StatusCode::OK, payload))
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
                paperless_enabled: None,
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

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    tokio::task::spawn_blocking(move || {
        let _ = run_account_action_for_user(&config, &username, account_id, AccountAction::Sync);
    });

    redirect_response("/?flash=Mailbox+sync+requested")
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

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    tokio::task::spawn_blocking(move || {
        let _ = run_account_action_for_user(&config, &username, account_id, AccountAction::Reindex);
    });

    redirect_response("/?flash=Mailbox+reindex+requested")
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

async fn dashboard_js() -> Response {
    let response = (
        [(CONTENT_TYPE, "text/javascript; charset=utf-8")],
        DASHBOARD_JS.to_string(),
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
    let paperless_consume_root = env::var("MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let paperless_staging_dir = env::var("MAIL_ARCHIVE_UI_PAPERLESS_STAGING_DIR")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
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
        paperless_consume_root,
        paperless_staging_dir,
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

    if let Some(path) = config.paperless_consume_root.as_deref() {
        fs::create_dir_all(path).map_err(|error| format!("failed to create {path}: {error}"))?;
    }
    if let Some(path) = config.paperless_staging_dir.as_deref() {
        fs::create_dir_all(path).map_err(|error| format!("failed to create {path}: {error}"))?;
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
                paperless_enabled INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_sync_started_at TEXT,
                last_sync_finished_at TEXT,
                last_sync_status TEXT,
                last_sync_error TEXT,
                last_sync_phase TEXT,
                last_sync_code TEXT,
                last_sync_summary TEXT,
                last_sync_detail TEXT,
                paperless_last_export_started_at TEXT,
                paperless_last_export_finished_at TEXT,
                paperless_last_export_status TEXT,
                paperless_last_export_error TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts (username);

            CREATE TABLE IF NOT EXISTS search_preferences (
                username TEXT PRIMARY KEY,
                last_query TEXT,
                default_account_id INTEGER
            );

            CREATE TABLE IF NOT EXISTS paperless_attachment_exports (
                account_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                attachment_sha256 TEXT NOT NULL,
                original_filename TEXT NOT NULL,
                paperless_relpath TEXT,
                outcome TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(account_id, message_key, attachment_sha256)
            );

            CREATE INDEX IF NOT EXISTS idx_paperless_attachment_exports_sha256
            ON paperless_attachment_exports (attachment_sha256);
            "#,
        )
        .map_err(|error| format!("failed to initialize sqlite schema: {error}"))?;

    ensure_account_column(
        &connection,
        "last_sync_phase",
        "ALTER TABLE accounts ADD COLUMN last_sync_phase TEXT",
    )?;
    ensure_account_column(
        &connection,
        "last_sync_code",
        "ALTER TABLE accounts ADD COLUMN last_sync_code TEXT",
    )?;
    ensure_account_column(
        &connection,
        "last_sync_summary",
        "ALTER TABLE accounts ADD COLUMN last_sync_summary TEXT",
    )?;
    ensure_account_column(
        &connection,
        "last_sync_detail",
        "ALTER TABLE accounts ADD COLUMN last_sync_detail TEXT",
    )?;
    ensure_account_column(
        &connection,
        "paperless_enabled",
        "ALTER TABLE accounts ADD COLUMN paperless_enabled INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_account_column(
        &connection,
        "paperless_last_export_started_at",
        "ALTER TABLE accounts ADD COLUMN paperless_last_export_started_at TEXT",
    )?;
    ensure_account_column(
        &connection,
        "paperless_last_export_finished_at",
        "ALTER TABLE accounts ADD COLUMN paperless_last_export_finished_at TEXT",
    )?;
    ensure_account_column(
        &connection,
        "paperless_last_export_status",
        "ALTER TABLE accounts ADD COLUMN paperless_last_export_status TEXT",
    )?;
    ensure_account_column(
        &connection,
        "paperless_last_export_error",
        "ALTER TABLE accounts ADD COLUMN paperless_last_export_error TEXT",
    )?;

    Ok(())
}

fn ensure_account_column(connection: &Connection, column: &str, sql: &str) -> Result<(), String> {
    let mut statement = connection
        .prepare("PRAGMA table_info(accounts)")
        .map_err(|error| format!("failed to inspect accounts schema: {error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("failed to inspect accounts columns: {error}"))?;

    for row in rows {
        if row.map_err(|error| format!("failed to decode accounts column: {error}"))? == column {
            return Ok(());
        }
    }

    connection
        .execute(sql, [])
        .map_err(|error| format!("failed to add accounts column {column}: {error}"))?;
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
        paperless_enabled: form.paperless_enabled.is_some(),
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
        paperless_enabled: account.paperless_enabled.then(|| "on".to_string()),
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
                paperless_enabled,
                created_at,
                updated_at,
                last_sync_status,
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail,
                paperless_last_export_status,
                paperless_last_export_error
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
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
                if account.paperless_enabled { 1 } else { 0 },
                now,
                now,
                "idle",
                Option::<String>::None,
                Option::<String>::None,
                Option::<String>::None,
                Option::<String>::None,
                Option::<String>::None,
                Option::<String>::None,
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
                paperless_enabled = ?10,
                updated_at = ?11
            WHERE username = ?12 AND id = ?13
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
                if account.paperless_enabled { 1 } else { 0 },
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
                paperless_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail,
                paperless_last_export_started_at,
                paperless_last_export_finished_at,
                paperless_last_export_status,
                paperless_last_export_error
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
                paperless_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail,
                paperless_last_export_started_at,
                paperless_last_export_finished_at,
                paperless_last_export_status,
                paperless_last_export_error
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
        paperless_enabled: row.get::<_, i64>(11)? != 0,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
        last_sync_started_at: row.get(14)?,
        last_sync_finished_at: row.get(15)?,
        last_sync_status: row.get(16)?,
        last_sync_error: row.get(17)?,
        last_sync_phase: row.get(18)?,
        last_sync_code: row.get(19)?,
        last_sync_summary: row.get(20)?,
        last_sync_detail: row.get(21)?,
        paperless_last_export_started_at: row.get(22)?,
        paperless_last_export_finished_at: row.get(23)?,
        paperless_last_export_status: row.get(24)?,
        paperless_last_export_error: row.get(25)?,
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
                paperless_enabled,
                created_at,
                updated_at,
                last_sync_started_at,
                last_sync_finished_at,
                last_sync_status,
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail,
                paperless_last_export_started_at,
                paperless_last_export_finished_at,
                paperless_last_export_status,
                paperless_last_export_error
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
                "mail-archive-ui sync failed username={} account_id={} phase={} code={} summary={} detail={}",
                account.username,
                account.id,
                error
                    .phase
                    .map(SyncPhase::as_str)
                    .unwrap_or("unknown"),
                error.code,
                error.summary,
                error.detail
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
) -> Result<(), SyncDiagnostic> {
    let account = load_account_for_user(config, username, account_id).map_err(|error| {
        preflight_sync_diagnostic(
            "account_lookup_failed",
            "Mailbox sync could not load the selected mailbox configuration.",
            error,
        )
    })?;
    run_account_action(config, &account, action)
}

fn run_account_action(
    config: &AppConfig,
    account: &AccountRecord,
    action: AccountAction,
) -> Result<(), SyncDiagnostic> {
    let _lock = acquire_account_lock(config, account.id).map_err(|error| {
        preflight_sync_diagnostic(
            "sync_lock_unavailable",
            "Mailbox sync could not start because another run is already active.",
            error,
        )
    })?;
    update_sync_started(config, account.id).map_err(|error| {
        preflight_sync_diagnostic(
            "sync_state_update_failed",
            "Mailbox sync could not record that the run started.",
            error,
        )
    })?;

    let result = (|| -> Result<(), SyncDiagnostic> {
        match action {
            AccountAction::Sync => {
                let encryption_key = load_or_create_master_key(config).map_err(|error| {
                    preflight_sync_diagnostic(
                        "master_key_unavailable",
                        "Mailbox sync could not read the archive encryption key.",
                        error,
                    )
                })?;
                let secret =
                    decrypt_secret(&encryption_key, &account.encrypted_secret).map_err(|error| {
                        preflight_sync_diagnostic(
                            "secret_decrypt_failed",
                            "Mailbox sync could not unlock the stored mailbox credential.",
                            error,
                        )
                    })?;
                let account_paths = ensure_account_paths(config, account).map_err(|error| {
                    preflight_sync_diagnostic(
                        "archive_path_unavailable",
                        "Mailbox sync could not prepare the archive paths.",
                        error,
                    )
                })?;
                ensure_notmuch_config(config, account, &account_paths).map_err(|error| {
                    preflight_sync_diagnostic(
                        "index_config_failed",
                        "Mailbox sync could not prepare the notmuch configuration.",
                        error,
                    )
                })?;
                let temp_secret =
                    write_temp_secret(config, account.id, &secret).map_err(|error| {
                        preflight_sync_diagnostic(
                            "temp_secret_failed",
                            "Mailbox sync could not prepare the temporary mailbox credential file.",
                            error,
                        )
                    })?;
                let temp_config = write_temp_mbsyncrc(
                    config,
                    account,
                    &account_paths,
                    &temp_secret.path,
                )
                .map_err(|error| {
                    preflight_sync_diagnostic(
                        "sync_config_failed",
                        "Mailbox sync could not generate the temporary mbsync configuration.",
                        error,
                    )
                })?;

                run_sync_command(
                    SyncPhase::Download,
                    "download_failed",
                    "Mailbox download failed before new mail could be indexed.",
                    "mbsync",
                    &["-c", temp_config.path.to_string_lossy().as_ref(), "--all"],
                    &[("HOME", account_paths.state_dir.to_string_lossy().as_ref())],
                )?;

                run_sync_command(
                    SyncPhase::Index,
                    "index_failed",
                    "Mail download completed, but indexing failed. Downloaded mail may be missing from search until reindex succeeds.",
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
            }
            AccountAction::Reindex => {
                let account_paths = ensure_account_paths(config, account).map_err(|error| {
                    preflight_sync_diagnostic(
                        "archive_path_unavailable",
                        "Mailbox reindex could not prepare the archive paths.",
                        error,
                    )
                })?;
                ensure_notmuch_config(config, account, &account_paths).map_err(|error| {
                    preflight_sync_diagnostic(
                        "index_config_failed",
                        "Mailbox reindex could not prepare the notmuch configuration.",
                        error,
                    )
                })?;
                run_sync_command(
                    SyncPhase::Index,
                    "index_failed",
                    "Mailbox reindex failed. Downloaded mail may be missing from search until reindex succeeds.",
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
            }
        }

        Ok(())
    })();

    match result {
        Ok(()) => {
            update_sync_finished(config, account.id, "ok", None).map_err(|error| {
                preflight_sync_diagnostic(
                    "sync_state_update_failed",
                    "Mailbox sync completed, but the final status could not be saved.",
                    error,
                )
            })?;
            if let Err(error) = maybe_export_account_to_paperless(config, account) {
                eprintln!(
                    "mail-archive-ui paperless export failed username={} account_id={} detail={}",
                    account.username, account.id, error
                );
            }
            Ok(())
        }
        Err(error) => {
            update_sync_finished(config, account.id, "error", Some(&error)).map_err(|db_error| {
                preflight_sync_diagnostic(
                    "sync_state_update_failed",
                    "Mailbox sync failed and the diagnostic state could not be saved.",
                    db_error,
                )
            })?;
            Err(error)
        }
    }
}

fn acquire_account_lock(config: &AppConfig, account_id: i64) -> Result<SyncLock, String> {
    let lock_path = sync_lock_path(config, account_id);
    remove_stale_sync_lock(&lock_path)?;

    match OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&lock_path)
    {
        Ok(mut file) => {
            let contents = format!("pid:{}", std::process::id());
            std::io::Write::write_all(&mut file, contents.as_bytes())
                .map_err(|error| format!("failed to write sync lock: {error}"))?;
            Ok(SyncLock { path: lock_path })
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if lock_pid_is_active(&lock_path) {
                Err("Mailbox sync is already running".to_string())
            } else {
                remove_stale_sync_lock(&lock_path)?;
                acquire_account_lock(config, account_id)
            }
        }
        Err(error) => Err(format!("failed to create sync lock: {error}")),
    }
}

fn sync_lock_path(config: &AppConfig, account_id: i64) -> PathBuf {
    PathBuf::from(config.lock_dir.as_ref()).join(format!("account-{account_id}.lock"))
}

fn reconcile_interrupted_syncs(config: &AppConfig) -> Result<(), String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare("SELECT id FROM accounts WHERE last_sync_status = 'running'")
        .map_err(|error| format!("failed to prepare interrupted sync query: {error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, i64>(0))
        .map_err(|error| format!("failed to query interrupted syncs: {error}"))?;
    let account_ids = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode interrupted sync account id: {error}"))?;
    drop(statement);
    drop(connection);

    for account_id in account_ids {
        let lock_path = sync_lock_path(config, account_id);
        if lock_pid_is_active(&lock_path) {
            continue;
        }

        remove_stale_sync_lock(&lock_path)?;
        let diagnostic = SyncDiagnostic::interrupted();
        update_sync_finished(config, account_id, "error", Some(&diagnostic))?;
    }

    Ok(())
}

fn remove_stale_sync_lock(lock_path: &FsPath) -> Result<(), String> {
    if !lock_path.exists() || lock_pid_is_active(lock_path) {
        return Ok(());
    }

    fs::remove_file(lock_path).map_err(|error| {
        format!(
            "failed to remove stale sync lock {}: {error}",
            lock_path.display()
        )
    })
}

fn lock_pid_is_active(lock_path: &FsPath) -> bool {
    let Some(pid) = read_lock_pid(lock_path) else {
        return false;
    };
    pid > 0 && FsPath::new("/proc").join(pid.to_string()).exists()
}

fn read_lock_pid(lock_path: &FsPath) -> Option<u32> {
    fs::read_to_string(lock_path)
        .ok()
        .and_then(|raw| raw.trim().strip_prefix("pid:").map(str::to_string))
        .and_then(|raw| raw.parse::<u32>().ok())
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
        .join(&account.username)
        .join("emails")
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
    let attachment_text_patterns = ATTACHMENT_TEXT_MIME_PATTERNS.join(";");
    let contents = format!(
        "[database]\npath={}\n\n[user]\nname={}\nprimary_email={}\n\n[new]\ntags={}\nignore=\n\n[search]\nexclude_tags=\n\n[index]\nas_text={}\n\n[maildir]\nsynchronize_flags=true\n",
        account_paths.maildir.display(),
        account.username,
        account.imap_username,
        tags,
        attachment_text_patterns,
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
                last_sync_error = NULL,
                last_sync_phase = NULL,
                last_sync_code = NULL,
                last_sync_summary = NULL,
                last_sync_detail = NULL
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
    diagnostic: Option<&SyncDiagnostic>,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let now = Utc::now().to_rfc3339();
    let phase = diagnostic
        .and_then(|value| value.phase)
        .map(SyncPhase::as_str)
        .map(str::to_string);
    let code = diagnostic.map(|value| value.code.clone());
    let summary = diagnostic.map(|value| value.summary.clone());
    let detail = diagnostic.map(|value| value.detail.clone());
    connection
        .execute(
            r#"
            UPDATE accounts
            SET
                last_sync_finished_at = ?1,
                updated_at = ?1,
                last_sync_status = ?2,
                last_sync_error = ?3,
                last_sync_phase = ?4,
                last_sync_code = ?5,
                last_sync_summary = ?6,
                last_sync_detail = ?7
            WHERE id = ?8
            "#,
            params![now, status, detail, phase, code, summary, detail, account_id],
        )
        .map_err(|error| format!("failed to mark sync finish: {error}"))?;
    Ok(())
}

fn truncate_diagnostic_detail(detail: &str) -> String {
    let trimmed = detail.trim();
    let mut truncated = String::new();
    for character in trimmed.chars().take(2048) {
        truncated.push(character);
    }
    truncated
}

fn sync_command_detail(command: &str, output: &Output) -> String {
    let detail = command_failure_detail(command, output);
    if detail.starts_with(command) {
        detail
    } else {
        format!("{command}: {detail}")
    }
}

fn preflight_sync_diagnostic(
    code: &str,
    summary: &str,
    detail: impl Into<String>,
) -> SyncDiagnostic {
    SyncDiagnostic::new(SyncPhase::Preflight, code, summary, detail.into())
}

fn command_sync_diagnostic(
    phase: SyncPhase,
    code: &str,
    summary: &str,
    command: &str,
    output: &Output,
) -> SyncDiagnostic {
    SyncDiagnostic::new(phase, code, summary, sync_command_detail(command, output))
}

fn run_sync_command(
    phase: SyncPhase,
    code: &str,
    summary: &str,
    command: &str,
    args: &[&str],
    envs: &[(&str, &str)],
) -> Result<(), SyncDiagnostic> {
    let output = execute_command(command, args, envs).map_err(|error| {
        SyncDiagnostic::new(
            phase,
            format!("{code}_spawn_failed"),
            summary,
            format!("failed to run {command}: {error}"),
        )
    })?;

    if output.status.success() {
        return Ok(());
    }

    Err(command_sync_diagnostic(phase, code, summary, command, &output))
}

fn stored_sync_diagnostic(account: &AccountRecord) -> Option<SyncDiagnostic> {
    if account.last_sync_status.as_deref() != Some("error") {
        return None;
    }

    if let Some(detail) = account.last_sync_error.as_deref() {
        if detail == "Mailbox sync was interrupted before completion." {
            return Some(SyncDiagnostic::interrupted());
        }
    }

    match (
        account.last_sync_phase.as_deref(),
        account.last_sync_code.as_deref(),
        account.last_sync_summary.as_deref(),
        account.last_sync_detail.as_deref().or(account.last_sync_error.as_deref()),
    ) {
        (phase, Some(code), Some(summary), Some(detail)) => Some(SyncDiagnostic {
            phase: phase.and_then(SyncPhase::from_stored),
            code: code.to_string(),
            summary: summary.to_string(),
            detail: truncate_diagnostic_detail(detail),
        }),
        (_, _, _, Some(detail)) => Some(SyncDiagnostic::legacy(detail)),
        _ => None,
    }
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

fn maybe_export_account_to_paperless(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<(), String> {
    if !account.paperless_enabled {
        return Ok(());
    }

    update_paperless_export_started(config, account.id)?;
    match export_account_to_paperless(config, account) {
        Ok(_) => {
            update_paperless_export_finished(config, account.id, "ok", None)?;
            Ok(())
        }
        Err(error) => {
            update_paperless_export_finished(config, account.id, "error", Some(error.clone()))?;
            Err(error)
        }
    }
}

fn export_account_to_paperless(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<PaperlessExportSummary, String> {
    let account_paths = ensure_account_paths(config, account)?;
    let paperless_paths = paperless_paths(config)?;
    let candidates = list_paperless_candidate_messages(&account_paths)?;
    let mut summary = PaperlessExportSummary {
        exported_count: 0,
        duplicate_count: 0,
        ignored_count: 0,
    };

    for candidate in candidates {
        let message_summary = export_candidate_message_to_paperless(
            config,
            account,
            &account_paths,
            &paperless_paths,
            &candidate,
        )?;
        tag_notmuch_message(&account_paths, &candidate.file_path, PAPERLESS_REVIEWED_TAG)?;
        if message_summary.exported_count > 0 {
            tag_notmuch_message(&account_paths, &candidate.file_path, PAPERLESS_FILED_TAG)?;
        }
        summary.exported_count += message_summary.exported_count;
        summary.duplicate_count += message_summary.duplicate_count;
        summary.ignored_count += message_summary.ignored_count;
    }

    Ok(summary)
}

fn export_candidate_message_to_paperless(
    config: &AppConfig,
    account: &AccountRecord,
    account_paths: &AccountPaths,
    paperless_paths: &PaperlessPaths,
    candidate: &CandidateMessage,
) -> Result<PaperlessExportSummary, String> {
    let extraction_dir = create_temp_extraction_dir(paperless_paths, account.id)?;
    extract_message_attachments(&candidate.file_path, &extraction_dir.path)?;
    let extracted_files = collect_regular_files(&extraction_dir.path)?;

    let mut summary = PaperlessExportSummary {
        exported_count: 0,
        duplicate_count: 0,
        ignored_count: 0,
    };

    for extracted_file in extracted_files {
        let metadata = fs::metadata(&extracted_file).map_err(|error| {
            format!(
                "failed to inspect extracted attachment {}: {error}",
                extracted_file.display()
            )
        })?;
        let original_filename = extracted_file
            .file_name()
            .and_then(|value| value.to_str())
            .map(ToString::to_string)
            .unwrap_or_else(|| "attachment".to_string());
        let attachment_sha256 = sha256_file(&extracted_file)?;

        if metadata.len() == 0 {
            record_attachment_export(
                config,
                account.id,
                &candidate.message_key,
                &attachment_sha256,
                &original_filename,
                None,
                "ignored",
            )?;
            summary.ignored_count += 1;
            continue;
        }

        let mime_type = detect_attachment_mime_type(&extracted_file)?;
        if !is_supported_document_attachment(&mime_type, &extracted_file)
            || looks_like_inline_artifact(&original_filename, &mime_type, metadata.len())
        {
            record_attachment_export(
                config,
                account.id,
                &candidate.message_key,
                &attachment_sha256,
                &original_filename,
                None,
                "ignored",
            )?;
            summary.ignored_count += 1;
            continue;
        }

        if let Some(existing_relpath) = find_existing_paperless_export(config, &attachment_sha256)?
        {
            record_attachment_export(
                config,
                account.id,
                &candidate.message_key,
                &attachment_sha256,
                &original_filename,
                Some(existing_relpath.as_str()),
                "duplicate",
            )?;
            summary.duplicate_count += 1;
            continue;
        }

        let relpath = move_attachment_into_paperless(
            account,
            account_paths,
            paperless_paths,
            &attachment_sha256,
            &original_filename,
            &extracted_file,
        )
        .map_err(|error| {
            let _ = record_attachment_export(
                config,
                account.id,
                &candidate.message_key,
                &attachment_sha256,
                &original_filename,
                None,
                "error",
            );
            error
        })?;
        record_attachment_export(
            config,
            account.id,
            &candidate.message_key,
            &attachment_sha256,
            &original_filename,
            Some(relpath.as_str()),
            "exported",
        )?;
        summary.exported_count += 1;
    }

    Ok(summary)
}

fn paperless_paths(config: &AppConfig) -> Result<PaperlessPaths, String> {
    let consume_root = config
        .paperless_consume_root
        .as_deref()
        .ok_or_else(|| "Paperless consume root is not configured".to_string())?;
    let staging_root = config
        .paperless_staging_dir
        .as_deref()
        .ok_or_else(|| "Paperless staging directory is not configured".to_string())?;

    Ok(PaperlessPaths {
        consume_root: PathBuf::from(consume_root),
        staging_root: PathBuf::from(staging_root),
    })
}

fn create_temp_extraction_dir(
    paperless_paths: &PaperlessPaths,
    account_id: i64,
) -> Result<TempExtractionDir, String> {
    let path = paperless_paths
        .staging_root
        .join(format!("account-{account_id}"))
        .join(random_hex(8));
    fs::create_dir_all(&path).map_err(|error| {
        format!(
            "failed to create extraction directory {}: {error}",
            path.display()
        )
    })?;
    Ok(TempExtractionDir { path })
}

fn extract_message_attachments(message_path: &FsPath, output_dir: &FsPath) -> Result<(), String> {
    run_command(
        "ripmime",
        &[
            "-i",
            message_path.to_string_lossy().as_ref(),
            "-d",
            output_dir.to_string_lossy().as_ref(),
            "-q",
        ],
        &[],
    )
}

fn collect_regular_files(root: &FsPath) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    collect_regular_files_inner(root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_regular_files_inner(root: &FsPath, files: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = fs::read_dir(root)
        .map_err(|error| format!("failed to read {}: {error}", root.display()))?;
    for entry in entries {
        let entry = entry.map_err(|error| format!("failed to read {}: {error}", root.display()))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;
        if file_type.is_dir() {
            collect_regular_files_inner(&entry.path(), files)?;
        } else if file_type.is_file() {
            files.push(entry.path());
        }
    }
    Ok(())
}

fn list_paperless_candidate_messages(
    account_paths: &AccountPaths,
) -> Result<Vec<CandidateMessage>, String> {
    let output = execute_command(
        "notmuch",
        &[
            "search",
            "--output=files",
            "--format=text",
            &format!("not tag:{PAPERLESS_REVIEWED_TAG}"),
        ],
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
            return Ok(Vec::new());
        }
        return Err(detail);
    }

    let mut candidates = Vec::new();
    for raw_line in String::from_utf8_lossy(&output.stdout).lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let file_path = PathBuf::from(line);
        if !file_path.is_file() {
            continue;
        }
        let metadata = read_message_metadata(&file_path)?;
        let message_key = metadata
            .normalized_message_id
            .map(|value| format!("message-id:{value}"))
            .unwrap_or_else(|| format!("sha256:{}", metadata.message_sha256));
        candidates.push(CandidateMessage {
            file_path,
            message_key,
        });
    }
    Ok(candidates)
}

fn read_message_metadata(message_path: &FsPath) -> Result<MessageMetadata, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    Ok(MessageMetadata {
        normalized_message_id: extract_message_id(&bytes).and_then(normalize_message_id),
        message_sha256: sha256_hex(&bytes),
    })
}

fn extract_message_id(message_bytes: &[u8]) -> Option<String> {
    let headers = String::from_utf8_lossy(message_bytes);
    let mut current_name = String::new();
    let mut current_value = String::new();

    for line in headers.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            break;
        }

        if line.starts_with(' ') || line.starts_with('\t') {
            if !current_name.is_empty() {
                if !current_value.is_empty() {
                    current_value.push(' ');
                }
                current_value.push_str(line.trim());
            }
            continue;
        }

        if current_name.eq_ignore_ascii_case("message-id") {
            return Some(current_value);
        }

        current_name.clear();
        current_value.clear();

        if let Some((name, value)) = line.split_once(':') {
            current_name = name.trim().to_string();
            current_value = value.trim().to_string();
        }
    }

    if current_name.eq_ignore_ascii_case("message-id") {
        Some(current_value)
    } else {
        None
    }
}

fn normalize_message_id(raw: String) -> Option<String> {
    let collapsed = raw.split_whitespace().collect::<String>();
    let trimmed = collapsed
        .trim()
        .trim_start_matches('<')
        .trim_end_matches('>');
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_ascii_lowercase())
    }
}

fn sha256_file(path: &FsPath) -> Result<String, String> {
    let mut file = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn detect_attachment_mime_type(path: &FsPath) -> Result<String, String> {
    let output = execute_command(
        "file",
        &["--mime-type", "-b", path.to_string_lossy().as_ref()],
        &[],
    )?;
    if output.status.success() {
        let detected = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !detected.is_empty() {
            return Ok(detected);
        }
    } else if let Some(fallback) = fallback_mime_from_extension(path) {
        return Ok(fallback);
    } else {
        return Err(command_failure_detail("file", &output));
    }

    Ok(
        fallback_mime_from_extension(path)
            .unwrap_or_else(|| "application/octet-stream".to_string()),
    )
}

fn fallback_mime_from_extension(path: &FsPath) -> Option<String> {
    let extension = path.extension()?.to_string_lossy().to_ascii_lowercase();
    Some(
        match extension.as_str() {
            "pdf" => "application/pdf",
            "txt" => "text/plain",
            "doc" => "application/msword",
            "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "odt" => "application/vnd.oasis.opendocument.text",
            "rtf" => "application/rtf",
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "tif" | "tiff" => "image/tiff",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            "webp" => "image/webp",
            _ => return None,
        }
        .to_string(),
    )
}

fn is_supported_document_attachment(mime_type: &str, path: &FsPath) -> bool {
    is_supported_document_mime(mime_type)
        || (mime_type == "application/octet-stream"
            && fallback_mime_from_extension(path)
                .as_deref()
                .is_some_and(is_supported_document_mime))
}

fn is_supported_document_mime(mime_type: &str) -> bool {
    matches!(
        mime_type,
        "application/pdf"
            | "text/plain"
            | "application/msword"
            | "application/rtf"
            | "application/vnd.oasis.opendocument.text"
            | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ) || mime_type.starts_with("image/")
}

fn looks_like_inline_artifact(filename: &str, mime_type: &str, size_bytes: u64) -> bool {
    mime_type.starts_with("image/") && size_bytes <= 1024
        || filename.eq_ignore_ascii_case("winmail.dat")
        || filename.eq_ignore_ascii_case("smime.p7s")
}

fn find_existing_paperless_export(
    config: &AppConfig,
    attachment_sha256: &str,
) -> Result<Option<String>, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            r#"
            SELECT paperless_relpath
            FROM paperless_attachment_exports
            WHERE attachment_sha256 = ?1 AND outcome = 'exported'
            ORDER BY created_at ASC
            LIMIT 1
            "#,
            params![attachment_sha256],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(|error| format!("failed to query paperless export dedupe: {error}"))?
        .flatten()
        .map_or(Ok(None), |value| Ok(Some(value)))
}

fn record_attachment_export(
    config: &AppConfig,
    account_id: i64,
    message_key: &str,
    attachment_sha256: &str,
    original_filename: &str,
    paperless_relpath: Option<&str>,
    outcome: &str,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let now = Utc::now().to_rfc3339();
    connection
        .execute(
            r#"
            INSERT INTO paperless_attachment_exports (
                account_id,
                message_key,
                attachment_sha256,
                original_filename,
                paperless_relpath,
                outcome,
                created_at,
                updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
            ON CONFLICT(account_id, message_key, attachment_sha256) DO UPDATE
            SET
                original_filename = excluded.original_filename,
                paperless_relpath = COALESCE(
                    paperless_attachment_exports.paperless_relpath,
                    excluded.paperless_relpath
                ),
                outcome = CASE
                    WHEN paperless_attachment_exports.outcome = 'exported'
                        AND excluded.outcome = 'duplicate'
                    THEN paperless_attachment_exports.outcome
                    ELSE excluded.outcome
                END,
                updated_at = excluded.updated_at
            "#,
            params![
                account_id,
                message_key,
                attachment_sha256,
                original_filename,
                paperless_relpath,
                outcome,
                now,
            ],
        )
        .map_err(|error| format!("failed to record paperless attachment export: {error}"))?;
    Ok(())
}

fn move_attachment_into_paperless(
    account: &AccountRecord,
    _account_paths: &AccountPaths,
    paperless_paths: &PaperlessPaths,
    attachment_sha256: &str,
    original_filename: &str,
    source_path: &FsPath,
) -> Result<String, String> {
    let safe_name = safe_filename(original_filename);
    let relpath = PathBuf::from("user-".to_string() + &account.username)
        .join(format!("account-{}", account.id))
        .join(format!("{attachment_sha256}--{safe_name}"));
    let destination = paperless_paths.consume_root.join(&relpath);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }
    if destination.exists() {
        return Ok(relpath.to_string_lossy().to_string());
    }
    fs::rename(source_path, &destination).map_err(|error| {
        format!(
            "failed to move {} into Paperless consume tree: {error}",
            source_path.display()
        )
    })?;
    sync_path(&destination)?;
    if let Some(parent) = destination.parent() {
        sync_directory(parent)?;
    }
    Ok(relpath.to_string_lossy().to_string())
}

fn sync_path(path: &FsPath) -> Result<(), String> {
    let file = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    file.sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", path.display()))
}

fn sync_directory(path: &FsPath) -> Result<(), String> {
    let dir = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    dir.sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", path.display()))
}

fn safe_filename(raw: &str) -> String {
    let sanitized = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string();
    if sanitized.is_empty() {
        "attachment".to_string()
    } else {
        sanitized
    }
}

fn tag_notmuch_message(
    account_paths: &AccountPaths,
    file_path: &FsPath,
    tag: &str,
) -> Result<(), String> {
    let relative_path = if let Ok(relative) = file_path.strip_prefix(&account_paths.maildir) {
        relative.to_path_buf()
    } else {
        let canonical_maildir = fs::canonicalize(&account_paths.maildir).map_err(|error| {
            format!(
                "failed to resolve {}: {error}",
                account_paths.maildir.display()
            )
        })?;
        let canonical_file = fs::canonicalize(file_path)
            .map_err(|error| format!("failed to resolve {}: {error}", file_path.display()))?;
        canonical_file
            .strip_prefix(&canonical_maildir)
            .map_err(|_| {
                format!(
                    "message path {} is outside the maildir",
                    file_path.display()
                )
            })?
            .to_path_buf()
    };
    let query = format!(
        "path:\"{}\"",
        escape_notmuch_query_value(&relative_path.to_string_lossy())
    );
    run_command(
        "notmuch",
        &["tag", &format!("+{tag}"), "--", query.as_str()],
        &[
            ("HOME", account_paths.state_dir.to_string_lossy().as_ref()),
            (
                "NOTMUCH_CONFIG",
                account_paths.notmuch_config.to_string_lossy().as_ref(),
            ),
        ],
    )
}

fn escape_notmuch_query_value(value: &str) -> String {
    value.replace('\\', r"\\").replace('"', "\\\"")
}

fn update_paperless_export_started(config: &AppConfig, account_id: i64) -> Result<(), String> {
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            UPDATE accounts
            SET
                paperless_last_export_started_at = ?1,
                paperless_last_export_status = 'running',
                paperless_last_export_error = NULL,
                updated_at = ?1
            WHERE id = ?2
            "#,
            params![Utc::now().to_rfc3339(), account_id],
        )
        .map_err(|error| format!("failed to mark paperless export start: {error}"))?;
    Ok(())
}

fn update_paperless_export_finished(
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
                paperless_last_export_finished_at = ?1,
                paperless_last_export_status = ?2,
                paperless_last_export_error = ?3,
                updated_at = ?1
            WHERE id = ?4
            "#,
            params![now, status, error_message, account_id],
        )
        .map_err(|error| format!("failed to mark paperless export finish: {error}"))?;
    Ok(())
}

fn visible_notmuch_tags(tags: Vec<String>) -> Vec<String> {
    tags.into_iter()
        .filter(|tag| !tag.starts_with("paperless-"))
        .collect()
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
                tags: visible_notmuch_tags(item.tags.unwrap_or_default()),
            });
        }
    }

    results.sort_by_key(|result| Reverse(result.timestamp));
    Ok(results)
}

fn load_dashboard_account_views(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<DashboardAccountView>, String> {
    let accounts = list_accounts_for_user(config, username)?;
    Ok(accounts
        .into_iter()
        .map(|account| build_dashboard_account_view(config, account))
        .collect())
}

fn load_dashboard_status_payload(
    config: &AppConfig,
    username: &str,
) -> Result<DashboardStatusPayload, String> {
    let accounts = load_dashboard_account_views(config, username)?;
    let statuses = accounts
        .iter()
        .map(|view| view.status.clone())
        .collect::<Vec<_>>();
    Ok(DashboardStatusPayload {
        generated_at: Utc::now().to_rfc3339(),
        totals: dashboard_totals(statuses.clone()),
        accounts: statuses,
    })
}

fn build_dashboard_account_view(
    config: &AppConfig,
    account: AccountRecord,
) -> DashboardAccountView {
    let last_activity = last_activity_label(&account);
    let sync_diagnostic = stored_sync_diagnostic(&account);
    let (index_state, counts, progress_error) = match ensure_account_paths(config, &account) {
        Ok(account_paths) => {
            let index_state = account_index_state(&account_paths);
            match load_account_progress(&account_paths, index_state) {
                Ok(counts) => (index_state, counts, None),
                Err(error) => (index_state, AccountProgressCounts::default(), Some(error)),
            }
        }
        Err(error) => (
            IndexState::NotConfigured,
            AccountProgressCounts::default(),
            Some(error),
        ),
    };
    let metrics_diagnostic = progress_error.map(metrics_sync_diagnostic);
    let (status_class, status_label) =
        account_status(&account, index_state, &counts, sync_diagnostic.as_ref());
    let progress_note = account_progress_note(
        &account,
        &counts,
        index_state,
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
    );
    let sync_notice = dashboard_sync_notice(
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
        &counts,
        index_state,
    );
    let (paperless_label, paperless_note) = paperless_status_summary(&account);
    let last_sync_error = account
        .last_sync_detail
        .clone()
        .or_else(|| account.last_sync_error.clone());

    DashboardAccountView {
        status: AccountStatusPayload {
            id: account.id,
            status_class: status_class.to_string(),
            status_label: status_label.to_string(),
            index_label: account_index_label(index_state).to_string(),
            last_activity,
            downloaded_message_count: counts.downloaded_message_count,
            indexed_message_count: counts.indexed_message_count,
            pending_index_count: counts.pending_index_count,
            index_coverage_percent: counts.index_coverage_percent,
            progress_note,
            last_sync_error,
            diagnostic_phase: sync_notice.diagnostic_phase,
            diagnostic_code: sync_notice.diagnostic_code,
            diagnostic_summary: sync_notice.diagnostic_summary,
            diagnostic_detail: sync_notice.diagnostic_detail,
            diagnostic_impact: sync_notice.diagnostic_impact,
            recommended_action: sync_notice.recommended_action,
            progress_warning: sync_notice.progress_warning,
            progress_warning_detail: sync_notice.progress_warning_detail,
            progress_warning_action: sync_notice.progress_warning_action,
            paperless_label,
            paperless_note,
            last_paperless_error: account.paperless_last_export_error.clone(),
        },
        account,
    }
}

fn load_account_progress(
    account_paths: &AccountPaths,
    index_state: IndexState,
) -> Result<AccountProgressCounts, String> {
    let downloaded_message_count = count_maildir_messages(&account_paths.maildir)?;
    let indexed_message_count = if index_state == IndexState::Indexed {
        count_indexed_messages(account_paths)?
    } else {
        0
    };
    Ok(progress_counts(
        downloaded_message_count,
        indexed_message_count,
    ))
}

fn count_maildir_messages(maildir: &FsPath) -> Result<usize, String> {
    count_maildir_messages_inner(maildir, false)
}

fn count_maildir_messages_inner(path: &FsPath, count_files_here: bool) -> Result<usize, String> {
    let entries = fs::read_dir(path)
        .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
    let mut total = 0;

    for entry in entries {
        let entry = entry.map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;

        if file_type.is_dir() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            total += count_maildir_messages_inner(
                &entry.path(),
                name.as_ref() == "cur" || name.as_ref() == "new",
            )?;
        } else if count_files_here && file_type.is_file() {
            total += 1;
        }
    }

    Ok(total)
}

fn count_indexed_messages(account_paths: &AccountPaths) -> Result<usize, String> {
    let output = execute_command(
        "notmuch",
        &["count", "*"],
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
            return Ok(0);
        }
        return Err(detail);
    }

    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<usize>()
        .map_err(|error| {
            format!(
                "failed to parse indexed message count from '{}': {error}",
                String::from_utf8_lossy(&output.stdout).trim()
            )
        })
}

fn progress_counts(
    downloaded_message_count: usize,
    indexed_message_count: usize,
) -> AccountProgressCounts {
    let pending_index_count = downloaded_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = if downloaded_message_count == 0 {
        usize::from(indexed_message_count > 0) * 100
    } else {
        (indexed_message_count.min(downloaded_message_count) * 100) / downloaded_message_count
    };
    AccountProgressCounts {
        downloaded_message_count,
        indexed_message_count,
        pending_index_count,
        index_coverage_percent,
    }
}

fn dashboard_totals(accounts: Vec<AccountStatusPayload>) -> DashboardTotals {
    let downloaded_message_count = accounts
        .iter()
        .map(|account| account.downloaded_message_count)
        .sum::<usize>();
    let indexed_message_count = accounts
        .iter()
        .map(|account| account.indexed_message_count)
        .sum::<usize>();
    let pending_index_count = downloaded_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = if downloaded_message_count == 0 {
        usize::from(indexed_message_count > 0) * 100
    } else {
        (indexed_message_count.min(downloaded_message_count) * 100) / downloaded_message_count
    };

    DashboardTotals {
        downloaded_message_count,
        indexed_message_count,
        pending_index_count,
        index_coverage_percent,
    }
}

fn account_index_label(index_state: IndexState) -> &'static str {
    match index_state {
        IndexState::Indexed => "Indexed",
        IndexState::ConfiguredNoDatabase | IndexState::NotConfigured => "Unindexed",
    }
}

fn account_progress_note(
    account: &AccountRecord,
    counts: &AccountProgressCounts,
    index_state: IndexState,
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
) -> String {
    if metrics_diagnostic.is_some() {
        "Counts are unavailable because the archive or search index could not be read."
            .to_string()
    } else if account.last_sync_status.as_deref() == Some("running")
        && counts.pending_index_count > 0
    {
        "Sync is active. Downloaded mail should rise first, then the index will catch up."
            .to_string()
    } else if sync_diagnostic
        .as_ref()
        .and_then(|value| value.phase)
        .is_some_and(|phase| matches!(phase, SyncPhase::Index | SyncPhase::Reconcile))
        && counts.pending_index_count > 0
    {
        "Downloaded mail is ahead of search. Run Reindex to catch up.".to_string()
    } else if counts.downloaded_message_count == 0 {
        "No messages downloaded yet.".to_string()
    } else if counts.pending_index_count > 0 {
        "Downloaded mail is ahead of the current search index. Run Reindex to catch up."
            .to_string()
    } else if index_state == IndexState::Indexed {
        "Search index is caught up with the downloaded archive.".to_string()
    } else {
        "Run Sync now or Reindex to build the search index.".to_string()
    }
}

fn metrics_sync_diagnostic(error: String) -> SyncDiagnostic {
    SyncDiagnostic::new(
        SyncPhase::Metrics,
        "metrics_unavailable",
        "Archive counts could not be verified for this mailbox.",
        error,
    )
}

fn diagnostic_impact(
    diagnostic: &SyncDiagnostic,
    counts: &AccountProgressCounts,
    index_state: IndexState,
) -> Option<String> {
    match diagnostic.phase {
        Some(SyncPhase::Download) => Some(
            "The sync did not reach the indexing step, so newly downloaded mail may still be missing."
                .to_string(),
        ),
        Some(SyncPhase::Index | SyncPhase::Reconcile)
            if counts.pending_index_count > 0 =>
        {
            Some(format!(
                "{} downloaded messages are not searchable yet.",
                counts.pending_index_count
            ))
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) => Some(
            "Downloaded mail may be missing from search until reindex succeeds.".to_string(),
        ),
        Some(SyncPhase::Preflight) => Some(
            "The sync stopped before the mailbox download step started.".to_string(),
        ),
        Some(SyncPhase::Metrics) => Some(
            "Downloaded and indexed counts are hidden until the archive can be read again."
                .to_string(),
        ),
        None if counts.pending_index_count > 0 => Some(format!(
            "{} downloaded messages may not be searchable yet.",
            counts.pending_index_count
        )),
        None if index_state != IndexState::Indexed => Some(
            "The archive has not been fully indexed yet.".to_string(),
        ),
        None => Some("Review the technical detail below before retrying.".to_string()),
    }
}

fn diagnostic_recommended_action(
    diagnostic: &SyncDiagnostic,
    counts: &AccountProgressCounts,
) -> Option<String> {
    match diagnostic.phase {
        Some(SyncPhase::Download | SyncPhase::Preflight) => Some(
            "Check the mailbox credentials and archive paths, then run Sync now again."
                .to_string(),
        ),
        Some(SyncPhase::Index | SyncPhase::Reconcile) if counts.pending_index_count > 0 => Some(
            "Run Reindex to catch search up with the downloaded archive.".to_string(),
        ),
        Some(SyncPhase::Index | SyncPhase::Reconcile) => Some(
            "Run Reindex after checking the notmuch configuration and archive state.".to_string(),
        ),
        Some(SyncPhase::Metrics) => Some(
            "Check archive and notmuch access, then refresh the dashboard.".to_string(),
        ),
        None => Some(
            "Review the technical detail below, then retry Sync now or Reindex.".to_string(),
        ),
    }
}

fn dashboard_sync_notice(
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
    counts: &AccountProgressCounts,
    index_state: IndexState,
) -> DashboardSyncNotice {
    let mut notice = DashboardSyncNotice {
        diagnostic_phase: None,
        diagnostic_code: None,
        diagnostic_summary: None,
        diagnostic_detail: None,
        diagnostic_impact: None,
        recommended_action: None,
        progress_warning: None,
        progress_warning_detail: None,
        progress_warning_action: None,
    };

    if let Some(diagnostic) = sync_diagnostic {
        notice.diagnostic_phase = diagnostic.phase.map(SyncPhase::as_str).map(str::to_string);
        notice.diagnostic_code = Some(diagnostic.code.clone());
        notice.diagnostic_summary = Some(diagnostic.summary.clone());
        notice.diagnostic_detail = Some(diagnostic.detail.clone());
        notice.diagnostic_impact = diagnostic_impact(diagnostic, counts, index_state);
        notice.recommended_action = diagnostic_recommended_action(diagnostic, counts);
    }

    if let Some(diagnostic) = metrics_diagnostic {
        notice.progress_warning = Some(diagnostic.summary.clone());
        notice.progress_warning_detail = Some(diagnostic.detail.clone());
        notice.progress_warning_action = diagnostic_recommended_action(diagnostic, counts);

        if notice.diagnostic_summary.is_none() {
            notice.diagnostic_phase =
                diagnostic.phase.map(SyncPhase::as_str).map(str::to_string);
            notice.diagnostic_code = Some(diagnostic.code.clone());
            notice.diagnostic_summary = Some(diagnostic.summary.clone());
            notice.diagnostic_detail = Some(diagnostic.detail.clone());
            notice.diagnostic_impact = diagnostic_impact(diagnostic, counts, index_state);
            notice.recommended_action = diagnostic_recommended_action(diagnostic, counts);
        }
    }

    notice
}

fn paperless_status_summary(account: &AccountRecord) -> (String, String) {
    if !account.paperless_enabled {
        return (
            "Paperless off".to_string(),
            "Attachment filing is disabled for this mailbox.".to_string(),
        );
    }

    match account.paperless_last_export_status.as_deref() {
        Some("running") => (
            "Paperless running".to_string(),
            format!(
                "Qualifying attachments are being handed off to Paperless{}.",
                account
                    .paperless_last_export_started_at
                    .as_deref()
                    .map(|timestamp| format!(" since {timestamp}"))
                    .unwrap_or_default()
            ),
        ),
        Some("error") => (
            "Paperless error".to_string(),
            "The last attachment export failed; the mailbox will retry on the next run."
                .to_string(),
        ),
        Some("ok") => (
            "Paperless on".to_string(),
            format!(
                "Qualifying attachments are handed off to Paperless after sync or reindex{}.",
                account
                    .paperless_last_export_finished_at
                    .as_deref()
                    .map(|timestamp| format!(" (last export {timestamp})"))
                    .unwrap_or_default()
            ),
        ),
        _ => (
            "Paperless on".to_string(),
            "Qualifying attachments will be handed off to Paperless on the next run.".to_string(),
        ),
    }
}

fn folder_mode_label(mode: &str) -> &str {
    match mode {
        "gmail_default" => "gmail-default",
        "generic_default" => "generic-default",
        _ => "custom",
    }
}

fn last_activity_label(account: &AccountRecord) -> String {
    account
        .last_sync_finished_at
        .as_deref()
        .or(account.last_sync_started_at.as_deref())
        .unwrap_or("Never")
        .to_string()
}

fn render_dashboard(
    identity: &Identity,
    accounts: &[DashboardAccountView],
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
    body.push_str(&render_dashboard_totals(accounts));
    if accounts.is_empty() {
        body.push_str(
            "<div class=\"empty-state\"><p class=\"meta\">No mailbox is configured yet. Start with Gmail or a generic IMAP account.</p><a class=\"button-link\" href=\"/accounts/new\">Add mailbox</a></div>",
        );
    } else {
        body.push_str("<div class=\"card-grid\" data-dashboard-status-root>");
        for view in accounts {
            body.push_str(&render_account_card(view));
        }
        body.push_str("</div>");
    }
    body.push_str("</section>");

    layout("Mail Archive", Some(identity), "dashboard", &body)
}

fn render_dashboard_totals(accounts: &[DashboardAccountView]) -> String {
    let totals = dashboard_totals(accounts.iter().map(|view| view.status.clone()).collect());
    format!(
        "<div class=\"dashboard-summary\" data-dashboard-summary>
          <div class=\"summary-metric\"><span class=\"metric-label\">Downloaded</span><strong data-summary-field=\"downloaded\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Indexed</span><strong data-summary-field=\"indexed\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Pending index</span><strong data-summary-field=\"pending\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Coverage</span><strong data-summary-field=\"coverage\">{}%</strong></div>
        </div>",
        totals.downloaded_message_count,
        totals.indexed_message_count,
        totals.pending_index_count,
        totals.index_coverage_percent,
    )
}

fn hidden_class(visible: bool) -> &'static str {
    if visible {
        ""
    } else {
        " hidden"
    }
}

fn render_sync_diagnostic_notice(status: &AccountStatusPayload) -> String {
    let meta = match (
        status.diagnostic_phase.as_deref(),
        status.diagnostic_code.as_deref(),
    ) {
        (Some(phase), Some(code)) => Some(format!("Phase {phase} · Code {code}")),
        (Some(phase), None) => Some(format!("Phase {phase}")),
        (None, Some(code)) => Some(format!("Code {code}")),
        (None, None) => None,
    };

    format!(
        "<div class=\"notice sync{}\" data-sync-diagnostic>
          <p class=\"notice-title{}\" data-diagnostic-summary>{}</p>
          <p class=\"meta notice-meta{}\" data-diagnostic-meta>{}</p>
          <p class=\"notice-copy{}\" data-diagnostic-impact>{}</p>
          <p class=\"notice-copy{}\" data-diagnostic-action>{}</p>
          <details class=\"notice-details{}\" data-diagnostic-details>
            <summary>Technical detail</summary>
            <pre data-diagnostic-detail>{}</pre>
          </details>
        </div>",
        hidden_class(status.diagnostic_summary.is_some()),
        hidden_class(status.diagnostic_summary.is_some()),
        escape_html(status.diagnostic_summary.as_deref().unwrap_or("")),
        hidden_class(meta.is_some()),
        escape_html(meta.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_impact.is_some()),
        escape_html(status.diagnostic_impact.as_deref().unwrap_or("")),
        hidden_class(status.recommended_action.is_some()),
        escape_html(status.recommended_action.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_detail.is_some()),
        escape_html(status.diagnostic_detail.as_deref().unwrap_or("")),
    )
}

fn render_progress_warning_notice(status: &AccountStatusPayload) -> String {
    format!(
        "<div class=\"notice warning{}\" data-progress-warning>
          <p class=\"notice-title{}\" data-progress-warning-text>{}</p>
          <p class=\"notice-copy{}\" data-progress-warning-action>{}</p>
          <details class=\"notice-details{}\" data-progress-warning-details>
            <summary>Technical detail</summary>
            <pre data-progress-warning-detail>{}</pre>
          </details>
        </div>",
        hidden_class(status.progress_warning.is_some()),
        hidden_class(status.progress_warning.is_some()),
        escape_html(status.progress_warning.as_deref().unwrap_or("")),
        hidden_class(status.progress_warning_action.is_some()),
        escape_html(status.progress_warning_action.as_deref().unwrap_or("")),
        hidden_class(status.progress_warning_detail.is_some()),
        escape_html(status.progress_warning_detail.as_deref().unwrap_or("")),
    )
}

fn render_account_card(view: &DashboardAccountView) -> String {
    let account = &view.account;
    let status = &view.status;
    let schedule_label = if account.sync_enabled {
        "Scheduled"
    } else {
        "Manual only"
    };
    let mut body = String::new();

    writeln!(
        &mut body,
        "<article class=\"account-card stack\" data-account-card data-account-id=\"{}\">
          <div class=\"card-header\">
            <div>
              <p class=\"eyebrow\">{}</p>
              <h2>{}</h2>
              <p class=\"meta\">{} · {}:{}</p>
            </div>
            <span class=\"status {}\" data-status-badge>{}</span>
          </div>
          <div class=\"card-meta\">
            <span class=\"pill\">{}</span>
            <span class=\"pill\" data-index-pill>{}</span>
            <span class=\"pill\" data-paperless-pill>{}</span>
          </div>
          <div class=\"hint\">Mailbox user: {} · Folder mode: {}</div>
          <div class=\"hint\">Added {} · Updated {}</div>
          <div class=\"progress-cluster\">
            <div class=\"progress-metrics\">
              <div class=\"summary-metric\"><span class=\"metric-label\">Downloaded</span><strong data-progress-field=\"downloaded\">{}</strong></div>
              <div class=\"summary-metric\"><span class=\"metric-label\">Indexed</span><strong data-progress-field=\"indexed\">{}</strong></div>
              <div class=\"summary-metric\"><span class=\"metric-label\">Pending index</span><strong data-progress-field=\"pending\">{}</strong></div>
              <div class=\"summary-metric\"><span class=\"metric-label\">Coverage</span><strong data-progress-field=\"coverage\">{}%</strong></div>
            </div>
            <div class=\"progress-bar\" aria-label=\"Index coverage\"><span data-progress-bar style=\"width: {}%\"></span></div>
            <p class=\"meta\" data-progress-note>{}</p>
          </div>
          <div class=\"hint\" data-paperless-note>{}</div>
          <div class=\"hint\" data-last-activity>Last activity {}</div>
          <div class=\"action-row\">
            <form method=\"post\" action=\"/accounts/{}/sync\"><button type=\"submit\">Sync now</button></form>
            <form method=\"post\" action=\"/accounts/{}/reindex\"><button class=\"secondary\" type=\"submit\">Reindex</button></form>
            <a class=\"button-link secondary\" href=\"/accounts/{}/edit\">Edit</a>
            <form method=\"post\" action=\"/accounts/{}/toggle-sync\"><button class=\"secondary\" type=\"submit\">{}</button></form>
          </div>
          {}
          {}",
        account.id,
        escape_html(&account.provider_kind),
        escape_html(&account.display_name),
        escape_html(&account.imap_host),
        account.imap_port,
        account.id,
        escape_html(&status.status_class),
        escape_html(&status.status_label),
        escape_html(schedule_label),
        escape_html(&status.index_label),
        escape_html(&status.paperless_label),
        escape_html(&account.imap_username),
        escape_html(folder_mode_label(&account.folder_mode)),
        escape_html(&account.created_at),
        escape_html(&account.updated_at),
        status.downloaded_message_count,
        status.indexed_message_count,
        status.pending_index_count,
        status.index_coverage_percent,
        status.index_coverage_percent,
        escape_html(&status.progress_note),
        escape_html(&status.paperless_note),
        escape_html(&status.last_activity),
        account.id,
        account.id,
        account.id,
        account.id,
        if account.sync_enabled {
            "Disable schedule"
        } else {
            "Enable schedule"
        },
        render_sync_diagnostic_notice(status),
        render_progress_warning_notice(status),
    )
    .ok();

    if let Some(error) = status.last_paperless_error.as_deref() {
        writeln!(
            &mut body,
            "<div class=\"error compact\" data-paperless-error>{}</div>",
            escape_html(error)
        )
        .ok();
    } else {
        body.push_str("<div class=\"error compact hidden\" data-paperless-error></div>");
    }

    body.push_str("</article>");
    body
}

fn account_status(
    account: &AccountRecord,
    index_state: IndexState,
    counts: &AccountProgressCounts,
    sync_diagnostic: Option<&SyncDiagnostic>,
) -> (&'static str, &'static str) {
    match account.last_sync_status.as_deref() {
        Some("running") => ("pending", "syncing"),
        Some("error")
            if sync_diagnostic
                .as_ref()
                .and_then(|value| value.phase)
                .is_some_and(|phase| matches!(phase, SyncPhase::Index | SyncPhase::Reconcile))
                && counts.pending_index_count > 0 =>
        {
            ("pending", "index behind")
        }
        Some("error") => ("error", "sync failed"),
        Some("ok") if counts.pending_index_count > 0 => ("pending", "index behind"),
        Some("ok") if index_state == IndexState::Indexed => ("ok", "healthy"),
        _ if index_state != IndexState::Indexed => ("unindexed", "needs index"),
        _ if counts.pending_index_count > 0 => ("pending", "index behind"),
        _ => ("idle", "healthy"),
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
          <label><input type=\"checkbox\" name=\"paperless_enabled\" {}> Send document attachments to Paperless for filing</label>
          <div class=\"actions\">
            <button type=\"submit\">{}</button>
            <a class=\"button-link secondary\" href=\"/\">Cancel</a>
          </div>
          <ul class=\"muted-list\">
            <li>Gmail defaults to append-only archive folders.</li>
            <li>Generic IMAP keeps TLS on port 993 by default.</li>
            <li>Paperless filing stays opt-in per mailbox and only sends qualifying attachments.</li>
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
        if form.paperless_enabled.is_some() {
            "checked"
        } else {
            ""
        },
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
          <p class=\"lede\">Search runs only across your own archive. Results stay metadata-only, but queries can match indexed message text and supported document attachments.</p>
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
    let dashboard_script = if active_nav == "dashboard" {
        r#"<script src="/static/dashboard.js" defer></script>"#
    } else {
        ""
    };
    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{}</title>
    <link rel="stylesheet" href="/static/custom.css">
    {}
  </head>
  <body>
    <main class="page">
      {}
      <footer class="page-footer">
        <nav class="footer-nav">
          <a class="{}" href="/">Dashboard</a>
          <a class="{}" href="/accounts/new">Add mailbox</a>
          <a class="{}" href="/search">Search</a>
        </nav>
        <p class="meta footer-meta">{}</p>
      </footer>
    </main>
  </body>
</html>"#,
        escape_html(title),
        dashboard_script,
        body,
        nav_active_class(active_nav == "dashboard"),
        nav_active_class(active_nav == "accounts"),
        nav_active_class(active_nav == "search"),
        escape_html(&identity_summary(identity)),
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

fn parse_optional_query_i64(raw: Option<&str>) -> Result<Option<i64>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => value
            .parse::<i64>()
            .map(Some)
            .map_err(|error| format!("invalid integer '{value}': {error}")),
        None => Ok(None),
    }
}

fn deserialize_optional_query_i64<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: Deserializer<'de>,
{
    let raw = Option::<String>::deserialize(deserializer)?;
    parse_optional_query_i64(raw.as_deref()).map_err(de::Error::custom)
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

fn no_store_response(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert("Cache-Control", HeaderValue::from_static("no-store"));
    response
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
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'",
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
        let paperless_consume_root = tempdir.path().join("paperless-consume");
        let paperless_staging_dir = tempdir.path().join("paperless-staging");

        AppConfig {
            address: Arc::<str>::from("127.0.0.1"),
            port: 9011,
            data_dir: Arc::<str>::from(data_dir.to_string_lossy().to_string()),
            store_root: Arc::<str>::from(store_root.to_string_lossy().to_string()),
            runtime_dir: Arc::<str>::from(runtime_dir.to_string_lossy().to_string()),
            lock_dir: Arc::<str>::from(lock_dir.to_string_lossy().to_string()),
            paperless_consume_root: Some(Arc::<str>::from(
                paperless_consume_root.to_string_lossy().to_string(),
            )),
            paperless_staging_dir: Some(Arc::<str>::from(
                paperless_staging_dir.to_string_lossy().to_string(),
            )),
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
            paperless_enabled: false,
            created_at: String::new(),
            updated_at: String::new(),
            last_sync_started_at: None,
            last_sync_finished_at: None,
            last_sync_status: None,
            last_sync_error: None,
            last_sync_phase: None,
            last_sync_code: None,
            last_sync_summary: None,
            last_sync_detail: None,
            paperless_last_export_started_at: None,
            paperless_last_export_finished_at: None,
            paperless_last_export_status: None,
            paperless_last_export_error: None,
        }
    }

    fn sample_status_payload() -> AccountStatusPayload {
        AccountStatusPayload {
            id: 42,
            status_class: "error".to_string(),
            status_label: "sync failed".to_string(),
            index_label: "Indexed".to_string(),
            last_activity: "2026-04-25T21:37:55Z".to_string(),
            downloaded_message_count: 8_002,
            indexed_message_count: 6_668,
            pending_index_count: 1_334,
            index_coverage_percent: 83,
            progress_note: "Downloaded mail is ahead of search. Run Reindex to catch up."
                .to_string(),
            last_sync_error: Some("mbsync: authentication failed".to_string()),
            diagnostic_phase: Some("download".to_string()),
            diagnostic_code: Some("download_failed".to_string()),
            diagnostic_summary: Some(
                "Mailbox download failed before new mail could be indexed.".to_string(),
            ),
            diagnostic_detail: Some("mbsync: authentication failed".to_string()),
            diagnostic_impact: Some(
                "The sync did not reach the indexing step, so newly downloaded mail may still be missing."
                    .to_string(),
            ),
            recommended_action: Some(
                "Check the mailbox credentials and archive paths, then run Sync now again."
                    .to_string(),
            ),
            progress_warning: None,
            progress_warning_detail: None,
            progress_warning_action: None,
            paperless_label: "Paperless off".to_string(),
            paperless_note: "Attachment filing is disabled for this mailbox.".to_string(),
            last_paperless_error: None,
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
        seed_account_with_flags(config, username, secret, true, false)
    }

    fn seed_account_with_flags(
        config: &AppConfig,
        username: &str,
        secret: &str,
        sync_enabled: bool,
        paperless_enabled: bool,
    ) -> i64 {
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
                sync_enabled,
                paperless_enabled,
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

    fn write_maildir_message(
        account_paths: &AccountPaths,
        relative_path: &str,
        contents: &str,
    ) -> PathBuf {
        let path = account_paths.maildir.join(relative_path);
        fs::create_dir_all(path.parent().expect("mail parent")).expect("maildir parent");
        write_private_file(&path, contents.as_bytes()).expect("mail message");
        path
    }

    fn paperless_consume_root(config: &AppConfig) -> PathBuf {
        PathBuf::from(
            config
                .paperless_consume_root
                .as_deref()
                .expect("paperless consume root"),
        )
    }

    fn count_paperless_handoff_files(config: &AppConfig) -> usize {
        collect_regular_files(&paperless_consume_root(config))
            .expect("paperless consume files")
            .len()
    }

    fn count_attachment_export_rows(config: &AppConfig) -> i64 {
        let connection = open_db(config).expect("db");
        connection
            .query_row(
                "SELECT COUNT(*) FROM paperless_attachment_exports",
                [],
                |row| row.get(0),
            )
            .expect("attachment export rows")
    }

    fn count_attachment_export_rows_for_outcome(config: &AppConfig, outcome: &str) -> i64 {
        let connection = open_db(config).expect("db");
        connection
            .query_row(
                "SELECT COUNT(*) FROM paperless_attachment_exports WHERE outcome = ?1",
                params![outcome],
                |row| row.get(0),
            )
            .expect("attachment export rows by outcome")
    }

    fn read_notmuch_stub_tag_file(account_paths: &AccountPaths, name: &str) -> String {
        fs::read_to_string(account_paths.state_dir.join(".notmuch-stub").join(name))
            .unwrap_or_default()
    }

    fn mail_export_stub_commands() -> [(&'static str, &'static str); 4] {
        [
            (
                "mbsync",
                "exit 0\n",
            ),
            (
                "notmuch",
                "STATE_DIR=\"$HOME/.notmuch-stub\"\nMAILDIR=\"$(dirname \"$NOTMUCH_CONFIG\")/../maildir\"\nmkdir -p \"$STATE_DIR\"\ncmd=\"${1:-}\"\nshift || true\ncase \"$cmd\" in\n  new)\n    mkdir -p \"$MAILDIR/.notmuch\"\n    ;;\n  count)\n    find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | wc -l | tr -d ' '\n    ;;\n  search)\n    if printf '%s ' \"$@\" | grep -q -- '--format=json'; then\n      printf '[]'\n      exit 0\n    fi\n    reviewed=\"$STATE_DIR/reviewed\"\n    touch \"$reviewed\"\n    while IFS= read -r path; do\n      rel=\"${path#${MAILDIR}/}\"\n      if grep -Fxq \"$rel\" \"$reviewed\"; then\n        continue\n      fi\n      printf '%s\\n' \"$path\"\n    done < <(find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | sort)\n    ;;\n  tag)\n    tag_spec=\"$1\"\n    shift\n    if [[ \"${1:-}\" == '--' ]]; then\n      shift\n    fi\n    query=\"${1:-}\"\n    rel=\"${query#path:\\\"}\"\n    rel=\"${rel%\\\"}\"\n    rel=\"${rel//\\\\\\\"/\\\"}\"\n    rel=\"${rel//\\\\\\\\/\\\\}\"\n    case \"$tag_spec\" in\n      +paperless-reviewed)\n        touch \"$STATE_DIR/reviewed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/reviewed\"\n        sort -u \"$STATE_DIR/reviewed\" -o \"$STATE_DIR/reviewed\"\n        ;;\n      +paperless-filed)\n        touch \"$STATE_DIR/filed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/filed\"\n        sort -u \"$STATE_DIR/filed\" -o \"$STATE_DIR/filed\"\n        ;;\n      *)\n        echo \"unsupported tag command: $tag_spec\" >&2\n        exit 1\n        ;;\n    esac\n    ;;\n  *)\n    echo \"unsupported notmuch command: $cmd\" >&2\n    exit 1\n    ;;\nesac\n",
            ),
            (
                "ripmime",
                "input=''\noutput=''\nwhile [[ $# -gt 0 ]]; do\n  case \"$1\" in\n    -i)\n      input=\"$2\"\n      shift 2\n      ;;\n    -d)\n      output=\"$2\"\n      shift 2\n      ;;\n    *)\n      shift\n      ;;\n  esac\ndone\nmkdir -p \"$output\"\ncontents=\"$(cat \"$input\")\"\nif [[ \"$contents\" == *'ATTACH:none'* ]]; then\n  exit 0\nfi\nif [[ \"$contents\" == *'ATTACH:duplicate-pdf'* ]]; then\n  printf 'duplicate payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:pdf'* ]]; then\n  printf 'pdf payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:text'* ]]; then\n  printf 'plain text payload\\n' > \"$output/note.txt\"\nfi\nif [[ \"$contents\" == *'ATTACH:tiny-image'* ]]; then\n  printf 'tiny' > \"$output/logo.png\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files-bad'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.bin\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.docx\"\nfi\n",
            ),
            (
                "file",
                "target=\"${@: -1}\"\ncase \"$target\" in\n  *.pdf)\n    printf 'application/pdf\\n'\n    ;;\n  *.txt)\n    printf 'text/plain\\n'\n    ;;\n  *.docx)\n    printf 'application/vnd.openxmlformats-officedocument.wordprocessingml.document\\n'\n    ;;\n  *.png)\n    printf 'image/png\\n'\n    ;;\n  *.bin)\n    echo 'unknown binary attachment' >&2\n    exit 1\n    ;;\n  *)\n    printf 'application/octet-stream\\n'\n    ;;\nesac\n",
            ),
        ]
    }

    #[test]
    fn account_paths_live_under_the_users_email_tree() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account = example_account();

        let paths = ensure_account_paths(&config, &account).expect("paths");

        assert_eq!(
            paths.maildir,
            tempdir
                .path()
                .join("store")
                .join("alice")
                .join("emails")
                .join("accounts")
                .join("42")
                .join("maildir")
        );
        assert_eq!(
            paths.state_dir,
            tempdir
                .path()
                .join("store")
                .join("alice")
                .join("emails")
                .join("accounts")
                .join("42")
                .join("state")
        );
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
    fn stale_lock_is_replaced_when_pid_is_not_active() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        let lock_path = sync_lock_path(&config, 9);
        write_private_file(&lock_path, b"999999").expect("stale lock");

        let lock = acquire_account_lock(&config, 9).expect("lock should be reacquired");
        let contents = fs::read_to_string(&lock.path).expect("lock contents");
        assert_eq!(contents.trim(), format!("pid:{}", std::process::id()));
    }

    #[test]
    fn reconcile_interrupted_sync_marks_running_account_as_error() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");

        update_sync_started(&config, account_id).expect("mark running");
        let lock_path = sync_lock_path(&config, account_id);
        write_private_file(&lock_path, b"999999").expect("stale lock");

        reconcile_interrupted_syncs(&config).expect("reconcile");

        let account = read_account(&config, "alice", account_id);
        assert_eq!(account.last_sync_status.as_deref(), Some("error"));
        assert_eq!(
            account.last_sync_error.as_deref(),
            Some("The account was marked running but no active sync lock remained.")
        );
        assert_eq!(account.last_sync_phase.as_deref(), Some("reconcile"));
        assert_eq!(account.last_sync_code.as_deref(), Some("interrupted"));
        assert_eq!(
            account.last_sync_summary.as_deref(),
            Some("A previous sync stopped before indexing finished.")
        );
        assert!(!lock_path.exists());
    }

    #[test]
    fn sync_failure_classifies_download_phase() {
        with_stubbed_path(
            &[
                ("mbsync", "echo 'authentication failed' >&2\nexit 1\n"),
                ("notmuch", "exit 0\n"),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");

                let error =
                    run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                        .expect_err("sync should fail");

                assert_eq!(error.phase, Some(SyncPhase::Download));
                assert_eq!(error.code, "download_failed");
                assert_eq!(
                    error.summary,
                    "Mailbox download failed before new mail could be indexed."
                );
                assert!(error.detail.contains("authentication failed"));

                let account = read_account(&config, "alice", account_id);
                assert_eq!(account.last_sync_phase.as_deref(), Some("download"));
                assert_eq!(account.last_sync_code.as_deref(), Some("download_failed"));
            },
        );
    }

    #[test]
    fn sync_failure_classifies_index_phase() {
        with_stubbed_path(
            &[
                ("mbsync", "exit 0\n"),
                ("notmuch", "echo 'database locked' >&2\nexit 1\n"),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");

                let error =
                    run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                        .expect_err("sync should fail");

                assert_eq!(error.phase, Some(SyncPhase::Index));
                assert_eq!(error.code, "index_failed");
                assert!(error.summary.contains("indexing failed"));
                assert!(error.detail.contains("database locked"));
            },
        );
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
        assert!(html.contains("/static/dashboard.js"));
        assert!(html.contains("alice@example.com"));

        let response = html_response(html);
        assert_eq!(
            response.headers().get("X-Frame-Options").expect("header"),
            "DENY"
        );
    }

    #[test]
    fn dashboard_card_renders_structured_sync_notice() {
        let view = DashboardAccountView {
            account: example_account(),
            status: sample_status_payload(),
        };

        let html = render_account_card(&view);
        assert!(html.contains("Mailbox download failed before new mail could be indexed."));
        assert!(html.contains("Technical detail"));
        assert!(html.contains("Check the mailbox credentials and archive paths"));
    }

    #[test]
    fn metrics_progress_warning_is_exposed_in_status_payload() {
        with_stubbed_path(
            &[(
                "notmuch",
                "if [[ \"$1\" == 'count' ]]; then echo 'database unavailable' >&2; exit 1; fi\nexit 0\n",
            )],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");
                let account = read_account(&config, "alice", account_id);
                let paths = ensure_account_paths(&config, &account).expect("paths");
                fs::create_dir_all(paths.maildir.join(".notmuch")).expect("db");

                let view = build_dashboard_account_view(&config, account);

                assert_eq!(
                    view.status.progress_warning.as_deref(),
                    Some("Archive counts could not be verified for this mailbox.")
                );
                assert!(view
                    .status
                    .progress_warning_detail
                    .as_deref()
                    .expect("warning detail")
                    .contains("database unavailable"));
            },
        );
    }

    #[test]
    fn legacy_last_sync_error_still_renders_reasonable_summary() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");
        let connection = open_db(&config).expect("db");
        connection
            .execute(
                r#"
                UPDATE accounts
                SET
                    last_sync_status = 'error',
                    last_sync_error = 'legacy failure detail',
                    last_sync_phase = NULL,
                    last_sync_code = NULL,
                    last_sync_summary = NULL,
                    last_sync_detail = NULL
                WHERE id = ?1
                "#,
                params![account_id],
            )
            .expect("update");

        let view = build_dashboard_account_view(&config, read_account(&config, "alice", account_id));
        assert_eq!(
            view.status.diagnostic_summary.as_deref(),
            Some("The last sync reported an error.")
        );
        assert_eq!(
            view.status.diagnostic_detail.as_deref(),
            Some("legacy failure detail")
        );
    }

    #[test]
    fn dashboard_status_payload_serializes_diagnostic_fields() {
        let payload = DashboardStatusPayload {
            generated_at: "2026-04-26T00:00:00Z".to_string(),
            totals: DashboardTotals::default(),
            accounts: vec![sample_status_payload()],
        };

        let json = serde_json::to_value(payload).expect("json");
        let account = &json["accounts"][0];
        assert!(account.get("diagnostic_summary").is_some());
        assert!(account.get("diagnostic_detail").is_some());
        assert!(account.get("recommended_action").is_some());
        assert!(account.get("progress_warning").is_some());
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
        assert!(html.contains("page-footer"));
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
                paperless_enabled: false,
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
                paperless_enabled: false,
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
        assert!(initial.contains("[index]\nas_text="));
        assert!(initial.contains("^application/pdf$"));
        assert!(initial.contains(
            "^application/vnd[.]openxmlformats-officedocument[.]wordprocessingml[.]document$"
        ));

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
                paperless_enabled: false,
            },
        )
        .expect("update");

        let updated = read_account(&config, "alice", account_id);
        let reconciled = read_notmuch_config(&config, &updated);
        assert!(reconciled.contains("primary_email=archive@example.com"));
    }

    #[test]
    fn paperless_flag_round_trips_through_account_storage_and_forms() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);

        let account = read_account(&config, "alice", account_id);
        let form = account_form_from_account(&account);

        assert!(account.paperless_enabled);
        assert_eq!(form.paperless_enabled.as_deref(), Some("on"));
    }

    #[test]
    fn paperless_export_skips_mailboxes_when_disabled() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, false);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <skip-disabled@example.com>\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            assert_eq!(count_paperless_handoff_files(&config), 0);
            assert_eq!(count_attachment_export_rows(&config), 0);
        });
    }

    #[test]
    fn paperless_backfills_once_then_stops_reprocessing_reviewed_messages() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <backfill@example.com>\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("first sync");
            assert_eq!(count_paperless_handoff_files(&config), 1);
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "exported"),
                1
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("second sync");
            assert_eq!(count_paperless_handoff_files(&config), 1);
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "exported"),
                1
            );
        });
    }

    #[test]
    fn paperless_marks_attachmentless_messages_reviewed_without_importing() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-no-attachments",
                "Message-ID: <no-attachments@example.com>\n\nATTACH:none\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            assert_eq!(count_paperless_handoff_files(&config), 0);
            assert!(read_notmuch_stub_tag_file(&account_paths, "reviewed")
                .contains("Inbox/cur/msg-no-attachments"));
        });
    }

    #[test]
    fn paperless_deduplicates_identical_attachments_across_messages() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <duplicate-a@example.com>\n\nATTACH:duplicate-pdf\n",
            );
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-2",
                "Message-ID: <duplicate-b@example.com>\n\nATTACH:duplicate-pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            assert_eq!(count_paperless_handoff_files(&config), 1);
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "exported"),
                1
            );
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "duplicate"),
                1
            );
        });
    }

    #[test]
    fn paperless_retry_avoids_reexporting_successful_attachments_after_partial_failure() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            let message_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <partial-failure@example.com>\n\nATTACH:two-files-bad\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("first sync");
            assert_eq!(count_paperless_handoff_files(&config), 1);
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "exported"),
                1
            );
            let account = read_account(&config, "alice", account_id);
            assert_eq!(
                account.paperless_last_export_status.as_deref(),
                Some("error")
            );
            assert!(
                account
                    .paperless_last_export_error
                    .as_deref()
                    .is_some_and(|error| error.contains("unknown binary attachment"))
            );

            write_private_file(
                &message_path,
                b"Message-ID: <partial-failure@example.com>\n\nATTACH:two-files\n",
            )
            .expect("rewrite mail message");
            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("retry sync");

            assert_eq!(count_paperless_handoff_files(&config), 2);
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "exported"),
                2
            );
            assert_eq!(
                count_attachment_export_rows_for_outcome(&config, "duplicate"),
                0
            );
        });
    }

    #[test]
    fn maildir_renames_do_not_trigger_duplicate_paperless_handoffs() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true, true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            let original_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <rename@example.com>\n\nATTACH:duplicate-pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("first sync");
            assert_eq!(count_paperless_handoff_files(&config), 1);

            let renamed_path = account_paths.maildir.join("Inbox/cur/msg-1:2,S");
            fs::rename(&original_path, &renamed_path).expect("rename maildir file");

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("second sync after rename");

            assert_eq!(count_paperless_handoff_files(&config), 1);
            assert_eq!(count_attachment_export_rows(&config), 1);
        });
    }

    #[test]
    fn visible_notmuch_tags_hide_internal_paperless_state() {
        assert_eq!(
            visible_notmuch_tags(vec![
                "inbox".to_string(),
                PAPERLESS_REVIEWED_TAG.to_string(),
                PAPERLESS_FILED_TAG.to_string(),
                "unread".to_string(),
            ]),
            vec!["inbox".to_string(), "unread".to_string()]
        );
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
            paperless_enabled: None,
        };

        assert!(validate_account_form(&form, true).is_err());
        assert!(validate_account_form(&form, false).is_ok());
    }

    #[test]
    fn saved_query_detection_only_runs_on_explicit_q_param() {
        assert!(has_explicit_query_param("q=from%3Abilling"));
        assert!(!has_explicit_query_param("account_id=4"));
    }

    #[test]
    fn empty_account_query_value_is_treated_as_all_mailboxes() {
        assert_eq!(parse_optional_query_i64(None).expect("none"), None);
        assert_eq!(parse_optional_query_i64(Some("")).expect("empty"), None);
        assert_eq!(parse_optional_query_i64(Some("  ")).expect("blank"), None);
        assert_eq!(
            parse_optional_query_i64(Some("7")).expect("number"),
            Some(7)
        );
    }

    #[test]
    fn maildir_message_count_tracks_root_and_nested_folders() {
        let tempdir = TempDir::new().expect("tempdir");
        let maildir = tempdir.path().join("maildir");

        fs::create_dir_all(maildir.join("cur")).expect("root cur");
        fs::create_dir_all(maildir.join("new")).expect("root new");
        fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");
        fs::create_dir_all(maildir.join(".Archive/tmp")).expect("archive tmp");
        fs::create_dir_all(maildir.join(".notmuch")).expect("notmuch");

        write_private_file(&maildir.join("cur/root-message"), b"1").expect("root cur message");
        write_private_file(&maildir.join("new/root-new"), b"1").expect("root new message");
        write_private_file(&maildir.join(".Archive/cur/sub-message"), b"1")
            .expect("archive cur message");
        write_private_file(&maildir.join(".Archive/tmp/not-a-message"), b"1").expect("tmp file");
        write_private_file(&maildir.join(".notmuch/metadata"), b"1").expect("metadata");

        assert_eq!(count_maildir_messages(&maildir).expect("message count"), 3);
    }
}
