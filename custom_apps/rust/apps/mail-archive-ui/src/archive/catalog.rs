use super::super::*;

pub(crate) fn list_notmuch_message_files(
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

pub(crate) fn scan_message_attachments_for_catalog(
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

pub(crate) fn load_attachment_messages_for_account(
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

pub(crate) fn refresh_attachment_catalog(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<(), String> {
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

pub(crate) fn refresh_attachment_catalog_for_user(
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
pub(crate) fn load_attachment_catalog_rows_for_account(
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

pub(crate) fn load_message_attachment_states_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<HashMap<String, bool>, String> {
    let mut statement = connection
        .prepare(
            "SELECT message_key, has_attachments FROM attachment_messages WHERE account_id = ?1",
        )
        .map_err(|error| format!("failed to prepare attachment message state query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? != 0))
        })
        .map_err(|error| format!("failed to query attachment message states: {error}"))?;

    rows.collect::<Result<HashMap<_, _>, _>>()
        .map_err(|error| format!("failed to decode attachment message state: {error}"))
}
