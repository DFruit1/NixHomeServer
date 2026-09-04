use super::super::*;

pub(crate) fn normalize_attachment_preset_name(raw: &str) -> Result<String, String> {
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err("Preset name is required.".to_string());
    }
    if name.chars().count() > 80 {
        return Err("Preset name must be 80 characters or fewer.".to_string());
    }
    Ok(name)
}

pub(crate) fn list_attachment_filter_presets(
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

pub(crate) fn save_attachment_filter_preset_for_user(
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
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET query = ?3,
                updated_at = ?4
            WHERE username = ?1 AND name = ?2
            "#,
            params![username, name, query, now],
        )
        .map_err(|error| format!("failed to update linked Paperless task: {error}"))?;

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

pub(crate) fn delete_attachment_filter_preset_for_user(
    config: &AppConfig,
    username: &str,
    preset_id: i64,
) -> Result<(), String> {
    let mut connection = open_db(config)?;
    let preset_name = connection
        .query_row(
            "SELECT name FROM attachment_filter_presets WHERE username = ?1 AND id = ?2 LIMIT 1",
            params![username, preset_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("failed to load attachment filter preset: {error}"))?
        .ok_or_else(|| "Attachment filter preset was not found.".to_string())?;

    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to begin preset delete transaction: {error}"))?;
    let deleted = transaction
        .execute(
            "DELETE FROM attachment_filter_presets WHERE username = ?1 AND id = ?2",
            params![username, preset_id],
        )
        .map_err(|error| format!("failed to delete attachment filter preset: {error}"))?;
    if deleted == 0 {
        return Err("Attachment filter preset was not found.".to_string());
    }
    transaction
        .execute(
            "DELETE FROM attachment_paperless_tasks WHERE username = ?1 AND name = ?2",
            params![username, preset_name],
        )
        .map_err(|error| format!("failed to delete linked Paperless task: {error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("failed to commit preset delete: {error}"))?;
    Ok(())
}

pub(crate) fn normalize_daily_schedule_time(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    let time = NaiveTime::parse_from_str(trimmed, "%H:%M")
        .map_err(|_| "Schedule time must use HH:MM format.".to_string())?;
    Ok(time.format("%H:%M").to_string())
}

pub(crate) fn normalize_paperless_schedule(
    mode: Option<&str>,
    interval_minutes: Option<&str>,
) -> Result<(String, i64), String> {
    match mode.unwrap_or("daily").trim() {
        "daily" => Ok(("daily".to_string(), 24 * 60)),
        "interval" => {
            let minutes = interval_minutes
                .unwrap_or("60")
                .trim()
                .parse::<i64>()
                .map_err(|_| "Repeat interval must be a whole number of minutes.".to_string())?;
            if !(MIN_PAPERLESS_TASK_INTERVAL_MINUTES..=MAX_PAPERLESS_TASK_INTERVAL_MINUTES)
                .contains(&minutes)
            {
                return Err(format!(
                    "Repeat interval must be between {MIN_PAPERLESS_TASK_INTERVAL_MINUTES} and {MAX_PAPERLESS_TASK_INTERVAL_MINUTES} minutes."
                ));
            }
            Ok(("interval".to_string(), minutes))
        }
        _ => Err("Schedule mode must be daily or repeating.".to_string()),
    }
}

pub(crate) fn normalize_paperless_task_max_attachments(raw: Option<&str>) -> Result<i64, String> {
    let trimmed = raw.unwrap_or("").trim();
    let value = if trimmed.is_empty() {
        DEFAULT_PAPERLESS_TASK_MAX_ATTACHMENTS as i64
    } else {
        trimmed
            .parse::<i64>()
            .map_err(|_| "Maximum attachments per run must be a whole number.".to_string())?
    };
    if !(1..=(MAX_PAPERLESS_TASK_ATTACHMENTS as i64)).contains(&value) {
        return Err(format!(
            "Maximum attachments per run must be between 1 and {MAX_PAPERLESS_TASK_ATTACHMENTS}."
        ));
    }
    Ok(value)
}

pub(crate) fn map_attachment_paperless_task(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AttachmentPaperlessTask> {
    Ok(AttachmentPaperlessTask {
        id: row.get(0)?,
        username: row.get(1)?,
        name: row.get(2)?,
        query: row.get(3)?,
        schedule_time: row.get(4)?,
        schedule_mode: row.get(5)?,
        interval_minutes: row.get(6)?,
        max_attachments: row.get(7)?,
        retry_enabled: row.get::<_, i64>(8)? != 0,
        enabled: row.get::<_, i64>(9)? != 0,
        last_run_date: row.get(10)?,
        last_run_at: row.get(11)?,
        last_summary: row.get(12)?,
        last_status: row.get(13)?,
        next_retry_at: row.get(14)?,
        consecutive_failures: row.get(15)?,
        successful_runs: row.get(16)?,
        failed_runs: row.get(17)?,
    })
}

pub(crate) fn list_attachment_paperless_tasks(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<AttachmentPaperlessTask>, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT id, username, name, query, schedule_time, schedule_mode,
                   interval_minutes, max_attachments, retry_enabled, enabled,
                   last_run_date, last_run_at, last_summary, last_status,
                   next_retry_at, consecutive_failures, successful_runs, failed_runs
            FROM attachment_paperless_tasks
            WHERE username = ?1
            ORDER BY schedule_time, lower(name), name
            "#,
        )
        .map_err(|error| format!("failed to load Paperless tasks: {error}"))?;
    let rows = statement
        .query_map(params![username], map_attachment_paperless_task)
        .map_err(|error| format!("failed to read Paperless tasks: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode Paperless tasks: {error}"))
}

pub(crate) fn save_attachment_paperless_task_for_user(
    config: &AppConfig,
    username: &str,
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<AttachmentPaperlessTask, String> {
    if config.paperless_consume_root.is_none() {
        return Err("Paperless handoff is not configured.".to_string());
    }
    let name = normalize_attachment_preset_name(&form.task_name)?;
    let schedule_time = normalize_daily_schedule_time(&form.schedule_time)?;
    let (schedule_mode, interval_minutes) = normalize_paperless_schedule(
        form.schedule_mode.as_deref(),
        form.interval_minutes.as_deref(),
    )?;
    let max_attachments =
        normalize_paperless_task_max_attachments(form.paperless_max_documents.as_deref())?;
    let retry_enabled = form.retry_enabled.as_deref() != Some("0");
    let query = attachment_paperless_task_query_from_form(form)?;
    if query.trim().is_empty() {
        return Err(
            "Add at least one attachment filter before saving a Paperless task.".to_string(),
        );
    }

    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO attachment_paperless_tasks (
                username, name, query, schedule_time, schedule_mode, interval_minutes,
                max_attachments, retry_enabled, enabled, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, ?9)
            ON CONFLICT(username, name) DO UPDATE SET
                query = excluded.query,
                schedule_time = excluded.schedule_time,
                schedule_mode = excluded.schedule_mode,
                interval_minutes = excluded.interval_minutes,
                max_attachments = excluded.max_attachments,
                retry_enabled = excluded.retry_enabled,
                enabled = 1,
                next_retry_at = NULL,
                consecutive_failures = 0,
                lease_until = NULL,
                updated_at = excluded.updated_at
            "#,
            params![
                username,
                name,
                query,
                schedule_time,
                schedule_mode,
                interval_minutes,
                max_attachments,
                if retry_enabled { 1i64 } else { 0i64 },
                now,
            ],
        )
        .map_err(|error| format!("failed to save Paperless task: {error}"))?;

    connection
        .query_row(
            r#"
            SELECT id, username, name, query, schedule_time, schedule_mode,
                   interval_minutes, max_attachments, retry_enabled, enabled,
                   last_run_date, last_run_at, last_summary, last_status,
                   next_retry_at, consecutive_failures, successful_runs, failed_runs
            FROM attachment_paperless_tasks
            WHERE username = ?1 AND name = ?2
            LIMIT 1
            "#,
            params![username, name],
            map_attachment_paperless_task,
        )
        .map_err(|error| format!("failed to reload Paperless task: {error}"))
}

pub(crate) fn delete_attachment_paperless_task_for_user(
    config: &AppConfig,
    username: &str,
    task_id: i64,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let deleted = connection
        .execute(
            "DELETE FROM attachment_paperless_tasks WHERE username = ?1 AND id = ?2",
            params![username, task_id],
        )
        .map_err(|error| format!("failed to delete Paperless task: {error}"))?;
    if deleted == 0 {
        return Err("Paperless task was not found.".to_string());
    }
    Ok(())
}

pub(crate) fn set_attachment_paperless_task_enabled(
    config: &AppConfig,
    username: &str,
    task_id: i64,
    enabled: bool,
) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    let updated = connection
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET enabled = ?3, updated_at = ?4
            WHERE username = ?1 AND id = ?2
            "#,
            params![username, task_id, if enabled { 1i64 } else { 0i64 }, now],
        )
        .map_err(|error| format!("failed to update Paperless task: {error}"))?;
    if updated == 0 {
        return Err("Paperless task was not found.".to_string());
    }
    Ok(())
}
