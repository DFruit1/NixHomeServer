//! Security regressions: future private-data tools must never disclose another
//! caller's documents/jobs through forged claims or reused transport state.

use super::*;
use axum::{
    body::Body,
    http::{header::HeaderValue, Method, Request as HttpRequest},
};
use serde_json::{json, Value};
use tower::ServiceExt;

const HOST: &str = "tools.example.test";
const LIST: &str = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#;

fn request(method: Method, body: &str, user: Option<&str>) -> HttpRequest<Body> {
    let mut request = HttpRequest::builder()
        .method(method)
        .uri("/")
        .header("host", HOST)
        .header("content-type", "application/json")
        .header("accept", "application/json, text/event-stream")
        .header("mcp-protocol-version", "2025-06-18")
        .body(Body::from(body.to_owned()))
        .unwrap();
    if let Some(user) = user {
        request.headers_mut().insert(
            "x-forwarded-user",
            format!("subject-{user}").parse().unwrap(),
        );
        request
            .headers_mut()
            .insert("x-forwarded-preferred-username", user.parse().unwrap());
    }
    request
}

#[test]
fn canonical_identity_has_no_fallback_or_list_interpretation() {
    let valid = request(Method::POST, LIST, Some("alice"));
    assert_eq!(
        AuthenticatedCaller::from_gateway_headers(valid.headers())
            .unwrap()
            .username(),
        "alice"
    );
    for header in ["x-forwarded-user", "x-forwarded-preferred-username"] {
        for value in [
            "",
            " alice",
            "alice ",
            "alice,bob",
            "alice bob",
            &"x".repeat(257),
        ] {
            let mut headers = valid.headers().clone();
            headers.insert(header, value.parse().unwrap());
            assert!(
                AuthenticatedCaller::from_gateway_headers(&headers).is_none(),
                "accepted {header}={value:?}"
            );
        }
        let mut headers = valid.headers().clone();
        headers.append(header, headers[header].clone());
        assert!(AuthenticatedCaller::from_gateway_headers(&headers).is_none());
        let mut headers = valid.headers().clone();
        headers.insert(header, HeaderValue::from_bytes(&[0xff]).unwrap());
        assert!(AuthenticatedCaller::from_gateway_headers(&headers).is_none());
        let mut headers = valid.headers().clone();
        headers.remove(header);
        headers.insert("x-auth-request-user", "subject-alice".parse().unwrap());
        headers.insert("x-forwarded-email", "alice@example.test".parse().unwrap());
        assert!(AuthenticatedCaller::from_gateway_headers(&headers).is_none());
    }
}

#[tokio::test]
async fn every_http_method_requires_current_identity_and_rejects_sessions() {
    let app = router(crate::tests::test_server(), HOST);
    for method in [Method::POST, Method::GET, Method::DELETE, Method::OPTIONS] {
        assert_eq!(
            app.clone()
                .oneshot(request(method.clone(), LIST, None))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        for session in ["", "borrowed-from-another-user"] {
            let mut req = request(method.clone(), LIST, Some("alice"));
            req.headers_mut()
                .insert("mcp-session-id", session.parse().unwrap());
            assert_eq!(
                app.clone().oneshot(req).await.unwrap().status(),
                StatusCode::BAD_REQUEST
            );
        }
    }
}

#[tokio::test]
async fn stateless_handshake_discovery_and_denials_use_real_mcp_dispatch() {
    let app = router(crate::tests::test_server(), HOST);
    let mut health = request(Method::GET, "", Some("alice"));
    *health.uri_mut() = "/healthz".parse().unwrap();
    assert_eq!(
        app.clone().oneshot(health).await.unwrap().status(),
        StatusCode::OK
    );
    let init = app
        .clone()
        .oneshot(request(
            Method::POST,
            &crate::tests::initialize_body(),
            Some("alice"),
        ))
        .await
        .unwrap();
    assert_eq!(init.status(), StatusCode::OK);
    assert!(!init.headers().contains_key("mcp-session-id"));
    let notification = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
    assert_eq!(
        app.clone()
            .oneshot(request(Method::POST, notification, Some("alice")))
            .await
            .unwrap()
            .status(),
        StatusCode::ACCEPTED
    );
    // Initialization does not authenticate later requests, even for discovery.
    assert_eq!(
        app.clone()
            .oneshot(request(Method::POST, LIST, None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let response = app
        .clone()
        .oneshot(request(Method::POST, LIST, Some("alice")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 1);
    assert_eq!(body["result"]["tools"][0]["name"], "web_search");
    for name in [
        "convert_document",
        "spreadsheet_read",
        "spreadsheet_write",
        "word_document",
    ] {
        let body = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":name,"arguments":{"path":"do-not-open.docx"}}}).to_string();
        let response = app
            .clone()
            .oneshot(request(Method::POST, &body, Some("alice")))
            .await
            .unwrap();
        let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        assert_eq!(body["error"]["code"], -32602);
        assert!(body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("unavailable pending caller-permission enforcement"));
    }
}

#[derive(Clone)]
struct InspectCaller;

impl ServerHandler for InspectCaller {
    fn get_info(&self) -> InitializeResult {
        crate::tests::test_server().get_info()
    }

    async fn list_tools(
        &self,
        request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        AuthenticatedCaller::require(&context)?;
        crate::tests::test_server()
            .list_tools(request, context)
            .await
    }

    async fn call_tool(
        &self,
        _: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let actor = AuthenticatedCaller::require(&context)?;
        Ok(
            rmcp::model::CallToolResult::success(vec![rmcp::model::ContentBlock::json(
                json!({"subject":actor.subject(),"username":actor.username()}),
            )?])
            .into(),
        )
    }
}

fn inspect_body() -> String {
    json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"web_search","arguments":{"caller":"mallory","identity":"mallory"},"_meta":{"subject":"mallory"}}}).to_string()
}

#[tokio::test]
async fn handlers_receive_only_the_current_actor_not_arguments_or_previous_users() {
    let app = authenticated_router(InspectCaller, HOST);
    for user in ["alice", "bob", "alice"] {
        let response = app
            .clone()
            .oneshot(request(Method::POST, &inspect_body(), Some(user)))
            .await
            .unwrap();
        let value: Value =
            serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        let payload: Value =
            serde_json::from_str(value["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(
            payload,
            json!({"subject":format!("subject-{user}"),"username":user})
        );
    }
    let response = app
        .oneshot(request(Method::POST, &inspect_body(), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn identity_headers_without_gateway_middleware_cannot_construct_a_caller() {
    let mut config = crate::streamable_http_config(Some(HOST));
    config.legacy_session_mode = false;
    let mcp = StreamableHttpService::new(
        || Ok(InspectCaller),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    let app = Router::new().fallback_service(mcp);
    let response = app
        .oneshot(request(Method::POST, &inspect_body(), Some("alice")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(body["error"]["message"], "Authenticated caller required");
}

#[tokio::test]
async fn authenticated_requests_still_require_the_approved_host_and_origin() {
    let app = router(crate::tests::test_server(), HOST);
    for (header, value) in [
        ("host", "evil.example.test"),
        ("origin", "https://evil.example.test"),
        ("origin", "https://tools.example.test:444"),
    ] {
        let mut req = request(Method::POST, LIST, Some("alice"));
        req.headers_mut().insert(header, value.parse().unwrap());
        assert_eq!(
            app.clone().oneshot(req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    for origin in [
        "https://tools.example.test",
        "https://tools.example.test:443",
    ] {
        let mut req = request(Method::POST, LIST, Some("alice"));
        req.headers_mut().insert("origin", origin.parse().unwrap());
        assert_eq!(
            app.clone().oneshot(req).await.unwrap().status(),
            StatusCode::OK
        );
    }
}

#[tokio::test]
async fn real_unix_transport_carries_identity_for_each_request() {
    let dir = crate::tests::SyntheticSharedRoot::new("gateway-transport");
    let path = dir.join("gateway.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let app = authenticated_router(InspectCaller, HOST);
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder()
        .no_proxy()
        .unix_socket(path.clone())
        .build()
        .unwrap();
    for user in ["alice", "bob"] {
        let response = client
            .post(format!("http://{HOST}/"))
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2025-06-18")
            .header("x-forwarded-user", format!("subject-{user}"))
            .header("x-forwarded-preferred-username", user)
            .header("content-type", "application/json")
            .body(inspect_body())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(!response.headers().contains_key("mcp-session-id"));
        let value: Value = response.json().await.unwrap();
        let payload: Value =
            serde_json::from_str(value["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(payload["username"], user);
    }
    let response = client
        .post(format!("http://{HOST}/"))
        .body(inspect_body())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    // Run the actual MCP initialize/initialized/list/call lifecycle as well as
    // raw HTTP, so the stateless transport contract is exercised by its client.
    use rmcp::{
        transport::{
            streamable_http_client::StreamableHttpClientTransportConfig,
            StreamableHttpClientTransport,
        },
        ClientServiceExt,
    };
    let mut headers = HeaderMap::new();
    headers.insert("x-forwarded-user", "subject-alice".parse().unwrap());
    headers.insert("x-forwarded-preferred-username", "alice".parse().unwrap());
    let client = reqwest::Client::builder()
        .no_proxy()
        .unix_socket(path)
        .default_headers(headers)
        .build()
        .unwrap();
    let transport = StreamableHttpClientTransport::with_client(
        client,
        StreamableHttpClientTransportConfig::with_uri(format!("http://{HOST}/")),
    );
    let peer = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        ().serve_with_lifecycle(transport, rmcp::ClientLifecycleMode::Initialize),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(peer.list_all_tools().await.unwrap()[0].name, "web_search");
    let result = peer
        .call_tool(CallToolRequestParams::new("web_search"))
        .await
        .unwrap();
    let payload: Value =
        serde_json::from_str(result.content[0].as_text().unwrap().text.as_str()).unwrap();
    assert_eq!(payload["subject"], "subject-alice");
    peer.cancel().await.unwrap();
    task.abort();
    let _ = task.await;
}
