//! Risk basis: durable library routes must retain ownership after history removal,
//! and neither inventory, replay, profile nor queued writer routes may cross users.
mod common;
use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
    Router,
};
use browsertrix_downloader::{
    database::Database,
    http::{router, AppState},
    library,
    queue::{JobQueue, Resolver},
};
use serde_json::{json, Value};
use tower::ServiceExt;
fn req(method: &str, path: &str, owner: &str, body: Value) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("host", "archives.example.test")
        .header("x-forwarded-preferred-username", owner);
    if method != "GET" {
        builder = builder
            .header("origin", "https://archives.example.test")
            .header("content-type", "application/json");
    }
    builder
        .body(if method == "GET" {
            Body::empty()
        } else {
            Body::from(body.to_string())
        })
        .unwrap()
}
async fn call(
    app: &Router,
    method: &str,
    path: &str,
    owner: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(req(method, path, owner, body))
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
#[tokio::test]
async fn durable_library_routes_use_summaries_and_owner_bound_writer_jobs() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    let state = AppState {
        config: config.clone(),
        database: db.clone(),
        queue: JobQueue::new(
            db.clone(),
            Resolver::new(|_| async { Ok(vec!["93.184.216.34".parse().unwrap()]) }),
        ),
    };
    let app = router(state);
    let fixture = temp.path().join("fixture.wacz");
    common::fixture(&fixture, "Durable library");
    let raw = std::fs::read(&fixture).unwrap();
    let import = Request::builder()
        .method("POST")
        .uri("/api/archives/import?filename=fixture.wacz")
        .header("host", "archives.example.test")
        .header("origin", "https://archives.example.test")
        .header("x-forwarded-preferred-username", "alice")
        .header("content-type", "application/wacz+zip")
        .body(Body::from(raw.clone()))
        .unwrap();
    let response = app.clone().oneshot(import).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let job = db.claim_next_queued_job().unwrap().unwrap();
    library::execute(&config, &db, &job).unwrap();
    // API/worker restarts must not remigrate an expanded private import as a
    // second legacy shared capture merely because its job ID differs.
    Database::open(&config.database_path).unwrap();
    let retained = db.archives("alice", &Default::default()).unwrap();
    assert_eq!(retained.total, 1);
    assert_eq!(retained.items[0].visibility, "private");
    let (status, list) = call(
        &app,
        "GET",
        "/api/archives?offset=0&limit=1",
        "alice",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list["total"], 1);
    let id = list["items"][0]["id"].as_str().unwrap();
    assert!(list["items"][0].get("request").is_none());
    assert!(list["items"][0].get("report").is_none());
    assert_eq!(
        call(&app, "GET", "/api/archives", "bob", json!({})).await.1["total"],
        0
    );
    for suffix in [
        "",
        "/pages",
        "/resources",
        "/replay.json",
        "/preview?url=https%3A%2F%2Fexample.com%2F",
        "/reader",
    ] {
        assert_eq!(
            call(
                &app,
                "GET",
                &format!("/api/archives/{id}{suffix}"),
                "bob",
                json!({})
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    let base = format!("/api/archives/{id}");
    assert_eq!(call(&app,"PATCH",&base,"alice",json!({"title":"Retained title","tags":["proof"],"favorite":true,"cleanRules":[{"selector":".ad","action":"hide"}]})).await.0,StatusCode::OK);
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/archives?tag=proof&favorite=true",
            "alice",
            json!({})
        )
        .await
        .1["total"],
        1
    );
    assert_eq!(
        call(
            &app,
            "GET",
            &format!("{base}/pages?q=Durable"),
            "alice",
            json!({})
        )
        .await
        .1["total"],
        1
    );
    let replay = call(
        &app,
        "GET",
        &format!("{base}/replay.json"),
        "alice",
        json!({}),
    )
    .await
    .1;
    assert!(replay["resources"][0]["path"]
        .as_str()
        .unwrap()
        .ends_with("/wacz"));
    assert_eq!(
        call(&app, "DELETE", "/api/jobs", "alice", json!({}))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    let response = app
        .clone()
        .oneshot(req("GET", &format!("{base}/wacz"), "alice", json!({})))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap()
            .as_ref(),
        raw
    );
    let verify = call(
        &app,
        "POST",
        &format!("{base}/verify"),
        "alice",
        json!({"mode":"fixity"}),
    )
    .await;
    assert_eq!(verify.0, StatusCode::OK);
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let checked = call(&app, "GET", &base, "alice", json!({})).await.1;
    assert_eq!(checked["verification"]["valid"], true);
    assert!(checked["verification"]["checks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["name"] == "offline-browser-replay" && c["status"] == "not-run"));
    let preview = app
        .clone()
        .oneshot(req(
            "GET",
            &format!("{base}/preview?url=https%3A%2F%2Fexample.com%2F"),
            "alice",
            json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(preview.status(), StatusCode::OK);
    assert!(preview.headers()["content-security-policy"]
        .to_str()
        .unwrap()
        .contains("sandbox allow-scripts"));
    let preview = String::from_utf8(
        to_bytes(preview.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(!preview.contains("https://leak.invalid/"));
    assert_eq!(
        call(&app, "DELETE", &base, "alice", json!({})).await.0,
        StatusCode::OK
    );
    assert_eq!(
        call(&app, "GET", "/api/archives", "alice", json!({}))
            .await
            .1["total"],
        0
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/archives?trashed=true",
            "alice",
            json!({})
        )
        .await
        .1["total"],
        1
    );
    assert_eq!(
        call(&app, "POST", &format!("{base}/restore"), "alice", json!({}))
            .await
            .0,
        StatusCode::OK
    );
}

// Risk basis: concurrent worker dispatch must not multiply an opt-in capture's
// storage/network budget or load another owner's frozen private recipe.
#[tokio::test]
async fn opt_in_schedules_dispatch_atomically_with_owner_bound_recipes() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    let app = router(AppState {
        config,
        database: db.clone(),
        queue: JobQueue::new(
            db.clone(),
            Resolver::new(|_| async { Ok(vec!["93.184.216.34".parse().unwrap()]) }),
        ),
    });
    let recipe = call(
        &app,
        "POST",
        "/api/recipes",
        "alice",
        json!({"name":"Synthetic recipe","request":common::request()}),
    )
    .await;
    assert_eq!(recipe.0, StatusCode::OK);
    let recipe_id = recipe.1["id"].as_str().unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            &format!("/api/recipes/{recipe_id}"),
            "bob",
            json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/schedules",
            "bob",
            json!({"recipeId":recipe_id,"enabled":true})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let schedule = call(
        &app,
        "POST",
        "/api/schedules",
        "alice",
        json!({"recipeId":recipe_id,"intervalMinutes":60}),
    )
    .await;
    assert_eq!(schedule.0, StatusCode::OK);
    assert_eq!(schedule.1["enabled"], false);
    let schedule_id = schedule.1["id"].as_str().unwrap();
    db.patch_record(
        "schedule",
        schedule_id,
        "alice",
        &json!({"nextRunAt":"2000-01-01T00:00:00Z"}),
    )
    .unwrap();
    assert_eq!(db.dispatch_due_schedules().unwrap(), 0);
    assert_eq!(
        call(
            &app,
            "PATCH",
            &format!("/api/schedules/{schedule_id}"),
            "alice",
            json!({"enabled":true})
        )
        .await
        .0,
        StatusCode::OK
    );
    let threads: Vec<_> = (0..2)
        .map(|_| {
            let db = db.clone();
            std::thread::spawn(move || db.dispatch_due_schedules().unwrap())
        })
        .collect();
    assert_eq!(
        threads
            .into_iter()
            .map(|t| t.join().unwrap())
            .sum::<usize>(),
        1
    );
    assert_eq!(db.list_jobs("alice", 100).unwrap().len(), 1);
    assert!(db.list_jobs("bob", 100).unwrap().is_empty());
    let due = db
        .record("schedule", schedule_id, "alice")
        .unwrap()
        .unwrap();
    let job = db.job(due["lastJobId"].as_str().unwrap()).unwrap().unwrap();
    let expected: browsertrix_downloader::model::CreateJobRequest =
        serde_json::from_value(recipe.1["request"].clone()).unwrap();
    assert_eq!(job.request, expected);
    assert_eq!(
        call(
            &app,
            "PATCH",
            &format!("/api/schedules/{schedule_id}"),
            "alice",
            json!({"enabled":false})
        )
        .await
        .0,
        StatusCode::OK
    );
    let after = db
        .record("schedule", schedule_id, "alice")
        .unwrap()
        .unwrap();
    assert_eq!(after["lastJobId"], due["lastJobId"]);
    db.patch_record(
        "schedule",
        schedule_id,
        "alice",
        &json!({"nextRunAt":"2000-01-01T00:00:00Z"}),
    )
    .unwrap();
    assert_eq!(db.dispatch_due_schedules().unwrap(), 0);
    let run = call(
        &app,
        "POST",
        &format!("/api/recipes/{recipe_id}/run"),
        "alice",
        json!({}),
    )
    .await;
    // Manual recipe operations are explicit work; disabling a schedule only
    // prevents automatic dispatch. The frozen recipe remains owner scoped.
    assert_eq!(run.0, StatusCode::OK);
    let frozen = db.list_jobs("alice", 100).unwrap();
    assert_eq!(frozen.len(), 2);
    let edited = call(
        &app,
        "PATCH",
        &format!("/api/recipes/{recipe_id}"),
        "alice",
        json!({"name":"Edited recipe"}),
    )
    .await;
    assert_eq!(edited.1["version"], 2);
    assert!(frozen.iter().all(|j| j.request == expected));
}

// Risk basis: slow clients retained amplified reader bodies and concurrent raw
// uploads could exhaust the API allocation before its handler permits helped.
#[tokio::test]
async fn reader_rejects_escaped_amplification_with_explicit_recovery() {
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    std::fs::create_dir_all(&config.inbox_root).unwrap();
    common::fixture_with_page_text(
        &config.inbox_root.join("large"),
        "Native text",
        Some(&"&".repeat(7 * 1024 * 1024 / 4)),
    );
    db.queue_operation(
        "import",
        "alice",
        &common::request(),
        browsertrix_downloader::model::Operation::Import {
            inbox_id: "large".into(),
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let archive = db
        .archives("alice", &Default::default())
        .unwrap()
        .items
        .pop()
        .unwrap();
    common::fixture(&config.inbox_root.join("ordinary"), "Ordinary capture");
    db.queue_operation(
        "ordinary-import",
        "alice",
        &common::request(),
        browsertrix_downloader::model::Operation::Import {
            inbox_id: "ordinary".into(),
        },
    )
    .unwrap();
    library::execute(&config, &db, &db.claim_next_queued_job().unwrap().unwrap()).unwrap();
    let ordinary = db
        .job("ordinary-import")
        .unwrap()
        .unwrap()
        .runtime
        .archive_id
        .unwrap();
    let app = router(AppState {
        config,
        database: db.clone(),
        queue: JobQueue::new(db, Resolver::system()),
    });
    let (status, error) = call(
        &app,
        "GET",
        &format!("/api/archives/{}/reader?format=html", archive.id),
        "alice",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(error.to_string().contains("8 MiB"), "{error}");
    assert!(error.to_string().contains("standalone"), "{error}");
    let response = app
        .oneshot(req(
            "GET",
            &format!("/api/archives/{ordinary}/reader"),
            "alice",
            json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(!to_bytes(response.into_body(), library::API_VIEW_BYTES)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn raw_imports_stream_before_eof_preserve_caps_and_clean_failed_staging() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let temp = tempfile::tempdir().unwrap();
    let config = common::config(temp.path());
    let db = Database::open(&config.database_path).unwrap();
    let app = router(AppState {
        config: config.clone(),
        database: db.clone(),
        queue: JobQueue::new(db.clone(), Resolver::system()),
    });
    let raw = |path: &str, body: Body| {
        Request::builder()
            .method("POST")
            .uri(path)
            .header("host", "archives.example.test")
            .header("origin", "https://archives.example.test")
            .header("x-forwarded-preferred-username", "alice")
            .header("content-type", "application/octet-stream")
            .body(body)
            .unwrap()
    };
    let mut uploads = vec![];
    let mut writers = vec![];
    for _ in 0..4 {
        let (mut writer, reader) = tokio::io::duplex(64 * 1024);
        let body = Body::from_stream(tokio_util::io::ReaderStream::new(reader));
        uploads.push(tokio::spawn(
            app.clone().oneshot(raw("/api/archives/import", body)),
        ));
        writer.write_all(&[42; 64 * 1024]).await.unwrap();
        writers.push(writer);
    }
    // All four must write to disk while their streams are still open. Bytes
    // extraction would wait for EOF here and retain complete bodies in memory.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let count = std::fs::read_dir(&config.inbox_root)
            .ok()
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.metadata().is_ok_and(|m| m.len() > 0))
            .count();
        if count == 4 {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "uploads were buffered before staging"
        );
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    let mut producers = vec![];
    for mut writer in writers {
        producers.push(tokio::spawn(async move {
            tokio::io::copy(
                &mut tokio::io::repeat(42).take(128 * 1024 * 1024 - 64 * 1024),
                &mut writer,
            )
            .await
            .unwrap();
            writer.shutdown().await.unwrap();
        }));
    }
    for producer in producers {
        producer.await.unwrap();
    }
    for upload in uploads {
        assert_eq!(upload.await.unwrap().unwrap().status(), StatusCode::OK);
    }
    for e in std::fs::read_dir(&config.inbox_root).unwrap() {
        assert_eq!(e.unwrap().metadata().unwrap().len(), 128 * 1024 * 1024);
    }
    assert_eq!(db.list_jobs("alice", 100).unwrap().len(), 4);
    // Release the four successful raw fixtures before testing rejection paths.
    for e in std::fs::read_dir(&config.inbox_root).unwrap() {
        std::fs::remove_file(e.unwrap().path()).unwrap();
    }
    for (path, limit) in [
        ("/api/archives/import", 128u64),
        ("/api/profiles/import?name=Synthetic", 32),
    ] {
        let body = Body::from_stream(tokio_util::io::ReaderStream::new(
            tokio::io::repeat(0).take(limit * 1024 * 1024 + 1),
        ));
        let response = app.clone().oneshot(raw(path, body)).await.unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(std::fs::read_dir(&config.inbox_root).unwrap().count(), 0);
    }
    struct InterruptedRead(bool);
    impl tokio::io::AsyncRead for InterruptedRead {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            if self.0 {
                return std::task::Poll::Ready(Err(std::io::Error::other("disconnected fixture")));
            }
            self.0 = true;
            buf.put_slice(b"partial");
            std::task::Poll::Ready(Ok(()))
        }
    }
    let response = app
        .clone()
        .oneshot(raw(
            "/api/archives/import",
            Body::from_stream(tokio_util::io::ReaderStream::new(InterruptedRead(false))),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(std::fs::read_dir(&config.inbox_root).unwrap().count(), 0);
    assert_eq!(db.list_jobs("alice", 100).unwrap().len(), 4);
    if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
        eprintln!(
            "streaming upload observation: {}",
            status
                .lines()
                .find(|s| s.starts_with("VmHWM:"))
                .unwrap_or("RSS unavailable")
        );
    }
}
