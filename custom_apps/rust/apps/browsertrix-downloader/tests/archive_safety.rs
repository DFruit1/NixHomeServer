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
        coverage: vec![browsertrix_downloader::coverage::CoverageRecord {
            url: "https://example.com/excluded".into(),
            kind: "skipped-page".into(),
            reason: "Excluded by frozen recipe".into(),
            status: None,
        }],
    };
    db.put_intent(&intent).unwrap();
    std::fs::write(
        config.archive_root.join(".archive-1.pending"),
        b"interrupted",
    )
    .unwrap();
    assert_eq!(custody::recover(&config, &db).unwrap(), 1);
    assert_eq!(custody::recover(&config, &db).unwrap(), 0);
    assert_eq!(
        db.coverage("archive-1", &ListQuery::default())
            .unwrap()
            .total,
        1
    );
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
        // Re-delivery after the source was removed must not restart inspection,
        // publish another version, or change a completed operation's status.
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
fn profile_revocation_committed_while_import_waits_cannot_be_overwritten() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    common::tar_gz(
        &config.inbox_root.join("synthetic"),
        "Default/Preferences",
        b'0',
    );
    db.put_record(
        "profile",
        "profile-race",
        "alice",
        &serde_json::json!({
            "id":"profile-race", "available":false, "revoked":false, "name":"Before"
        }),
    )
    .unwrap();
    // WAL readers can inspect the old profile while this connection owns the
    // writer. Commit revocation after import has copied its immutable bytes.
    let mut connection = rusqlite::Connection::open(db.path()).unwrap();
    let tx = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    let config2 = config.clone();
    let db2 = db.clone();
    let import = std::thread::spawn(move || {
        profiles::accept(&config2, &db2, "profile-race", "synthetic", "alice")
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !config.profiles_root.join("profile-race.tar.gz").exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "import did not reach private copy"
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    tx.execute("UPDATE owned_records SET document=json_set(document,'$.revoked',json('true'),'$.available',json('false'),'$.name','Revoked') WHERE id='profile-race'", []).unwrap();
    tx.commit().unwrap();
    assert!(import.join().unwrap().unwrap_err().contains("revoked"));
    let metadata = db
        .record("profile", "profile-race", "alice")
        .unwrap()
        .unwrap();
    assert_eq!(metadata["revoked"], true);
    assert_eq!(metadata["available"], false);
    assert_eq!(metadata["name"], "Revoked");
    assert!(profiles::checked_profile(&config, &db, "profile-race", "alice").is_err());
    assert!(profiles::accept(&config, &db, "profile-race", "synthetic", "alice").is_err());
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

/// Risk basis: a file hash pass must never masquerade as browser QA, and replay
/// must not retrieve private/live data through browser or service-worker traffic.
#[test]
#[ignore = "requires WEB_ARCHIVES_FIXTURE and WEB_ARCHIVES_PODMAN for isolated pinned crawler QA"]
fn worker_browser_qa_observes_offline_replay_in_pinned_runtime() {
    let fixture = std::env::var_os("WEB_ARCHIVES_FIXTURE").expect("actual crawler WACZ fixture");
    let podman = std::env::var_os("WEB_ARCHIVES_PODMAN").expect("isolated podman wrapper");
    let temp = tempfile::tempdir().unwrap();
    let mut config = common::config(temp.path());
    config.podman_bin = podman.into();
    config.crawler_image = std::env::var("WEB_ARCHIVES_IMAGE")
        .unwrap_or_else(|_| "docker.io/webrecorder/browsertrix-crawler:1.14.3".into());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    if std::env::var_os("WEB_ARCHIVES_OMIT_FAVICON").is_some() {
        let source = std::path::PathBuf::from(&fixture);
        let report = archive_engine::inspect_archive(&source).unwrap();
        let favicon = report
            .resources
            .iter()
            .find(|r| r.url.ends_with("/favicon.ico") && r.status == 200)
            .expect("positive source has valid captured favicon");
        archive_engine::export_archive(
            &source,
            &config.inbox_root.join("actual"),
            &archive_engine::ExportOptions {
                exclude_urls: vec![favicon.url.clone()],
                ..Default::default()
            },
        )
        .unwrap();
    } else {
        std::fs::copy(fixture, config.inbox_root.join("actual")).unwrap();
    }
    db.queue_operation(
        "import-actual",
        "alice",
        &common::request(),
        Operation::Import {
            inbox_id: "actual".into(),
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let a = db
        .archives("alice", &Default::default())
        .unwrap()
        .items
        .pop()
        .unwrap();
    db.queue_operation(
        "qa-actual",
        "alice",
        &common::request(),
        Operation::Verify {
            archive_id: a.id.clone(),
            sha256: a.sha256.clone(),
            mode: "browser".into(),
            url: if std::env::var_os("WEB_ARCHIVES_QA_ALL").is_some() {
                None
            } else {
                Some(a.url.clone())
            },
            interactions: if std::env::var_os("WEB_ARCHIVES_QA_ALL").is_some() {
                vec![]
            } else {
                vec![
                    browsertrix_downloader::model::Interaction {
                        selector: "#menu-toggle".into(),
                        assertion: "visible".into(),
                        expected: "#menu".into(),
                    },
                    browsertrix_downloader::model::Interaction {
                        selector: "#tab-toggle".into(),
                        assertion: "visible".into(),
                        expected: "#detail".into(),
                    },
                ]
            },
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let a = db.archive_for_user(&a.id, "alice").unwrap().unwrap();
    let checks = a.verification.unwrap().checks;
    eprintln!(
        "Observed QA checks: {}",
        serde_json::to_string(&checks).unwrap()
    );
    if config.checkpoints_root.join("qa-actual/qa.log").exists() {
        eprintln!(
            "QA bounded diagnostics: {}",
            std::fs::read_to_string(config.checkpoints_root.join("qa-actual/qa.log"))
                .unwrap()
                .chars()
                .take(8000)
                .collect::<String>()
        );
    }
    let replay = checks
        .iter()
        .find(|c| c.name == "offline-browser-replay")
        .unwrap();
    assert!(
        matches!(replay.status.as_str(), "pass" | "fail"),
        "{}",
        replay.details
    );
    assert!(checks
        .iter()
        .any(|c| c.name == "screenshot-baseline" && matches!(c.status.as_str(), "pass" | "fail")));
    if std::env::var_os("WEB_ARCHIVES_QA_ALL").is_none() {
        assert!(
            checks
                .iter()
                .any(|c| c.name == "interaction-assertions" && c.status == "pass"),
            "configured clicks must execute offline"
        );
    }
    if let Ok(expected) = std::env::var("WEB_ARCHIVES_EXPECT_RESOURCES") {
        assert!(checks
            .iter()
            .any(|c| c.name == "resource-fidelity" && c.status == expected));
    }
}

/// Demonstrated regression: a changed site with no matching parent payloads must
/// retain and publish its valid original instead of failing a completed capture.
#[test]
fn no_savings_deduplication_publishes_changed_standalone_capture() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.checkpoints_root).unwrap();
    for (index, title) in ["First body", "Changed body"].iter().enumerate() {
        let path = config
            .checkpoints_root
            .join(format!("capture-{index}.wacz"));
        common::fixture(&path, title);
        let mut request = common::request();
        request.options.deduplicate = index > 0;
        let id = format!("changed-{index}");
        db.create_job(&id, "alice", &request).unwrap();
        let job = db.claim_next_queued_job().unwrap().unwrap();
        assert!(db.begin_capture(&job.id, &job.runtime).unwrap());
        db.prepare_publication(&job.id, &job.runtime)
            .unwrap()
            .unwrap();
        library::publish_capture(&config, &db, &job, &path, false, JobStatus::Completed).unwrap();
        assert_eq!(db.job(&id).unwrap().unwrap().status, JobStatus::Completed);
    }
    let items = db.archives("alice", &Default::default()).unwrap().items;
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|a| a.report.warnings.iter().any(|w| w.contains("zero savings"))));
    assert_ne!(items[0].sha256, items[1].sha256);
    assert!(items.iter().all(|a| a.dependencies.is_empty()));
}

/// Risk basis: corruption must replace an old successful fixity receipt with a
/// persisted failure; a failed worker alone would leave misleading green state.
#[test]
fn corrupted_payload_records_failed_fixity_without_changing_catalogue_identity() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    common::fixture(&config.inbox_root.join("fixity"), "Original");
    db.queue_operation(
        "import-fixity",
        "alice",
        &common::request(),
        Operation::Import {
            inbox_id: "fixity".into(),
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let a = db
        .archives("alice", &Default::default())
        .unwrap()
        .items
        .pop()
        .unwrap();
    std::fs::write(
        config.private_archive_root.join(&a.archive_file),
        b"corrupt",
    )
    .unwrap();
    db.queue_operation(
        "verify-fixity",
        "alice",
        &common::request(),
        Operation::Verify {
            archive_id: a.id.clone(),
            sha256: a.sha256.clone(),
            mode: "fixity".into(),
            url: None,
            interactions: vec![],
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let updated = db.archive_for_user(&a.id, "alice").unwrap().unwrap();
    assert!(!updated.verification.unwrap().valid);
    assert_eq!(updated.sha256, a.sha256);
}

/// Actual fidelity regressions showed forecasts must include assets and dynamic
/// requests; HTML compressed spans alone can dangerously understate disk budget.
#[test]
#[ignore = "requires WEB_ARCHIVES_FIXTURE pointing to a real multi-page crawler capture"]
fn measured_stored_forecast_accounts_for_assets_and_unattributed_overhead() {
    let path = std::env::var_os("WEB_ARCHIVES_FIXTURE").unwrap();
    let report = archive_engine::inspect_archive(std::path::Path::new(&path)).unwrap();
    let samples = library::page_samples(&report);
    assert!(!samples.is_empty());
    for (sample, page) in samples.iter().zip(&report.pages) {
        assert!(sample.bytes >= page.bytes);
        let distinct = sample.resource_digests.values().sum::<u64>();
        assert!(
            sample.bytes >= distinct,
            "shared assets must also be in the page total"
        );
    }
    let bounded = library::stored_estimate(&report, report.pages.len() as u32);
    let expanded = library::stored_estimate(&report, 30);
    eprintln!("Actual measured package={}B resources={} pages={}; bounded forecast={}; 30-page forecast={}",report.archive_bytes,report.resources.len(),report.pages.len(),serde_json::to_string(&bounded).unwrap(),serde_json::to_string(&expanded).unwrap());
    assert!(bounded.measured);
    assert!(bounded.marginal_page_bytes > 0);
    assert!(
        bounded.lower_bytes <= report.archive_bytes && bounded.upper_bytes >= report.archive_bytes
    );
    assert!(
        bounded.expected_bytes >= report.archive_bytes / 2
            && bounded.expected_bytes < report.archive_bytes * 2
    );
    assert!(expanded.expected_bytes > bounded.expected_bytes);
    assert!(expanded.warnings.iter().any(|w| w.contains("attribution")));
}

// Risk basis: accepted cancellation during file inspection formerly published a
// new archive anyway. Cover both orders at the execution and recovery boundaries.
#[test]
fn file_operations_atomically_reject_execution_after_accepted_cancel() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    for (index, operation) in [
        Operation::Import {
            inbox_id: "not-inspected".into(),
        },
        Operation::Export {
            archive_id: "not-read".into(),
            sha256: "0".repeat(64),
            options: Default::default(),
        },
        Operation::ProfileImport {
            profile_id: "not-activated".into(),
            inbox_id: "not-read".into(),
        },
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("cancel-first-{index}");
        db.queue_operation(&id, "alice", &common::request(), operation)
            .unwrap();
        let job = db.claim_next_queued_job().unwrap().unwrap();
        assert!(db.request_cancel(&id).unwrap());
        library::execute(&config, &db, &job).unwrap();
        library::execute(&config, &db, &job).unwrap();
        assert_eq!(db.job(&id).unwrap().unwrap().status, JobStatus::Cancelled);
        assert!(!config.checkpoints_root.join(&id).exists());
    }
    db.queue_operation(
        "execution-first",
        "alice",
        &common::request(),
        Operation::Import {
            inbox_id: "frozen".into(),
        },
    )
    .unwrap();
    let job = db.claim_next_queued_job().unwrap().unwrap();
    assert!(db.begin_file_operation(&job.id, "alice").unwrap());
    assert_eq!(
        db.job(&job.id).unwrap().unwrap().status,
        JobStatus::Packaging
    );
    assert!(
        !db.request_cancel(&job.id).unwrap(),
        "packaging explicitly rejects cancellation"
    );
    assert!(
        !db.begin_file_operation(&job.id, "alice").unwrap(),
        "duplicate execution cannot enter twice"
    );
    assert_eq!(db.archives("alice", &Default::default()).unwrap().total, 0);
}

#[test]
fn publication_recovery_serializes_against_cancel_and_retains_legacy_sources() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.checkpoints_root).unwrap();
    for cancel_first in [true, false] {
        let id = if cancel_first {
            "cancel-first"
        } else {
            "recovery-first"
        };
        let input = config.checkpoints_root.join(format!("{id}.wacz"));
        common::fixture(&input, id);
        let report = archive_engine::inspect_archive(&input).unwrap();
        let mut archive = Archive::new(id.into(), "alice".into(), None, &report);
        archive.archive_file = format!("{id}.wacz");
        archive.visibility = "private".into();
        let intent = PublicationIntent {
            archive: archive.clone(),
            report,
            source: input.to_string_lossy().into_owned(),
            job_id: Some(id.into()),
            final_status: "completed".into(),
            coverage: vec![],
        };
        db.queue_operation(
            id,
            "alice",
            &common::request(),
            Operation::Import {
                inbox_id: "legacy".into(),
            },
        )
        .unwrap();
        db.claim_next_queued_job().unwrap().unwrap();
        db.set_status(id, JobStatus::Running, None).unwrap();
        // Reconstruct the exact pre-fix durable state: old imports persisted an
        // intent without first freezing cancellation in packaging.
        let connection = rusqlite::Connection::open(db.path()).unwrap();
        connection
            .execute(
                "INSERT INTO publication_intents(id,document) VALUES(?1,?2)",
                rusqlite::params![id, serde_json::to_string(&intent).unwrap()],
            )
            .unwrap();
        if cancel_first {
            assert!(db.request_cancel(id).unwrap());
            assert!(!db.admit_pending_publication(&intent).unwrap());
            assert!(db.put_intent(&intent).is_err());
            assert_eq!(custody::recover(&config, &db).unwrap(), 0);
            db.set_status(id, JobStatus::Completed, None).unwrap();
            assert_eq!(db.job(id).unwrap().unwrap().status, JobStatus::Cancelled);
            assert!(db.archive_for_user(id, "alice").unwrap().is_none());
            assert!(!config
                .private_archive_root
                .join(&archive.archive_file)
                .exists());
        } else {
            assert!(db.admit_pending_publication(&intent).unwrap());
            assert!(!db.request_cancel(id).unwrap());
            assert_eq!(custody::recover(&config, &db).unwrap(), 1);
            assert_eq!(db.job(id).unwrap().unwrap().status, JobStatus::Completed);
            assert_eq!(
                custody::sha256(&config.private_archive_root.join(&archive.archive_file)).unwrap(),
                archive.sha256
            );
            assert_eq!(custody::recover(&config, &db).unwrap(), 0);
        }
        assert_eq!(
            custody::sha256(&input).unwrap(),
            archive.sha256,
            "source custody survives either ordering"
        );
    }
}
