use browsertrix_downloader::{
    database::Database,
    model::{CrawlScope, CreateJobRequest, JobProgress, JobStatus},
};

fn request() -> CreateJobRequest {
    CreateJobRequest {
        url: "https://example.com/".to_owned(),
        scope: CrawlScope::Page,
        page_limit: 5,
        time_limit_minutes: 2,
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
    assert_eq!(job.status, JobStatus::Failed);
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
