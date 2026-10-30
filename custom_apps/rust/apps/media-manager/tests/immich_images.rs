//! These boundary regressions cover the concrete risk of leaking private photos
//! or credentials across users or redirects. They never contact a real Immich.
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderMap, Request, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use media_manager::{
    config::Identity,
    provider_account_http::{provider_account_router, ProviderBrokerState},
    provider_accounts::ProviderAccountStore,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const PHOTO: &str = "10000000-0000-4000-8000-000000000001";
const OLD_TAG: &str = "20000000-0000-4000-8000-000000000001";
const NEW_TAG: &str = "20000000-0000-4000-8000-000000000002";
const ROOT: &str = "/api/v1/provider-lookups/immich/images";

#[derive(Clone, Default)]
struct Fixture {
    calls: Arc<Mutex<Vec<String>>>,
    tagged: Arc<Mutex<bool>>,
    preview_bytes: bool,
}
fn photo(tagged: bool) -> Value {
    let mut tags = vec![json!({"id":OLD_TAG,"value":"Family"})];
    if tagged {
        tags.push(json!({"id":NEW_TAG,"value":"EYE/beach"}));
    }
    json!({"id":PHOTO,"type":"IMAGE","originalFileName":"portrait.jpg","fileCreatedAt":"2026-10-01T10:00:00Z","visibility":"timeline","isTrashed":false,"originalPath":"/private/immich/original.jpg","tags":tags})
}
async fn search(
    State(state): State<Fixture>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    state
        .calls
        .lock()
        .unwrap()
        .push(headers["x-api-key"].to_str().unwrap().to_owned());
    assert_eq!(body["type"], "IMAGE");
    assert_eq!(body["visibility"], "timeline");
    assert_eq!(body["size"], 48);
    Json(json!({"assets":{"items":[photo(false)],"nextPage":"2"}}))
}
async fn asset(State(state): State<Fixture>, headers: HeaderMap) -> Json<Value> {
    assert_eq!(headers["x-api-key"], "fixture-alice");
    state.calls.lock().unwrap().push("asset".into());
    Json(photo(*state.tagged.lock().unwrap()))
}
async fn upsert(
    State(state): State<Fixture>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    assert_eq!(headers["x-api-key"], "fixture-alice");
    assert_eq!(body, json!({"tags":["EYE/beach"]}));
    state.calls.lock().unwrap().push("upsert".into());
    Json(json!([{"id":NEW_TAG,"value":"EYE/beach"}]))
}
async fn attach(State(state): State<Fixture>, Json(body): Json<Value>) -> Json<Value> {
    assert_eq!(body, json!({"assetIds":[PHOTO],"tagIds":[NEW_TAG]}));
    *state.tagged.lock().unwrap() = true;
    Json(json!({"count":1}))
}
async fn redirect(State(state): State<Fixture>) -> Response {
    if state.preview_bytes {
        return (
            [("content-type", "image/png")],
            b"\x89PNG\r\n\x1a\n".to_vec(),
        )
            .into_response();
    }
    (
        StatusCode::FOUND,
        [("location", "https://outside.invalid/collect-key")],
    )
        .into_response()
}
async fn test_app(
    temp: &tempfile::TempDir,
    state: Fixture,
    enabled: bool,
) -> (Router, tokio::task::JoinHandle<()>) {
    let mock = Router::new()
        .route("/api/search/metadata", post(search))
        .route(&format!("/api/assets/{PHOTO}"), get(asset))
        .route(&format!("/api/assets/{PHOTO}/thumbnail"), get(redirect))
        .route("/api/tags", put(upsert))
        .route("/api/tags/assets", put(attach))
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
    for user in ["alice", "bob"] {
        store
            .save(
                &Identity::try_new(user, ["users"]).unwrap(),
                "immich",
                &[("apiKey".into(), format!("fixture-{user}"))].into(),
                1,
            )
            .unwrap();
    }
    let runtime = ProviderBrokerState::new(Arc::new(store))
        .unwrap()
        .with_images(
            &format!("http://{address}/api/"),
            &temp.path().join("eye.sock"),
            "media-manager-editors",
            enabled,
        )
        .unwrap();
    (provider_account_router(runtime), task)
}
fn request(method: &str, uri: &str, user: &str, editor: bool, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("host", "media.test")
        .header("origin", "http://media.test")
        .header("content-type", "application/json")
        .header("x-forwarded-user", user)
        .header(
            "x-forwarded-groups",
            if editor {
                "users,media-manager-editors"
            } else {
                "users"
            },
        )
        .body(if method == "GET" {
            Body::empty()
        } else {
            Body::from(body.to_string())
        })
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
async fn caller_credentials_are_isolated_and_private_paths_are_never_returned() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture.clone(), true).await;
    for user in ["alice", "bob"] {
        let response = app
            .clone()
            .oneshot(request("GET", ROOT, user, false, Value::Null))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["cache-control"], "no-store, max-age=0");
        let body = json_response(response).await;
        assert_eq!(body["nextPage"], 2);
        assert_eq!(body["canTag"], false);
        assert_eq!(body["items"][0]["tags"][0]["value"], "Family");
        assert!(!body.to_string().contains("originalPath"));
        assert!(!body.to_string().contains("fixture-"));
    }
    assert_eq!(
        *fixture.calls.lock().unwrap(),
        ["fixture-alice", "fixture-bob"]
    );
    let response = app
        .oneshot(request("GET", ROOT, "charlie", false, Value::Null))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PRECONDITION_REQUIRED);
    assert_eq!(fixture.calls.lock().unwrap().len(), 2);
    task.abort();
}

#[tokio::test]
async fn adds_tags_through_immich_without_replacing_existing_tags() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture, true).await;
    let response = app
        .oneshot(request(
            "POST",
            &format!("{ROOT}/{PHOTO}/tags"),
            "alice",
            true,
            json!({"tags":["beach"]}),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_response(response).await;
    assert_eq!(body["image"]["tags"].as_array().unwrap().len(), 2);
    assert_eq!(body["image"]["tags"][0]["value"], "Family");
    assert_eq!(body["image"]["tags"][1]["value"], "EYE/beach");
    task.abort();
}

#[tokio::test]
async fn rejects_cross_origin_viewer_and_read_only_tag_writes_before_contacting_immich() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture.clone(), true).await;
    let uri = format!("{ROOT}/{PHOTO}/tags");
    let mut cross = request("POST", &uri, "alice", true, json!({"tags":["beach"]}));
    cross
        .headers_mut()
        .insert("origin", "https://evil.test".parse().unwrap());
    for req in [
        cross,
        request("POST", &uri, "alice", false, json!({"tags":["beach"]})),
    ] {
        assert_eq!(
            app.clone().oneshot(req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    assert!(fixture.calls.lock().unwrap().is_empty());
    task.abort();
    let (app, task) = test_app(&temp, fixture.clone(), false).await;
    assert_eq!(
        app.oneshot(request(
            "POST",
            &uri,
            "alice",
            true,
            json!({"tags":["beach"]})
        ))
        .await
        .unwrap()
        .status(),
        StatusCode::FORBIDDEN
    );
    assert!(fixture.calls.lock().unwrap().is_empty());
    task.abort();
}

#[tokio::test]
async fn never_forwards_credentials_through_a_preview_redirect() {
    let temp = tempfile::tempdir().unwrap();
    let (app, task) = test_app(&temp, Fixture::default(), true).await;
    let response = app
        .oneshot(request(
            "GET",
            &format!("{ROOT}/{PHOTO}/preview"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    assert!(!json_response(response)
        .await
        .to_string()
        .contains("fixture-alice"));
    task.abort();
}

#[tokio::test]
async fn eye_receives_only_preview_bytes_and_never_immich_credentials() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let temp = tempfile::tempdir().unwrap();
    let listener = tokio::net::UnixListener::bind(temp.path().join("eye.sock")).unwrap();
    let eye = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let mut chunk = [0; 4096];
        let (head_end, length) = loop {
            let n = socket.read(&mut chunk).await.unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&chunk[..n]);
            if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                assert!(!headers.contains("api-key"));
                assert!(!headers.contains("authorization"));
                assert!(!headers.contains("cookie"));
                assert!(!headers.contains("fixture-alice"));
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("content-length:")
                            .map(|n| n.trim().parse::<usize>().unwrap())
                    })
                    .unwrap();
                break (end + 4, length);
            }
            assert!(bytes.len() < 16 * 1024);
        };
        while bytes.len() < head_end + length {
            let n = socket.read(&mut chunk).await.unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&chunk[..n]);
        }
        assert_eq!(&bytes[head_end..], b"\x89PNG\r\n\x1a\n");
        let body = json!({"model":"eye@v1.0.0","suggestions":[{"tag":"beach","confidence":0.95}],"scores":{"aesthetic":0.8,"keeper":0.7,"cover":0.9}}).to_string();
        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
    });
    let (app, task) = test_app(
        &temp,
        Fixture {
            preview_bytes: true,
            ..Fixture::default()
        },
        true,
    )
    .await;
    let response = app
        .oneshot(request(
            "POST",
            &format!("{ROOT}/{PHOTO}/analysis"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_response(response).await["analysis"]["suggestions"][0]["tag"],
        "beach"
    );
    eye.await.unwrap();
    task.abort();
}
