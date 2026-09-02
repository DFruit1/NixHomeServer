use browsertrix_downloader::{
    database::Database,
    model::{CrawlScope, CurrentUser, JobStatus},
    queue::{JobQueue, Resolver},
    validation::CreateJobInput,
};
use std::net::{IpAddr, Ipv4Addr};

fn user() -> CurrentUser {
    CurrentUser {
        username: "alice".to_owned(),
        email: None,
        groups: vec!["web-archive-users".to_owned()],
    }
}

fn input(url: &str) -> CreateJobInput {
    CreateJobInput {
        url: url.to_owned(),
        scope: Some(CrawlScope::Page),
        page_limit: Some(5),
        time_limit_minutes: Some(2),
        collection: None,
    }
}

fn public_resolver() -> Resolver {
    Resolver::new(|_| async { Ok(vec![IpAddr::V4(Ipv4Addr::new(93, 184, 216, 34))]) })
}

#[tokio::test]
async fn enqueue_rejects_duplicates_and_private_dns_results() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = Database::open(temp.path().join("jobs.sqlite")).expect("database");
    let queue = JobQueue::new(database.clone(), public_resolver());

    let id = queue
        .enqueue(&user(), input("https://example.com/"))
        .await
        .expect("queued job");
    assert!(!id.is_empty());
    let error = queue
        .enqueue(&user(), input("https://example.com/"))
        .await
        .expect_err("duplicate rejected");
    assert!(error.to_string().contains("already being archived"));

    let private_queue = JobQueue::new(
        database,
        Resolver::new(|_| async { Ok(vec![IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10))]) }),
    );
    let error = private_queue
        .enqueue(&user(), input("https://internal.example/"))
        .await
        .expect_err("private destination rejected");
    assert!(error.to_string().contains("private"));
}

#[tokio::test]
async fn cancel_and_retry_preserve_user_ownership() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = Database::open(temp.path().join("jobs.sqlite")).expect("database");
    let queue = JobQueue::new(database.clone(), public_resolver());
    let id = queue
        .enqueue(&user(), input("https://example.com/cancel"))
        .await
        .expect("queued job");

    let bob = CurrentUser {
        username: "bob".to_owned(),
        email: None,
        groups: vec![],
    };
    assert!(queue.cancel(&id, &bob).is_err());
    queue.cancel(&id, &user()).expect("cancel request");
    assert_eq!(
        database.job(&id).expect("job lookup").expect("job").status,
        JobStatus::Cancelled
    );
    let retry_id = queue.retry(&id, &user()).await.expect("retry");
    assert_ne!(retry_id, id);
    assert_eq!(
        database
            .job(&retry_id)
            .expect("retry lookup")
            .expect("retry job")
            .status,
        JobStatus::Queued
    );
}
