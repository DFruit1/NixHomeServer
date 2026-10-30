mod common;
use browsertrix_downloader::{database::Database, model::JobStatus, worker::process_job};
#[tokio::test]
async fn worker_turns_a_claimed_job_into_a_shared_wacz_archive() {
    let temp = tempfile::tempdir().unwrap();
    let mut config = common::config(temp.path());
    let fixture = temp.path().join("fixture.wacz");
    common::fixture(&fixture, "Actual WACZ fixture");
    config.podman_bin = common::fake_podman(temp.path(), &fixture, false);
    let database = Database::open(&config.database_path).unwrap();
    database
        .create_job("job-1", "alice", &common::request())
        .unwrap();
    let job = database.claim_next_queued_job().unwrap().unwrap();
    process_job(&config, &database, &job).await.unwrap();
    let completed = database.job("job-1").unwrap().unwrap();
    assert_eq!(completed.status, JobStatus::Completed);
    assert_eq!(completed.progress.unwrap().pages_done, 1);
    let archive_file = completed.archive_file.unwrap();
    assert_eq!(
        std::fs::read(config.archive_root.join(archive_file)).unwrap(),
        std::fs::read(&fixture).unwrap()
    );
    assert!(!config.checkpoints_root.join("job-1").exists());
    let archive_id = completed.runtime.archive_id.unwrap();
    assert_eq!(database.clear_history("alice").unwrap(), 1);
    let archived = database
        .archive_for_user(&archive_id, "alice")
        .unwrap()
        .unwrap();
    assert!(config.archive_root.join(archived.archive_file).exists());
    assert!(database
        .archive_for_user(&archive_id, "bob")
        .unwrap()
        .is_none());
}
#[tokio::test]
async fn exhausted_partial_retains_checkpoint_and_immutable_snapshot_for_extended_resume() {
    let temp = tempfile::tempdir().unwrap();
    let mut config = common::config(temp.path());
    let fixture = temp.path().join("fixture.wacz");
    common::fixture(&fixture, "Partial snapshot");
    config.podman_bin = common::fake_podman(temp.path(), &fixture, true);
    let db = Database::open(&config.database_path).unwrap();
    let mut request = common::request();
    request.page_limit = 1;
    db.create_job("partial-1", "alice", &request).unwrap();
    let job = db.claim_next_queued_job().unwrap().unwrap();
    process_job(&config, &db, &job).await.unwrap();
    let partial = db.job("partial-1").unwrap().unwrap();
    assert_eq!(partial.status, JobStatus::Partial);
    assert!(partial.runtime.can_resume);
    let first = db
        .archive_for_user(partial.runtime.archive_id.as_ref().unwrap(), "alice")
        .unwrap()
        .unwrap();
    assert!(db
        .resume(&job.id, "alice", &Default::default())
        .unwrap_err()
        .contains("exhausted"));
    db.resume(
        &job.id,
        "alice",
        &browsertrix_downloader::model::ResumeOptions {
            additional_pages: 2,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(db.resume(&job.id, "alice", &Default::default()).is_err());
    let resumed = db.claim_next_queued_job().unwrap().unwrap();
    process_job(&config, &db, &resumed).await.unwrap();
    let next = db.job(&job.id).unwrap().unwrap();
    assert_ne!(next.runtime.archive_id, Some(first.id));
    assert_eq!(
        browsertrix_downloader::custody::sha256(&config.archive_root.join(first.archive_file))
            .unwrap(),
        first.sha256
    );
    assert!(
        !std::fs::read_to_string(config.checkpoints_root.join("partial-1/capture.json"))
            .unwrap()
            .contains("overwrite")
    );
}
