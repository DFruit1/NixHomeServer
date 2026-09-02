use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use browsertrix_downloader::{
    config::AppConfig,
    database::Database,
    http::{compute_range, router, AppState},
    model::{CrawlScope, CreateJobRequest, JobStatus},
    queue::{JobQueue, Resolver},
};
use serde_json::{json, Value};
use std::net::{IpAddr, Ipv4Addr};
use tower::ServiceExt;

fn test_app(temp: &tempfile::TempDir) -> axum::Router {
    let config = AppConfig::for_test(temp.path());
    std::fs::create_dir_all(&config.frontend_dir).expect("frontend directory");
    std::fs::create_dir_all(&config.replay_dir).expect("replay directory");
    std::fs::create_dir_all(&config.archive_root).expect("archive directory");
    std::fs::write(config.frontend_dir.join("index.html"), "<html>app</html>")
        .expect("client index");
    std::fs::write(config.replay_dir.join("index.html"), "<html>replay</html>")
        .expect("replay index");
    std::fs::write(
        config.replay_dir.join("sw.js"),
        "self.addEventListener('fetch', () => {})",
    )
    .expect("replay service worker");
    let database = Database::open(&config.database_path).expect("database");
    let resolver =
        Resolver::new(|_| async { Ok(vec![IpAddr::V4(Ipv4Addr::new(93, 184, 216, 34))]) });
    router(AppState {
        queue: JobQueue::new(database.clone(), resolver),
        database,
        config,
    })
}

#[tokio::test]
async fn completed_archives_stream_with_defensive_byte_ranges() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let config = AppConfig::for_test(temp.path());
    let database = Database::open(&config.database_path).expect("database");
    let crawl = CreateJobRequest {
        url: "https://example.com/".to_owned(),
        scope: CrawlScope::Page,
        page_limit: 5,
        time_limit_minutes: 2,
        collection: None,
    };
    database
        .create_job("wacz-job", "alice", &crawl)
        .expect("job");
    database
        .set_archive("wacz-job", "example.com 2026-08-31.wacz", 1_024)
        .expect("archive record");
    database
        .set_status("wacz-job", JobStatus::Completed, None)
        .expect("completed");
    std::fs::write(
        config.archive_root.join("example.com 2026-08-31.wacz"),
        vec![7_u8; 1_024],
    )
    .expect("WACZ fixture");

    let full = app
        .clone()
        .oneshot(request("GET", "/api/jobs/wacz-job/wacz", Body::empty()))
        .await
        .expect("full archive");
    assert_eq!(full.status(), StatusCode::OK);
    assert_eq!(full.headers()["accept-ranges"], "bytes");
    assert_eq!(
        to_bytes(full.into_body(), 2_048).await.expect("body").len(),
        1_024
    );

    let mut partial_request = request("GET", "/api/jobs/wacz-job/wacz", Body::empty());
    partial_request
        .headers_mut()
        .insert("range", "bytes=0-99".parse().expect("range"));
    let partial = app
        .clone()
        .oneshot(partial_request)
        .await
        .expect("partial archive");
    assert_eq!(partial.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(partial.headers()["content-range"], "bytes 0-99/1024");
    assert_eq!(
        to_bytes(partial.into_body(), 200)
            .await
            .expect("body")
            .len(),
        100
    );

    let mut invalid_request = request("GET", "/api/jobs/wacz-job/wacz", Body::empty());
    invalid_request
        .headers_mut()
        .insert("range", "bytes=99999-".parse().expect("range"));
    let invalid = app.oneshot(invalid_request).await.expect("invalid range");
    assert_eq!(invalid.status(), StatusCode::RANGE_NOT_SATISFIABLE);
}

#[tokio::test]
async fn replay_assets_and_client_routes_are_served_from_separate_roots() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let replay = app
        .clone()
        .oneshot(request("GET", "/replay/", Body::empty()))
        .await
        .expect("replay response");
    assert!(
        String::from_utf8_lossy(&to_bytes(replay.into_body(), 1_024).await.expect("body"))
            .contains("replay")
    );

    let worker = app
        .clone()
        .oneshot(request("GET", "/replay/sw.js", Body::empty()))
        .await
        .expect("worker response");
    assert_eq!(worker.headers()["service-worker-allowed"], "/replay/");

    let client = app
        .oneshot(request("GET", "/anything/else", Body::empty()))
        .await
        .expect("client fallback");
    assert!(
        String::from_utf8_lossy(&to_bytes(client.into_body(), 1_024).await.expect("body"))
            .contains("app")
    );
}

#[test]
fn byte_ranges_are_computed_defensively() {
    assert_eq!(compute_range(None, 100), None);
    assert_eq!(compute_range(Some("bytes=0-9"), 100), Some((0, 9)));
    assert_eq!(compute_range(Some("bytes=90-"), 100), Some((90, 99)));
    assert_eq!(compute_range(Some("bytes=-10"), 100), Some((90, 99)));
    assert_eq!(compute_range(Some("bytes=100-"), 100), None);
    assert_eq!(compute_range(Some("bytes=5-2"), 100), None);
    assert_eq!(compute_range(Some("nonsense"), 100), None);
}

fn request(method: &str, uri: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("host", "archives.example.test")
        .header("x-auth-request-preferred-username", "alice")
        .header("x-auth-request-groups", "web-archive-users")
        .body(body)
        .expect("request")
}

fn mutation(method: &str, uri: &str, value: Value) -> Request<Body> {
    let mut request = request(method, uri, Body::from(value.to_string()));
    request.headers_mut().insert(
        "content-type",
        "application/json".parse().expect("content type"),
    );
    request.headers_mut().insert(
        "origin",
        "https://archives.example.test".parse().expect("origin"),
    );
    request
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("response body");
    serde_json::from_slice(&bytes).expect("JSON response")
}

#[tokio::test]
async fn health_is_public_but_api_requires_forwarded_identity() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let health = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/healthz")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("health response");
    assert_eq!(health.status(), StatusCode::OK);
    assert_eq!(json_body(health).await, json!({ "ok": true }));

    let anonymous = app
        .oneshot(
            Request::builder()
                .uri("/api/me")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("anonymous response");
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn jobs_follow_the_existing_create_list_cancel_and_user_isolation_contract() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let me = app
        .clone()
        .oneshot(request("GET", "/api/me", Body::empty()))
        .await
        .expect("me response");
    assert_eq!(json_body(me).await["username"], "alice");

    let created = app
        .clone()
        .oneshot(mutation(
            "POST",
            "/api/jobs",
            json!({ "url": "https://example.com/", "scope": "page", "pageLimit": 5, "timeLimitMinutes": 2 }),
        ))
        .await
        .expect("create response");
    assert_eq!(created.status(), StatusCode::CREATED);
    let job_id = json_body(created).await["jobId"]
        .as_str()
        .expect("job id")
        .to_owned();

    let listed = app
        .clone()
        .oneshot(request("GET", "/api/jobs", Body::empty()))
        .await
        .expect("list response");
    let jobs = json_body(listed).await;
    assert_eq!(jobs.as_array().expect("jobs").len(), 1);
    assert_eq!(jobs[0]["id"], job_id);

    let mut stranger = request("GET", &format!("/api/jobs/{job_id}"), Body::empty());
    stranger.headers_mut().insert(
        "x-auth-request-preferred-username",
        "bob".parse().expect("username"),
    );
    let hidden = app
        .clone()
        .oneshot(stranger)
        .await
        .expect("hidden response");
    assert_eq!(hidden.status(), StatusCode::NOT_FOUND);

    let active_delete = app
        .clone()
        .oneshot(mutation(
            "DELETE",
            &format!("/api/jobs/{job_id}"),
            json!({}),
        ))
        .await
        .expect("active delete response");
    assert_eq!(active_delete.status(), StatusCode::BAD_REQUEST);

    let cancelled = app
        .clone()
        .oneshot(mutation(
            "POST",
            &format!("/api/jobs/{job_id}/cancel"),
            json!({}),
        ))
        .await
        .expect("cancel response");
    assert_eq!(cancelled.status(), StatusCode::OK);

    let job = app
        .oneshot(request(
            "GET",
            &format!("/api/jobs/{job_id}"),
            Body::empty(),
        ))
        .await
        .expect("cancelled job response");
    assert_eq!(json_body(job).await["status"], "cancelled");
}

#[tokio::test]
async fn mutations_require_same_origin_json() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let mut evil = mutation(
        "POST",
        "/api/jobs",
        json!({ "url": "https://example.com/" }),
    );
    evil.headers_mut()
        .insert("origin", "https://evil.example".parse().expect("origin"));
    let response = app.clone().oneshot(evil).await.expect("evil response");
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let mut missing_content_type = request(
        "POST",
        "/api/jobs",
        Body::from(json!({ "url": "https://example.com/" }).to_string()),
    );
    missing_content_type.headers_mut().insert(
        "origin",
        "https://archives.example.test".parse().expect("origin"),
    );
    let missing_content_type = app
        .oneshot(missing_content_type)
        .await
        .expect("content type response");
    assert_eq!(
        missing_content_type.status(),
        StatusCode::UNSUPPORTED_MEDIA_TYPE
    );
}
