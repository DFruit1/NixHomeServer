//! Risk basis: native page-limit overflow is absent from the checkpoint queue.
//! Extending a partial capture must preserve original bytes and actually resume
//! those scoped pages instead of silently claiming an empty restart succeeded.
mod common;
use browsertrix_downloader::{
    custody,
    database::Database,
    model::{CrawlScope, JobStatus, ResumeOptions},
    worker,
};
#[tokio::test]
#[ignore = "requires WEB_ARCHIVES_BASE_PODMAN/WEB_ARCHIVES_IMAGE and WEB_ARCHIVES_FIXTURE_MODE=site"]
async fn pinned_crawler_resumes_native_checkpoint_with_explicit_page_extension() {
    assert_eq!(std::env::var("WEB_ARCHIVES_FIXTURE_MODE").unwrap(), "site");
    let temp = tempfile::tempdir().unwrap();
    let mut config = common::config(temp.path());
    config.podman_bin = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/profile-capture-wrapper.py");
    config.crawler_image = std::env::var("WEB_ARCHIVES_IMAGE").unwrap();
    let db = Database::open(&config.database_path).unwrap();
    let mut request = common::request();
    request.url = "http://example.com:18800/".into();
    request.scope = CrawlScope::Host;
    request.options.depth = 3;
    request.page_limit = 1;
    request.time_limit_minutes = 1;
    request.options.behaviors = vec!["autoscroll".into()];
    request.options.behavior_timeout_seconds = 5;
    db.create_job("actual-resume", "alice", &request).unwrap();
    worker::process_job(&config, &db, &db.claim_next_queued_job().unwrap().unwrap())
        .await
        .unwrap();
    let partial = db.job("actual-resume").unwrap().unwrap();
    assert_eq!(partial.status, JobStatus::Partial);
    assert_eq!(partial.runtime.stop_reason.as_deref(), Some("page-limit"));
    assert!(partial.runtime.can_resume);
    let original = db
        .archive_for_user(partial.runtime.archive_id.as_ref().unwrap(), "alice")
        .unwrap()
        .unwrap();
    assert_eq!(original.page_count, 1);
    assert!(db
        .resume("actual-resume", "alice", &Default::default())
        .is_err());
    db.resume(
        "actual-resume",
        "alice",
        &ResumeOptions {
            additional_pages: 2,
            ..Default::default()
        },
    )
    .unwrap();
    worker::process_job(&config, &db, &db.claim_next_queued_job().unwrap().unwrap())
        .await
        .unwrap();
    let completed = db.job("actual-resume").unwrap().unwrap();
    eprintln!(
        "Actual native resume receipt: status={:?} stop={:?} progress={:?} cumulativeSeconds={}",
        completed.status,
        completed.runtime.stop_reason,
        completed.progress,
        completed.runtime.runtime_seconds
    );
    assert_eq!(completed.status, JobStatus::Completed);
    assert_eq!(completed.runtime.attempt, 2);
    assert_eq!(completed.request.time_limit_minutes, 1);
    let extended = db
        .archive_for_user(completed.runtime.archive_id.as_ref().unwrap(), "alice")
        .unwrap()
        .unwrap();
    assert_eq!(extended.page_count, 3);
    assert_eq!(extended.parent_id.as_deref(), Some(original.id.as_str()));
    assert_eq!(
        custody::sha256(&config.archive_root.join(original.archive_file)).unwrap(),
        original.sha256
    );
    assert!(!config.checkpoints_root.join("actual-resume").exists());
}
