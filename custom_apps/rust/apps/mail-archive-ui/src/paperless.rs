use super::*;

pub(super) fn due_paperless_tasks(
    config: &AppConfig,
) -> Result<Vec<AttachmentPaperlessTask>, String> {
    let now_local = Local::now();
    let now_utc = Utc::now();
    let now_rfc3339 = now_utc.to_rfc3339();
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT id, username, name, query, schedule_time, schedule_mode,
                   interval_minutes, max_attachments, retry_enabled, enabled,
                   last_run_date, last_run_at, last_summary, last_status,
                   next_retry_at, consecutive_failures, successful_runs, failed_runs
            FROM attachment_paperless_tasks
            WHERE enabled = 1
              AND (lease_until IS NULL OR lease_until <= ?1)
            ORDER BY COALESCE(next_retry_at, ''), schedule_time, lower(name), name
            "#,
        )
        .map_err(|error| format!("failed to prepare Paperless task query: {error}"))?;
    let rows = statement
        .query_map(params![now_rfc3339], map_attachment_paperless_task)
        .map_err(|error| format!("failed to query Paperless tasks: {error}"))?;
    let tasks = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode Paperless tasks: {error}"))?;
    Ok(tasks
        .into_iter()
        .filter(|task| paperless_task_is_due(task, now_local, now_utc))
        .collect())
}

pub(super) fn paperless_task_is_due(
    task: &AttachmentPaperlessTask,
    now_local: DateTime<Local>,
    now_utc: DateTime<Utc>,
) -> bool {
    if let Some(next_retry_at) = task.next_retry_at.as_deref() {
        return DateTime::parse_from_rfc3339(next_retry_at)
            .map(|retry_at| retry_at <= now_utc)
            .unwrap_or(true);
    }
    if task.schedule_mode == "interval" {
        return task
            .last_run_at
            .as_deref()
            .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
            .is_none_or(|last_run| last_run + Duration::minutes(task.interval_minutes) <= now_utc);
    }

    let today = now_local.format("%Y-%m-%d").to_string();
    task.schedule_time <= now_local.format("%H:%M").to_string()
        && task.last_run_date.as_deref() != Some(today.as_str())
}

pub(super) fn claim_paperless_task(config: &AppConfig, task_id: i64) -> Result<bool, String> {
    let now = Utc::now();
    let connection = open_db(config)?;
    let updated = connection
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET lease_until = ?2
            WHERE id = ?1
              AND enabled = 1
              AND (lease_until IS NULL OR lease_until <= ?3)
            "#,
            params![
                task_id,
                (now + Duration::minutes(PAPERLESS_TASK_LEASE_MINUTES)).to_rfc3339(),
                now.to_rfc3339(),
            ],
        )
        .map_err(|error| format!("failed to claim Paperless task: {error}"))?;
    Ok(updated == 1)
}

pub(super) fn paperless_retry_delay_minutes(consecutive_failures: usize) -> i64 {
    let exponent = u32::try_from(consecutive_failures.saturating_sub(1).min(10)).unwrap_or(10);
    PAPERLESS_TASK_RETRY_BASE_MINUTES
        .saturating_mul(2_i64.saturating_pow(exponent))
        .min(PAPERLESS_TASK_RETRY_MAX_MINUTES)
}

pub(super) struct PaperlessTaskRunResult {
    pub(super) status: &'static str,
    pub(super) summary: String,
    pub(super) handoff: PaperlessHandoffSummary,
}

pub(super) fn record_paperless_task_run(
    config: &AppConfig,
    task: &AttachmentPaperlessTask,
    started_at: &str,
    run_date: &str,
    result: &PaperlessTaskRunResult,
) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    let failed = result.status != "success";
    let consecutive_failures = if failed {
        task.consecutive_failures.saturating_add(1)
    } else {
        0
    };
    let next_retry_at = if failed && task.retry_enabled {
        Some(
            (Utc::now() + Duration::minutes(paperless_retry_delay_minutes(consecutive_failures)))
                .to_rfc3339(),
        )
    } else {
        None
    };
    let mut connection = open_db(config)?;
    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to begin Paperless task state transaction: {error}"))?;
    transaction
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET last_run_date = CASE
                    WHEN ?5 = 'success' OR ?8 = 0 THEN ?2
                    ELSE last_run_date
                END,
                last_run_at = ?3,
                last_summary = ?4,
                last_status = ?5,
                next_retry_at = ?6,
                consecutive_failures = ?7,
                successful_runs = successful_runs + CASE WHEN ?5 = 'success' THEN 1 ELSE 0 END,
                failed_runs = failed_runs + CASE WHEN ?5 = 'success' THEN 0 ELSE 1 END,
                lease_until = NULL,
                updated_at = ?3
            WHERE id = ?1
            "#,
            params![
                task.id,
                run_date,
                now,
                result.summary,
                result.status,
                next_retry_at,
                consecutive_failures,
                if task.retry_enabled { 1 } else { 0 },
            ],
        )
        .map_err(|error| format!("failed to record Paperless task run: {error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO attachment_paperless_task_runs (
                task_id, username, task_name, started_at, finished_at, status,
                sent_count, already_uploaded_count, skipped_count, failed_count, summary
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                task.id,
                task.username,
                task.name,
                started_at,
                now,
                result.status,
                result.handoff.sent,
                result.handoff.already_uploaded,
                result.handoff.skipped,
                result.handoff.failures.len(),
                result.summary,
            ],
        )
        .map_err(|error| format!("failed to append Paperless task run history: {error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("failed to commit Paperless task state: {error}"))?;
    Ok(())
}

pub(super) fn paperless_task_summary(summary: &PaperlessHandoffSummary) -> String {
    if summary.successful() > 0 {
        summary.flash_message()
    } else if !summary.failures.is_empty() {
        summary.failure_message()
    } else {
        "No new matching attachments".to_string()
    }
}

pub(super) fn run_due_paperless_tasks(config: &AppConfig) -> Result<bool, String> {
    let run_date = Local::now().format("%Y-%m-%d").to_string();
    let tasks = due_paperless_tasks(config)?;
    let mut had_errors = false;

    for task in tasks {
        if !claim_paperless_task(config, task.id)? {
            continue;
        }
        let started_at = Utc::now().to_rfc3339();
        let result = send_attachment_filter_to_paperless(
            config,
            &task.username,
            &task.query,
            task.max_attachments,
        );
        let run_result = match result {
            Ok(handoff) => {
                let status = if handoff.failures.is_empty() {
                    "success"
                } else {
                    "partial"
                };
                if status != "success" {
                    had_errors = true;
                }
                PaperlessTaskRunResult {
                    status,
                    summary: paperless_task_summary(&handoff),
                    handoff,
                }
            }
            Err(error) => {
                had_errors = true;
                PaperlessTaskRunResult {
                    status: "failed",
                    summary: format!("Failed: {error}"),
                    handoff: PaperlessHandoffSummary::default(),
                }
            }
        };
        if let Err(error) =
            record_paperless_task_run(config, &task, &started_at, &run_date, &run_result)
        {
            eprintln!(
                "mail-archive-ui Paperless task state update failed task_id={} detail={}",
                task.id, error
            );
            had_errors = true;
        }
        if run_result.status != "success" {
            eprintln!(
                "mail-archive-ui Paperless task {} task_id={} name={} detail={}",
                run_result.status, task.id, task.name, run_result.summary
            );
        }
    }

    Ok(had_errors)
}

pub(super) fn load_attachment_paperless_handoff(
    connection: &Connection,
    username: &str,
    attachment_key: &str,
) -> Result<Option<String>, String> {
    connection
        .query_row(
            "SELECT sent_at FROM attachment_paperless_handoffs WHERE username = ?1 AND attachment_key = ?2 LIMIT 1",
            params![username, attachment_key],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("failed to query Paperless handoff state: {error}"))
}

pub(super) fn acquire_paperless_handoff_lock(
    config: &AppConfig,
    username: &str,
    attachment_key: &str,
) -> Result<PaperlessHandoffLock, String> {
    let lock_root = PathBuf::from(config.lock_dir.as_ref()).join("paperless-handoffs");
    fs::create_dir_all(&lock_root).map_err(|error| {
        format!(
            "failed to prepare Paperless handoff lock directory {}: {error}",
            lock_root.display()
        )
    })?;
    let lock_name = sha256_hex(format!("{username}\0{attachment_key}").as_bytes());
    let lock_path = lock_root.join(format!("{lock_name}.lock"));

    for _ in 0..2 {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&lock_path)
        {
            Ok(file) => {
                file.sync_all().map_err(|error| {
                    format!(
                        "failed to sync Paperless handoff lock {}: {error}",
                        lock_path.display()
                    )
                })?;
                sync_directory(&lock_root)?;
                return Ok(PaperlessHandoffLock { path: lock_path });
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                let stale = fs::metadata(&lock_path)
                    .and_then(|metadata| metadata.modified())
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .is_some_and(|age| {
                        age.as_secs()
                            > u64::try_from(PAPERLESS_TASK_LEASE_MINUTES * 60).unwrap_or(30 * 60)
                    });
                if stale {
                    match fs::remove_file(&lock_path) {
                        Ok(()) => continue,
                        Err(remove_error) if remove_error.kind() == ErrorKind::NotFound => continue,
                        Err(remove_error) => {
                            return Err(format!(
                                "failed to recover stale Paperless handoff lock {}: {remove_error}",
                                lock_path.display()
                            ))
                        }
                    }
                }
                return Err("This attachment is already being sent to Paperless.".to_string());
            }
            Err(error) => {
                return Err(format!(
                    "failed to acquire Paperless handoff lock {}: {error}",
                    lock_path.display()
                ))
            }
        }
    }

    Err("This attachment is already being sent to Paperless.".to_string())
}

pub(super) fn load_attachment_paperless_handoff_by_sha(
    connection: &Connection,
    username: &str,
    attachment_sha256: &str,
) -> Result<Option<(String, String)>, String> {
    connection
        .query_row(
            r#"
            SELECT consume_filename, sent_at
            FROM attachment_paperless_handoffs
            WHERE username = ?1 AND attachment_sha256 = ?2
            ORDER BY sent_at DESC
            LIMIT 1
            "#,
            params![username, attachment_sha256],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|error| format!("failed to query Paperless handoff by hash: {error}"))
}

#[derive(Debug)]
pub(super) struct PaperlessDocumentMatch {
    pub(super) id: i64,
}

pub(super) fn open_paperless_database(config: &AppConfig) -> Result<Option<Connection>, String> {
    let Some(database_path) = config.paperless_database_path.as_deref() else {
        return Ok(None);
    };
    let metadata = fs::metadata(database_path).map_err(|error| {
        format!("Paperless duplicate-check snapshot is unavailable at {database_path}: {error}")
    })?;
    let snapshot_age = metadata
        .modified()
        .map_err(|error| format!("failed to inspect Paperless duplicate-check snapshot: {error}"))?
        .elapsed()
        .map_err(|error| {
            format!("Paperless duplicate-check snapshot has a future timestamp: {error}")
        })?;
    if snapshot_age.as_secs() > PAPERLESS_DATABASE_SNAPSHOT_MAX_AGE_SECONDS {
        return Err(format!(
            "Paperless duplicate-check snapshot is stale ({} seconds old)",
            snapshot_age.as_secs()
        ));
    }
    let uri = format!("file:{database_path}?mode=ro&immutable=1");
    Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map(Some)
    .map_err(|error| format!("failed to open Paperless database: {error}"))
}

pub(super) fn load_paperless_document_by_checksum(
    connection: Option<&Connection>,
    checksum: &str,
) -> Result<Option<PaperlessDocumentMatch>, String> {
    let Some(connection) = connection else {
        return Ok(None);
    };
    connection
        .query_row(
            r#"
            SELECT id
            FROM documents_document
            WHERE deleted_at IS NULL
              AND (checksum = ?1 OR archive_checksum = ?1)
            ORDER BY id DESC
            LIMIT 1
            "#,
            params![checksum],
            |row| Ok(PaperlessDocumentMatch { id: row.get(0)? }),
        )
        .optional()
        .map_err(|error| format!("failed to query Paperless document checksum: {error}"))
}

#[derive(Debug, Default)]
pub(super) struct PaperlessHandoffSummary {
    pub(super) sent: usize,
    pub(super) already_uploaded: usize,
    pub(super) skipped: usize,
    pub(super) sent_attachment_keys: Vec<String>,
    pub(super) failures: Vec<PaperlessHandoffFailure>,
}

#[derive(Debug)]
pub(super) struct PaperlessHandoffFailure {
    pub(super) attachment_key: String,
    pub(super) filename: String,
    pub(super) error: String,
}

impl PaperlessHandoffSummary {
    pub(super) fn successful(&self) -> usize {
        self.sent + self.already_uploaded
    }

    pub(super) fn flash_message(&self) -> String {
        let base = if self.sent > 0 && self.already_uploaded > 0 {
            format!(
                "{} sent to Paperless; {} already uploaded",
                pluralize_attachments(self.sent),
                pluralize_attachments(self.already_uploaded)
            )
        } else if self.sent > 0 {
            format!("{} sent to Paperless", pluralize_attachments(self.sent))
        } else {
            format!(
                "{} already uploaded to Paperless",
                pluralize_attachments(self.already_uploaded)
            )
        };
        if self.failures.is_empty() {
            base
        } else {
            format!("{base}; {} failed", self.failures.len())
        }
    }

    pub(super) fn failure_message(&self) -> String {
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

pub(super) fn record_attachment_paperless_handoff(
    connection: &Connection,
    username: &str,
    attachment: &AttachmentRecord,
    consume_filename: &str,
    sent_at: &str,
) -> Result<(), String> {
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

pub(super) fn send_attachments_to_paperless(
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

    let connection = open_db(config)?;
    // When a duplicate-check snapshot is configured, fail closed if it cannot
    // be read. Publishing without it can race Paperless's consumer and create a
    // second document after the consume file disappears.
    let paperless_database = open_paperless_database(config)?;
    let mut consume_checksums = index_paperless_consume_files(&consume_root)?;
    let mut seen = HashSet::new();
    let mut reserved_consume_filenames = HashSet::new();
    let mut summary = PaperlessHandoffSummary::default();
    for key in attachment_keys {
        let key = key.trim();
        if key.is_empty() || !seen.insert(key.to_string()) {
            continue;
        }

        let _handoff_lock = match acquire_paperless_handoff_lock(config, username, key) {
            Ok(lock) => lock,
            Err(error) => {
                summary.failures.push(PaperlessHandoffFailure {
                    attachment_key: key.to_string(),
                    filename: "attachment".to_string(),
                    error,
                });
                continue;
            }
        };

        if load_attachment_paperless_handoff(&connection, username, key)?.is_some() {
            // Repeated clicks and retried requests are successful idempotent
            // operations, not user-facing failures.
            summary.already_uploaded += 1;
            summary.sent_attachment_keys.push(key.to_string());
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
        let preferred_consume_filename = paperless_consume_filename(&attachment.original_filename);
        if let Some((consume_filename, sent_at)) = load_attachment_paperless_handoff_by_sha(
            &connection,
            username,
            &attachment.attachment_sha256,
        )? {
            if let Err(error) = record_attachment_paperless_handoff(
                &connection,
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
            summary.already_uploaded += 1;
            summary.sent_attachment_keys.push(key.to_string());
            continue;
        }
        let (_dir, attachment_path) =
            match resolve_attachment_payload(config, &account, &message, &attachment) {
                Ok(payload) => payload,
                Err(error) => {
                    summary.failures.push(PaperlessHandoffFailure {
                        attachment_key: key.to_string(),
                        filename: preferred_consume_filename.clone(),
                        error,
                    });
                    continue;
                }
            };
        if let Some(consume_filename) = consume_checksums
            .get(&attachment.attachment_sha256)
            .cloned()
        {
            let sent_at = Utc::now().to_rfc3339();
            if let Err(error) = record_attachment_paperless_handoff(
                &connection,
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
            summary.already_uploaded += 1;
            summary.sent_attachment_keys.push(key.to_string());
            continue;
        }
        match md5_file(&attachment_path).and_then(|checksum| {
            load_paperless_document_by_checksum(paperless_database.as_ref(), &checksum)
        }) {
            Ok(Some(document)) => {
                let consume_filename = format!("paperless-document-{}", document.id);
                let sent_at = Utc::now().to_rfc3339();
                if let Err(error) = record_attachment_paperless_handoff(
                    &connection,
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
                summary.already_uploaded += 1;
                summary.sent_attachment_keys.push(key.to_string());
                continue;
            }
            Ok(None) => {}
            Err(error) => {
                eprintln!(
                    "mail-archive-ui Paperless duplicate checksum check skipped attachment_key={} detail={}",
                    key, error
                );
            }
        }
        let consume_filename = reserve_available_paperless_consume_filename(
            &consume_root,
            &preferred_consume_filename,
            &mut reserved_consume_filenames,
        );
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
            &connection,
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
        consume_checksums.insert(attachment.attachment_sha256.clone(), consume_filename);
        summary.sent += 1;
        summary.sent_attachment_keys.push(key.to_string());
    }

    if summary.successful() == 0 && summary.failures.is_empty() {
        return Err("Select at least one attachment that has not already been sent.".to_string());
    }

    Ok(summary)
}

pub(super) fn paperless_consume_filename(original_filename: &str) -> String {
    filename_component(
        strip_mail_archive_generated_prefix(original_filename),
        "attachment",
    )
}

pub(super) fn reserve_available_paperless_consume_filename(
    consume_root: &FsPath,
    preferred_filename: &str,
    reserved: &mut HashSet<String>,
) -> String {
    let preferred = filename_component(preferred_filename, "attachment");
    for suffix in std::iter::once(0).chain(2..1000) {
        let candidate = paperless_consume_filename_with_suffix(&preferred, suffix);
        if reserved.contains(&candidate) || consume_root.join(&candidate).exists() {
            continue;
        }
        reserved.insert(candidate.clone());
        return candidate;
    }

    let fallback = paperless_consume_filename_with_suffix(&preferred, 1000 + reserved.len());
    reserved.insert(fallback.clone());
    fallback
}

pub(super) fn index_paperless_consume_files(
    consume_root: &FsPath,
) -> Result<HashMap<String, String>, String> {
    let mut checksums = HashMap::new();
    let entries = match fs::read_dir(consume_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(checksums),
        Err(error) => {
            return Err(format!(
                "failed to read Paperless consume directory {}: {error}",
                consume_root.display()
            ))
        }
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                eprintln!(
                    "mail-archive-ui skipped transient Paperless consume entry detail={error}"
                );
                continue;
            }
        };
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(error) => {
                eprintln!(
                    "mail-archive-ui skipped Paperless consume entry path={} detail={error}",
                    entry.path().display()
                );
                continue;
            }
        };
        if !metadata.is_file() {
            continue;
        }
        let candidate_path = entry.path();
        let candidate_sha256 = match sha256_file(&candidate_path) {
            Ok(checksum) => checksum,
            Err(error) => {
                eprintln!(
                    "mail-archive-ui skipped changing Paperless consume file path={} detail={error}",
                    candidate_path.display()
                );
                continue;
            }
        };
        checksums
            .entry(candidate_sha256)
            .or_insert_with(|| entry.file_name().to_string_lossy().to_string());
    }
    Ok(checksums)
}

pub(super) fn paperless_consume_filename_with_suffix(filename: &str, suffix: usize) -> String {
    if suffix == 0 {
        return filename.to_string();
    }

    if let Some((stem, extension)) = filename.rsplit_once('.') {
        if !stem.is_empty() && !extension.is_empty() {
            return format!("{stem} ({suffix}).{extension}");
        }
    }
    format!("{filename} ({suffix})")
}

pub(super) fn strip_mail_archive_generated_prefix(filename: &str) -> &str {
    let Some(rest) = filename.strip_prefix("mail-archive-") else {
        return filename;
    };
    let mut parts = rest.splitn(4, '-');
    let date = parts.next().unwrap_or_default();
    let time = parts.next().unwrap_or_default();
    let token = parts.next().unwrap_or_default();
    let original = parts.next().unwrap_or_default();
    if date.len() == 8
        && date.chars().all(|character| character.is_ascii_digit())
        && time.len() == 6
        && time.chars().all(|character| character.is_ascii_digit())
        && token.len() >= 8
        && token.chars().all(|character| character.is_ascii_hexdigit())
        && !original.trim().is_empty()
    {
        original
    } else {
        filename
    }
}

pub(super) fn copy_attachment_to_paperless(
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

pub(super) fn paperless_handoff_staging_root(config: &AppConfig, consume_root: &FsPath) -> PathBuf {
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

pub(super) fn paperless_handoff_staging_filename(attachment_key: &str) -> String {
    format!(
        "{}{}-{}{}",
        PAPERLESS_HANDOFF_STAGING_PREFIX,
        random_hex(8),
        filename_component(attachment_key, "attachment-key"),
        PAPERLESS_HANDOFF_STAGING_SUFFIX
    )
}

pub(super) fn sleep_before_paperless_publish_retry() {
    #[cfg(not(test))]
    std::thread::sleep(std::time::Duration::from_millis(
        PAPERLESS_PUBLISH_RETRY_DELAY_MS,
    ));
}

pub(super) fn publish_staged_paperless_file(
    tmp_path: &FsPath,
    final_path: &FsPath,
) -> Result<(), String> {
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

pub(super) fn is_cross_device_link(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(18)
}

pub(super) fn copy_staged_paperless_file_across_devices(
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

pub(super) fn copy_file_to_new_path(
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

pub(super) fn cleanup_old_paperless_handoff_staging(
    handoff_staging_root: &FsPath,
) -> Result<(), String> {
    cleanup_paperless_handoff_staging_older_than(
        handoff_staging_root,
        PAPERLESS_HANDOFF_STAGING_MAX_AGE_SECONDS,
    )
}

pub(super) fn cleanup_paperless_handoff_staging_older_than(
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
