use browsertrix_downloader::{
    database::Database,
    model::{CrawlScope, CreateJobRequest, JobProgress, JobStatus, Operation},
};

fn request() -> CreateJobRequest {
    CreateJobRequest {
        url: "https://example.com/".to_owned(),
        scope: CrawlScope::Page,
        page_limit: 5,
        time_limit_minutes: 2,
        collection: None,
        options: Default::default(),
    }
}

#[test]
fn jobs_are_isolated_by_user_and_claimed_once() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = Database::open(temp.path().join("jobs.sqlite")).expect("database");
    database
        .create_job("job-1", "alice", &request())
        .expect("alice job");
    database
        .create_job("job-2", "bob", &request())
        .expect("bob job");

    let alice = database.list_jobs("alice", 100).expect("alice jobs");
    assert_eq!(alice.len(), 1);
    assert_eq!(alice[0].id, "job-1");
    assert!(database
        .job_for_user("job-1", "bob")
        .expect("foreign lookup")
        .is_none());

    let claimed = database
        .claim_next_queued_job()
        .expect("claim")
        .expect("queued job");
    assert_eq!(claimed.id, "job-1");
    assert_eq!(claimed.status, JobStatus::Starting);
    let second = database
        .claim_next_queued_job()
        .expect("second claim")
        .expect("bob job");
    assert_eq!(second.id, "job-2");
    assert!(database
        .claim_next_queued_job()
        .expect("empty queue")
        .is_none());
}

#[test]
fn progress_archive_and_terminal_history_are_persisted() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = Database::open(temp.path().join("jobs.sqlite")).expect("database");
    database
        .create_job("job-1", "alice", &request())
        .expect("job");
    database
        .set_progress(
            "job-1",
            Some(&JobProgress {
                pages_done: 3,
                pages_queued: 1,
                pages_failed: 0,
            }),
        )
        .expect("progress");
    database
        .set_archive("job-1", "example.com 2026-08-31.wacz", 12_345)
        .expect("archive");
    database
        .set_status("job-1", JobStatus::Completed, None)
        .expect("completed");

    let job = database.job("job-1").expect("job lookup").expect("job");
    assert_eq!(job.progress.expect("progress").pages_done, 3);
    assert_eq!(
        job.archive_file.as_deref(),
        Some("example.com 2026-08-31.wacz")
    );
    assert_eq!(job.archive_bytes, Some(12_345));

    database.clear_history("alice").expect("clear history");
    assert!(database.job("job-1").expect("job lookup").is_none());
}

#[test]
fn cancellation_duplicates_and_worker_restart_recovery_match_the_api_contract() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = Database::open(temp.path().join("jobs.sqlite")).expect("database");
    database
        .create_job("job-1", "alice", &request())
        .expect("job");
    assert!(database
        .active_duplicate(&request(), "alice")
        .expect("duplicate")
        .is_some());
    assert!(database.request_cancel("job-1").expect("cancel"));
    assert!(!database.request_cancel("job-1").expect("second cancel"));
    assert_eq!(
        database
            .job("job-1")
            .expect("cancelled lookup")
            .expect("cancelled job")
            .status,
        JobStatus::Cancelled
    );

    database
        .create_job(
            "job-2",
            "alice",
            &CreateJobRequest {
                url: "https://example.net/".to_owned(),
                ..request()
            },
        )
        .expect("running job");
    database
        .set_status("job-2", JobStatus::Running, None)
        .expect("running status");
    assert!(database.request_cancel("job-2").expect("running cancel"));
    database
        .create_job(
            "job-3",
            "alice",
            &CreateJobRequest {
                url: "https://example.org/".to_owned(),
                ..request()
            },
        )
        .expect("queued job");
    database
        .mark_worker_interrupted()
        .expect("worker restart recovery");
    let job = database.job("job-2").expect("job lookup").expect("job");
    assert_eq!(job.status, JobStatus::Cancelled);
    assert_eq!(
        job.error.as_deref(),
        Some("interrupted by crawl worker restart")
    );
    assert_eq!(
        database
            .job("job-3")
            .expect("queued lookup")
            .expect("queued job")
            .status,
        JobStatus::Queued
    );
}

// WA-BE005: accepted pause/stop repeatedly stranded file jobs and their durable
// inbox bytes. Exercise admission before/after claiming without making checkpoints.
#[test]
fn file_operations_reject_pause_and_stop_without_stranding_the_queue() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open(temp.path().join("jobs.sqlite")).unwrap();
    for (index, operation) in [
        Operation::Import {
            inbox_id: "inbox".into(),
        },
        Operation::ProfileImport {
            profile_id: "profile".into(),
            inbox_id: "inbox".into(),
        },
        Operation::Export {
            archive_id: "archive".into(),
            sha256: "hash".into(),
            options: Default::default(),
        },
        Operation::Verify {
            archive_id: "archive".into(),
            sha256: "hash".into(),
            mode: "fixity".into(),
            url: None,
            interactions: vec![],
        },
        Operation::Reconcile,
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("file-{index}");
        db.queue_operation(&id, "alice", &request(), operation)
            .unwrap();
        for status in [JobStatus::Queued, JobStatus::Starting] {
            let before = db.job(&id).unwrap().unwrap();
            assert_eq!(before.status, status);
            for action in ["pause", "stop"] {
                let error = db.request_control(&id, "alice", action).unwrap_err();
                assert!(error.contains("not supported"), "{error}");
                assert!(error.contains("cancel"), "{error}");
                let after = db.job(&id).unwrap().unwrap();
                assert_eq!(after.status, status);
                assert_eq!(after.updated_at, before.updated_at);
                assert!(after.runtime.control.is_none());
            }
            if status == JobStatus::Queued {
                assert_eq!(db.claim_next_queued_job().unwrap().unwrap().id, id);
            }
        }
        assert!(db.begin_file_operation(&id, "alice").unwrap());
        for action in ["pause", "stop"] {
            assert!(db.request_control(&id, "alice", action).is_err());
        }
        assert!(!db.request_cancel(&id).unwrap());
    }
}

#[test]
fn native_capture_operations_keep_pause_and_stop_admission() {
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open(temp.path().join("jobs.sqlite")).unwrap();
    for (index, operation) in [
        Operation::Capture,
        Operation::Sample { target_pages: 1 },
        Operation::Repair {
            archive_id: "archive".into(),
            sha256: "hash".into(),
            urls: vec![],
        },
    ]
    .into_iter()
    .enumerate()
    {
        for action in ["pause", "stop"] {
            for status in [JobStatus::Queued, JobStatus::Starting, JobStatus::Running] {
                let id = format!("native-{index}-{action}-{}", status.as_str());
                db.queue_operation(&id, "alice", &request(), operation.clone())
                    .unwrap();
                db.set_status(&id, status.clone(), None).unwrap();
                db.request_control(&id, "alice", action).unwrap();
                let after = db.job(&id).unwrap().unwrap();
                assert_eq!(
                    after.status,
                    if status == JobStatus::Queued {
                        JobStatus::Paused
                    } else {
                        status
                    }
                );
                assert_eq!(after.runtime.control.as_deref(), Some(action));
            }
        }
    }
}

#[test]
fn file_control_rejection_serializes_with_claim_and_packaging() {
    use std::sync::{Arc, Barrier};
    let temp = tempfile::tempdir().unwrap();
    let db = Database::open(temp.path().join("jobs.sqlite")).unwrap();
    for action in ["pause", "stop"] {
        let id = format!("race-{action}");
        db.queue_operation(
            &id,
            "alice",
            &request(),
            Operation::Import {
                inbox_id: "inbox".into(),
            },
        )
        .unwrap();
        for claim in [true, false] {
            let barrier = Arc::new(Barrier::new(2));
            let other_db = db.clone();
            let other_id = id.clone();
            let other_barrier = barrier.clone();
            let worker = std::thread::spawn(move || {
                other_barrier.wait();
                if claim {
                    assert_eq!(
                        other_db.claim_next_queued_job().unwrap().unwrap().id,
                        other_id
                    );
                } else {
                    assert!(other_db.begin_file_operation(&other_id, "alice").unwrap());
                }
            });
            barrier.wait();
            assert!(db.request_control(&id, "alice", action).is_err());
            worker.join().unwrap();
            let after = db.job(&id).unwrap().unwrap();
            assert_eq!(
                after.status,
                if claim {
                    JobStatus::Starting
                } else {
                    JobStatus::Packaging
                }
            );
            assert!(after.runtime.control.is_none());
        }
    }
}
