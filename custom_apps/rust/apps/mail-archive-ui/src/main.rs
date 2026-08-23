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
use chrono::{DateTime, Duration, Local, NaiveDate, NaiveTime, Timelike, Utc};
#[cfg(target_os = "linux")]
use landlock::{
    path_beneath_rules, Access, AccessFs, RestrictionStatus, Ruleset, RulesetAttr,
    RulesetCreatedAttr, RulesetStatus, ABI,
};
use mailparse::{DispositionType, MailAddr, MailHeaderMap};
use md5::Md5;
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
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
    net::{IpAddr, SocketAddr},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path as FsPath, PathBuf},
    process::{Command, Output},
    sync::Arc,
};
use tokio_util::io::ReaderStream;
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

mod archive;
mod config;
mod database;
mod http;
mod paperless;
mod views;

use archive::*;
use config::*;
use database::*;
use http::*;
use paperless::*;
use views::*;

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 9011;
const DEFAULT_DATA_DIR: &str = ".";
const DEFAULT_STORE_ROOT: &str = ".";
const DEFAULT_RUNTIME_DIR: &str = "/tmp";
const DEFAULT_LOCK_DIR: &str = ".";
const ATTACHMENTS_PER_PAGE: usize = 100;
const MAX_ZIP_ATTACHMENTS: usize = 500;
const MAX_PAPERLESS_TASK_ATTACHMENTS: usize = 2_000;
const DEFAULT_PAPERLESS_TASK_MAX_ATTACHMENTS: usize = 500;
const MIN_PAPERLESS_TASK_INTERVAL_MINUTES: i64 = 15;
const MAX_PAPERLESS_TASK_INTERVAL_MINUTES: i64 = 7 * 24 * 60;
const PAPERLESS_TASK_LEASE_MINUTES: i64 = 30;
const PAPERLESS_TASK_RETRY_BASE_MINUTES: i64 = 5;
const PAPERLESS_TASK_RETRY_MAX_MINUTES: i64 = 6 * 60;
const MAX_ZIP_BYTES: u64 = 1024 * 1024 * 1024;
const RUNTIME_EXPORT_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
const PAPERLESS_HANDOFF_STAGING_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
const PAPERLESS_DATABASE_SNAPSHOT_MAX_AGE_SECONDS: u64 = 10 * 60;
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
struct AppState {
    config: AppConfig,
}

#[derive(Clone, Debug)]
struct Identity {
    username: String,
    email: Option<String>,
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
    message_preview: Option<String>,
    message_preview_truncated: bool,
    message_cc: Option<String>,
}

#[derive(Clone, Debug)]
struct ExtractedAttachment {
    path: PathBuf,
    original_filename: String,
    is_inline_image: bool,
}

#[derive(Clone, Debug, Default)]
struct MessageContextPreview {
    body: Option<String>,
    truncated: bool,
    cc: Option<String>,
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
    archived_message_count: i64,
    indexed_message_count: i64,
    pending_index_count: i64,
    index_coverage_percent: i64,
    archive_file_count: i64,
    overlap_file_count: i64,
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

#[derive(Debug)]
struct PaperlessHandoffLock {
    path: PathBuf,
}

impl Drop for PaperlessHandoffLock {
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
    extension_custom: Option<String>,
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

#[derive(Debug, Default, Deserialize)]
struct AttachmentPaperlessTaskSaveForm {
    task_name: String,
    schedule_time: String,
    schedule_mode: Option<String>,
    interval_minutes: Option<String>,
    paperless_max_documents: Option<String>,
    retry_enabled: Option<String>,
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
struct AttachmentPaperlessTaskDeleteForm {
    task_id: i64,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AttachmentPaperlessTaskToggleForm {
    task_id: i64,
    enabled: Option<String>,
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
    archived_message_count: i64,
    indexed_message_count: i64,
    pending_index_count: i64,
    index_coverage_percent: i64,
    archive_file_count: i64,
    overlap_file_count: i64,
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
    paperless_tasks: Vec<AttachmentPaperlessTask>,
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

#[derive(Debug, Clone)]
struct AttachmentPaperlessTask {
    id: i64,
    username: String,
    name: String,
    query: String,
    schedule_time: String,
    schedule_mode: String,
    interval_minutes: i64,
    max_attachments: i64,
    retry_enabled: bool,
    enabled: bool,
    last_run_date: Option<String>,
    last_run_at: Option<String>,
    last_summary: Option<String>,
    last_status: Option<String>,
    next_retry_at: Option<String>,
    consecutive_failures: i64,
    successful_runs: i64,
    failed_runs: i64,
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
        } else if mode == "paperless-tasks-due" {
            let had_errors =
                run_due_paperless_tasks(&config).expect("mail archive Paperless tasks failed");
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
        .route(
            "/attachments/paperless-tasks",
            post(save_attachment_paperless_task),
        )
        .route(
            "/attachments/paperless-tasks/delete",
            post(delete_attachment_paperless_task),
        )
        .route(
            "/attachments/paperless-tasks/toggle",
            post(toggle_attachment_paperless_task),
        )
        .route("/attachments/refresh", post(refresh_attachments))
        .route(
            "/attachments/{attachment_key}/download/browser",
            post(download_attachment_browser),
        )
        .route(
            "/attachments/{attachment_key}/message/browser",
            get(download_attachment_message_browser),
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

async fn save_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskSaveForm>,
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
        save_attachment_paperless_task_for_user(&config, &username, &form)
    })
    .await;

    match result {
        Ok(Ok(task)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(&format!("Saved Paperless task {}", task.name)),
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
            Some("Paperless task save failed"),
        )),
    }
}

async fn delete_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskDeleteForm>,
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
        delete_attachment_paperless_task_for_user(&config, &username, form.task_id)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some("Paperless task deleted"),
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
            Some("Paperless task delete failed"),
        )),
    }
}

async fn toggle_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskToggleForm>,
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
    let enabled = form.enabled.as_deref() == Some("1");
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        set_attachment_paperless_task_enabled(&config, &username, form.task_id, enabled)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(if enabled {
                "Paperless task enabled"
            } else {
                "Paperless task paused"
            }),
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
            Some("Paperless task update failed"),
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

async fn download_attachment_message_browser(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(attachment_key): Path<String>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let payload = match tokio::task::spawn_blocking(move || {
        let (account, message, _attachment) =
            load_attachment_for_user(&config, &username, &attachment_key)?;
        let account_paths = ensure_account_paths(&config, &account)?;
        let message_path = account_paths.maildir.join(&message.message_relpath);
        let bytes = fs::read(&message_path).map_err(|error| {
            format!(
                "failed to read source message {}: {error}",
                message_path.display()
            )
        })?;
        let filename = format!(
            "{} - {}.eml",
            safe_filename(&format_timestamp_date_label(message.timestamp)),
            safe_filename(&decode_display_header_value(&message.subject))
        );
        Ok::<_, String>((filename, bytes))
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => {
            return server_error_page("Email download failed", &error, Some(&identity))
        }
        Err(_) => {
            return server_error_page(
                "Email download failed",
                "Email download task failed",
                Some(&identity),
            )
        }
    };

    attachment_download_response(&payload.0, "message/rfc822", payload.1)
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
        Ok(Ok(summary)) if summary.successful() > 0 => {
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

    Ok(Identity { username, email })
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
    validate_single_line_config_value("Display name", display_name, 256)?;

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
        validate_imap_host(host)?;
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
    validate_single_line_config_value("Mailbox username", imap_username, 1024)?;

    let folder_patterns = parse_folder_patterns(provider_kind, &form.folder_patterns);
    if folder_patterns.is_empty() {
        return Err("At least one folder pattern is required".to_string());
    }
    for pattern in &folder_patterns {
        validate_single_line_config_value("Folder pattern", pattern, 1024)?;
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

fn validate_single_line_config_value(
    label: &str,
    value: &str,
    max_bytes: usize,
) -> Result<(), String> {
    if value.len() > max_bytes {
        return Err(format!("{label} is too long"));
    }
    if value.chars().any(char::is_control) {
        return Err(format!("{label} must not contain control characters"));
    }
    Ok(())
}

fn validate_imap_host(host: &str) -> Result<(), String> {
    validate_single_line_config_value("IMAP host", host, 253)?;
    if host.parse::<IpAddr>().is_ok() {
        return Ok(());
    }

    let dns_name = host.strip_suffix('.').unwrap_or(host);
    let valid = !dns_name.is_empty()
        && dns_name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
        });
    if valid {
        Ok(())
    } else {
        Err("IMAP host must be a valid DNS name or IP address".to_string())
    }
}

fn escape_mbsync_quoted_value(value: &str) -> Result<String, String> {
    validate_single_line_config_value("mbsync value", value, 1024)?;
    Ok(value.replace('\\', "\\\\").replace('"', "\\\""))
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
    validate_imap_host(&account.imap_host)?;
    validate_single_line_config_value("Mailbox username", &account.imap_username, 1024)?;
    let rendered_username = escape_mbsync_quoted_value(&account.imap_username)?;
    let rendered_patterns = patterns
        .iter()
        .map(|pattern| escape_mbsync_quoted_value(pattern).map(|value| format!("\"{value}\"")))
        .collect::<Result<Vec<_>, _>>()?;
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
    writeln!(&mut rendered, "User \"{rendered_username}\"")
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
    writeln!(&mut rendered, "Patterns {}", rendered_patterns.join(" "))
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
            archived_message_count: counts.archived_message_count as usize,
            indexed_message_count: counts.indexed_message_count as usize,
            pending_index_count: counts.pending_index_count as usize,
            index_coverage_percent: counts.index_coverage_percent as usize,
            archive_file_count: counts.archive_file_count as usize,
            overlap_file_count: counts.overlap_file_count as usize,
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
        archived_message_count: archived_message_count as i64,
        indexed_message_count: indexed_message_count as i64,
        pending_index_count: pending_index_count as i64,
        index_coverage_percent: index_coverage_percent as i64,
        archive_file_count: inventory.archive_file_count as i64,
        overlap_file_count: inventory.overlap_file_count as i64,
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
        "Use Sync Now or Repair search to prepare saved mail for search.".to_string()
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
            Some("Check the mailbox credentials, then use Sync Now again.".to_string())
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
            "Open troubleshooting details if needed, then retry Sync Now or Repair search."
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

fn provider_icon_label(provider: &str) -> &'static str {
    match provider {
        "gmail" => "M",
        _ => "✉",
    }
}

fn provider_icon_class(provider: &str) -> &'static str {
    match provider {
        "gmail" => "gmail",
        _ => "imap",
    }
}

fn last_activity_label(account: &AccountRecord) -> String {
    let Some(value) = account
        .last_sync_finished_at
        .as_deref()
        .or(account.last_sync_started_at.as_deref())
    else {
        return "Never synced".to_string();
    };

    let Ok(synced_at) = DateTime::parse_from_rfc3339(value) else {
        return "Synced recently".to_string();
    };
    let elapsed = Utc::now().signed_duration_since(synced_at.with_timezone(&Utc));
    let elapsed_seconds = elapsed.num_seconds().max(0);

    if elapsed_seconds < 60 {
        "Synced <1 minute ago".to_string()
    } else if elapsed_seconds < 60 * 60 {
        let minutes = elapsed_seconds / 60;
        format!(
            "Synced {minutes} {} ago",
            if minutes == 1 { "minute" } else { "minutes" }
        )
    } else if elapsed_seconds < 24 * 60 * 60 {
        let hours = elapsed_seconds / (60 * 60);
        format!(
            "Synced {hours} {} ago",
            if hours == 1 { "hour" } else { "hours" }
        )
    } else {
        let days = elapsed_seconds / (24 * 60 * 60);
        format!(
            "Synced {days} {} ago",
            if days == 1 { "day" } else { "days" }
        )
    }
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
mod tests;
