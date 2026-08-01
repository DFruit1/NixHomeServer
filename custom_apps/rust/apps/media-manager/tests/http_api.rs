use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::{AppConfig, IntegrationCapability, MutationMode},
    http::{router, AppState},
};
use serde_json::Value;
use tower::ServiceExt;

fn test_app(temp: &tempfile::TempDir) -> axum::Router {
    test_app_with_mode(temp, MutationMode::ReadOnly).0
}

fn test_app_with_mode(
    temp: &tempfile::TempDir,
    mutation_mode: MutationMode,
) -> (axum::Router, std::path::PathBuf) {
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.mutation_mode = mutation_mode;
    std::fs::create_dir_all(config.shared_root.join("_Videos")).expect("shared videos");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    (
        router(AppState {
            config,
            catalog: CatalogHandle::new(database.clone()),
        }),
        database,
    )
}

#[tokio::test]
async fn api_rejects_missing_forwarded_identity() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let response = test_app(&temp)
        .oneshot(
            Request::builder()
                .uri("/api/v1/session")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(value["error"]["code"], "identity_required");
}

#[tokio::test]
async fn viewer_can_read_roots_but_cannot_start_a_scan() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    let roots = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/roots")
                .header("x-forwarded-user", "viewer")
                .header("x-forwarded-groups", "users")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("roots response");
    assert_eq!(roots.status(), StatusCode::OK);

    let scan = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/scans")
                .header("content-type", "application/json")
                .header("x-forwarded-user", "viewer")
                .header("x-forwarded-groups", "users")
                .body(Body::from(r#"{"rootId":"shared-videos"}"#))
                .expect("request"),
        )
        .await
        .expect("scan response");
    assert_eq!(scan.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn editor_scan_populates_the_catalog() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("movie");
    let scan = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/scans")
                .header("content-type", "application/json")
                .header("x-forwarded-user", "editor")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::from(r#"{"rootId":"shared-videos"}"#))
                .expect("request"),
        )
        .await
        .expect("scan response");
    assert_eq!(scan.status(), StatusCode::OK);

    let items = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/items?rootId=shared-videos")
                .header("x-forwarded-user", "editor")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let value: Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(value["items"].as_array().expect("items").len(), 1);
}

#[tokio::test]
async fn frontend_assets_are_served_only_from_the_packaged_asset_directory() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let frontend = temp.path().join("frontend");
    std::fs::create_dir_all(frontend.join("assets")).expect("asset directory");
    std::fs::write(frontend.join("index.html"), "<main>Media Manager</main>").expect("index");
    std::fs::write(frontend.join("assets/app.css"), "body { color: white; }").expect("asset");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.frontend_dir = Some(frontend);
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });

    let asset = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/assets/app.css")
                .body(Body::empty())
                .expect("asset request"),
        )
        .await
        .expect("asset response");
    assert_eq!(asset.status(), StatusCode::OK);
    assert_eq!(asset.headers()["content-type"], "text/css; charset=utf-8");

    let traversal = app
        .oneshot(
            Request::builder()
                .uri("/assets/%2e%2e/index.html")
                .body(Body::empty())
                .expect("traversal request"),
        )
        .await
        .expect("traversal response");
    assert_ne!(traversal.status(), StatusCode::OK);
}

#[tokio::test]
async fn canonical_name_plan_is_catalog_backed_and_read_only_confirmation_fails_closed() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    std::fs::write(temp.path().join("shared/_Videos/Arrival.mkv"), b"movie").expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let items = app
        .clone()
        .oneshot(editor_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let items_json: Value = serde_json::from_slice(&body).expect("items JSON");
    let item_id = items_json["items"][0]["id"].as_str().expect("item ID");
    let plan_body = serde_json::json!({
        "operation": {
            "kind": "canonicalize_names",
            "title": "Arrival",
            "year": 2016
        },
        "itemIds": [item_id]
    })
    .to_string();
    let preview = app
        .clone()
        .oneshot(editor_post_request("/api/v1/plans", Body::from(plan_body)))
        .await
        .expect("preview response");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let preview_json: Value = serde_json::from_slice(&body).expect("preview JSON");
    assert_eq!(
        preview_json["actions"][0]["destinationRelativePath"],
        "Arrival (2016).mkv"
    );
    let plan_id = preview_json["id"].as_str().expect("plan ID");
    let digest = preview_json["digest"].as_str().expect("digest");

    let confirmation = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/plans/{plan_id}/confirm"))
                .header("x-forwarded-user", "editor")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .header("if-match", format!("\"{digest}\""))
                .body(Body::empty())
                .expect("confirmation request"),
        )
        .await
        .expect("confirmation response");
    assert_eq!(confirmation.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn tv_profile_builds_a_jellyfin_season_path_from_typed_fields() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    std::fs::write(
        temp.path().join("shared/_Videos/disk-3-title-2.mkv"),
        b"episode",
    )
    .expect("episode");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let item_id = first_item_id(&app, "shared-videos").await;
    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/plans",
            Body::from(
                serde_json::json!({
                    "operation": {
                        "kind": "canonicalize_names",
                        "profile": "tv",
                        "organizeFolders": true,
                        "title": "Example Show",
                        "season": 1,
                        "episode": 7,
                        "episodeTitle": "The Return"
                    },
                    "itemIds": [item_id]
                })
                .to_string(),
            ),
        ))
        .await
        .expect("preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(
        value["actions"][0]["destinationRelativePath"],
        "Example Show/Season 01/Example Show - S01E07 - The Return.mkv"
    );
}

#[tokio::test]
async fn music_profile_builds_an_artist_album_and_disc_track_path() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Music")).expect("music root");
    std::fs::write(temp.path().join("shared/_Music/incoming.mp3"), b"track").expect("track");
    let app = test_app(&temp);
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = first_item_id(&app, "shared-music").await;
    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/plans",
            Body::from(
                serde_json::json!({
                    "operation": {
                        "kind": "canonicalize_names",
                        "profile": "music",
                        "organizeFolders": true,
                        "title": "Third Track",
                        "artist": "Example Artist",
                        "album": "Example Album",
                        "year": 1999,
                        "disc": 2,
                        "track": 3
                    },
                    "itemIds": [item_id]
                })
                .to_string(),
            ),
        ))
        .await
        .expect("preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(
        value["actions"][0]["destinationRelativePath"],
        "Example Artist/Example Album (1999)/2-03 - Third Track.mp3"
    );
}

#[tokio::test]
async fn book_profile_builds_an_author_series_and_title_path() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Books")).expect("books root");
    std::fs::write(temp.path().join("shared/_Books/import.epub"), b"book").expect("book");
    let app = test_app(&temp);
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-books"}"#).await;
    let item_id = first_item_id(&app, "shared-books").await;
    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/plans",
            Body::from(
                serde_json::json!({
                    "operation": {
                        "kind": "canonicalize_names",
                        "profile": "book",
                        "organizeFolders": true,
                        "title": "The Book",
                        "author": "An Author",
                        "series": "A Series"
                    },
                    "itemIds": [item_id]
                })
                .to_string(),
            ),
        ))
        .await
        .expect("preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(
        value["actions"][0]["destinationRelativePath"],
        "An Author/A Series/The Book/The Book.epub"
    );
}

#[tokio::test]
async fn enabled_confirmation_queues_exactly_the_previewed_plan() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, database) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let items = app
        .clone()
        .oneshot(editor_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let items_json: Value = serde_json::from_slice(&body).expect("items JSON");
    let item_id = items_json["items"][0]["id"].as_str().expect("item ID");
    let plan_body = serde_json::json!({
        "operation": { "kind": "canonicalize_names", "title": "Canonical Movie" },
        "itemIds": [item_id]
    })
    .to_string();
    let preview = app
        .clone()
        .oneshot(editor_post_request("/api/v1/plans", Body::from(plan_body)))
        .await
        .expect("preview response");
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let preview_json: Value = serde_json::from_slice(&body).expect("preview JSON");
    let plan_id = preview_json["id"].as_str().expect("plan ID");
    let digest = preview_json["digest"].as_str().expect("digest");

    let confirmation = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/plans/{plan_id}/confirm"))
                .header("x-forwarded-user", "editor")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .header("if-match", format!("\"{digest}\""))
                .body(Body::empty())
                .expect("confirmation request"),
        )
        .await
        .expect("confirmation response");
    assert_eq!(confirmation.status(), StatusCode::ACCEPTED);
    assert_eq!(
        Catalog::open(&database)
            .expect("catalog")
            .mutation_plan_state(plan_id)
            .expect("plan state"),
        Some("queued".to_string())
    );
}

#[tokio::test]
async fn subtitle_upload_creates_an_editor_bound_no_overwrite_preview() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, database) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Movies")).expect("movie folder");
    std::fs::write(
        temp.path().join("shared/_Videos/Movies/Arrival (2016).mkv"),
        b"movie",
    )
    .expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let items = app
        .clone()
        .oneshot(editor_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let items_json: Value = serde_json::from_slice(&body).expect("items JSON");
    let item_id = items_json["items"][0]["id"].as_str().expect("item ID");

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!(
                    "/api/v1/items/{item_id}/subtitles/upload?language=en"
                ))
                .header("content-type", "application/x-subrip")
                .header("x-forwarded-user", "editor")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::from("1\n00:00:01,000 --> 00:00:02,000\nHello\n"))
                .expect("upload request"),
        )
        .await
        .expect("upload response");
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let preview: Value = serde_json::from_slice(&body).expect("preview JSON");
    assert_eq!(preview["actions"][0]["kind"], "install_subtitle");
    assert_eq!(
        preview["actions"][0]["destinationRelativePath"],
        "Movies/Arrival (2016).en.srt"
    );
    let plan_id = preview["id"].as_str().expect("plan ID");
    assert_eq!(
        Catalog::open(&database)
            .expect("catalog")
            .mutation_plan_state(plan_id)
            .expect("plan state"),
        Some("previewed".to_string())
    );
    assert_eq!(
        std::fs::read_dir(temp.path().join("state/provider-staging"))
            .expect("staging directory")
            .count(),
        1
    );
}

#[tokio::test]
async fn metadata_fields_create_an_opf_sidecar_preview_without_a_default_year() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::create_dir_all(temp.path().join("shared/_Audiobooks/Author/Book"))
        .expect("book folder");
    std::fs::write(
        temp.path().join("shared/_Audiobooks/Author/Book/Book.m4b"),
        b"audio",
    )
    .expect("audio file");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-audiobooks"}"#).await;
    let items = app
        .clone()
        .oneshot(editor_get_request("/api/v1/items?rootId=shared-audiobooks"))
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let items_json: Value = serde_json::from_slice(&body).expect("items JSON");
    let item_id = items_json["items"][0]["id"].as_str().expect("item ID");
    let preview = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/sidecar"),
            Body::from(
                serde_json::json!({
                    "title": "The Book",
                    "authors": ["An Author"],
                    "narrators": ["A Narrator"],
                    "language": "en",
                    "genres": ["History"]
                })
                .to_string(),
            ),
        ))
        .await
        .expect("metadata preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("preview JSON");
    assert_eq!(value["actions"][0]["kind"], "install_metadata_sidecar");
    assert_eq!(
        value["actions"][0]["destinationRelativePath"],
        "Author/Book/metadata.opf"
    );
    let staged = std::fs::read_dir(temp.path().join("state/provider-staging"))
        .expect("staging")
        .next()
        .expect("staged entry")
        .expect("staged file")
        .path();
    let opf = std::fs::read_to_string(staged).expect("staged OPF");
    assert!(opf.contains("<dc:title>The Book</dc:title>"));
    assert!(!opf.contains("<dc:date>"));
}

#[tokio::test]
async fn manual_refresh_queues_only_a_registered_available_adapter() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.integrations = vec![IntegrationCapability {
        id: "jellyfin".to_string(),
        label: "Jellyfin".to_string(),
        available: true,
        capabilities: vec!["library-refresh".to_string()],
    }];
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    let response = app
        .oneshot(editor_post_request(
            "/api/v1/integrations/jellyfin/refresh",
            Body::empty(),
        ))
        .await
        .expect("refresh response");
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    assert!(temp
        .path()
        .join("state/refresh-requests/jellyfin.request")
        .is_file());
}

fn editor_get_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("x-forwarded-user", "editor")
        .header("x-forwarded-groups", "users,media-manager-editors")
        .body(Body::empty())
        .expect("editor request")
}

fn editor_post_request(uri: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-user", "editor")
        .header("x-forwarded-groups", "users,media-manager-editors")
        .body(body)
        .expect("editor request")
}

async fn editor_json_request(app: &axum::Router, uri: &str, body: &'static str) {
    let response = app
        .clone()
        .oneshot(editor_post_request(uri, Body::from(body)))
        .await
        .expect("editor response");
    assert_eq!(response.status(), StatusCode::OK);
}

async fn first_item_id(app: &axum::Router, root_id: &str) -> String {
    let response = app
        .clone()
        .oneshot(editor_get_request(&format!(
            "/api/v1/items?rootId={root_id}"
        )))
        .await
        .expect("items response");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("items body");
    let value: Value = serde_json::from_slice(&body).expect("items JSON");
    value["items"][0]["id"]
        .as_str()
        .expect("first item ID")
        .to_string()
}
