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

#[tokio::test]
async fn administration_discovery_and_calls_are_exact_login_scoped() {
    let mut server = app_server();
    Arc::make_mut(&mut server.config).admin = Some(crate::admin_tools::Config {
        username: "admindsaw".into(),
        host: HOST.into(),
    });
    let app = router(server.clone(), HOST);
    let mut transport = crate::streamable_http_config(Some(HOST));
    transport.legacy_session_mode = false;
    let core = Router::new().fallback_service(StreamableHttpService::new(
        move || Ok(server.clone()),
        Arc::new(NeverSessionManager::default()),
        transport,
    ));
    let response = core
        .clone()
        .oneshot(request(Method::POST, LIST, Some("admindsaw")))
        .await
        .unwrap();
    let value: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(value["result"]["tools"].as_array().unwrap().len(), 1);
    for user in ["admindsaw", "dsaw", "AdminDsaw", "admindsaw@example.test"] {
        let response = app
            .clone()
            .oneshot(request(Method::POST, LIST, Some(user)))
            .await
            .unwrap();
        let value: Value =
            serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        let names: Vec<_> = value["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|t| t["name"].as_str())
            .collect();
        for name in [
            "server_health",
            "server_services",
            "server_service_status",
            "server_restart_service",
        ] {
            assert_eq!(names.contains(&name), user == "admindsaw");
            let body=json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":name,"arguments":{"username":"admindsaw"}}}).to_string();
            let response = app
                .clone()
                .oneshot(request(Method::POST, &body, Some(user)))
                .await
                .unwrap();
            let value: Value =
                serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
            let expected = if user == "admindsaw" {
                crate::app_tools::session_required()
            } else {
                crate::admin_tools::denied()
            };
            assert_eq!(value["error"]["message"], expected.message.as_ref());
            let mut forged = request(Method::POST, &body, Some("admindsaw"));
            forged.headers_mut().insert(
                "cookie",
                "__Secure-nixhomeserver_sso=forged".parse().unwrap(),
            );
            let response = core.clone().oneshot(forged).await.unwrap();
            let value: Value =
                serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
            assert!(value["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with("unknown tool:"));
        }
    }
}

#[tokio::test]
async fn structural_import_authorizes_each_source_with_the_current_request_actor() {
    let socket =
        std::env::temp_dir().join(format!("office-import-test-{}.sock", std::process::id()));
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let mut server = app_server();
    Arc::make_mut(&mut server.config).office_socket = Some(socket.clone());
    let app = router(server, HOST);
    let broker = tokio::spawn(async move {
        for user in ["alice", "bob"] {
            for path in ["destination.xlsx", "private.docx"] {
                let (mut stream, _) = listener.accept().await.unwrap();
                let bytes = crate::office_io::receive(&mut stream).await.unwrap();
                let value: Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(value["username"], user);
                assert_eq!(value["subject"], format!("subject-{user}"));
                assert_eq!(value["operation"], json!({"op":"read","path":path}));
                let response = if path == "destination.xlsx" {
                    json!({"result":{"document":"Zml4dHVyZQ=="}})
                } else {
                    json!({"error":format!("source denied for {user}")})
                };
                crate::office_io::send(&mut stream, response.to_string().as_bytes())
                    .await
                    .unwrap();
            }
        }
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), listener.accept())
                .await
                .is_err(),
            "a denied import must never publish a file"
        );
    });
    let call = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spreadsheet_edit","arguments":{
        "source_path":"destination.xlsx","source_revision":"0".repeat(64),"operations":[{"op":"import_rows","target":{"sheet":"Sales","table":"Data"},"source":{"path":"private.docx","revision":"0".repeat(64),"selector":{"table_index":0}}}]
    }}}).to_string();
    assert_eq!(
        app.clone()
            .oneshot(request(Method::POST, &call, None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    for user in ["alice", "bob"] {
        let response = app
            .clone()
            .oneshot(request(Method::POST, &call, Some(user)))
            .await
            .unwrap();
        let value: Value =
            serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        assert_eq!(value["result"]["isError"], true);
        assert_eq!(
            value["result"]["content"][0]["text"],
            format!("source denied for {user}")
        );
    }
    broker.await.unwrap();
    std::fs::remove_file(socket).unwrap();
}

#[tokio::test]
async fn office_discovery_and_file_requests_use_only_the_current_gateway_actor() {
    let socket =
        std::env::temp_dir().join(format!("office-gateway-test-{}.sock", std::process::id()));
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let mut server = app_server();
    Arc::make_mut(&mut server.config).office_socket = Some(socket.clone());
    let app = router(server.clone(), HOST);
    let response = app
        .clone()
        .oneshot(request(Method::POST, LIST, Some("alice")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 17);
    let broker = tokio::spawn(async move {
        for user in ["alice", "bob"] {
            let (mut stream, _) = listener.accept().await.unwrap();
            let bytes = crate::office_io::receive(&mut stream).await.unwrap();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["username"], user);
            assert_eq!(value["subject"], format!("subject-{user}"));
            assert_eq!(
                value["operation"],
                json!({"op":"read","path":"Reports/private.xlsx"})
            );
            crate::office_io::send(&mut stream, br#"{"error":"Fixture denies file access"}"#)
                .await
                .unwrap();
        }
    });
    let call = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spreadsheet_read","arguments":{"path":"Reports/private.xlsx"}}}).to_string();
    assert_eq!(
        app.clone()
            .oneshot(request(Method::POST, &call, None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    // Even a fully configured server exposes no private tools through TCP's
    // base handler, and forged headers cannot contact the file broker.
    let mut policy = crate::streamable_http_config(Some(HOST));
    policy.legacy_session_mode = false;
    let core = Router::new().fallback_service(StreamableHttpService::new(
        move || Ok(server.clone()),
        Arc::new(NeverSessionManager::default()),
        policy,
    ));
    let response = core
        .oneshot(request(Method::POST, &call, Some("forged")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert!(body["error"].is_object());
    for user in ["alice", "bob"] {
        let response = app
            .clone()
            .oneshot(request(Method::POST, &call, Some(user)))
            .await
            .unwrap();
        let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        assert_eq!(body["result"]["isError"], true);
        assert_eq!(
            body["result"]["content"][0]["text"],
            "Fixture denies file access"
        );
    }
    broker.await.unwrap();
    std::fs::remove_file(socket).unwrap();
}

fn app_server() -> crate::Server {
    let mut server = crate::tests::test_server();
    Arc::make_mut(&mut server.config).apps = crate::app_tools::Config {
        search_host: Some("search.example.test".into()),
        youtube_host: Some("ytdownload.example.test".into()),
        chat_host: Some("ai.example.test".into()),
    };
    server
}

#[tokio::test]
async fn private_tools_require_gateway_and_current_cookie_even_when_configured() {
    let app = router(app_server(), HOST);
    let mut list = request(Method::POST, LIST, Some("alice"));
    *list.uri_mut() = "/mcp".parse().unwrap();
    list.headers_mut()
        .insert("host", "ai.example.test".parse().unwrap());
    list.headers_mut()
        .insert("origin", "https://ai.example.test".parse().unwrap());
    let response = app.clone().oneshot(list).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 8);
    let mut wrong_port = request(Method::POST, LIST, Some("alice"));
    wrong_port
        .headers_mut()
        .insert("origin", "https://ai.example.test:444".parse().unwrap());
    assert_eq!(
        app.clone().oneshot(wrong_port).await.unwrap().status(),
        StatusCode::FORBIDDEN
    );

    let mut config = crate::streamable_http_config(Some(HOST));
    config.legacy_session_mode = false;
    let core = Router::new().fallback_service(StreamableHttpService::new(
        || Ok(app_server()),
        Arc::new(NeverSessionManager::default()),
        config,
    ));
    let response = core
        .clone()
        .oneshot(request(Method::POST, LIST, Some("forged")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 1);
    for name in [
        "document_search",
        "email_search",
        "youtube_search",
        "youtube_info",
        "youtube_download",
        "youtube_job",
        "youtube_jobs",
    ] {
        let body = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":name,"arguments":{"query":"test","username":"forged","cookie":"forged"}}}).to_string();
        let response = app
            .clone()
            .oneshot(request(Method::POST, &body, Some("alice")))
            .await
            .unwrap();
        let value: Value =
            serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        assert_eq!(
            value["error"]["message"],
            crate::app_tools::session_required().message.as_ref()
        );
        let mut forged = request(Method::POST, &body, Some("alice"));
        forged.headers_mut().insert(
            "cookie",
            "__Secure-nixhomeserver_sso=forged".parse().unwrap(),
        );
        let response = core.clone().oneshot(forged).await.unwrap();
        let value: Value =
            serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
        assert_eq!(value["error"]["code"], -32602);
        assert!(value["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("unknown tool:"));
    }
}

#[tokio::test]
async fn authenticated_video_search_uses_only_canonical_single_video_results() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let mock = Router::new().route("/search", axum::routing::get(|| async {
        axum::Json(json!({"results":[
            {"title":"Tutorial", "url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1", "content":"Video description"},
            {"title":"Same video", "url":"https://youtu.be/dQw4w9WgXcQ"},
            {"title":"Other host", "url":"https://evil.test/watch?v=dQw4w9WgXcQ"},
            {"title":"Playlist", "url":"https://www.youtube.com/playlist?list=PL1"}
        ]}))
    }));
    let task = tokio::spawn(async move { axum::serve(listener, mock).await.unwrap() });
    let mut server = app_server();
    Arc::make_mut(&mut server.config).searxng_base = format!("http://{address}");
    let app = router(server, HOST);
    let body = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"youtube_search","arguments":{"query":"repair tutorial"}}}).to_string();
    let mut req = request(Method::POST, &body, Some("alice"));
    req.headers_mut().insert(
        "cookie",
        "__Secure-nixhomeserver_sso=alice".parse().unwrap(),
    );
    let response = app.oneshot(req).await.unwrap();
    let value: Value = serde_json::from_str(&crate::tests::body_string(response).await).unwrap();
    let result: Value =
        serde_json::from_str(value["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(result["returned"], 1);
    assert_eq!(
        result["results"][0]["url"],
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    );
    task.abort();
}

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
