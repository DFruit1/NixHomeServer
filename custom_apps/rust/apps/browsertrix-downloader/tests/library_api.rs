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
