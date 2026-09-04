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

mod account_management;
mod archive;
mod config;
mod dashboard;
mod database;
mod http;
mod paperless;
mod sync;
mod views;

use account_management::*;
use archive::*;
use config::*;
#[cfg(test)]
use dashboard::{
    account_overlap_note, account_progress_note, build_dashboard_account_view,
    scan_maildir_inventory,
};
use dashboard::{
    count_indexed_messages, load_dashboard_account_views, load_dashboard_status_payload,
    message_key_from_metadata, progress_counts, provider_icon_class, provider_icon_label,
    provider_label,
};
use database::*;
use http::*;
use paperless::*;
use sync::*;
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
