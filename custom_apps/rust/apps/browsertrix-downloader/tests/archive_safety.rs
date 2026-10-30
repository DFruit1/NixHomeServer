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
