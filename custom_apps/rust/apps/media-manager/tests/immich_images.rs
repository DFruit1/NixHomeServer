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
#[path = "support/api_contract.rs"]
mod api_contract;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const PHOTO: &str = "10000000-0000-4000-8000-000000000001";
const OLD_TAG: &str = "20000000-0000-4000-8000-000000000001";
const NEW_TAG: &str = "20000000-0000-4000-8000-000000000002";
const ALBUM: &str = "30000000-0000-4000-8000-000000000001";
const ROOT: &str = "/api/v1/provider-lookups/immich/images";

// Automatic keys must remain subject-bound even when a username is reused,
// and removing Photos membership must immediately stop broker access.
#[tokio::test]
async fn managed_immich_never_falls_back_or_crosses_identity_or_group_boundaries() {
    let temp = tempfile::Builder::new()
        .prefix("immich-managed-boundary-")
        .tempdir()
        .unwrap();
    let fixture = Fixture::default();
    let mock = Router::new()
        .route("/api/search/metadata", post(search))
        .with_state(fixture.clone());
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
    let subject = "10000000-0000-4000-8000-000000000010";
    let alice = Identity::try_new_with_subject(subject, "alice", ["immich-users"]).unwrap();
    store
        .save(
            &alice,
            "immich-managed",
            &[("apiKey".into(), "fixture-alice".into())].into(),
            1,
        )
        .unwrap();
    let reused = Identity::try_new_with_subject(
        "10000000-0000-4000-8000-000000000011",
        "alice",
        ["immich-users"],
    )
    .unwrap();
    store
        .save(
            &reused,
            "immich",
            &[("apiKey".into(), "wrong-manual-key".into())].into(),
            1,
        )
        .unwrap();
    let runtime = ProviderBrokerState::new(Arc::new(store))
        .unwrap()
        .with_images(
            &format!("http://{address}/api/"),
            &temp.path().join("eye.sock"),
        )
        .unwrap()
        .with_managed_immich();
    let app = provider_account_router(runtime);
    let managed_request = |who: &str, groups: &str, path: &str| {
        Request::builder()
            .uri(path)
            .header("x-forwarded-user", who)
            .header("x-forwarded-preferred-username", "alice")
            .header("x-forwarded-groups", groups)
            .body(Body::empty())
            .unwrap()
    };
    let response = app
        .clone()
        .oneshot(managed_request(subject, "users,immich-users", ROOT))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(!json_response(response)
        .await
        .to_string()
        .contains("fixture-alice"));
    let response = app
        .clone()
        .oneshot(managed_request(&reused.subject, "users,immich-users", ROOT))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PRECONDITION_REQUIRED);
    let response = app
        .clone()
        .oneshot(managed_request(subject, "users", ROOT))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(fixture.calls.lock().unwrap().as_slice(), ["fixture-alice"]);
    let response = app
        .oneshot(managed_request(
            subject,
            "users,immich-users",
            "/api/v1/provider-accounts",
        ))
        .await
        .unwrap();
    let body = json_response(response).await;
    let provider = body["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "immich")
        .unwrap();
    assert_eq!(provider["canConfigure"], false);
    assert_eq!(provider["credentialFields"], json!([]));
    assert_eq!(provider["account"]["state"], "configured");
    task.abort();
}

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
async fn list_albums(
    State(state): State<Fixture>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Json<Value> {
    assert_eq!(headers["x-api-key"], "fixture-alice");
    let query = uri.query().unwrap_or_default();
    assert!(query.contains("name=Beach") && query.contains("isOwned=true"));
    state.calls.lock().unwrap().push("albums".into());
    Json(json!([]))
}
async fn create_album(
    State(state): State<Fixture>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    assert_eq!(headers["x-api-key"], "fixture-alice");
    assert_eq!(
        body,
        json!({"albumName":"Beach","assetIds":[PHOTO]}),
        "album writes must stay limited to the assessed photo"
    );
    state.calls.lock().unwrap().push("create-album".into());
    Json(json!({"id":ALBUM,"albumName":"Beach"}))
}
async fn add_album_assets(
    State(state): State<Fixture>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    assert_eq!(headers["x-api-key"], "fixture-alice");
    assert_eq!(body, json!({"ids":[PHOTO]}));
    state.calls.lock().unwrap().push("add-album-asset".into());
    Json(json!([{"id":PHOTO,"success":true}]))
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
) -> (Router, tokio::task::JoinHandle<()>) {
    let mock = Router::new()
        .route("/api/search/metadata", post(search))
        .route(&format!("/api/assets/{PHOTO}"), get(asset))
        .route(&format!("/api/assets/{PHOTO}/thumbnail"), get(redirect))
        .route("/api/tags", put(upsert))
        .route("/api/tags/assets", put(attach))
        .route("/api/albums", get(list_albums).post(create_album))
        .route(
            &format!("/api/albums/{ALBUM}/assets"),
            put(add_album_assets),
        )
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
        )
        .unwrap()
        .with_decision_socket(&temp.path().join("d1.sock"))
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
    let (app, task) = test_app(&temp, fixture.clone()).await;
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

// The tag filter used to be resolved in a per-photo correlated subquery, so
// SQLite drove every candidate photo from the tag index and re-scanned all rows
// sharing the tag. On the real 24k-photo library a scores/aesthetic/tag sort
// took 46 s of SQLite time and the browser gave up at 30 s. The filter must stay
// one indexed pass over the account's own photos.
#[tokio::test]
async fn tag_search_stays_bounded_on_a_large_library() {
    use rusqlite::params;
    use std::time::{Duration, Instant};
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture).await;
    // The fixture has no EYE socket, so the analysis itself fails; it still
    // registers the account scope that owns the private index.
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("{ROOT}/{PHOTO}/analysis"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let mut database = rusqlite::Connection::open(temp.path().join("accounts.sqlite3")).unwrap();
    let scope: String = database
        .query_row("SELECT scope FROM image_assets", [], |row| row.get(0))
        .unwrap();
    let analysis = json!({"model":"eye@v1.0.0","suggestions":[],"scores":{"aesthetic":0.5,"keeper":0.5,"cover":0.5}}).to_string();
    let transaction = database.transaction().unwrap();
    for n in 100..10_100_u32 {
        let asset_id = format!("10000000-0000-4000-8000-{n:012}");
        transaction
            .execute(
                "INSERT INTO image_assets(scope,asset_id,filename,captured_at,analysis,aesthetic,keeper,cover,seen)
                 VALUES (?1,?2,?3,?4,?5,0.5,0.5,0.5,1)",
                params![
                    scope,
                    asset_id,
                    format!("IMG_{n}.jpg"),
                    format!("2025-01-{:02}T10:00:00Z", 1 + n % 28),
                    analysis
                ],
            )
            .unwrap();
        transaction
            .execute(
                "INSERT INTO image_tags(scope,asset_id,tag,confidence) VALUES (?1,?2,'common',0.9)",
                params![scope, asset_id],
            )
            .unwrap();
    }
    transaction.commit().unwrap();
    for query in [
        "tags=common&tagMode=all&sort=scores",
        "tags=absent&tagMode=all&sort=scores",
        "tags=common,absent&tagMode=all&sort=tag&sortTag=common",
    ] {
        let started = Instant::now();
        let response = app
            .clone()
            .oneshot(request(
                "GET",
                &format!("{ROOT}/index?page=1&{query}"),
                "alice",
                false,
                Value::Null,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let elapsed = started.elapsed();
        assert!(
            elapsed < Duration::from_millis(1500),
            "{query} took {elapsed:?} over 10k photos and tags"
        );
        let body = json_response(response).await;
        if query.starts_with("tags=common&") {
            assert_eq!(body["nextPage"], 2);
        } else {
            assert_eq!(body["items"], json!([]));
        }
    }
    task.abort();
}

#[tokio::test]
async fn refuses_legacy_tag_writes_for_editors() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture.clone()).await;
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
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(fixture.calls.lock().unwrap().is_empty());
    task.abort();
}

#[tokio::test]
async fn rejects_cross_origin_viewer_and_read_only_tag_writes_before_contacting_immich() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = Fixture::default();
    let (app, task) = test_app(&temp, fixture.clone()).await;
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
    let (app, task) = test_app(&temp, fixture.clone()).await;
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
    let (app, task) = test_app(&temp, Fixture::default()).await;
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
    )
    .await;
    let response = app
        .clone()
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
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("{ROOT}/index?tags=beach&sort=scores&minAesthetic=0.75"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_response(response).await;
    assert_eq!(body["items"][0]["analysis"]["scores"]["aesthetic"], 0.8);
    assert_eq!(body["index"]["analyzed"], 1);
    assert!(!body.to_string().contains("fixture-alice"));
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("{ROOT}/index?tags=beach"),
            "bob",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_response(response).await;
    assert_eq!(body["items"], json!([]));
    assert_eq!(body["index"]["analyzed"], 0);
    let response = app
        .oneshot(request(
            "GET",
            &format!("{ROOT}/{PHOTO}"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_response(response).await["analysis"]["suggestions"][0]["tag"],
        "beach"
    );
    eye.await.unwrap();
    task.abort();
}

// New decision endpoints carry the same catastrophic privacy risk as EYE:
// private pixels, rule text, derived tags and credentials must stay owner-scoped.
#[tokio::test]
async fn decisions_isolate_private_rules_pixels_and_tags_and_fail_without_partial_writes() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let temp = tempfile::tempdir().unwrap();
    let listener = tokio::net::UnixListener::bind(temp.path().join("d1.sock")).unwrap();
    let d1 = tokio::spawn(async move {
        for probability in [0.95, 2.0, 0.95] {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut chunk = [0u8; 8192];
            let (start, length) = loop {
                let n = socket.read(&mut chunk).await.unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.windows(4).position(|b| b == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                    for secret in ["api-key", "authorization", "cookie", "fixture-alice"] {
                        assert!(!headers.contains(secret));
                    }
                    let length = headers
                        .lines()
                        .find_map(|l| {
                            l.strip_prefix("content-length:")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap();
                    break (end + 4, length);
                }
            };
            while bytes.len() < start + length {
                let n = socket.read(&mut chunk).await.unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&chunk[..n]);
            }
            let input: Value = serde_json::from_slice(&bytes[start..start + length]).unwrap();
            assert_eq!(input["questions"]["screen"]["type"], "noul");
            if input.get("images").is_some() {
                assert_eq!(input["images"][0], "data:image/png;base64,iVBORw0KGgo=");
            } else {
                assert!(input["state"]
                    .as_str()
                    .unwrap()
                    .contains("personal UTF-8 file"));
            }
            assert!(!input.to_string().contains("fixture-alice"));
            let body = json!({"answers":{"screen":{"noul":probability},"untouched":{"noul":0.1}}})
                .to_string();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
        }
    });
    let (app, upstream) = test_app(
        &temp,
        Fixture {
            preview_bytes: true,
            ..Fixture::default()
        },
    )
    .await;
    let rules_path = "/api/v1/provider-lookups/immich/decision-rules";
    let rules = json!({"rules":[
        {"id":"screen","question":"Is this a computer screen or code?","yesTag":"to be deleted","noTag":"","automatic":false},
        {"id":"untouched","question":"Is there a dog?","yesTag":"","noTag":"","automatic":false}
    ]});
    let mut cross_origin = request("PUT", rules_path, "alice", false, rules.clone());
    cross_origin
        .headers_mut()
        .insert("origin", "http://outside.invalid".parse().unwrap());
    assert_eq!(
        app.clone().oneshot(cross_origin).await.unwrap().status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        app.clone()
            .oneshot(request("PUT", rules_path, "alice", false, rules))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let bob = json_response(
        app.clone()
            .oneshot(request("GET", rules_path, "bob", false, Value::Null))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(bob["rules"], json!([]));
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("{ROOT}/{PHOTO}/decisions"),
            "alice",
            false,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let result = json_response(response).await;
    assert_eq!(result["results"][1]["answer"], "no");
    assert_eq!(result["results"][1]["tag"], "");
    let tags = result["tags"].as_array().unwrap();
    assert!(tags.contains(&json!("to be deleted")));
    assert_eq!(tags, &vec![json!("to be deleted")]);
    let details = json_response(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("{ROOT}/{PHOTO}"),
                "alice",
                false,
                Value::Null,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(details["image"]["decisionTags"], result["tags"]);
    let bob = json_response(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("{ROOT}/index?tags=to%20be%20deleted"),
                "bob",
                false,
                Value::Null,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(bob["items"], json!([]));
    let search = json_response(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("{ROOT}/index?tags=to%20be%20deleted"),
                "alice",
                false,
                Value::Null,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(search["items"].as_array().unwrap().len(), 1);
    // Malformed probabilities must not apply even one action or timestamp.
    assert_eq!(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("{ROOT}/{PHOTO}/decisions"),
                "alice",
                false,
                Value::Null
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    let after = json_response(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("{ROOT}/{PHOTO}"),
                "alice",
                false,
                Value::Null,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(after["image"]["decisionTags"], result["tags"]);
    let file_path = "/api/v1/provider-lookups/immich/decision-files";
    let file = json!({"name":"notes.txt","content":"cGVyc29uYWwgVVRGLTggZmlsZQ==","image":false});
    let bob = app
        .clone()
        .oneshot(request("POST", file_path, "bob", false, file.clone()))
        .await
        .unwrap();
    assert_eq!(bob.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let uploaded = app
        .oneshot(request("POST", file_path, "alice", false, file))
        .await
        .unwrap();
    assert_eq!(uploaded.status(), StatusCode::OK);
    let uploaded = json_response(uploaded).await;
    assert!(uploaded["target"].as_str().unwrap().starts_with("file:"));
    assert!(uploaded["tags"]
        .as_array()
        .unwrap()
        .contains(&json!("to be deleted")));
    d1.await.unwrap();
    upstream.abort();
}

async fn read_socket_request(socket: &mut tokio::net::UnixStream) -> (String, Vec<u8>) {
    use tokio::io::AsyncReadExt;
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    let (start, length) = loop {
        let n = socket.read(&mut chunk).await.unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
        if let Some(end) = bytes.windows(4).position(|b| b == b"\r\n\r\n") {
            let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
            let length = headers
                .lines()
                .find_map(|line| {
                    line.strip_prefix("content-length:")
                        .map(|value| value.trim().parse::<usize>().unwrap())
                })
                .unwrap();
            break (end + 4, length);
        }
    };
    while bytes.len() < start + length {
        let n = socket.read(&mut chunk).await.unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
    }
    (
        String::from_utf8_lossy(&bytes[..start]).to_lowercase(),
        bytes[start..start + length].to_vec(),
    )
}

async fn write_socket_json(socket: &mut tokio::net::UnixStream, body: &Value) {
    use tokio::io::AsyncWriteExt;
    let body = body.to_string();
    socket
        .write_all(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
}

// Category rules are the only Immich write. This regression pins the narrow
// boundary: one assessed photo, exact album name, no credentials on d1/EYE,
// score-bound skips, and cached album reuse without listing albums again.
#[tokio::test]
async fn category_questions_add_only_the_assessed_photo_to_the_matching_album() {
    let temp = tempfile::tempdir().unwrap();
    let d1_listener = tokio::net::UnixListener::bind(temp.path().join("d1.sock")).unwrap();
    let eye_listener = tokio::net::UnixListener::bind(temp.path().join("eye.sock")).unwrap();
    let fixture = Fixture {
        preview_bytes: true,
        ..Fixture::default()
    };
    let (app, upstream) = test_app(&temp, fixture.clone()).await;

    let eye = tokio::spawn(async move {
        let (mut socket, _) = eye_listener.accept().await.unwrap();
        let (headers, body) = read_socket_request(&mut socket).await;
        assert!(headers.contains("content-type: image/png"));
        assert!(body.starts_with(b"\x89PNG"));
        write_socket_json(
            &mut socket,
            &json!({
                "model":"eye@v1.0.0",
                "suggestions":[{"tag":"beach","confidence":0.9}],
                "scores":{"aesthetic":0.8,"keeper":0.2,"cover":0.4}
            }),
        )
        .await;
    });
    let d1 = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = d1_listener.accept().await.unwrap();
            let (headers, body) = read_socket_request(&mut socket).await;
            for secret in ["api-key", "authorization", "cookie", "fixture-alice"] {
                assert!(!headers.contains(secret));
            }
            let input: Value = serde_json::from_slice(&body).unwrap();
            let questions = input["questions"].as_object().unwrap();
            assert_eq!(questions.len(), 2);
            assert!(questions.contains_key("category#0") && questions.contains_key("category#1"));
            assert!(
                !questions.contains_key("bounded"),
                "a question outside its score bounds must not reach d1"
            );
            assert!(questions["category#0"]["instructions"]
                .as_str()
                .unwrap()
                .contains("Beach"));
            write_socket_json(
                &mut socket,
                &json!({"answers":{"category#0":{"noul":0.9},"category#1":{"noul":0.2}}}),
            )
            .await;
        }
    });

    let rules_path = "/api/v1/provider-lookups/immich/decision-rules";
    let rules = json!({"rules":[
        {
            "id":"category",
            "kind":"category",
            "question":"Based on the photo's contents and tags, which category does it belong to?",
            "yesTag":"",
            "noTag":"",
            "categories":["Beach","City"],
            "bounds":{"aestheticMin":0.5},
            "automatic":false
        },
        {
            "id":"bounded",
            "kind":"yesNo",
            "question":"Is there a dog?",
            "yesTag":"dogs",
            "noTag":"",
            "categories":[],
            "bounds":{"keeperMin":0.9},
            "automatic":false
        }
    ]});
    assert_eq!(
        app.clone()
            .oneshot(request("PUT", rules_path, "alice", false, rules))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );

    for attempt in 0..2 {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("{ROOT}/{PHOTO}/decisions"),
                "alice",
                false,
                Value::Null,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let result = json_response(response).await;
        assert_eq!(result["results"][0]["kind"], "category");
        assert_eq!(result["results"][0]["answer"], "yes");
        assert_eq!(result["results"][0]["category"], "Beach");
        assert_eq!(result["results"][0]["album"], "Beach");
        api_contract::assert_component("DecisionAssessment", &result);
        assert_eq!(result["results"][1]["kind"], "yesNo");
        assert_eq!(result["results"][1]["answer"], "skipped");
        assert_eq!(result["results"][1]["tag"], "");
        assert!(result["results"][1]["skipReason"]
            .as_str()
            .unwrap()
            .contains("bounds"));
        let tags = result["tags"].as_array().unwrap();
        assert!(!tags.contains(&json!("dogs")));
        assert!(tags.is_empty());
        if attempt == 1 {
            assert!(
                result["assessedAt"].is_string(),
                "a repeated assessment still reports a time"
            );
        }
    }
    let calls = fixture.calls.lock().unwrap().clone();
    assert_eq!(calls.iter().filter(|call| *call == "albums").count(), 1);
    assert_eq!(
        calls.iter().filter(|call| *call == "create-album").count(),
        1
    );
    assert!(calls.iter().any(|call| call == "add-album-asset"));
    eye.await.unwrap();
    d1.await.unwrap();
    upstream.abort();
}
