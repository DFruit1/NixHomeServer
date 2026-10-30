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
    let mut runtime = partial.runtime.clone();
    runtime.runtime_seconds = 115;
    db.set_runtime(&job.id, &runtime).unwrap();
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
            additional_minutes: 1,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(db.resume(&job.id, "alice", &Default::default()).is_err());
    let resumed = db.claim_next_queued_job().unwrap().unwrap();
    assert_eq!(resumed.request.time_limit_minutes, 3);
    process_job(&config, &db, &resumed).await.unwrap();
    let next = db.job(&job.id).unwrap().unwrap();
    assert_eq!(
        std::fs::read_to_string(config.checkpoints_root.join("partial-1/time-limit.txt")).unwrap(),
        "65"
    );
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
    let mut exhausted = next.runtime;
    exhausted.runtime_seconds = 180;
    db.set_runtime(&job.id, &exhausted).unwrap();
    assert!(db
        .resume(&job.id, "alice", &Default::default())
        .unwrap_err()
        .contains("exhausted"));
    db.resume(
        &job.id,
        "alice",
        &browsertrix_downloader::model::ResumeOptions {
            additional_minutes: 1,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        db.job(&job.id).unwrap().unwrap().request.time_limit_minutes,
        4
    );
}

// Risk basis: a discard accepted after a native checkpoint was persisted must
// never resurrect on restart, delete an immutable partial, or lose cleanup custody.
#[tokio::test]
async fn restart_finishes_discard_only_after_stopping_prior_capture() {
    use browsertrix_downloader::{custody, worker};
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().unwrap();
    let mut config = common::config(temp.path());
    let fixture = temp.path().join("fixture.wacz");
    common::fixture(&fixture, "Retained partial");
    config.podman_bin = common::fake_podman(temp.path(), &fixture, true);
    let db = Database::open(&config.database_path).unwrap();
    let mut request = common::request();
    request.page_limit = 1;
    db.create_job("discard-restart", "alice", &request).unwrap();
    let job = db.claim_next_queued_job().unwrap().unwrap();
    process_job(&config, &db, &job).await.unwrap();
    let partial = db.job(&job.id).unwrap().unwrap();
    let archive = db
        .archive_for_user(partial.runtime.archive_id.as_ref().unwrap(), "alice")
        .unwrap()
        .unwrap();
    let checkpoint = config.checkpoints_root.join(&job.id);
    db.resume(
        &job.id,
        "alice",
        &browsertrix_downloader::model::ResumeOptions {
            additional_pages: 1,
            ..Default::default()
        },
    )
    .unwrap();
    db.claim_next_queued_job().unwrap().unwrap();
    assert!(db.request_cancel(&job.id).unwrap());
    let fail = temp.path().join("fail-stop");
    std::fs::write(&fail, "fixture").unwrap();
    let log = temp.path().join("recovery.log");
    let script = temp.path().join("recovery-podman");
    std::fs::write(&script, format!("#!/bin/sh\nset -eu\n[ \"$1\" = rm ]\n[ -d '{}' ]\nprintf '%s\\n' \"$*\" >> '{}'\nif [ -e '{}' ]; then exit 1; fi\n", checkpoint.display(), log.display(), fail.display())).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    config.podman_bin = script;
    assert!(worker::recover_interrupted(&config, &db)
        .await
        .unwrap_err()
        .contains("checkpoint retained"));
    let cancelled = db.job(&job.id).unwrap().unwrap();
    assert_eq!(cancelled.status, JobStatus::Cancelled);
    assert!(!cancelled.runtime.can_resume);
    assert!(checkpoint.exists());
    assert_eq!(
        db.clear_history("alice").unwrap(),
        0,
        "cleanup custody must survive history clearing"
    );
    std::fs::remove_file(fail).unwrap();
    worker::recover_interrupted(&config, &db).await.unwrap();
    assert!(!checkpoint.exists());
    let cancelled = db.job(&job.id).unwrap().unwrap();
    assert_eq!(cancelled.status, JobStatus::Cancelled);
    assert_eq!(cancelled.runtime.control.as_deref(), Some("discard"));
    assert!(!cancelled.runtime.can_resume);
    assert!(cancelled.runtime.resume_config.is_none());
    assert!(db.resume(&job.id, "alice", &Default::default()).is_err());
    // A late checkpoint observer or stale periodic metric write cannot reactivate it.
    db.restore_checkpoint(&job.id, "stale.yaml").unwrap();
    db.set_runtime_preserving_control(&job.id, &partial.runtime)
        .unwrap();
    assert!(!db.job(&job.id).unwrap().unwrap().runtime.can_resume);
    assert_eq!(
        custody::sha256(&config.archive_root.join(&archive.archive_file)).unwrap(),
        archive.sha256
    );
    worker::recover_interrupted(&config, &db).await.unwrap();
    assert_eq!(std::fs::read_to_string(log).unwrap().lines().count(), 2);
    assert_eq!(db.clear_history("alice").unwrap(), 1);
    assert!(db.archive_for_user(&archive.id, "alice").unwrap().is_some());
}
