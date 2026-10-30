//! Offline rollback aid. The expanded source remains authoritative and untouched.
//! No active work, private material, dependent captures, events or credentials are
//! copied into the legacy database. Keep the current Nix privacy boundary even
//! when using an older binary with this separately selected history database.
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::OpenOptions,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub exported: u64,
    pub parked: u64,
    pub reasons: BTreeMap<String, u64>,
}
impl Receipt {
    fn park(&mut self, reason: &str) {
        self.parked += 1;
        *self.reasons.entry(reason.into()).or_default() += 1;
    }
}

/// Destination must be new, in an existing private, caller-owned directory.
/// The source is opened read-only and all reads share one SQLite snapshot.
pub fn export(source: &Path, destination: &Path) -> Result<Receipt, String> {
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or("destination requires an explicit private parent directory")?;
    let canonical_parent = parent.canonicalize().map_err(|e| e.to_string())?;
    let absolute_parent = if parent.is_absolute() {
        parent.to_owned()
    } else {
        std::env::current_dir()
            .map_err(|e| e.to_string())?
            .join(parent)
    };
    if canonical_parent != absolute_parent {
        return Err(
            "destination parent must be canonical, without symlinks or dot segments".into(),
        );
    }
    let metadata = canonical_parent.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
    {
        return Err("destination parent must be caller-owned and not group/world writable".into());
    }
    let input = Connection::open_with_flags(
        source,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| e.to_string())?;
    input
        .busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    input
        .execute_batch("PRAGMA query_only=ON; BEGIN;")
        .map_err(|e| e.to_string())?;
    let has_catalog: bool = input
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='archives')",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    let has_runtime = input
        .prepare("PRAGMA table_info(jobs)")
        .and_then(|mut q| {
            q.query_map([], |r| r.get::<_, String>(1))?
                .collect::<rusqlite::Result<Vec<_>>>()
        })
        .map_err(|e| e.to_string())?
        .iter()
        .any(|s| s == "runtime_json");
    // Exclusive creation also rejects existing files, hard links and symlinks.
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(destination)
        .map_err(|e| e.to_string())?;
    let mut output = Connection::open_with_flags(
        destination,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| e.to_string())?;
    output.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY,applied_at TEXT NOT NULL);
        CREATE TABLE jobs(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,created_by TEXT NOT NULL,status TEXT NOT NULL,request_json TEXT NOT NULL,progress_json TEXT,archive_file TEXT,archive_bytes INTEGER,error TEXT);
        CREATE INDEX jobs_status_created_at_idx ON jobs(status,created_at);
        CREATE INDEX jobs_created_by_created_at_idx ON jobs(created_by,created_at);
        CREATE TABLE job_events(id INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,created_at TEXT NOT NULL,event_type TEXT NOT NULL,message TEXT,data_json TEXT);
        CREATE INDEX job_events_job_id_created_at_idx ON job_events(job_id,created_at);
        INSERT INTO schema_migrations VALUES(1,strftime('%Y-%m-%dT%H:%M:%fZ','now'));").map_err(|e| e.to_string())?;
    let tx = output.transaction().map_err(|e| e.to_string())?;
    let mut receipt = Receipt::default();
    let mut query = input.prepare(&format!("SELECT id,created_at,updated_at,created_by,status,request_json,archive_file,archive_bytes,{} FROM jobs ORDER BY id", if has_runtime { "runtime_json" } else { "'{}'" })).map_err(|e| e.to_string())?;
    let mut rows = query.query([]).map_err(|e| e.to_string())?;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let id: String = row.get(0).map_err(|e| e.to_string())?;
        let status: String = row.get(4).map_err(|e| e.to_string())?;
        if status != "completed" {
            receipt.park("non-completed-work");
            continue;
        }
        let request: Value =
            serde_json::from_str(&row.get::<_, String>(5).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        let runtime: Value =
            serde_json::from_str(&row.get::<_, String>(8).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if request
            .pointer("/options/profileId")
            .is_some_and(|v| !v.is_null())
        {
            receipt.park("profile-material");
            continue;
        }
        if !matches!(request["scope"].as_str(), Some("page" | "prefix" | "host"))
            || runtime
                .pointer("/operation/kind")
                .and_then(Value::as_str)
                .is_some_and(|kind| kind != "capture")
        {
            receipt.park("incompatible-request");
            continue;
        }
        let owner: String = row.get(3).map_err(|e| e.to_string())?;
        let file_name: Option<String> = row.get(6).map_err(|e| e.to_string())?;
        let Some(file_name) = file_name.filter(|f| safe_name(f)) else {
            receipt.park("missing-or-unsafe-payload");
            continue;
        };
        if has_catalog {
            let archive_id = runtime["archiveId"].as_str().unwrap_or(&id);
            let document: Option<String> = input
                .query_row(
                    "SELECT document FROM archives WHERE id=?1 AND owner=?2",
                    params![archive_id, owner],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            let Some(document) = document else {
                receipt.park("missing-owner-custody");
                continue;
            };
            let archive: Value = serde_json::from_str(&document).map_err(|e| e.to_string())?;
            // Parent lineage cannot be silently downgraded, even if a malformed
            // descendant has lost its original profile request metadata.
            if archive["visibility"] != "shared"
                || archive["trashed"] != false
                || archive["archiveFile"] != file_name
                || archive["createdBy"] != owner
                || archive["parentId"].as_str().is_some()
                || !archive["dependencies"]
                    .as_array()
                    .is_some_and(Vec::is_empty)
                || archive
                    .pointer("/request/options/profileId")
                    .is_some_and(|v| !v.is_null())
            {
                receipt.park("private-dependent-or-derived-custody");
                continue;
            }
        } else if has_runtime {
            // Expanded jobs without the catalogue have lost privacy evidence.
            receipt.park("missing-owner-custody");
            continue;
        }
        let legacy = json!({"url":request["url"],"scope":request["scope"],"pageLimit":request["pageLimit"],"timeLimitMinutes":request["timeLimitMinutes"],"collection":request["collection"]});
        // Parse through the exact old field types before committing any row.
        let _: LegacyRequest = serde_json::from_value(legacy.clone()).map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO jobs(id,created_at,updated_at,created_by,status,request_json,archive_file,archive_bytes) VALUES(?1,?2,?3,?4,'completed',?5,?6,?7)", params![id,row.get::<_,String>(1).map_err(|e|e.to_string())?,row.get::<_,String>(2).map_err(|e|e.to_string())?,owner,legacy.to_string(),file_name,row.get::<_,Option<i64>>(7).map_err(|e|e.to_string())?]).map_err(|e| e.to_string())?;
        receipt.exported += 1;
    }
    tx.commit().map_err(|e| e.to_string())?;
    output.close().map_err(|(_, e)| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::File::open(&canonical_parent)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(receipt)
}
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.ends_with(".wacz")
        && PathBuf::from(name).components().count() == 1
        && !name.contains(['/', '\\'])
        && !name.chars().any(char::is_control)
}
#[derive(serde::Deserialize)]
#[allow(dead_code)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyRequest {
    url: String,
    scope: LegacyScope,
    page_limit: u32,
    time_limit_minutes: u32,
    collection: Option<String>,
}
#[derive(serde::Deserialize)]
#[serde(rename_all = "lowercase")]
enum LegacyScope {
    Page,
    Prefix,
    Host,
}
