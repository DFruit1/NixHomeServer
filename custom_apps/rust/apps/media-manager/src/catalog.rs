use crate::broker::BrokerAction;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogItem {
    pub id: String,
    pub root_id: String,
    pub owner_username: Option<String>,
    pub relative_path: String,
    pub media_kind: String,
    pub size_bytes: i64,
    pub modified_ns: i64,
    pub fingerprint: String,
}

#[derive(Clone, Debug)]
pub struct ScannedItem {
    pub id: String,
    pub relative_path: String,
    pub media_kind: String,
    pub size_bytes: i64,
    pub modified_ns: i64,
    pub fingerprint: String,
}

#[derive(Clone, Debug)]
pub struct MutationPlanDraft {
    pub id: String,
    pub owner_username: String,
    pub digest: String,
    pub request_json: String,
    pub expires_at: i64,
    pub actions: Vec<BrokerAction>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConfirmPlanOutcome {
    Queued,
    NotFound,
    DigestMismatch,
    Expired,
    StateConflict,
}

#[derive(Clone, Debug)]
pub struct ClaimedMutationPlan {
    pub id: String,
    pub owner_username: String,
    pub actions: Vec<ClaimedMutationAction>,
}

#[derive(Clone, Debug)]
pub struct ClaimedMutationAction {
    pub ordinal: usize,
    pub action: BrokerAction,
}

#[derive(Clone, Debug)]
pub struct ExpiredPreviewAction {
    pub plan_id: String,
    pub ordinal: usize,
    pub action: BrokerAction,
}

pub struct Catalog {
    connection: Connection,
}

impl Catalog {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(error.to_string()),
                )
            })?;
        }
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(std::time::Duration::from_secs(30))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             CREATE TABLE IF NOT EXISTS catalog_items (
               id TEXT PRIMARY KEY,
               root_id TEXT NOT NULL,
               owner_username TEXT,
               relative_path TEXT NOT NULL,
               media_kind TEXT NOT NULL,
               size_bytes INTEGER NOT NULL,
               modified_ns INTEGER NOT NULL,
               fingerprint TEXT NOT NULL,
               scanned_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
               UNIQUE(root_id, owner_username, relative_path)
             );
             CREATE INDEX IF NOT EXISTS catalog_items_root
               ON catalog_items(root_id, owner_username, relative_path);
             CREATE TABLE IF NOT EXISTS catalog_scans (
               root_id TEXT NOT NULL,
               owner_username TEXT NOT NULL DEFAULT '',
               scanned_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
               PRIMARY KEY(root_id, owner_username)
             );
             CREATE TABLE IF NOT EXISTS audit_events (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               request_id TEXT NOT NULL,
               actor_username TEXT NOT NULL,
               event_kind TEXT NOT NULL,
               object_id TEXT,
               detail_json TEXT NOT NULL,
               created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
             );
             CREATE TABLE IF NOT EXISTS user_preferences (
               username TEXT PRIMARY KEY,
               subtitle_languages_json TEXT NOT NULL DEFAULT '[\"en\"]',
               updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
             );
             COMMIT;",
        )?;
        let schema_version =
            connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        match schema_version {
            0 => create_mutation_schema(&connection)?,
            1 => migrate_mutation_schema_v1(&connection)?,
            2 => {}
            version => {
                return Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_SCHEMA),
                    Some(format!(
                        "unsupported Media Manager schema version {version}"
                    )),
                ))
            }
        }
        Ok(Self { connection })
    }

    pub fn schema_version(&self) -> rusqlite::Result<i64> {
        self.connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
    }

    pub fn journal_mode(&self) -> rusqlite::Result<String> {
        self.connection
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
    }

    pub fn list_items(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
        limit: usize,
    ) -> rusqlite::Result<Vec<CatalogItem>> {
        let mut statement = self.connection.prepare(
            "SELECT id, root_id, owner_username, relative_path, media_kind,
                    size_bytes, modified_ns, fingerprint
               FROM catalog_items
              WHERE root_id = ?1
                AND (owner_username IS ?2 OR owner_username = ?2)
              ORDER BY relative_path
              LIMIT ?3",
        )?;
        let rows = statement
            .query_map(
                rusqlite::params![root_id, owner_username, limit.min(500) as i64],
                |row| {
                    Ok(CatalogItem {
                        id: row.get(0)?,
                        root_id: row.get(1)?,
                        owner_username: row.get(2)?,
                        relative_path: row.get(3)?,
                        media_kind: row.get(4)?,
                        size_bytes: row.get(5)?,
                        modified_ns: row.get(6)?,
                        fingerprint: row.get(7)?,
                    })
                },
            )?
            .collect();
        rows
    }

    pub fn list_artwork(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
    ) -> rusqlite::Result<Vec<CatalogItem>> {
        let mut statement = self.connection.prepare(
            "SELECT id, root_id, owner_username, relative_path, media_kind,
                    size_bytes, modified_ns, fingerprint
               FROM catalog_items
              WHERE root_id = ?1
                AND media_kind = 'artwork'
                AND (owner_username IS ?2 OR owner_username = ?2)
              ORDER BY relative_path",
        )?;
        let rows = statement
            .query_map(rusqlite::params![root_id, owner_username], |row| {
                Ok(CatalogItem {
                    id: row.get(0)?,
                    root_id: row.get(1)?,
                    owner_username: row.get(2)?,
                    relative_path: row.get(3)?,
                    media_kind: row.get(4)?,
                    size_bytes: row.get(5)?,
                    modified_ns: row.get(6)?,
                    fingerprint: row.get(7)?,
                })
            })?
            .collect();
        rows
    }

    pub fn root_has_been_scanned(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
    ) -> rusqlite::Result<bool> {
        self.connection.query_row(
            "SELECT EXISTS(
                   SELECT 1 FROM catalog_scans
                    WHERE root_id = ?1 AND owner_username = ?2
                 )",
            rusqlite::params![root_id, owner_username.unwrap_or_default()],
            |row| row.get(0),
        )
    }

    pub fn catalog_item(&self, id: &str) -> rusqlite::Result<Option<CatalogItem>> {
        self.connection
            .query_row(
                "SELECT id, root_id, owner_username, relative_path, media_kind,
                        size_bytes, modified_ns, fingerprint
                   FROM catalog_items WHERE id = ?1",
                [id],
                |row| {
                    Ok(CatalogItem {
                        id: row.get(0)?,
                        root_id: row.get(1)?,
                        owner_username: row.get(2)?,
                        relative_path: row.get(3)?,
                        media_kind: row.get(4)?,
                        size_bytes: row.get(5)?,
                        modified_ns: row.get(6)?,
                        fingerprint: row.get(7)?,
                    })
                },
            )
            .optional()
    }

    pub fn reconcile_root(
        &mut self,
        root_id: &str,
        owner_username: Option<&str>,
        items: &[ScannedItem],
    ) -> rusqlite::Result<usize> {
        let transaction = self.connection.transaction()?;
        let existing_ids = {
            let mut statement = transaction.prepare(
                "SELECT id FROM catalog_items
                  WHERE root_id = ?1
                    AND (owner_username IS ?2 OR owner_username = ?2)",
            )?;
            let rows = statement.query_map(rusqlite::params![root_id, owner_username], |row| {
                row.get::<_, String>(0)
            })?;
            rows.collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?
        };
        let scanned_ids = items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<std::collections::BTreeSet<_>>();

        for item in items {
            transaction.execute(
                "INSERT INTO catalog_items
                 (id, root_id, owner_username, relative_path, media_kind,
                  size_bytes, modified_ns, fingerprint, scanned_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, CURRENT_TIMESTAMP)
                 ON CONFLICT(id) DO UPDATE SET
                   root_id = excluded.root_id,
                   owner_username = excluded.owner_username,
                   relative_path = excluded.relative_path,
                   media_kind = excluded.media_kind,
                   size_bytes = excluded.size_bytes,
                   modified_ns = excluded.modified_ns,
                   fingerprint = excluded.fingerprint,
                   scanned_at = CURRENT_TIMESTAMP",
                rusqlite::params![
                    item.id,
                    root_id,
                    owner_username,
                    item.relative_path,
                    item.media_kind,
                    item.size_bytes,
                    item.modified_ns,
                    item.fingerprint,
                ],
            )?;
        }

        let removed_ids = existing_ids
            .iter()
            .filter(|id| !scanned_ids.contains(id.as_str()))
            .collect::<Vec<_>>();
        for id in &removed_ids {
            transaction.execute("DELETE FROM catalog_items WHERE id = ?1", [id.as_str()])?;
        }
        transaction.execute(
            "INSERT INTO catalog_scans (root_id, owner_username, scanned_at)
             VALUES (?1, ?2, CURRENT_TIMESTAMP)
             ON CONFLICT(root_id, owner_username) DO UPDATE SET
               scanned_at = CURRENT_TIMESTAMP",
            rusqlite::params![root_id, owner_username.unwrap_or_default()],
        )?;
        transaction.commit()?;
        Ok(removed_ids.len())
    }

    pub fn insert_audit_event(
        &self,
        request_id: &str,
        actor_username: &str,
        event_kind: &str,
        object_id: Option<&str>,
        detail_json: &str,
    ) -> rusqlite::Result<()> {
        self.connection.execute(
            "INSERT INTO audit_events
             (request_id, actor_username, event_kind, object_id, detail_json)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                request_id,
                actor_username,
                event_kind,
                object_id,
                detail_json
            ],
        )?;
        Ok(())
    }

    pub fn create_mutation_plan(&mut self, draft: &MutationPlanDraft) -> rusqlite::Result<()> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO mutation_plans
             (id, owner_username, digest, request_json, state, expires_at)
             VALUES (?1, ?2, ?3, ?4, 'previewed', ?5)",
            rusqlite::params![
                draft.id,
                draft.owner_username,
                draft.digest,
                draft.request_json,
                draft.expires_at
            ],
        )?;
        for (ordinal, action) in draft.actions.iter().enumerate() {
            let action_json = serde_json::to_string(action).map_err(json_to_sql_error)?;
            transaction.execute(
                "INSERT INTO mutation_actions
                 (plan_id, ordinal, action_json, state)
                 VALUES (?1, ?2, ?3, 'pending')",
                rusqlite::params![draft.id, ordinal as i64, action_json],
            )?;
        }
        transaction.commit()
    }

    pub fn confirm_mutation_plan(
        &mut self,
        plan_id: &str,
        owner_username: &str,
        digest: &str,
        now: i64,
    ) -> rusqlite::Result<ConfirmPlanOutcome> {
        let transaction = self.connection.transaction()?;
        let plan = transaction
            .query_row(
                "SELECT digest, state, expires_at FROM mutation_plans
                  WHERE id = ?1 AND owner_username = ?2",
                rusqlite::params![plan_id, owner_username],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((stored_digest, state, expires_at)) = plan else {
            return Ok(ConfirmPlanOutcome::NotFound);
        };
        let outcome = if digest != stored_digest {
            ConfirmPlanOutcome::DigestMismatch
        } else if expires_at <= now {
            transaction.execute(
                "UPDATE mutation_plans SET state = 'expired' WHERE id = ?1 AND state = 'previewed'",
                [plan_id],
            )?;
            ConfirmPlanOutcome::Expired
        } else if state != "previewed" {
            ConfirmPlanOutcome::StateConflict
        } else {
            transaction.execute(
                "UPDATE mutation_plans SET state = 'queued', confirmed_at = CURRENT_TIMESTAMP
                  WHERE id = ?1 AND state = 'previewed'",
                [plan_id],
            )?;
            ConfirmPlanOutcome::Queued
        };
        transaction.commit()?;
        Ok(outcome)
    }

    pub fn claim_expired_preview_action(
        &mut self,
        now: i64,
    ) -> rusqlite::Result<Option<ExpiredPreviewAction>> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE mutation_plans
                SET state = 'expired', finished_at = CURRENT_TIMESTAMP
              WHERE state = 'previewed' AND expires_at <= ?1",
            [now],
        )?;
        let action = transaction
            .query_row(
                "SELECT plan.id, action.ordinal, action.action_json
                   FROM mutation_plans AS plan
                   JOIN mutation_actions AS action ON action.plan_id = plan.id
                  WHERE plan.state = 'expired' AND action.state = 'pending'
                  ORDER BY plan.expires_at, plan.created_at, plan.id, action.ordinal
                  LIMIT 1",
                [],
                |row| {
                    let ordinal = row.get::<_, i64>(1)?;
                    let json = row.get::<_, String>(2)?;
                    Ok(ExpiredPreviewAction {
                        plan_id: row.get(0)?,
                        ordinal: usize::try_from(ordinal).map_err(|error| {
                            rusqlite::Error::FromSqlConversionFailure(
                                1,
                                rusqlite::types::Type::Integer,
                                Box::new(error),
                            )
                        })?,
                        action: serde_json::from_str(&json).map_err(json_from_sql_error)?,
                    })
                },
            )
            .optional()?;
        transaction.commit()?;
        Ok(action)
    }

    pub fn complete_expired_preview_action(
        &self,
        plan_id: &str,
        ordinal: usize,
    ) -> rusqlite::Result<()> {
        let changed = self.connection.execute(
            "UPDATE mutation_actions
                SET state = 'completed', completed_at = CURRENT_TIMESTAMP, error = NULL
              WHERE plan_id = ?1 AND ordinal = ?2 AND state = 'pending'
                AND EXISTS (
                  SELECT 1 FROM mutation_plans
                   WHERE id = ?1 AND state = 'expired'
                )",
            rusqlite::params![plan_id, ordinal as i64],
        )?;
        if changed == 1 {
            Ok(())
        } else {
            Err(rusqlite::Error::QueryReturnedNoRows)
        }
    }

    pub fn claim_next_mutation_plan(&mut self) -> rusqlite::Result<Option<ClaimedMutationPlan>> {
        self.claim_mutation_plan(false)
    }

    pub fn claim_or_resume_mutation_plan(
        &mut self,
    ) -> rusqlite::Result<Option<ClaimedMutationPlan>> {
        self.claim_mutation_plan(true)
    }

    fn claim_mutation_plan(
        &mut self,
        resume_running: bool,
    ) -> rusqlite::Result<Option<ClaimedMutationPlan>> {
        let transaction = self.connection.transaction()?;
        let query = if resume_running {
            "SELECT id, owner_username FROM mutation_plans
              WHERE state IN ('running', 'queued')
              ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,
                       confirmed_at, created_at, id LIMIT 1"
        } else {
            "SELECT id, owner_username FROM mutation_plans
              WHERE state = 'queued'
              ORDER BY confirmed_at, created_at, id LIMIT 1"
        };
        let plan = transaction
            .query_row(query, [], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .optional()?;
        let Some((id, owner_username)) = plan else {
            transaction.commit()?;
            return Ok(None);
        };
        transaction.execute(
            "UPDATE mutation_plans
                SET state = 'running', started_at = COALESCE(started_at, CURRENT_TIMESTAMP)
              WHERE id = ?1 AND state IN ('queued', 'running')",
            [&id],
        )?;
        let actions = {
            let mut statement = transaction.prepare(
                "SELECT ordinal, action_json FROM mutation_actions
                  WHERE plan_id = ?1 AND state != 'completed' ORDER BY ordinal",
            )?;
            let rows = statement.query_map([&id], |row| {
                let ordinal = row.get::<_, i64>(0)?;
                let json = row.get::<_, String>(1)?;
                let action =
                    serde_json::from_str::<BrokerAction>(&json).map_err(json_from_sql_error)?;
                Ok(ClaimedMutationAction {
                    ordinal: usize::try_from(ordinal).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                    action,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        transaction.commit()?;
        Ok(Some(ClaimedMutationPlan {
            id,
            owner_username,
            actions,
        }))
    }

    pub fn complete_mutation_action(&self, plan_id: &str, ordinal: usize) -> rusqlite::Result<()> {
        let changed = self.connection.execute(
            "UPDATE mutation_actions
                SET state = 'completed', completed_at = CURRENT_TIMESTAMP, error = NULL
              WHERE plan_id = ?1 AND ordinal = ?2 AND state != 'completed'",
            rusqlite::params![plan_id, ordinal as i64],
        )?;
        if changed == 1 {
            Ok(())
        } else {
            Err(rusqlite::Error::QueryReturnedNoRows)
        }
    }

    pub fn finish_mutation_plan(&self, plan_id: &str, error: Option<&str>) -> rusqlite::Result<()> {
        match error {
            Some(error) => {
                self.connection.execute(
                    "UPDATE mutation_plans
                        SET state = 'failed', finished_at = CURRENT_TIMESTAMP, error = ?2
                      WHERE id = ?1 AND state = 'running'",
                    rusqlite::params![plan_id, error],
                )?;
            }
            None => {
                let incomplete: i64 = self.connection.query_row(
                    "SELECT count(*) FROM mutation_actions
                      WHERE plan_id = ?1 AND state != 'completed'",
                    [plan_id],
                    |row| row.get(0),
                )?;
                if incomplete != 0 {
                    return Err(rusqlite::Error::SqliteFailure(
                        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
                        Some("cannot complete a plan with pending actions".to_string()),
                    ));
                }
                self.connection.execute(
                    "UPDATE mutation_plans
                        SET state = 'completed', finished_at = CURRENT_TIMESTAMP, error = NULL
                      WHERE id = ?1 AND state = 'running'",
                    [plan_id],
                )?;
            }
        }
        Ok(())
    }

    pub fn mutation_plan_state(&self, plan_id: &str) -> rusqlite::Result<Option<String>> {
        self.connection
            .query_row(
                "SELECT state FROM mutation_plans WHERE id = ?1",
                [plan_id],
                |row| row.get(0),
            )
            .optional()
    }
}

fn create_mutation_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE mutation_plans (
           id TEXT PRIMARY KEY,
           owner_username TEXT NOT NULL,
           digest TEXT NOT NULL,
           request_json TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN
             ('previewed', 'queued', 'running', 'completed', 'failed', 'expired', 'rejected')),
           created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
           confirmed_at TEXT,
           started_at TEXT,
           finished_at TEXT,
           expires_at INTEGER NOT NULL,
           error TEXT
         );
         CREATE TABLE mutation_actions (
           plan_id TEXT NOT NULL REFERENCES mutation_plans(id) ON DELETE CASCADE,
           ordinal INTEGER NOT NULL,
           action_json TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN ('pending', 'completed')),
           completed_at TEXT,
           error TEXT,
           PRIMARY KEY(plan_id, ordinal)
         );
         CREATE INDEX mutation_plans_queue
           ON mutation_plans(state, confirmed_at, created_at);
         PRAGMA user_version = 2;
         COMMIT;",
    )
}

fn migrate_mutation_schema_v1(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE mutation_plans RENAME TO mutation_plans_v1;
         CREATE TABLE mutation_plans (
           id TEXT PRIMARY KEY,
           owner_username TEXT NOT NULL,
           digest TEXT NOT NULL,
           request_json TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN
             ('previewed', 'queued', 'running', 'completed', 'failed', 'expired', 'rejected')),
           created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
           confirmed_at TEXT,
           started_at TEXT,
           finished_at TEXT,
           expires_at INTEGER NOT NULL,
           error TEXT
         );
         INSERT INTO mutation_plans
           (id, owner_username, digest, request_json, state, created_at, expires_at)
         SELECT id, owner_username, digest, request_json,
                CASE WHEN state = 'queued' THEN 'rejected' ELSE state END,
                created_at,
                COALESCE(CAST(strftime('%s', expires_at) AS INTEGER), 0)
           FROM mutation_plans_v1;
         DROP TABLE mutation_plans_v1;
         CREATE TABLE mutation_actions (
           plan_id TEXT NOT NULL REFERENCES mutation_plans(id) ON DELETE CASCADE,
           ordinal INTEGER NOT NULL,
           action_json TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN ('pending', 'completed')),
           completed_at TEXT,
           error TEXT,
           PRIMARY KEY(plan_id, ordinal)
         );
         CREATE INDEX mutation_plans_queue
           ON mutation_plans(state, confirmed_at, created_at);
         PRAGMA user_version = 2;
         COMMIT;",
    )
}

fn json_to_sql_error(error: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn json_from_sql_error(error: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

#[derive(Clone, Debug)]
pub struct CatalogHandle {
    path: PathBuf,
}

impl CatalogHandle {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn open(&self) -> rusqlite::Result<Catalog> {
        Catalog::open(&self.path)
    }
}
