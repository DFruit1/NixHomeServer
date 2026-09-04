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
    let open_library = providers
        .iter()
        .find(|provider| provider["id"] == "open-library")
        .expect("Open Library");
    assert_eq!(open_library["setupKind"], "public");
    assert_eq!(open_library["implementationStatus"], "active");
    assert_eq!(open_library["canConfigure"], false);
    assert_eq!(open_library["canTest"], false);
    assert_eq!(open_library["account"]["state"], "notRequired");
    let tmdb = providers
        .iter()
        .find(|provider| provider["id"] == "tmdb")
        .expect("TMDB");
    assert_eq!(tmdb["setupKind"], "apiKey");
    assert_eq!(tmdb["implementationStatus"], "active");
    assert_eq!(tmdb["canConfigure"], true);
    assert_eq!(tmdb["canTest"], true);
    assert_eq!(tmdb["account"]["state"], "notConfigured");
    let cover_art_archive = providers
        .iter()
        .find(|provider| provider["id"] == "cover-art-archive")
        .expect("Cover Art Archive");
    assert_eq!(cover_art_archive["implementationStatus"], "active");
    assert_eq!(cover_art_archive["account"]["state"], "notRequired");
    let google_books = providers
        .iter()
        .find(|provider| provider["id"] == "google-books")
        .expect("Google Books");
    assert_eq!(google_books["implementationStatus"], "active");
    assert_eq!(google_books["canConfigure"], true);
    assert!(tmdb["credentialFields"]
        .as_array()
        .is_some_and(|fields| { fields.iter().all(|field| field["inputType"] == "password") }));
    assert!(providers
        .iter()
        .any(|provider| provider["implementationStatus"] == "planned"));
    let tvdb = providers
        .iter()
        .find(|provider| provider["id"] == "tvdb")
        .expect("TheTVDB");
    assert_eq!(tvdb["canConfigure"], false);
    assert_eq!(tvdb["canTest"], false);

    let opensubtitles = providers
        .iter()
        .find(|provider| provider["id"] == "opensubtitles")
        .expect("OpenSubtitles");
    let username = opensubtitles["credentialFields"]
        .as_array()
        .expect("credential fields")
        .iter()
        .find(|field| field["id"] == "username")
        .expect("username field");
    assert_eq!(username["inputType"], "text");
}

#[tokio::test]
async fn open_library_search_is_public_bounded_and_normalized() {
    use axum::{extract::Query, routing::get, Json, Router};
    use std::collections::HashMap;

    async fn search(Query(query): Query<HashMap<String, String>>) -> Json<Value> {
        assert_eq!(
            query.get("q").map(String::as_str),
            Some("isbn:9780441172719")
        );
        assert_eq!(query.get("limit").map(String::as_str), Some("12"));
        let fields = query.get("fields").expect("explicit fields");
        assert!(fields.contains("author_name"));
        assert!(fields.contains("editions.key"));
        assert_ne!(fields, "*");
        Json(serde_json::json!({
            "numFound": 1,
            "docs": [{
                "key": "/works/OL893415W",
                "title": "Dune",
                "author_name": ["Frank Herbert"],
                "first_publish_year": 1965,
                "edition_count": 312,
                "cover_i": 8231856,
                "publisher": ["Ace Books"],
                "isbn": ["9780441172719", "0441172717"],
                "language": ["eng"],
                "subject": ["Science fiction", "Dune (Imaginary place)"],
                "editions": {
                    "docs": [{
                        "key": "/books/OL75313M",
                        "title": "Dune",
                        "publish_date": ["September 1990"],
                        "publisher": ["Ace Books"],
                        "isbn": ["9780441172719"],
                        "language": ["eng"],
                        "number_of_pages": 535,
                        "cover_i": 8231856
                    }]
                }
            }]
        }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/search.json", get(search)))
            .await
            .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            open_library_api_base: format!("http://127.0.0.1:{}/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );

    let invalid = app
        .clone()
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/open-library/search",
            "reader-subject",
            Body::from(r#"{"query":""}"#),
        ))
        .await
        .expect("invalid lookup response");
    assert_eq!(invalid.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        response_json(invalid).await["error"]["code"],
        "open_library_query_invalid"
    );

    let response = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/open-library/search",
            "reader-subject",
            Body::from(r#"{"query":"978-0-441-17271-9"}"#),
        ))
        .await
        .expect("lookup response");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["cache-control"], "no-store, max-age=0");
    let body = response_json(response).await;
    assert_eq!(body["provider"], "open-library");
    assert_eq!(body["query"], "978-0-441-17271-9");
    assert_eq!(body["results"][0]["workId"], "OL893415W");
    assert_eq!(body["results"][0]["editionId"], "OL75313M");
    assert_eq!(body["results"][0]["title"], "Dune");
    assert_eq!(body["results"][0]["authors"][0], "Frank Herbert");
    assert_eq!(body["results"][0]["firstPublishYear"], 1965);
    assert_eq!(body["results"][0]["publishYear"], 1990);
    assert_eq!(body["results"][0]["publishers"][0], "Ace Books");
    assert_eq!(body["results"][0]["isbn13"], "9780441172719");
    assert_eq!(body["results"][0]["isbn10"], "0441172717");
    assert_eq!(body["results"][0]["languages"][0], "eng");
    assert_eq!(body["results"][0]["numberOfPages"], 535);
    assert_eq!(
        body["results"][0]["coverUrl"],
        "https://covers.openlibrary.org/b/id/8231856-M.jpg"
    );
    assert_eq!(body["results"][0]["coverId"], 8231856);
    mock.abort();
}

#[tokio::test]
async fn open_library_editions_and_covers_are_bounded_normalized_proxies() {
    use axum::{extract::Query, routing::get, Json, Router};
    use std::collections::HashMap;

    async fn editions(Query(query): Query<HashMap<String, String>>) -> Json<Value> {
        assert_eq!(query.get("limit").map(String::as_str), Some("2"));
        assert_eq!(query.get("offset").map(String::as_str), Some("0"));
        Json(serde_json::json!({
            "size": 3,
            "entries": [{
                "key": "/books/OL75313M",
                "title": "Dune",
                "publish_date": "September 1990",
                "publishers": ["Ace Books"],
                "isbn_10": ["0441172717"],
                "isbn_13": ["9780441172719"],
                "languages": [{"key": "/languages/eng"}],
                "number_of_pages": 535,
                "covers": [8231856]
            }]
        }))
    }

    async fn cover() -> impl axum::response::IntoResponse {
        (
            [("content-type", "image/jpeg")],
            vec![0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43],
        )
    }

    async fn invalid_cover() -> impl axum::response::IntoResponse {
        (
            [("content-type", "image/jpeg")],
            b"<html>not an image</html>".to_vec(),
        )
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new()
                .route("/works/OL893415W/editions.json", get(editions))
                .route("/b/id/8231856-L.jpg", get(cover))
                .route("/b/id/8231857-L.jpg", get(invalid_cover)),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let base = format!("http://127.0.0.1:{}/", address.port());
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            open_library_api_base: base.clone(),
            open_library_covers_base: base,
            ..ProviderTestEndpoints::default()
        },
    );

    let invalid_work = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/open-library/works/not-a-work/editions",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("invalid work response");
    assert_eq!(invalid_work.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        response_json(invalid_work).await["error"]["code"],
        "open_library_work_id_invalid"
    );

    let invalid_cover = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/open-library/covers/0",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("invalid cover response");
    assert_eq!(invalid_cover.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        response_json(invalid_cover).await["error"]["code"],
        "open_library_cover_id_invalid"
    );

    let editions_response = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/open-library/works/OL893415W/editions?offset=0&limit=2",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("editions response");
    assert_eq!(editions_response.status(), StatusCode::OK);
    let editions_body = response_json(editions_response).await;
    assert_eq!(editions_body["workId"], "OL893415W");
    assert_eq!(editions_body["total"], 3);
    assert_eq!(editions_body["hasMore"], true);
    assert_eq!(editions_body["results"][0]["editionId"], "OL75313M");
    assert_eq!(editions_body["results"][0]["coverId"], 8231856);

    let cover_response = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/open-library/covers/8231856",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("cover response");
    assert_eq!(cover_response.status(), StatusCode::OK);
    assert_eq!(cover_response.headers()["content-type"], "image/jpeg");
    assert_eq!(
        cover_response.headers()["x-content-type-options"],
        "nosniff"
    );
    let bytes = to_bytes(cover_response.into_body(), 1024)
        .await
        .expect("cover body");
    assert_eq!(&bytes[..3], &[0xff, 0xd8, 0xff]);

    let invalid_bytes = app
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/open-library/covers/8231857",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("invalid cover bytes response");
    assert_eq!(invalid_bytes.status(), StatusCode::BAD_GATEWAY);
    mock.abort();
}

#[tokio::test]
async fn planned_provider_credentials_are_rejected_without_being_saved() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let response = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tvdb",
            "subject-1",
            Body::from(r#"{"credentials":{"apiKey":"must-not-be-stored"}}"#),
        ))
        .await
        .expect("save response");

    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = response_json(response).await;
    assert_eq!(body["error"]["code"], "provider_adapter_unavailable");
    assert!(!body.to_string().contains("must-not-be-stored"));

    let listed = app
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-accounts",
            "subject-1",
            Body::empty(),
        ))
        .await
        .expect("list response");
    let listed = response_json(listed).await;
    let tvdb = listed["providers"]
        .as_array()
        .expect("providers")
        .iter()
        .find(|provider| provider["id"] == "tvdb")
        .expect("TheTVDB");
    assert_eq!(tvdb["account"]["state"], "notConfigured");
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
async fn tmdb_episode_details_use_the_selected_series_and_episode_numbers() {
    use axum::{http::HeaderMap, routing::get, Json, Router};

    async fn episode(headers: HeaderMap) -> Json<Value> {
        assert_eq!(
            headers
                .get("authorization")
                .and_then(|value| value.to_str().ok()),
            Some("Bearer episode-token")
        );
        Json(serde_json::json!({
            "id": 63056,
            "name": "The Train Job",
            "overview": "Mal takes a questionable transport job.",
            "air_date": "2002-09-20",
            "episode_number": 2,
            "season_number": 1,
            "runtime": 44,
            "vote_average": 8.1,
            "still_path": "/train-job.jpg",
            "crew": [{"id": 1, "name": "Joss Whedon", "job": "Writer", "department": "Writing"}],
            "guest_stars": []
        }))
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().route("/3/tv/1437/season/1/episode/2", get(episode)),
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
            Body::from(r#"{"credentials":{"apiKey":"episode-token"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let response = app
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/tmdb/details",
            "owner-subject",
            Body::from(
                r#"{"tmdbId":1437,"mediaType":"episode","seasonNumber":1,"episodeNumber":2}"#,
            ),
        ))
        .await
        .expect("episode details response");
    assert_eq!(response.status(), StatusCode::OK);
    let response = response_json(response).await;
    assert_eq!(response["details"]["mediaType"], "episode");
    assert_eq!(response["details"]["episodeTitle"], "The Train Job");
    assert_eq!(response["details"]["season"], 1);
    assert_eq!(response["details"]["episode"], 2);
    assert_eq!(response["details"]["runtimeMinutes"], 44);
    assert_eq!(response["details"]["stillPath"], "/train-job.jpg");
    mock.abort();
}

#[tokio::test]
async fn provider_artwork_is_authenticated_bounded_and_content_sniffed() {
    use axum::{http::header, routing::get, Router};

    async fn image() -> ([(&'static str, &'static str); 1], Vec<u8>) {
        (
            [(header::CONTENT_TYPE.as_str(), "image/jpeg")],
            vec![0xff, 0xd8, 0xff, 0xd9],
        )
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new()
                .route("/t/p/w500/poster.jpg", get(image))
                .route(
                    "/cover/release/2d4b4f36-bbf7-37d2-8c59-8f84a8f1b5a7/front-1200",
                    get(image),
                ),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            tmdb_images_base: format!("http://127.0.0.1:{}/t/p/", address.port()),
            cover_art_archive_base: format!("http://127.0.0.1:{}/cover/", address.port()),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/tmdb",
            "owner-subject",
            Body::from(r#"{"credentials":{"apiKey":"image-token"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    for uri in [
        "/api/v1/provider-lookups/tmdb/images/w500/poster.jpg",
        "/api/v1/provider-lookups/cover-art-archive/releases/2d4b4f36-bbf7-37d2-8c59-8f84a8f1b5a7/front",
    ] {
        let response = app
            .clone()
            .oneshot(account_request("GET", uri, "owner-subject", Body::empty()))
            .await
            .expect("artwork response");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], "image/jpeg");
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert_eq!(
            to_bytes(response.into_body(), 1024).await.expect("image body"),
            &[0xff, 0xd8, 0xff, 0xd9][..]
        );
    }
    mock.abort();
}

#[tokio::test]
async fn google_books_search_normalizes_volumes_and_proxies_selected_covers() {
    use axum::{
        extract::{Path, Query, State},
        http::header,
        routing::get,
        Json, Router,
    };
    use std::collections::HashMap;

    async fn volumes(Query(query): Query<HashMap<String, String>>) -> Json<Value> {
        assert_eq!(query.get("q").map(String::as_str), Some("Dune"));
        assert_eq!(query.get("key").map(String::as_str), Some("books-key"));
        Json(serde_json::json!({
            "totalItems": 1,
            "items": [{
                "id": "zyTCAlFPjgYC",
                "volumeInfo": {
                    "title": "Dune",
                    "subtitle": "The first novel",
                    "authors": ["Frank Herbert"],
                    "publisher": "Ace",
                    "publishedDate": "1965-08-01",
                    "description": "A desert world and its politics.",
                    "industryIdentifiers": [{"type": "ISBN_13", "identifier": "9780441172719"}],
                    "pageCount": 535,
                    "categories": ["Fiction"],
                    "language": "en",
                    "averageRating": 4.5,
                    "ratingsCount": 99,
                    "imageLinks": {"thumbnail": "https://unused.invalid/cover.jpg"}
                }
            }]
        }))
    }

    async fn volume(
        State(base): State<String>,
        Path(volume_id): Path<String>,
        Query(query): Query<HashMap<String, String>>,
    ) -> Json<Value> {
        assert_eq!(query.get("key").map(String::as_str), Some("books-key"));
        let response_id = if volume_id == "mismatched" {
            "different-volume"
        } else {
            volume_id.as_str()
        };
        Json(serde_json::json!({
            "id": response_id,
            "volumeInfo": {
                "title": "Dune",
                "imageLinks": {"large": format!("{base}/covers/dune.jpg")}
            }
        }))
    }

    async fn cover() -> ([(&'static str, &'static str); 1], Vec<u8>) {
        (
            [(header::CONTENT_TYPE.as_str(), "image/jpeg")],
            vec![0xff, 0xd8, 0xff, 0xd9],
        )
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock listener");
    let address = listener.local_addr().expect("mock address");
    let base = format!("http://127.0.0.1:{}", address.port());
    let mock_base = base.clone();
    let mock = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new()
                .route("/books/v1/volumes", get(volumes))
                .route("/books/v1/volumes/{volume_id}", get(volume))
                .route("/covers/dune.jpg", get(cover))
                .with_state(mock_base),
        )
        .await
        .expect("mock provider");
    });
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app_with_endpoints(
        &temp,
        ProviderTestEndpoints {
            google_books_api_base: format!("{base}/books/v1/"),
            ..ProviderTestEndpoints::default()
        },
    );
    let saved = app
        .clone()
        .oneshot(account_request(
            "PUT",
            "/api/v1/provider-accounts/google-books",
            "reader-subject",
            Body::from(r#"{"credentials":{"apiKey":"books-key"}}"#),
        ))
        .await
        .expect("save response");
    assert_eq!(saved.status(), StatusCode::OK);

    let response = app
        .clone()
        .oneshot(account_request(
            "POST",
            "/api/v1/provider-lookups/google-books/search",
            "reader-subject",
            Body::from(r#"{"query":"Dune"}"#),
        ))
        .await
        .expect("search response");
    assert_eq!(response.status(), StatusCode::OK);
    let response = response_json(response).await;
    assert_eq!(response["results"][0]["volumeId"], "zyTCAlFPjgYC");
    assert_eq!(response["results"][0]["isbn"], "9780441172719");
    assert_eq!(response["results"][0]["year"], 1965);
    assert_eq!(response["results"][0]["coverAvailable"], true);
    assert!(!response.to_string().contains("books-key"));

    let mismatched_cover = app
        .clone()
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/google-books/volumes/mismatched/cover",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("mismatched cover response");
    assert_eq!(mismatched_cover.status(), StatusCode::BAD_GATEWAY);

    let cover = app
        .oneshot(account_request(
            "GET",
            "/api/v1/provider-lookups/google-books/volumes/zyTCAlFPjgYC/cover",
            "reader-subject",
            Body::empty(),
        ))
        .await
        .expect("cover response");
    assert_eq!(cover.status(), StatusCode::OK);
    assert_eq!(cover.headers()["content-type"], "image/jpeg");
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
