use super::super::*;

pub(crate) fn verify_attachment_archive(
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

pub(crate) fn load_attachment_for_user(
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

pub(crate) fn resolve_attachment_payload(
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
