use super::*;

pub(super) fn initialize_db(config: &AppConfig) -> Result<(), String> {
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

            CREATE TABLE IF NOT EXISTS attachment_paperless_tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                name TEXT NOT NULL,
                query TEXT NOT NULL,
                schedule_time TEXT NOT NULL,
                schedule_mode TEXT NOT NULL DEFAULT 'daily',
                interval_minutes INTEGER NOT NULL DEFAULT 1440,
                max_attachments INTEGER NOT NULL DEFAULT 500,
                retry_enabled INTEGER NOT NULL DEFAULT 1,
                enabled INTEGER NOT NULL DEFAULT 1,
                last_run_date TEXT,
                last_run_at TEXT,
                last_summary TEXT,
                last_status TEXT,
                next_retry_at TEXT,
                consecutive_failures INTEGER NOT NULL DEFAULT 0,
                successful_runs INTEGER NOT NULL DEFAULT 0,
                failed_runs INTEGER NOT NULL DEFAULT 0,
                lease_until TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE (username, name)
            );

            CREATE INDEX IF NOT EXISTS idx_attachment_paperless_tasks_due
            ON attachment_paperless_tasks (enabled, schedule_time, last_run_date);

            CREATE TABLE IF NOT EXISTS attachment_paperless_task_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER NOT NULL,
                username TEXT NOT NULL,
                task_name TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT NOT NULL,
                status TEXT NOT NULL,
                sent_count INTEGER NOT NULL DEFAULT 0,
                already_uploaded_count INTEGER NOT NULL DEFAULT 0,
                skipped_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0,
                summary TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES attachment_paperless_tasks(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_attachment_paperless_task_runs_task
            ON attachment_paperless_task_runs (task_id, id DESC);

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
        (
            "attachment_paperless_tasks",
            "schedule_mode",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN schedule_mode TEXT NOT NULL DEFAULT 'daily'",
        ),
        (
            "attachment_paperless_tasks",
            "interval_minutes",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN interval_minutes INTEGER NOT NULL DEFAULT 1440",
        ),
        (
            "attachment_paperless_tasks",
            "max_attachments",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN max_attachments INTEGER NOT NULL DEFAULT 500",
        ),
        (
            "attachment_paperless_tasks",
            "retry_enabled",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN retry_enabled INTEGER NOT NULL DEFAULT 1",
        ),
        (
            "attachment_paperless_tasks",
            "last_status",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN last_status TEXT",
        ),
        (
            "attachment_paperless_tasks",
            "next_retry_at",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN next_retry_at TEXT",
        ),
        (
            "attachment_paperless_tasks",
            "consecutive_failures",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN consecutive_failures INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "attachment_paperless_tasks",
            "successful_runs",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN successful_runs INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "attachment_paperless_tasks",
            "failed_runs",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN failed_runs INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "attachment_paperless_tasks",
            "lease_until",
            "ALTER TABLE attachment_paperless_tasks ADD COLUMN lease_until TEXT",
        ),
    ] {
        ensure_table_column(&connection, table, column, sql)?;
    }
    connection
        .execute_batch(
            r#"
            CREATE INDEX IF NOT EXISTS idx_attachment_paperless_tasks_scheduler
            ON attachment_paperless_tasks (enabled, next_retry_at, lease_until, schedule_time);
            "#,
        )
        .map_err(|error| format!("failed to create Paperless task scheduler index: {error}"))?;

    Ok(())
}

pub(super) fn ensure_table_column(
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

pub(super) fn ensure_account_column(
    connection: &Connection,
    column: &str,
    sql: &str,
) -> Result<(), String> {
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

pub(super) fn drop_account_column_if_exists(
    connection: &Connection,
    column: &str,
) -> Result<(), String> {
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

pub(super) fn open_db(config: &AppConfig) -> Result<Connection, String> {
    let db_path = PathBuf::from(config.data_dir.as_ref()).join(DB_FILENAME);
    let connection = Connection::open(db_path)
        .map_err(|error| format!("failed to open sqlite database: {error}"))?;
    connection
        .busy_timeout(std::time::Duration::from_secs(30))
        .map_err(|error| format!("failed to configure sqlite busy timeout: {error}"))?;
    connection
        .execute_batch("PRAGMA foreign_keys = ON;")
        .map_err(|error| format!("failed to configure sqlite connection: {error}"))?;
    Ok(connection)
}
