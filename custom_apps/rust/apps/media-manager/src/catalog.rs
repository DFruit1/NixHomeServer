use crate::broker::BrokerAction;
use crate::media::MediaKind;
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogItem {
    pub id: String,
    pub root_id: String,
    pub owner_username: Option<String>,
    pub relative_path: String,
    pub media_kind: MediaKind,
    pub size_bytes: i64,
    pub modified_ns: i64,
    pub fingerprint: String,
}

#[derive(Clone, Debug)]
pub struct ScannedItem {
    pub id: String,
    pub relative_path: String,
    pub media_kind: MediaKind,
    pub size_bytes: i64,
    pub modified_ns: i64,
    pub fingerprint: String,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ReconcileOutcome {
    pub changed: usize,
    pub removed: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScanSchedule {
    pub interval_minutes: i64,
    pub next_scan_at: i64,
    pub last_scanned_at: Option<i64>,
    pub last_change_at: Option<i64>,
}

pub const INITIAL_SCAN_INTERVAL_MINUTES: i64 = 15;
pub const MAX_SCAN_INTERVAL_MINUTES: i64 = 24 * 60;

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationPlanStatus {
    pub state: String,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MutationPlanSummary {
    pub id: String,
    pub owner_username: String,
    pub state: String,
    pub operation_kind: String,
    pub item_ids: Vec<String>,
    pub action_count: i64,
    pub completed_action_count: i64,
    pub created_at: String,
    pub confirmed_at: Option<String>,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub expires_at: i64,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RetryPlanOutcome {
    Queued,
    NotFound,
    StateConflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AbandonPlanOutcome {
    Rejected,
    NotFound,
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
pub struct DiscardablePreviewAction {
    pub plan_id: String,
    pub ordinal: usize,
    pub action: BrokerAction,
}

pub struct Catalog {
    connection: Connection,
}

fn catalog_item_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CatalogItem> {
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
}

impl Catalog {
    pub fn initialize(path: &Path) -> rusqlite::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(error.to_string()),
                )
            })?;
        }
        let mut connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(std::time::Duration::from_secs(30))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if !(0..=4).contains(&version) {
            return Err(unsupported_schema(version));
        }
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS catalog_items (
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
             ",
        )?;
        loop {
            let schema_version: i64 =
                transaction.pragma_query_value(None, "user_version", |row| row.get(0))?;
            match schema_version {
                0 => create_mutation_schema(&transaction)?,
                1 => migrate_mutation_schema_v1(&transaction)?,
                2 => migrate_playback_positions(&transaction)?,
                3 => migrate_scan_schedule(&transaction)?,
                4 => break,
                version => return Err(unsupported_schema(version)),
            }
        }
        transaction.commit()?;
        Ok(Self { connection })
    }

    /// Open an already initialized catalog without acquiring a schema write lock.
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(std::time::Duration::from_secs(30))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != 4 {
            return Err(unsupported_schema(version));
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
        self.list_items_after(root_id, owner_username, None, limit)
    }

    pub fn list_items_after(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
        after_relative_path: Option<&str>,
        limit: usize,
    ) -> rusqlite::Result<Vec<CatalogItem>> {
        let limit = limit.min(1000) as i64;
        if let Some(after_relative_path) = after_relative_path {
            let mut statement = self.connection.prepare(
                "SELECT id, root_id, owner_username, relative_path, media_kind,
                        size_bytes, modified_ns, fingerprint
                   FROM catalog_items
                  WHERE root_id = ?1
                    AND owner_username IS ?2
                    AND relative_path > ?3
                  ORDER BY relative_path
                  LIMIT ?4",
            )?;
            let rows = statement
                .query_map(
                    rusqlite::params![root_id, owner_username, after_relative_path, limit],
                    catalog_item_from_row,
                )?
                .collect();
            return rows;
        }
        let mut statement = self.connection.prepare(
            "SELECT id, root_id, owner_username, relative_path, media_kind,
                    size_bytes, modified_ns, fingerprint
               FROM catalog_items
              WHERE root_id = ?1
                AND owner_username IS ?2
              ORDER BY relative_path
              LIMIT ?3",
        )?;
        let rows = statement
            .query_map(
                rusqlite::params![root_id, owner_username, limit],
                catalog_item_from_row,
            )?
            .collect();
        rows
    }

    pub fn remove_items(&self, ids: &[String]) -> rusqlite::Result<usize> {
        let mut deleted = 0;
        for id in ids {
            deleted += self
                .connection
                .execute("DELETE FROM catalog_items WHERE id = ?1", [id])?;
        }
        Ok(deleted)
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

    pub fn list_media_in_directory(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
        directory: &str,
    ) -> rusqlite::Result<Vec<CatalogItem>> {
        let prefix = if directory.is_empty() {
            String::new()
        } else {
            format!("{directory}/")
        };
        let mut statement = self.connection.prepare(
            "SELECT id, root_id, owner_username, relative_path, media_kind,
                    size_bytes, modified_ns, fingerprint
               FROM catalog_items
              WHERE root_id = ?1
                AND (owner_username IS ?2 OR owner_username = ?2)
                AND instr(relative_path, ?3) = 1
                AND substr(relative_path, length(?3) + 1) NOT LIKE '%/%'
                AND media_kind != 'artwork'
                AND media_kind != 'subtitle'
              ORDER BY relative_path",
        )?;
        let rows = statement
            .query_map(rusqlite::params![root_id, owner_username, prefix], |row| {
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

    pub fn list_subtitles_in_directory(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
        directory: &str,
        limit: usize,
    ) -> rusqlite::Result<Vec<CatalogItem>> {
        let prefix = if directory.is_empty() {
            String::new()
        } else {
            format!("{directory}/")
        };
        let mut statement = self.connection.prepare(
            "SELECT id, root_id, owner_username, relative_path, media_kind,
                    size_bytes, modified_ns, fingerprint
               FROM catalog_items
              WHERE root_id = ?1
                AND (owner_username IS ?2 OR owner_username = ?2)
                AND media_kind = 'subtitle'
                AND instr(relative_path, ?3) = 1
                AND substr(relative_path, length(?3) + 1) NOT LIKE '%/%'
              ORDER BY relative_path
              LIMIT ?4",
        )?;
        let rows = statement
            .query_map(
                rusqlite::params![root_id, owner_username, prefix, limit as i64],
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

    pub fn get_playback_position(
        &self,
        item_id: &str,
        username: &str,
    ) -> rusqlite::Result<Option<f64>> {
        self.connection
            .query_row(
                "SELECT position_seconds FROM playback_positions
                  WHERE item_id = ?1 AND username = ?2",
                rusqlite::params![item_id, username],
                |row| row.get(0),
            )
            .optional()
            .map(|opt| opt.flatten())
    }

    pub fn save_playback_position(
        &self,
        item_id: &str,
        username: &str,
        position_seconds: f64,
    ) -> rusqlite::Result<()> {
        self.connection.execute(
            r#"INSERT INTO playback_positions (item_id, username, position_seconds)
               VALUES (?1, ?2, ?3)
               ON CONFLICT(item_id, username) DO UPDATE SET
                 position_seconds = excluded.position_seconds,
                 updated_at = CURRENT_TIMESTAMP"#,
            rusqlite::params![item_id, username, position_seconds],
        )?;
        Ok(())
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

    /// Returns the persisted adaptive scan schedule for a root, if it has one.
    pub fn scan_schedule(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
    ) -> rusqlite::Result<Option<ScanSchedule>> {
        self.connection
            .query_row(
                "SELECT interval_minutes, next_scan_at, last_scanned_at, last_change_at
                   FROM catalog_scan_schedule
                  WHERE root_id = ?1 AND owner_username = ?2",
                rusqlite::params![root_id, owner_username.unwrap_or_default()],
                |row| {
                    Ok(ScanSchedule {
                        interval_minutes: row.get(0)?,
                        next_scan_at: row.get(1)?,
                        last_scanned_at: row.get(2)?,
                        last_change_at: row.get(3)?,
                    })
                },
            )
            .optional()
    }

    /// A root with no schedule has never been scanned and is due immediately.
    pub fn scan_is_due(
        &self,
        root_id: &str,
        owner_username: Option<&str>,
        now: i64,
    ) -> rusqlite::Result<bool> {
        Ok(self
            .scan_schedule(root_id, owner_username)?
            .map(|schedule| schedule.next_scan_at <= now)
            .unwrap_or(true))
    }

    /// Records a scan result and advances the adaptive backoff for this root. A
    /// pass that found a change resets to the initial interval; a pass with no
    /// change extends toward the maximum interval.
    pub fn record_scan_outcome(
        &mut self,
        root_id: &str,
        owner_username: Option<&str>,
        changed: bool,
        now: i64,
    ) -> rusqlite::Result<ScanSchedule> {
        let previous = self.scan_schedule(root_id, owner_username)?;
        let current_interval = previous
            .as_ref()
            .map(|schedule| schedule.interval_minutes)
            .unwrap_or(INITIAL_SCAN_INTERVAL_MINUTES);
        let interval_minutes = next_scan_interval_minutes(current_interval, changed);
        let last_change_at = if changed {
            Some(now)
        } else {
            previous
                .as_ref()
                .and_then(|schedule| schedule.last_change_at)
        };
        let schedule = ScanSchedule {
            interval_minutes,
            next_scan_at: now.saturating_add(interval_minutes * 60),
            last_scanned_at: Some(now),
            last_change_at,
        };
        self.connection.execute(
            "INSERT INTO catalog_scan_schedule
               (root_id, owner_username, interval_minutes, next_scan_at,
                last_scanned_at, last_change_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(root_id, owner_username) DO UPDATE SET
               interval_minutes = excluded.interval_minutes,
               next_scan_at = excluded.next_scan_at,
               last_scanned_at = excluded.last_scanned_at,
               last_change_at = excluded.last_change_at",
            rusqlite::params![
                root_id,
                owner_username.unwrap_or_default(),
                schedule.interval_minutes,
                schedule.next_scan_at,
                schedule.last_scanned_at,
                schedule.last_change_at,
            ],
        )?;
        Ok(schedule)
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
    ) -> rusqlite::Result<ReconcileOutcome> {
        // Acquire the write reservation before reading the existing rows. A
        // deferred transaction can read alongside another writer in WAL mode,
        // then fail immediately with SQLITE_BUSY when it tries to upgrade;
        // BEGIN IMMEDIATE lets the configured busy timeout wait at the start.
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = {
            let mut statement = transaction.prepare(
                "SELECT id, fingerprint FROM catalog_items
                  WHERE root_id = ?1
                    AND (owner_username IS ?2 OR owner_username = ?2)",
            )?;
            let rows = statement.query_map(rusqlite::params![root_id, owner_username], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<rusqlite::Result<std::collections::HashMap<_, _>>>()?
        };
        let scanned_ids = items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<std::collections::BTreeSet<_>>();

        let mut changed = 0usize;
        for item in items {
            if existing.get(&item.id).map(String::as_str) != Some(item.fingerprint.as_str()) {
                changed += 1;
            }
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

        let removed_ids = existing
            .keys()
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
        Ok(ReconcileOutcome {
            changed,
            removed: removed_ids.len(),
        })
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

    /// Claim one pending action from a plan that will never execute (an expired
    /// preview or one the editor abandoned) so its private staging file can be
    /// discarded. Overdue previews are marked expired first.
    pub fn claim_discardable_preview_action(
        &mut self,
        now: i64,
    ) -> rusqlite::Result<Option<DiscardablePreviewAction>> {
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
                  WHERE plan.state IN ('expired', 'rejected') AND action.state = 'pending'
                  ORDER BY plan.expires_at, plan.created_at, plan.id, action.ordinal
                  LIMIT 1",
                [],
                |row| {
                    let ordinal = row.get::<_, i64>(1)?;
                    let json = row.get::<_, String>(2)?;
                    Ok(DiscardablePreviewAction {
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

    pub fn complete_discarded_preview_action(
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
                   WHERE id = ?1 AND state IN ('expired', 'rejected')
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
        let changed = transaction.execute(
            "UPDATE mutation_plans
                SET state = 'running', started_at = COALESCE(started_at, CURRENT_TIMESTAMP)
              WHERE id = ?1 AND state IN ('queued', 'running')",
            [&id],
        )?;
        if changed == 0 {
            transaction.commit()?;
            return Ok(None);
        }
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

    pub fn mutation_plan_status_for_owner(
        &self,
        plan_id: &str,
        owner_username: &str,
    ) -> rusqlite::Result<Option<MutationPlanStatus>> {
        self.connection
            .query_row(
                "SELECT state, error FROM mutation_plans WHERE id = ?1 AND owner_username = ?2",
                rusqlite::params![plan_id, owner_username],
                |row| {
                    Ok(MutationPlanStatus {
                        state: row.get(0)?,
                        error: row.get(1)?,
                    })
                },
            )
            .optional()
    }

    /// List mutation plans newest first. `owner_username` scopes the result to
    /// one identity; pass `None` for the editor-wide view.
    pub fn list_mutation_plans(
        &self,
        owner_username: Option<&str>,
        limit: usize,
    ) -> rusqlite::Result<Vec<MutationPlanSummary>> {
        let limit = limit.clamp(1, 200) as i64;
        let mut statement = self.connection.prepare(
            "SELECT plan.id, plan.owner_username, plan.state, plan.request_json,
                    plan.created_at, plan.confirmed_at, plan.started_at, plan.finished_at,
                    plan.expires_at, plan.error,
                    (SELECT count(*) FROM mutation_actions AS action
                      WHERE action.plan_id = plan.id),
                    (SELECT count(*) FROM mutation_actions AS action
                      WHERE action.plan_id = plan.id AND action.state = 'completed')
               FROM mutation_plans AS plan
              WHERE (?1 IS NULL OR plan.owner_username = ?1)
              ORDER BY plan.created_at DESC, plan.id DESC
              LIMIT ?2",
        )?;
        let rows = statement.query_map(rusqlite::params![owner_username, limit], |row| {
            let request_json: String = row.get(3)?;
            let (operation_kind, item_ids) = plan_request_summary(&request_json);
            Ok(MutationPlanSummary {
                id: row.get(0)?,
                owner_username: row.get(1)?,
                state: row.get(2)?,
                operation_kind,
                item_ids,
                action_count: row.get(10)?,
                completed_action_count: row.get(11)?,
                created_at: row.get(4)?,
                confirmed_at: row.get(5)?,
                started_at: row.get(6)?,
                finished_at: row.get(7)?,
                expires_at: row.get(8)?,
                error: row.get(9)?,
            })
        })?;
        rows.collect()
    }

    /// Re-queue a failed plan so the broker resumes its incomplete actions.
    pub fn retry_mutation_plan(
        &mut self,
        plan_id: &str,
        owner_username: &str,
    ) -> rusqlite::Result<RetryPlanOutcome> {
        let changed = self.connection.execute(
            "UPDATE mutation_plans
                SET state = 'queued', error = NULL, finished_at = NULL
              WHERE id = ?1 AND owner_username = ?2 AND state = 'failed'",
            rusqlite::params![plan_id, owner_username],
        )?;
        if changed == 1 {
            return Ok(RetryPlanOutcome::Queued);
        }
        match self.mutation_plan_status_for_owner(plan_id, owner_username)? {
            Some(_) => Ok(RetryPlanOutcome::StateConflict),
            None => Ok(RetryPlanOutcome::NotFound),
        }
    }

    /// Cancel a plan that has not started executing. Pending staging files are
    /// discarded by the broker's preview cleanup.
    pub fn abandon_mutation_plan(
        &mut self,
        plan_id: &str,
        owner_username: &str,
    ) -> rusqlite::Result<AbandonPlanOutcome> {
        let changed = self.connection.execute(
            "UPDATE mutation_plans
                SET state = 'rejected', finished_at = CURRENT_TIMESTAMP
              WHERE id = ?1 AND owner_username = ?2 AND state IN ('previewed', 'queued')",
            rusqlite::params![plan_id, owner_username],
        )?;
        if changed == 1 {
            return Ok(AbandonPlanOutcome::Rejected);
        }
        match self.mutation_plan_status_for_owner(plan_id, owner_username)? {
            Some(_) => Ok(AbandonPlanOutcome::StateConflict),
            None => Ok(AbandonPlanOutcome::NotFound),
        }
    }
}

/// Extract the operator-facing operation kind and affected item IDs from a
/// stored plan request without exposing the raw request payload.
fn plan_request_summary(request_json: &str) -> (String, Vec<String>) {
    let value: serde_json::Value = match serde_json::from_str(request_json) {
        Ok(value) => value,
        Err(_) => return ("unknown".to_string(), Vec::new()),
    };
    let kind = value
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            value
                .pointer("/operation/kind")
                .and_then(serde_json::Value::as_str)
        })
        .unwrap_or("unknown")
        .to_string();
    let mut item_ids: Vec<String> = value
        .get("itemIds")
        .and_then(serde_json::Value::as_array)
        .map(|ids| {
            ids.iter()
                .filter_map(|id| id.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    if item_ids.is_empty() {
        if let Some(item_id) = value.get("itemId").and_then(serde_json::Value::as_str) {
            item_ids.push(item_id.to_string());
        }
    }
    (kind, item_ids)
}

fn create_mutation_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE mutation_plans (
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
         PRAGMA user_version = 2;",
    )
}

fn migrate_mutation_schema_v1(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "ALTER TABLE mutation_plans RENAME TO mutation_plans_v1;
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
         PRAGMA user_version = 2;",
    )
}

fn migrate_playback_positions(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS playback_positions (
           item_id TEXT NOT NULL,
           username TEXT NOT NULL,
           position_seconds REAL NOT NULL,
           updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
           PRIMARY KEY(item_id, username)
         ) WITHOUT ROWID;
         PRAGMA user_version = 3;",
    )
}

fn json_to_sql_error(error: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn migrate_scan_schedule(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS catalog_scan_schedule (
           root_id TEXT NOT NULL,
           owner_username TEXT NOT NULL DEFAULT '',
           interval_minutes INTEGER NOT NULL DEFAULT 15,
           next_scan_at INTEGER NOT NULL DEFAULT 0,
           last_scanned_at INTEGER,
           last_change_at INTEGER,
           PRIMARY KEY(root_id, owner_username)
         ) WITHOUT ROWID;
         PRAGMA user_version = 4;",
    )
}

/// The adaptive polling ladder: 15/30/45/60 minutes, then hourly steps up to a
/// 24-hour ceiling. Any detected change resets the root to the first interval.
fn next_scan_interval_minutes(current: i64, changed: bool) -> i64 {
    if changed {
        return INITIAL_SCAN_INTERVAL_MINUTES;
    }
    let current = current.max(INITIAL_SCAN_INTERVAL_MINUTES);
    if current < 60 {
        (current + 15).min(60)
    } else {
        (current + 60).min(MAX_SCAN_INTERVAL_MINUTES)
    }
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

fn unsupported_schema(version: i64) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_SCHEMA), Some(format!("unsupported Media Manager schema version {version}; initialize the catalog before opening it")))
}
