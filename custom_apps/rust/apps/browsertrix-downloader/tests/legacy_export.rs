//! Risk basis: binary rollback must neither corrupt the expanded database nor
//! disclose private/profile captures through the older shared archive handler.
mod common;
use browsertrix_downloader::{
    catalog::Archive,
    custody,
    database::Database,
    legacy_export,
    model::{CrawlScope, JobRuntime, JobStatus},
};
use std::os::unix::fs::{symlink, PermissionsExt};

#[test]
fn rollback_exports_only_compatible_shared_history_and_preserves_source() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    for (id, kind) in [
        ("shared", "shared"),
        ("private", "private"),
        ("profile", "profile"),
        ("new-scope", "new-scope"),
        ("active", "active"),
        ("partial", "partial"),
        ("derived", "derived"),
        ("dependency", "dependency"),
    ] {
        let mut request = common::request();
        if kind == "new-scope" {
            request.scope = CrawlScope::Domain;
        }
        if kind == "profile" {
            request.options.profile_id = Some("synthetic-only".into());
            request.url = "https://example.com/private-material".into();
        }
        db.create_job(id, "alice", &request).unwrap();
        if kind == "active" {
            continue;
        }
        db.set_status(
            id,
            if kind == "partial" {
                JobStatus::Partial
            } else {
                JobStatus::Completed
            },
            None,
        )
        .unwrap();
        let mut a = Archive::new(
            id.into(),
            "alice".into(),
            Some(request),
            &Default::default(),
        );
        a.visibility = if matches!(kind, "private" | "profile") {
            "private"
        } else {
            "shared"
        }
        .into();
        a.archive_file = format!("{id}.wacz");
        if kind == "derived" {
            a.parent_id = Some("private".into());
        }
        if kind == "dependency" {
            a.dependencies.push("shared".into());
        }
        db.set_archive(id, &a.archive_file, 12).unwrap();
        db.save_archive_metadata(&a).unwrap();
        db.set_runtime(
            id,
            &JobRuntime {
                archive_id: Some(a.id),
                ..Default::default()
            },
        )
        .unwrap();
        db.add_event(
            id,
            "log",
            Some("synthetic sensitive log must stay in source"),
        )
        .unwrap();
    }
    let source = rusqlite::Connection::open(&config.database_path).unwrap();
    source
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
        .unwrap();
    let before = custody::sha256(&config.database_path).unwrap();
    let dest = temp.path().join("legacy.sqlite");
    let receipt = legacy_export::export(&config.database_path, &dest).unwrap();
    assert_eq!(receipt.exported, 1);
    assert_eq!(receipt.parked, 7);
    assert_eq!(custody::sha256(&config.database_path).unwrap(), before);
    assert_eq!(
        std::fs::metadata(&dest).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let legacy = rusqlite::Connection::open(&dest).unwrap();
    let rows: Vec<(String, String, String)> = legacy
        .prepare("SELECT id,status,request_json FROM jobs")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].0, "shared");
    assert_eq!(rows[0].1, "completed");
    assert!(!rows[0].2.contains("options"));
    assert!(!rows[0].2.contains("private"));
    assert_eq!(
        legacy
            .query_row("SELECT count(*) FROM job_events", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(legacy.query_row("SELECT count(*) FROM sqlite_master WHERE name IN ('archives','owned_records','publication_intents')",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    assert!(legacy_export::export(&config.database_path, &dest).is_err());
    let link = temp.path().join("symlink.sqlite");
    symlink(&dest, &link).unwrap();
    assert!(legacy_export::export(&config.database_path, &link).is_err());
    assert_eq!(custody::sha256(&config.database_path).unwrap(), before);
    assert_eq!(db.list_jobs("alice", 100).unwrap().len(), 8);
}
