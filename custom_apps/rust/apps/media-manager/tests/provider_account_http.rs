use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use media_manager::{
    provider_account_http::{provider_account_router, ProviderBrokerState, ProviderTestEndpoints},
    provider_accounts::ProviderAccountStore,
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

fn test_app(temp: &tempfile::TempDir) -> axum::Router {
    let store = ProviderAccountStore::open(
        &temp.path().join("provider-accounts.sqlite3"),
        &temp.path().join("master.key"),
    )
    .expect("provider account store");
    provider_account_router(
        ProviderBrokerState::new(Arc::new(store)).expect("provider broker state"),
    )
}

fn test_app_with_endpoints(
    temp: &tempfile::TempDir,
    endpoints: ProviderTestEndpoints,
) -> axum::Router {
    let store = ProviderAccountStore::open(
        &temp.path().join("provider-accounts.sqlite3"),
        &temp.path().join("master.key"),
    )
    .expect("provider account store");
    provider_account_router(
        ProviderBrokerState::with_test_endpoints(Arc::new(store), endpoints)
            .expect("provider broker state"),
    )
}

fn account_request(method: &str, uri: &str, subject: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-user", subject)
        .header("x-forwarded-preferred-username", "sydney")
        .header("x-forwarded-groups", "users")
        .body(body)
        .expect("request")
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), 1024 * 1024)
        .await
        .expect("response body");
    serde_json::from_slice(&bytes).expect("response JSON")
}

#[tokio::test]
async fn provider_catalog_shows_public_configurable_and_planned_sources() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let response = test_app(&temp)
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["cache-control"], "no-store, max-age=0");
    let value = response_json(response).await;
    assert_eq!(value["schemaVersion"], 1);
    assert!(value["recoveryAdvice"]
        .as_str()
        .expect("recovery advice")
        .contains("password manager"));
    let providers = value["providers"].as_array().expect("providers");
    assert!(providers.len() >= 16);
    let musicbrainz = providers
        .iter()
        .find(|provider| provider["id"] == "musicbrainz")
        .expect("MusicBrainz");
    assert_eq!(musicbrainz["setupKind"], "public");
    assert_eq!(musicbrainz["account"]["state"], "notRequired");
    let tmdb = providers
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["setupKind"], "apiKey");
    assert_eq!(tmdb["implementationStatus"], "active");
    assert_eq!(tmdb["account"]["state"], "notConfigured");
    assert!(tmdb["credentialFields"]
        .as_array()
        .is_some_and(|fields| { fields.iter().all(|field| field["inputType"] == "password") }));
    assert!(providers
        .iter()
        .any(|provider| provider["implementationStatus"] == "planned"));
}

#[tokio::test]
async fn saving_an_account_never_returns_or_lists_its_secret() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let secret = "tmdb-key-that-must-not-be-returned";
    let response = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "subject-1",
            Body::from(format!(r#"{{"credentials":{{"apiKey":"{secret}"}}}}"#)),
        ))
        .await
        .expect("save response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["provider"]["account"]["state"], "configured");
    assert!(!body.to_string().contains(secret));

    let response = app
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("list response");
    let body = response_json(response).await;
    assert!(!body.to_string().contains(secret));
    let tmdb = body["providers"]
        .as_array()
        .expect("providers")
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["account"]["state"], "configured");
}

#[tokio::test]
async fn credential_documents_require_exact_bounded_fields() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    for body in [
        r#"{"credentials":{}}"#.to_string(),
        r#"{"credentials":{"apiKey":"key","password":"unexpected"}}"#.to_string(),
        format!(r#"{{"credentials":{{"apiKey":"{}"}}}}"#, "x".repeat(8193)),
    ] {
        let response = app
            .clone()
            .oneshot(account_request(
                "PUT",
                "/api/v1/provider-accounts/tmdb",
                "subject-1",
                Body::from(body),
            ))
            .await
            .expect("response");
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "credential_validation_failed"
        );
    }
}

#[tokio::test]
async fn malformed_json_uses_the_common_api_error_shape() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let response = test_app(&temp)
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "subject-1",
            Body::from(r#"{"credentials":"#),
        ))
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        response_json(response).await["error"]["code"],
        "invalid_json"
    );
}

#[tokio::test]
async fn one_user_cannot_list_or_delete_another_users_account() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "subject-1",
            Body::from(r#"{"credentials":{"apiKey":"secret"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let other_list = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-2",
            Body::empty(),
        ))
        .await
        .expect("other list");
    let other_body = response_json(other_list).await;
    let tmdb = other_body["providers"]
        .as_array()
        .expect("providers")
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["account"]["state"], "notConfigured");

    let other_delete = app
        .clone()
        .oneshot(account_request(
            "DELETE",
            "/api/v1/provider-accounts/tmdb",
            "subject-2",
            Body::empty(),
        ))
        .await
        .expect("other delete");
    assert_eq!(other_delete.status(), StatusCode::NO_CONTENT);

    let owner_list = app
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("owner list");
    let owner_body = response_json(owner_list).await;
    let tmdb = owner_body["providers"]
        .as_array()
        .expect("providers")
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["account"]["state"], "configured");
}

#[tokio::test]
async fn tmdb_connection_test_uses_the_saved_key_and_records_only_normalized_status() {
    use axum::{http::HeaderMap, routing::get, Json, Router};

    async fn authentication(headers: HeaderMap) -> Json<Value> {
        assert_eq!(
            headers
                .get("authorization")
                .and_then(|value| value.to_str().ok()),
            Some("Bearer secret-key")
        );
        Json(serde_json::json!({ "success": true }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().route("/3/authentication", get(authentication)),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            tmdb_api_base: format!("http://127.0.0.1:{}/3/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "subject-1",
            Body::from(r#"{"credentials":{"apiKey":"secret-key"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let tested = app
        .clone()
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-accounts/tmdb/test",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("test response");
    assert_eq!(tested.status(), StatusCode::OK);
    let tested = response_json(tested).await;
    assert_eq!(tested["status"], "ready");
    assert!(!tested.to_string().contains("secret-key"));

    let listed = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("list response");
    let listed = response_json(listed).await;
    let tmdb = listed["providers"]
        .as_array()
        .expect("providers")
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["account"]["lastTestStatus"], "ready");

    let other = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-accounts/tmdb/test",
            "subject-2",
            Body::empty(),
        ))
        .await
        .expect("other user's test response");
    assert_eq!(other.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        response_json(other).await["error"]["code"],
        "provider_account_not_found"
    );
    mock.abort();
}

#[tokio::test]
async fn tmdb_lookup_uses_only_the_callers_runtime_account() {
    use axum::{extract::Query, http::HeaderMap, routing::get, Json, Router};
    use std::collections::HashMap;

    async fn search(
        headers: HeaderMap,
        Query(query): Query<HashMap<String, String>>,
    ) -> Json<Value> {
        assert_eq!(
            headers
                .get("authorization")
                .and_then(|value| value.to_str().ok()),
            Some("Bearer owner-read-token")
        );
        assert_eq!(query.get("query").map(String::as_str), Some("Arrival"));
        Json(serde_json::json!({
            "results": [{
                "id": 329865,
                "title": "Arrival",
                "overview": "A linguist works with the military.",
                "release_date": "2016-11-10",
                "vote_average": 7.6,
                "vote_count": 18000,
                "genre_ids": [18, 878]
            }]
        }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().route("/3/search/movie", get(search)),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            tmdb_api_base: format!("http://127.0.0.1:{}/3/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "owner-subject",
            Body::from(r#"{"credentials":{"apiKey":"owner-read-token"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let lookup = app
        .clone()
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/tmdb/search",
            "owner-subject",
            Body::from(r#"{"query":"Arrival","year":2016,"mediaType":"movie"}"#),
        ))
        .await
        .expect("lookup response");
    assert_eq!(lookup.status(), StatusCode::OK);
    let lookup = response_json(lookup).await;
    assert_eq!(lookup["results"][0]["tmdbId"], 329865);
    assert_eq!(lookup["results"][0]["title"], "Arrival");
    assert_eq!(lookup["provider"], "tmdb");
    assert!(!lookup.to_string().contains("owner-read-token"));

    let other = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/tmdb/search",
            "other-subject",
            Body::from(r#"{"query":"Arrival","mediaType":"movie"}"#),
        ))
        .await
        .expect("other response");
    assert_eq!(other.status(), StatusCode::PRECONDITION_REQUIRED);
    assert_eq!(
        response_json(other).await["error"]["code"],
        "provider_account_required"
    );
    mock.abort();
}

#[tokio::test]
async fn opensubtitles_lookup_uses_the_callers_runtime_account_and_local_hash() {
    use axum::{extract::Query, http::HeaderMap, routing::get, Json, Router};
    use std::collections::HashMap;

    async fn subtitles(
        headers: HeaderMap,
        Query(query): Query<HashMap<String, String>>,
    ) -> Json<Value> {
        assert_eq!(
            headers.get("api-key").and_then(|value| value.to_str().ok()),
            Some("owner-app-key")
        );
        assert_eq!(
            query.get("moviehash").map(String::as_str),
            Some("0123456789abcdef")
        );
        assert_eq!(
            query.get("moviebytesize").map(String::as_str),
            Some("200000")
        );
        Json(serde_json::json!({
            "data": [{
                "id": "subtitle-result",
                "attributes": {
                    "language": "en",
                    "release": "Arrival.2016.1080p",
                    "download_count": 42,
                    "moviehash_match": true,
                    "files": [{"file_id": 99, "file_name": "Arrival.en.srt"}]
                }
            }]
        }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().route("/api/v1/subtitles", get(subtitles)),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            opensubtitles_api_base: format!("http://127.0.0.1:{}/api/v1/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/opensubtitles",
            "owner-subject",
            Body::from(
                r#"{"credentials":{"apiKey":"owner-app-key","username":"owner","password":"secret-password","userAgent":"MediaManagerTests"}}"#,
            ),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let lookup = app
        .clone()
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/opensubtitles/search",
            "owner-subject",
            Body::from(
                r#"{"movieHash":"0123456789abcdef","movieByteSize":200000,"query":"Arrival","languages":"en"}"#,
            ),
        ))
        .await
        .expect("lookup response");
    assert_eq!(lookup.status(), StatusCode::OK);
    let lookup = response_json(lookup).await;
    assert_eq!(lookup["matchMethod"], "movie-hash");
    assert_eq!(lookup["results"][0]["fileId"], 99);
    assert!(!lookup.to_string().contains("owner-app-key"));
    assert!(!lookup.to_string().contains("secret-password"));

    let other = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/opensubtitles/search",
            "other-subject",
            Body::from(r#"{"query":"Arrival","languages":"en"}"#),
        ))
        .await
        .expect("other response");
    assert_eq!(other.status(), StatusCode::PRECONDITION_REQUIRED);
    mock.abort();
}

#[tokio::test]
async fn acoustid_lookup_uses_the_callers_key_without_uploading_audio() {
    use axum::{extract::Query, routing::get, Json, Router};
    use std::collections::HashMap;

    async fn lookup(Query(query): Query<HashMap<String, String>>) -> Json<Value> {
        assert_eq!(
            query.get("client").map(String::as_str),
            Some("owner-client-key")
        );
        assert_eq!(
            query.get("fingerprint").map(String::as_str),
            Some("AQAD-test")
        );
        assert_eq!(query.get("duration").map(String::as_str), Some("213"));
        assert_eq!(
            query.get("meta").map(String::as_str),
            Some("recordingids+releasegroups")
        );
        Json(serde_json::json!({
            "status": "ok",
            "results": [{
                "recordings": [{
                    "releasegroups": [{"id": "1b022e01-4da6-387b-8658-8678046e4cef"}]
                }]
            }]
        }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/v2/lookup", get(lookup)))
            .await
            .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            acoustid_api_base: format!("http://127.0.0.1:{}/v2/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/acoustid",
            "owner-subject",
            Body::from(r#"{"credentials":{"apiKey":"owner-client-key"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let response = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/acoustid/lookup",
            "owner-subject",
            Body::from(r#"{"fingerprint":"AQAD-test","duration":213}"#),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::OK);
    let response = response_json(response).await;
    assert_eq!(response["provider"], "acoustid");
    assert_eq!(
        response["releaseGroupIds"][0],
        "1b022e01-4da6-387b-8658-8678046e4cef"
    );
    assert!(!response.to_string().contains("owner-client-key"));
    mock.abort();
}
