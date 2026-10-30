//! Risk basis: interrupted publication previously removed the only ownership
//! evidence and scratch copy. Imports/profiles also cross untrusted path and
//! user boundaries. These regressions prevent archive loss and credential leaks.
mod common;
use browsertrix_downloader::{
    archive_engine,
    catalog::{Archive, ListQuery, PublicationIntent},
    custody,
    database::Database,
    library,
    model::{JobStatus, Operation},
    profiles,
};
#[test]
fn publication_intent_recovers_partial_copy_before_history_cleanup() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.checkpoints_root).unwrap();
    std::fs::create_dir_all(&config.archive_root).unwrap();
    let input = config.checkpoints_root.join("capture.wacz");
    common::fixture(&input, "Recovered capture");
    let report = archive_engine::inspect_archive(&input).unwrap();
    let mut a = Archive::new(
        "archive-1".into(),
        "alice".into(),
        Some(common::request()),
        &report,
    );
    a.archive_file = "recovered.wacz".into();
    let intent = PublicationIntent {
        archive: a.clone(),
        report,
        source: input.to_string_lossy().into_owned(),
        job_id: None,
        final_status: "completed".into(),
    };
    db.put_intent(&intent).unwrap();
    std::fs::write(
        config.archive_root.join(".archive-1.pending"),
        b"interrupted",
    )
    .unwrap();
    assert_eq!(custody::recover(&config, &db).unwrap(), 1);
    assert_eq!(custody::recover(&config, &db).unwrap(), 0);
    assert!(input.exists());
    assert_eq!(
        custody::sha256(&config.archive_root.join("recovered.wacz")).unwrap(),
        a.sha256
    );
    assert!(db.archive_for_user("archive-1", "bob").unwrap().is_none());
    assert_eq!(
        db.pages("archive-1", &ListQuery::default()).unwrap().total,
        1
    );
    assert_eq!(
        db.resources("archive-1", &ListQuery::default())
            .unwrap()
            .total,
        1
    );
}
#[test]
fn corrupt_import_is_not_catalogued_and_valid_import_is_idempotent() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    std::fs::write(config.inbox_root.join("bad"), b"test-wacz").unwrap();
    db.queue_operation(
        "import-bad",
        "alice",
        &common::request(),
        Operation::Import {
            inbox_id: "bad".into(),
        },
    )
    .unwrap();
    let job = db.claim_next_queued_job().unwrap().unwrap();
    assert!(library::execute(&config, &db, &job).is_err());
    assert_eq!(
        db.archives("alice", &ListQuery::default()).unwrap().total,
        0
    );
    for (index, inbox) in ["good-1", "good-2"].iter().enumerate() {
        common::fixture(&config.inbox_root.join(inbox), "Owner import");
        let id = format!("import-{index}");
        db.queue_operation(
            &id,
            "alice",
            &common::request(),
            Operation::Import {
                inbox_id: inbox.to_string(),
            },
        )
        .unwrap();
        let job = db.claim_next_queued_job().unwrap().unwrap();
        library::execute(&config, &db, &job).unwrap();
        assert_eq!(db.job(&id).unwrap().unwrap().status, JobStatus::Completed);
    }
    assert_eq!(
        db.archives("alice", &ListQuery::default()).unwrap().total,
        1
    );
    assert_eq!(db.archives("bob", &ListQuery::default()).unwrap().total, 0);
    let a = db
        .archives("alice", &ListQuery::default())
        .unwrap()
        .items
        .pop()
        .unwrap();
    assert_eq!(a.visibility, "private");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(config.private_archive_root.join(a.archive_file))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o640
        );
    }
}
#[test]
fn profile_import_rejects_path_link_and_owner_substitution() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    for (name, kind) in [
        ("../escape", b'0'),
        ("/absolute", b'0'),
        ("Default/Cookies", b'2'),
        ("device", b'3'),
    ] {
        let path = temp.path().join("bad.tar.gz");
        common::tar_gz(&path, name, kind);
        assert!(profiles::validate_tar(&path).is_err(), "{name}");
    }
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    let staged = config.inbox_root.join("synthetic-profile");
    common::tar_gz(&staged, "Default/Preferences", b'0');
    db.put_record("profile","profile-1","alice",&serde_json::json!({"id":"profile-1","name":"Synthetic only","available":false,"revoked":false})).unwrap();
    assert!(profiles::accept(&config, &db, "profile-1", "synthetic-profile", "bob").is_err());
    profiles::accept(&config, &db, "profile-1", "synthetic-profile", "alice").unwrap();
    let accepted = profiles::checked_profile(&config, &db, "profile-1", "alice").unwrap();
    assert!(profiles::checked_profile(&config, &db, "profile-1", "bob").is_err());
    std::fs::write(accepted, b"tampered").unwrap();
    assert!(profiles::checked_profile(&config, &db, "profile-1", "alice").is_err());
}
#[test]
fn missing_or_cross_owner_dependencies_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    let mut a = Archive::new(
        "child".into(),
        "alice".into(),
        Some(common::request()),
        &Default::default(),
    );
    a.dependencies.push("bob-parent".into());
    a.dependency_hashes
        .insert("bob-parent".into(), "0".repeat(64));
    let mut parent = Archive::new(
        "bob-parent".into(),
        "bob".into(),
        Some(common::request()),
        &Default::default(),
    );
    parent.sha256 = "0".repeat(64);
    db.save_archive_metadata(&parent).unwrap();
    assert!(library::authorized_dependencies(&config, &db, &a).is_err());
}
