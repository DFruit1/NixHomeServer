use browsertrix_downloader::{
    config::AppConfig,
    database::Database,
    model::{CrawlScope, CreateJobRequest, JobStatus},
    worker::process_job,
};
use std::os::unix::fs::PermissionsExt;

#[tokio::test]
async fn worker_turns_a_claimed_job_into_a_shared_wacz_archive() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(temp.path());
    std::fs::create_dir_all(&config.archive_root).expect("archive root");
    std::fs::create_dir_all(&config.crawls_root).expect("crawls root");
    config.archive_uid = unsafe { libc::geteuid() };
    config.archive_gid = unsafe { libc::getegid() };
    let fake_podman = temp.path().join("fake-podman");
    std::fs::write(
        &fake_podman,
        r#"#!/bin/sh
set -eu
volume=''
collection=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -v) volume="$2"; shift 2 ;;
    --collection) collection="$2"; shift 2 ;;
    *) shift ;;
  esac
done
crawl_root="${volume%:/crawls}"
mkdir -p "$crawl_root/collections/$collection"
printf 'test-wacz' >"$crawl_root/collections/$collection/$collection.wacz"
printf '%s\n' '{"stats":{"done":1,"queued":0,"failed":0}}'
"#,
    )
    .expect("fake podman");
    let mut permissions = std::fs::metadata(&fake_podman)
        .expect("script metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&fake_podman, permissions).expect("script permissions");
    config.podman_bin = fake_podman;

    let database = Database::open(&config.database_path).expect("database");
    database
        .create_job(
            "job-1",
            "alice",
            &CreateJobRequest {
                url: "https://example.com/".to_owned(),
                scope: CrawlScope::Page,
                page_limit: 5,
                time_limit_minutes: 2,
            },
        )
        .expect("job");
    let job = database
        .claim_next_queued_job()
        .expect("claim")
        .expect("queued job");

    process_job(&config, &database, &job)
        .await
        .expect("worker job");

    let completed = database
        .job("job-1")
        .expect("job lookup")
        .expect("completed job");
    assert_eq!(completed.status, JobStatus::Completed);
    assert_eq!(completed.progress.expect("progress").pages_done, 1);
    let archive_file = completed.archive_file.expect("archive file");
    assert_eq!(
        std::fs::read(config.archive_root.join(archive_file)).expect("archive payload"),
        b"test-wacz"
    );
    assert!(!config.crawls_root.join("job-1").exists());
}
