use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use media_manager::{
    provider_account_http::{provider_account_router, ProviderBrokerState},
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
    provider_account_router(ProviderBrokerState {
        store: Arc::new(store),
    })
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
    assert_eq!(
        response.headers()["cache-control"],
        "no-store, max-age=0"
    );
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
    assert!(tmdb["credentialFields"].as_array().is_some_and(|fields| {
        fields
            .iter()
            .all(|field| field["inputType"] == "password")
    }));
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
        format!(
            r#"{{"credentials":{{"apiKey":"{}"}}}}"#,
            "x".repeat(8193)
        ),
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
