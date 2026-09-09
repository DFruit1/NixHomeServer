use axum::{
    body::{Body, Bytes},
    extract::{Form, Path, Query, State},
    http::{
        header::{ACCEPT, CONTENT_DISPOSITION, CONTENT_TYPE},
        HeaderMap, HeaderValue, StatusCode,
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
use homelab_common::{random_hex, sha256_hex};
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
mod routes;
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
use routes::router;
use sync::*;
use views::*;

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 9011;
const DEFAULT_DATA_DIR: &str = ".";
const DEFAULT_STORE_ROOT: &str = ".";
const DEFAULT_RUNTIME_DIR: &str = "/tmp";
const DEFAULT_LOCK_DIR: &str = ".";
const ATTACHMENTS_PER_PAGE: usize = 100;
const MAIL_PER_PAGE: usize = 100;
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

#[derive(Clone, Debug)]
struct SearchResult {
    account_id: i64,
    account_name: String,
    message_key: String,
    message_relpath: String,
    timestamp: i64,
    date_label: String,
    from: String,
    subject: String,
    sender_priority: SenderPriorityView,
    dismissed_at: Option<String>,
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
    dismissed_at: Option<String>,
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
    page: Option<String>,
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
struct AttachmentDismissForm {
    #[serde(default)]
    attachment_keys: Vec<String>,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MessageDismissForm {
    #[serde(default, deserialize_with = "deserialize_optional_query_i64")]
    account_id: Option<i64>,
    message_key: String,
    return_to: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MessageRestoreForm {
    #[serde(default, deserialize_with = "deserialize_optional_query_i64")]
    account_id: Option<i64>,
    message_key: String,
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
    page: usize,
    has_previous_page: bool,
    has_next_page: bool,
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
        .with_graceful_shutdown(homelab_common::shutdown_signal())
        .await
        .expect("mail archive ui exited unexpectedly");
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

#[cfg(test)]
mod tests;
