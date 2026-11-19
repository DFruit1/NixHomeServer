//! Immich videos are private media: this boundary test proves listing,
//! playback and thumbnails stay behind the caller's own key and never expose
//! upstream paths. It never contacts a real Immich.
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{HeaderMap, Request, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use media_manager::{
    config::Identity,
    provider_account_http::{provider_account_router, ProviderBrokerState},
    provider_accounts::ProviderAccountStore,
};
#[path = "support/api_contract.rs"]
mod api_contract;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const VIDEO: &str = "60000000-0000-4000-8000-000000000001";
const PHOTO: &str = "10000000-0000-4000-8000-000000000001";
const VIDEOS: &str = "/api/v1/provider-lookups/immich/videos";

#[derive(Clone, Default)]
struct Fixture {
    calls: Arc<Mutex<Vec<String>>>,
}

fn asset(id: &str, kind: &str, name: &str) -> Value {
    json!({
        "id": id,
        "type": kind,
        "originalFileName": name,
        "fileCreatedAt": "2026-10-01T10:00:00Z",
        "visibility": "timeline",
        "isTrashed": false,
        "originalPath": "/private/immich/original"
    })
}

async fn search(State(state): State<Fixture>, Json(body): Json<Value>) -> Json<Value> {
    state.calls.lock().unwrap().push("search".into());
    assert_eq!(body["type"], "VIDEO");
    assert_eq!(body["visibility"], "timeline");
    assert_eq!(body["size"], 48);
    assert!(body.get("originalFileName").is_none());
    // A misbehaving upstream must not leak a photo through the video list.
    Json(json!({
        "assets": {
            "items": [
                asset(VIDEO, "VIDEO", "Beach day.mp4"),
                asset(PHOTO, "IMAGE", "portrait.jpg")
            ],
            "nextPage": null
        }
    }))
}

async fn details(State(state): State<Fixture>, Path(id): Path<String>) -> Response {
    state.calls.lock().unwrap().push(format!("asset:{id}"));
    match id.as_str() {
        VIDEO => Json(asset(VIDEO, "VIDEO", "Beach day.mp4")).into_response(),
        PHOTO => Json(asset(PHOTO, "IMAGE", "portrait.jpg")).into_response(),
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn playback(headers: HeaderMap) -> Response {
    assert_eq!(headers["range"], "bytes=0-4");
    (
        StatusCode::PARTIAL_CONTENT,
        [
            ("content-type", "video/mp4"),
            ("content-range", "bytes 0-4/10"),
            ("content-length", "5"),
            ("accept-ranges", "bytes"),
        ],
        b"video".to_vec(),
    )
        .into_response()
}

async fn thumbnail(uri: axum::http::Uri) -> Response {
    assert_eq!(uri.query(), Some("size=thumbnail"));
    (
        [("content-type", "image/png")],
        b"\x89PNG\r\n\x1a\n".to_vec(),
    )
        .into_response()
}

async fn test_app(
    temp: &tempfile::TempDir,
    state: Fixture,
) -> (Router, tokio::task::JoinHandle<()>) {
    let mock = Router::new()
        .route("/api/search/metadata", post(search))
        .route("/api/assets/{id}", get(details))
        .route("/api/assets/{id}/video/playback", get(playback))
        .route("/api/assets/{id}/thumbnail", get(thumbnail))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, mock).await.unwrap();
    });
    let store = ProviderAccountStore::open(
        &temp.path().join("accounts.sqlite3"),
        &temp.path().join("master.key"),
    )
    .unwrap();
    store
        .save(
            &Identity::try_new("alice", ["users"]).unwrap(),
            "immich",
            &[("apiKey".into(), "fixture-alice".into())].into(),
            1,
        )
        .unwrap();
    let runtime = ProviderBrokerState::new(Arc::new(store))
        .unwrap()
        .with_images(
            &format!("http://{address}/api/"),
            &temp.path().join("eye.sock"),
        )
        .unwrap();
    (provider_account_router(runtime), task)
}

fn request(uri: &str, user: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("host", "media.test")
        .header("origin", "http://media.test")
        .header("x-forwarded-user", user)
        .header("x-forwarded-groups", "users")
        .body(Body::empty())
        .unwrap()
}

async fn json_response(response: Response) -> Value {
    serde_json::from_slice(
        &to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap(),
    )
    .unwrap()
}

#[tokio::test]
async fn videos_list_play_and_thumbnail_without_leaking_private_media() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture.clone()).await;

    let response = app.clone().oneshot(request(VIDEOS, "alice")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_response(response).await;
    api_contract::assert_component("ImmichVideoPage", &body);
    assert_eq!(body["items"].as_array().unwrap().len(), 1);
    assert_eq!(body["items"][0]["id"], VIDEO);
    assert_eq!(body["items"][0]["filename"], "Beach day.mp4");
    assert!(!body.to_string().contains("portrait.jpg"));
    assert!(!body.to_string().contains("originalPath"));
    assert!(!body.to_string().contains("fixture-"));

    let playback_request = Request::builder()
        .uri(format!("{VIDEOS}/{VIDEO}/playback"))
        .header("x-forwarded-user", "alice")
        .header("x-forwarded-groups", "users")
        .header("range", "bytes=0-4")
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(playback_request).await.unwrap();
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(response.headers()["content-range"], "bytes 0-4/10");
    assert_eq!(response.headers()["content-type"], "video/mp4");
    assert_eq!(response.headers()["cache-control"], "no-store, max-age=0");
    assert_eq!(
        to_bytes(response.into_body(), 1024).await.unwrap().as_ref(),
        b"video"
    );

    let response = app
        .clone()
        .oneshot(request(&format!("{VIDEOS}/{PHOTO}/playback"), "alice"))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert!(json_response(response)
        .await
        .to_string()
        .contains("immich_video_not_found"));

    let response = app
        .clone()
        .oneshot(request(
            &format!("{VIDEOS}/{VIDEO}/thumbnail?size=160"),
            "alice",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "image/png");
    assert_eq!(response.headers()["cache-control"], "no-store, max-age=0");

    // Charlie has no saved Immich account, so no upstream request is made.
    let before = fixture.calls.lock().unwrap().len();
    let response = app.oneshot(request(VIDEOS, "charlie")).await.unwrap();
    assert_eq!(response.status(), StatusCode::PRECONDITION_REQUIRED);
    assert_eq!(fixture.calls.lock().unwrap().len(), before);
    task.abort();
}
