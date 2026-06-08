use axum::{
    body::{Body, Bytes},
    extract::{Form, Path, Query, State},
    http::{
        header::{ACCEPT, CONTENT_DISPOSITION, CONTENT_TYPE, HOST},
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
use chrono::{DateTime, Local, NaiveDate, Timelike, Utc};
#[cfg(target_os = "linux")]
use landlock::{
    path_beneath_rules, Access, AccessFs, RestrictionStatus, Ruleset, RulesetAttr,
    RulesetCreatedAttr, RulesetStatus, ABI,
};
use mailparse::{DispositionType, MailAddr, MailHeaderMap};
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{
    de::{self, Deserializer},
    Deserialize, Serialize,
};
use sha2::{Digest, Sha256};
use std::{
    cmp::Reverse,
    collections::{HashMap, HashSet},
    env,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::{ErrorKind, Read},
    net::SocketAddr,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path as FsPath, PathBuf},
    process::{Command, Output},
    sync::Arc,
};
use tokio_util::io::ReaderStream;
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 9011;
const DEFAULT_DATA_DIR: &str = ".";
const DEFAULT_STORE_ROOT: &str = ".";
const DEFAULT_RUNTIME_DIR: &str = "/tmp";
const DEFAULT_LOCK_DIR: &str = ".";
const ATTACHMENTS_PER_PAGE: usize = 100;
const MAX_ZIP_ATTACHMENTS: usize = 500;
const MAX_ZIP_BYTES: u64 = 1024 * 1024 * 1024;
const RUNTIME_EXPORT_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
const PAPERLESS_HANDOFF_STAGING_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
const PAPERLESS_HANDOFF_STAGING_PREFIX: &str = ".mail-archive-";
const PAPERLESS_HANDOFF_STAGING_SUFFIX: &str = ".tmp";
#[cfg(not(test))]
const PAPERLESS_PUBLISH_RETRY_ATTEMPTS: usize = 30;
#[cfg(test)]
const PAPERLESS_PUBLISH_RETRY_ATTEMPTS: usize = 2;
#[cfg(not(test))]
const PAPERLESS_PUBLISH_RETRY_DELAY_MS: u64 = 1000;
const ATTACHMENT_SELECTION_ALL_MATCHING: &str = "all_matching";
const MASTER_KEY_FILENAME: &str = "master.key";
const DB_FILENAME: &str = "mail-archive-ui.sqlite3";
const VISIBLE_MESSAGE_SUBJECT_MAX_CHARS: usize = 120;
const ATTACHMENT_TEXT_MIME_PATTERNS: &[&str] = &[
    "^application/pdf$",
    "^application/msword$",
    "^application/rtf$",
    "^application/vnd[.]oasis[.]opendocument[.]text$",
    "^application/vnd[.]openxmlformats-officedocument[.]wordprocessingml[.]document$",
    "^text/plain$",
];
const DEFAULT_FRONTEND_DIST_DIR: &str = "frontend/dist";
const DEFAULT_VITE_ORIGIN: &str = "http://127.0.0.1:5173";
const FRONTEND_ENTRYPOINT: &str = "src/entry.prod.tsx";
const GROUP_NAME: &str = "mail-archive-users";

#[derive(Clone, Debug)]
struct AppConfig {
    address: Arc<str>,
    port: u16,
    data_dir: Arc<str>,
    store_root: Arc<str>,
    account_state_root: Arc<str>,
    runtime_dir: Arc<str>,
    lock_dir: Arc<str>,
    paperless_consume_root: Option<Arc<str>>,
    paperless_handoff_staging_root: Option<Arc<str>>,
    visible_mirror_read_group: Option<Arc<str>>,
    default_tags: Arc<[String]>,
    frontend_dist_dir: Arc<str>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrontendMode {
    Production,
    Vite,
}

#[derive(Clone, Debug)]
struct AppState {
    config: AppConfig,
}

#[derive(Clone, Debug)]
struct Identity {
    username: String,
    email: Option<String>,
    #[allow(dead_code)]
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
    #[allow(dead_code)]
    folder_mode: String,
    folder_patterns_json: String,
    encrypted_secret: String,
    sync_enabled: bool,
    #[allow(dead_code)]
    created_at: String,
    #[allow(dead_code)]
    updated_at: String,
    last_sync_started_at: Option<String>,
    last_sync_finished_at: Option<String>,
    last_sync_status: Option<String>,
    last_sync_error: Option<String>,
    last_sync_phase: Option<String>,
    last_sync_code: Option<String>,
    last_sync_summary: Option<String>,
    last_sync_detail: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct SearchPreferenceRecord {
    last_query: Option<String>,
    default_account_id: Option<i64>,
}

#[derive(Clone, Debug)]
struct SearchResult {
    account_name: String,
    message_relpath: String,
    timestamp: i64,
    date_label: String,
    from: String,
    subject: String,
    tags: Vec<String>,
    sender_priority: SenderPriorityView,
}

#[allow(dead_code)]
#[derive(Clone, Debug)]
struct AttachmentMessageRecord {
    account_id: i64,
    message_key: String,
    message_relpath: String,
    message_mtime: i64,
    message_size: i64,
    subject: String,
    from: String,
    timestamp: i64,
    last_scanned_at: String,
    has_attachments: bool,
}

#[derive(Clone, Debug)]
struct AttachmentRecord {
    attachment_key: String,
    account_id: i64,
    message_key: String,
    attachment_index: i64,
    attachment_sha256: String,
    original_filename: String,
    safe_filename: String,
    extension: String,
    mime_type: String,
    size_bytes: i64,
    is_inline_artifact: bool,
    blob_relpath: Option<String>,
    source_message_sha256: Option<String>,
    last_verified_at: Option<String>,
    created_at: String,
    updated_at: String,
    last_seen_at: String,
}

#[derive(Clone, Debug)]
struct AttachmentListItem {
    attachment: AttachmentRecord,
    message: AttachmentMessageRecord,
    account_name: String,
    sender_priority: SenderPriorityView,
    paperless_sent_at: Option<String>,
}

#[derive(Clone, Debug)]
struct ExtractedAttachment {
    path: PathBuf,
    original_filename: String,
    is_inline_image: bool,
}

#[allow(dead_code)]
#[derive(Debug)]
struct AccountPaths {
    emails_root: PathBuf,
    visible_emails_root: PathBuf,
    hidden_sync_root: PathBuf,
    maildir: PathBuf,
    attachment_blob_root: PathBuf,
    export_root: PathBuf,
    account_state_root: PathBuf,
    notmuch_config: PathBuf,
    sync_state_dir: PathBuf,
    notmuch_db_root: PathBuf,
}

#[allow(dead_code)]
#[derive(Clone, Debug)]
struct AccountProgressSnapshotRecord {
    account_id: i64,
    archived_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
    archive_file_count: usize,
    overlap_file_count: usize,
    last_computed_at: String,
    source_sync_finished_at: Option<String>,
    snapshot_status: String,
    snapshot_note: Option<String>,
}

#[derive(Clone, Debug)]
struct MessageCatalogRecord {
    account_id: i64,
    message_key: String,
    canonical_hidden_relpath: String,
    subject: String,
    sender: String,
    timestamp: i64,
    message_sha256: String,
    last_seen_at: String,
}

#[derive(Clone, Debug)]
struct MessageMailboxInstanceRecord {
    account_id: i64,
    message_key: String,
    raw_mailbox_path: String,
    visible_relpath: String,
    hidden_relpath: String,
    account_slug: String,
    mailbox_slug: String,
    filename: String,
    last_seen_at: String,
}

#[derive(Clone, Debug)]
struct MessageMetadata {
    normalized_message_id: Option<String>,
    message_sha256: Option<String>,
    subject: String,
    from: String,
    timestamp: i64,
}

#[derive(Clone, Debug)]
struct LiveMessageRecord {
    message_key: String,
    message_relpaths: Vec<String>,
    subject: String,
    from: String,
    timestamp: i64,
}

#[derive(Clone, Debug, Default)]
struct MaildirInventory {
    archive_file_count: usize,
    logical_message_count: usize,
    overlap_file_count: usize,
}

#[derive(Debug, Serialize)]
struct AttachmentZipManifest {
    generated_at: String,
    source: &'static str,
    file_count: usize,
    total_size_bytes: u64,
    files: Vec<AttachmentZipManifestEntry>,
}

#[derive(Debug, Serialize)]
struct AttachmentZipManifestEntry {
    zip_path: String,
    account: String,
    account_id: i64,
    message_key: String,
    message_relpath: String,
    subject: String,
    sender: String,
    message_timestamp: i64,
    original_filename: String,
    mime_type: String,
    size_bytes: i64,
    attachment_sha256: String,
    blob_relpath: Option<String>,
    source_message_sha256: Option<String>,
}

#[derive(Debug, Serialize)]
struct AttachmentVerificationReport {
    generated_at: String,
    accounts_checked: usize,
    messages_checked: usize,
    attachments_checked: usize,
    missing_sources: usize,
    missing_blobs: usize,
    mismatched_blobs: usize,
    orphaned_blobs: usize,
    warnings: Vec<String>,
}

impl AttachmentVerificationReport {
    fn has_errors(&self) -> bool {
        self.missing_sources > 0 || self.missing_blobs > 0 || self.mismatched_blobs > 0
    }
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
        if !self.path.as_os_str().is_empty() {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[derive(Debug)]
struct TempZipFile {
    filename: String,
    path: PathBuf,
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
    #[serde(default, deserialize_with = "deserialize_optional_query_i64")]
    account_id: Option<i64>,
    priority: Option<String>,
    sender_address: Option<String>,
    sender_name: Option<String>,
    sender_domain: Option<String>,
    subject: Option<String>,
    body_text: Option<String>,
    date_from: Option<String>,
    date_to: Option<String>,
    has_attachments: Option<String>,
    flash: Option<String>,
    error: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct AttachmentListParams {
    q: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_query_i64")]
    account_id: Option<i64>,
    priority: Option<String>,
    sender_address: Option<String>,
    sender_name: Option<String>,
    sender_domain: Option<String>,
    subject: Option<String>,
    body_text: Option<String>,
    date_from: Option<String>,
    date_to: Option<String>,
    has_attachments: Option<String>,
    extension: Option<String>,
    attachment_name: Option<String>,
    mime_type: Option<String>,
    min_size: Option<String>,
    max_size: Option<String>,
    min_attachments: Option<String>,
    max_attachments: Option<String>,
    include_inline: Option<String>,
    include_inline_images: Option<String>,
    show_mime_details: Option<String>,
    download_subfolder: Option<String>,
    page: Option<String>,
    flash: Option<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AttachmentRefreshForm {
    account_id: Option<String>,
    return_to: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct AttachmentDownloadForm {
    #[serde(default)]
    attachment_keys: Vec<String>,
    selection_scope: Option<String>,
    q: Option<String>,
    account_id: Option<String>,
    priority: Option<String>,
    sender_address: Option<String>,
    sender_name: Option<String>,
    sender_domain: Option<String>,
    subject: Option<String>,
    body_text: Option<String>,
    date_from: Option<String>,
    date_to: Option<String>,
    has_attachments: Option<String>,
    extension: Option<String>,
    attachment_name: Option<String>,
    mime_type: Option<String>,
    min_size: Option<String>,
    max_size: Option<String>,
    min_attachments: Option<String>,
    max_attachments: Option<String>,
    include_inline: Option<String>,
    include_inline_images: Option<String>,
    show_mime_details: Option<String>,
    download_subfolder: Option<String>,
    return_to: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct AttachmentPaperlessForm {
    #[serde(default)]
    attachment_keys: Vec<String>,
    return_to: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct AttachmentPresetSaveForm {
    preset_name: String,
    q: Option<String>,
    account_id: Option<String>,
    priority: Option<String>,
    sender_address: Option<String>,
    sender_name: Option<String>,
    sender_domain: Option<String>,
    subject: Option<String>,
    body_text: Option<String>,
    date_from: Option<String>,
    date_to: Option<String>,
    has_attachments: Option<String>,
    extension: Option<String>,
    attachment_name: Option<String>,
    mime_type: Option<String>,
    min_size: Option<String>,
    max_size: Option<String>,
    min_attachments: Option<String>,
    max_attachments: Option<String>,
    include_inline: Option<String>,
    include_inline_images: Option<String>,
    show_mime_details: Option<String>,
    download_subfolder: Option<String>,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AttachmentPresetDeleteForm {
    preset_id: i64,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SenderPriorityForm {
    sender_kind: String,
    sender_value: String,
    priority: String,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SenderPriorityClearForm {
    sender_kind: String,
    sender_value: String,
    return_to: Option<String>,
}

#[derive(Clone, Debug)]
struct DashboardAccountView {
    account: AccountRecord,
    status: AccountStatusPayload,
}

#[derive(Clone, Debug, Default)]
struct AccountProgressCounts {
    archived_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
    archive_file_count: usize,
    overlap_file_count: usize,
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

#[derive(Debug, Serialize)]
struct PriorityChangePayload {
    ok: bool,
    message: String,
    return_to: Option<String>,
}

#[derive(Debug, Serialize)]
struct ActionPayload {
    ok: bool,
    message: String,
    account_id: Option<i64>,
}

#[derive(Debug, Serialize)]
struct PaperlessHandoffPayload {
    ok: bool,
    message: String,
    error: Option<String>,
    sent_attachment_keys: Vec<String>,
    return_to: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
struct DashboardTotals {
    archived_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
    archive_file_count: usize,
    overlap_file_count: usize,
}

#[derive(Clone, Debug, Serialize)]
struct AccountStatusPayload {
    id: i64,
    status_class: String,
    status_label: String,
    index_label: String,
    last_activity: String,
    archived_message_count: usize,
    indexed_message_count: usize,
    pending_index_count: usize,
    index_coverage_percent: usize,
    archive_file_count: usize,
    overlap_file_count: usize,
    progress_note: String,
    overlap_note: Option<String>,
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
}

#[allow(dead_code)]
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
    ripmime: String,
    file: String,
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
}

#[derive(Debug)]
struct SearchViewState {
    submitted: bool,
    result_count: usize,
    empty_message: Option<String>,
    priority_filter: SenderPriorityFilter,
}

#[derive(Clone, Debug, Default)]
struct MessageSearchFilters {
    q: String,
    sender_address: String,
    sender_name: String,
    sender_domain: String,
    subject: String,
    body_text: String,
    date_from: String,
    date_to: String,
    has_attachments: Option<bool>,
}

#[derive(Clone, Debug, Default)]
struct ParsedMessageSearchFilters {
    raw: MessageSearchFilters,
    normalized_sender_address: Option<String>,
    normalized_sender_domain: Option<String>,
    date_from_timestamp: Option<i64>,
    date_to_timestamp: Option<i64>,
}

#[derive(Clone, Debug, Default)]
struct AttachmentSearchFilters {
    message: MessageSearchFilters,
    extension: String,
    attachment_name: String,
    mime_type: String,
    min_size: String,
    max_size: String,
    min_attachments: String,
    max_attachments: String,
}

#[derive(Clone, Debug, Default)]
struct ParsedAttachmentSearchFilters {
    raw: AttachmentSearchFilters,
    message: ParsedMessageSearchFilters,
    min_size_bytes: Option<i64>,
    max_size_bytes: Option<i64>,
    min_attachment_count: Option<usize>,
    max_attachment_count: Option<usize>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SenderPriority {
    High,
    Normal,
    Low,
}

impl SenderPriority {
    fn from_stored(value: &str) -> Option<Self> {
        match value {
            "high" => Some(Self::High),
            "low" => Some(Self::Low),
            _ => None,
        }
    }

    fn as_stored_value(self) -> &'static str {
        match self {
            Self::High => "high",
            Self::Normal => "normal",
            Self::Low => "low",
        }
    }

    fn dropdown_label(self) -> &'static str {
        match self {
            Self::High => "Important",
            Self::Normal => "Normal",
            Self::Low => "Ignore",
        }
    }

    fn sort_rank(self) -> u8 {
        match self {
            Self::High => 0,
            Self::Normal => 1,
            Self::Low => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SenderPriorityFilter {
    All,
    High,
    Normal,
    Low,
}

impl SenderPriorityFilter {
    fn from_query(raw: Option<&str>) -> Self {
        match raw.map(str::trim).filter(|value| !value.is_empty()) {
            Some("all") => Self::All,
            Some("high") => Self::High,
            Some("normal") => Self::Normal,
            Some("low") => Self::Low,
            _ => Self::All,
        }
    }

    fn as_query_value(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::High => "high",
            Self::Normal => "normal",
            Self::Low => "low",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::All => "Any importance",
            Self::High => "Important",
            Self::Normal => "Normal",
            Self::Low => "Ignore",
        }
    }

    fn matches(self, priority: SenderPriority) -> bool {
        match self {
            Self::All => true,
            Self::High => priority == SenderPriority::High,
            Self::Normal => priority == SenderPriority::Normal,
            Self::Low => priority == SenderPriority::Low,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SenderRuleKind {
    Address,
    Domain,
}

impl SenderRuleKind {
    fn from_form(value: &str) -> Option<Self> {
        match value.trim() {
            "address" => Some(Self::Address),
            "domain" => Some(Self::Domain),
            _ => None,
        }
    }

    fn as_stored_value(self) -> &'static str {
        match self {
            Self::Address => "address",
            Self::Domain => "domain",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SenderIdentity {
    address: String,
    domain: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SenderDisplay {
    primary: String,
    secondary: Option<String>,
}

#[derive(Clone, Debug)]
struct SenderPriorityRule {
    value: String,
    priority: SenderPriority,
}

#[derive(Clone, Debug, Default)]
struct SenderPriorityRules {
    addresses: HashMap<String, SenderPriority>,
    domains: HashMap<String, SenderPriority>,
}

#[derive(Clone, Debug)]
struct SenderPriorityView {
    identity: Option<SenderIdentity>,
    priority: SenderPriority,
    address_rule: Option<SenderPriority>,
    #[allow(dead_code)]
    domain_rule: Option<SenderPriority>,
}

impl SenderPriorityRules {
    fn view_for_sender(&self, sender: &str) -> SenderPriorityView {
        let identity = sender_identity_from_header(sender);
        let (address_rule, domain_rule) = identity
            .as_ref()
            .map(|sender| {
                (
                    self.addresses.get(&sender.address).copied(),
                    self.domains.get(&sender.domain).copied(),
                )
            })
            .unwrap_or((None, None));
        let priority = address_rule
            .or(domain_rule)
            .unwrap_or(SenderPriority::Normal);
        SenderPriorityView {
            identity,
            priority,
            address_rule,
            domain_rule,
        }
    }
}

#[derive(Debug)]
struct AttachmentListViewState {
    priority_filter: SenderPriorityFilter,
    page: usize,
    result_count: usize,
    has_previous_page: bool,
    has_next_page: bool,
    empty_message: Option<String>,
    base_query: String,
}

#[derive(Debug)]
struct AttachmentPageData {
    accounts: Vec<AccountRecord>,
    selected_account_id: Option<i64>,
    presets: Vec<AttachmentFilterPreset>,
    filters: AttachmentSearchFilters,
    include_inline: bool,
    include_inline_images: bool,
    show_mime_details: bool,
    download_subfolder: String,
    items: Vec<AttachmentListItem>,
    state: AttachmentListViewState,
}

struct AttachmentBaseQuery<'a> {
    filters: &'a AttachmentSearchFilters,
    selected_account_id: Option<i64>,
    priority_filter: SenderPriorityFilter,
    include_inline: bool,
    include_inline_images: bool,
    show_mime_details: bool,
    download_subfolder: &'a str,
}

#[derive(Debug, Clone)]
struct AttachmentFilterPreset {
    id: i64,
    name: String,
    query: String,
}

#[tokio::main]
async fn main() {
    let config = load_config();
    ensure_app_layout(&config).expect("failed to prepare mail archive ui paths");
    initialize_db(&config).expect("failed to initialize sqlite schema");
    reconcile_interrupted_syncs(&config).expect("failed to reconcile interrupted sync state");
    install_filesystem_sandbox(&config);

    let args = env::args().collect::<Vec<_>>();
    if let Some(mode) = args.get(1).map(String::as_str) {
        if mode == "sync-due" {
            let had_errors = sync_due(&config).expect("mail archive sync-due failed");
            if had_errors {
                std::process::exit(1);
            }
            return;
        } else if mode == "verify-attachments" {
            let repair = args.iter().any(|arg| arg == "--repair");
            let report_path = args
                .windows(2)
                .find(|window| window[0] == "--report")
                .map(|window| FsPath::new(window[1].as_str()));
            let report = verify_attachment_archive(&config, repair, report_path)
                .expect("mail archive attachment verification failed");
            println!(
                "{}",
                serde_json::to_string_pretty(&report)
                    .expect("failed to encode attachment verification report")
            );
            if report.has_errors() {
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
        .route("/sender-priorities", post(upsert_sender_priority))
        .route("/sender-priorities/clear", post(clear_sender_priority))
        .route("/attachments", get(attachments_page))
        .route("/attachments/presets", post(save_attachment_filter_preset))
        .route(
            "/attachments/presets/delete",
            post(delete_attachment_filter_preset),
        )
        .route("/attachments/refresh", post(refresh_attachments))
        .route(
            "/attachments/{attachment_key}/download/browser",
            post(download_attachment_browser),
        )
        .route("/attachments/download", post(download_attachments_zip))
        .route(
            "/attachments/send-paperless",
            post(send_attachments_paperless),
        )
        .route("/healthz", get(healthz))
        .route("/static/frontend/{*asset_path}", get(frontend_asset))
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
            };

            html_response(render_account_form(
                &identity,
                "Add Mailbox",
                "Add a mailbox",
                "Connect a mailbox so saved messages and attachments can be searched later.",
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
                "Edit mailbox",
                "Leave the app password blank to keep the current saved password.",
                &format!("/accounts/{}/update", account.id),
                "Save changes",
                false,
                &form,
                Some("Leave blank to keep the current saved password."),
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
            "Add a mailbox",
            "Connect a mailbox so saved messages and attachments can be searched later.",
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
            "Edit mailbox",
            "Leave the app password blank to keep the current saved password.",
            &format!("/accounts/{account_id}/update"),
            "Save changes",
            false,
            &form,
            Some("Leave blank to keep the current saved password."),
            Some(&error),
        )),
    }
}

async fn toggle_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    match toggle_sync_for_user(&state.config, &identity.username, account_id) {
        Ok(true) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Automatic updates enabled",
            Some(account_id),
        ),
        Ok(false) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Automatic updates disabled",
            Some(account_id),
        ),
        Ok(true) => redirect_response("/?flash=Automatic+updates+enabled"),
        Ok(false) => redirect_response("/?flash=Automatic+updates+disabled"),
        Err(error) if wants_json => {
            action_json_response(StatusCode::BAD_REQUEST, false, &error, Some(account_id))
        }
        Err(error) => server_error_page("Failed to update schedule", &error, Some(&identity)),
    }
}

async fn sync_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        if wants_json {
            return action_json_response(StatusCode::NOT_FOUND, false, &error, Some(account_id));
        }
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    tokio::task::spawn_blocking(move || {
        let _ = run_account_action_for_user(&config, &username, account_id, AccountAction::Sync);
    });

    if wants_json {
        action_json_response(
            StatusCode::ACCEPTED,
            true,
            "Mailbox update started",
            Some(account_id),
        )
    } else {
        redirect_response("/?flash=Mailbox+update+started")
    }
}

async fn reindex_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        if wants_json {
            return action_json_response(StatusCode::NOT_FOUND, false, &error, Some(account_id));
        }
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    tokio::task::spawn_blocking(move || {
        let _ = run_account_action_for_user(&config, &username, account_id, AccountAction::Reindex);
    });

    if wants_json {
        action_json_response(
            StatusCode::ACCEPTED,
            true,
            "Search repair started",
            Some(account_id),
        )
    } else {
        redirect_response("/?flash=Search+repair+started")
    }
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
    let has_explicit_search = uri.query().is_some_and(has_explicit_search_param);
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

    let saved_query = if has_params {
        String::new()
    } else {
        preferences.last_query.unwrap_or_default()
    };
    let filters = message_filters_from_search_params(&params, saved_query);
    let priority_filter = if has_params {
        SenderPriorityFilter::from_query(params.priority.as_deref())
    } else {
        SenderPriorityFilter::All
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
            filters.q.trim(),
            selected_account_id,
        ) {
            return server_error_page("Failed to save search preferences", &error, Some(&identity));
        }
    }

    let should_execute_search = has_params
        && (message_filters_have_terms(&filters) || priority_filter != SenderPriorityFilter::All);
    let results = if should_execute_search {
        let config = state.config.clone();
        let username = identity.username.clone();
        let filters_clone = filters.clone();
        match tokio::task::spawn_blocking(move || {
            let mut results = search_mail(
                &config,
                &username,
                selected_account_id,
                filters_clone,
                priority_filter,
            )?;
            results.sort_by(|left, right| {
                left.sender_priority
                    .priority
                    .sort_rank()
                    .cmp(&right.sender_priority.priority.sort_rank())
                    .then(right.timestamp.cmp(&left.timestamp))
            });
            Ok::<_, String>(results)
        })
        .await
        {
            Ok(Ok(results)) => results,
            Ok(Err(error)) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &filters,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some(error),
                        priority_filter,
                    },
                    params.flash.as_deref(),
                    params.error.as_deref(),
                ))
            }
            Err(_) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &filters,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some("Search task failed".to_string()),
                        priority_filter,
                    },
                    params.flash.as_deref(),
                    params.error.as_deref(),
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

    let empty_message = if !has_explicit_search {
        if has_params && priority_filter != SenderPriorityFilter::All {
            if results.is_empty() {
                Some("No messages matched the selected sender priority.".to_string())
            } else {
                None
            }
        } else {
            Some(
                "Saved search defaults are filled in below. Submit a search when ready."
                    .to_string(),
            )
        }
    } else if !message_filters_have_terms(&filters) && priority_filter == SenderPriorityFilter::All
    {
        Some("Enter a word, name, or email address to search saved mail.".to_string())
    } else if selected_accounts.is_empty() {
        Some("No mailbox is available for this search filter.".to_string())
    } else if indexed_selected_accounts == 0 {
        Some(
            "This mailbox is not ready to search yet. Update it from the dashboard first."
                .to_string(),
        )
    } else if results.is_empty() {
        Some("No saved messages matched the current filters.".to_string())
    } else {
        None
    };

    let view_state = SearchViewState {
        submitted: has_params,
        result_count: results.len(),
        empty_message,
        priority_filter,
    };

    html_response(render_search(
        &identity,
        &accounts,
        &filters,
        selected_account_id,
        &results,
        &view_state,
        params.flash.as_deref(),
        params.error.as_deref(),
    ))
}

async fn attachments_page(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<AttachmentListParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let params_for_task = params.clone();
    let data = match tokio::task::spawn_blocking(move || {
        load_attachment_page_data(&config, &username, &params_for_task)
    })
    .await
    {
        Ok(Ok(data)) => data,
        Ok(Err(error)) => {
            return server_error_page("Failed to load attachments", &error, Some(&identity))
        }
        Err(_) => {
            return server_error_page(
                "Failed to load attachments",
                "Attachment task failed",
                Some(&identity),
            )
        }
    };

    html_response(render_attachments_page(
        &identity,
        &data,
        params.flash.as_deref(),
        params.error.as_deref(),
    ))
}

async fn save_attachment_filter_preset(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPresetSaveForm>,
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
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        save_attachment_filter_preset_for_user(&config, &username, &form)
    })
    .await;

    match result {
        Ok(Ok(preset)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(&format!("Saved attachment filter preset {}", preset.name)),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment preset task failed"),
        )),
    }
}

async fn delete_attachment_filter_preset(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPresetDeleteForm>,
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
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        delete_attachment_filter_preset_for_user(&config, &username, form.preset_id)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some("Attachment filter preset deleted"),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment preset delete task failed"),
        )),
    }
}

async fn upsert_sender_priority(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<SenderPriorityForm>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return priority_change_json_response(status, false, &message, form.return_to.clone())
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return priority_change_json_response(status, false, &message, form.return_to.clone());
        }
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        set_sender_priority_rule(
            &config,
            &username,
            &form.sender_kind,
            &form.sender_value,
            &form.priority,
        )
    })
    .await;

    match result {
        Ok(Ok(Some(rule))) => {
            let message = format!(
                "Marked sender {} as {}",
                rule.value,
                rule.priority.dropdown_label().to_lowercase()
            );
            if wants_json {
                priority_change_json_response(StatusCode::OK, true, &message, return_to)
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    Some(&message),
                    None,
                ))
            }
        }
        Ok(Ok(None)) => {
            let message = "Sender importance cleared";
            if wants_json {
                priority_change_json_response(StatusCode::OK, true, message, return_to)
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    Some(message),
                    None,
                ))
            }
        }
        Ok(Err(error)) => {
            if wants_json {
                priority_change_json_response(
                    priority_error_status(&error),
                    false,
                    &error,
                    return_to,
                )
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&error),
                ))
            }
        }
        Err(_) => {
            let message = "Sender importance task failed";
            if wants_json {
                priority_change_json_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    false,
                    message,
                    return_to,
                )
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(message),
                ))
            }
        }
    }
}

fn request_accepts_json(headers: &HeaderMap) -> bool {
    headers
        .get(ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value
                .split(',')
                .any(|part| part.trim().starts_with("application/json"))
        })
}

fn priority_error_status(error: &str) -> StatusCode {
    if error.starts_with("failed ") {
        StatusCode::INTERNAL_SERVER_ERROR
    } else {
        StatusCode::BAD_REQUEST
    }
}

fn priority_change_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    return_to: Option<String>,
) -> Response {
    json_response(
        status,
        PriorityChangePayload {
            ok,
            message: message.to_string(),
            return_to,
        },
    )
}

fn action_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    account_id: Option<i64>,
) -> Response {
    json_response(
        status,
        ActionPayload {
            ok,
            message: message.to_string(),
            account_id,
        },
    )
}

async fn clear_sender_priority(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<SenderPriorityClearForm>,
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
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        clear_sender_priority_rule(&config, &username, &form.sender_kind, &form.sender_value)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            Some("Sender importance cleared"),
            None,
        )),
        Ok(Err(error)) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some("Sender importance task failed"),
        )),
    }
}

async fn refresh_attachments(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentRefreshForm>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, None)
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, None);
        }
        return auth_error(status, &message);
    }

    let selected_account_id = match parse_optional_query_i64(form.account_id.as_deref()) {
        Ok(value) => value,
        Err(error) if wants_json => {
            return action_json_response(StatusCode::BAD_REQUEST, false, &error, None);
        }
        Err(error) => {
            return redirect_response(&attachments_redirect_location(
                form.return_to.as_deref(),
                None,
                Some(error.as_str()),
            ))
        }
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let result = tokio::task::spawn_blocking(move || {
        refresh_attachment_catalog_for_user(&config, &username, selected_account_id)
    })
    .await;

    match result {
        Ok(Ok(())) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Attachment list refreshed",
            selected_account_id,
        ),
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            Some("Attachment catalog refreshed"),
            None,
        )),
        Ok(Err(error)) if wants_json => {
            action_json_response(StatusCode::BAD_REQUEST, false, &error, selected_account_id)
        }
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) if wants_json => action_json_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            false,
            "Attachment refresh task failed",
            selected_account_id,
        ),
        Err(_) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            None,
            Some("Attachment refresh task failed"),
        )),
    }
}

async fn download_attachment_browser(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(attachment_key): Path<String>,
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
    let payload = match tokio::task::spawn_blocking(move || {
        let (account, message, attachment) =
            load_attachment_for_user(&config, &username, &attachment_key)?;
        let (_dir, attachment_path) =
            resolve_attachment_payload(&config, &account, &message, &attachment)?;
        let bytes = fs::read(&attachment_path).map_err(|error| {
            format!(
                "failed to read extracted attachment {}: {error}",
                attachment_path.display()
            )
        })?;
        Ok::<_, String>((attachment.original_filename, attachment.mime_type, bytes))
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => return server_error_page("Download failed", &error, Some(&identity)),
        Err(_) => {
            return server_error_page(
                "Download failed",
                "Attachment download task failed",
                Some(&identity),
            )
        }
    };

    attachment_download_response(&payload.0, &payload.1, payload.2)
}

async fn download_attachments_zip(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let form = parse_attachment_download_form_body(&body);
    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result =
        tokio::task::spawn_blocking(move || build_attachments_zip(&config, &username, &form)).await;

    match result {
        Ok(Ok(zip_file)) => zip_download_file_response(zip_file).await,
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment ZIP task failed"),
        )),
    }
}

async fn send_attachments_paperless(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let form = parse_attachment_paperless_form_body(&body);
    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        send_attachments_to_paperless(&config, &username, &form.attachment_keys)
    })
    .await;

    match result {
        Ok(Ok(summary)) if summary.sent > 0 => {
            let failure_message = if summary.failures.is_empty() {
                None
            } else {
                Some(summary.failure_message())
            };
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::OK,
                    true,
                    &summary.flash_message(),
                    failure_message.as_deref(),
                    summary.sent_attachment_keys,
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    Some(&summary.flash_message()),
                    failure_message.as_deref(),
                ))
            }
        }
        Ok(Ok(summary)) => {
            let message = summary.failure_message();
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::BAD_REQUEST,
                    false,
                    &message,
                    Some(&message),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&message),
                ))
            }
        }
        Ok(Err(error)) => {
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::BAD_REQUEST,
                    false,
                    &error,
                    Some(&error),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&error),
                ))
            }
        }
        Err(_) => {
            let message = "Paperless handoff task failed";
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    false,
                    message,
                    Some(message),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(message),
                ))
            }
        }
    }
}

fn paperless_handoff_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    error: Option<&str>,
    sent_attachment_keys: Vec<String>,
    return_to: Option<String>,
) -> Response {
    json_response(
        status,
        PaperlessHandoffPayload {
            ok,
            message: message.to_string(),
            error: error.map(ToString::to_string),
            sent_attachment_keys,
            return_to,
        },
    )
}

async fn healthz(State(state): State<AppState>) -> Response {
    let (status, payload) = health_payload(&state.config);
    json_response(status, payload)
}

async fn frontend_asset(State(state): State<AppState>, Path(asset_path): Path<String>) -> Response {
    let root = PathBuf::from(state.config.frontend_dist_dir.as_ref());
    let candidate = root.join(&asset_path);
    let root = match root.canonicalize() {
        Ok(root) => root,
        Err(error) => {
            return html_response_with_status(
                StatusCode::NOT_FOUND,
                format!("frontend dist directory is unavailable: {error}"),
            )
        }
    };
    let candidate = match candidate.canonicalize() {
        Ok(candidate) => candidate,
        Err(_) => {
            return html_response_with_status(
                StatusCode::NOT_FOUND,
                "frontend asset not found".to_string(),
            )
        }
    };
    if candidate == root || !candidate.starts_with(&root) {
        return html_response_with_status(
            StatusCode::NOT_FOUND,
            "frontend asset not found".to_string(),
        );
    }
    match fs::read(&candidate) {
        Ok(bytes) => {
            let mut response = Response::new(Body::from(bytes));
            *response.status_mut() = StatusCode::OK;
            response.headers_mut().insert(
                CONTENT_TYPE,
                HeaderValue::from_static(content_type_for_path(&candidate)),
            );
            harden_response(response)
        }
        Err(_) => html_response_with_status(
            StatusCode::NOT_FOUND,
            "frontend asset not found".to_string(),
        ),
    }
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
    let account_state_root = env::var("MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT")
        .unwrap_or_else(|_| format!("{data_dir}/accounts"));
    let runtime_dir =
        env::var("MAIL_ARCHIVE_UI_RUNTIME_DIR").unwrap_or_else(|_| DEFAULT_RUNTIME_DIR.to_string());
    let lock_dir =
        env::var("MAIL_ARCHIVE_UI_LOCK_DIR").unwrap_or_else(|_| DEFAULT_LOCK_DIR.to_string());
    let paperless_consume_root = env::var("MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let paperless_handoff_staging_root = env::var("MAIL_ARCHIVE_UI_PAPERLESS_HANDOFF_STAGING_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(Arc::<str>::from);
    let visible_mirror_read_group = env::var("MAIL_ARCHIVE_UI_VISIBLE_MIRROR_READ_GROUP")
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
    let frontend_dist_dir = env::var("MAIL_ARCHIVE_UI_FRONTEND_DIST_DIR")
        .unwrap_or_else(|_| DEFAULT_FRONTEND_DIST_DIR.to_string());

    AppConfig {
        address: Arc::<str>::from(address),
        port,
        data_dir: Arc::<str>::from(data_dir),
        store_root: Arc::<str>::from(store_root),
        account_state_root: Arc::<str>::from(account_state_root),
        runtime_dir: Arc::<str>::from(runtime_dir),
        lock_dir: Arc::<str>::from(lock_dir),
        paperless_consume_root,
        paperless_handoff_staging_root,
        visible_mirror_read_group,
        default_tags: Arc::from(default_tags),
        frontend_dist_dir: Arc::<str>::from(frontend_dist_dir),
    }
}

fn ensure_app_layout(config: &AppConfig) -> Result<(), String> {
    for directory in [
        config.data_dir.as_ref(),
        config.account_state_root.as_ref(),
        config.runtime_dir.as_ref(),
        config.lock_dir.as_ref(),
    ] {
        fs::create_dir_all(directory)
            .map_err(|error| format!("failed to create {directory}: {error}"))?;
    }

    Ok(())
}

fn install_filesystem_sandbox(config: &AppConfig) {
    #[cfg(target_os = "linux")]
    match restrict_filesystem(config) {
        Ok(status) => log_landlock_status(status),
        Err(error) => eprintln!("mail-archive-ui Landlock sandbox disabled: {error}"),
    }
}

#[cfg(not(target_os = "linux"))]
fn install_filesystem_sandbox(_config: &AppConfig) {}

#[cfg(target_os = "linux")]
fn restrict_filesystem(config: &AppConfig) -> Result<RestrictionStatus, String> {
    let abi = ABI::V6;
    let read_access = AccessFs::from_read(abi) | AccessFs::Execute;
    let write_access = AccessFs::from_all(abi);
    let (read_only_roots, read_write_roots) = landlock_roots(config);

    Ruleset::default()
        .handle_access(AccessFs::from_all(abi))
        .map_err(|error| format!("failed to configure Landlock access set: {error}"))?
        .create()
        .map_err(|error| format!("failed to create Landlock ruleset: {error}"))?
        .add_rules(path_beneath_rules(
            read_only_roots.iter().map(PathBuf::as_path),
            read_access,
        ))
        .map_err(|error| format!("failed to add read-only Landlock rules: {error}"))?
        .add_rules(path_beneath_rules(
            read_write_roots.iter().map(PathBuf::as_path),
            write_access,
        ))
        .map_err(|error| format!("failed to add read-write Landlock rules: {error}"))?
        .restrict_self()
        .map_err(|error| format!("failed to apply Landlock sandbox: {error}"))
}

#[cfg(target_os = "linux")]
fn log_landlock_status(status: RestrictionStatus) {
    let label = match status.ruleset {
        RulesetStatus::FullyEnforced => "fully enforced",
        RulesetStatus::PartiallyEnforced => "partially enforced",
        RulesetStatus::NotEnforced => "not enforced",
    };
    eprintln!("mail-archive-ui Landlock sandbox: {label}");
}

fn landlock_roots(config: &AppConfig) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let read_only_roots = dedupe_paths([
        Some(PathBuf::from("/nix/store")),
        Some(PathBuf::from("/etc")),
        Some(PathBuf::from("/run/current-system")),
        Some(PathBuf::from("/run/systemd/resolve")),
        Some(PathBuf::from("/dev/null")),
        Some(PathBuf::from("/dev/random")),
        Some(PathBuf::from("/dev/urandom")),
    ]);
    let read_write_roots = dedupe_paths([
        Some(PathBuf::from(config.data_dir.as_ref())),
        Some(PathBuf::from(config.store_root.as_ref())),
        Some(PathBuf::from(config.account_state_root.as_ref())),
        Some(PathBuf::from(config.runtime_dir.as_ref())),
        Some(PathBuf::from(config.lock_dir.as_ref())),
        config.paperless_consume_root.as_deref().map(PathBuf::from),
        config
            .paperless_handoff_staging_root
            .as_deref()
            .map(PathBuf::from),
    ]);

    (read_only_roots, read_write_roots)
}

fn dedupe_paths<const N: usize>(paths: [Option<PathBuf>; N]) -> Vec<PathBuf> {
    let mut deduped = Vec::new();
    for path in paths.into_iter().flatten() {
        if deduped.iter().any(|existing| existing == &path) {
            continue;
        }
        deduped.push(path);
    }
    deduped
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
                last_sync_error TEXT,
                last_sync_phase TEXT,
                last_sync_code TEXT,
                last_sync_summary TEXT,
                last_sync_detail TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts (username);

            CREATE TABLE IF NOT EXISTS search_preferences (
                username TEXT PRIMARY KEY,
                last_query TEXT,
                default_account_id INTEGER
            );

            CREATE TABLE IF NOT EXISTS attachment_messages (
                account_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                message_relpath TEXT NOT NULL,
                message_mtime INTEGER NOT NULL,
                message_size INTEGER NOT NULL,
                subject TEXT NOT NULL,
                sender TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                last_scanned_at TEXT NOT NULL,
                has_attachments INTEGER NOT NULL,
                PRIMARY KEY (account_id, message_key),
                UNIQUE (account_id, message_relpath)
            );

            CREATE INDEX IF NOT EXISTS idx_attachment_messages_relpath
            ON attachment_messages (account_id, message_relpath);

            CREATE TABLE IF NOT EXISTS attachment_catalog (
                attachment_key TEXT PRIMARY KEY,
                account_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                attachment_index INTEGER NOT NULL,
                attachment_sha256 TEXT NOT NULL,
                original_filename TEXT NOT NULL,
                safe_filename TEXT NOT NULL,
                extension TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                is_inline_artifact INTEGER NOT NULL,
                blob_relpath TEXT,
                source_message_sha256 TEXT,
                last_verified_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_attachment_catalog_message
            ON attachment_catalog (account_id, message_key);

            CREATE INDEX IF NOT EXISTS idx_attachment_catalog_filters
            ON attachment_catalog (account_id, extension, is_inline_artifact, size_bytes);

            CREATE INDEX IF NOT EXISTS idx_attachment_catalog_sha
            ON attachment_catalog (account_id, attachment_sha256);

            CREATE TABLE IF NOT EXISTS account_progress_snapshots (
                account_id INTEGER PRIMARY KEY,
                archived_message_count INTEGER NOT NULL,
                indexed_message_count INTEGER NOT NULL,
                pending_index_count INTEGER NOT NULL,
                index_coverage_percent INTEGER NOT NULL,
                archive_file_count INTEGER NOT NULL,
                overlap_file_count INTEGER NOT NULL,
                last_computed_at TEXT NOT NULL,
                source_sync_finished_at TEXT,
                snapshot_status TEXT NOT NULL,
                snapshot_note TEXT
            );

            CREATE TABLE IF NOT EXISTS message_catalog (
                account_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                canonical_hidden_relpath TEXT NOT NULL,
                subject TEXT NOT NULL,
                sender TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                message_sha256 TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                PRIMARY KEY (account_id, message_key)
            );

            CREATE INDEX IF NOT EXISTS idx_message_catalog_timestamp
            ON message_catalog (account_id, timestamp DESC);

            CREATE TABLE IF NOT EXISTS message_mailbox_instances (
                account_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                raw_mailbox_path TEXT NOT NULL,
                visible_relpath TEXT NOT NULL,
                hidden_relpath TEXT NOT NULL,
                account_slug TEXT NOT NULL,
                mailbox_slug TEXT NOT NULL,
                filename TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                PRIMARY KEY (account_id, message_key, raw_mailbox_path)
            );

            CREATE INDEX IF NOT EXISTS idx_message_mailbox_visible_relpath
            ON message_mailbox_instances (account_id, visible_relpath);

            CREATE TABLE IF NOT EXISTS sender_priorities (
                username TEXT NOT NULL,
                sender_kind TEXT NOT NULL CHECK(sender_kind IN ('address', 'domain')),
                sender_value TEXT NOT NULL,
                priority TEXT NOT NULL CHECK(priority IN ('high', 'low')),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (username, sender_kind, sender_value)
            );

            CREATE INDEX IF NOT EXISTS idx_sender_priorities_user_priority
            ON sender_priorities (username, priority, sender_kind, sender_value);

            CREATE TABLE IF NOT EXISTS attachment_filter_presets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                name TEXT NOT NULL,
                query TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE (username, name)
            );

            CREATE INDEX IF NOT EXISTS idx_attachment_filter_presets_user
            ON attachment_filter_presets (username, name);

            CREATE TABLE IF NOT EXISTS attachment_paperless_handoffs (
                username TEXT NOT NULL,
                attachment_key TEXT NOT NULL,
                attachment_sha256 TEXT NOT NULL,
                original_filename TEXT NOT NULL,
                consume_filename TEXT NOT NULL,
                sent_at TEXT NOT NULL,
                PRIMARY KEY (username, attachment_key)
            );
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
    connection
        .execute_batch(
            r#"
            DROP TABLE IF EXISTS attachment_actions;
            DROP TABLE IF EXISTS paperless_attachment_exports;
            DROP TABLE IF EXISTS deleted_message_attachments;
            DROP TABLE IF EXISTS deleted_messages;
            "#,
        )
        .map_err(|error| format!("failed to drop legacy app-local state: {error}"))?;
    for column in [
        "paperless_enabled",
        "paperless_last_export_started_at",
        "paperless_last_export_finished_at",
        "paperless_last_export_status",
        "paperless_last_export_error",
    ] {
        drop_account_column_if_exists(&connection, column)?;
    }

    for (table, column, sql) in [
        (
            "attachment_catalog",
            "blob_relpath",
            "ALTER TABLE attachment_catalog ADD COLUMN blob_relpath TEXT",
        ),
        (
            "attachment_catalog",
            "source_message_sha256",
            "ALTER TABLE attachment_catalog ADD COLUMN source_message_sha256 TEXT",
        ),
        (
            "attachment_catalog",
            "last_verified_at",
            "ALTER TABLE attachment_catalog ADD COLUMN last_verified_at TEXT",
        ),
    ] {
        ensure_table_column(&connection, table, column, sql)?;
    }

    Ok(())
}

fn ensure_table_column(
    connection: &Connection,
    table: &str,
    column: &str,
    sql: &str,
) -> Result<(), String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| format!("failed to inspect {table} schema: {error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("failed to inspect {table} columns: {error}"))?;

    for row in rows {
        if row.map_err(|error| format!("failed to decode {table} column: {error}"))? == column {
            return Ok(());
        }
    }

    connection
        .execute(sql, [])
        .map(|_| ())
        .map_err(|error| format!("failed to add {table}.{column}: {error}"))
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

fn drop_account_column_if_exists(connection: &Connection, column: &str) -> Result<(), String> {
    let mut statement = connection
        .prepare("PRAGMA table_info(accounts)")
        .map_err(|error| format!("failed to inspect accounts schema: {error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("failed to inspect accounts columns: {error}"))?;
    let mut exists = false;
    for row in rows {
        if row.map_err(|error| format!("failed to decode accounts column: {error}"))? == column {
            exists = true;
            break;
        }
    }
    drop(statement);

    if exists {
        connection
            .execute(&format!("ALTER TABLE accounts DROP COLUMN {column}"), [])
            .map_err(|error| format!("failed to drop legacy accounts column {column}: {error}"))?;
    }
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
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
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
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail
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

fn list_all_accounts(config: &AppConfig) -> Result<Vec<AccountRecord>, String> {
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
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail
            FROM accounts
            ORDER BY username ASC, display_name COLLATE NOCASE ASC, id ASC
            "#,
        )
        .map_err(|error| format!("failed to prepare account inventory query: {error}"))?;
    let rows = statement
        .query_map([], map_account_row)
        .map_err(|error| format!("failed to query account inventory: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode account inventory: {error}"))
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
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail
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

fn load_sender_priority_rules(
    config: &AppConfig,
    username: &str,
) -> Result<SenderPriorityRules, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT sender_kind, sender_value, priority
            FROM sender_priorities
            WHERE username = ?1
            "#,
        )
        .map_err(|error| format!("failed to prepare sender priority query: {error}"))?;
    let rows = statement
        .query_map(params![username], |row| {
            let kind: String = row.get(0)?;
            let value: String = row.get(1)?;
            let priority: String = row.get(2)?;
            Ok((kind, value, priority))
        })
        .map_err(|error| format!("failed to query sender priorities: {error}"))?;

    let mut rules = SenderPriorityRules::default();
    for row in rows {
        let (kind, value, priority) =
            row.map_err(|error| format!("failed to decode sender priority: {error}"))?;
        let Some(priority) = SenderPriority::from_stored(&priority) else {
            continue;
        };
        match kind.as_str() {
            "address" => {
                rules.addresses.insert(value, priority);
            }
            "domain" => {
                rules.domains.insert(value, priority);
            }
            _ => {}
        }
    }
    Ok(rules)
}

fn upsert_sender_priority_rule(
    config: &AppConfig,
    username: &str,
    raw_kind: &str,
    raw_value: &str,
    raw_priority: &str,
) -> Result<SenderPriorityRule, String> {
    let kind = SenderRuleKind::from_form(raw_kind)
        .ok_or_else(|| "Sender rule kind must be address or domain".to_string())?;
    let value = normalize_sender_rule_value(kind, raw_value)?;
    let priority = SenderPriority::from_stored(raw_priority.trim())
        .ok_or_else(|| "Sender importance must be important or ignored".to_string())?;
    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO sender_priorities (
                username,
                sender_kind,
                sender_value,
                priority,
                created_at,
                updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?5)
            ON CONFLICT(username, sender_kind, sender_value) DO UPDATE SET
                priority = excluded.priority,
                updated_at = excluded.updated_at
            "#,
            params![
                username,
                kind.as_stored_value(),
                value,
                priority.as_stored_value(),
                now,
            ],
        )
        .map_err(|error| format!("failed to save sender priority: {error}"))?;
    Ok(SenderPriorityRule { value, priority })
}

fn set_sender_priority_rule(
    config: &AppConfig,
    username: &str,
    raw_kind: &str,
    raw_value: &str,
    raw_priority: &str,
) -> Result<Option<SenderPriorityRule>, String> {
    if raw_priority.trim() == SenderPriority::Normal.as_stored_value() {
        clear_sender_priority_rule(config, username, raw_kind, raw_value)?;
        Ok(None)
    } else {
        upsert_sender_priority_rule(config, username, raw_kind, raw_value, raw_priority).map(Some)
    }
}

fn clear_sender_priority_rule(
    config: &AppConfig,
    username: &str,
    raw_kind: &str,
    raw_value: &str,
) -> Result<(), String> {
    let kind = SenderRuleKind::from_form(raw_kind)
        .ok_or_else(|| "Sender rule kind must be address or domain".to_string())?;
    let value = normalize_sender_rule_value(kind, raw_value)?;
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            DELETE FROM sender_priorities
            WHERE username = ?1
              AND sender_kind = ?2
              AND sender_value = ?3
            "#,
            params![username, kind.as_stored_value(), value],
        )
        .map_err(|error| format!("failed to clear sender priority: {error}"))?;
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
        last_sync_phase: row.get(17)?,
        last_sync_code: row.get(18)?,
        last_sync_summary: row.get(19)?,
        last_sync_detail: row.get(20)?,
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
                last_sync_error,
                last_sync_phase,
                last_sync_code,
                last_sync_summary,
                last_sync_detail
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
                let secret = decrypt_secret(&encryption_key, &account.encrypted_secret).map_err(
                    |error| {
                        preflight_sync_diagnostic(
                            "secret_decrypt_failed",
                            "Mailbox sync could not unlock the stored mailbox credential.",
                            error,
                        )
                    },
                )?;
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
                let temp_config =
                    write_temp_mbsyncrc(config, account, &account_paths, &temp_secret.path)
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
                    &[(
                        "HOME",
                        account_paths.account_state_root.to_string_lossy().as_ref(),
                    )],
                )?;

                run_sync_command(
                    SyncPhase::Index,
                    "index_failed",
                    "Mail download completed, but indexing failed. Archived messages may be missing from search until reindex succeeds.",
                    "notmuch",
                    &["new"],
                    &[
                        (
                            "HOME",
                            account_paths.account_state_root.to_string_lossy().as_ref(),
                        ),
                        (
                            "NOTMUCH_CONFIG",
                            account_paths.notmuch_config.to_string_lossy().as_ref(),
                        ),
                    ],
                )?;
                rebuild_message_catalog_and_visible_mailboxes(config, account).map_err(
                    |error| {
                        SyncDiagnostic::new(
                        SyncPhase::Reconcile,
                        "mailbox_mirror_rebuild_failed",
                        "Mail sync completed, but the visible mailbox mirror could not be rebuilt.",
                        error,
                    )
                    },
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
                    "Mailbox reindex failed. Archived messages may be missing from search until reindex succeeds.",
                    "notmuch",
                    &["new"],
                    &[
                        (
                            "HOME",
                            account_paths.account_state_root.to_string_lossy().as_ref(),
                        ),
                        (
                            "NOTMUCH_CONFIG",
                            account_paths.notmuch_config.to_string_lossy().as_ref(),
                        ),
                    ],
                )?;
                rebuild_message_catalog_and_visible_mailboxes(config, account).map_err(|error| {
                    SyncDiagnostic::new(
                        SyncPhase::Reconcile,
                        "mailbox_mirror_rebuild_failed",
                        "Mailbox reindex completed, but the visible mailbox mirror could not be rebuilt.",
                        error,
                    )
                })?;
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
            if let Err(error) = refresh_attachment_catalog(config, account) {
                eprintln!(
                    "mail-archive-ui attachment refresh failed username={} account_id={} detail={}",
                    account.username, account.id, error
                );
            }
            Ok(())
        }
        Err(error) => {
            update_sync_finished(config, account.id, "error", Some(&error)).map_err(
                |db_error| {
                    preflight_sync_diagnostic(
                        "sync_state_update_failed",
                        "Mailbox sync failed and the diagnostic state could not be saved.",
                        db_error,
                    )
                },
            )?;
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

    let emails_root = store_root.join(&account.username).join("_Emails");
    let visible_emails_root = emails_root.clone();
    let hidden_sync_root = emails_root
        .join(".internal-sync")
        .join(account_hidden_root_name(account));
    let maildir = hidden_sync_root.join("maildir");
    let attachment_blob_root = hidden_sync_root
        .join("attachments")
        .join("blobs")
        .join("sha256");
    let export_root = hidden_sync_root.join("exports");
    let account_state_root = PathBuf::from(config.account_state_root.as_ref())
        .join(&account.username)
        .join(account.id.to_string());
    let sync_state_dir = account_state_root.join("mbsync-state");
    let notmuch_config = account_state_root.join("notmuch-config");
    let notmuch_db_root = account_state_root.join("notmuch-db");

    for directory in [
        &emails_root,
        &visible_emails_root,
        hidden_sync_root.parent().unwrap_or(&hidden_sync_root),
        &hidden_sync_root,
        &maildir,
        &attachment_blob_root,
        &export_root,
        &account_state_root,
    ] {
        fs::create_dir_all(directory)
            .map_err(|error| format!("failed to create {}: {error}", directory.display()))?;
    }

    let account_paths = AccountPaths {
        emails_root,
        visible_emails_root,
        hidden_sync_root,
        maildir,
        attachment_blob_root,
        export_root,
        account_state_root,
        notmuch_config,
        sync_state_dir,
        notmuch_db_root,
    };

    fs::create_dir_all(&account_paths.sync_state_dir).map_err(|error| {
        format!(
            "failed to create {}: {error}",
            account_paths.sync_state_dir.display()
        )
    })?;

    Ok(account_paths)
}

fn slugify_component(raw: &str, fallback: &str) -> String {
    let mut slug = String::new();
    let mut last_was_dash = false;
    for character in raw.chars() {
        let lowered = character.to_ascii_lowercase();
        if lowered.is_ascii_alphanumeric() {
            slug.push(lowered);
            last_was_dash = false;
        } else if !last_was_dash {
            slug.push('-');
            last_was_dash = true;
        }
    }
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        fallback.to_string()
    } else {
        slug
    }
}

fn account_hidden_root_name(account: &AccountRecord) -> String {
    format!(
        "{}--{}",
        slugify_component(&account.display_name, "mailbox"),
        account.id
    )
}

fn account_notmuch_db_exists(account_paths: &AccountPaths) -> bool {
    account_paths.notmuch_db_root.exists()
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
        "[database]\nmail_root={}\npath={}\n\n[user]\nname={}\nprimary_email={}\n\n[new]\ntags={}\nignore=\n\n[search]\nexclude_tags=\n\n[index]\nas_text={}\n\n[maildir]\nsynchronize_flags=true\n",
        account_paths.maildir.display(),
        account_paths.notmuch_db_root.display(),
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
        account_paths.sync_state_dir.join("state").display()
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

    Err(command_sync_diagnostic(
        phase, code, summary, command, &output,
    ))
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
        account
            .last_sync_detail
            .as_deref()
            .or(account.last_sync_error.as_deref()),
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

fn extract_message_attachments(
    message_path: &FsPath,
    output_dir: &FsPath,
) -> Result<Vec<ExtractedAttachment>, String> {
    if let Ok(extracted) = extract_message_attachments_with_mailparse(message_path, output_dir) {
        if !extracted.is_empty() {
            return Ok(extracted);
        }
    }

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
    )?;
    collect_regular_files(output_dir)?
        .into_iter()
        .map(|path| {
            let original_filename = path
                .file_name()
                .and_then(|value| value.to_str())
                .map(ToString::to_string)
                .unwrap_or_else(|| "attachment".to_string());
            Ok(ExtractedAttachment {
                is_inline_image: false,
                path,
                original_filename,
            })
        })
        .collect()
}

fn extract_message_attachments_with_mailparse(
    message_path: &FsPath,
    output_dir: &FsPath,
) -> Result<Vec<ExtractedAttachment>, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let parsed = mailparse::parse_mail(&bytes).map_err(|error| {
        format!(
            "failed to parse MIME message {}: {error}",
            message_path.display()
        )
    })?;
    let mut attachments = Vec::new();
    let mut used_names = HashMap::<String, usize>::new();

    for (index, part) in parsed.parts().enumerate() {
        if !part.subparts.is_empty() {
            continue;
        }
        let disposition_header = part.headers.get_first_value("Content-Disposition");
        let disposition = part.get_content_disposition();
        let content_id = part.headers.get_first_value("Content-ID");
        let filename = disposition
            .params
            .get("filename")
            .or_else(|| part.ctype.params.get("name"))
            .cloned();
        let is_attachment = matches!(disposition.disposition, DispositionType::Attachment);
        let is_inline_image = part.ctype.mimetype.starts_with("image/")
            && matches!(disposition.disposition, DispositionType::Inline)
            && (disposition_header.is_some() || content_id.is_some());
        if !is_attachment && filename.is_none() && !is_inline_image {
            continue;
        }

        let fallback = if is_inline_image {
            inline_image_fallback_name(index, &part.ctype.mimetype)
        } else {
            format!("attachment-{index}")
        };
        let original_filename = filename
            .map(|value| filename_component(&value, &fallback))
            .unwrap_or(fallback);
        let file_name = unique_zip_entry_name(
            filename_component(&original_filename, "attachment"),
            &mut used_names,
        );
        let output_path = output_dir.join(file_name);
        let body = part.get_body_raw().map_err(|error| {
            format!(
                "failed to decode MIME attachment {} from {}: {error}",
                original_filename,
                message_path.display()
            )
        })?;
        write_private_file(&output_path, &body)?;
        attachments.push(ExtractedAttachment {
            path: output_path,
            original_filename,
            is_inline_image,
        });
    }

    Ok(attachments)
}

fn inline_image_fallback_name(index: usize, mime_type: &str) -> String {
    let extension = match mime_type {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/tiff" => "tiff",
        "image/bmp" => "bmp",
        _ => "img",
    };
    format!("inline-image-{index}.{extension}")
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

fn read_message_metadata(message_path: &FsPath) -> Result<MessageMetadata, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let normalized_message_id =
        decoded_header_value(&bytes, "message-id").and_then(normalize_message_id);
    let subject = decoded_header_value(&bytes, "subject").unwrap_or_else(|| "(no subject)".into());
    let from = decoded_header_value(&bytes, "from").unwrap_or_else(|| "Unknown sender".into());
    let timestamp = decoded_header_value(&bytes, "date")
        .and_then(|value| parse_message_timestamp(&value))
        .unwrap_or_else(|| {
            fs::metadata(message_path)
                .ok()
                .and_then(|metadata| DateTime::<Utc>::from_timestamp(metadata.mtime(), 0))
                .map(|value| value.timestamp())
                .unwrap_or_default()
        });
    Ok(MessageMetadata {
        message_sha256: normalized_message_id.is_none().then(|| sha256_hex(&bytes)),
        normalized_message_id,
        subject,
        from,
        timestamp,
    })
}

fn decoded_header_value(message_bytes: &[u8], target_name: &str) -> Option<String> {
    mailparse::parse_mail(message_bytes)
        .ok()
        .and_then(|message| message.headers.get_first_value(target_name))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn sender_identity_from_header(raw_sender: &str) -> Option<SenderIdentity> {
    mailparse::addrparse(raw_sender)
        .ok()
        .and_then(|addresses| {
            addresses.iter().find_map(|address| match address {
                MailAddr::Single(single) => normalize_sender_address(&single.addr),
                MailAddr::Group(group) => group
                    .addrs
                    .first()
                    .and_then(|single| normalize_sender_address(&single.addr)),
            })
        })
        .or_else(|| fallback_sender_identity(raw_sender))
}

fn sender_display_from_header(raw_sender: &str) -> SenderDisplay {
    if let Some(display) = mailparse::addrparse(raw_sender).ok().and_then(|addresses| {
        addresses.iter().find_map(|address| match address {
            MailAddr::Single(single) => {
                let email = clean_sender_display_part(&single.addr);
                if email.is_empty() {
                    return None;
                }
                Some(sender_display_from_parts(
                    single.display_name.as_deref(),
                    email,
                ))
            }
            MailAddr::Group(group) => group.addrs.first().and_then(|single| {
                let email = clean_sender_display_part(&single.addr);
                if email.is_empty() {
                    return None;
                }
                Some(sender_display_from_parts(
                    single.display_name.as_deref(),
                    email,
                ))
            }),
        })
    }) {
        return display;
    }

    if let Some(identity) = fallback_sender_identity(raw_sender) {
        return SenderDisplay {
            primary: identity.address,
            secondary: None,
        };
    }

    SenderDisplay {
        primary: clean_sender_display_part(raw_sender),
        secondary: None,
    }
}

fn sender_display_from_parts(raw_name: Option<&str>, email: String) -> SenderDisplay {
    match raw_name
        .map(clean_sender_display_part)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case(&email))
    {
        Some(name) => SenderDisplay {
            primary: name,
            secondary: Some(email),
        },
        None => SenderDisplay {
            primary: email,
            secondary: None,
        },
    }
}

fn clean_sender_display_part(value: &str) -> String {
    value
        .trim()
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .trim()
        .to_string()
}

fn fallback_sender_identity(raw_sender: &str) -> Option<SenderIdentity> {
    let candidate = raw_sender
        .split(|character: char| {
            character.is_whitespace() || matches!(character, '<' | '>' | ',' | ';' | '"' | '\'')
        })
        .find(|part| part.contains('@'))?;
    normalize_sender_address(candidate)
}

fn normalize_sender_address(raw_address: &str) -> Option<SenderIdentity> {
    let address = raw_address
        .trim()
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .to_ascii_lowercase();
    let (local, domain) = address.rsplit_once('@')?;
    let domain = domain.trim().trim_matches('.').to_string();
    if local.trim().is_empty()
        || domain.is_empty()
        || domain.contains('/')
        || domain.contains('@')
        || address.contains(char::is_whitespace)
    {
        return None;
    }
    Some(SenderIdentity { address, domain })
}

fn normalize_sender_domain(raw_domain: &str) -> Option<String> {
    let domain = raw_domain
        .trim()
        .trim_start_matches('@')
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .trim_matches('.')
        .to_ascii_lowercase();
    if domain.is_empty()
        || domain.contains('@')
        || domain.contains('/')
        || domain.contains(char::is_whitespace)
    {
        None
    } else {
        Some(domain)
    }
}

fn normalize_sender_rule_value(kind: SenderRuleKind, raw_value: &str) -> Result<String, String> {
    match kind {
        SenderRuleKind::Address => normalize_sender_address(raw_value)
            .map(|identity| identity.address)
            .ok_or_else(|| "Sender address rule must be a valid email address".to_string()),
        SenderRuleKind::Domain => normalize_sender_domain(raw_value)
            .ok_or_else(|| "Sender domain rule must be a valid mail domain".to_string()),
    }
}

fn parse_message_timestamp(raw: &str) -> Option<i64> {
    DateTime::parse_from_rfc2822(raw)
        .ok()
        .map(|value| value.with_timezone(&Utc).timestamp())
        .or_else(|| {
            DateTime::parse_from_rfc3339(raw)
                .ok()
                .map(|value| value.with_timezone(&Utc).timestamp())
        })
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
    fallback_mime_from_extension_str(&extension)
}

fn fallback_mime_from_extension_str(extension: &str) -> Option<String> {
    Some(
        match extension {
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

fn looks_like_inline_artifact(filename: &str, mime_type: &str, size_bytes: u64) -> bool {
    looks_like_extracted_body_part(filename)
        || mime_type.starts_with("image/") && size_bytes <= 1024
        || filename.eq_ignore_ascii_case("winmail.dat")
        || filename.eq_ignore_ascii_case("smime.p7s")
}

fn attachment_is_body_artifact(attachment: &AttachmentRecord) -> bool {
    looks_like_extracted_body_part(&attachment.original_filename)
        || attachment
            .original_filename
            .eq_ignore_ascii_case("winmail.dat")
        || attachment
            .original_filename
            .eq_ignore_ascii_case("smime.p7s")
}

fn attachment_is_inline_image(attachment: &AttachmentRecord) -> bool {
    attachment.mime_type.starts_with("image/")
        && (attachment.is_inline_artifact
            || u64::try_from(attachment.size_bytes.max(0)).unwrap_or_default() <= 1024)
}

fn looks_like_extracted_body_part(filename: &str) -> bool {
    let lowered = filename.to_ascii_lowercase();
    lowered.strip_prefix("textfile").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.chars().all(|character| character.is_ascii_digit())
    })
}

fn sync_directory(path: &FsPath) -> Result<(), String> {
    let dir = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    dir.sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", path.display()))
}

fn safe_filename(raw: &str) -> String {
    filename_component(raw, "attachment")
}

fn filename_component(raw: &str, fallback: &str) -> String {
    let sanitized = raw
        .chars()
        .map(|character| {
            if character == '\0' || character == '/' || character == '\\' || character.is_control()
            {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|character| matches!(character, '.' | ' '))
        .to_string();
    if sanitized.is_empty() || sanitized == "." || sanitized == ".." {
        fallback.to_string()
    } else {
        sanitized
    }
}

fn ascii_download_fallback(raw: &str, fallback: &str) -> String {
    let sanitized = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | ' ') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|character| matches!(character, '.' | '_' | ' '))
        .to_string();
    if sanitized.is_empty() {
        fallback.to_string()
    } else {
        sanitized
    }
}

fn rfc5987_encode(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'!'
            | b'#'
            | b'$'
            | b'&'
            | b'+'
            | b'-'
            | b'.'
            | b'^'
            | b'_'
            | b'`'
            | b'|'
            | b'~' => vec![byte as char],
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

fn content_disposition_attachment(filename: &str) -> String {
    let safe = filename_component(filename, "download");
    let fallback = ascii_download_fallback(&safe, "download").replace('"', "_");
    format!(
        "attachment; filename=\"{}\"; filename*=UTF-8''{}",
        fallback,
        rfc5987_encode(&safe)
    )
}

fn normalize_download_subfolder(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let mut components = Vec::new();
    for component in trimmed.split(['/', '\\']) {
        let component = filename_component(component, "");
        if component.is_empty() {
            continue;
        }
        if component == "." || component == ".." {
            return Err("Download subfolder cannot contain . or .. path components.".to_string());
        }
        components.push(component);
    }
    if components.is_empty() {
        Ok(String::new())
    } else {
        Ok(components.join("/"))
    }
}

fn attachment_inventory_root(config: &AppConfig, account_id: i64) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref())
        .join("attachment-inventory")
        .join(format!("account-{account_id}"))
}

fn runtime_export_root(config: &AppConfig) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref()).join("attachment-exports")
}

fn attachment_blob_relpath(sha256: &str) -> PathBuf {
    let prefix = sha256.chars().take(2).collect::<String>();
    PathBuf::from("attachments")
        .join("blobs")
        .join("sha256")
        .join(if prefix.len() == 2 {
            prefix
        } else {
            "unknown".to_string()
        })
        .join(sha256)
}

fn attachment_blob_path(
    account_paths: &AccountPaths,
    blob_relpath: &str,
) -> Result<PathBuf, String> {
    let relpath = FsPath::new(blob_relpath);
    if relpath.is_absolute() || blob_relpath.contains("..") {
        return Err(format!("invalid attachment blob path: {blob_relpath}"));
    }
    Ok(account_paths.hidden_sync_root.join(relpath))
}

fn persist_attachment_blob(
    account_paths: &AccountPaths,
    source: &FsPath,
    sha256: &str,
) -> Result<String, String> {
    let relpath = attachment_blob_relpath(sha256);
    let destination = account_paths.hidden_sync_root.join(&relpath);
    if destination.exists() {
        let existing_sha = sha256_file(&destination)?;
        if existing_sha == sha256 {
            return Ok(relpath.to_string_lossy().to_string());
        }
        fs::remove_file(&destination).map_err(|error| {
            format!(
                "failed to replace mismatched attachment blob {}: {error}",
                destination.display()
            )
        })?;
    }

    let parent = destination.parent().ok_or_else(|| {
        format!(
            "attachment blob path has no parent: {}",
            destination.display()
        )
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    let temporary = parent.join(format!(".{}.tmp", random_hex(8)));
    fs::copy(source, &temporary).map_err(|error| {
        format!(
            "failed to copy attachment blob {} to {}: {error}",
            source.display(),
            temporary.display()
        )
    })?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600)).map_err(|error| {
        format!(
            "failed to set attachment blob permissions {}: {error}",
            temporary.display()
        )
    })?;
    let copied_sha = sha256_file(&temporary)?;
    if copied_sha != sha256 {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "attachment blob hash changed while copying: expected {sha256}, got {copied_sha}"
        ));
    }
    fs::rename(&temporary, &destination).map_err(|error| {
        format!(
            "failed to publish attachment blob {}: {error}",
            destination.display()
        )
    })?;
    sync_directory(parent)?;
    Ok(relpath.to_string_lossy().to_string())
}

fn create_runtime_extraction_dir(
    config: &AppConfig,
    account_id: i64,
) -> Result<TempExtractionDir, String> {
    let path = attachment_inventory_root(config, account_id).join(random_hex(8));
    fs::create_dir_all(&path).map_err(|error| {
        format!(
            "failed to create extraction directory {}: {error}",
            path.display()
        )
    })?;
    Ok(TempExtractionDir { path })
}

fn message_relative_path(
    account_paths: &AccountPaths,
    file_path: &FsPath,
) -> Result<PathBuf, String> {
    if let Ok(relative) = file_path.strip_prefix(&account_paths.maildir) {
        return Ok(relative.to_path_buf());
    }

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
        .map(|relative| relative.to_path_buf())
        .map_err(|_| {
            format!(
                "message path {} is outside the maildir",
                file_path.display()
            )
        })
}

fn attachment_extension(filename: &str) -> String {
    FsPath::new(filename)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default()
}

fn attachment_key(
    account_id: i64,
    message_key: &str,
    attachment_index: usize,
    attachment_sha256: &str,
    original_filename: &str,
) -> String {
    sha256_hex(
        format!(
            "{account_id}\u{1f}{message_key}\u{1f}{attachment_index}\u{1f}{attachment_sha256}\u{1f}{original_filename}"
        )
        .as_bytes(),
    )
}

fn list_notmuch_message_files(
    account_paths: &AccountPaths,
    query: &str,
) -> Result<Vec<PathBuf>, String> {
    let output = execute_command(
        "notmuch",
        &["search", "--output=files", "--format=text", query],
        &[
            (
                "HOME",
                account_paths.account_state_root.to_string_lossy().as_ref(),
            ),
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

    let mut files = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();
    files.sort();
    Ok(files)
}

fn scan_message_attachments_for_catalog(
    config: &AppConfig,
    account_paths: &AccountPaths,
    account_id: i64,
    message_key: &str,
    message_path: &FsPath,
    source_message_sha256: &str,
) -> Result<(TempExtractionDir, Vec<(AttachmentRecord, PathBuf)>), String> {
    let extraction_dir = create_runtime_extraction_dir(config, account_id)?;
    let extracted_files = extract_message_attachments(message_path, &extraction_dir.path)?;
    let now = Utc::now().to_rfc3339();
    let mut attachments = Vec::new();

    for (index, extracted) in extracted_files.into_iter().enumerate() {
        let metadata = fs::metadata(&extracted.path).map_err(|error| {
            format!(
                "failed to inspect extracted attachment {}: {error}",
                extracted.path.display()
            )
        })?;
        let original_filename = extracted.original_filename;
        let safe_name = safe_filename(&original_filename);
        let extension = attachment_extension(&original_filename);
        let mime_type = detect_attachment_mime_type(&extracted.path)
            .unwrap_or_else(|_| "application/octet-stream".to_string());
        let size_bytes = i64::try_from(metadata.len()).map_err(|_| {
            format!(
                "attachment {} is too large to catalog",
                extracted.path.display()
            )
        })?;
        let attachment_sha256 = sha256_file(&extracted.path)?;
        let blob_relpath =
            persist_attachment_blob(account_paths, &extracted.path, &attachment_sha256)?;
        let attachment_record = AttachmentRecord {
            attachment_key: attachment_key(
                account_id,
                message_key,
                index,
                &attachment_sha256,
                &original_filename,
            ),
            account_id,
            message_key: message_key.to_string(),
            attachment_index: index as i64,
            attachment_sha256,
            original_filename: original_filename.clone(),
            safe_filename: safe_name,
            extension,
            mime_type: mime_type.clone(),
            size_bytes,
            is_inline_artifact: extracted.is_inline_image
                || looks_like_inline_artifact(&original_filename, &mime_type, metadata.len()),
            blob_relpath: Some(blob_relpath),
            source_message_sha256: Some(source_message_sha256.to_string()),
            last_verified_at: Some(now.clone()),
            created_at: now.clone(),
            updated_at: now.clone(),
            last_seen_at: now.clone(),
        };
        attachments.push((attachment_record, extracted.path));
    }

    Ok((extraction_dir, attachments))
}

fn load_attachment_messages_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<AttachmentMessageRecord>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                account_id,
                message_key,
                message_relpath,
                message_mtime,
                message_size,
                subject,
                sender,
                timestamp,
                last_scanned_at,
                has_attachments
            FROM attachment_messages
            WHERE account_id = ?1
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment message query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok(AttachmentMessageRecord {
                account_id: row.get(0)?,
                message_key: row.get(1)?,
                message_relpath: row.get(2)?,
                message_mtime: row.get(3)?,
                message_size: row.get(4)?,
                subject: row.get(5)?,
                from: row.get(6)?,
                timestamp: row.get(7)?,
                last_scanned_at: row.get(8)?,
                has_attachments: row.get::<_, i64>(9)? != 0,
            })
        })
        .map_err(|error| format!("failed to query attachment messages: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment messages: {error}"))
}

fn refresh_attachment_catalog(config: &AppConfig, account: &AccountRecord) -> Result<(), String> {
    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        return Ok(());
    }

    let mut connection = open_db(config)?;
    let existing_messages = load_attachment_messages_for_account(&connection, account.id)?;
    let existing_by_relpath = existing_messages
        .iter()
        .map(|record| (record.message_relpath.clone(), record.clone()))
        .collect::<HashMap<_, _>>();
    let message_files = list_notmuch_message_files(&account_paths, "*")?;
    let mut seen_relpaths = HashSet::new();
    let mut seen_message_keys = HashSet::new();

    for message_path in message_files {
        let relpath = message_relative_path(&account_paths, &message_path)?
            .to_string_lossy()
            .to_string();
        let metadata = fs::metadata(&message_path)
            .map_err(|error| format!("failed to inspect {}: {error}", message_path.display()))?;
        let message_mtime = metadata.mtime();
        let message_size = i64::try_from(metadata.size())
            .map_err(|_| format!("message {} is too large to catalog", message_path.display()))?;
        let message_metadata = read_message_metadata(&message_path)?;
        let message_key = message_key_from_metadata(&message_metadata)?;
        let source_message_sha256 = sha256_file(&message_path)?;

        if !seen_message_keys.insert(message_key.clone()) {
            continue;
        }
        seen_relpaths.insert(relpath.clone());

        if existing_by_relpath.get(&relpath).is_some_and(|record| {
            record.message_key == message_key
                && record.message_mtime == message_mtime
                && record.message_size == message_size
        }) {
            continue;
        }

        let (_extraction_dir, scanned_attachments) = scan_message_attachments_for_catalog(
            config,
            &account_paths,
            account.id,
            &message_key,
            &message_path,
            &source_message_sha256,
        )?;
        let now = Utc::now().to_rfc3339();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("failed to start attachment refresh transaction: {error}"))?;

        if let Some(existing) = existing_by_relpath.get(&relpath) {
            transaction
                .execute(
                    "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, existing.message_key],
                )
                .map_err(|error| format!("failed to clear stale attachment rows: {error}"))?;
        }
        transaction
            .execute(
                "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                params![account.id, message_key],
            )
            .map_err(|error| format!("failed to replace attachment rows: {error}"))?;
        transaction
            .execute(
                "DELETE FROM attachment_messages WHERE account_id = ?1 AND (message_relpath = ?2 OR message_key = ?3)",
                params![account.id, relpath, message_key],
            )
            .map_err(|error| format!("failed to replace attachment message row: {error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO attachment_messages (
                    account_id,
                    message_key,
                    message_relpath,
                    message_mtime,
                    message_size,
                    subject,
                    sender,
                    timestamp,
                    last_scanned_at,
                    has_attachments
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    account.id,
                    message_key,
                    relpath,
                    message_mtime,
                    message_size,
                    message_metadata.subject,
                    message_metadata.from,
                    message_metadata.timestamp,
                    now,
                    if scanned_attachments.is_empty() { 0 } else { 1 },
                ],
            )
            .map_err(|error| format!("failed to store attachment message row: {error}"))?;

        for (attachment, _) in scanned_attachments {
            transaction
                .execute(
                    r#"
                    INSERT INTO attachment_catalog (
                        attachment_key,
                        account_id,
                        message_key,
                        attachment_index,
                        attachment_sha256,
                        original_filename,
                        safe_filename,
                        extension,
                        mime_type,
                        size_bytes,
                        is_inline_artifact,
                        blob_relpath,
                        source_message_sha256,
                        last_verified_at,
                        created_at,
                        updated_at,
                        last_seen_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                    "#,
                    params![
                        attachment.attachment_key,
                        attachment.account_id,
                        attachment.message_key,
                        attachment.attachment_index,
                        attachment.attachment_sha256,
                        attachment.original_filename,
                        attachment.safe_filename,
                        attachment.extension,
                        attachment.mime_type,
                        attachment.size_bytes,
                        if attachment.is_inline_artifact { 1 } else { 0 },
                        attachment.blob_relpath,
                        attachment.source_message_sha256,
                        attachment.last_verified_at,
                        attachment.created_at,
                        attachment.updated_at,
                        attachment.last_seen_at,
                    ],
                )
                .map_err(|error| format!("failed to store attachment catalog row: {error}"))?;
        }

        transaction
            .commit()
            .map_err(|error| format!("failed to commit attachment refresh transaction: {error}"))?;
    }

    let stale_messages = existing_messages
        .into_iter()
        .filter(|message| !seen_relpaths.contains(&message.message_relpath))
        .collect::<Vec<_>>();
    if !stale_messages.is_empty() {
        let transaction = connection
            .transaction()
            .map_err(|error| format!("failed to start stale attachment cleanup: {error}"))?;
        for stale in stale_messages {
            transaction
                .execute(
                    "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, stale.message_key],
                )
                .map_err(|error| {
                    format!("failed to delete stale attachment catalog rows: {error}")
                })?;
            transaction
                .execute(
                    "DELETE FROM attachment_messages WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, stale.message_key],
                )
                .map_err(|error| {
                    format!("failed to delete stale attachment message row: {error}")
                })?;
        }
        transaction
            .commit()
            .map_err(|error| format!("failed to commit stale attachment cleanup: {error}"))?;
    }

    Ok(())
}

fn refresh_attachment_catalog_for_user(
    config: &AppConfig,
    username: &str,
    selected_account_id: Option<i64>,
) -> Result<(), String> {
    let accounts = list_accounts_for_user(config, username)?;
    for account in accounts
        .into_iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        refresh_attachment_catalog(config, &account)?;
    }
    Ok(())
}
fn load_attachment_catalog_rows_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<(AttachmentMessageRecord, AttachmentRecord)>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                m.account_id,
                m.message_key,
                m.message_relpath,
                m.message_mtime,
                m.message_size,
                m.subject,
                m.sender,
                m.timestamp,
                m.last_scanned_at,
                m.has_attachments,
                c.attachment_key,
                c.account_id,
                c.message_key,
                c.attachment_index,
                c.attachment_sha256,
                c.original_filename,
                c.safe_filename,
                c.extension,
                c.mime_type,
                c.size_bytes,
                c.is_inline_artifact,
                c.blob_relpath,
                c.source_message_sha256,
                c.last_verified_at,
                c.created_at,
                c.updated_at,
                c.last_seen_at
            FROM attachment_catalog c
            INNER JOIN attachment_messages m
                ON m.account_id = c.account_id
               AND m.message_key = c.message_key
            WHERE c.account_id = ?1
            ORDER BY m.timestamp DESC, c.attachment_index ASC
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment catalog query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok((
                AttachmentMessageRecord {
                    account_id: row.get(0)?,
                    message_key: row.get(1)?,
                    message_relpath: row.get(2)?,
                    message_mtime: row.get(3)?,
                    message_size: row.get(4)?,
                    subject: row.get(5)?,
                    from: row.get(6)?,
                    timestamp: row.get(7)?,
                    last_scanned_at: row.get(8)?,
                    has_attachments: row.get::<_, i64>(9)? != 0,
                },
                AttachmentRecord {
                    attachment_key: row.get(10)?,
                    account_id: row.get(11)?,
                    message_key: row.get(12)?,
                    attachment_index: row.get(13)?,
                    attachment_sha256: row.get(14)?,
                    original_filename: row.get(15)?,
                    safe_filename: row.get(16)?,
                    extension: row.get(17)?,
                    mime_type: row.get(18)?,
                    size_bytes: row.get(19)?,
                    is_inline_artifact: row.get::<_, i64>(20)? != 0,
                    blob_relpath: row.get(21)?,
                    source_message_sha256: row.get(22)?,
                    last_verified_at: row.get(23)?,
                    created_at: row.get(24)?,
                    updated_at: row.get(25)?,
                    last_seen_at: row.get(26)?,
                },
            ))
        })
        .map_err(|error| format!("failed to query attachment catalog rows: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment catalog rows: {error}"))
}

fn message_catalog_has_attachments(
    connection: &Connection,
    account_id: i64,
    message_key: &str,
) -> Result<bool, String> {
    connection
        .query_row(
            "SELECT has_attachments FROM attachment_messages WHERE account_id = ?1 AND message_key = ?2 LIMIT 1",
            params![account_id, message_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|error| format!("failed to query attachment message state: {error}"))
        .map(|value| value.unwrap_or(0) != 0)
}

fn parse_page_number(raw: Option<&str>) -> usize {
    raw.and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(1)
}

fn optional_trimmed(raw: Option<&String>) -> String {
    raw.map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
}

fn parse_query_bool(raw: Option<&str>) -> Result<Option<bool>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => match value.to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Ok(Some(true)),
            "0" | "false" | "no" | "off" => Ok(Some(false)),
            _ => Err(format!("invalid boolean query value '{value}'")),
        },
        None => Ok(None),
    }
}

fn query_bool_is_true(raw: Option<&str>) -> bool {
    matches!(parse_query_bool(raw).ok().flatten(), Some(true))
}

fn parse_optional_usize(raw: Option<&str>, label: &str) -> Result<Option<usize>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => value
            .parse::<usize>()
            .map(Some)
            .map_err(|error| format!("invalid {label} '{value}': {error}")),
        None => Ok(None),
    }
}

fn parse_optional_nonnegative_i64(raw: Option<&str>, label: &str) -> Result<Option<i64>, String> {
    match parse_optional_query_i64(raw)? {
        Some(value) if value < 0 => Err(format!("{label} cannot be negative")),
        value => Ok(value),
    }
}

fn parse_date_start(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(0, 0, 0)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

fn parse_date_end(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(23, 59, 59)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

fn message_filters_from_search_params(
    params: &SearchParams,
    fallback_query: String,
) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()).if_empty_then(fallback_query),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: parse_query_bool(params.has_attachments.as_deref())
            .ok()
            .flatten(),
    }
}

trait EmptyStringFallback {
    fn if_empty_then(self, fallback: String) -> String;
}

impl EmptyStringFallback for String {
    fn if_empty_then(self, fallback: String) -> String {
        if self.is_empty() {
            fallback
        } else {
            self
        }
    }
}

fn message_filters_from_attachment_params(params: &AttachmentListParams) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: parse_query_bool(params.has_attachments.as_deref())
            .ok()
            .flatten(),
    }
}

fn attachment_filters_from_params(params: &AttachmentListParams) -> AttachmentSearchFilters {
    AttachmentSearchFilters {
        message: message_filters_from_attachment_params(params),
        extension: optional_trimmed(params.extension.as_ref()).to_ascii_lowercase(),
        attachment_name: optional_trimmed(params.attachment_name.as_ref()),
        mime_type: optional_trimmed(params.mime_type.as_ref()).to_ascii_lowercase(),
        min_size: optional_trimmed(params.min_size.as_ref()),
        max_size: optional_trimmed(params.max_size.as_ref()),
        min_attachments: optional_trimmed(params.min_attachments.as_ref()),
        max_attachments: optional_trimmed(params.max_attachments.as_ref()),
    }
}

fn attachment_params_from_preset_form(
    form: &AttachmentPresetSaveForm,
) -> Result<AttachmentListParams, String> {
    Ok(AttachmentListParams {
        q: form.q.clone(),
        account_id: parse_optional_query_i64(form.account_id.as_deref())?,
        priority: form.priority.clone(),
        sender_address: form.sender_address.clone(),
        sender_name: form.sender_name.clone(),
        sender_domain: form.sender_domain.clone(),
        subject: form.subject.clone(),
        body_text: form.body_text.clone(),
        date_from: form.date_from.clone(),
        date_to: form.date_to.clone(),
        has_attachments: form.has_attachments.clone(),
        extension: form.extension.clone(),
        attachment_name: form.attachment_name.clone(),
        mime_type: form.mime_type.clone(),
        min_size: form.min_size.clone(),
        max_size: form.max_size.clone(),
        min_attachments: form.min_attachments.clone(),
        max_attachments: form.max_attachments.clone(),
        include_inline: form.include_inline.clone(),
        include_inline_images: form.include_inline_images.clone(),
        show_mime_details: form.show_mime_details.clone(),
        download_subfolder: form.download_subfolder.clone(),
        page: None,
        flash: None,
        error: None,
    })
}

fn parse_message_search_filters(
    filters: MessageSearchFilters,
) -> Result<ParsedMessageSearchFilters, String> {
    let normalized_sender_address = if filters.sender_address.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_address(&filters.sender_address)
                .map(|identity| identity.address)
                .ok_or_else(|| "Sender address must be a valid email address.".to_string())?,
        )
    };
    let normalized_sender_domain = if filters.sender_domain.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_domain(&filters.sender_domain)
                .ok_or_else(|| "Sender domain must be a valid mail domain.".to_string())?,
        )
    };
    let date_from_timestamp = parse_date_start(&filters.date_from, "from")?;
    let date_to_timestamp = parse_date_end(&filters.date_to, "to")?;
    if let (Some(from), Some(to)) = (date_from_timestamp, date_to_timestamp) {
        if from > to {
            return Err("Date from must be before date to.".to_string());
        }
    }

    Ok(ParsedMessageSearchFilters {
        raw: filters,
        normalized_sender_address,
        normalized_sender_domain,
        date_from_timestamp,
        date_to_timestamp,
    })
}

fn parse_attachment_search_filters(
    filters: AttachmentSearchFilters,
) -> Result<ParsedAttachmentSearchFilters, String> {
    let message = parse_message_search_filters(filters.message.clone())?;
    let min_size_bytes = parse_optional_nonnegative_i64(Some(&filters.min_size), "minimum size")?;
    let max_size_bytes = parse_optional_nonnegative_i64(Some(&filters.max_size), "maximum size")?;
    if let (Some(min), Some(max)) = (min_size_bytes, max_size_bytes) {
        if min > max {
            return Err("Minimum size must be less than or equal to maximum size.".to_string());
        }
    }
    let min_attachment_count =
        parse_optional_usize(Some(&filters.min_attachments), "minimum attachment count")?;
    let max_attachment_count =
        parse_optional_usize(Some(&filters.max_attachments), "maximum attachment count")?;
    if let (Some(min), Some(max)) = (min_attachment_count, max_attachment_count) {
        if min > max {
            return Err(
                "Minimum attachment count must be less than or equal to maximum attachment count."
                    .to_string(),
            );
        }
    }

    Ok(ParsedAttachmentSearchFilters {
        raw: filters,
        message,
        min_size_bytes,
        max_size_bytes,
        min_attachment_count,
        max_attachment_count,
    })
}

fn notmuch_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value.replace('\\', "\\\\").replace('"', "\\\"").trim()
    )
}

fn notmuch_query_for_filters(filters: &ParsedMessageSearchFilters) -> String {
    let mut terms = Vec::new();
    if !filters.raw.q.trim().is_empty() {
        terms.push(filters.raw.q.trim().to_string());
    }
    if let Some(address) = filters.normalized_sender_address.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(address)));
    }
    if !filters.raw.sender_name.trim().is_empty() {
        terms.push(format!("from:{}", notmuch_quote(&filters.raw.sender_name)));
    }
    if let Some(domain) = filters.normalized_sender_domain.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(domain)));
    }
    if !filters.raw.subject.trim().is_empty() {
        terms.push(format!("subject:{}", notmuch_quote(&filters.raw.subject)));
    }
    if !filters.raw.body_text.trim().is_empty() {
        terms.push(notmuch_quote(&filters.raw.body_text));
    }
    if terms.is_empty() {
        "*".to_string()
    } else {
        terms.join(" ")
    }
}

fn message_matches_filters(
    metadata: &LiveMessageRecord,
    filters: &ParsedMessageSearchFilters,
    has_attachments: Option<bool>,
) -> bool {
    if let Some(from_timestamp) = filters.date_from_timestamp {
        if metadata.timestamp < from_timestamp {
            return false;
        }
    }
    if let Some(to_timestamp) = filters.date_to_timestamp {
        if metadata.timestamp > to_timestamp {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_address.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.address != expected)
        {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_domain.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.domain != expected)
        {
            return false;
        }
    }
    if !filters.raw.sender_name.trim().is_empty() {
        let needle = filters.raw.sender_name.to_ascii_lowercase();
        let display = sender_display_from_header(&metadata.from);
        if !display.primary.to_ascii_lowercase().contains(&needle)
            && !metadata.from.to_ascii_lowercase().contains(&needle)
        {
            return false;
        }
    }
    if !filters.raw.subject.trim().is_empty()
        && !metadata
            .subject
            .to_ascii_lowercase()
            .contains(&filters.raw.subject.to_ascii_lowercase())
    {
        return false;
    }
    if let Some(expected) = filters.raw.has_attachments {
        if has_attachments != Some(expected) {
            return false;
        }
    }
    true
}

fn attachment_matches_filters(
    item: &AttachmentListItem,
    filters: &ParsedAttachmentSearchFilters,
    attachment_count: usize,
) -> bool {
    if !filters.raw.extension.is_empty() && item.attachment.extension != filters.raw.extension {
        return false;
    }
    if !filters.raw.attachment_name.is_empty()
        && !item
            .attachment
            .original_filename
            .to_ascii_lowercase()
            .contains(&filters.raw.attachment_name.to_ascii_lowercase())
    {
        return false;
    }
    if !filters.raw.mime_type.is_empty()
        && !item
            .attachment
            .mime_type
            .to_ascii_lowercase()
            .contains(&filters.raw.mime_type)
    {
        return false;
    }
    if let Some(min_size) = filters.min_size_bytes {
        if item.attachment.size_bytes < min_size {
            return false;
        }
    }
    if let Some(max_size) = filters.max_size_bytes {
        if item.attachment.size_bytes > max_size {
            return false;
        }
    }
    if let Some(min_count) = filters.min_attachment_count {
        if attachment_count < min_count {
            return false;
        }
    }
    if let Some(max_count) = filters.max_attachment_count {
        if attachment_count > max_count {
            return false;
        }
    }
    true
}

fn build_attachment_base_query(state: AttachmentBaseQuery<'_>) -> String {
    let mut pairs = Vec::new();
    append_message_filter_query_pairs(&mut pairs, &state.filters.message);
    if let Some(account_id) = state.selected_account_id {
        pairs.push(("account_id", account_id.to_string()));
    }
    if state.priority_filter != SenderPriorityFilter::All {
        pairs.push((
            "priority",
            state.priority_filter.as_query_value().to_string(),
        ));
    }
    append_attachment_filter_query_pairs(&mut pairs, state.filters);
    if state.include_inline {
        pairs.push(("include_inline", "1".to_string()));
    }
    if state.include_inline_images {
        pairs.push(("include_inline_images", "1".to_string()));
    }
    if state.show_mime_details {
        pairs.push(("show_mime_details", "1".to_string()));
    }
    if !state.download_subfolder.trim().is_empty() {
        pairs.push((
            "download_subfolder",
            state.download_subfolder.trim().to_string(),
        ));
    }
    pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={}", url_encode_component(&value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn attachment_preset_query_from_form(form: &AttachmentPresetSaveForm) -> Result<String, String> {
    let params = attachment_params_from_preset_form(form)?;
    let filters = attachment_filters_from_params(&params);
    let parsed_filters = parse_attachment_search_filters(filters)?;
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;

    Ok(build_attachment_base_query(AttachmentBaseQuery {
        filters: &parsed_filters.raw,
        selected_account_id: params.account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    }))
}

fn append_message_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &MessageSearchFilters,
) {
    for (key, value) in [
        ("q", filters.q.trim()),
        ("sender_address", filters.sender_address.trim()),
        ("sender_name", filters.sender_name.trim()),
        ("sender_domain", filters.sender_domain.trim()),
        ("subject", filters.subject.trim()),
        ("body_text", filters.body_text.trim()),
        ("date_from", filters.date_from.trim()),
        ("date_to", filters.date_to.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
    if let Some(value) = filters.has_attachments {
        pairs.push(("has_attachments", if value { "1" } else { "0" }.to_string()));
    }
}

fn append_attachment_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &AttachmentSearchFilters,
) {
    for (key, value) in [
        ("extension", filters.extension.trim()),
        ("attachment_name", filters.attachment_name.trim()),
        ("mime_type", filters.mime_type.trim()),
        ("min_size", filters.min_size.trim()),
        ("max_size", filters.max_size.trim()),
        ("min_attachments", filters.min_attachments.trim()),
        ("max_attachments", filters.max_attachments.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
}

fn message_filters_have_terms(filters: &MessageSearchFilters) -> bool {
    [
        filters.q.as_str(),
        filters.sender_address.as_str(),
        filters.sender_name.as_str(),
        filters.sender_domain.as_str(),
        filters.subject.as_str(),
        filters.body_text.as_str(),
        filters.date_from.as_str(),
        filters.date_to.as_str(),
    ]
    .iter()
    .any(|value| !value.trim().is_empty())
        || filters.has_attachments.is_some()
}

fn normalize_attachment_preset_name(raw: &str) -> Result<String, String> {
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err("Preset name is required.".to_string());
    }
    if name.chars().count() > 80 {
        return Err("Preset name must be 80 characters or fewer.".to_string());
    }
    Ok(name)
}

fn list_attachment_filter_presets(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<AttachmentFilterPreset>, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT id, name, query
            FROM attachment_filter_presets
            WHERE username = ?1
            ORDER BY lower(name), name
            "#,
        )
        .map_err(|error| format!("failed to load attachment filter presets: {error}"))?;
    let rows = statement
        .query_map(params![username], |row| {
            Ok(AttachmentFilterPreset {
                id: row.get(0)?,
                name: row.get(1)?,
                query: row.get(2)?,
            })
        })
        .map_err(|error| format!("failed to read attachment filter presets: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment filter preset: {error}"))
}

fn save_attachment_filter_preset_for_user(
    config: &AppConfig,
    username: &str,
    form: &AttachmentPresetSaveForm,
) -> Result<AttachmentFilterPreset, String> {
    let name = normalize_attachment_preset_name(&form.preset_name)?;
    let query = attachment_preset_query_from_form(form)?;
    if query.trim().is_empty() {
        return Err("Add at least one attachment filter before saving a preset.".to_string());
    }

    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO attachment_filter_presets (username, name, query, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?4)
            ON CONFLICT(username, name) DO UPDATE SET
                query = excluded.query,
                updated_at = excluded.updated_at
            "#,
            params![username, name, query, now],
        )
        .map_err(|error| format!("failed to save attachment filter preset: {error}"))?;

    connection
        .query_row(
            r#"
            SELECT id, name, query
            FROM attachment_filter_presets
            WHERE username = ?1 AND name = ?2
            LIMIT 1
            "#,
            params![username, name],
            |row| {
                Ok(AttachmentFilterPreset {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    query: row.get(2)?,
                })
            },
        )
        .map_err(|error| format!("failed to reload attachment filter preset: {error}"))
}

fn delete_attachment_filter_preset_for_user(
    config: &AppConfig,
    username: &str,
    preset_id: i64,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let deleted = connection
        .execute(
            "DELETE FROM attachment_filter_presets WHERE username = ?1 AND id = ?2",
            params![username, preset_id],
        )
        .map_err(|error| format!("failed to delete attachment filter preset: {error}"))?;
    if deleted == 0 {
        return Err("Attachment filter preset was not found.".to_string());
    }
    Ok(())
}

fn load_attachment_page_data(
    config: &AppConfig,
    username: &str,
    params: &AttachmentListParams,
) -> Result<AttachmentPageData, String> {
    let accounts = list_accounts_for_user(config, username)?;
    let presets = list_attachment_filter_presets(config, username)?;
    let selected_account_id = normalize_selected_account_id(&accounts, params.account_id);
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let raw_filters = attachment_filters_from_params(params);
    let filters = parse_attachment_search_filters(raw_filters)?;
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;
    let page = parse_page_number(params.page.as_deref());
    let connection = open_db(config)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let mut items = Vec::new();
    let mut query_relpaths_by_account = HashMap::<i64, HashSet<String>>::new();

    for account in accounts
        .iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        let account_paths = ensure_account_paths(config, account)?;
        if account_index_state(&account_paths) != IndexState::Indexed {
            continue;
        }

        if message_filters_have_terms(&filters.raw.message) {
            let relpaths = list_notmuch_message_files(
                &account_paths,
                &notmuch_query_for_filters(&filters.message),
            )?
            .into_iter()
            .map(|path| {
                message_relative_path(&account_paths, &path)
                    .map(|relative| relative.to_string_lossy().to_string())
            })
            .collect::<Result<HashSet<_>, _>>()?;
            query_relpaths_by_account.insert(account.id, relpaths);
        }

        let catalog_rows = load_attachment_catalog_rows_for_account(&connection, account.id)?;
        let mut attachment_counts = HashMap::<String, usize>::new();
        for (message, _) in &catalog_rows {
            *attachment_counts
                .entry(message.message_key.clone())
                .or_insert(0) += 1;
        }

        for (message, attachment) in catalog_rows {
            if message_filters_have_terms(&filters.raw.message)
                && !query_relpaths_by_account
                    .get(&account.id)
                    .is_some_and(|relpaths| relpaths.contains(&message.message_relpath))
            {
                continue;
            }
            if !include_inline && attachment_is_body_artifact(&attachment) {
                continue;
            }
            if !include_inline_images && attachment_is_inline_image(&attachment) {
                continue;
            }

            let sender_priority = priority_rules.view_for_sender(&message.from);
            if !priority_filter.matches(sender_priority.priority) {
                continue;
            }

            let mut item = AttachmentListItem {
                account_name: account.display_name.clone(),
                attachment,
                message,
                sender_priority,
                paperless_sent_at: None,
            };
            if !message_matches_filters(
                &LiveMessageRecord {
                    message_key: item.message.message_key.clone(),
                    message_relpaths: vec![item.message.message_relpath.clone()],
                    subject: item.message.subject.clone(),
                    from: item.message.from.clone(),
                    timestamp: item.message.timestamp,
                },
                &filters.message,
                Some(item.message.has_attachments),
            ) {
                continue;
            }
            let attachment_count = attachment_counts
                .get(&item.message.message_key)
                .copied()
                .unwrap_or(0);
            if !attachment_matches_filters(&item, &filters, attachment_count) {
                continue;
            }
            item.paperless_sent_at = load_attachment_paperless_handoff(
                &connection,
                config,
                username,
                &item.attachment.attachment_key,
            )?;
            items.push(item);
        }
    }

    items.sort_by(|left, right| {
        left.sender_priority
            .priority
            .sort_rank()
            .cmp(&right.sender_priority.priority.sort_rank())
            .then(right.message.timestamp.cmp(&left.message.timestamp))
            .then(
                left.attachment
                    .attachment_index
                    .cmp(&right.attachment.attachment_index),
            )
    });

    let total_count = items.len();
    let start = (page - 1).saturating_mul(ATTACHMENTS_PER_PAGE);
    let end = usize::min(start + ATTACHMENTS_PER_PAGE, total_count);
    let page_items = if start >= total_count {
        Vec::new()
    } else {
        items[start..end].to_vec()
    };
    let base_query = build_attachment_base_query(AttachmentBaseQuery {
        filters: &filters.raw,
        selected_account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    });
    let empty_message =
        if selected_account_id.is_some() && page_items.is_empty() && total_count == 0 {
            Some("No attachments matched this mailbox filter.".to_string())
        } else if page_items.is_empty() && total_count == 0 {
            Some("No catalogued attachments matched the current filters.".to_string())
        } else {
            None
        };

    Ok(AttachmentPageData {
        accounts,
        selected_account_id,
        presets,
        filters: filters.raw,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder,
        items: page_items,
        state: AttachmentListViewState {
            priority_filter,
            page,
            result_count: total_count,
            has_previous_page: page > 1 && start < total_count,
            has_next_page: end < total_count,
            empty_message,
            base_query,
        },
    })
}

fn download_attachment_keys_for_form(
    config: &AppConfig,
    username: &str,
    form: &AttachmentDownloadForm,
) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();

    if form.selection_scope.as_deref() == Some(ATTACHMENT_SELECTION_ALL_MATCHING) {
        let selected_account_id = parse_optional_query_i64(form.account_id.as_deref())?;
        let mut page = 1;
        loop {
            let params = AttachmentListParams {
                q: form.q.clone(),
                account_id: selected_account_id,
                priority: form.priority.clone(),
                sender_address: form.sender_address.clone(),
                sender_name: form.sender_name.clone(),
                sender_domain: form.sender_domain.clone(),
                subject: form.subject.clone(),
                body_text: form.body_text.clone(),
                date_from: form.date_from.clone(),
                date_to: form.date_to.clone(),
                has_attachments: form.has_attachments.clone(),
                extension: form.extension.clone(),
                attachment_name: form.attachment_name.clone(),
                mime_type: form.mime_type.clone(),
                min_size: form.min_size.clone(),
                max_size: form.max_size.clone(),
                min_attachments: form.min_attachments.clone(),
                max_attachments: form.max_attachments.clone(),
                include_inline: form.include_inline.clone(),
                include_inline_images: form.include_inline_images.clone(),
                show_mime_details: form.show_mime_details.clone(),
                download_subfolder: form.download_subfolder.clone(),
                page: Some(page.to_string()),
                flash: None,
                error: None,
            };
            let data = load_attachment_page_data(config, username, &params)?;
            for item in data.items {
                if seen.insert(item.attachment.attachment_key.clone()) {
                    keys.push(item.attachment.attachment_key);
                }
                if keys.len() > MAX_ZIP_ATTACHMENTS {
                    return Err(format!(
                        "Too many attachments matched. Narrow the filters to {} files or fewer.",
                        MAX_ZIP_ATTACHMENTS
                    ));
                }
            }
            if !data.state.has_next_page {
                break;
            }
            page += 1;
        }
    } else {
        for key in &form.attachment_keys {
            let key = key.trim();
            if !key.is_empty() && seen.insert(key.to_string()) {
                keys.push(key.to_string());
            }
        }
    }

    if keys.is_empty() {
        return Err("Select at least one downloadable attachment.".to_string());
    }
    if keys.len() > MAX_ZIP_ATTACHMENTS {
        return Err(format!(
            "Select {} attachments or fewer for one ZIP download.",
            MAX_ZIP_ATTACHMENTS
        ));
    }

    Ok(keys)
}

fn parse_attachment_download_form_body(body: &[u8]) -> AttachmentDownloadForm {
    let mut form = AttachmentDownloadForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "selection_scope" => form.selection_scope = Some(value),
            "q" => form.q = Some(value),
            "account_id" => form.account_id = Some(value),
            "priority" => form.priority = Some(value),
            "sender_address" => form.sender_address = Some(value),
            "sender_name" => form.sender_name = Some(value),
            "sender_domain" => form.sender_domain = Some(value),
            "subject" => form.subject = Some(value),
            "body_text" => form.body_text = Some(value),
            "date_from" => form.date_from = Some(value),
            "date_to" => form.date_to = Some(value),
            "has_attachments" => form.has_attachments = Some(value),
            "extension" => form.extension = Some(value),
            "attachment_name" => form.attachment_name = Some(value),
            "mime_type" => form.mime_type = Some(value),
            "min_size" => form.min_size = Some(value),
            "max_size" => form.max_size = Some(value),
            "min_attachments" => form.min_attachments = Some(value),
            "max_attachments" => form.max_attachments = Some(value),
            "include_inline" => form.include_inline = Some(value),
            "include_inline_images" => form.include_inline_images = Some(value),
            "show_mime_details" => form.show_mime_details = Some(value),
            "download_subfolder" => form.download_subfolder = Some(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

fn parse_attachment_paperless_form_body(body: &[u8]) -> AttachmentPaperlessForm {
    let mut form = AttachmentPaperlessForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

fn build_attachments_zip(
    config: &AppConfig,
    username: &str,
    form: &AttachmentDownloadForm,
) -> Result<TempZipFile, String> {
    cleanup_old_runtime_exports(config)?;
    let keys = download_attachment_keys_for_form(config, username, form)?;
    let download_subfolder =
        normalize_download_subfolder(form.download_subfolder.as_deref().unwrap_or_default())?;
    let mut records = Vec::new();
    let mut total_size = 0_u64;

    for key in keys {
        let record = load_attachment_for_user(config, username, &key)?;
        let size = u64::try_from(record.2.size_bytes.max(0))
            .map_err(|_| "Attachment size could not be represented safely".to_string())?;
        total_size = total_size.saturating_add(size);
        if total_size > MAX_ZIP_BYTES {
            return Err("Selected attachments are too large for one ZIP download.".to_string());
        }
        records.push(record);
    }

    let export_root = runtime_export_root(config);
    fs::create_dir_all(&export_root)
        .map_err(|error| format!("failed to create {}: {error}", export_root.display()))?;
    let filename = format!(
        "mail-archive-attachments-{}.zip",
        Utc::now().format("%Y%m%d-%H%M%S")
    );
    let zip_path = export_root.join(format!("{}-{}", random_hex(8), filename));
    let zip_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&zip_path)
        .map_err(|error| format!("failed to create ZIP file {}: {error}", zip_path.display()))?;
    let mut zip = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .unix_permissions(0o600);
    let mut used_names = HashMap::<String, usize>::new();
    let mut manifest_entries = Vec::new();

    for (account, message, attachment) in records {
        let (_dir, attachment_path) =
            resolve_attachment_payload(config, &account, &message, &attachment)?;
        let entry_name = unique_zip_entry_name(
            zip_entry_name(&account, &message, &attachment, &download_subfolder),
            &mut used_names,
        );
        zip.start_file(entry_name.clone(), options)
            .map_err(|error| format!("failed to start ZIP entry: {error}"))?;
        let mut source = fs::File::open(&attachment_path).map_err(|error| {
            format!(
                "failed to open extracted attachment {}: {error}",
                attachment_path.display()
            )
        })?;
        std::io::copy(&mut source, &mut zip)
            .map_err(|error| format!("failed to write ZIP entry: {error}"))?;
        manifest_entries.push(AttachmentZipManifestEntry {
            zip_path: entry_name,
            account: account.display_name,
            account_id: account.id,
            message_key: message.message_key,
            message_relpath: message.message_relpath,
            subject: message.subject,
            sender: message.from,
            message_timestamp: message.timestamp,
            original_filename: attachment.original_filename,
            mime_type: attachment.mime_type,
            size_bytes: attachment.size_bytes,
            attachment_sha256: attachment.attachment_sha256,
            blob_relpath: attachment.blob_relpath,
            source_message_sha256: attachment.source_message_sha256,
        });
    }

    let manifest = AttachmentZipManifest {
        generated_at: Utc::now().to_rfc3339(),
        source: "mail-archive-ui",
        file_count: manifest_entries.len(),
        total_size_bytes: total_size,
        files: manifest_entries,
    };
    zip.start_file("manifest.json", options)
        .map_err(|error| format!("failed to start ZIP manifest: {error}"))?;
    serde_json::to_writer_pretty(&mut zip, &manifest)
        .map_err(|error| format!("failed to write ZIP manifest: {error}"))?;

    zip.finish()
        .map_err(|error| format!("failed to finish ZIP archive: {error}"))?
        .sync_all()
        .map_err(|error| format!("failed to sync ZIP archive {}: {error}", zip_path.display()))?;
    Ok(TempZipFile {
        filename,
        path: zip_path,
    })
}

fn load_attachment_paperless_handoff(
    connection: &Connection,
    config: &AppConfig,
    username: &str,
    attachment_key: &str,
) -> Result<Option<String>, String> {
    let row = connection
        .query_row(
            "SELECT sent_at, consume_filename FROM attachment_paperless_handoffs WHERE username = ?1 AND attachment_key = ?2 LIMIT 1",
            params![username, attachment_key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|error| format!("failed to query Paperless handoff state: {error}"))?;
    let (sent_at, consume_filename) = match row {
        Some(row) => row,
        None => return Ok(None),
    };
    let consume_root = match config.paperless_consume_root.as_deref() {
        Some(value) => value,
        None => return Ok(Some(sent_at)),
    };
    let consume_root = PathBuf::from(consume_root);
    if !consume_root.is_dir() {
        return Ok(Some(sent_at));
    }
    if !consume_root.join(&consume_filename).is_file() {
        if let Err(error) = connection.execute(
            "DELETE FROM attachment_paperless_handoffs WHERE username = ?1 AND attachment_key = ?2",
            params![username, attachment_key],
        ) {
            eprintln!(
                "failed to clear stale Paperless handoff for user {} attachment {}: {error}",
                username, attachment_key
            );
        }
        return Ok(None);
    }
    Ok(Some(sent_at))
}

#[derive(Debug, Default)]
struct PaperlessHandoffSummary {
    sent: usize,
    skipped: usize,
    sent_attachment_keys: Vec<String>,
    failures: Vec<PaperlessHandoffFailure>,
}

#[derive(Debug)]
struct PaperlessHandoffFailure {
    attachment_key: String,
    filename: String,
    error: String,
}

impl PaperlessHandoffSummary {
    fn flash_message(&self) -> String {
        let base = format!("{} sent to Paperless", pluralize_attachments(self.sent));
        if self.failures.is_empty() {
            base
        } else {
            format!("{base}; {} failed", self.failures.len())
        }
    }

    fn failure_message(&self) -> String {
        let prefix = if self.sent == 0 {
            format!("No attachments were sent; {} failed", self.failures.len())
        } else {
            format!("{} failed", self.failures.len())
        };
        let details = self
            .failures
            .iter()
            .take(3)
            .map(|failure| {
                let label = if failure.filename.is_empty() {
                    failure.attachment_key.as_str()
                } else {
                    failure.filename.as_str()
                };
                format!("{label}: {}", failure.error)
            })
            .collect::<Vec<_>>();
        if details.is_empty() {
            prefix
        } else if self.failures.len() > details.len() {
            format!(
                "{prefix}: {}; and {} more",
                details.join("; "),
                self.failures.len() - details.len()
            )
        } else {
            format!("{prefix}: {}", details.join("; "))
        }
    }
}

fn record_attachment_paperless_handoff(
    config: &AppConfig,
    username: &str,
    attachment: &AttachmentRecord,
    consume_filename: &str,
    sent_at: &str,
) -> Result<(), String> {
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO attachment_paperless_handoffs (
                username,
                attachment_key,
                attachment_sha256,
                original_filename,
                consume_filename,
                sent_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(username, attachment_key) DO UPDATE SET
                attachment_sha256 = excluded.attachment_sha256,
                original_filename = excluded.original_filename,
                consume_filename = excluded.consume_filename,
                sent_at = excluded.sent_at
            "#,
            params![
                username,
                attachment.attachment_key,
                attachment.attachment_sha256,
                attachment.original_filename,
                consume_filename,
                sent_at,
            ],
        )
        .map_err(|error| format!("failed to record Paperless handoff: {error}"))?;
    Ok(())
}

fn send_attachments_to_paperless(
    config: &AppConfig,
    username: &str,
    attachment_keys: &[String],
) -> Result<PaperlessHandoffSummary, String> {
    let consume_root = config
        .paperless_consume_root
        .as_deref()
        .map(PathBuf::from)
        .ok_or_else(|| "Paperless handoff is not configured.".to_string())?;
    let handoff_staging_root = paperless_handoff_staging_root(config, &consume_root);
    fs::create_dir_all(&consume_root).map_err(|error| {
        format!(
            "failed to prepare Paperless consume directory {}: {error}",
            consume_root.display()
        )
    })?;
    fs::create_dir_all(&handoff_staging_root).map_err(|error| {
        format!(
            "failed to prepare Paperless handoff staging directory {}: {error}",
            handoff_staging_root.display()
        )
    })?;
    cleanup_old_paperless_handoff_staging(&handoff_staging_root)?;

    let mut seen = HashSet::new();
    let mut summary = PaperlessHandoffSummary::default();
    for key in attachment_keys {
        let key = key.trim();
        if key.is_empty() || !seen.insert(key.to_string()) {
            continue;
        }

        let connection = open_db(config)?;
        if load_attachment_paperless_handoff(&connection, config, username, key)?.is_some() {
            summary.skipped += 1;
            continue;
        }

        let (account, message, attachment) = match load_attachment_for_user(config, username, key) {
            Ok(record) => record,
            Err(error) => {
                summary.failures.push(PaperlessHandoffFailure {
                    attachment_key: key.to_string(),
                    filename: "attachment".to_string(),
                    error,
                });
                continue;
            }
        };
        let consume_filename = paperless_consume_filename(&attachment.original_filename);
        let (_dir, attachment_path) =
            match resolve_attachment_payload(config, &account, &message, &attachment) {
                Ok(payload) => payload,
                Err(error) => {
                    summary.failures.push(PaperlessHandoffFailure {
                        attachment_key: key.to_string(),
                        filename: consume_filename,
                        error,
                    });
                    continue;
                }
            };
        let sent_at = Utc::now().to_rfc3339();
        let final_path = consume_root.join(&consume_filename);
        if let Err(error) =
            copy_attachment_to_paperless(&attachment_path, &handoff_staging_root, &final_path, key)
        {
            summary.failures.push(PaperlessHandoffFailure {
                attachment_key: key.to_string(),
                filename: consume_filename,
                error,
            });
            continue;
        }
        if let Err(error) = record_attachment_paperless_handoff(
            config,
            username,
            &attachment,
            &consume_filename,
            &sent_at,
        ) {
            summary.failures.push(PaperlessHandoffFailure {
                attachment_key: key.to_string(),
                filename: consume_filename,
                error,
            });
            continue;
        }
        summary.sent += 1;
        summary.sent_attachment_keys.push(key.to_string());
    }

    if summary.sent == 0 && summary.failures.is_empty() {
        return Err("Select at least one attachment that has not already been sent.".to_string());
    }

    Ok(summary)
}

fn paperless_consume_filename(original_filename: &str) -> String {
    filename_component(original_filename, "attachment")
}

fn copy_attachment_to_paperless(
    source_path: &FsPath,
    handoff_staging_root: &FsPath,
    final_path: &FsPath,
    attachment_key: &str,
) -> Result<(), String> {
    fs::create_dir_all(handoff_staging_root).map_err(|error| {
        format!(
            "failed to create Paperless handoff staging directory {}: {error}",
            handoff_staging_root.display()
        )
    })?;
    let tmp_path = handoff_staging_root.join(paperless_handoff_staging_filename(attachment_key));
    let mut source = fs::File::open(source_path).map_err(|error| {
        format!(
            "failed to open attachment {}: {error}",
            source_path.display()
        )
    })?;
    let mut target = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o660)
        .open(&tmp_path)
        .map_err(|error| format!("failed to create {}: {error}", tmp_path.display()))?;
    std::io::copy(&mut source, &mut target)
        .map_err(|error| format!("failed to copy attachment to Paperless: {error}"))?;
    target
        .sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", tmp_path.display()))?;
    fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o660)).map_err(|error| {
        format!(
            "failed to set permissions on {}: {error}",
            tmp_path.display()
        )
    })?;
    sync_directory(handoff_staging_root)?;
    publish_staged_paperless_file(&tmp_path, final_path)
}

fn paperless_handoff_staging_root(config: &AppConfig, consume_root: &FsPath) -> PathBuf {
    config
        .paperless_handoff_staging_root
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| {
            consume_root
                .parent()
                .map(|parent| parent.join("handoff-staging"))
        })
        .unwrap_or_else(|| consume_root.join("handoff-staging"))
}

fn paperless_handoff_staging_filename(attachment_key: &str) -> String {
    format!(
        "{}{}-{}{}",
        PAPERLESS_HANDOFF_STAGING_PREFIX,
        random_hex(8),
        filename_component(attachment_key, "attachment-key"),
        PAPERLESS_HANDOFF_STAGING_SUFFIX
    )
}

fn sleep_before_paperless_publish_retry() {
    #[cfg(not(test))]
    std::thread::sleep(std::time::Duration::from_millis(
        PAPERLESS_PUBLISH_RETRY_DELAY_MS,
    ));
}

fn publish_staged_paperless_file(tmp_path: &FsPath, final_path: &FsPath) -> Result<(), String> {
    for attempt in 0..PAPERLESS_PUBLISH_RETRY_ATTEMPTS {
        match fs::hard_link(tmp_path, final_path) {
            Ok(()) => {
                fs::remove_file(tmp_path).map_err(|error| {
                    format!(
                        "failed to remove staged Paperless handoff file {}: {error}",
                        tmp_path.display()
                    )
                })?;
                if let Some(parent) = final_path.parent() {
                    sync_directory(parent)?;
                }
                return Ok(());
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                if attempt + 1 < PAPERLESS_PUBLISH_RETRY_ATTEMPTS {
                    sleep_before_paperless_publish_retry();
                    continue;
                }
                let _ = fs::remove_file(tmp_path);
                return Err(format!(
                    "Paperless consume file {} already exists after waiting",
                    final_path.display()
                ));
            }
            Err(error) if is_cross_device_link(&error) => {
                return copy_staged_paperless_file_across_devices(tmp_path, final_path);
            }
            Err(error) => {
                let _ = fs::remove_file(tmp_path);
                return Err(format!(
                    "failed to publish Paperless consume file {}: {error}",
                    final_path.display()
                ));
            }
        }
    }

    let _ = fs::remove_file(tmp_path);
    Err(format!(
        "failed to publish Paperless consume file {}",
        final_path.display()
    ))
}

fn is_cross_device_link(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(18)
}

fn copy_staged_paperless_file_across_devices(
    tmp_path: &FsPath,
    final_path: &FsPath,
) -> Result<(), String> {
    let final_parent = final_path.parent().ok_or_else(|| {
        format!(
            "Paperless consume path {} has no parent",
            final_path.display()
        )
    })?;

    for attempt in 0..PAPERLESS_PUBLISH_RETRY_ATTEMPTS {
        let consume_tmp_path = final_parent.join(format!(
            "{}publish-{}{}",
            PAPERLESS_HANDOFF_STAGING_PREFIX,
            random_hex(8),
            PAPERLESS_HANDOFF_STAGING_SUFFIX
        ));

        if let Err(error) = copy_file_to_new_path(tmp_path, &consume_tmp_path, 0o660) {
            let _ = fs::remove_file(&consume_tmp_path);
            let _ = fs::remove_file(tmp_path);
            return Err(error);
        }

        match fs::hard_link(&consume_tmp_path, final_path) {
            Ok(()) => {
                fs::remove_file(&consume_tmp_path).map_err(|error| {
                    format!(
                        "failed to remove temporary Paperless consume file {}: {error}",
                        consume_tmp_path.display()
                    )
                })?;
                let _ = fs::remove_file(tmp_path);
                sync_directory(final_parent)?;
                return Ok(());
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&consume_tmp_path);
                if attempt + 1 < PAPERLESS_PUBLISH_RETRY_ATTEMPTS {
                    sleep_before_paperless_publish_retry();
                    continue;
                }
                let _ = fs::remove_file(tmp_path);
                return Err(format!(
                    "Paperless consume file {} already exists after waiting",
                    final_path.display()
                ));
            }
            Err(error) => {
                let _ = fs::remove_file(&consume_tmp_path);
                let _ = fs::remove_file(tmp_path);
                return Err(format!(
                    "failed to publish Paperless consume file {}: {error}",
                    final_path.display()
                ));
            }
        }
    }

    let _ = fs::remove_file(tmp_path);
    Err(format!(
        "failed to publish Paperless consume file {}",
        final_path.display()
    ))
}

fn copy_file_to_new_path(
    source_path: &FsPath,
    target_path: &FsPath,
    mode: u32,
) -> Result<(), String> {
    let mut source = fs::File::open(source_path)
        .map_err(|error| format!("failed to open {}: {error}", source_path.display()))?;
    let mut target = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(target_path)
        .map_err(|error| format!("failed to create {}: {error}", target_path.display()))?;
    std::io::copy(&mut source, &mut target)
        .map_err(|error| format!("failed to copy {}: {error}", target_path.display()))?;
    target
        .sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", target_path.display()))?;
    fs::set_permissions(target_path, fs::Permissions::from_mode(mode)).map_err(|error| {
        format!(
            "failed to set permissions on {}: {error}",
            target_path.display()
        )
    })?;
    if let Some(parent) = target_path.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

fn cleanup_old_paperless_handoff_staging(handoff_staging_root: &FsPath) -> Result<(), String> {
    cleanup_paperless_handoff_staging_older_than(
        handoff_staging_root,
        PAPERLESS_HANDOFF_STAGING_MAX_AGE_SECONDS,
    )
}

fn cleanup_paperless_handoff_staging_older_than(
    handoff_staging_root: &FsPath,
    max_age_seconds: i64,
) -> Result<(), String> {
    let entries = match fs::read_dir(handoff_staging_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "failed to read Paperless handoff staging directory {}: {error}",
                handoff_staging_root.display()
            ))
        }
    };
    let now = Utc::now().timestamp();
    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to read Paperless handoff staging directory {}: {error}",
                handoff_staging_root.display()
            )
        })?;
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();
        if !file_name.starts_with(PAPERLESS_HANDOFF_STAGING_PREFIX)
            || !file_name.ends_with(PAPERLESS_HANDOFF_STAGING_SUFFIX)
        {
            continue;
        }
        let metadata = entry.metadata().map_err(|error| {
            format!(
                "failed to inspect Paperless handoff staging file {}: {error}",
                entry.path().display()
            )
        })?;
        if !metadata.is_file() {
            continue;
        }
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(i64::MAX))
            .unwrap_or(now);
        if now.saturating_sub(modified) > max_age_seconds {
            fs::remove_file(entry.path()).map_err(|error| {
                format!(
                    "failed to remove stale Paperless handoff staging file {}: {error}",
                    entry.path().display()
                )
            })?;
        }
    }
    Ok(())
}

fn zip_entry_name(
    account: &AccountRecord,
    message: &AttachmentMessageRecord,
    attachment: &AttachmentRecord,
    download_subfolder: &str,
) -> String {
    let date = DateTime::<Utc>::from_timestamp(message.timestamp, 0)
        .map(|value| value.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "unknown-date".to_string());
    let account_name = filename_component(&account.display_name, "mailbox");
    let subject_name = filename_component(&message.subject, "message");
    let entry = format!(
        "{}/{} - {}/{}",
        account_name,
        date,
        subject_name,
        filename_component(&attachment.original_filename, "attachment")
    );
    if download_subfolder.trim().is_empty() {
        entry
    } else {
        format!("{download_subfolder}/{entry}")
    }
}

fn unique_zip_entry_name(base: String, used_names: &mut HashMap<String, usize>) -> String {
    let count = used_names.entry(base.clone()).or_insert(0);
    if *count == 0 {
        *count = 1;
        base
    } else {
        let name = zip_entry_name_with_numeric_suffix(&base, *count);
        *count += 1;
        name
    }
}

fn zip_entry_name_with_numeric_suffix(base: &str, suffix: usize) -> String {
    let path = FsPath::new(base);
    let parent = path.parent().filter(|value| !value.as_os_str().is_empty());
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(base);
    let suffixed = if let Some((stem, extension)) = filename.rsplit_once('.') {
        if stem.is_empty() || extension.is_empty() {
            format!("{filename} ({suffix})")
        } else {
            format!("{stem} ({suffix}).{extension}")
        }
    } else {
        format!("{filename} ({suffix})")
    };
    parent
        .map(|value| value.join(&suffixed).to_string_lossy().to_string())
        .unwrap_or(suffixed)
}

fn cleanup_old_runtime_exports(config: &AppConfig) -> Result<(), String> {
    let export_root = runtime_export_root(config);
    let entries = match fs::read_dir(&export_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "failed to read runtime export directory {}: {error}",
                export_root.display()
            ))
        }
    };
    let now = Utc::now().timestamp();
    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to read runtime export directory {}: {error}",
                export_root.display()
            )
        })?;
        let metadata = entry.metadata().map_err(|error| {
            format!(
                "failed to inspect runtime export {}: {error}",
                entry.path().display()
            )
        })?;
        if !metadata.is_file() {
            continue;
        }
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(i64::MAX))
            .unwrap_or(now);
        if now.saturating_sub(modified) > RUNTIME_EXPORT_MAX_AGE_SECONDS {
            fs::remove_file(entry.path()).map_err(|error| {
                format!(
                    "failed to remove stale runtime export {}: {error}",
                    entry.path().display()
                )
            })?;
        }
    }
    Ok(())
}

fn verify_attachment_archive(
    config: &AppConfig,
    repair: bool,
    report_path: Option<&FsPath>,
) -> Result<AttachmentVerificationReport, String> {
    let connection = open_db(config)?;
    let accounts = list_all_accounts(config)?;
    let mut report = AttachmentVerificationReport {
        generated_at: Utc::now().to_rfc3339(),
        accounts_checked: 0,
        messages_checked: 0,
        attachments_checked: 0,
        missing_sources: 0,
        missing_blobs: 0,
        mismatched_blobs: 0,
        orphaned_blobs: 0,
        warnings: Vec::new(),
    };

    for account in accounts {
        report.accounts_checked += 1;
        let account_paths = ensure_account_paths(config, &account)?;
        let rows = load_attachment_catalog_rows_for_account(&connection, account.id)?;
        let mut seen_messages = HashSet::<String>::new();
        let mut referenced_blobs = HashSet::<String>::new();

        for (message, attachment) in rows {
            report.attachments_checked += 1;
            if seen_messages.insert(message.message_key.clone()) {
                report.messages_checked += 1;
            }

            let source_path = account_paths.maildir.join(&message.message_relpath);
            if !source_path.is_file() {
                report.missing_sources += 1;
                report.warnings.push(format!(
                    "missing source message account={} attachment={} source={}",
                    account.id,
                    attachment.attachment_key,
                    source_path.display()
                ));
                continue;
            }

            let blob_relpath = attachment.blob_relpath.clone().unwrap_or_else(|| {
                attachment_blob_relpath(&attachment.attachment_sha256)
                    .to_string_lossy()
                    .to_string()
            });
            let blob_path = attachment_blob_path(&account_paths, &blob_relpath)?;
            let mut blob_ok = false;
            let mut blob_missing = false;
            let mut blob_mismatched = false;
            if blob_path.is_file() {
                let blob_sha = sha256_file(&blob_path)?;
                let blob_size = fs::metadata(&blob_path)
                    .map_err(|error| format!("failed to inspect {}: {error}", blob_path.display()))?
                    .len();
                if blob_sha == attachment.attachment_sha256
                    && i64::try_from(blob_size).ok() == Some(attachment.size_bytes)
                {
                    blob_ok = true;
                } else {
                    blob_mismatched = true;
                    report.mismatched_blobs += 1;
                    report.warnings.push(format!(
                        "mismatched attachment blob account={} attachment={} blob={}",
                        account.id,
                        attachment.attachment_key,
                        blob_path.display()
                    ));
                }
            } else {
                blob_missing = true;
                report.missing_blobs += 1;
                report.warnings.push(format!(
                    "missing attachment blob account={} attachment={} blob={}",
                    account.id,
                    attachment.attachment_key,
                    blob_path.display()
                ));
            }

            if !blob_ok && repair {
                let (_dir, repaired_path) =
                    resolve_attachment_payload(config, &account, &message, &attachment)?;
                let repaired_sha = sha256_file(&repaired_path)?;
                if repaired_sha == attachment.attachment_sha256 {
                    let repaired_relpath = attachment_blob_relpath(&repaired_sha)
                        .to_string_lossy()
                        .to_string();
                    let now = Utc::now().to_rfc3339();
                    connection
                        .execute(
                            r#"
                            UPDATE attachment_catalog
                            SET blob_relpath = ?3,
                                last_verified_at = ?4
                            WHERE account_id = ?1
                              AND attachment_key = ?2
                            "#,
                            params![account.id, attachment.attachment_key, repaired_relpath, now],
                        )
                        .map_err(|error| {
                            format!("failed to update repaired attachment metadata: {error}")
                        })?;
                    if blob_missing {
                        report.missing_blobs = report.missing_blobs.saturating_sub(1);
                    }
                    if blob_mismatched {
                        report.mismatched_blobs = report.mismatched_blobs.saturating_sub(1);
                    }
                    referenced_blobs.insert(repaired_relpath);
                    continue;
                }
            }

            if blob_ok {
                let now = Utc::now().to_rfc3339();
                connection
                    .execute(
                        r#"
                        UPDATE attachment_catalog
                        SET blob_relpath = ?3,
                            last_verified_at = ?4
                        WHERE account_id = ?1
                          AND attachment_key = ?2
                        "#,
                        params![account.id, attachment.attachment_key, blob_relpath, now],
                    )
                    .map_err(|error| {
                        format!("failed to update attachment verification time: {error}")
                    })?;
            }
            referenced_blobs.insert(blob_relpath);
        }

        for blob in collect_regular_files(&account_paths.attachment_blob_root).unwrap_or_default() {
            let relpath = blob
                .strip_prefix(&account_paths.hidden_sync_root)
                .map(|value| value.to_string_lossy().to_string())
                .unwrap_or_else(|_| blob.to_string_lossy().to_string());
            if !referenced_blobs.contains(&relpath) {
                report.orphaned_blobs += 1;
                report.warnings.push(format!(
                    "orphaned attachment blob account={} blob={}",
                    account.id,
                    blob.display()
                ));
            }
        }
    }

    if let Some(path) = report_path {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "failed to create report directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        let bytes = serde_json::to_vec_pretty(&report)
            .map_err(|error| format!("failed to encode attachment verification report: {error}"))?;
        write_private_file(path, &bytes)?;
    }

    Ok(report)
}

fn load_attachment_for_user(
    config: &AppConfig,
    username: &str,
    attachment_key_value: &str,
) -> Result<(AccountRecord, AttachmentMessageRecord, AttachmentRecord), String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                a.id,
                a.username,
                a.provider_kind,
                a.display_name,
                a.imap_host,
                a.imap_port,
                a.imap_username,
                a.folder_mode,
                a.folder_patterns_json,
                a.encrypted_secret,
                a.sync_enabled,
                a.created_at,
                a.updated_at,
                a.last_sync_started_at,
                a.last_sync_finished_at,
                a.last_sync_status,
                a.last_sync_error,
                a.last_sync_phase,
                a.last_sync_code,
                a.last_sync_summary,
                a.last_sync_detail,
                m.account_id,
                m.message_key,
                m.message_relpath,
                m.message_mtime,
                m.message_size,
                m.subject,
                m.sender,
                m.timestamp,
                m.last_scanned_at,
                m.has_attachments,
                c.attachment_key,
                c.account_id,
                c.message_key,
                c.attachment_index,
                c.attachment_sha256,
                c.original_filename,
                c.safe_filename,
                c.extension,
                c.mime_type,
                c.size_bytes,
                c.is_inline_artifact,
                c.blob_relpath,
                c.source_message_sha256,
                c.last_verified_at,
                c.created_at,
                c.updated_at,
                c.last_seen_at
            FROM attachment_catalog c
            INNER JOIN attachment_messages m
                ON m.account_id = c.account_id
               AND m.message_key = c.message_key
            INNER JOIN accounts a
                ON a.id = c.account_id
            WHERE a.username = ?1 AND c.attachment_key = ?2
            LIMIT 1
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment lookup: {error}"))?;
    statement
        .query_row(params![username, attachment_key_value], |row| {
            Ok((
                AccountRecord {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    provider_kind: row.get(2)?,
                    display_name: row.get(3)?,
                    imap_host: row.get(4)?,
                    imap_port: row.get(5)?,
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
                    last_sync_phase: row.get(17)?,
                    last_sync_code: row.get(18)?,
                    last_sync_summary: row.get(19)?,
                    last_sync_detail: row.get(20)?,
                },
                AttachmentMessageRecord {
                    account_id: row.get(21)?,
                    message_key: row.get(22)?,
                    message_relpath: row.get(23)?,
                    message_mtime: row.get(24)?,
                    message_size: row.get(25)?,
                    subject: row.get(26)?,
                    from: row.get(27)?,
                    timestamp: row.get(28)?,
                    last_scanned_at: row.get(29)?,
                    has_attachments: row.get::<_, i64>(30)? != 0,
                },
                AttachmentRecord {
                    attachment_key: row.get(31)?,
                    account_id: row.get(32)?,
                    message_key: row.get(33)?,
                    attachment_index: row.get(34)?,
                    attachment_sha256: row.get(35)?,
                    original_filename: row.get(36)?,
                    safe_filename: row.get(37)?,
                    extension: row.get(38)?,
                    mime_type: row.get(39)?,
                    size_bytes: row.get(40)?,
                    is_inline_artifact: row.get::<_, i64>(41)? != 0,
                    blob_relpath: row.get(42)?,
                    source_message_sha256: row.get(43)?,
                    last_verified_at: row.get(44)?,
                    created_at: row.get(45)?,
                    updated_at: row.get(46)?,
                    last_seen_at: row.get(47)?,
                },
            ))
        })
        .optional()
        .map_err(|error| format!("failed to load attachment row: {error}"))?
        .ok_or_else(|| "Attachment not found".to_string())
}

fn resolve_attachment_payload(
    config: &AppConfig,
    account: &AccountRecord,
    message: &AttachmentMessageRecord,
    attachment: &AttachmentRecord,
) -> Result<(TempExtractionDir, PathBuf), String> {
    let account_paths = ensure_account_paths(config, account)?;
    if let Some(blob_relpath) = attachment.blob_relpath.as_deref() {
        let blob_path = attachment_blob_path(&account_paths, blob_relpath)?;
        if blob_path.is_file() {
            let blob_sha = sha256_file(&blob_path)?;
            if blob_sha == attachment.attachment_sha256 {
                return Ok((
                    TempExtractionDir {
                        path: PathBuf::new(),
                    },
                    blob_path,
                ));
            }
        }
    }

    let message_path = account_paths.maildir.join(&message.message_relpath);
    let source_message_sha256 = sha256_file(&message_path)?;
    let (extraction_dir, scanned) = scan_message_attachments_for_catalog(
        config,
        &account_paths,
        account.id,
        &message.message_key,
        &message_path,
        &source_message_sha256,
    )?;
    scanned
        .into_iter()
        .find(|(scanned_attachment, _)| {
            scanned_attachment.attachment_key == attachment.attachment_key
        })
        .map(|(_, path)| (extraction_dir, path))
        .ok_or_else(|| {
            "Attachment payload could not be reconstructed from the archived message".to_string()
        })
}

fn collect_live_messages_for_account(
    config: &AppConfig,
    account: &AccountRecord,
    query: &str,
) -> Result<Vec<LiveMessageRecord>, String> {
    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        return Ok(Vec::new());
    }

    let mut by_key = HashMap::<String, LiveMessageRecord>::new();
    for file_path in list_notmuch_message_files(&account_paths, query)? {
        let relpath = message_relative_path(&account_paths, &file_path)?
            .to_string_lossy()
            .to_string();
        let metadata = read_message_metadata(&file_path)?;
        let message_key = message_key_from_metadata(&metadata)?;
        let record = by_key
            .entry(message_key.clone())
            .or_insert_with(|| LiveMessageRecord {
                message_key: message_key.clone(),
                message_relpaths: Vec::new(),
                subject: metadata.subject.clone(),
                from: metadata.from.clone(),
                timestamp: metadata.timestamp,
            });
        record.message_relpaths.push(relpath);
    }

    let mut messages = by_key.into_values().collect::<Vec<_>>();
    messages.sort_by_key(|message| Reverse(message.timestamp));
    Ok(messages)
}

fn search_mail(
    config: &AppConfig,
    username: &str,
    selected_account_id: Option<i64>,
    filters: MessageSearchFilters,
    priority_filter: SenderPriorityFilter,
) -> Result<Vec<SearchResult>, String> {
    let filters = parse_message_search_filters(filters)?;
    let query = notmuch_query_for_filters(&filters);
    let connection = open_db(config)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let mut results = Vec::new();
    for account in list_accounts_for_user(config, username)?
        .into_iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        for item in collect_live_messages_for_account(config, &account, &query)? {
            let has_attachments =
                message_catalog_has_attachments(&connection, account.id, &item.message_key)?;
            if !message_matches_filters(&item, &filters, Some(has_attachments)) {
                continue;
            }
            let sender_priority = priority_rules.view_for_sender(&item.from);
            if !priority_filter.matches(sender_priority.priority) {
                continue;
            }
            results.push(SearchResult {
                account_name: account.display_name.clone(),
                message_relpath: item.message_relpaths.first().cloned().unwrap_or_default(),
                timestamp: item.timestamp,
                date_label: format_timestamp_date_label(item.timestamp),
                from: item.from.clone(),
                subject: item.subject.clone(),
                tags: Vec::new(),
                sender_priority,
            });
        }
    }

    results.sort_by(|left, right| {
        left.sender_priority
            .priority
            .sort_rank()
            .cmp(&right.sender_priority.priority.sort_rank())
            .then(right.timestamp.cmp(&left.timestamp))
    });
    Ok(results)
}

fn load_account_progress_snapshot(
    config: &AppConfig,
    account_id: i64,
) -> Result<Option<AccountProgressSnapshotRecord>, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            r#"
            SELECT
                account_id,
                archived_message_count,
                indexed_message_count,
                pending_index_count,
                index_coverage_percent,
                archive_file_count,
                overlap_file_count,
                last_computed_at,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note
            FROM account_progress_snapshots
            WHERE account_id = ?1
            "#,
            params![account_id],
            |row| {
                Ok(AccountProgressSnapshotRecord {
                    account_id: row.get(0)?,
                    archived_message_count: row.get(1)?,
                    indexed_message_count: row.get(2)?,
                    pending_index_count: row.get(3)?,
                    index_coverage_percent: row.get(4)?,
                    archive_file_count: row.get(5)?,
                    overlap_file_count: row.get(6)?,
                    last_computed_at: row.get(7)?,
                    source_sync_finished_at: row.get(8)?,
                    snapshot_status: row.get(9)?,
                    snapshot_note: row.get(10)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("failed to load account progress snapshot: {error}"))
}

fn store_account_progress_snapshot(
    config: &AppConfig,
    account_id: i64,
    counts: &AccountProgressCounts,
    source_sync_finished_at: Option<&str>,
    snapshot_status: &str,
    snapshot_note: Option<&str>,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let now = Utc::now().to_rfc3339();
    connection
        .execute(
            r#"
            INSERT INTO account_progress_snapshots (
                account_id,
                archived_message_count,
                indexed_message_count,
                pending_index_count,
                index_coverage_percent,
                archive_file_count,
                overlap_file_count,
                last_computed_at,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT(account_id) DO UPDATE SET
                archived_message_count = excluded.archived_message_count,
                indexed_message_count = excluded.indexed_message_count,
                pending_index_count = excluded.pending_index_count,
                index_coverage_percent = excluded.index_coverage_percent,
                archive_file_count = excluded.archive_file_count,
                overlap_file_count = excluded.overlap_file_count,
                last_computed_at = excluded.last_computed_at,
                source_sync_finished_at = excluded.source_sync_finished_at,
                snapshot_status = excluded.snapshot_status,
                snapshot_note = excluded.snapshot_note
            "#,
            params![
                account_id,
                counts.archived_message_count,
                counts.indexed_message_count,
                counts.pending_index_count,
                counts.index_coverage_percent,
                counts.archive_file_count,
                counts.overlap_file_count,
                now,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note,
            ],
        )
        .map_err(|error| format!("failed to store account progress snapshot: {error}"))?;
    Ok(())
}

fn snapshot_counts(snapshot: &AccountProgressSnapshotRecord) -> AccountProgressCounts {
    AccountProgressCounts {
        archived_message_count: snapshot.archived_message_count,
        indexed_message_count: snapshot.indexed_message_count,
        pending_index_count: snapshot.pending_index_count,
        index_coverage_percent: snapshot.index_coverage_percent,
        archive_file_count: snapshot.archive_file_count,
        overlap_file_count: snapshot.overlap_file_count,
    }
}

fn load_message_mailbox_instances_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<MessageMailboxInstanceRecord>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                account_id,
                message_key,
                raw_mailbox_path,
                visible_relpath,
                hidden_relpath,
                account_slug,
                mailbox_slug,
                filename,
                last_seen_at
            FROM message_mailbox_instances
            WHERE account_id = ?1
            "#,
        )
        .map_err(|error| format!("failed to prepare mailbox instance query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok(MessageMailboxInstanceRecord {
                account_id: row.get(0)?,
                message_key: row.get(1)?,
                raw_mailbox_path: row.get(2)?,
                visible_relpath: row.get(3)?,
                hidden_relpath: row.get(4)?,
                account_slug: row.get(5)?,
                mailbox_slug: row.get(6)?,
                filename: row.get(7)?,
                last_seen_at: row.get(8)?,
            })
        })
        .map_err(|error| format!("failed to load mailbox instances: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode mailbox instances: {error}"))
}

fn visible_account_slug(config: &AppConfig, account: &AccountRecord) -> Result<String, String> {
    let accounts = list_accounts_for_user(config, &account.username)?;
    let base_source = if account.display_name.trim().is_empty() {
        account.imap_username.as_str()
    } else {
        account.display_name.as_str()
    };
    let base = slugify_component(base_source, "mailbox");
    let conflicting_count = accounts
        .iter()
        .filter(|candidate| {
            let candidate_source = if candidate.display_name.trim().is_empty() {
                candidate.imap_username.as_str()
            } else {
                candidate.display_name.as_str()
            };
            slugify_component(candidate_source, "mailbox") == base
        })
        .count();
    if conflicting_count > 1 {
        Ok(format!("{base}--{}", account.id))
    } else {
        Ok(base)
    }
}

fn preferred_mailbox_slug(raw_mailbox_path: &str) -> String {
    match raw_mailbox_path.trim().to_ascii_lowercase().as_str() {
        "" | "inbox" => "inbox".to_string(),
        "[gmail]/all mail" => "archive".to_string(),
        "[gmail]/sent mail" => "sent".to_string(),
        "[gmail]/drafts" => "drafts".to_string(),
        "[gmail]/important" => "important".to_string(),
        "[gmail]/starred" => "starred".to_string(),
        "[gmail]/spam" => "spam".to_string(),
        "[gmail]/trash" => "trash".to_string(),
        other => {
            let label = other.rsplit('/').next().unwrap_or(other);
            slugify_component(label, "mailbox")
        }
    }
}

fn raw_mailbox_path_from_hidden_relpath(hidden_relpath: &str) -> String {
    let components = hidden_relpath
        .split('/')
        .filter(|component| !component.is_empty())
        .collect::<Vec<_>>();
    let marker = components
        .iter()
        .position(|component| matches!(*component, "cur" | "new" | "tmp"));
    match marker {
        Some(0) | None => "Inbox".to_string(),
        Some(index) => components[..index].join("/"),
    }
}

fn short_message_key(message_key: &str) -> String {
    sha256_hex(message_key.as_bytes())
        .chars()
        .take(8)
        .collect::<String>()
}

fn visible_message_subject(subject: &str) -> String {
    let sanitized = subject
        .chars()
        .map(|character| {
            if character == '\0' || character == '/' || character == '\\' || character.is_control()
            {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let visible = if sanitized.chars().count() > VISIBLE_MESSAGE_SUBJECT_MAX_CHARS {
        sanitized
            .chars()
            .take(VISIBLE_MESSAGE_SUBJECT_MAX_CHARS)
            .collect::<String>()
            .trim()
            .to_string()
    } else {
        sanitized
    };
    if visible.is_empty() {
        "No Subject".to_string()
    } else {
        visible
    }
}

fn visible_message_filename(timestamp: i64, subject: &str, message_key: &str) -> String {
    let date_label = DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.format("%Y-%m-%d %H-%M").to_string())
        .unwrap_or_else(|| "1970-01-01 00-00".to_string());
    format!(
        "{} - {} [{}].eml",
        date_label,
        visible_message_subject(subject),
        short_message_key(message_key)
    )
}

fn timestamp_year_month(timestamp: i64) -> (String, String) {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| {
            (
                value.format("%Y").to_string(),
                value.format("%m").to_string(),
            )
        })
        .unwrap_or_else(|| ("1970".to_string(), "01".to_string()))
}

fn same_file_identity(left: &FsPath, right: &FsPath) -> Result<bool, String> {
    let left_meta = fs::metadata(left)
        .map_err(|error| format!("failed to inspect {}: {error}", left.display()))?;
    let right_meta = fs::metadata(right)
        .map_err(|error| format!("failed to inspect {}: {error}", right.display()))?;
    Ok(left_meta.dev() == right_meta.dev() && left_meta.ino() == right_meta.ino())
}

fn ensure_hard_link(source: &FsPath, destination: &FsPath) -> Result<(), String> {
    if destination.exists() {
        if same_file_identity(source, destination)? {
            return Ok(());
        }
        fs::remove_file(destination)
            .map_err(|error| format!("failed to replace {}: {error}", destination.display()))?;
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }
    fs::hard_link(source, destination).map_err(|error| {
        format!(
            "failed to link {} to {}: {error}",
            source.display(),
            destination.display()
        )
    })
}

fn reconcile_visible_mirror_read_acl(
    config: &AppConfig,
    account_paths: &AccountPaths,
    destination: &FsPath,
) -> Result<(), String> {
    let Some(group) = config.visible_mirror_read_group.as_deref() else {
        return Ok(());
    };

    let mut directory = destination.parent();
    while let Some(path) = directory {
        if !path.starts_with(&account_paths.visible_emails_root) {
            break;
        }
        setfacl(path, &format!("g:{group}:r-x"))?;
        if path == account_paths.visible_emails_root {
            break;
        }
        directory = path.parent();
    }

    setfacl(destination, &format!("g:{group}:r--"))
}

fn setfacl(path: &FsPath, acl: &str) -> Result<(), String> {
    let output = Command::new("setfacl")
        .args(["-m", acl])
        .arg(path)
        .output()
        .map_err(|error| format!("failed to run setfacl for {}: {error}", path.display()))?;
    if output.status.success() {
        return Ok(());
    }

    Err(command_failure_detail("setfacl", &output))
}

fn prune_empty_ancestors(path: &FsPath, stop_at: &FsPath) -> Result<(), String> {
    let mut current = path.to_path_buf();
    while current.starts_with(stop_at) && current != stop_at {
        match fs::remove_dir(&current) {
            Ok(()) => {
                if let Some(parent) = current.parent() {
                    current = parent.to_path_buf();
                } else {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::DirectoryNotEmpty => break,
            Err(error) if error.kind() == ErrorKind::NotFound => break,
            Err(error) => {
                return Err(format!(
                    "failed to prune empty directory {}: {error}",
                    current.display()
                ))
            }
        }
    }
    Ok(())
}

fn rebuild_message_catalog_and_visible_mailboxes(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<AccountProgressCounts, String> {
    #[derive(Clone)]
    struct PendingInstance {
        message_key: String,
        hidden_relpath: String,
        raw_mailbox_path: String,
        subject: String,
        timestamp: i64,
        last_seen_at: String,
    }

    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        let empty = AccountProgressCounts::default();
        store_account_progress_snapshot(
            config,
            account.id,
            &empty,
            account.last_sync_finished_at.as_deref(),
            "stale",
            Some("Use Update now or Repair search to rebuild dashboard counts."),
        )?;
        return Ok(empty);
    }

    let mut connection = open_db(config)?;
    let previous_instances = load_message_mailbox_instances_for_account(&connection, account.id)?;
    let account_slug = visible_account_slug(config, account)?;
    let mut pending_instances = Vec::new();
    let mut catalog_by_key = HashMap::<String, MessageCatalogRecord>::new();

    for file_path in list_notmuch_message_files(&account_paths, "*")? {
        let metadata = read_message_metadata(&file_path)?;
        let message_key = message_key_from_metadata(&metadata)?;

        let hidden_relpath = message_relative_path(&account_paths, &file_path)?
            .to_string_lossy()
            .to_string();
        let raw_mailbox_path = raw_mailbox_path_from_hidden_relpath(&hidden_relpath);
        let last_seen_at = Utc::now().to_rfc3339();
        let message_sha256 = sha256_file(&file_path)?;
        pending_instances.push(PendingInstance {
            message_key: message_key.clone(),
            hidden_relpath: hidden_relpath.clone(),
            raw_mailbox_path,
            subject: metadata.subject.clone(),
            timestamp: metadata.timestamp,
            last_seen_at: last_seen_at.clone(),
        });
        catalog_by_key
            .entry(message_key.clone())
            .and_modify(|record| {
                if hidden_relpath < record.canonical_hidden_relpath {
                    record.canonical_hidden_relpath = hidden_relpath.clone();
                }
            })
            .or_insert_with(|| MessageCatalogRecord {
                account_id: account.id,
                message_key,
                canonical_hidden_relpath: hidden_relpath,
                subject: metadata.subject,
                sender: metadata.from,
                timestamp: metadata.timestamp,
                message_sha256,
                last_seen_at,
            });
    }

    let mut mailbox_slug_map = HashMap::<String, String>::new();
    let mut grouped_mailboxes = HashMap::<String, Vec<String>>::new();
    for raw_mailbox_path in pending_instances
        .iter()
        .map(|instance| instance.raw_mailbox_path.clone())
        .collect::<HashSet<_>>()
    {
        grouped_mailboxes
            .entry(preferred_mailbox_slug(&raw_mailbox_path))
            .or_default()
            .push(raw_mailbox_path);
    }
    for (preferred_slug, mut mailboxes) in grouped_mailboxes {
        mailboxes.sort();
        for (index, raw_mailbox_path) in mailboxes.into_iter().enumerate() {
            let mailbox_slug = if index == 0 {
                preferred_slug.clone()
            } else {
                format!(
                    "{}--{}",
                    preferred_slug,
                    slugify_component(&raw_mailbox_path, "mailbox")
                )
            };
            mailbox_slug_map.insert(raw_mailbox_path, mailbox_slug);
        }
    }

    let mut used_visible_relpaths = HashSet::new();
    let mut desired_instances = Vec::new();
    for instance in pending_instances {
        let mailbox_slug = mailbox_slug_map
            .get(&instance.raw_mailbox_path)
            .cloned()
            .unwrap_or_else(|| preferred_mailbox_slug(&instance.raw_mailbox_path));
        let mailbox_dir = format!("{account_slug}-{mailbox_slug}");
        let (year, month) = timestamp_year_month(instance.timestamp);
        let mut filename =
            visible_message_filename(instance.timestamp, &instance.subject, &instance.message_key);
        let mut visible_relpath = PathBuf::from(&mailbox_dir)
            .join(&year)
            .join(&month)
            .join(&filename)
            .to_string_lossy()
            .to_string();
        if !used_visible_relpaths.insert(visible_relpath.clone()) {
            filename = format!(
                "{}--{}.eml",
                filename.trim_end_matches(".eml"),
                short_message_key(&instance.hidden_relpath)
            );
            visible_relpath = PathBuf::from(&mailbox_dir)
                .join(&year)
                .join(&month)
                .join(&filename)
                .to_string_lossy()
                .to_string();
            used_visible_relpaths.insert(visible_relpath.clone());
        }
        desired_instances.push(MessageMailboxInstanceRecord {
            account_id: account.id,
            message_key: instance.message_key,
            raw_mailbox_path: instance.raw_mailbox_path,
            visible_relpath,
            hidden_relpath: instance.hidden_relpath,
            account_slug: account_slug.clone(),
            mailbox_slug,
            filename,
            last_seen_at: instance.last_seen_at,
        });
    }

    let desired_visible_relpaths = desired_instances
        .iter()
        .map(|instance| instance.visible_relpath.clone())
        .collect::<HashSet<_>>();
    for instance in &desired_instances {
        let source = account_paths.maildir.join(&instance.hidden_relpath);
        let destination = account_paths
            .visible_emails_root
            .join(&instance.visible_relpath);
        ensure_hard_link(&source, &destination)?;
        reconcile_visible_mirror_read_acl(config, &account_paths, &destination)?;
    }
    for previous in previous_instances {
        if desired_visible_relpaths.contains(&previous.visible_relpath) {
            continue;
        }
        let destination = account_paths
            .visible_emails_root
            .join(&previous.visible_relpath);
        if destination.exists() {
            fs::remove_file(&destination)
                .map_err(|error| format!("failed to remove {}: {error}", destination.display()))?;
            if let Some(parent) = destination.parent() {
                prune_empty_ancestors(parent, &account_paths.visible_emails_root)?;
            }
        }
    }

    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to start mailbox rebuild transaction: {error}"))?;
    transaction
        .execute(
            "DELETE FROM message_mailbox_instances WHERE account_id = ?1",
            params![account.id],
        )
        .map_err(|error| format!("failed to clear mailbox instances: {error}"))?;
    transaction
        .execute(
            "DELETE FROM message_catalog WHERE account_id = ?1",
            params![account.id],
        )
        .map_err(|error| format!("failed to clear message catalog: {error}"))?;
    for record in catalog_by_key.values() {
        transaction
            .execute(
                r#"
                INSERT INTO message_catalog (
                    account_id,
                    message_key,
                    canonical_hidden_relpath,
                    subject,
                    sender,
                    timestamp,
                    message_sha256,
                    last_seen_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                "#,
                params![
                    record.account_id,
                    record.message_key,
                    record.canonical_hidden_relpath,
                    record.subject,
                    record.sender,
                    record.timestamp,
                    record.message_sha256,
                    record.last_seen_at,
                ],
            )
            .map_err(|error| format!("failed to insert message catalog row: {error}"))?;
    }
    for record in &desired_instances {
        transaction
            .execute(
                r#"
                INSERT INTO message_mailbox_instances (
                    account_id,
                    message_key,
                    raw_mailbox_path,
                    visible_relpath,
                    hidden_relpath,
                    account_slug,
                    mailbox_slug,
                    filename,
                    last_seen_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                "#,
                params![
                    record.account_id,
                    record.message_key,
                    record.raw_mailbox_path,
                    record.visible_relpath,
                    record.hidden_relpath,
                    record.account_slug,
                    record.mailbox_slug,
                    record.filename,
                    record.last_seen_at,
                ],
            )
            .map_err(|error| format!("failed to insert mailbox instance row: {error}"))?;
    }
    transaction
        .commit()
        .map_err(|error| format!("failed to commit mailbox rebuild transaction: {error}"))?;

    let inventory = MaildirInventory {
        archive_file_count: desired_instances.len(),
        logical_message_count: catalog_by_key.len(),
        overlap_file_count: desired_instances.len().saturating_sub(catalog_by_key.len()),
    };
    let indexed_message_count = count_indexed_messages(&account_paths)?;
    let counts = progress_counts(&inventory, indexed_message_count);
    let snapshot_status = if counts.archived_message_count == 0 {
        "empty"
    } else {
        "ready"
    };
    store_account_progress_snapshot(
        config,
        account.id,
        &counts,
        account.last_sync_finished_at.as_deref(),
        snapshot_status,
        None,
    )?;
    Ok(counts)
}

fn load_dashboard_account_views(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<DashboardAccountView>, String> {
    reconcile_interrupted_syncs(config)?;
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
            match load_account_progress_snapshot(config, account.id) {
                Ok(Some(snapshot)) => {
                    let note = match snapshot.snapshot_status.as_str() {
                        "error" => snapshot.snapshot_note.clone().or_else(|| {
                            Some(
                                "Dashboard counts could not be refreshed for this mailbox."
                                    .to_string(),
                            )
                        }),
                        "stale" => snapshot.snapshot_note.clone().or_else(|| {
                            Some(
                                "Dashboard counts are waiting for the next sync or reindex."
                                    .to_string(),
                            )
                        }),
                        _ => None,
                    };
                    (index_state, snapshot_counts(&snapshot), note)
                }
                Ok(None) => (
                    index_state,
                    AccountProgressCounts::default(),
                    Some(
                        "Dashboard counts will appear after the next sync or reindex.".to_string(),
                    ),
                ),
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
    let (status_class, status_label) = account_status(
        &account,
        index_state,
        &counts,
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
    );
    let progress_note = account_progress_note(
        &account,
        &counts,
        index_state,
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
    );
    let overlap_note = account_overlap_note(&counts, metrics_diagnostic.as_ref());
    let sync_notice = dashboard_sync_notice(
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
        &counts,
        index_state,
    );
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
            archived_message_count: counts.archived_message_count,
            indexed_message_count: counts.indexed_message_count,
            pending_index_count: counts.pending_index_count,
            index_coverage_percent: counts.index_coverage_percent,
            archive_file_count: counts.archive_file_count,
            overlap_file_count: counts.overlap_file_count,
            progress_note,
            overlap_note,
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
        },
        account,
    }
}

#[cfg(test)]
fn scan_maildir_inventory(maildir: &FsPath) -> Result<MaildirInventory, String> {
    let mut message_keys = HashSet::new();
    let mut archive_file_count = 0;
    scan_maildir_inventory_inner(maildir, false, &mut archive_file_count, &mut message_keys)?;
    let logical_message_count = message_keys.len();
    Ok(MaildirInventory {
        archive_file_count,
        logical_message_count,
        overlap_file_count: archive_file_count.saturating_sub(logical_message_count),
    })
}

#[cfg(test)]
fn scan_maildir_inventory_inner(
    path: &FsPath,
    count_files_here: bool,
    archive_file_count: &mut usize,
    message_keys: &mut HashSet<String>,
) -> Result<(), String> {
    let entries = fs::read_dir(path)
        .map_err(|error| format!("failed to read {}: {error}", path.display()))?;

    for entry in entries {
        let entry = entry.map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;

        if file_type.is_dir() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            scan_maildir_inventory_inner(
                &entry.path(),
                name.as_ref() == "cur" || name.as_ref() == "new",
                archive_file_count,
                message_keys,
            )?;
        } else if count_files_here && file_type.is_file() {
            *archive_file_count += 1;
            let metadata = read_message_metadata(&entry.path())?;
            message_keys.insert(message_key_from_metadata(&metadata)?);
        }
    }

    Ok(())
}

fn count_indexed_messages(account_paths: &AccountPaths) -> Result<usize, String> {
    let output = execute_command(
        "notmuch",
        &["count", "*"],
        &[
            (
                "HOME",
                account_paths.account_state_root.to_string_lossy().as_ref(),
            ),
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

    let trimmed = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if trimmed.is_empty() {
        return Ok(0);
    }
    trimmed.parse::<usize>().map_err(|error| {
        format!(
            "failed to parse indexed message count from '{}': {error}",
            trimmed
        )
    })
}

fn message_key_from_metadata(metadata: &MessageMetadata) -> Result<String, String> {
    metadata
        .normalized_message_id
        .as_ref()
        .map(|value| format!("message-id:{value}"))
        .or_else(|| {
            metadata
                .message_sha256
                .as_ref()
                .map(|value| format!("sha256:{value}"))
        })
        .ok_or_else(|| "message metadata must provide an identity key".to_string())
}

fn progress_counts(
    inventory: &MaildirInventory,
    indexed_message_count: usize,
) -> AccountProgressCounts {
    let archived_message_count = inventory.logical_message_count;
    let pending_index_count = archived_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = indexed_message_count
        .min(archived_message_count)
        .saturating_mul(100)
        .checked_div(archived_message_count)
        .unwrap_or_else(|| usize::from(indexed_message_count > 0) * 100);
    AccountProgressCounts {
        archived_message_count,
        indexed_message_count,
        pending_index_count,
        index_coverage_percent,
        archive_file_count: inventory.archive_file_count,
        overlap_file_count: inventory.overlap_file_count,
    }
}

fn dashboard_totals(accounts: Vec<AccountStatusPayload>) -> DashboardTotals {
    let archived_message_count = accounts
        .iter()
        .map(|account| account.archived_message_count)
        .sum::<usize>();
    let indexed_message_count = accounts
        .iter()
        .map(|account| account.indexed_message_count)
        .sum::<usize>();
    let archive_file_count = accounts
        .iter()
        .map(|account| account.archive_file_count)
        .sum::<usize>();
    let overlap_file_count = accounts
        .iter()
        .map(|account| account.overlap_file_count)
        .sum::<usize>();
    let pending_index_count = archived_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = indexed_message_count
        .min(archived_message_count)
        .saturating_mul(100)
        .checked_div(archived_message_count)
        .unwrap_or_else(|| usize::from(indexed_message_count > 0) * 100);

    DashboardTotals {
        archived_message_count,
        indexed_message_count,
        pending_index_count,
        index_coverage_percent,
        archive_file_count,
        overlap_file_count,
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
        "Counts are unavailable because the archive or search index could not be read.".to_string()
    } else if account.last_sync_status.as_deref() == Some("running")
        && counts.pending_index_count > 0
    {
        "Sync is active. Archived message count should rise first, then the index will catch up."
            .to_string()
    } else if sync_diagnostic
        .as_ref()
        .and_then(|value| value.phase)
        .is_some_and(|phase| matches!(phase, SyncPhase::Index | SyncPhase::Reconcile))
        && counts.pending_index_count > 0
    {
        "Saved messages are ahead of search. Use Repair search to catch up.".to_string()
    } else if counts.archived_message_count == 0 {
        "No archived messages yet.".to_string()
    } else if counts.pending_index_count > 0 {
        "Saved messages are ahead of search. Use Repair search to catch up.".to_string()
    } else if index_state == IndexState::Indexed {
        "Search index is caught up with the archived messages.".to_string()
    } else {
        "Use Update now or Repair search to prepare saved mail for search.".to_string()
    }
}

fn account_overlap_note(
    counts: &AccountProgressCounts,
    metrics_diagnostic: Option<&SyncDiagnostic>,
) -> Option<String> {
    if metrics_diagnostic.is_some() || counts.overlap_file_count == 0 {
        return None;
    }

    Some(format!(
        "Archive contains {} physical message files representing {} logical messages because synced folders overlap.",
        counts.archive_file_count, counts.archived_message_count
    ))
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
                "{} archived messages are not searchable yet.",
                counts.pending_index_count
            ))
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) => Some(
            "Archived messages may be missing from search until reindex succeeds.".to_string(),
        ),
        Some(SyncPhase::Preflight) => Some(
            "The sync stopped before the mailbox download step started.".to_string(),
        ),
        Some(SyncPhase::Metrics) => Some(
            "Archive and index counts are hidden until the archive can be read again."
                .to_string(),
        ),
        None if counts.pending_index_count > 0 => Some(format!(
            "{} archived messages may not be searchable yet.",
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
        Some(SyncPhase::Download | SyncPhase::Preflight) => {
            Some("Check the mailbox credentials, then use Update now again.".to_string())
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) if counts.pending_index_count > 0 => {
            Some("Use Repair search to catch search up with saved messages.".to_string())
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) => {
            Some("Run Repair search after checking that the archive is available.".to_string())
        }
        Some(SyncPhase::Metrics) => {
            Some("Check that the archive is available, then refresh the dashboard.".to_string())
        }
        None => Some(
            "Open troubleshooting details if needed, then retry Update now or Repair search."
                .to_string(),
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
            notice.diagnostic_phase = diagnostic.phase.map(SyncPhase::as_str).map(str::to_string);
            notice.diagnostic_code = Some(diagnostic.code.clone());
            notice.diagnostic_summary = Some(diagnostic.summary.clone());
            notice.diagnostic_detail = Some(diagnostic.detail.clone());
            notice.diagnostic_impact = diagnostic_impact(diagnostic, counts, index_state);
            notice.recommended_action = diagnostic_recommended_action(diagnostic, counts);
        }
    }

    notice
}

fn provider_label(provider: &str) -> &str {
    match provider {
        "gmail" => "Gmail",
        "generic_imap" => "Other mailbox",
        _ => "Custom mailbox",
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
    body.push_str(&render_toasts(flash, error));

    body.push_str(
        "<section class=\"hero\">
          <p class=\"eyebrow\">Mail Archive</p>
          <h1>Search saved mail and file important attachments.</h1>
          <p class=\"lede\">Find old messages, download attachments, and send documents to Paperless without opening a full mail client.</p>
          <div class=\"nav\">
            <a href=\"/search\">Search mail</a>
            <a class=\"secondary\" href=\"/attachments\">Find attachments</a>
            <a class=\"secondary\" href=\"/accounts/new\">Add mailbox</a>
          </div>
        </section>",
    );

    body.push_str("<section class=\"panel stack\"><div class=\"section-head\"><h2>Mailboxes</h2><p class=\"meta\">Update mailbox archives and check whether saved mail is ready to search.</p></div>");
    body.push_str(
        "<div id=\"dashboard-status-island\" data-mail-archive-island=\"dashboard-status\"></div>",
    );
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
          <div class=\"summary-metric\"><span class=\"metric-label\">Archived</span><strong data-summary-field=\"archived\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Indexed</span><strong data-summary-field=\"indexed\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Pending index</span><strong data-summary-field=\"pending\">{}</strong></div>
          <div class=\"summary-metric\"><span class=\"metric-label\">Coverage</span><strong data-summary-field=\"coverage\">{}%</strong></div>
        </div>",
        totals.archived_message_count,
        totals.indexed_message_count,
        totals.pending_index_count,
        totals.index_coverage_percent,
    )
}

fn render_toasts(flash: Option<&str>, error: Option<&str>) -> String {
    let mut toasts = Vec::new();
    if let Some(flash) = flash.filter(|value| !value.is_empty()) {
        toasts.push(format!(
            "<div class=\"toast success\" role=\"status\">{}</div>",
            escape_html(&flash.replace('+', " "))
        ));
    }
    if let Some(error) = error.filter(|value| !value.is_empty()) {
        toasts.push(format!(
            "<div class=\"toast error\" role=\"alert\">{}</div>",
            escape_html(&error.replace('+', " "))
        ));
    }
    if toasts.is_empty() {
        String::new()
    } else {
        format!(
            "<div class=\"toast-stack\" aria-live=\"polite\" aria-atomic=\"true\">{}</div>",
            toasts.join("")
        )
    }
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
          <p class=\"notice-copy{}\" data-diagnostic-impact>{}</p>
          <p class=\"notice-copy{}\" data-diagnostic-action>{}</p>
          <details class=\"notice-details{}\" data-diagnostic-details>
            <summary>Troubleshooting details</summary>
            <p class=\"meta notice-meta{}\" data-diagnostic-meta>{}</p>
            <pre data-diagnostic-detail>{}</pre>
          </details>
        </div>",
        hidden_class(status.diagnostic_summary.is_some()),
        hidden_class(status.diagnostic_summary.is_some()),
        escape_html(status.diagnostic_summary.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_impact.is_some()),
        escape_html(status.diagnostic_impact.as_deref().unwrap_or("")),
        hidden_class(status.recommended_action.is_some()),
        escape_html(status.recommended_action.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_detail.is_some()),
        hidden_class(meta.is_some()),
        escape_html(meta.as_deref().unwrap_or("")),
        escape_html(status.diagnostic_detail.as_deref().unwrap_or("")),
    )
}

fn render_progress_warning_notice(status: &AccountStatusPayload) -> String {
    format!(
        "<div class=\"notice warning{}\" data-progress-warning>
          <p class=\"notice-title{}\" data-progress-warning-text>{}</p>
          <p class=\"notice-copy{}\" data-progress-warning-action>{}</p>
          <details class=\"notice-details{}\" data-progress-warning-details>
            <summary>Troubleshooting details</summary>
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
              <p class=\"eyebrow\">Mailbox</p>
              <h2>{}</h2>
              <p class=\"meta\" data-last-activity>Last update {}</p>
            </div>
            <span class=\"status {}\" data-status-badge>{}</span>
          </div>
          <div class=\"card-meta\">
            <span class=\"pill\">{}</span>
            <span class=\"pill\" data-index-pill>{}</span>
          </div>
          <div class=\"progress-cluster\">
            <div class=\"progress-metrics\">
              <div class=\"summary-metric\"><span class=\"metric-label\">Saved mail</span><strong data-progress-field=\"archived\">{}</strong></div>
              <div class=\"summary-metric\"><span class=\"metric-label\">Search ready</span><strong data-progress-field=\"indexed\">{}</strong></div>
              <div class=\"summary-metric\"><span class=\"metric-label\">Catching up</span><strong data-progress-field=\"pending\">{}</strong></div>
            </div>
            <div class=\"progress-bar\" aria-label=\"Index coverage\"><span data-progress-bar style=\"width: {}%\"></span></div>
            <p class=\"meta\" data-progress-note>{}</p>
            <p class=\"meta{}\" data-overlap-note>{}</p>
          </div>
          <div class=\"action-row\">
            <form method=\"post\" action=\"/accounts/{}/sync\" data-dashboard-action><button type=\"submit\">Update now</button></form>
            <a class=\"button-link secondary\" href=\"/search?account_id={}\">Search</a>
            <a class=\"button-link secondary\" href=\"/attachments?account_id={}\">Attachments</a>
            <a class=\"button-link secondary\" href=\"/accounts/{}/edit\">Edit</a>
          </div>
          <details class=\"account-settings\">
            <summary>Mailbox settings</summary>
            <div class=\"hint\">Provider: {} · Automatic updates: {}</div>
            <div class=\"action-row\">
              <form method=\"post\" action=\"/accounts/{}/reindex\" data-dashboard-action><button class=\"secondary\" type=\"submit\">Repair search</button></form>
              <form method=\"post\" action=\"/accounts/{}/toggle-sync\" data-dashboard-action><button class=\"secondary\" type=\"submit\">{}</button></form>
            </div>
          </details>
          {}
          {}",
        account.id,
        escape_html(&account.display_name),
        escape_html(&status.last_activity),
        escape_html(&status.status_class),
        escape_html(&status.status_label),
        escape_html(schedule_label),
        escape_html(&status.index_label),
        status.archived_message_count,
        status.indexed_message_count,
        status.pending_index_count,
        status.index_coverage_percent,
        escape_html(&status.progress_note),
        hidden_class(status.overlap_note.is_some()),
        escape_html(status.overlap_note.as_deref().unwrap_or("")),
        account.id,
        account.id,
        account.id,
        account.id,
        escape_html(provider_label(&account.provider_kind)),
        escape_html(schedule_label),
        account.id,
        account.id,
        if account.sync_enabled {
            "Turn off automatic updates"
        } else {
            "Turn on automatic updates"
        },
        render_sync_diagnostic_notice(status),
        render_progress_warning_notice(status),
    )
    .ok();

    body.push_str("</article>");
    body
}

fn account_status(
    account: &AccountRecord,
    index_state: IndexState,
    counts: &AccountProgressCounts,
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
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
        _ if metrics_diagnostic.is_some() => ("pending", "check archive"),
        Some("ok") if counts.pending_index_count > 0 => ("pending", "index behind"),
        Some("ok") if index_state == IndexState::Indexed => ("ok", "healthy"),
        _ if index_state != IndexState::Indexed => ("unindexed", "needs index"),
        _ if counts.pending_index_count > 0 => ("pending", "index behind"),
        _ => ("idle", "healthy"),
    }
}

#[allow(clippy::too_many_arguments)]
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
            <label>Mailbox type
              <select name=\"provider_kind\">
                <option value=\"gmail\" {}>Gmail</option>
                <option value=\"generic_imap\" {}>Other mailbox</option>
              </select>
            </label>
            <label>Name shown in the archive
              <input name=\"display_name\" value=\"{}\" placeholder=\"Personal Gmail\">
            </label>
          </div>
          <div class=\"fields two\">
            <label>Email address
              <input name=\"imap_username\" value=\"{}\" placeholder=\"you@example.com\">
            </label>
            <label>App password
              <input type=\"password\" name=\"secret\" value=\"\" autocomplete=\"new-password\" {}>
            </label>
          </div>
          {}
          <label><input type=\"checkbox\" name=\"sync_enabled\" {}> Update this mailbox automatically</label>
          <details class=\"account-settings\">
            <summary>Advanced connection settings</summary>
            <div class=\"fields two\">
              <label>Server
                <input name=\"imap_host\" value=\"{}\" placeholder=\"imap.gmail.com\">
              </label>
              <label>Port
                <input name=\"imap_port\" value=\"{}\" placeholder=\"993\">
              </label>
            </div>
            <label>Folders to save
              <textarea name=\"folder_patterns\" placeholder=\"One folder pattern per line\">{}</textarea>
            </label>
          </details>
          <div class=\"actions\">
            <button type=\"submit\">{}</button>
            <a class=\"button-link secondary\" href=\"/\">Cancel</a>
          </div>
          <ul class=\"muted-list\">
            <li>Gmail usually needs an app password.</li>
            <li>Saved mail can be searched and attachments can be sent to Paperless.</li>
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
        escape_html(&form.imap_username),
        if secret_required { "required" } else { "" },
        secret_help
            .map(|text| format!("<p class=\"hint\">{}</p>", escape_html(text)))
            .unwrap_or_default(),
        if form.sync_enabled.is_some() { "checked" } else { "" },
        escape_html(&form.imap_host),
        escape_html(&form.imap_port),
        escape_html(&form.folder_patterns),
        escape_html(submit_label),
    )
    .ok();
    body.push_str("</section>");

    layout(page_title, Some(identity), "accounts", &body)
}

fn render_attachments_page(
    identity: &Identity,
    data: &AttachmentPageData,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&render_toasts(flash, error));

    body.push_str(
        "<section class=\"page-heading\">
          <span class=\"page-heading-icon\" aria-hidden=\"true\">&#128206;</span>
          <h1>Attachments</h1>
        </section>",
    );

    let return_to = attachment_return_to(&data.state);
    let filter_hiddens = render_attachment_filter_hiddens(data, &return_to);
    let preset_panel = render_attachment_presets(data, &return_to, &filter_hiddens);
    let show_download_all = data.state.result_count > data.items.len();
    writeln!(
        &mut body,
        "<section class=\"panel search-panel\">
          <form method=\"get\" action=\"/attachments\" class=\"search-form\">
            <div class=\"primary-search-row\">
              <label class=\"primary-search-field\">Search attachments
                <input class=\"primary-search-input\" name=\"q\" value=\"{}\">
              </label>
              <button class=\"icon-button search-submit\" type=\"submit\" title=\"Search attachments\" aria-label=\"Search attachments\">⌕</button>
            </div>
            <details class=\"filter-accordion\">
              <summary>Filter attachments</summary>
              <div class=\"filter-groups\">
                <section class=\"filter-group\">
                  <h2>Scope</h2>
                  <div class=\"filter-grid\">
                    <label class=\"field-wide\">Mailbox
                    <select name=\"account_id\">
                      <option value=\"\">All mailboxes</option>
                      {}
                    </select>
                    </label>
                    <label>Sender importance
                    <select name=\"priority\">{}</select>
                    </label>
                    <label class=\"field-short\">Extension
                      <input name=\"extension\" value=\"{}\">
                    </label>
                  </div>
                </section>
                <section class=\"filter-group\">
                  <h2>Sender</h2>
                  <div class=\"filter-grid\">
                    <label class=\"field-wide\">Sender address
                      <input name=\"sender_address\" value=\"{}\">
                    </label>
                    <label>Sender name
                      <input name=\"sender_name\" value=\"{}\">
                    </label>
                    <label>Sender domain
                      <input name=\"sender_domain\" value=\"{}\">
                    </label>
                  </div>
                </section>
                <section class=\"filter-group\">
                  <h2>Message</h2>
                  <div class=\"filter-grid\">
                    <label class=\"field-wide\">Subject
                      <input name=\"subject\" value=\"{}\">
                    </label>
                    <label class=\"field-wide\">Body text
                      <input name=\"body_text\" value=\"{}\">
                    </label>
                    <label>Date from
                      <input type=\"date\" name=\"date_from\" value=\"{}\">
                    </label>
                    <label>Date to
                      <input type=\"date\" name=\"date_to\" value=\"{}\">
                    </label>
                  </div>
                </section>
              </div>
            </details>
            <details class=\"filter-accordion\">
              <summary>More filters</summary>
              <div class=\"filter-groups\">
                <section class=\"filter-group\">
                  <h2>Attachment</h2>
                  <div class=\"filter-grid\">
                    <label>Has attachments
                    <select name=\"has_attachments\">{}</select>
                    </label>
                    <label class=\"field-wide\">Attachment name
                      <input name=\"attachment_name\" value=\"{}\">
                    </label>
                    <label class=\"field-wide\">Technical file type
                      <input name=\"mime_type\" value=\"{}\">
                    </label>
                  </div>
                </section>
                <section class=\"filter-group\">
                  <h2>Limits</h2>
                  <div class=\"filter-grid\">
                    <label class=\"field-short\">Min size
                      <input name=\"min_size\" value=\"{}\" inputmode=\"numeric\">
                    </label>
                    <label class=\"field-short\">Max size
                      <input name=\"max_size\" value=\"{}\" inputmode=\"numeric\">
                    </label>
                    <label class=\"field-short\">Min attachments
                      <input name=\"min_attachments\" value=\"{}\" inputmode=\"numeric\">
                    </label>
                    <label class=\"field-short\">Max attachments
                      <input name=\"max_attachments\" value=\"{}\" inputmode=\"numeric\">
                    </label>
                  </div>
                </section>
                <section class=\"filter-group\">
                  <h2>Output</h2>
                  <div class=\"filter-grid\">
                    <label class=\"checkbox-field\">Include message body files
                    <input type=\"checkbox\" name=\"include_inline\" value=\"1\" {}>
                    </label>
                    <label class=\"checkbox-field\">Inline images
                    <input type=\"checkbox\" name=\"include_inline_images\" value=\"1\" {}>
                    </label>
                    <label class=\"checkbox-field\">Show technical file type
                    <input type=\"checkbox\" name=\"show_mime_details\" value=\"1\" {}>
                    </label>
                    <label class=\"field-wide\">ZIP subfolder
                      <input name=\"download_subfolder\" value=\"{}\">
                    </label>
                  </div>
                </section>
              </div>
            </details>
            <div class=\"action-row\">
              <a class=\"button-link secondary icon-button\" href=\"/attachments?q=\" title=\"Reset filters\" aria-label=\"Reset filters\">×</a>
              <a class=\"button-link secondary icon-button\" href=\"/search\" title=\"Back to search\" aria-label=\"Back to search\">↩</a>
            </div>
          </form>
          {}
          <div class=\"attachment-toolbar\">
            <div id=\"attachment-selection-island\" data-mail-archive-island=\"attachment-selection\"></div>
            <span class=\"selection-count\" data-selected-count>0 selected</span>
            <button class=\"secondary\" type=\"button\" data-select-page title=\"Select visible attachments\">Select page</button>
            <form id=\"attachment-download-form\" method=\"post\" action=\"/attachments/download\" class=\"icon-form\">
              {}
              <button class=\"icon-button\" type=\"submit\" title=\"Download selected attachments\" aria-label=\"Download selected attachments\" data-bulk-action>↓</button>
              {}
            </form>
            <form id=\"attachment-paperless-form\" method=\"post\" action=\"/attachments/send-paperless\" class=\"icon-form\" data-paperless-form>
              <input type=\"hidden\" name=\"return_to\" value=\"{}\">
              <button class=\"secondary icon-button paperless-send-button\" type=\"submit\" title=\"Send selected attachments to Paperless\" aria-label=\"Send selected attachments to Paperless\" data-paperless-button data-bulk-action>&#8594;</button>
            </form>
            <form method=\"post\" action=\"/attachments/refresh\" class=\"icon-form\" data-refresh-attachments-form>
              <input type=\"hidden\" name=\"account_id\" value=\"{}\">
              <input type=\"hidden\" name=\"return_to\" value=\"{}\">
              <button class=\"secondary icon-button\" type=\"submit\" title=\"Refresh attachment list\" aria-label=\"Refresh attachment list\">↻</button>
            </form>
          </div>
        </section>",
        escape_html(&data.filters.message.q),
        render_account_options(&data.accounts, data.selected_account_id),
        render_sender_priority_filter_options(data.state.priority_filter),
        escape_html(&data.filters.extension),
        escape_html(&data.filters.message.sender_address),
        escape_html(&data.filters.message.sender_name),
        escape_html(&data.filters.message.sender_domain),
        escape_html(&data.filters.message.subject),
        escape_html(&data.filters.message.body_text),
        escape_html(&data.filters.message.date_from),
        escape_html(&data.filters.message.date_to),
        render_optional_bool_options(data.filters.message.has_attachments),
        escape_html(&data.filters.attachment_name),
        escape_html(&data.filters.mime_type),
        escape_html(&data.filters.min_size),
        escape_html(&data.filters.max_size),
        escape_html(&data.filters.min_attachments),
        escape_html(&data.filters.max_attachments),
        if data.include_inline { "checked" } else { "" },
        if data.include_inline_images {
            "checked"
        } else {
            ""
        },
        if data.show_mime_details { "checked" } else { "" },
        escape_html(&data.download_subfolder),
        preset_panel,
        filter_hiddens,
        if show_download_all {
            "<button class=\"secondary icon-button\" type=\"submit\" name=\"selection_scope\" value=\"all_matching\" title=\"Download all matching attachments\" aria-label=\"Download all matching attachments\">⇩</button>"
        } else {
            ""
        },
        escape_html(&return_to),
        data.selected_account_id
            .map(|value| value.to_string())
            .unwrap_or_default(),
        escape_html(&return_to),
    )
    .ok();

    writeln!(
        &mut body,
        "<section class=\"panel result-summary\"><strong>{}</strong><span class=\"meta\"> attachments matching the current view</span></section>",
        pluralize_results(data.state.result_count),
    )
    .ok();

    body.push_str(
        "<section class=\"notice\">
          <p class=\"notice-title\">Download files or send documents to Paperless.</p>
        </section>",
    );

    if let Some(message) = data.state.empty_message.as_deref() {
        writeln!(
            &mut body,
            "<section class=\"panel empty-state\"><p class=\"meta\">{}</p></section>",
            escape_html(message)
        )
        .ok();
    }

    if !data.items.is_empty() {
        writeln!(
            &mut body,
            "<section class=\"attachment-list\">
              {}
              {}
            </section>",
            render_attachment_list_header(),
            data.items
                .iter()
                .map(|item| render_attachment_item(item, &return_to, data.show_mime_details))
                .collect::<Vec<_>>()
                .join("")
        )
        .ok();
    }

    if data.state.has_previous_page || data.state.has_next_page {
        body.push_str(&render_attachment_pagination(&data.state));
    }

    layout("Attachments", Some(identity), "attachments", &body)
}

fn render_attachment_presets(
    data: &AttachmentPageData,
    return_to: &str,
    filter_hiddens: &str,
) -> String {
    let mut html = String::new();
    html.push_str(
        "<section class=\"attachment-presets\" aria-label=\"Attachment filter presets\">",
    );
    html.push_str(
        "<form method=\"post\" action=\"/attachments/presets\" class=\"preset-save-form\">
          <label>Preset name
            <input name=\"preset_name\" maxlength=\"80\">
          </label>",
    );
    html.push_str(filter_hiddens);
    html.push_str(
        "<button class=\"secondary\" type=\"submit\">Save preset</button>
        </form>",
    );

    if data.presets.is_empty() {
        html.push_str("<p class=\"meta preset-empty\">No saved attachment presets</p>");
    } else {
        html.push_str("<div class=\"preset-list\">");
        for preset in &data.presets {
            let href = if preset.query.trim().is_empty() {
                "/attachments".to_string()
            } else {
                format!("/attachments?{}", preset.query)
            };
            writeln!(
                &mut html,
                "<div class=\"preset-chip\">
                  <a class=\"button-link secondary\" href=\"{}\">{}</a>
                  <form method=\"post\" action=\"/attachments/presets/delete\" class=\"icon-form\">
                    <input type=\"hidden\" name=\"preset_id\" value=\"{}\">
                    <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                    <button class=\"secondary icon-button\" type=\"submit\" title=\"Delete preset\" aria-label=\"Delete preset\">×</button>
                  </form>
                </div>",
                escape_html(&href),
                escape_html(&preset.name),
                preset.id,
                escape_html(return_to),
            )
            .ok();
        }
        html.push_str("</div>");
    }
    html.push_str("</section>");
    html
}

fn render_attachment_filter_hiddens(data: &AttachmentPageData, return_to: &str) -> String {
    let mut fields = Vec::new();
    fields.push(format!(
        "<input type=\"hidden\" name=\"return_to\" value=\"{}\">",
        escape_html(return_to)
    ));
    append_hidden_fields_for_message_filters(&mut fields, &data.filters.message);
    if let Some(account_id) = data.selected_account_id {
        fields.push(format!(
            "<input type=\"hidden\" name=\"account_id\" value=\"{}\">",
            account_id
        ));
    }
    if data.state.priority_filter != SenderPriorityFilter::All {
        fields.push(format!(
            "<input type=\"hidden\" name=\"priority\" value=\"{}\">",
            data.state.priority_filter.as_query_value()
        ));
    }
    append_hidden_fields_for_attachment_filters(&mut fields, &data.filters);
    if data.include_inline {
        fields.push("<input type=\"hidden\" name=\"include_inline\" value=\"1\">".to_string());
    }
    if data.include_inline_images {
        fields
            .push("<input type=\"hidden\" name=\"include_inline_images\" value=\"1\">".to_string());
    }
    if data.show_mime_details {
        fields.push("<input type=\"hidden\" name=\"show_mime_details\" value=\"1\">".to_string());
    }
    if !data.download_subfolder.trim().is_empty() {
        fields.push(format!(
            "<input type=\"hidden\" name=\"download_subfolder\" value=\"{}\">",
            escape_html(&data.download_subfolder)
        ));
    }
    fields.join("")
}

fn append_hidden_fields_for_message_filters(
    fields: &mut Vec<String>,
    filters: &MessageSearchFilters,
) {
    for (key, value) in [
        ("q", filters.q.trim()),
        ("sender_address", filters.sender_address.trim()),
        ("sender_name", filters.sender_name.trim()),
        ("sender_domain", filters.sender_domain.trim()),
        ("subject", filters.subject.trim()),
        ("body_text", filters.body_text.trim()),
        ("date_from", filters.date_from.trim()),
        ("date_to", filters.date_to.trim()),
    ] {
        if !value.is_empty() {
            fields.push(format!(
                "<input type=\"hidden\" name=\"{}\" value=\"{}\">",
                key,
                escape_html(value)
            ));
        }
    }
    if let Some(value) = filters.has_attachments {
        fields.push(format!(
            "<input type=\"hidden\" name=\"has_attachments\" value=\"{}\">",
            if value { "1" } else { "0" }
        ));
    }
}

fn append_hidden_fields_for_attachment_filters(
    fields: &mut Vec<String>,
    filters: &AttachmentSearchFilters,
) {
    for (key, value) in [
        ("extension", filters.extension.trim()),
        ("attachment_name", filters.attachment_name.trim()),
        ("mime_type", filters.mime_type.trim()),
        ("min_size", filters.min_size.trim()),
        ("max_size", filters.max_size.trim()),
        ("min_attachments", filters.min_attachments.trim()),
        ("max_attachments", filters.max_attachments.trim()),
    ] {
        if !value.is_empty() {
            fields.push(format!(
                "<input type=\"hidden\" name=\"{}\" value=\"{}\">",
                key,
                escape_html(value)
            ));
        }
    }
}

fn simple_attachment_type_label(attachment: &AttachmentRecord) -> String {
    if !attachment.extension.is_empty() {
        attachment.extension.clone()
    } else if attachment.mime_type == "application/pdf" {
        "pdf".to_string()
    } else if let Some((_, subtype)) = attachment.mime_type.split_once('/') {
        subtype.to_string()
    } else {
        attachment.mime_type.clone()
    }
}

fn detailed_attachment_type_label(attachment: &AttachmentRecord) -> String {
    let simple = simple_attachment_type_label(attachment);
    if simple == attachment.mime_type {
        simple
    } else {
        format!("{} · {}", simple, attachment.mime_type)
    }
}

fn attachment_column_date_label(timestamp: i64) -> String {
    format_timestamp_date_label(timestamp)
}

fn render_attachment_item(
    item: &AttachmentListItem,
    return_to: &str,
    show_mime_details: bool,
) -> String {
    let badge_label = simple_attachment_type_label(&item.attachment);
    let date_label = attachment_column_date_label(item.message.timestamp);
    let date_tooltip = format_timestamp_tooltip_label(item.message.timestamp);
    let source = format!("{} · {}", item.account_name, item.message.message_relpath);
    let type_label = if show_mime_details {
        detailed_attachment_type_label(&item.attachment)
    } else {
        badge_label.clone()
    };

    let download_action = format!(
        "<form method=\"post\" action=\"/attachments/{}/download/browser\" class=\"icon-form\">
          <button class=\"icon-button\" type=\"submit\" title=\"Download attachment locally\" aria-label=\"Download attachment locally\">↓</button>
        </form>",
        escape_html(&item.attachment.attachment_key),
    );
    let paperless_action = if let Some(sent_at) = item.paperless_sent_at.as_deref() {
        format!(
            "<button class=\"icon-button paperless-sent-button\" type=\"button\" title=\"Successfully sent to Paperless on {}\" aria-label=\"Successfully sent to Paperless on {}\" data-paperless-sent-button>✓</button>",
            escape_html(sent_at),
            escape_html(sent_at),
        )
    } else {
        format!(
            "<form method=\"post\" action=\"/attachments/send-paperless\" class=\"icon-form\" data-paperless-form>
              <input type=\"hidden\" name=\"return_to\" value=\"{}\">
              <input type=\"hidden\" name=\"attachment_keys\" value=\"{}\">
              <button class=\"secondary icon-button paperless-send-button\" type=\"submit\" title=\"Send attachment to Paperless\" aria-label=\"Send attachment to Paperless\" data-paperless-button>&#8594;</button>
            </form>",
            escape_html(return_to),
            escape_html(&item.attachment.attachment_key),
        )
    };
    let sender_importance = render_sender_importance_select(&item.sender_priority, return_to);

    format!(
        "<article class=\"attachment-row\" data-attachment-row data-attachment-key=\"{}\" tabindex=\"0\" aria-selected=\"false\">
          <span class=\"meta truncate\" title=\"{}\">{}</span>
          <div class=\"attachment-main\">
            <strong class=\"truncate\" title=\"{}\">{}</strong>
            <span class=\"meta truncate\" title=\"{}\">{} · {} · {} · {}</span>
          </div>
          <span class=\"badge truncate\" title=\"{}\">{}</span>
          <div class=\"row-actions\">{}{}</div>
          <div class=\"priority-cell\">{}</div>
        </article>",
        escape_html(&item.attachment.attachment_key),
        escape_html(&date_tooltip),
        escape_html(&date_label),
        escape_html(&format!(
            "{} · Source: {}",
            item.attachment.original_filename, source
        )),
        escape_html(&item.attachment.original_filename),
        escape_html(&format!("{} · Source: {}", item.message.subject, source)),
        escape_html(&item.message.subject),
        escape_html(&item.account_name),
        escape_html(&item.message.from),
        escape_html(&format_file_size(item.attachment.size_bytes)),
        escape_html(&type_label),
        escape_html(&type_label),
        download_action,
        paperless_action,
        sender_importance,
    )
}

fn render_attachment_list_header() -> String {
    "<div class=\"attachment-list-header\" aria-hidden=\"true\">
      <span>Date</span>
      <span>Attachment</span>
      <span>Type</span>
      <span>Actions</span>
      <span>Sender importance</span>
    </div>"
        .to_string()
}

fn render_attachment_pagination(state: &AttachmentListViewState) -> String {
    let previous_page = state.page.saturating_sub(1);
    let next_page = state.page + 1;
    let previous_href = attachment_page_href(&state.base_query, previous_page);
    let next_href = attachment_page_href(&state.base_query, next_page);
    format!(
        "<section class=\"panel pagination-row\">
          <a class=\"button-link secondary {}\" href=\"{}\">Previous page</a>
          <span class=\"meta\">Page {}</span>
          <a class=\"button-link secondary {}\" href=\"{}\">Next page</a>
        </section>",
        if state.has_previous_page {
            ""
        } else {
            "disabled"
        },
        escape_html(&previous_href),
        state.page,
        if state.has_next_page { "" } else { "disabled" },
        escape_html(&next_href),
    )
}

fn attachment_return_to(state: &AttachmentListViewState) -> String {
    attachment_page_href(&state.base_query, state.page)
}

fn attachment_page_href(base_query: &str, page: usize) -> String {
    let page = usize::max(page, 1);
    let mut query = base_query.to_string();
    if page > 1 {
        if !query.is_empty() {
            query.push('&');
        }
        query.push_str(&format!("page={page}"));
    }
    if query.is_empty() {
        "/attachments".to_string()
    } else {
        format!("/attachments?{query}")
    }
}

fn format_file_size(size_bytes: i64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;

    let size = size_bytes.max(0) as f64;
    if size >= GIB {
        format!("{:.1} GiB", size / GIB)
    } else if size >= MIB {
        format!("{:.1} MiB", size / MIB)
    } else if size >= KIB {
        format!("{:.1} KiB", size / KIB)
    } else {
        format!("{} B", size_bytes.max(0))
    }
}

#[allow(clippy::too_many_arguments)]
fn render_search(
    identity: &Identity,
    accounts: &[AccountRecord],
    filters: &MessageSearchFilters,
    selected_account_id: Option<i64>,
    results: &[SearchResult],
    state: &SearchViewState,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&render_toasts(flash, error));

    body.push_str(
        "<section class=\"page-heading\">
          <span class=\"page-heading-icon\" aria-hidden=\"true\">&#9993;</span>
          <h1>Search mail</h1>
        </section>",
    );

    writeln!(
        &mut body,
        "<section class=\"panel search-panel\">
          <form method=\"get\" action=\"/search\" class=\"search-form\">
            <div class=\"primary-search-row\">
              <label class=\"primary-search-field\">Search mail
                <input class=\"primary-search-input\" name=\"q\" value=\"{}\">
              </label>
              <button class=\"icon-button search-submit\" type=\"submit\" title=\"Search mail\" aria-label=\"Search mail\">⌕</button>
            </div>
            <details class=\"filter-accordion\">
              <summary>Filter results</summary>
              <div class=\"filter-grid\">
                <label class=\"field-wide\">Mailbox
                  <select name=\"account_id\">
                    <option value=\"\">All mailboxes</option>
                    {}
                  </select>
                </label>
                <label>Sender importance
                  <select name=\"priority\">{}</select>
                </label>
                <label class=\"field-wide\">Sender address
                  <input name=\"sender_address\" value=\"{}\">
                </label>
                <label>Sender name
                  <input name=\"sender_name\" value=\"{}\">
                </label>
                <label>Sender domain
                  <input name=\"sender_domain\" value=\"{}\">
                </label>
                <label class=\"field-wide\">Subject
                  <input name=\"subject\" value=\"{}\">
                </label>
                <label class=\"field-wide\">Body text
                  <input name=\"body_text\" value=\"{}\">
                </label>
                <label>Has attachments
                  <select name=\"has_attachments\">{}</select>
                </label>
                <label>Date from
                  <input type=\"date\" name=\"date_from\" value=\"{}\">
                </label>
                <label>Date to
                  <input type=\"date\" name=\"date_to\" value=\"{}\">
                </label>
              </div>
            </details>
            <div class=\"action-row\">
              <a class=\"button-link secondary icon-button\" href=\"/search?q=\" title=\"Reset filters\" aria-label=\"Reset filters\">×</a>
              <a class=\"button-link secondary icon-button\" href=\"/\" title=\"Back to dashboard\" aria-label=\"Back to dashboard\">↩</a>
            </div>
          </form>
        </section>",
        escape_html(&filters.q),
        render_account_options(accounts, selected_account_id),
        render_sender_priority_filter_options(state.priority_filter),
        escape_html(&filters.sender_address),
        escape_html(&filters.sender_name),
        escape_html(&filters.sender_domain),
        escape_html(&filters.subject),
        escape_html(&filters.body_text),
        render_optional_bool_options(filters.has_attachments),
        escape_html(&filters.date_from),
        escape_html(&filters.date_to),
    )
    .ok();

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
        let return_to = search_page_href(filters, selected_account_id, state.priority_filter);
        writeln!(
            &mut body,
            "<section class=\"mail-list\">
              {}
              {}
            </section>",
            render_mail_list_header(),
            results
                .iter()
                .map(|result| render_search_result(result, &return_to))
                .collect::<Vec<_>>()
                .join("")
        )
        .ok();
    }

    layout("Search Mail", Some(identity), "search", &body)
}

fn render_sender_priority_filter_options(selected: SenderPriorityFilter) -> String {
    [
        SenderPriorityFilter::All,
        SenderPriorityFilter::High,
        SenderPriorityFilter::Normal,
        SenderPriorityFilter::Low,
    ]
    .into_iter()
    .map(|option| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            option.as_query_value(),
            if option == selected { "selected" } else { "" },
            escape_html(option.label())
        )
    })
    .collect::<Vec<_>>()
    .join("")
}

fn render_optional_bool_options(selected: Option<bool>) -> String {
    [
        ("", selected.is_none(), "Any"),
        ("1", selected == Some(true), "Yes"),
        ("0", selected == Some(false), "No"),
    ]
    .into_iter()
    .map(|(value, is_selected, label)| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            value,
            if is_selected { "selected" } else { "" },
            label
        )
    })
    .collect::<Vec<_>>()
    .join("")
}

fn pluralize_results(count: usize) -> String {
    if count == 1 {
        "1 result".to_string()
    } else {
        format!("{count} results")
    }
}

fn pluralize_attachments(count: usize) -> String {
    if count == 1 {
        "1 attachment".to_string()
    } else {
        format!("{count} attachments")
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

fn search_page_href(
    filters: &MessageSearchFilters,
    selected_account_id: Option<i64>,
    priority_filter: SenderPriorityFilter,
) -> String {
    let mut pairs = Vec::new();
    append_message_filter_query_pairs(&mut pairs, filters);
    if let Some(account_id) = selected_account_id {
        pairs.push(("account_id", account_id.to_string()));
    }
    if priority_filter != SenderPriorityFilter::All {
        pairs.push(("priority", priority_filter.as_query_value().to_string()));
    }
    if pairs.is_empty() {
        "/search".to_string()
    } else {
        format!(
            "/search?{}",
            pairs
                .into_iter()
                .map(|(key, value)| format!("{key}={}", url_encode_component(&value)))
                .collect::<Vec<_>>()
                .join("&")
        )
    }
}

fn render_sender_importance_select(view: &SenderPriorityView, return_to: &str) -> String {
    let Some(identity) = view.identity.as_ref() else {
        return String::new();
    };

    render_sender_priority_select(
        SenderRuleKind::Address,
        &identity.address,
        view.address_rule.unwrap_or(SenderPriority::Normal),
        return_to,
    )
}

fn render_sender_priority_select(
    kind: SenderRuleKind,
    value: &str,
    selected: SenderPriority,
    return_to: &str,
) -> String {
    let label = "Sender importance";
    let options = [
        SenderPriority::High,
        SenderPriority::Normal,
        SenderPriority::Low,
    ]
    .into_iter()
    .map(|priority| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            priority.as_stored_value(),
            if priority == selected { "selected" } else { "" },
            escape_html(priority.dropdown_label())
        )
    })
    .collect::<Vec<_>>()
    .join("");
    format!(
        "<select class=\"priority-select {}\" name=\"priority\" data-priority-select data-sender-kind=\"{}\" data-sender-value=\"{}\" data-return-to=\"{}\" data-previous-priority=\"{}\" aria-label=\"{} for {}\" title=\"{} for {}\">{}</select>",
        priority_select_class(selected),
        kind.as_stored_value(),
        escape_html(value),
        escape_html(return_to),
        selected.as_stored_value(),
        escape_html(label),
        escape_html(value),
        escape_html(label),
        escape_html(value),
        options,
    )
}

fn priority_select_class(priority: SenderPriority) -> &'static str {
    match priority {
        SenderPriority::High => "priority-select-high",
        SenderPriority::Normal => "priority-select-normal",
        SenderPriority::Low => "priority-select-low",
    }
}

fn render_sender_cell(raw_sender: &str) -> String {
    let display = sender_display_from_header(raw_sender);
    let secondary = display
        .secondary
        .as_deref()
        .map(|value| {
            format!(
                "<span class=\"sender-email truncate\">{}</span>",
                escape_html(value)
            )
        })
        .unwrap_or_default();
    format!(
        "<div class=\"sender-cell\" title=\"{}\">
          <strong class=\"truncate\">{}</strong>
          {}
        </div>",
        escape_html(raw_sender),
        escape_html(&display.primary),
        secondary,
    )
}

fn render_search_result(result: &SearchResult, return_to: &str) -> String {
    let sender_importance = render_sender_importance_select(&result.sender_priority, return_to);
    let source = format!("{} · {}", result.account_name, result.message_relpath);

    let tags = if result.tags.is_empty() {
        vec!["<span class=\"meta\">No tags</span>".to_string()]
    } else {
        result
            .tags
            .iter()
            .map(|tag| format!("<span class=\"tag\">{}</span>", escape_html(tag)))
            .collect::<Vec<_>>()
    };

    format!(
        "<article class=\"mail-row\">
          <span class=\"meta truncate\" title=\"{}\">{}</span>
          {}
          <div class=\"mail-subject\" title=\"{}\">
            <strong class=\"truncate\" title=\"{}\">{}</strong>
          </div>
          <div class=\"tag-list compact\">{}</div>
          <div class=\"priority-cell\">{}</div>
        </article>",
        escape_html(&format_timestamp_tooltip_label(result.timestamp)),
        escape_html(&result.date_label),
        render_sender_cell(&result.from),
        escape_html(&source),
        escape_html(&result.subject),
        escape_html(&result.subject),
        tags.join(""),
        sender_importance,
    )
}

fn render_mail_list_header() -> String {
    "<div class=\"mail-list-header\" aria-hidden=\"true\">
      <span>Date</span>
      <span>Sender</span>
      <span>Message</span>
      <span>Tags</span>
      <span>Sender importance</span>
    </div>"
        .to_string()
}

fn frontend_mode() -> FrontendMode {
    match env::var("MAIL_ARCHIVE_UI_FRONTEND_MODE")
        .unwrap_or_else(|_| "production".to_string())
        .trim()
    {
        "vite" => FrontendMode::Vite,
        _ => FrontendMode::Production,
    }
}

fn frontend_dist_dir_from_env() -> String {
    env::var("MAIL_ARCHIVE_UI_FRONTEND_DIST_DIR")
        .unwrap_or_else(|_| DEFAULT_FRONTEND_DIST_DIR.to_string())
}

fn vite_origin_from_env() -> String {
    env::var("MAIL_ARCHIVE_UI_VITE_ORIGIN").unwrap_or_else(|_| DEFAULT_VITE_ORIGIN.to_string())
}

fn render_frontend_tags() -> String {
    match frontend_mode() {
        FrontendMode::Production => {
            match production_asset_tags(&frontend_dist_dir_from_env(), FRONTEND_ENTRYPOINT) {
                Ok(tags) => tags,
                Err(error) => format!(
                    "<!-- mail-archive-ui frontend assets unavailable: {} -->",
                    escape_html(&error)
                ),
            }
        }
        FrontendMode::Vite => vite_asset_tags(&vite_origin_from_env()),
    }
}

fn production_asset_tags(dist_dir: &str, entrypoint: &str) -> Result<String, String> {
    let manifest_path = PathBuf::from(dist_dir).join(".vite").join("manifest.json");
    let manifest_text = fs::read_to_string(&manifest_path).map_err(|error| {
        format!(
            "failed to read Vite manifest at {}: {error}",
            manifest_path.display()
        )
    })?;
    let manifest: serde_json::Value = serde_json::from_str(&manifest_text)
        .map_err(|error| format!("invalid manifest: {error}"))?;
    let entry = manifest
        .get(entrypoint)
        .and_then(|value| value.as_object())
        .ok_or_else(|| format!("manifest is missing entrypoint {entrypoint}"))?;
    let file = entry
        .get("file")
        .and_then(|value| value.as_str())
        .ok_or_else(|| format!("manifest entrypoint {entrypoint} is missing file"))?;

    let mut tags = String::new();
    if let Some(css_files) = entry.get("css").and_then(|value| value.as_array()) {
        for css_file in css_files.iter().filter_map(|value| value.as_str()) {
            writeln!(
                &mut tags,
                r#"<link rel="stylesheet" href="/static/frontend/{}">"#,
                escape_html(css_file)
            )
            .ok();
        }
    }
    writeln!(
        &mut tags,
        r#"<script type="module" src="/static/frontend/{}"></script>"#,
        escape_html(file)
    )
    .ok();
    Ok(tags)
}

fn vite_asset_tags(origin: &str) -> String {
    let origin = origin.trim_end_matches('/');
    format!(
        r#"<script type="module" src="{}/@vite/client"></script>
<script type="module" src="{}/src/entry.dev.tsx"></script>"#,
        escape_html(origin),
        escape_html(origin),
    )
}

fn layout(title: &str, identity: Option<&Identity>, active_nav: &str, body: &str) -> String {
    let frontend_tags = render_frontend_tags();
    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{}</title>
    {}
  </head>
  <body>
    <main class="page">
      <header class="app-header">
        <a class="brand-link" href="/" aria-label="Mail Archive dashboard">
          <span class="brand-icon" aria-hidden="true"><span class="brand-envelope"></span></span>
          <span>Mail Archive</span>
        </a>
        <nav class="top-nav" aria-label="Main navigation">
          <a class="{}" href="/search">Mail</a>
          <a class="{}" href="/attachments">Attachments</a>
          <a class="{}" href="/accounts/new">Add mailbox</a>
        </nav>
      </header>
      {}
      <footer class="page-footer">
        <nav class="footer-nav">
          <a class="{}" href="/">Dashboard</a>
          <a class="{}" href="/accounts/new">Add mailbox</a>
          <a class="{}" href="/search">Search</a>
          <a class="{}" href="/attachments">Attachments</a>
        </nav>
        <p class="meta footer-meta">{}</p>
      </footer>
    </main>
    <div id="mail-archive-ui-islands"></div>
  </body>
</html>"#,
        escape_html(title),
        frontend_tags,
        nav_active_class(active_nav == "search"),
        nav_active_class(active_nav == "attachments"),
        nav_active_class(active_nav == "accounts"),
        body,
        nav_active_class(active_nav == "dashboard"),
        nav_active_class(active_nav == "accounts"),
        nav_active_class(active_nav == "search"),
        nav_active_class(active_nav == "attachments"),
        escape_html(&identity_summary(identity)),
    )
}

fn identity_summary(identity: Option<&Identity>) -> String {
    identity
        .map(|identity| format!("Signed in as {}", identity.username))
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

fn local_datetime(timestamp: i64) -> Option<DateTime<Local>> {
    DateTime::<Utc>::from_timestamp(timestamp, 0).map(|value| value.with_timezone(&Local))
}

fn format_timestamp_date_label(timestamp: i64) -> String {
    local_datetime(timestamp)
        .map(|value| value.format("%d %b %Y").to_string())
        .unwrap_or_else(|| "Unknown date".to_string())
}

fn format_timestamp_tooltip_label(timestamp: i64) -> String {
    local_datetime(timestamp)
        .map(|value| {
            let hour = value.hour();
            let display_hour = match hour % 12 {
                0 => 12,
                value => value,
            };
            let suffix = if hour < 12 { "am" } else { "pm" };
            format!(
                "{}, {}:{:02}{}",
                value.format("%d %b %Y"),
                display_hour,
                value.minute(),
                suffix
            )
        })
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

fn has_explicit_search_param(raw_query: &str) -> bool {
    const SEARCH_KEYS: &[&str] = &[
        "q",
        "sender_address",
        "sender_name",
        "sender_domain",
        "subject",
        "body_text",
        "date_from",
        "date_to",
        "has_attachments",
        "priority",
    ];
    raw_query.split('&').any(|part| {
        let key = part.split_once('=').map(|(key, _)| key).unwrap_or(part);
        SEARCH_KEYS.contains(&key)
    })
}

fn url_encode_component(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![byte as char]
            }
            b' ' => vec!['+'],
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

fn attachments_redirect_location(
    return_to: Option<&str>,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut location = return_to
        .filter(|value| value.starts_with("/attachments"))
        .unwrap_or("/attachments")
        .to_string();
    let separator = if location.contains('?') { '&' } else { '?' };
    let mut first_extra = true;
    for (key, value) in [("flash", flash), ("error", error)] {
        if let Some(value) = value.filter(|value| !value.is_empty()) {
            location.push(if first_extra { separator } else { '&' });
            first_extra = false;
            location.push_str(key);
            location.push('=');
            location.push_str(&url_encode_component(value));
        }
    }
    location
}

fn message_redirect_location(
    return_to: Option<&str>,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut location = return_to
        .filter(|value| value.starts_with("/search") || value.starts_with("/attachments"))
        .unwrap_or("/search")
        .to_string();
    let separator = if location.contains('?') { '&' } else { '?' };
    let mut first_extra = true;
    for (key, value) in [("flash", flash), ("error", error)] {
        if let Some(value) = value.filter(|value| !value.is_empty()) {
            location.push(if first_extra { separator } else { '&' });
            first_extra = false;
            location.push_str(key);
            location.push('=');
            location.push_str(&url_encode_component(value));
        }
    }
    location
}

fn attachment_download_response(filename: &str, mime_type: &str, bytes: Vec<u8>) -> Response {
    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = StatusCode::OK;
    if let Ok(value) = HeaderValue::from_str(mime_type) {
        response.headers_mut().insert(CONTENT_TYPE, value);
    } else {
        response.headers_mut().insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/octet-stream"),
        );
    }
    if let Ok(value) = HeaderValue::from_str(&content_disposition_attachment(filename)) {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
    harden_response(response)
}

async fn zip_download_file_response(zip_file: TempZipFile) -> Response {
    let metadata = match tokio::fs::metadata(&zip_file.path).await {
        Ok(metadata) => metadata,
        Err(error) => {
            return server_error_page(
                "Download failed",
                &format!("ZIP file is unavailable: {error}"),
                None,
            )
        }
    };
    let file = match tokio::fs::File::open(&zip_file.path).await {
        Ok(file) => file,
        Err(error) => {
            return server_error_page(
                "Download failed",
                &format!("ZIP file could not be opened: {error}"),
                None,
            )
        }
    };
    let stream = ReaderStream::new(file);
    let mut response = Response::new(Body::from_stream(stream));
    *response.status_mut() = StatusCode::OK;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
    if let Ok(value) = HeaderValue::from_str(&metadata.len().to_string()) {
        response.headers_mut().insert("Content-Length", value);
    }
    if let Ok(value) = HeaderValue::from_str(&content_disposition_attachment(&zip_file.filename)) {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
    harden_response(response)
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

fn content_type_for_path(path: &FsPath) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("css") => "text/css; charset=utf-8",
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("wasm") => "application/wasm",
        _ => "application/octet-stream",
    }
}

fn vite_ws_origin(origin: &str) -> String {
    if let Some(rest) = origin.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = origin.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        origin.to_string()
    }
}

fn content_security_policy() -> String {
    match frontend_mode() {
        FrontendMode::Production => {
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'".to_string()
        }
        FrontendMode::Vite => {
            let origin = vite_origin_from_env();
            let origin = origin.trim_end_matches('/');
            let ws_origin = vite_ws_origin(origin);
            format!(
                "default-src 'self'; script-src 'self' {origin}; style-src 'self' 'unsafe-inline' {origin}; connect-src 'self' {origin} {ws_origin}; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'"
            )
        }
    }
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
        HeaderValue::from_str(&content_security_policy()).unwrap_or_else(|_| {
            HeaderValue::from_static(
                "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'",
            )
        }),
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
        ripmime: command_status("ripmime"),
        file: command_status("file"),
    };

    let ok = [
        &checks.database,
        &checks.store_root,
        &checks.runtime_dir,
        &checks.lock_dir,
        &checks.mbsync,
        &checks.notmuch,
        &checks.ripmime,
        &checks.file,
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

    fn with_env_var<F, R>(key: &str, value: &str, test: F) -> R
    where
        F: FnOnce() -> R,
    {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let previous = env::var_os(key);
        env::set_var(key, value);
        let result = test();
        if let Some(previous) = previous {
            env::set_var(key, previous);
        } else {
            env::remove_var(key);
        }
        result
    }

    fn test_config(tempdir: &TempDir) -> AppConfig {
        let data_dir = tempdir.path().join("data");
        let store_root = tempdir.path().join("store");
        let account_state_root = data_dir.join("accounts");
        let runtime_dir = tempdir.path().join("runtime");
        let lock_dir = tempdir.path().join("locks");

        AppConfig {
            address: Arc::<str>::from("127.0.0.1"),
            port: 9011,
            data_dir: Arc::<str>::from(data_dir.to_string_lossy().to_string()),
            store_root: Arc::<str>::from(store_root.to_string_lossy().to_string()),
            account_state_root: Arc::<str>::from(account_state_root.to_string_lossy().to_string()),
            runtime_dir: Arc::<str>::from(runtime_dir.to_string_lossy().to_string()),
            lock_dir: Arc::<str>::from(lock_dir.to_string_lossy().to_string()),
            paperless_consume_root: None,
            paperless_handoff_staging_root: None,
            visible_mirror_read_group: None,
            default_tags: Arc::from(vec!["new".to_string()]),
            frontend_dist_dir: Arc::<str>::from(
                tempdir
                    .path()
                    .join("frontend-dist")
                    .to_string_lossy()
                    .to_string(),
            ),
        }
    }

    fn prepare_test_layout(config: &AppConfig) {
        ensure_app_layout(config).expect("layout");
        fs::create_dir_all(config.store_root.as_ref()).expect("store root");
        initialize_db(config).expect("db");
    }

    #[test]
    fn landlock_roots_include_runtime_store_and_account_paths() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);

        let (read_only, read_write) = landlock_roots(&config);

        assert!(read_only.contains(&PathBuf::from("/nix/store")));
        assert!(read_only.contains(&PathBuf::from("/etc")));
        assert!(read_write.contains(&PathBuf::from(config.data_dir.as_ref())));
        assert!(read_write.contains(&PathBuf::from(config.store_root.as_ref())));
        assert!(read_write.contains(&PathBuf::from(config.account_state_root.as_ref())));
        assert!(read_write.contains(&PathBuf::from(config.runtime_dir.as_ref())));
        assert!(read_write.contains(&PathBuf::from(config.lock_dir.as_ref())));

        let mut config = config;
        config.paperless_handoff_staging_root = Some(Arc::from(
            tempdir
                .path()
                .join("handoff-staging")
                .to_string_lossy()
                .to_string(),
        ));
        let (_read_only, read_write) = landlock_roots(&config);
        assert!(read_write.contains(&PathBuf::from(
            config.paperless_handoff_staging_root.as_deref().unwrap()
        )));
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
            last_sync_phase: None,
            last_sync_code: None,
            last_sync_summary: None,
            last_sync_detail: None,
        }
    }

    fn sample_status_payload() -> AccountStatusPayload {
        AccountStatusPayload {
            id: 42,
            status_class: "error".to_string(),
            status_label: "sync failed".to_string(),
            index_label: "Indexed".to_string(),
            last_activity: "2026-04-25T21:37:55Z".to_string(),
            archived_message_count: 6_668,
            indexed_message_count: 6_668,
            pending_index_count: 0,
            index_coverage_percent: 100,
            archive_file_count: 8_002,
            overlap_file_count: 1_334,
            progress_note: "Search index is caught up with the archived messages."
                .to_string(),
            overlap_note: Some(
                "Archive contains 8002 physical message files representing 6668 logical messages because synced folders overlap.".to_string(),
            ),
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
                "Check the mailbox credentials, then use Update now again.".to_string(),
            ),
            progress_warning: None,
            progress_warning_detail: None,
            progress_warning_action: None,
        }
    }

    fn sample_identity() -> Identity {
        Identity {
            username: "alice".to_string(),
            email: Some("alice@example.com".to_string()),
            groups: vec!["mail-archive-users".to_string()],
        }
    }

    fn test_message_filters(query: &str) -> MessageSearchFilters {
        MessageSearchFilters {
            q: query.to_string(),
            ..Default::default()
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
        seed_account_with_flags(config, username, secret, true)
    }

    fn seed_account_with_flags(
        config: &AppConfig,
        username: &str,
        secret: &str,
        sync_enabled: bool,
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
            },
        )
        .expect("insert account");

        let connection = open_db(config).expect("db");
        connection
            .query_row(
                "SELECT id FROM accounts WHERE username = ?1 ORDER BY id DESC LIMIT 1",
                params![username],
                |row| row.get(0),
            )
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

    fn count_attachment_catalog_rows(config: &AppConfig) -> i64 {
        let connection = open_db(config).expect("db");
        connection
            .query_row("SELECT COUNT(*) FROM attachment_catalog", [], |row| {
                row.get(0)
            })
            .expect("attachment catalog rows")
    }

    fn count_message_catalog_rows(config: &AppConfig) -> i64 {
        let connection = open_db(config).expect("db");
        connection
            .query_row("SELECT COUNT(*) FROM message_catalog", [], |row| row.get(0))
            .expect("message catalog rows")
    }

    fn load_account_progress_snapshot_for_test(
        config: &AppConfig,
        account_id: i64,
    ) -> AccountProgressSnapshotRecord {
        load_account_progress_snapshot(config, account_id)
            .expect("snapshot query")
            .expect("snapshot row")
    }

    fn first_attachment_item(config: &AppConfig, username: &str) -> AttachmentListItem {
        let page = load_attachment_page_data(
            config,
            username,
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("attachment page");
        page.items.into_iter().next().expect("attachment item")
    }

    fn configure_test_paperless_handoff(config: &mut AppConfig, tempdir: &TempDir) {
        config.paperless_consume_root = Some(Arc::from(
            tempdir
                .path()
                .join("paperless-consume")
                .to_string_lossy()
                .to_string(),
        ));
        config.paperless_handoff_staging_root = Some(Arc::from(
            tempdir
                .path()
                .join("paperless-handoff-staging")
                .to_string_lossy()
                .to_string(),
        ));
    }

    fn mail_export_stub_commands() -> [(&'static str, &'static str); 4] {
        [
            (
                "mbsync",
                "exit 0\n",
            ),
            (
                "notmuch",
                "parse_notmuch_value() {\n  key=\"$1\"\n  awk -F= -v key=\"$key\" '\n    /^\\[database\\]$/ { in_db = 1; next }\n    /^\\[/ { in_db = 0 }\n    in_db && $1 == key { print substr($0, index($0, \"=\") + 1); exit }\n  ' \"$NOTMUCH_CONFIG\"\n}\nSTATE_DIR=\"$HOME/.notmuch-stub\"\nMAILDIR=\"$(parse_notmuch_value mail_root)\"\nDB_DIR=\"$(parse_notmuch_value path)\"\nmkdir -p \"$STATE_DIR\"\ncmd=\"${1:-}\"\nshift || true\ncase \"$cmd\" in\n  new)\n    mkdir -p \"$DB_DIR\"\n    ;;\n  count)\n    find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | wc -l | tr -d ' '\n    ;;\n  search)\n    if printf '%s ' \"$@\" | grep -q -- '--format=json'; then\n      printf '[]'\n      exit 0\n    fi\n    reviewed=\"$STATE_DIR/reviewed\"\n    touch \"$reviewed\"\n    while IFS= read -r path; do\n      rel=\"${path#${MAILDIR}/}\"\n      if grep -Fxq \"$rel\" \"$reviewed\"; then\n        continue\n      fi\n      printf '%s\\n' \"$path\"\n    done < <(find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | sort)\n    ;;\n  tag)\n    tag_spec=\"$1\"\n    shift\n    if [[ \"${1:-}\" == '--' ]]; then\n      shift\n    fi\n    query=\"${1:-}\"\n    rel=\"${query#path:\\\"}\"\n    rel=\"${rel%\\\"}\"\n    rel=\"${rel//\\\\\\\"/\\\"}\"\n    rel=\"${rel//\\\\\\\\/\\\\}\"\n    case \"$tag_spec\" in\n      +archive-reviewed)\n        touch \"$STATE_DIR/reviewed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/reviewed\"\n        sort -u \"$STATE_DIR/reviewed\" -o \"$STATE_DIR/reviewed\"\n        ;;\n      +archive-filed)\n        touch \"$STATE_DIR/filed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/filed\"\n        sort -u \"$STATE_DIR/filed\" -o \"$STATE_DIR/filed\"\n        ;;\n      *)\n        echo \"unsupported tag command: $tag_spec\" >&2\n        exit 1\n        ;;\n    esac\n    ;;\n  *)\n    echo \"unsupported notmuch command: $cmd\" >&2\n    exit 1\n    ;;\nesac\n",
            ),
            (
                "ripmime",
                "input=''\noutput=''\nwhile [[ $# -gt 0 ]]; do\n  case \"$1\" in\n    -i)\n      input=\"$2\"\n      shift 2\n      ;;\n    -d)\n      output=\"$2\"\n      shift 2\n      ;;\n    *)\n      shift\n      ;;\n  esac\ndone\nmkdir -p \"$output\"\ncontents=\"$(cat \"$input\")\"\nif [[ \"$contents\" == *'ATTACH:none'* ]]; then\n  exit 0\nfi\nif [[ \"$contents\" == *'ATTACH:body-parts'* ]]; then\n  : > \"$output/textfile0\"\n  printf 'plain body\\n' > \"$output/textfile1\"\n  printf '<p>html body</p>\\n' > \"$output/textfile2\"\nfi\nif [[ \"$contents\" == *'ATTACH:duplicate-pdf'* ]]; then\n  printf 'duplicate payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:pdf-and-zip'* ]]; then\n  printf 'pdf payload\\n' > \"$output/invoice.pdf\"\n  printf 'zip payload\\n' > \"$output/archive.zip\"\nfi\nif [[ \"$contents\" == *'ATTACH:pdf'* ]]; then\n  printf 'pdf payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:text'* ]]; then\n  printf 'plain text payload\\n' > \"$output/note.txt\"\nfi\nif [[ \"$contents\" == *'ATTACH:tiny-image'* ]]; then\n  printf 'tiny' > \"$output/logo.png\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files-bad'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.bin\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.docx\"\nfi\n",
            ),
            (
                "file",
                "target=\"${@: -1}\"\ncase \"$target\" in\n  *textfile0)\n    printf 'inode/x-empty\\n'\n    ;;\n  *textfile1)\n    printf 'text/plain\\n'\n    ;;\n  *textfile2)\n    printf 'text/html\\n'\n    ;;\n  *.pdf)\n    printf 'application/pdf\\n'\n    ;;\n  *.txt)\n    printf 'text/plain\\n'\n    ;;\n  *.docx)\n    printf 'application/vnd.openxmlformats-officedocument.wordprocessingml.document\\n'\n    ;;\n  *.png)\n    printf 'image/png\\n'\n    ;;\n  *.zip)\n    printf 'application/zip\\n'\n    ;;\n  *.bin)\n    echo 'unknown binary attachment' >&2\n    exit 1\n    ;;\n  *)\n    printf 'application/octet-stream\\n'\n    ;;\nesac\n",
            ),
        ]
    }

    fn mail_export_acl_stub_commands() -> Vec<(&'static str, &'static str)> {
        let mut commands = mail_export_stub_commands().to_vec();
        commands.push((
            "setfacl",
            "printf '%s %s %s\\n' \"$1\" \"$2\" \"$3\" >> \"$SETFACL_LOG\"\n",
        ));
        commands
    }

    fn mail_export_failing_acl_stub_commands() -> Vec<(&'static str, &'static str)> {
        let mut commands = mail_export_stub_commands().to_vec();
        commands.push(("setfacl", "echo 'setfacl denied' >&2\nexit 1\n"));
        commands
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
                .join("_Emails")
                .join(".internal-sync")
                .join("personal-gmail--42")
                .join("maildir")
        );
        assert_eq!(
            paths.account_state_root,
            tempdir
                .path()
                .join("data")
                .join("accounts")
                .join("alice")
                .join("42")
        );
    }

    #[test]
    fn visible_message_filename_caps_long_subjects() {
        let long_subject = "10197254.".to_string() + &"LongToken".repeat(80);
        let filename = visible_message_filename(
            1_632_991_000,
            &long_subject,
            "message-id:very-long-subject@example.com",
        );

        assert!(filename.ends_with(".eml"));
        assert!(filename.len() < 255);
        assert!(filename.contains("["));
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
        assert!(rendered.contains(&format!("Path {}/", paths.maildir.display())));
        assert!(rendered.contains(&format!(
            "SyncState {}",
            paths.sync_state_dir.join("state").display()
        )));
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
        assert!(rendered.contains(&format!(
            "SyncState {}",
            paths.sync_state_dir.join("state").display()
        )));
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
    fn dashboard_load_reconciles_stale_running_syncs() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");

        update_sync_started(&config, account_id).expect("mark running");
        let lock_path = sync_lock_path(&config, account_id);
        write_private_file(&lock_path, b"999999").expect("stale lock");

        let views = load_dashboard_account_views(&config, "alice").expect("dashboard views");

        assert_eq!(views.len(), 1);
        assert_eq!(views[0].status.status_label, "sync failed");
        assert_eq!(
            views[0].status.diagnostic_code.as_deref(),
            Some("interrupted")
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
        with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "vite", || {
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
            assert!(html.contains("@vite/client"));
            assert!(html.contains("/src/entry.dev.tsx"));
            assert!(html.contains("mail-archive-ui-islands"));
            assert!(html.contains("Signed in as alice"));

            let response = html_response(html);
            assert_eq!(
                response.headers().get("X-Frame-Options").expect("header"),
                "DENY"
            );
            assert!(response
                .headers()
                .get("Content-Security-Policy")
                .expect("csp")
                .to_str()
                .expect("csp string")
                .contains("http://127.0.0.1:5173"));
        });
    }

    #[test]
    fn production_frontend_tags_are_read_from_vite_manifest() {
        let tempdir = TempDir::new().expect("tempdir");
        let manifest_dir = tempdir.path().join(".vite");
        fs::create_dir_all(&manifest_dir).expect("manifest dir");
        fs::write(
            manifest_dir.join("manifest.json"),
            r#"{
              "src/entry.prod.tsx": {
                "file": "assets/entry.prod-abc.js",
                "css": ["assets/entry.prod-abc.css"]
              }
            }"#,
        )
        .expect("manifest");

        let tags = production_asset_tags(
            tempdir.path().to_str().expect("utf8 path"),
            FRONTEND_ENTRYPOINT,
        )
        .expect("tags");

        assert!(tags.contains("/static/frontend/assets/entry.prod-abc.css"));
        assert!(tags.contains("/static/frontend/assets/entry.prod-abc.js"));
    }

    #[test]
    fn production_frontend_tags_report_missing_manifest_clearly() {
        let tempdir = TempDir::new().expect("tempdir");
        let error = production_asset_tags(
            tempdir.path().to_str().expect("utf8 path"),
            FRONTEND_ENTRYPOINT,
        )
        .expect_err("missing manifest should fail");

        assert!(error.contains("failed to read Vite manifest"));
    }

    #[test]
    fn csp_only_allows_vite_origin_in_vite_mode() {
        with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "production", || {
            let csp = content_security_policy();
            assert!(!csp.contains("127.0.0.1:5173"));
        });
        with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "vite", || {
            let csp = content_security_policy();
            assert!(csp.contains("http://127.0.0.1:5173"));
            assert!(csp.contains("ws://127.0.0.1:5173"));
        });
    }

    #[test]
    fn dashboard_card_renders_structured_sync_notice() {
        let view = DashboardAccountView {
            account: example_account(),
            status: sample_status_payload(),
        };

        let html = render_account_card(&view);
        assert!(html.contains("Mailbox download failed before new mail could be indexed."));
        assert!(html.contains("Troubleshooting details"));
        assert!(html.contains("Check the mailbox credentials"));
        assert!(html.contains("physical message files representing 6668 logical messages"));
    }

    #[test]
    fn dashboard_keeps_large_hero_panel() {
        let html = render_dashboard(&sample_identity(), &[], None, None);

        assert!(html.contains("class=\"hero\""));
        assert!(html.contains("Mail Archive"));
        assert!(html.contains("Search saved mail and file important attachments."));
    }

    #[test]
    fn metrics_progress_warning_is_exposed_in_status_payload() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");
        let account = read_account(&config, "alice", account_id);
        let paths = ensure_account_paths(&config, &account).expect("paths");
        fs::create_dir_all(&paths.notmuch_db_root).expect("db");
        store_account_progress_snapshot(
            &config,
            account_id,
            &AccountProgressCounts::default(),
            None,
            "error",
            Some("database unavailable"),
        )
        .expect("snapshot");

        let view = build_dashboard_account_view(&config, account);

        assert_eq!(
            view.status.progress_warning.as_deref(),
            Some("Archive counts could not be verified for this mailbox.")
        );
        assert_eq!(view.status.status_label, "check archive");
        assert!(view
            .status
            .progress_warning_detail
            .as_deref()
            .expect("warning detail")
            .contains("database unavailable"));
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

        let view =
            build_dashboard_account_view(&config, read_account(&config, "alice", account_id));
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
        assert!(account.get("archived_message_count").is_some());
        assert!(account.get("archive_file_count").is_some());
        assert!(account.get("overlap_file_count").is_some());
        assert!(account.get("overlap_note").is_some());
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
        let paths = ensure_account_paths(&config, &account).expect("paths");
        assert!(initial.contains("primary_email=alice@gmail.com"));
        assert!(initial.contains(&format!("mail_root={}", paths.maildir.display())));
        assert!(initial.contains(&format!("path={}", paths.notmuch_db_root.display())));
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
                    "mkdir -p \"$HOME/.reindex-log\"\nprintf '%s\n' \"$*\" >> \"$HOME/.reindex-log/commands\"\nawk -F= '\n  /^\\[database\\]$/ { in_db = 1; next }\n  /^\\[/ { in_db = 0 }\n  in_db && $1 == \"path\" { print substr($0, index($0, \"=\") + 1); exit }\n' \"$NOTMUCH_CONFIG\" | xargs -r mkdir -p\n",
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

                let log = fs::read_to_string(
                    paths
                        .account_state_root
                        .join(".reindex-log/commands"),
                )
                .expect("log");
                assert!(log.contains("new"));
                assert!(paths.notmuch_db_root.exists());
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
        fs::create_dir_all(&paths.notmuch_db_root).expect("db");
        assert_eq!(account_index_state(&paths), IndexState::Indexed);
    }

    #[test]
    fn health_payload_reports_success_with_stubbed_commands() {
        with_stubbed_path(
            &[
                ("mbsync", "exit 0\n"),
                ("notmuch", "exit 0\n"),
                ("ripmime", "exit 0\n"),
                ("file", "exit 0\n"),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                initialize_db(&config).expect("db");

                let (status, payload) = health_payload(&config);
                assert_eq!(status, StatusCode::OK);
                assert_eq!(payload.status, "ok");
                assert_eq!(payload.checks.mbsync, "ok");
            },
        );
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
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account(&config, "alice", "secret");
            let account = read_account(&config, "alice", account_id);
            let paths = ensure_account_paths(&config, &account).expect("paths");
            ensure_notmuch_config(&config, &account, &paths).expect("config");
            fs::create_dir_all(&paths.notmuch_db_root).expect("db");
            write_maildir_message(
                &paths,
                "Inbox/cur/msg-1",
                "Message-ID: <search@example.com>\nFrom: Alice Example <alice@example.com>\nSubject: Invoice ready\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

            let results = search_mail(
                &config,
                "alice",
                Some(account_id),
                test_message_filters("subject:invoice"),
                SenderPriorityFilter::All,
            )
            .expect("search");
            assert_eq!(results.len(), 1);
            assert_eq!(results[0].subject, "Invoice ready");
        });
    }

    #[test]
    fn sender_identity_parsing_normalizes_address_and_exact_domain() {
        let parsed =
            sender_identity_from_header("Billing Team <Billing@Example.COM>").expect("sender");
        assert_eq!(parsed.address, "billing@example.com");
        assert_eq!(parsed.domain, "example.com");

        let fallback =
            sender_identity_from_header("broken <fallback@example.org>").expect("fallback sender");
        assert_eq!(fallback.address, "fallback@example.org");
        assert!(sender_identity_from_header("Unknown sender").is_none());
    }

    #[test]
    fn sender_priority_rules_are_per_user_and_address_overrides_domain() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
            .expect("domain rule");
        upsert_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
            .expect("address rule");
        upsert_sender_priority_rule(&config, "bob", "domain", "example.com", "high")
            .expect("bob rule");

        let alice = load_sender_priority_rules(&config, "alice").expect("alice rules");
        assert_eq!(
            alice
                .view_for_sender("Billing <billing@example.com>")
                .priority,
            SenderPriority::Low
        );
        assert_eq!(
            alice.view_for_sender("VIP <vip@example.com>").priority,
            SenderPriority::High
        );
        assert_eq!(
            alice
                .view_for_sender("Subdomain <person@news.example.com>")
                .priority,
            SenderPriority::Normal
        );

        let bob = load_sender_priority_rules(&config, "bob").expect("bob rules");
        assert_eq!(
            bob.view_for_sender("Billing <billing@example.com>")
                .priority,
            SenderPriority::High
        );

        clear_sender_priority_rule(&config, "alice", "address", "vip@example.com").expect("clear");
        let alice = load_sender_priority_rules(&config, "alice").expect("alice after clear");
        assert_eq!(
            alice.view_for_sender("VIP <vip@example.com>").priority,
            SenderPriority::Low
        );
    }

    #[test]
    fn sender_priority_setter_clears_rule_when_normal_is_selected() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);

        set_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
            .expect("set high")
            .expect("saved rule");
        let alice = load_sender_priority_rules(&config, "alice").expect("alice rules");
        assert_eq!(
            alice.view_for_sender("VIP <vip@example.com>").priority,
            SenderPriority::High
        );

        let cleared =
            set_sender_priority_rule(&config, "alice", "address", "vip@example.com", "normal")
                .expect("clear normal");
        assert!(cleared.is_none());
        let alice = load_sender_priority_rules(&config, "alice").expect("alice after clear");
        assert_eq!(
            alice.view_for_sender("VIP <vip@example.com>").priority,
            SenderPriority::Normal
        );
    }

    #[test]
    fn search_mail_sorts_and_filters_by_sender_priority_without_query_changes() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account(&config, "alice", "secret");
            let account = read_account(&config, "alice", account_id);
            let paths = ensure_account_paths(&config, &account).expect("paths");
            ensure_notmuch_config(&config, &account, &paths).expect("config");
            fs::create_dir_all(&paths.notmuch_db_root).expect("db");
            write_maildir_message(
                &paths,
                "Inbox/cur/low",
                "Message-ID: <low@example.com>\nFrom: Low <billing@example.com>\nSubject: Low newest\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
            write_maildir_message(
                &paths,
                "Inbox/cur/normal",
                "Message-ID: <normal@example.com>\nFrom: Normal <alerts@news.example.com>\nSubject: Normal middle\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
            write_maildir_message(
                &paths,
                "Inbox/cur/high",
                "Message-ID: <high@example.com>\nFrom: High <vip@example.com>\nSubject: High oldest\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
            upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
                .expect("domain low");
            upsert_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
                .expect("address high");

            let results = search_mail(
                &config,
                "alice",
                Some(account_id),
                test_message_filters(""),
                SenderPriorityFilter::All,
            )
            .expect("search all");
            assert_eq!(
                results
                    .iter()
                    .map(|result| result.subject.as_str())
                    .collect::<Vec<_>>(),
                ["High oldest", "Normal middle", "Low newest"]
            );

            let low = search_mail(
                &config,
                "alice",
                Some(account_id),
                test_message_filters(""),
                SenderPriorityFilter::Low,
            )
            .expect("search low");
            assert_eq!(low.len(), 1);
            assert_eq!(low[0].subject, "Low newest");
        });
    }

    #[test]
    fn search_mail_applies_structured_sender_subject_date_and_attachment_filters() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-match",
                "Message-ID: <match@example.com>\nFrom: Billing Team <billing@example.com>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-no-attachment",
                "Message-ID: <plain@example.com>\nFrom: Billing Team <billing@example.com>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:none\n",
            );
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-domain",
                "Message-ID: <other@example.net>\nFrom: Billing Team <billing@example.net>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let results = search_mail(
                &config,
                "alice",
                Some(account_id),
                MessageSearchFilters {
                    sender_name: "Billing".to_string(),
                    sender_domain: "example.com".to_string(),
                    subject: "invoice".to_string(),
                    date_from: "2024-04-20".to_string(),
                    date_to: "2024-04-20".to_string(),
                    has_attachments: Some(true),
                    ..Default::default()
                },
                SenderPriorityFilter::All,
            )
            .expect("search");

            assert_eq!(results.len(), 1);
            assert_eq!(results[0].subject, "Invoice ready");
            assert_eq!(results[0].from, "Billing Team <billing@example.com>");
        });
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
            &test_message_filters(""),
            None,
            &[],
            &SearchViewState {
                submitted: false,
                result_count: 0,
                empty_message: Some("Saved search defaults are prefilled below. Submit a query to search indexed mail.".to_string()),
                priority_filter: SenderPriorityFilter::All,
            },
            None,
            None,
        );
        let html_submitted = render_search(
            &identity,
            &[],
            &test_message_filters("from:billing"),
            None,
            &[],
            &SearchViewState {
                submitted: true,
                result_count: 0,
                empty_message: Some("No indexed messages matched this query.".to_string()),
                priority_filter: SenderPriorityFilter::All,
            },
            None,
            None,
        );

        assert!(html_prefill.contains("Saved search defaults"));
        assert!(html_submitted.contains("0 results"));
        assert!(html_submitted.contains("No indexed messages matched this query."));
    }

    #[test]
    fn search_page_uses_compact_heading_and_sticky_result_header() {
        let priority_rules = SenderPriorityRules::default();
        let result = SearchResult {
            account_name: "Personal Gmail".to_string(),
            message_relpath: "Inbox/message.eml".to_string(),
            timestamp: 0,
            date_label: "2024-04-18 14:32 UTC".to_string(),
            from: "Billing <billing@example.com>".to_string(),
            subject: "Invoice ready".to_string(),
            tags: vec!["inbox".to_string()],
            sender_priority: priority_rules.view_for_sender("Billing <billing@example.com>"),
        };
        let html = render_search(
            &sample_identity(),
            &[],
            &test_message_filters("subject:invoice"),
            None,
            &[result],
            &SearchViewState {
                submitted: true,
                result_count: 1,
                empty_message: None,
                priority_filter: SenderPriorityFilter::All,
            },
            None,
            None,
        );

        assert!(html.contains("page-heading"));
        assert!(html.contains("Search mail"));
        assert!(html.contains("mail-list-header"));
        assert!(html.contains("Sender importance"));
        assert!(!html.contains("Query your downloaded mail with notmuch."));
    }

    #[test]
    fn search_reset_link_clears_saved_query() {
        let html = render_search(
            &sample_identity(),
            &[],
            &test_message_filters("remembered query"),
            None,
            &[],
            &SearchViewState {
                submitted: false,
                result_count: 0,
                empty_message: None,
                priority_filter: SenderPriorityFilter::All,
            },
            None,
            None,
        );

        assert!(html.contains("href=\"/search?q=\""));
        assert!(!html.contains("href=\"/search\" title=\"Reset filters\""));
    }

    #[test]
    fn redirect_feedback_renders_as_toasts_not_page_banners() {
        let html = render_search(
            &sample_identity(),
            &[],
            &test_message_filters(""),
            None,
            &[],
            &SearchViewState {
                submitted: false,
                result_count: 0,
                empty_message: None,
                priority_filter: SenderPriorityFilter::All,
            },
            Some("Sender+importance+cleared"),
            Some("Sender+importance+task+failed"),
        );

        assert!(html.contains("toast-stack"));
        assert!(html.contains("class=\"toast success\""));
        assert!(html.contains("class=\"toast error\""));
        assert!(html.contains("Sender importance cleared"));
        assert!(html.contains("Sender importance task failed"));
        assert!(!html.contains("class=\"flash\""));
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

    #[test]
    fn rfc2047_headers_decode_to_display_symbols() {
        let tempdir = TempDir::new().expect("tempdir");
        let message_path = tempdir.path().join("message.eml");
        write_private_file(
            &message_path,
            b"Message-ID: <encoded@example.com>\r\nFrom: =?UTF-8?Q?Billing_=E2=9C=85?= <billing@example.com>\r\nSubject: =?UTF-8?Q?Invoice?=\r\n =?UTF-8?Q?_=E2=9C=85?=\r\nDate: Thu, 18 Apr 2024 14:32:00 +0000\r\n\r\nBody\r\n",
        )
        .expect("message");

        let metadata = read_message_metadata(&message_path).expect("metadata");

        assert_eq!(metadata.subject, "Invoice ✅");
        assert!(metadata.from.contains("Billing ✅"));
        assert_eq!(
            metadata.normalized_message_id.as_deref(),
            Some("encoded@example.com")
        );
    }

    #[test]
    fn malformed_headers_fall_back_without_panicking() {
        let tempdir = TempDir::new().expect("tempdir");
        let message_path = tempdir.path().join("message.eml");
        write_private_file(&message_path, b"Subject: =?UTF-8?Q?broken\r\n\r\nBody\r\n")
            .expect("message");

        let metadata = read_message_metadata(&message_path).expect("metadata");

        assert!(!metadata.subject.is_empty());
        assert_eq!(metadata.from, "Unknown sender");
    }

    #[test]
    fn compact_search_result_markup_truncates_long_values() {
        let priority_rules = SenderPriorityRules::default();
        let result = SearchResult {
            account_name: "Personal Gmail".to_string(),
            message_relpath: "Inbox/very/long/path/that/should/not/overflow/message.eml"
                .to_string(),
            timestamp: 0,
            date_label: format_timestamp_date_label(0),
            from: "Billing ✅ <billing@example.com>".to_string(),
            subject: "Invoice ✅ with a very long subject that should truncate".to_string(),
            tags: vec!["inbox".to_string()],
            sender_priority: priority_rules.view_for_sender("Billing ✅ <billing@example.com>"),
        };

        let html = render_search_result(&result, "/search?q=invoice");

        assert!(html.contains("mail-row"));
        assert!(html.contains("Billing ✅"));
        assert!(html.contains("billing@example.com"));
        assert!(html.contains("Invoice ✅"));
        assert!(html.contains("truncate"));
        assert!(html.contains(&format_timestamp_tooltip_label(0)));
        assert!(!html.contains("Normal priority"));
        assert!(html.contains("Sender importance"));
        assert!(html.contains("name=\"priority\""));
        assert!(html.contains("priority-select-normal"));
        assert!(html.contains("data-priority-select"));
        assert!(html.contains("data-sender-kind=\"address\""));
        assert!(html.contains("data-sender-value=\"billing@example.com\""));
        assert!(html.contains(
            "Personal Gmail · Inbox/very/long/path/that/should/not/overflow/message.eml"
        ));
        assert!(!html.contains("Delete local archive copy"));
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
    fn maildir_inventory_tracks_root_and_nested_folders() {
        let tempdir = TempDir::new().expect("tempdir");
        let maildir = tempdir.path().join("maildir");

        fs::create_dir_all(maildir.join("cur")).expect("root cur");
        fs::create_dir_all(maildir.join("new")).expect("root new");
        fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");
        fs::create_dir_all(maildir.join(".Archive/tmp")).expect("archive tmp");
        fs::create_dir_all(maildir.join(".notmuch")).expect("notmuch");

        write_private_file(
            &maildir.join("cur/root-message"),
            b"Message-ID: <root@example.com>\n\n1",
        )
        .expect("root cur message");
        write_private_file(
            &maildir.join("new/root-new"),
            b"Message-ID: <new@example.com>\n\n1",
        )
        .expect("root new message");
        write_private_file(
            &maildir.join(".Archive/cur/sub-message"),
            b"Message-ID: <archive@example.com>\n\n1",
        )
        .expect("archive cur message");
        write_private_file(&maildir.join(".Archive/tmp/not-a-message"), b"1").expect("tmp file");
        write_private_file(&maildir.join(".notmuch/metadata"), b"1").expect("metadata");

        let inventory = scan_maildir_inventory(&maildir).expect("inventory");
        assert_eq!(inventory.archive_file_count, 3);
        assert_eq!(inventory.logical_message_count, 3);
        assert_eq!(inventory.overlap_file_count, 0);
    }

    #[test]
    fn maildir_inventory_collapses_duplicate_message_ids_across_folders() {
        let tempdir = TempDir::new().expect("tempdir");
        let maildir = tempdir.path().join("maildir");

        fs::create_dir_all(maildir.join("cur")).expect("root cur");
        fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");

        write_private_file(
            &maildir.join("cur/root-message"),
            b"Message-ID: <duplicate@example.com>\n\nsame",
        )
        .expect("root cur message");
        write_private_file(
            &maildir.join(".Archive/cur/sub-message"),
            b"Message-ID: <duplicate@example.com>\n\nsame",
        )
        .expect("archive cur message");

        let inventory = scan_maildir_inventory(&maildir).expect("inventory");
        assert_eq!(inventory.archive_file_count, 2);
        assert_eq!(inventory.logical_message_count, 1);
        assert_eq!(inventory.overlap_file_count, 1);
    }

    #[test]
    fn maildir_inventory_falls_back_to_sha256_when_message_id_is_missing() {
        let tempdir = TempDir::new().expect("tempdir");
        let maildir = tempdir.path().join("maildir");

        fs::create_dir_all(maildir.join("cur")).expect("root cur");
        fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");

        write_private_file(&maildir.join("cur/root-message"), b"same body")
            .expect("root cur message");
        write_private_file(&maildir.join(".Archive/cur/sub-message"), b"same body")
            .expect("archive cur message");
        write_private_file(
            &maildir.join(".Archive/cur/other-message"),
            b"different body",
        )
        .expect("other archive cur message");

        let inventory = scan_maildir_inventory(&maildir).expect("inventory");
        assert_eq!(inventory.archive_file_count, 3);
        assert_eq!(inventory.logical_message_count, 2);
        assert_eq!(inventory.overlap_file_count, 1);
    }

    #[test]
    fn progress_counts_use_logical_messages_for_pending_index() {
        let counts = progress_counts(
            &MaildirInventory {
                archive_file_count: 5,
                logical_message_count: 3,
                overlap_file_count: 2,
            },
            3,
        );

        assert_eq!(counts.archived_message_count, 3);
        assert_eq!(counts.archive_file_count, 5);
        assert_eq!(counts.overlap_file_count, 2);
        assert_eq!(counts.pending_index_count, 0);
        assert_eq!(counts.index_coverage_percent, 100);
    }

    #[test]
    fn overlap_does_not_mark_a_caught_up_index_as_behind() {
        let mut account = example_account();
        account.last_sync_status = Some("ok".to_string());
        let counts = progress_counts(
            &MaildirInventory {
                archive_file_count: 5,
                logical_message_count: 3,
                overlap_file_count: 2,
            },
            3,
        );

        assert_eq!(
            account_status(&account, IndexState::Indexed, &counts, None, None),
            ("ok", "healthy")
        );
        assert_eq!(
            account_progress_note(&account, &counts, IndexState::Indexed, None, None),
            "Search index is caught up with the archived messages."
        );
        assert_eq!(
            account_overlap_note(&counts, None),
            Some(
                "Archive contains 5 physical message files representing 3 logical messages because synced folders overlap."
                    .to_string()
            )
        );
    }

    #[test]
    fn true_logical_index_lag_still_marks_the_account_as_behind() {
        let mut account = example_account();
        account.last_sync_status = Some("ok".to_string());
        let counts = progress_counts(
            &MaildirInventory {
                archive_file_count: 12,
                logical_message_count: 10,
                overlap_file_count: 2,
            },
            8,
        );

        assert_eq!(counts.pending_index_count, 2);
        assert_eq!(
            account_status(&account, IndexState::Indexed, &counts, None, None),
            ("pending", "index behind")
        );
    }

    #[test]
    fn attachment_tables_are_initialized() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let connection = open_db(&config).expect("db");

        let names = [
            "attachment_messages",
            "attachment_catalog",
            "attachment_paperless_handoffs",
        ];
        for name in names {
            let count = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    params![name],
                    |row| row.get::<_, i64>(0),
                )
                .expect("table count");
            assert_eq!(count, 1, "expected table {name} to exist");
        }
        for name in ["attachment_actions", "paperless_attachment_exports"] {
            let count = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    params![name],
                    |row| row.get::<_, i64>(0),
                )
                .expect("table count");
            assert_eq!(count, 0, "expected table {name} to stay absent");
        }
    }

    #[test]
    fn sender_priority_table_is_initialized_and_deleted_tables_are_dropped() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let connection = open_db(&config).expect("db");

        let names = ["sender_priorities"];
        for name in names {
            let count = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    params![name],
                    |row| row.get::<_, i64>(0),
                )
                .expect("table count");
            assert_eq!(count, 1, "expected table {name} to exist");
        }
        for name in ["deleted_messages", "deleted_message_attachments"] {
            let count = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    params![name],
                    |row| row.get::<_, i64>(0),
                )
                .expect("table count");
            assert_eq!(count, 0, "expected table {name} to stay absent");
        }
    }

    #[test]
    fn message_catalog_and_progress_snapshot_tables_are_initialized() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let connection = open_db(&config).expect("db");

        let names = [
            "account_progress_snapshots",
            "message_catalog",
            "message_mailbox_instances",
        ];
        for name in names {
            let count = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    params![name],
                    |row| row.get::<_, i64>(0),
                )
                .expect("table count");
            assert_eq!(count, 1, "expected table {name} to exist");
        }
    }

    #[test]
    fn sync_refreshes_attachment_catalog_and_exposes_unsaved_items() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <catalog@example.com>\nFrom: Billing <billing@example.com>\nSubject: Invoice ready\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            assert_eq!(count_attachment_catalog_rows(&config), 1);
            let item = first_attachment_item(&config, "alice");
            assert_eq!(item.attachment.original_filename, "invoice.pdf");
            assert!(item.attachment.blob_relpath.is_some());
            assert_eq!(item.message.subject, "Invoice ready");
        });
    }

    #[test]
    fn attachment_page_and_bulk_download_respect_sender_priority_filter() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-low",
                "Message-ID: <attach-low@example.com>\nFrom: Billing <billing@example.com>\nSubject: Low attachment\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-normal",
                "Message-ID: <attach-normal@example.com>\nFrom: Normal <alerts@news.example.com>\nSubject: Normal attachment\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nATTACH:text\n",
            );
            upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
                .expect("domain low");

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let low_page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: Some("low".to_string()),
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("low page");
            assert_eq!(low_page.items.len(), 1);
            assert_eq!(low_page.items[0].message.subject, "Low attachment");
            assert_eq!(
                low_page.items[0].sender_priority.priority,
                SenderPriority::Low
            );

            let keys = download_attachment_keys_for_form(
                &config,
                "alice",
                &AttachmentDownloadForm {
                    attachment_keys: Vec::new(),
                    selection_scope: Some(ATTACHMENT_SELECTION_ALL_MATCHING.to_string()),
                    q: None,
                    account_id: None,
                    priority: Some("low".to_string()),
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    return_to: None,
                    ..Default::default()
                },
            )
            .expect("bulk keys");
            assert_eq!(
                keys,
                vec![low_page.items[0].attachment.attachment_key.clone()]
            );
        });
    }

    #[test]
    fn extracted_textfile_body_parts_are_hidden_by_default() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <body-parts@example.com>\nSubject: Body parts\nDate: Fri, 01 May 2026 09:00:00 +0000\n\nATTACH:body-parts\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");
            assert_eq!(count_attachment_catalog_rows(&config), 3);

            let default_page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("default page");
            assert!(default_page.items.is_empty());
            assert_eq!(default_page.state.result_count, 0);

            let included_page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: Some("1".to_string()),
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("included page");
            assert_eq!(included_page.state.result_count, 3);
            assert!(included_page
                .items
                .iter()
                .all(|item| item.attachment.is_inline_artifact));
        });
    }

    #[test]
    fn inline_images_are_excluded_by_default_and_can_be_included() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                concat!(
                    "Message-ID: <inline-image@example.com>\n",
                    "Subject: Inline image\n",
                    "Date: Fri, 01 May 2026 09:00:00 +0000\n",
                    "MIME-Version: 1.0\n",
                    "Content-Type: multipart/related; boundary=\"b\"\n",
                    "\n",
                    "--b\n",
                    "Content-Type: text/html; charset=utf-8\n\n",
                    "<img src=\"cid:logo\">\n",
                    "--b\n",
                    "Content-Type: image/png; name=\"logo ✅.png\"\n",
                    "Content-Disposition: inline; filename=\"logo ✅.png\"\n",
                    "Content-ID: <logo>\n",
                    "\n",
                    "inline image bytes\n",
                    "--b--\n",
                ),
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");
            assert_eq!(count_attachment_catalog_rows(&config), 1);

            let default_page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("default page");
            assert!(default_page.items.is_empty());

            let included_page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: Some("1".to_string()),
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("included page");
            assert_eq!(included_page.items.len(), 1);
            assert_eq!(
                included_page.items[0].attachment.original_filename,
                "logo ✅.png"
            );
            assert!(attachment_is_inline_image(
                &included_page.items[0].attachment
            ));
        });
    }

    #[test]
    fn attachment_verification_checks_materialized_blobs() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <verify@example.com>\nSubject: Verify\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let report_path = tempdir.path().join("report.json");
            let report =
                verify_attachment_archive(&config, true, Some(&report_path)).expect("verify");
            assert_eq!(report.attachments_checked, 1);
            assert!(!report.has_errors());
            assert!(report_path.exists());
        });
    }

    #[test]
    fn sync_builds_visible_mailbox_mirror_and_progress_snapshot() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            let hidden_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <mirror@example.com>\nSubject: Friendly invoice\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            assert_eq!(count_message_catalog_rows(&config), 1);
            let snapshot = load_account_progress_snapshot_for_test(&config, account_id);
            assert_eq!(snapshot.snapshot_status, "ready");
            assert_eq!(snapshot.archived_message_count, 1);

            let visible_filename = visible_message_filename(
                1_713_450_720,
                "Friendly invoice",
                "message-id:mirror@example.com",
            );
            let visible_path = account_paths
                .visible_emails_root
                .join("personal-gmail-inbox/2024/04")
                .join(visible_filename);
            assert!(visible_path.exists());
            assert!(same_file_identity(&hidden_path, &visible_path).expect("same inode"));
        });
    }

    #[test]
    fn sync_applies_visible_mirror_read_acl_to_new_and_existing_hard_links() {
        with_stubbed_path(&mail_export_acl_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let log_path = tempdir.path().join("setfacl.log");
            env::set_var("SETFACL_LOG", &log_path);
            let mut config = test_config(&tempdir);
            config.visible_mirror_read_group = Some(Arc::<str>::from("filestash"));
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            let hidden_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-acl",
                "Message-ID: <acl@example.com>\nSubject: ACL repair\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("initial sync");
            let visible_filename =
                visible_message_filename(1_713_450_720, "ACL repair", "message-id:acl@example.com");
            let visible_path = account_paths
                .visible_emails_root
                .join("personal-gmail-inbox/2024/04")
                .join(&visible_filename);
            assert!(same_file_identity(&hidden_path, &visible_path).expect("same inode"));

            fs::write(&log_path, "").expect("clear acl log");
            run_account_action_for_user(&config, "alice", account_id, AccountAction::Reindex)
                .expect("reindex repairs acl");

            let log = fs::read_to_string(&log_path).expect("acl log");
            assert!(log.contains("g:filestash:r--"));
            assert!(log.contains(visible_path.to_string_lossy().as_ref()));
            assert!(log.contains("g:filestash:r-x"));
            assert!(!log.contains(".internal-sync"));
            env::remove_var("SETFACL_LOG");
        });
    }

    #[test]
    fn visible_mirror_acl_failure_fails_sync_reconciliation() {
        with_stubbed_path(&mail_export_failing_acl_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let mut config = test_config(&tempdir);
            config.visible_mirror_read_group = Some(Arc::<str>::from("filestash"));
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-acl-fail",
                "Message-ID: <acl-fail@example.com>\nSubject: ACL fail\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

            let error =
                run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                    .expect_err("sync should fail when visible mirror acl cannot be applied");

            assert_eq!(error.code, "mailbox_mirror_rebuild_failed");
            assert!(error.detail.contains("setfacl denied"));
        });
    }
    #[test]
    fn attachment_lookup_is_scoped_to_the_authenticated_user() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let alice_account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let bob_account_id = seed_account_with_flags(&config, "bob", "secret", true);
            let alice_account = read_account(&config, "alice", alice_account_id);
            let bob_account = read_account(&config, "bob", bob_account_id);
            let alice_paths = ensure_account_paths(&config, &alice_account).expect("alice paths");
            let bob_paths = ensure_account_paths(&config, &bob_account).expect("bob paths");
            write_maildir_message(
                &alice_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <alice-only@example.com>\n\nATTACH:pdf\n",
            );
            write_maildir_message(
                &bob_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <bob@example.com>\n\n1\n",
            );

            run_account_action_for_user(&config, "alice", alice_account_id, AccountAction::Sync)
                .expect("alice sync");
            run_account_action_for_user(&config, "bob", bob_account_id, AccountAction::Sync)
                .expect("bob sync");

            let item = first_attachment_item(&config, "alice");
            assert!(
                load_attachment_for_user(&config, "bob", &item.attachment.attachment_key).is_err()
            );
        });
    }

    #[test]
    fn attachments_page_renders_bulk_download_controls_without_action_state() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <render@example.com>\nFrom: Render Sender <render@example.com>\n\nATTACH:pdf-and-zip\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    page: None,
                    flash: None,
                    error: None,
                    ..Default::default()
                },
            )
            .expect("page");
            let html = render_attachments_page(&sample_identity(), &page, None, None);
            assert!(!html.contains("save_state"));
            assert!(!html.contains("/save/files"));
            assert!(!html.contains("/save/paperless"));
            assert!(html.contains("aria-label=\"Download selected attachments\""));
            assert!(html.contains("aria-label=\"Send selected attachments to Paperless\""));
            assert!(html.contains("href=\"/attachments?q=\""));
            assert!(!html.contains("href=\"/attachments\" title=\"Reset filters\""));
            assert!(html.contains("title=\"Download attachment locally\""));
            assert!(html.contains("/attachments/send-paperless"));
            assert!(html.contains("data-attachment-row"));
            assert!(html.contains("data-attachment-key"));
            assert!(html.contains("priority-select-normal"));
            assert!(html.contains("page-heading"));
            assert!(html.contains("attachment-list-header"));
            assert!(html.contains("<span>Date</span>"));
            assert!(!html.contains("<span>Select</span>"));
            assert!(!html.contains("<span>Tags</span>"));
            assert!(html.contains("Sender importance"));
            assert!(html.contains("name=\"priority\""));
            assert!(!html.contains("<span>Source</span>"));
            assert!(html.contains("Source: "));
            assert!(!html.contains("Search and download archived mail attachments."));
            assert!(!html.contains("Delete local archive copy"));
            assert!(!html.contains("Restore on next sync"));
            assert!(!html.contains("/messages/"));
        });
    }

    #[test]
    fn attachment_filter_presets_are_user_scoped_and_rendered() {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let preset = save_attachment_filter_preset_for_user(
            &config,
            "alice",
            &AttachmentPresetSaveForm {
                preset_name: "  Invoices  ".to_string(),
                q: Some("rent review".to_string()),
                priority: Some("high".to_string()),
                extension: Some("PDF".to_string()),
                include_inline: Some("1".to_string()),
                download_subfolder: Some("Invoices".to_string()),
                ..Default::default()
            },
        )
        .expect("save preset");

        assert_eq!(preset.name, "Invoices");
        assert!(preset.query.contains("q=rent+review"));
        assert!(preset.query.contains("priority=high"));
        assert!(preset.query.contains("extension=pdf"));
        assert!(preset.query.contains("include_inline=1"));
        assert!(preset.query.contains("download_subfolder=Invoices"));
        assert!(list_attachment_filter_presets(&config, "bob")
            .expect("bob presets")
            .is_empty());

        let page = load_attachment_page_data(&config, "alice", &AttachmentListParams::default())
            .expect("page");
        let html = render_attachments_page(&sample_identity(), &page, None, None);
        assert!(html.contains("Invoices"));
        assert!(html.contains("/attachments/presets/delete"));
        assert!(html.contains("q=rent+review"));
    }

    #[test]
    fn attachment_search_filters_by_structured_fields_and_paperless_handoff_records_state() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let mut config = test_config(&tempdir);
            configure_test_paperless_handoff(&mut config, &tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Paperless invoice\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf-and-zip\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    subject: Some("invoice".to_string()),
                    sender_address: Some("docs@example.com".to_string()),
                    attachment_name: Some("invoice".to_string()),
                    extension: Some("pdf".to_string()),
                    mime_type: Some("pdf".to_string()),
                    min_attachments: Some("2".to_string()),
                    max_attachments: Some("2".to_string()),
                    ..Default::default()
                },
            )
            .expect("page");
            assert_eq!(page.items.len(), 1);
            let key = page.items[0].attachment.attachment_key.clone();

            let sent = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
                .expect("send");
            assert_eq!(sent.sent, 1);
            assert!(sent.failures.is_empty());
            let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
            let consume_files = fs::read_dir(&consume_root)
                .expect("consume dir")
                .collect::<Result<Vec<_>, _>>()
                .expect("consume files");
            assert_eq!(consume_files.len(), 1);
            assert_eq!(
                consume_files[0].file_name().to_string_lossy(),
                "invoice.pdf"
            );
            assert!(!consume_files[0]
                .file_name()
                .to_string_lossy()
                .starts_with("mail-archive-"));
            let staging_root =
                PathBuf::from(config.paperless_handoff_staging_root.as_deref().unwrap());
            assert_eq!(
                fs::read_dir(&staging_root)
                    .expect("staging dir")
                    .collect::<Result<Vec<_>, _>>()
                    .expect("staging files")
                    .len(),
                0
            );
            let recorded_consume_filename = open_db(&config)
                .expect("db")
                .query_row(
                    "SELECT consume_filename FROM attachment_paperless_handoffs WHERE attachment_key = ?1",
                    params![key],
                    |row| row.get::<_, String>(0),
                )
                .expect("handoff filename");
            assert_eq!(recorded_consume_filename, "invoice.pdf");

            let refreshed = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    attachment_name: Some("invoice".to_string()),
                    extension: Some("pdf".to_string()),
                    ..Default::default()
                },
            )
            .expect("refreshed page");
            assert!(refreshed.items[0].paperless_sent_at.is_some());
            let html = render_attachment_item(&refreshed.items[0], "/attachments", false);
            assert!(html.contains("Successfully sent to Paperless on"));
            assert!(html.contains("paperless-sent-button"));

            assert!(send_attachments_to_paperless(&config, "alice", &[key]).is_err());
        });
    }

    #[test]
    fn stale_paperless_handoff_records_are_cleared_and_allows_resend() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let mut config = test_config(&tempdir);
            configure_test_paperless_handoff(&mut config, &tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <stale-paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Stale Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    subject: Some("Stale Paperless".to_string()),
                    ..Default::default()
                },
            )
            .expect("page");
            assert_eq!(page.items.len(), 1);
            let key = page.items[0].attachment.attachment_key.clone();
            let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
            fs::create_dir_all(&consume_root).expect("consume root");

            let connection = open_db(&config).expect("db");
            connection
                .execute(
                    "INSERT OR REPLACE INTO attachment_paperless_handoffs (username, attachment_key, attachment_sha256, original_filename, consume_filename, sent_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        "alice",
                        &key,
                        page.items[0].attachment.attachment_sha256,
                        page.items[0].attachment.original_filename,
                        "missing-stale.pdf",
                        Utc::now().to_rfc3339(),
                    ],
                )
                .expect("manual handoff insert");

            let reloaded = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    subject: Some("Stale Paperless".to_string()),
                    ..Default::default()
                },
            )
            .expect("reloaded page");
            assert!(reloaded.items[0].paperless_sent_at.is_none());

            let remaining = connection
                .query_row(
                    "SELECT COUNT(*) FROM attachment_paperless_handoffs WHERE username = ?1 AND attachment_key = ?2",
                    params!["alice", &key],
                    |row| row.get::<_, i64>(0),
                )
                .expect("handoff row check");
            assert_eq!(remaining, 0);

            let summary =
                send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
                    .expect("resend");
            assert_eq!(summary.sent, 1);
            assert!(summary.sent_attachment_keys.contains(&key));
        });
    }

    #[test]
    fn bulk_paperless_handoff_continues_after_publish_failure() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let mut config = test_config(&tempdir);
            configure_test_paperless_handoff(&mut config, &tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <bulk-paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Bulk Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf-and-zip\n",
            );
            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    subject: Some("Bulk Paperless".to_string()),
                    ..Default::default()
                },
            )
            .expect("page");
            let keys = page
                .items
                .iter()
                .map(|item| item.attachment.attachment_key.clone())
                .collect::<Vec<_>>();
            assert_eq!(keys.len(), 2);
            let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
            fs::create_dir_all(&consume_root).expect("consume root");
            fs::write(consume_root.join("invoice.pdf"), b"existing").expect("existing invoice");

            let summary = send_attachments_to_paperless(&config, "alice", &keys).expect("send");

            assert_eq!(summary.sent, 1);
            assert_eq!(summary.failures.len(), 1);
            assert_eq!(summary.failures[0].filename, "invoice.pdf");
            assert!(summary.failures[0]
                .error
                .contains("already exists after waiting"));
            assert!(consume_root.join("archive.zip").is_file());
            assert_eq!(
                fs::read(consume_root.join("invoice.pdf")).expect("invoice"),
                b"existing"
            );
        });
    }

    #[test]
    fn duplicate_paperless_filenames_do_not_overwrite_existing_consume_file() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let mut config = test_config(&tempdir);
            configure_test_paperless_handoff(&mut config, &tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <duplicate-paperless-1@example.com>\nSubject: Duplicate One\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-2",
                "Message-ID: <duplicate-paperless-2@example.com>\nSubject: Duplicate Two\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nATTACH:duplicate-pdf\n",
            );
            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");

            let page = load_attachment_page_data(
                &config,
                "alice",
                &AttachmentListParams {
                    attachment_name: Some("invoice".to_string()),
                    ..Default::default()
                },
            )
            .expect("page");
            let keys = page
                .items
                .iter()
                .map(|item| item.attachment.attachment_key.clone())
                .collect::<Vec<_>>();
            assert_eq!(keys.len(), 2);

            let summary = send_attachments_to_paperless(&config, "alice", &keys).expect("send");

            assert_eq!(summary.sent, 1);
            assert_eq!(summary.failures.len(), 1);
            assert_eq!(summary.failures[0].filename, "invoice.pdf");
            let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
            let consume_files = fs::read_dir(&consume_root)
                .expect("consume dir")
                .collect::<Result<Vec<_>, _>>()
                .expect("consume files");
            assert_eq!(consume_files.len(), 1);
            assert_eq!(
                consume_files[0].file_name().to_string_lossy(),
                "invoice.pdf"
            );
        });
    }

    #[test]
    fn paperless_handoff_staging_cleanup_only_removes_old_tmp_files() {
        let tempdir = TempDir::new().expect("tempdir");
        let staging_root = tempdir.path().join("staging");
        fs::create_dir_all(&staging_root).expect("staging root");
        let stale_tmp = staging_root.join(".mail-archive-old.tmp");
        let keep_txt = staging_root.join("mail-archive-old.tmp");
        let keep_other = staging_root.join(".mail-archive-old.txt");
        fs::write(&stale_tmp, b"stale").expect("stale");
        fs::write(&keep_txt, b"keep").expect("keep txt");
        fs::write(&keep_other, b"keep").expect("keep other");

        cleanup_paperless_handoff_staging_older_than(&staging_root, -1).expect("cleanup");

        assert!(!stale_tmp.exists());
        assert!(keep_txt.exists());
        assert!(keep_other.exists());
    }

    #[test]
    fn selected_attachment_keys_build_download_zip() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <zip@example.com>\nSubject: Zip ✅\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");
            let item = first_attachment_item(&config, "alice");
            let zip_file = build_attachments_zip(
                &config,
                "alice",
                &AttachmentDownloadForm {
                    attachment_keys: vec![item.attachment.attachment_key],
                    selection_scope: None,
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: None,
                    return_to: None,
                    ..Default::default()
                },
            )
            .expect("zip");

            let file = fs::File::open(&zip_file.path).expect("zip file");
            let mut archive = zip::ZipArchive::new(file).expect("archive");
            assert_eq!(archive.len(), 2);
            let entry = archive.by_index(0).expect("entry");
            assert_eq!(
                entry.name(),
                "Personal Gmail/2024-04-18 - Zip ✅/invoice.pdf"
            );
            drop(entry);
            assert!(archive.by_name("manifest.json").is_ok());
        });
    }

    #[test]
    fn attachment_action_forms_accept_single_and_repeated_keys() {
        let single_download =
            parse_attachment_download_form_body(b"attachment_keys=one&return_to=%2Fattachments");
        assert_eq!(single_download.attachment_keys, vec!["one".to_string()]);
        assert_eq!(single_download.return_to.as_deref(), Some("/attachments"));

        let repeated_download = parse_attachment_download_form_body(
            b"attachment_keys=one&attachment_keys=two&selection_scope=all_matching&q=invoice",
        );
        assert_eq!(
            repeated_download.attachment_keys,
            vec!["one".to_string(), "two".to_string()]
        );
        assert_eq!(
            repeated_download.selection_scope.as_deref(),
            Some(ATTACHMENT_SELECTION_ALL_MATCHING)
        );
        assert_eq!(repeated_download.q.as_deref(), Some("invoice"));

        let paperless = parse_attachment_paperless_form_body(
            b"attachment_keys=one&attachment_keys=two&return_to=%2Fattachments%3Fextension%3Dpdf",
        );
        assert_eq!(
            paperless.attachment_keys,
            vec!["one".to_string(), "two".to_string()]
        );
        assert_eq!(
            paperless.return_to.as_deref(),
            Some("/attachments?extension=pdf")
        );
    }

    #[test]
    fn attachment_downloads_preserve_unicode_filenames_and_zip_subfolder() {
        with_stubbed_path(&mail_export_stub_commands(), |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account_with_flags(&config, "alice", "secret", true);
            let account = read_account(&config, "alice", account_id);
            let account_paths = ensure_account_paths(&config, &account).expect("paths");
            write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                concat!(
                    "Message-ID: <unicode-attachment@example.com>\n",
                    "Subject: Résumé ✅ files\n",
                    "Date: Thu, 18 Apr 2024 14:32:00 +0000\n",
                    "MIME-Version: 1.0\n",
                    "Content-Type: multipart/mixed; boundary=\"b\"\n",
                    "\n",
                    "--b\n",
                    "Content-Type: text/plain; charset=utf-8\n\n",
                    "body\n",
                    "--b\n",
                    "Content-Type: application/pdf; name=\"Résumé ✅.pdf\"\n",
                    "Content-Disposition: attachment; filename=\"Résumé ✅.pdf\"\n",
                    "\n",
                    "pdf bytes\n",
                    "--b--\n",
                ),
            );

            run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                .expect("sync");
            let item = first_attachment_item(&config, "alice");
            assert_eq!(item.attachment.original_filename, "Résumé ✅.pdf");

            let response = attachment_download_response(
                &item.attachment.original_filename,
                &item.attachment.mime_type,
                Vec::new(),
            );
            let disposition = response
                .headers()
                .get(CONTENT_DISPOSITION)
                .expect("content disposition")
                .to_str()
                .expect("ascii header");
            assert!(disposition.contains("filename=\""));
            assert!(disposition.contains("filename*=UTF-8''R%C3%A9sum%C3%A9%20%E2%9C%85.pdf"));

            let zip_file = build_attachments_zip(
                &config,
                "alice",
                &AttachmentDownloadForm {
                    attachment_keys: vec![item.attachment.attachment_key],
                    selection_scope: None,
                    q: None,
                    account_id: None,
                    priority: None,
                    extension: None,
                    include_inline: None,
                    include_inline_images: None,
                    show_mime_details: None,
                    download_subfolder: Some("Downloaded/Invoices ✅".to_string()),
                    return_to: None,
                    ..Default::default()
                },
            )
            .expect("zip");

            let file = fs::File::open(&zip_file.path).expect("zip file");
            let mut archive = zip::ZipArchive::new(file).expect("archive");
            let entry = archive.by_index(0).expect("entry");
            assert_eq!(
                entry.name(),
                "Downloaded/Invoices ✅/Personal Gmail/2024-04-18 - Résumé ✅ files/Résumé ✅.pdf"
            );
        });
    }

    #[test]
    fn duplicate_zip_entry_names_get_human_numeric_suffixes() {
        let mut used = HashMap::new();
        assert_eq!(
            unique_zip_entry_name(
                "mailbox/2026-05-01 - invoice/report.pdf".to_string(),
                &mut used
            ),
            "mailbox/2026-05-01 - invoice/report.pdf"
        );
        assert_eq!(
            unique_zip_entry_name(
                "mailbox/2026-05-01 - invoice/report.pdf".to_string(),
                &mut used
            ),
            "mailbox/2026-05-01 - invoice/report (1).pdf"
        );
    }
}
