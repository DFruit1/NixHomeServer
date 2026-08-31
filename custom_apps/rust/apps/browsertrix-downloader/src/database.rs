use crate::model::{CreateJobRequest, Job, JobProgress, JobStatus};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::path::{Path, PathBuf};

const NOW: &str = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";

#[derive(Clone, Debug)]
pub struct Database {
    path: PathBuf,
}

impl Database {
    pub fn open(path: impl Into<PathBuf>) -> rusqlite::Result<Self> {
        let database = Self { path: path.into() };
        if let Some(parent) = database.path.parent() {
            std::fs::create_dir_all(parent).map_err(io_to_sqlite)?;
        }
        database.migrate()?;
        Ok(database)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn connect(&self) -> rusqlite::Result<Connection> {
        let connection = Connection::open_with_flags(
            &self.path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        Ok(connection)
    }

    fn migrate(&self) -> rusqlite::Result<()> {
        let connection = self.connect()?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.execute_batch(&format!(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
               version INTEGER PRIMARY KEY,
               applied_at TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS jobs (
               id TEXT PRIMARY KEY,
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL,
               created_by TEXT NOT NULL,
               status TEXT NOT NULL,
               request_json TEXT NOT NULL,
               progress_json TEXT,
               archive_file TEXT,
               archive_bytes INTEGER,
               error TEXT
             );
             CREATE INDEX IF NOT EXISTS jobs_status_created_at_idx
               ON jobs(status, created_at);
             CREATE INDEX IF NOT EXISTS jobs_created_by_created_at_idx
               ON jobs(created_by, created_at);
             CREATE TABLE IF NOT EXISTS job_events (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
               created_at TEXT NOT NULL,
               event_type TEXT NOT NULL,
               message TEXT,
               data_json TEXT
             );
             CREATE INDEX IF NOT EXISTS job_events_job_id_created_at_idx
               ON job_events(job_id, created_at);
             INSERT OR IGNORE INTO schema_migrations(version, applied_at)
               VALUES (1, {NOW});"
        ))
    }

    pub fn mark_worker_interrupted(&self) -> rusqlite::Result<usize> {
        self.connect()?.execute(
            &format!(
                "UPDATE jobs
                    SET status = 'failed', updated_at = {NOW},
                        error = 'interrupted by crawl worker restart', progress_json = NULL
                  WHERE status IN ('starting', 'running', 'cancelling')"
            ),
            [],
        )
    }

    pub fn create_job(
        &self,
        id: &str,
        created_by: &str,
        request: &CreateJobRequest,
    ) -> rusqlite::Result<()> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let request_json = serde_json::to_string(request).map_err(json_to_sqlite)?;
        transaction.execute(
            &format!(
                "INSERT INTO jobs(id, created_at, updated_at, created_by, status, request_json)
                 VALUES (?1, {NOW}, {NOW}, ?2, 'queued', ?3)"
            ),
            params![id, created_by, request_json],
        )?;
        transaction.execute(
            &format!(
                "INSERT INTO job_events(job_id, created_at, event_type, message, data_json)
                 VALUES (?1, {NOW}, 'queued', 'Archive job queued', NULL)"
            ),
            [id],
        )?;
        transaction.commit()
    }

    pub fn add_event(
        &self,
        job_id: &str,
        event_type: &str,
        message: Option<&str>,
    ) -> rusqlite::Result<()> {
        self.connect()?.execute(
            &format!(
                "INSERT INTO job_events(job_id, created_at, event_type, message, data_json)
                 VALUES (?1, {NOW}, ?2, ?3, NULL)"
            ),
            params![job_id, event_type, message],
        )?;
        Ok(())
    }

    pub fn set_status(
        &self,
        job_id: &str,
        status: JobStatus,
        error: Option<&str>,
    ) -> rusqlite::Result<()> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute(
            &format!("UPDATE jobs SET status = ?2, updated_at = {NOW}, error = ?3 WHERE id = ?1"),
            params![job_id, status.as_str(), error],
        )?;
        transaction.execute(
            &format!(
                "INSERT INTO job_events(job_id, created_at, event_type, message, data_json)
                 VALUES (?1, {NOW}, ?2, ?3, NULL)"
            ),
            params![job_id, status.as_str(), error],
        )?;
        transaction.commit()
    }

    pub fn request_cancel(&self, job_id: &str) -> rusqlite::Result<bool> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = transaction
            .query_row("SELECT status FROM jobs WHERE id = ?1", [job_id], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;
        let (next, message) = match current.as_deref() {
            Some("queued") => ("cancelled", "Queued archive cancelled"),
            Some("starting" | "running") => ("cancelling", "Cancellation requested"),
            _ => {
                transaction.commit()?;
                return Ok(false);
            }
        };
        let changed = transaction.execute(
            &format!("UPDATE jobs SET status = ?2, updated_at = {NOW} WHERE id = ?1"),
            params![job_id, next],
        )? == 1;
        transaction.execute(
            &format!(
                "INSERT INTO job_events(job_id, created_at, event_type, message, data_json)
                 VALUES (?1, {NOW}, ?2, ?3, NULL)"
            ),
            params![job_id, next, message],
        )?;
        transaction.commit()?;
        Ok(changed)
    }

    pub fn set_progress(
        &self,
        job_id: &str,
        progress: Option<&JobProgress>,
    ) -> rusqlite::Result<()> {
        let progress_json = progress
            .map(serde_json::to_string)
            .transpose()
            .map_err(json_to_sqlite)?;
        self.connect()?.execute(
            &format!("UPDATE jobs SET progress_json = ?2, updated_at = {NOW} WHERE id = ?1"),
            params![job_id, progress_json],
        )?;
        Ok(())
    }

    pub fn set_archive(
        &self,
        job_id: &str,
        archive_file: &str,
        archive_bytes: u64,
    ) -> rusqlite::Result<()> {
        let archive_bytes = i64::try_from(archive_bytes).map_err(|_| {
            rusqlite::Error::ToSqlConversionFailure("archive size exceeds SQLite INTEGER".into())
        })?;
        self.connect()?.execute(
            &format!(
                "UPDATE jobs SET archive_file = ?2, archive_bytes = ?3, updated_at = {NOW}
                  WHERE id = ?1"
            ),
            params![job_id, archive_file, archive_bytes],
        )?;
        Ok(())
    }

    pub fn list_jobs(&self, created_by: &str, limit: usize) -> rusqlite::Result<Vec<Job>> {
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT id, created_at, updated_at, created_by, status, request_json,
                    progress_json, archive_file, archive_bytes, error
               FROM jobs WHERE created_by = ?1
              ORDER BY created_at DESC, id DESC LIMIT ?2",
        )?;
        let jobs = statement
            .query_map(params![created_by, limit.clamp(1, 500) as i64], row_to_job)?
            .collect();
        jobs
    }

    pub fn job(&self, id: &str) -> rusqlite::Result<Option<Job>> {
        self.connect()?
            .query_row(
                "SELECT id, created_at, updated_at, created_by, status, request_json,
                        progress_json, archive_file, archive_bytes, error
                   FROM jobs WHERE id = ?1 LIMIT 1",
                [id],
                row_to_job,
            )
            .optional()
    }

    pub fn job_for_user(&self, id: &str, created_by: &str) -> rusqlite::Result<Option<Job>> {
        self.connect()?
            .query_row(
                "SELECT id, created_at, updated_at, created_by, status, request_json,
                        progress_json, archive_file, archive_bytes, error
                   FROM jobs WHERE id = ?1 AND created_by = ?2 LIMIT 1",
                params![id, created_by],
                row_to_job,
            )
            .optional()
    }

    pub fn active_duplicate(
        &self,
        request: &CreateJobRequest,
        created_by: &str,
    ) -> rusqlite::Result<Option<Job>> {
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT id, created_at, updated_at, created_by, status, request_json,
                    progress_json, archive_file, archive_bytes, error
               FROM jobs
              WHERE created_by = ?1 AND status IN ('queued', 'starting', 'running')
              ORDER BY created_at, id",
        )?;
        let jobs = statement
            .query_map([created_by], row_to_job)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(jobs.into_iter().find(|job| job.request.url == request.url))
    }

    pub fn delete_job(&self, id: &str, created_by: &str) -> rusqlite::Result<usize> {
        self.connect()?.execute(
            "DELETE FROM jobs
              WHERE id = ?1 AND created_by = ?2
                AND status IN ('completed', 'failed', 'cancelled')",
            params![id, created_by],
        )
    }

    pub fn clear_history(&self, created_by: &str) -> rusqlite::Result<usize> {
        self.connect()?.execute(
            "DELETE FROM jobs
              WHERE created_by = ?1 AND status IN ('completed', 'failed', 'cancelled')",
            [created_by],
        )
    }

    pub fn prune_events(&self, retention_days: u32) -> rusqlite::Result<usize> {
        let connection = self.connect()?;
        let cutoff = format!("-{} days", retention_days.max(1));
        let mut deleted = 0;
        loop {
            let changed = connection.execute(
                "DELETE FROM job_events WHERE id IN (
                   SELECT id FROM job_events
                    WHERE created_at < datetime('now', ?1)
                      AND job_id IN (
                        SELECT id FROM jobs WHERE status IN ('completed', 'failed', 'cancelled')
                      )
                    ORDER BY id LIMIT 10000
                 )",
                [&cutoff],
            )?;
            deleted += changed;
            if changed < 10_000 {
                break;
            }
        }
        connection.execute_batch("PRAGMA wal_checkpoint(PASSIVE); PRAGMA optimize;")?;
        Ok(deleted)
    }

    pub fn claim_next_queued_job(&self) -> rusqlite::Result<Option<Job>> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = transaction
            .query_row(
                "SELECT id FROM jobs WHERE status = 'queued'
                  ORDER BY created_at, id LIMIT 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(id) = id else {
            transaction.commit()?;
            return Ok(None);
        };
        if transaction.execute(
            &format!(
                "UPDATE jobs SET status = 'starting', updated_at = {NOW}, error = NULL
                  WHERE id = ?1 AND status = 'queued'"
            ),
            [&id],
        )? != 1
        {
            transaction.rollback()?;
            return Ok(None);
        }
        transaction.execute(
            &format!(
                "INSERT INTO job_events(job_id, created_at, event_type, message, data_json)
                 VALUES (?1, {NOW}, 'starting', 'Job claimed by crawl worker', NULL)"
            ),
            [&id],
        )?;
        transaction.commit()?;
        self.job(&id)
    }
}

fn row_to_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    let status_text: String = row.get(4)?;
    let request_json: String = row.get(5)?;
    let progress_json: Option<String> = row.get(6)?;
    let archive_bytes: Option<i64> = row.get(8)?;
    Ok(Job {
        id: row.get(0)?,
        created_at: row.get(1)?,
        updated_at: row.get(2)?,
        created_by: row.get(3)?,
        status: JobStatus::from_database(&status_text).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(
                4,
                rusqlite::types::Type::Text,
                format!("unknown job status {status_text}").into(),
            )
        })?,
        request: serde_json::from_str(&request_json).map_err(json_from_sqlite)?,
        progress: progress_json
            .map(|value| serde_json::from_str(&value).map_err(json_from_sqlite))
            .transpose()?,
        archive_file: row.get(7)?,
        archive_bytes: archive_bytes.and_then(|value| u64::try_from(value).ok()),
        error: row.get(9)?,
    })
}

fn json_to_sqlite(error: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn json_from_sqlite(error: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

fn io_to_sqlite(error: std::io::Error) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
        Some(error.to_string()),
    )
}
