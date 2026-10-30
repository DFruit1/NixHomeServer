//! Risk basis: credential-bearing browser state must never cross owners or
//! survive into a later unprofiled capture. All cookies/storage here are synthetic.
mod common;
use browsertrix_downloader::{database::Database, model::JobStatus, profiles, worker};
#[tokio::test]
#[ignore = "requires WEB_ARCHIVES_PODMAN/WEB_ARCHIVES_IMAGE for isolated synthetic profile browsers"]
async fn synthetic_profiles_are_owner_bound_fresh_and_rechecked_at_execution() {
    let podman = std::env::var("WEB_ARCHIVES_PODMAN").unwrap();
    let image = std::env::var("WEB_ARCHIVES_IMAGE").unwrap();
    let temp = tempfile::tempdir().unwrap();
    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut config = common::config(temp.path());
    config.crawler_image = image.clone();
    config.podman_bin = fixtures.join("profile-capture-wrapper.py");
    unsafe {
        std::env::set_var("WEB_ARCHIVES_BASE_PODMAN", &podman);
    }
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    for owner in ["alice", "bob"] {
        let status = tokio::process::Command::new(&podman)
            .args([
                "run",
                "--rm",
                "--network=none",
                "--shm-size=1g",
                "--cap-add=SYS_ADMIN",
                "--security-opt=seccomp=unconfined",
                "--pid=host",
                "--uts=host",
                "--entrypoint=node",
                "-v",
            ])
            .arg(format!("{}:/profile-fixtures", temp.path().display()))
            .arg("-v")
            .arg(format!("{}:/archive-test-fixtures:ro", fixtures.display()))
            .arg(&image)
            .args(["/archive-test-fixtures/create-profile.mjs", owner])
            .status()
            .await
            .unwrap();
        assert!(status.success(), "synthetic profile preparation");
        let id = format!("profile-{owner}");
        let inbox = format!("inbox-{owner}");
        std::fs::copy(
            temp.path().join(format!("{owner}.tar.gz")),
            config.inbox_root.join(&inbox),
        )
        .unwrap();
        db.put_record("profile",&id,owner,&serde_json::json!({"id":id,"name":format!("Synthetic {owner}"),"available":false,"revoked":false})).unwrap();
        profiles::accept(&config, &db, &id, &inbox, owner).unwrap();
        assert!(profiles::checked_profile(
            &config,
            &db,
            &id,
            if owner == "alice" { "bob" } else { "alice" }
        )
        .is_err());
    }
    for (index, owner) in ["alice", "bob", "alice"].iter().enumerate() {
        let mut request = common::request();
        request.url = "http://example.com:18800/".into();
        request.page_limit = 1;
        request.time_limit_minutes = 1;
        request.options.behaviors = vec![];
        request.options.behavior_timeout_seconds = 5;
        if index < 2 {
            request.options.profile_id = Some(format!("profile-{owner}"));
        }
        let id = format!("profile-capture-{index}");
        if index == 0 {
            db.queue_operation(
                &id,
                owner,
                &request,
                browsertrix_downloader::model::Operation::Sample { target_pages: 30 },
            )
            .unwrap();
        } else {
            db.create_job(&id, owner, &request).unwrap();
        }
        let job = db.claim_next_queued_job().unwrap().unwrap();
        worker::process_job(&config, &db, &job).await.unwrap();
        let completed = db.job(&id).unwrap().unwrap();
        eprintln!(
            "Synthetic capture {index}: status={:?}, transferred={}B",
            completed.status, completed.runtime.bytes_downloaded
        );
        let a = db
            .archive_for_user(completed.runtime.archive_id.as_ref().unwrap(), owner)
            .unwrap()
            .unwrap();
        let path = browsertrix_downloader::custody::root(&config, &a).join(&a.archive_file);
        let mut zip = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
        let mut native_pages = String::new();
        use std::io::Read;
        zip.by_name("pages/pages.jsonl")
            .unwrap()
            .read_to_string(&mut native_pages)
            .unwrap();
        let text = native_pages
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter_map(|v| v["text"].as_str().map(str::to_owned))
            .collect::<Vec<_>>()
            .join("\n");
        eprintln!("Synthetic rendered baseline {index}: {text}");
        assert_eq!(completed.status, JobStatus::Completed);
        if index == 0 {
            let estimate = completed
                .runtime
                .estimate
                .as_ref()
                .expect("actual browser sampling persists measured forecast");
            assert!(estimate.measured);
            assert_eq!(estimate.discovered_pages, 30);
            assert!(estimate.expected_bytes > a.archive_bytes);
        }
        if index < 2 {
            assert_eq!(a.visibility, "private");
            assert!(text.contains(&format!("synthetic-owner={owner}")));
            assert!(text.contains(&format!("storage={owner}")));
            assert!(!text.contains(if *owner == "alice" {
                "storage=bob"
            } else {
                "storage=alice"
            }));
        } else {
            assert!(!text.contains("synthetic-owner="));
            assert!(text.contains("storage=null"));
        }
        assert!(!config.checkpoints_root.join(&id).exists());
    }
    for (index, reason) in ["revoked", "expired"].iter().enumerate() {
        let mut metadata = db
            .record("profile", "profile-alice", "alice")
            .unwrap()
            .unwrap();
        if *reason == "revoked" {
            metadata["revoked"] = serde_json::json!(true);
        } else {
            metadata["revoked"] = serde_json::json!(false);
            metadata["expiresAt"] = serde_json::json!("2000-01-01T00:00:00Z");
        }
        db.put_record("profile", "profile-alice", "alice", &metadata)
            .unwrap();
        let mut request = common::request();
        request.options.profile_id = Some("profile-alice".into());
        let id = format!("rejected-profile-{index}");
        db.create_job(&id, "alice", &request).unwrap();
        let job = db.claim_next_queued_job().unwrap().unwrap();
        assert!(worker::process_job(&config, &db, &job)
            .await
            .unwrap_err()
            .contains(reason));
        assert!(!config.checkpoints_root.join(id).exists());
    }
}
