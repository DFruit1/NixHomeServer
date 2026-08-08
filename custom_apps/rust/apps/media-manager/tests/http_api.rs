use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use image::ImageEncoder;
use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::{AppConfig, IntegrationCapability, MutationMode},
    http::{router, AppState, JellyfinImageCache},
};
use serde_json::Value;
use std::{os::unix::fs::PermissionsExt, sync::Arc};
use tower::ServiceExt;

fn one_pixel_png() -> Vec<u8> {
    let mut bytes = Vec::new();
    image::codecs::png::PngEncoder::new(&mut bytes)
        .write_image(&[28, 86, 42, 255], 1, 1, image::ExtendedColorType::Rgba8)
        .expect("encode test PNG");
    bytes
}

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
async fn session_prefers_the_canonical_forwarded_username_over_the_oidc_subject() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let response = test_app(&temp)
        .oneshot(
            Request::builder()
                .uri("/api/v1/session")
                .header("x-forwarded-user", "4689a2b2-62ba-4131-bc32-4cca2ca7859c")
                .header("x-forwarded-preferred-username", "dsaw")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(value["username"], "dsaw");
    assert_eq!(value["canEdit"], true);
}

#[tokio::test]
async fn preferred_username_owns_personal_roots_and_audit_events() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("users/dsaw/_Videos")).expect("personal videos root");
    let (app, database) = test_app_with_mode(&temp, MutationMode::ReadOnly);
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("shared video");

    let roots = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/roots")
                .header("x-forwarded-user", "4689a2b2-62ba-4131-bc32-4cca2ca7859c")
                .header("x-forwarded-preferred-username", "dsaw")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("roots response");
    let body = to_bytes(roots.into_body(), 64 * 1024)
        .await
        .expect("roots body");
    let value: Value = serde_json::from_slice(&body).expect("roots json");
    let personal_videos = value
        .as_array()
        .expect("roots array")
        .iter()
        .find(|root| root["id"] == "personal-videos")
        .expect("personal videos root");
    assert_eq!(personal_videos["available"], true);

    let scan = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/scans")
                .header("content-type", "application/json")
                .header("x-forwarded-user", "4689a2b2-62ba-4131-bc32-4cca2ca7859c")
                .header("x-forwarded-preferred-username", "dsaw")
                .header("x-forwarded-groups", "users,media-manager-editors")
                .body(Body::from(r#"{"rootId":"shared-videos"}"#))
                .expect("request"),
        )
        .await
        .expect("scan response");
    assert_eq!(scan.status(), StatusCode::OK);

    let connection = rusqlite::Connection::open(database).expect("catalog database");
    let actor: String = connection
        .query_row(
            "SELECT actor_username FROM audit_events WHERE event_kind = 'catalog_root_scanned'",
            [],
            |row| row.get(0),
        )
        .expect("scan audit actor");
    assert_eq!(actor, "dsaw");
}

#[tokio::test]
async fn malformed_preferred_username_is_rejected_instead_of_falling_back() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let malformed = axum::http::HeaderValue::from_bytes(&[0xff]).expect("opaque header value");
    let response = test_app(&temp)
        .oneshot(
            Request::builder()
                .uri("/api/v1/session")
                .header("x-forwarded-user", "fallback-user")
                .header("x-forwarded-preferred-username", malformed)
                .header("x-forwarded-groups", "users")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn empty_preferred_username_uses_the_legacy_forwarded_user() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let response = test_app(&temp)
        .oneshot(
            Request::builder()
                .uri("/api/v1/session")
                .header("x-forwarded-user", "legacy-user")
                .header("x-forwarded-preferred-username", "  ")
                .header("x-forwarded-groups", "users")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(value["username"], "legacy-user");
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
async fn viewer_first_read_populates_an_unscanned_catalog() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("movie");

    let items = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/items?rootId=shared-videos")
                .header("x-forwarded-user", "viewer")
                .header("x-forwarded-groups", "users")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("items response");

    assert_eq!(items.status(), StatusCode::OK);
    let body = to_bytes(items.into_body(), 64 * 1024)
        .await
        .expect("items body");
    let value: Value = serde_json::from_slice(&body).expect("items json");
    let catalog_items = value["items"].as_array().expect("items array");
    assert_eq!(catalog_items.len(), 1);
    assert_eq!(catalog_items[0]["relativePath"], "Movie.mkv");
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
async fn subtitle_content_preview_requires_provider_credentials() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::ReadOnly);
    std::fs::create_dir_all(temp.path().join("shared/_Videos")).expect("movie folder");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie.mkv"),
        b"movie",
    )
    .expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let item_id = first_item_id(&app, "shared-videos").await;

    let response = app
        .oneshot(editor_get_request(&format!(
            "/api/v1/items/{item_id}/subtitles/provider/123/content"
        )))
        .await
        .expect("content response");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(value["error"]["code"], "subtitle_provider_unconfigured");
}

#[tokio::test]
async fn subtitle_content_preview_rejects_non_positive_file_ids() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::ReadOnly);
    std::fs::create_dir_all(temp.path().join("shared/_Videos")).expect("movie folder");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie.mkv"),
        b"movie",
    )
    .expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let item_id = first_item_id(&app, "shared-videos").await;

    let response = app
        .oneshot(editor_get_request(&format!(
            "/api/v1/items/{item_id}/subtitles/provider/0/content"
        )))
        .await
        .expect("content response");
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(value["error"]["code"], "invalid_provider_file_id");
}

#[tokio::test]
async fn subtitle_content_preview_requires_a_video_item() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::ReadOnly);
    std::fs::create_dir_all(temp.path().join("shared/_Audiobooks/Author/Book"))
        .expect("book folder");
    std::fs::write(
        temp.path().join("shared/_Audiobooks/Author/Book/Book.m4b"),
        b"audio",
    )
    .expect("audio file");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-audiobooks"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-audiobooks", "audiobook").await;

    let response = app
        .oneshot(editor_get_request(&format!(
            "/api/v1/items/{item_id}/subtitles/provider/123/content"
        )))
        .await
        .expect("content response");
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(value["error"]["code"], "video_item_required");
}

#[tokio::test]
async fn items_without_ffprobe_report_no_probe_pending() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::ReadOnly);
    std::fs::create_dir_all(temp.path().join("shared/_Videos")).expect("movie folder");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie.mkv"),
        b"movie",
    )
    .expect("movie");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;

    let response = app
        .oneshot(editor_get_request(
            "/api/v1/items?rootId=shared-videos&includeVideoProbes=true",
        ))
        .await
        .expect("items response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(value["probePending"], false);
    assert!(value["items"][0].get("videoProbe").is_none());
}

#[tokio::test]
async fn items_report_unprobeable_videos_as_null_probes() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.ffprobe_path = Some(temp.path().join("definitely-not-ffprobe"));
    std::fs::create_dir_all(config.shared_root.join("_Videos")).expect("movie folder");
    std::fs::write(config.shared_root.join("_Videos/Movie.mkv"), b"movie").expect("movie");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;

    let response = app
        .oneshot(editor_get_request(
            "/api/v1/items?rootId=shared-videos&includeVideoProbes=true",
        ))
        .await
        .expect("items response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("JSON");
    assert_eq!(value["probePending"], false);
    let video = value["items"]
        .as_array()
        .expect("items array")
        .iter()
        .find(|item| item["mediaKind"] == "video")
        .expect("video item");
    assert_eq!(video["videoProbe"], Value::Null);
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
                    "mediaType": "audiobook",
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
async fn episode_metadata_creates_a_jellyfin_compatible_episode_nfo() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    let episode = temp.path().join("shared/_Videos/_Shows/Open All Hours (1976)/Season 00/Open All Hours (1976) - S00E01 - Pilot.mkv");
    std::fs::create_dir_all(episode.parent().expect("episode parent")).expect("show folder");
    std::fs::write(&episode, b"video").expect("episode file");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let items = app
        .clone()
        .oneshot(editor_get_request("/api/v1/items?rootId=shared-videos"))
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
                    "mediaType": "episode", "title": "Pilot", "series": "Open All Hours",
                    "season": 0, "episode": 1, "episodeTitle": "Pilot", "year": 1973,
                    "premiereDate": "1973-03-24", "runtimeMinutes": 30,
                    "officialRating": "TV-PG", "communityRating": 10.0,
                    "writers": ["Roy Clarke"], "genres": ["Comedy"],
                    "providerIds": {"tmdb": "123"}
                })
                .to_string(),
            ),
        ))
        .await
        .expect("metadata preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let staged = std::fs::read_dir(temp.path().join("state/provider-staging"))
        .expect("staging")
        .next()
        .expect("staged entry")
        .expect("staged file")
        .path();
    let nfo = std::fs::read_to_string(staged).expect("staged NFO");
    for expected in [
        "<episodedetails>",
        "<showtitle>Open All Hours</showtitle>",
        "<season>0</season>",
        "<episode>1</episode>",
        "<title>Pilot</title>",
        "<premiered>1973-03-24</premiered>",
        "<runtime>30</runtime>",
        "<writer>Roy Clarke</writer>",
        "<uniqueid type=\"tmdb\">123</uniqueid>",
    ] {
        assert!(nfo.contains(expected), "missing {expected} in {nfo}");
    }
}

#[tokio::test]
async fn metadata_details_merge_filename_fields_with_a_bounded_jellyfin_snapshot() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    let cache = temp.path().join("jellyfin-metadata.json");
    config.jellyfin_metadata_cache_file = Some(cache.clone());
    let episode_relative =
        "_Shows/Open All Hours (1976)/Season 00/Open All Hours (1976) - S00E01 - Pilot.mkv";
    let episode = config.shared_root.join("_Videos").join(episode_relative);
    std::fs::create_dir_all(episode.parent().expect("episode parent")).expect("show folder");
    std::fs::write(&episode, b"video").expect("episode file");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    let items = app
        .clone()
        .oneshot(viewer_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(items.into_body(), 64 * 1024).await.expect("body");
    let items_json: Value = serde_json::from_slice(&body).expect("items JSON");
    let item_id = items_json["items"][0]["id"].as_str().expect("item ID");
    std::fs::write(&cache, serde_json::json!({
        "schemaVersion": 1,
        "entries": [{
            "rootId": "shared-videos", "ownerUsername": null, "relativePath": episode_relative,
            "mediaType": "episode", "title": "Pilot", "series": "Open All Hours",
            "season": 0, "episode": 1, "episodeTitle": "Pilot",
            "description": "Episode 1 of the Ronnie Barker anthology series of pilots, Seven of One.",
            "premiereDate": "1973-03-24T00:00:00.0000000Z", "runtimeMinutes": 30,
            "communityRating": 10.0, "writers": ["Roy Clarke"], "providerIds": {"Tmdb": "123"},
            "videoStreams": [{"height": 576, "codec": "h264", "videoRange": "SDR"}],
            "audioStreams": [{"language": "eng", "codec": "aac", "channelLayout": "stereo"}]
        }]
    }).to_string()).expect("metadata cache");

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{item_id}/metadata"
        )))
        .await
        .expect("metadata response");
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let metadata: Value = serde_json::from_slice(&body).expect("metadata JSON");
    assert_eq!(metadata["series"], "Open All Hours");
    assert_eq!(metadata["season"], 0);
    assert_eq!(metadata["episode"], 1);
    assert_eq!(metadata["runtimeMinutes"], 30);
    assert_eq!(metadata["videoStreams"][0]["height"], 576);
    assert_eq!(
        metadata["sources"],
        serde_json::json!(["filename", "jellyfin"])
    );
}

#[tokio::test]
async fn authenticated_viewer_can_queue_and_follow_a_registered_refresh() {
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
        .clone()
        .oneshot(viewer_post_request(
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

    let response = app
        .oneshot(viewer_get_request("/api/v1/integrations/jellyfin/refresh"))
        .await
        .expect("refresh status response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("refresh status body");
    let value: Value = serde_json::from_slice(&body).expect("refresh status JSON");
    assert_eq!(value["integrationId"], "jellyfin");
    assert_eq!(value["state"], "queued");
    assert!(value["requestId"].as_str().is_some_and(|id| !id.is_empty()));
}

#[tokio::test]
async fn authenticated_viewer_can_queue_a_registered_kavita_refresh() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.integrations = vec![IntegrationCapability {
        id: "kavita".to_string(),
        label: "Kavita".to_string(),
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
        .oneshot(viewer_post_request(
            "/api/v1/integrations/kavita/refresh",
            Body::empty(),
        ))
        .await
        .expect("refresh response");

    assert_eq!(response.status(), StatusCode::ACCEPTED);
    assert!(temp
        .path()
        .join("state/refresh-requests/kavita.request")
        .is_file());
}

#[tokio::test]
async fn refresh_status_returns_the_durable_terminal_result() {
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
    std::fs::create_dir_all(config.state_dir.join("refresh-results"))
        .expect("refresh results directory");
    std::fs::write(
        config.state_dir.join("refresh-results/jellyfin.json"),
        serde_json::json!({
            "schemaVersion": 1,
            "integrationId": "jellyfin",
            "state": "succeeded",
            "requestId": "r123-1",
            "queuedAt": 1,
            "startedAt": 2,
            "finishedAt": 3,
            "message": "Jellyfin library scan completed."
        })
        .to_string(),
    )
    .expect("refresh result");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });

    let response = app
        .oneshot(viewer_get_request("/api/v1/integrations/jellyfin/refresh"))
        .await
        .expect("refresh status response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("refresh status body");
    let value: Value = serde_json::from_slice(&body).expect("refresh status JSON");
    assert_eq!(value["state"], "succeeded");
    assert_eq!(value["finishedAt"], 3);
    assert_eq!(value["message"], "Jellyfin library scan completed.");
}

#[tokio::test]
async fn iso_inbox_is_not_a_library_root() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_ISO/_DVDs")).expect("iso inbox");
    let app = test_app(&temp);

    let roots = app
        .clone()
        .oneshot(viewer_get_request("/api/v1/roots"))
        .await
        .expect("roots response");
    let body = to_bytes(roots.into_body(), 64 * 1024)
        .await
        .expect("roots body");
    let value: Value = serde_json::from_slice(&body).expect("roots json");
    let ids: Vec<&str> = value
        .as_array()
        .expect("roots array")
        .iter()
        .filter_map(|root| root["id"].as_str())
        .collect();
    assert!(!ids.contains(&"shared-dvd-inbox"));

    let items = app
        .oneshot(viewer_get_request("/api/v1/items?rootId=shared-dvd-inbox"))
        .await
        .expect("items response");
    assert_eq!(items.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn conversions_inbox_lists_iso_groups_with_identification() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let inbox = temp.path().join("shared/_ISO/_DVDs");
    std::fs::create_dir_all(inbox.join("_Processed")).expect("processed");
    std::fs::create_dir_all(inbox.join("_Failed")).expect("failed");
    std::fs::write(inbox.join("MOVIE_DISC.ISO"), test_iso("EXAMPLE_MOVIE")).expect("pending iso");
    std::fs::write(inbox.join("notes.txt"), b"not an iso").expect("non-iso file");
    std::fs::write(
        inbox.join("_Processed/OLD_MOVIE.ISO"),
        test_iso("OLD_MOVIE"),
    )
    .expect("processed iso");
    std::fs::write(inbox.join("_Failed/BROKEN_DISC.ISO"), b"tiny").expect("failed iso");
    let app = test_app(&temp);

    let response = app
        .oneshot(viewer_get_request("/api/v1/conversions/inbox"))
        .await
        .expect("inbox response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("inbox body");
    let value: Value = serde_json::from_slice(&body).expect("inbox json");
    assert_eq!(value["available"], true);
    let pending = value["pending"].as_array().expect("pending array");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0]["name"], "MOVIE_DISC.ISO");
    assert_eq!(pending[0]["volumeId"], "EXAMPLE_MOVIE");
    assert_eq!(pending[0]["sizeBytes"], 17 * 2048);
    assert!(pending[0]["modifiedNs"].as_i64().unwrap_or(0) > 0);
    let processed = value["processed"].as_array().expect("processed array");
    assert_eq!(processed.len(), 1);
    assert_eq!(processed[0]["volumeId"], "OLD_MOVIE");
    let failed = value["failed"].as_array().expect("failed array");
    assert_eq!(failed.len(), 1);
    assert_eq!(failed[0]["name"], "BROKEN_DISC.ISO");
    assert!(failed[0]["volumeId"].is_null());
}

#[tokio::test]
async fn conversions_inbox_reports_unavailable_without_directory() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);

    let response = app
        .oneshot(viewer_get_request("/api/v1/conversions/inbox"))
        .await
        .expect("inbox response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("inbox body");
    let value: Value = serde_json::from_slice(&body).expect("inbox json");
    assert_eq!(value["available"], false);
    assert_eq!(value["pending"].as_array().expect("pending").len(), 0);
}

#[tokio::test]
async fn item_image_serves_sibling_cover_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Movie (2020)")).expect("movie dir");
    std::fs::write(
        temp.path()
            .join("shared/_Videos/Movie (2020)/Movie (2020).mkv"),
        b"movie",
    )
    .expect("movie");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie (2020)/cover.jpg"),
        b"jpeg-bytes",
    )
    .expect("cover");
    let app = test_app(&temp);

    let response = app
        .clone()
        .oneshot(viewer_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("items body");
    let value: Value = serde_json::from_slice(&body).expect("items json");
    let items = value["items"].as_array().expect("items array");
    assert_eq!(items.len(), 2);
    let movie_id = items
        .iter()
        .find(|item| item["mediaKind"] == "video")
        .and_then(|item| item["id"].as_str())
        .expect("movie item id");
    let cover_id = items
        .iter()
        .find(|item| item["mediaKind"] == "artwork")
        .and_then(|item| item["id"].as_str())
        .expect("cover item id");

    for id in [movie_id, cover_id] {
        let response = app
            .clone()
            .oneshot(viewer_get_request(&format!("/api/v1/items/{id}/image")))
            .await
            .expect("image response");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok()),
            Some("image/jpeg")
        );
        let body = to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("image body");
        assert_eq!(body.as_ref(), b"jpeg-bytes");
    }
}

#[tokio::test]
async fn item_image_prefers_title_specific_jellyfin_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Videos")).expect("video directory");
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("movie");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie-poster.jpg"),
        b"movie-poster",
    )
    .expect("movie poster");
    std::fs::write(
        temp.path().join("shared/_Videos/folder.jpg"),
        b"root-folder-art",
    )
    .expect("folder artwork");
    let app = test_app(&temp);
    let movie_id = item_id_by_kind(&app, "shared-videos", "video").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{movie_id}/image"
        )))
        .await
        .expect("image response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    assert_eq!(body.as_ref(), b"movie-poster");
}

#[tokio::test]
async fn item_image_uses_jellyfin_default_artwork_for_an_mkv_without_embedded_art() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Movie")).expect("movie directory");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie/Movie.mkv"),
        b"mkv-without-art",
    )
    .expect("movie");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie/default.jpg"),
        b"jellyfin-default-art",
    )
    .expect("default art");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie/aaa-scan.jpg"),
        b"unrelated-image",
    )
    .expect("unrelated image");
    let app = test_app(&temp);
    let movie_id = item_id_by_kind(&app, "shared-videos", "video").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{movie_id}/image"
        )))
        .await
        .expect("image response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    assert_eq!(body.as_ref(), b"jellyfin-default-art");
}

#[tokio::test]
async fn folder_metadata_uses_folder_identity_and_previews_a_season_sidecar() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    let season = temp
        .path()
        .join("shared/_Videos/_Shows/Example Show/Season 01");
    std::fs::create_dir_all(&season).expect("season directory");
    std::fs::write(season.join("Episode.mkv"), b"video").expect("episode");

    let response = app
        .clone()
        .oneshot(viewer_get_request(
            "/api/v1/folders/metadata?rootId=shared-videos&relativePath=_Shows%2FExample%20Show%2FSeason%2001",
        ))
        .await
        .expect("folder metadata response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("folder metadata body");
    let metadata: Value = serde_json::from_slice(&body).expect("folder metadata JSON");
    assert_eq!(metadata["mediaType"], "season");
    assert_eq!(metadata["title"], "Season 01");
    assert_eq!(metadata["sources"][0], "folder");

    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/folders/metadata/sidecar?rootId=shared-videos&relativePath=_Shows%2FExample%20Show%2FSeason%2001",
            Body::from(
                serde_json::json!({
                    "mediaType": "season",
                    "title": "Season 1",
                    "description": "The first season",
                    "language": "en"
                })
                .to_string(),
            ),
        ))
        .await
        .expect("folder metadata preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("preview body");
    let value: Value = serde_json::from_slice(&body).expect("preview JSON");
    assert_eq!(value["actions"][0]["kind"], "install_metadata_sidecar");
    assert_eq!(
        value["actions"][0]["destinationRelativePath"],
        "_Shows/Example Show/Season 01/season.nfo"
    );
}

#[tokio::test]
async fn folder_metadata_splits_a_trailing_year_from_a_movie_folder() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let movie = temp
        .path()
        .join("shared/_Videos/_Movies/Example Film (2024)");
    std::fs::create_dir_all(&movie).expect("movie directory");
    std::fs::write(movie.join("Example Film (2024).mkv"), b"movie").expect("movie file");
    let app = test_app(&temp);

    let response = app
        .oneshot(viewer_get_request(
            "/api/v1/folders/metadata?rootId=shared-videos&relativePath=_Movies%2FExample%20Film%20%282024%29",
        ))
        .await
        .expect("folder metadata response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("folder metadata body");
    let metadata: Value = serde_json::from_slice(&body).expect("folder metadata JSON");
    assert_eq!(metadata["title"], "Example Film");
    assert_eq!(metadata["year"], 2024);
}

#[tokio::test]
async fn folder_metadata_recognizes_seasons_without_a_shows_collection_prefix() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    let season = temp.path().join("shared/_Videos/Example Show/Season 02");
    std::fs::create_dir_all(&season).expect("season directory");
    std::fs::write(season.join("Episode.mkv"), b"video").expect("episode");

    let response = app
        .clone()
        .oneshot(viewer_get_request(
            "/api/v1/folders/metadata?rootId=shared-videos&relativePath=Example%20Show%2FSeason%2002",
        ))
        .await
        .expect("folder metadata response");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("folder metadata body");
    let metadata: Value = serde_json::from_slice(&body).expect("folder metadata JSON");
    assert_eq!(metadata["mediaType"], "season");
    assert_eq!(metadata["season"], 2);

    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/folders/metadata/sidecar?rootId=shared-videos&relativePath=Example%20Show%2FSeason%2002",
            Body::from(r#"{"mediaType":"season","title":"Season 2"}"#),
        ))
        .await
        .expect("season sidecar preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("preview body");
    let preview: Value = serde_json::from_slice(&body).expect("preview JSON");
    assert_eq!(
        preview["actions"][0]["destinationRelativePath"],
        "Example Show/Season 02/season.nfo"
    );
}

#[tokio::test]
async fn grouping_folders_are_selectable_but_cannot_receive_media_sidecars() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::create_dir_all(temp.path().join("shared/_Videos/_Movies/Film"))
        .expect("movie grouping");
    std::fs::write(
        temp.path().join("shared/_Videos/_Movies/Film/Film.mkv"),
        b"movie",
    )
    .expect("movie file");

    let response = app
        .clone()
        .oneshot(viewer_get_request(
            "/api/v1/folders/metadata?rootId=shared-videos&relativePath=_Movies",
        ))
        .await
        .expect("collection metadata response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("collection metadata body");
    let metadata: Value = serde_json::from_slice(&body).expect("collection metadata JSON");
    assert_eq!(metadata["mediaType"], "collection");

    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/folders/metadata/sidecar?rootId=shared-videos&relativePath=_Movies",
            Body::from(r#"{"mediaType":"collection","title":"Movies"}"#),
        ))
        .await
        .expect("collection sidecar response");
    assert_eq!(preview.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn music_folders_with_tracks_preview_album_sidecars() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    let album = temp.path().join("shared/_Music/Artist/Album");
    std::fs::create_dir_all(&album).expect("album directory");
    std::fs::write(album.join("Track.flac"), b"track").expect("track");

    let response = app
        .clone()
        .oneshot(viewer_get_request(
            "/api/v1/folders/metadata?rootId=shared-music&relativePath=Artist%2FAlbum",
        ))
        .await
        .expect("album metadata response");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("album metadata body");
    let metadata: Value = serde_json::from_slice(&body).expect("album metadata JSON");
    assert_eq!(metadata["mediaType"], "music");

    let preview = app
        .oneshot(editor_post_request(
            "/api/v1/folders/metadata/sidecar?rootId=shared-music&relativePath=Artist%2FAlbum",
            Body::from(r#"{"mediaType":"music","title":"Album"}"#),
        ))
        .await
        .expect("album sidecar preview");
    assert_eq!(preview.status(), StatusCode::CREATED);
    let body = to_bytes(preview.into_body(), 64 * 1024)
        .await
        .expect("album preview body");
    let preview: Value = serde_json::from_slice(&body).expect("album preview JSON");
    assert_eq!(
        preview["actions"][0]["destinationRelativePath"],
        "Artist/Album/album.nfo"
    );
}

#[tokio::test]
async fn artwork_replacement_previews_one_recoverable_broker_action() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    let movie = temp.path().join("shared/_Videos/Movie");
    std::fs::create_dir_all(&movie).expect("movie directory");
    std::fs::write(movie.join("Movie.mkv"), b"movie").expect("movie");
    std::fs::write(movie.join("cover.jpg"), b"old-cover").expect("old cover");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let cover_id = item_id_by_kind(&app, "shared-videos", "artwork").await;

    let corrupt = app
        .clone()
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{cover_id}/image/replacement?format=png"),
            Body::from(b"\x89PNG\r\n\x1a\nnot-an-image".to_vec()),
        ))
        .await
        .expect("corrupt artwork response");
    assert_eq!(corrupt.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);

    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{cover_id}/image/replacement?format=png"),
            Body::from(one_pixel_png()),
        ))
        .await
        .expect("artwork replacement preview");
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("preview body");
    let preview: Value = serde_json::from_slice(&body).expect("preview JSON");
    let actions = preview["actions"].as_array().expect("actions");
    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0]["kind"], "replace_artwork");
    assert!(actions[0]["destinationRelativePath"].is_null());
    assert!(actions[0]["archivedRelativePath"]
        .as_str()
        .expect("archive path")
        .contains("superseded/cover-"));
    assert_eq!(actions[0]["replacementRelativePath"], "Movie/cover.png");
}

#[tokio::test]
async fn unauthenticated_artwork_upload_is_rejected_before_reading_a_large_body() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let body = vec![0_u8; 32 * 1024 * 1024 + 2048];
    let response = test_app(&temp)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/items/not-visible/image/replacement?format=png")
                .body(Body::from(body))
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn item_image_falls_back_to_jellyfin_artwork_in_an_ancestor_folder() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Show/Season 01"))
        .expect("season directory");
    std::fs::write(
        temp.path()
            .join("shared/_Videos/Show/Season 01/Episode.mkv"),
        b"episode",
    )
    .expect("episode");
    std::fs::write(
        temp.path().join("shared/_Videos/Show/Show-default.jpg"),
        b"series-poster",
    )
    .expect("series poster");
    std::fs::write(
        temp.path()
            .join("shared/_Videos/Show/Season 01/aaa-scan.jpg"),
        b"unrelated-season-image",
    )
    .expect("unrelated season image");
    let app = test_app(&temp);
    let episode_id = first_item_id(&app, "shared-videos").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{episode_id}/image"
        )))
        .await
        .expect("image response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    assert_eq!(body.as_ref(), b"series-poster");
}

#[tokio::test]
async fn item_image_serves_embedded_audio_cover_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Music/Album")).expect("album directory");
    std::fs::write(
        temp.path().join("shared/_Music/Album/Track.mp3"),
        mp3_with_embedded_artwork("image/jpeg", b"embedded-cover"),
    )
    .expect("tagged audio");
    let app = test_app(&temp);
    let track_id = first_item_id(&app, "shared-music").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{track_id}/image"
        )))
        .await
        .expect("image response");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok()),
        Some("image/jpeg")
    );
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    assert_eq!(body.as_ref(), b"embedded-cover");
}

#[tokio::test]
async fn item_image_serves_embedded_webp_cover_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Music/Album")).expect("album directory");
    std::fs::write(
        temp.path().join("shared/_Music/Album/Track.mp3"),
        mp3_with_embedded_artwork("image/webp", b"webp-cover"),
    )
    .expect("tagged audio");
    let app = test_app(&temp);
    let track_id = first_item_id(&app, "shared-music").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{track_id}/image"
        )))
        .await
        .expect("image response");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok()),
        Some("image/webp")
    );
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    assert_eq!(body.as_ref(), b"webp-cover");
}

#[tokio::test]
async fn item_image_serves_gif_cover_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Movie (2020)")).expect("movie dir");
    std::fs::write(
        temp.path()
            .join("shared/_Videos/Movie (2020)/Movie (2020).mkv"),
        b"movie",
    )
    .expect("movie");
    std::fs::write(
        temp.path().join("shared/_Videos/Movie (2020)/cover.gif"),
        b"gif-bytes",
    )
    .expect("gif cover");
    let app = test_app(&temp);

    let response = app
        .clone()
        .oneshot(viewer_get_request("/api/v1/items?rootId=shared-videos"))
        .await
        .expect("items response");
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("items body");
    let value: Value = serde_json::from_slice(&body).expect("items json");
    let items = value["items"].as_array().expect("items array");
    assert_eq!(items.len(), 2);
    let movie_id = items
        .iter()
        .find(|item| item["mediaKind"] == "video")
        .and_then(|item| item["id"].as_str())
        .expect("movie item id");
    let cover_id = items
        .iter()
        .find(|item| item["mediaKind"] == "artwork")
        .and_then(|item| item["id"].as_str())
        .expect("cover item id");

    for id in [movie_id, cover_id] {
        let response = app
            .clone()
            .oneshot(viewer_get_request(&format!("/api/v1/items/{id}/image")))
            .await
            .expect("image response");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok()),
            Some("image/gif")
        );
        let body = to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("image body");
        assert_eq!(body.as_ref(), b"gif-bytes");
    }
}

#[tokio::test]
async fn item_image_returns_not_found_without_artwork() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let app = test_app(&temp);
    std::fs::write(temp.path().join("shared/_Videos/Movie.mkv"), b"movie").expect("movie");
    let movie_id = first_item_id(&app, "shared-videos").await;

    let response = app
        .oneshot(viewer_get_request(&format!(
            "/api/v1/items/{movie_id}/image"
        )))
        .await
        .expect("image response");
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("image body");
    let value: Value = serde_json::from_slice(&body).expect("image json");
    assert_eq!(value["error"]["code"], "artwork_not_found");
}

fn mp3_with_embedded_artwork(mime: &str, image: &[u8]) -> Vec<u8> {
    let mut apic = Vec::new();
    apic.push(0);
    apic.extend_from_slice(mime.as_bytes());
    apic.push(0);
    apic.push(3);
    apic.push(0);
    apic.extend_from_slice(image);

    let mut frame = Vec::new();
    frame.extend_from_slice(b"APIC");
    frame.extend_from_slice(&(apic.len() as u32).to_be_bytes());
    frame.extend_from_slice(&[0, 0]);
    frame.extend_from_slice(&apic);

    let size = frame.len() as u32;
    let synchsafe = [
        ((size >> 21) & 0x7f) as u8,
        ((size >> 14) & 0x7f) as u8,
        ((size >> 7) & 0x7f) as u8,
        (size & 0x7f) as u8,
    ];
    let mut mp3 = Vec::new();
    mp3.extend_from_slice(b"ID3\x03\x00\x00");
    mp3.extend_from_slice(&synchsafe);
    mp3.extend_from_slice(&frame);
    for _ in 0..2 {
        mp3.extend_from_slice(&[0xff, 0xfb, 0x90, 0x64]);
        mp3.resize(mp3.len() + 413, 0);
    }
    mp3
}

fn test_iso(volume_id: &str) -> Vec<u8> {
    let mut bytes = vec![0u8; 17 * 2048];
    bytes[16 * 2048] = 1;
    bytes[16 * 2048 + 1..16 * 2048 + 6].copy_from_slice(b"CD001");
    bytes[16 * 2048 + 6] = 1;
    let mut volume = [b' '; 32];
    volume[..volume_id.len()].copy_from_slice(volume_id.as_bytes());
    bytes[16 * 2048 + 40..16 * 2048 + 72].copy_from_slice(&volume);
    bytes
}

fn viewer_get_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("x-forwarded-user", "viewer")
        .header("x-forwarded-groups", "users")
        .body(Body::empty())
        .expect("viewer request")
}

fn viewer_post_request(uri: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-user", "viewer")
        .header("x-forwarded-groups", "users")
        .body(body)
        .expect("viewer request")
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

async fn item_id_by_kind(app: &axum::Router, root_id: &str, media_kind: &str) -> String {
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
    value["items"]
        .as_array()
        .expect("items array")
        .iter()
        .find(|item| item["mediaKind"] == media_kind)
        .and_then(|item| item["id"].as_str())
        .expect("item ID for media kind")
        .to_string()
}

const NIRVANA_MBID: &str = "1b022e01-4da6-387b-8658-8678046e4cef";

fn release_group_payload(mbid: &str) -> String {
    format!(
        r#"{{
            "id": "{mbid}",
            "title": "Nevermind",
            "primary-type": "Album",
            "first-release-date": "1991-09-24",
            "artist-credit": [{{ "name": "Nirvana", "joinphrase": "" }}],
            "genres": [{{ "name": "grunge" }}, {{ "name": "alternative rock" }}],
            "releases": [
                {{
                    "label-info": [{{ "label": {{ "name": "DGC" }} }}],
                    "media": [{{ "track-count": 13 }}]
                }}
            ]
        }}"#
    )
}

async fn serve_mock(routes: axum::Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind mock server");
    let address = listener.local_addr().expect("mock address");
    let handle = tokio::spawn(async move {
        axum::serve(listener, routes).await.expect("mock server");
    });
    (format!("http://127.0.0.1:{}", address.port()), handle)
}

fn musicbrainz_mock() -> axum::Router {
    use axum::routing::get;
    use axum::Json;
    async fn search(
        query: axum::extract::Query<std::collections::HashMap<String, String>>,
    ) -> Json<Value> {
        let lucene = query
            .get("query")
            .expect("search query parameter")
            .to_string();
        assert!(
            lucene.contains("artist:\"Nirvana\"") || lucene.contains("releasegroup:\"Nevermind\""),
            "unexpected search query: {lucene}"
        );
        Json(serde_json::json!({
            "release-groups": [{ "id": NIRVANA_MBID }]
        }))
    }
    async fn lookup() -> Json<Value> {
        Json(
            serde_json::from_str::<Value>(&release_group_payload(NIRVANA_MBID))
                .expect("release group payload"),
        )
    }
    async fn acoustid_lookup() -> Json<Value> {
        Json(serde_json::json!({
            "status": "ok",
            "results": [{
                "recordings": [{
                    "releasegroups": [{ "id": NIRVANA_MBID }]
                }]
            }]
        }))
    }
    axum::Router::new()
        .route("/release-group/", get(search))
        .route("/release-group/{id}", get(lookup))
        .route("/lookup", get(acoustid_lookup))
}

#[tokio::test]
async fn musicbrainz_search_lookup_returns_release_group_candidates() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (mock_base, _mock) = serve_mock(musicbrainz_mock()).await;
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.mutation_mode = MutationMode::Enabled;
    config.musicbrainz_api_base = Some(mock_base);
    std::fs::create_dir_all(config.shared_root.join("_Music/Artist/Album")).expect("music folder");
    std::fs::write(
        config.shared_root.join("_Music/Artist/Album/01 Song.flac"),
        b"audio",
    )
    .expect("audio file");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-music", "music").await;
    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(
                serde_json::json!({
                    "mode": "search",
                    "artist": "Nirvana",
                    "title": "Nevermind"
                })
                .to_string(),
            ),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert!(value["requestId"].as_str().is_some());
    let candidate = &value["candidates"][0];
    assert_eq!(candidate["releaseGroupId"], NIRVANA_MBID);
    assert_eq!(candidate["artist"], "Nirvana");
    assert_eq!(candidate["title"], "Nevermind");
    assert_eq!(candidate["releaseType"], "Album");
    assert_eq!(candidate["year"], 1991);
    let genres = candidate["genres"]
        .as_array()
        .expect("genres array")
        .iter()
        .filter_map(|genre| genre.as_str())
        .collect::<Vec<_>>();
    assert!(genres.contains(&"grunge"));
    assert!(genres.contains(&"alternative rock"));
    assert_eq!(candidate["label"], "DGC");
    assert_eq!(candidate["trackCount"], 13);
    assert_eq!(candidate["matchMethod"], "search");
}

#[tokio::test]
async fn musicbrainz_fingerprint_lookup_runs_fpcalc_and_uses_acoustid() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (mock_base, _mock) = serve_mock(musicbrainz_mock()).await;
    let key_file = temp.path().join("acoustid.json");
    std::fs::write(&key_file, r#"{"acoustidApiKey":"test-api-key"}"#).expect("write key");
    let fpcalc = temp.path().join("fpcalc-stub");
    let mut finger = "AQ".to_string();
    for _ in 0..50 {
        finger.push_str("ABC");
    }
    std::fs::write(
        &fpcalc,
        format!("#!/bin/sh\necho DURATION=271\necho FINGERPRINT={finger}\n"),
    )
    .expect("write stub");
    let mut permissions = std::fs::metadata(&fpcalc)
        .expect("stub metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&fpcalc, permissions).expect("make stub executable");

    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.mutation_mode = MutationMode::Enabled;
    config.musicbrainz_api_base = Some(mock_base.clone());
    config.acoustid_api_base = Some(mock_base);
    config.acoustid_api_key_file = Some(key_file);
    config.fpcalc_path = Some(fpcalc);
    std::fs::create_dir_all(config.shared_root.join("_Music/Artist/Album")).expect("music folder");
    std::fs::write(
        config.shared_root.join("_Music/Artist/Album/01 Song.flac"),
        b"audio",
    )
    .expect("audio file");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-music", "music").await;
    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"fingerprint"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["candidates"][0]["releaseGroupId"], NIRVANA_MBID);
    assert_eq!(value["candidates"][0]["matchMethod"], "fingerprint");
}

#[tokio::test]
async fn musicbrainz_auto_mode_falls_back_to_search_without_an_api_key() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (mock_base, _mock) = serve_mock(musicbrainz_mock()).await;
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.mutation_mode = MutationMode::Enabled;
    config.musicbrainz_api_base = Some(mock_base);
    std::fs::create_dir_all(config.shared_root.join("_Music/Nirvana")).expect("music folder");
    std::fs::write(
        config.shared_root.join("_Music/Nirvana/Nevermind.flac"),
        b"audio",
    )
    .expect("audio file");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-music", "music").await;
    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"auto"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["candidates"][0]["matchMethod"], "search");
}

#[tokio::test]
async fn musicbrainz_fingerprint_without_a_key_is_rejected_as_unconfigured() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut config = AppConfig::for_test(
        temp.path().join("shared").to_str().expect("shared path"),
        temp.path().join("users").to_str().expect("users path"),
    );
    config.state_dir = temp.path().join("state");
    config.mutation_mode = MutationMode::Enabled;
    std::fs::create_dir_all(config.shared_root.join("_Music/Artist")).expect("music folder");
    std::fs::write(config.shared_root.join("_Music/Artist/Song.flac"), b"audio")
        .expect("audio file");
    let database = config.database_path();
    Catalog::open(&database).expect("catalog");
    let app = router(AppState {
        config,
        catalog: CatalogHandle::new(database),
    });
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-music", "music").await;
    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"fingerprint"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["error"]["code"], "musicbrainz_lookup_unconfigured");
}

#[tokio::test]
async fn musicbrainz_lookup_rejects_invalid_queries_and_modes() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::create_dir_all(temp.path().join("shared/_Music/Artist")).expect("music folder");
    std::fs::write(temp.path().join("shared/_Music/Artist/Song.flac"), b"audio")
        .expect("audio file");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-music"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-music", "music").await;

    let invalid_mode = app
        .clone()
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"bogus"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(invalid_mode.status(), StatusCode::BAD_REQUEST);
    let body = to_bytes(invalid_mode.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["error"]["code"], "musicbrainz_mode_invalid");

    let no_query = app
        .clone()
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"search"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(no_query.status(), StatusCode::BAD_REQUEST);
    let body = to_bytes(no_query.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["error"]["code"], "musicbrainz_query_required");
}

#[tokio::test]
async fn musicbrainz_lookup_requires_a_music_item() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let (app, _) = test_app_with_mode(&temp, MutationMode::Enabled);
    std::fs::create_dir_all(temp.path().join("shared/_Videos/Movies")).expect("movie folder");
    std::fs::write(
        temp.path().join("shared/_Videos/Movies/Arrival (2016).mkv"),
        b"movie",
    )
    .expect("movie file");
    editor_json_request(&app, "/api/v1/scans", r#"{"rootId":"shared-videos"}"#).await;
    let item_id = item_id_by_kind(&app, "shared-videos", "video").await;
    let response = app
        .oneshot(editor_post_request(
            &format!("/api/v1/items/{item_id}/metadata/lookup"),
            Body::from(r#"{"mode":"search","artist":"Nirvana"}"#.to_string()),
        ))
        .await
        .expect("lookup response");
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .expect("body");
    let value: Value = serde_json::from_slice(&body).expect("lookup JSON");
    assert_eq!(value["error"]["code"], "music_item_required");
}
