use super::super::*;

pub(crate) fn collect_live_messages_for_account(
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

pub(crate) fn search_mail(
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
        let attachment_states =
            load_message_attachment_states_for_account(&connection, account.id)?;
        for item in collect_live_messages_for_account(config, &account, &query)? {
            let has_attachments = attachment_states
                .get(&item.message_key)
                .copied()
                .unwrap_or(false);
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

pub(crate) fn load_account_progress_snapshot(
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

pub(crate) fn store_account_progress_snapshot(
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

pub(crate) fn snapshot_counts(snapshot: &AccountProgressSnapshotRecord) -> AccountProgressCounts {
    AccountProgressCounts {
        archived_message_count: snapshot.archived_message_count,
        indexed_message_count: snapshot.indexed_message_count,
        pending_index_count: snapshot.pending_index_count,
        index_coverage_percent: snapshot.index_coverage_percent,
        archive_file_count: snapshot.archive_file_count,
        overlap_file_count: snapshot.overlap_file_count,
    }
}

pub(crate) fn load_message_mailbox_instances_for_account(
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

pub(crate) fn visible_account_slug(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<String, String> {
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

pub(crate) fn preferred_mailbox_slug(raw_mailbox_path: &str) -> String {
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

pub(crate) fn raw_mailbox_path_from_hidden_relpath(hidden_relpath: &str) -> String {
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

pub(crate) fn short_message_key(message_key: &str) -> String {
    sha256_hex(message_key.as_bytes())
        .chars()
        .take(8)
        .collect::<String>()
}

pub(crate) fn visible_message_subject(subject: &str) -> String {
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

pub(crate) fn visible_message_filename(timestamp: i64, subject: &str, message_key: &str) -> String {
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

pub(crate) fn timestamp_year_month(timestamp: i64) -> (String, String) {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| {
            (
                value.format("%Y").to_string(),
                value.format("%m").to_string(),
            )
        })
        .unwrap_or_else(|| ("1970".to_string(), "01".to_string()))
}

pub(crate) fn same_file_identity(left: &FsPath, right: &FsPath) -> Result<bool, String> {
    let left_meta = fs::metadata(left)
        .map_err(|error| format!("failed to inspect {}: {error}", left.display()))?;
    let right_meta = fs::metadata(right)
        .map_err(|error| format!("failed to inspect {}: {error}", right.display()))?;
    Ok(left_meta.dev() == right_meta.dev() && left_meta.ino() == right_meta.ino())
}

pub(crate) fn ensure_hard_link(source: &FsPath, destination: &FsPath) -> Result<(), String> {
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

pub(crate) fn reconcile_visible_mirror_read_acl(
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

pub(crate) fn setfacl(path: &FsPath, acl: &str) -> Result<(), String> {
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

pub(crate) fn prune_empty_ancestors(path: &FsPath, stop_at: &FsPath) -> Result<(), String> {
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

pub(crate) fn rebuild_message_catalog_and_visible_mailboxes(
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
            Some("Use Sync Now or Repair search to rebuild dashboard counts."),
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
