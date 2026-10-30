//! Library endpoints mutate only metadata or inbox staging. Payload writers run
//! as queued worker operations, retaining the API service's read-only boundary.
use crate::{
    archive_engine,
    catalog::{self, Archive, ListQuery},
    http::{
        assert_same_origin, authenticated_user, file_response, mutation_json, ApiError, AppState,
    },
    model::{CaptureOptions, CrawlScope, CreateJobRequest, Interaction, Operation, ResumeOptions},
    queue::random_job_id,
    validation::{parse_create_job, CreateJobInput},
};
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
const UPLOAD_LIMIT: usize = 128 * 1024 * 1024;
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/presets", get(presets))
        .route("/api/preflight", post(preflight))
        .route("/api/samples", post(sample))
        .route("/api/batch", post(batch))
        .route("/api/archives", get(list_archives))
        .route("/api/archives/search", get(search))
        .route("/api/archives/reconcile", post(reconcile))
        .route(
            "/api/archives/import",
            post(import_archive).layer(DefaultBodyLimit::max(UPLOAD_LIMIT)),
        )
        .route(
            "/api/archives/{id}",
            get(detail).patch(patch_archive).delete(trash),
        )
        .route(
            "/api/archives/{id}/{action}",
            get(archive_read).post(archive_write),
        )
        .route("/api/recipes", get(list_recipes).post(create_recipe))
        .route(
            "/api/recipes/{id}",
            get(get_recipe).patch(edit_recipe).delete(delete_recipe),
        )
        .route("/api/recipes/{id}/run", post(run_recipe))
        .route("/api/schedules", get(list_schedules).post(create_schedule))
        .route(
            "/api/schedules/{id}",
            axum::routing::patch(edit_schedule).delete(delete_schedule),
        )
        .route("/api/profiles", get(list_profiles).post(create_profile))
        .route(
            "/api/profiles/import",
            post(import_profile).layer(DefaultBodyLimit::max(crate::profiles::PROFILE_BYTES)),
        )
        .route("/api/profiles/{id}", axum::routing::delete(revoke_profile))
}
fn value<T: Serialize>(v: T) -> Result<Json<Value>, ApiError> {
    Ok(Json(serde_json::to_value(v).map_err(ApiError::internal)?))
}
fn conflict(e: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, e)
}
fn owned(state: &AppState, id: &str, owner: &str) -> Result<Archive, ApiError> {
    state
        .database
        .archive_for_user(id, owner)?
        .ok_or_else(|| ApiError::not_found("archive not found"))
}
fn archive_path(state: &AppState, a: &Archive) -> Result<std::path::PathBuf, ApiError> {
    crate::custody::checked_file(crate::custody::root(&state.config, a), &a.archive_file)
        .map_err(|_| ApiError::not_found("archive payload unavailable"))
}
fn request_for_archive(a: &Archive) -> CreateJobRequest {
    a.request.clone().unwrap_or(CreateJobRequest {
        url: a.url.clone(),
        scope: CrawlScope::Page,
        page_limit: 25,
        time_limit_minutes: 10,
        collection: None,
        options: CaptureOptions::default(),
    })
}
fn queue(
    state: &AppState,
    owner: &str,
    request: &CreateJobRequest,
    operation: Operation,
) -> Result<Json<Value>, ApiError> {
    let id = random_job_id();
    state
        .database
        .queue_operation(&id, owner, request, operation)?;
    Ok(Json(json!({"jobId":id})))
}
async fn presets(headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    authenticated_user(&headers)?;
    value(["faithful", "balanced", "reader"].map(CaptureOptions::preset))
}
async fn list_archives(
    State(s): State<AppState>,
    Query(q): Query<ListQuery>,
    h: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(archive_page(s.database.archives(&u.username, &q)?))
}
async fn detail(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(owned(&s, &id, &u.username)?)
}
async fn search(
    State(s): State<AppState>,
    Query(q): Query<ListQuery>,
    h: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    if q.q.len() > 512 {
        return Err(ApiError::bad_request("search is too long"));
    }
    value(s.database.search_pages(&u.username, &q)?)
}
async fn patch_archive(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let patch: Value = mutation_json(&h, &b)?;
    let mut a = owned(&s, &id, &u.username)?;
    for (key, v) in patch.as_object().expect("JSON object") {
        match key.as_str() {
            "title" | "collection" | "notes" => {
                let text = v
                    .as_str()
                    .ok_or_else(|| ApiError::bad_request("metadata must be text"))?;
                if text.len() > if key == "notes" { 10000 } else { 512 } {
                    return Err(ApiError::bad_request("metadata too long"));
                }
                match key.as_str() {
                    "title" => a.title = text.into(),
                    "collection" => a.collection = text.into(),
                    _ => a.notes = text.into(),
                }
            }
            "favorite" => {
                a.favorite = v
                    .as_bool()
                    .ok_or_else(|| ApiError::bad_request("favorite must be boolean"))?
            }
            "tags" => {
                let tags: Vec<String> = serde_json::from_value(v.clone())
                    .map_err(|_| ApiError::bad_request("tags must be text array"))?;
                if tags.len() > 50 || tags.iter().any(|v| v.len() > 100) {
                    return Err(ApiError::bad_request("too many/long tags"));
                }
                a.tags = tags;
            }
            "cleanRules" => {
                a.clean_rules = serde_json::from_value(v.clone())
                    .map_err(|_| ApiError::bad_request("invalid selector rules"))?;
                crate::validation::validate_selectors(&a.clean_rules)
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
            }
            _ => {
                return Err(ApiError::bad_request(
                    "only title, tags, collection, favorite, notes and cleanRules can be edited",
                ))
            }
        }
    }
    a.updated_at = catalog::now();
    s.database.save_archive_metadata(&a)?;
    value(a)
}
async fn trash(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    let mut a = owned(&s, &id, &u.username)?;
    a.trashed = true;
    a.updated_at = catalog::now();
    s.database.save_archive_metadata(&a)?;
    Ok(Json(
        json!({"ok":true,"reclaimedBytes":0,"restorable":true,"dependencies":a.dependencies,"retainedBytes":a.archive_bytes}),
    ))
}
async fn archive_read(
    State(s): State<AppState>,
    Path((id, action)): Path<(String, String)>,
    Query(params): Query<BTreeMap<String, String>>,
    h: HeaderMap,
) -> Result<Response, ApiError> {
    let u = authenticated_user(&h)?;
    let a = owned(&s, &id, &u.username)?;
    let q: ListQuery =
        serde_json::from_value(serde_json::to_value(&params).map_err(ApiError::internal)?)
            .unwrap_or_default();
    let mut q = q;
    q.q = params.get("q").cloned().unwrap_or_default();
    q.limit = params.get("limit").and_then(|v| v.parse().ok());
    q.offset = params
        .get("offset")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    q.mime = params.get("mime").cloned();
    q.domain = params.get("domain").cloned();
    match action.as_str() {
        "wacz" => {
            let query = if params.get("download").is_some_and(|v| v == "1") {
                Some("download=1")
            } else {
                None
            };
            file_response(
                crate::custody::root(&s.config, &a),
                &a.archive_file,
                query,
                &h,
            )
            .await
        }
        "pages" => Ok(value(s.database.pages(&id, &q)?)?.into_response()),
        "resources" => Ok(value(s.database.resources(&id, &q)?)?.into_response()),
        "coverage" => Ok(value(s.database.coverage(&id, &q)?)?.into_response()),
        "replay" | "replay.json" => {
            let deps = crate::library::authorized_dependencies(&s.config, &s.database, &a)
                .map_err(conflict)?;
            let mut resources = vec![
                json!({"name":format!("{}.wacz",a.id),"path":format!("/api/archives/{}/wacz",a.id),"hash":format!("sha256:{}",a.sha256)}),
            ];
            for dep in deps {
                resources.push(json!({"name":format!("{}.wacz",dep.id),"path":format!("/api/archives/{}/wacz",dep.id),"hash":format!("sha256:{}",dep.sha256),"fromDependency":true}));
            }
            Ok(Json(json!({"profile":"multi-wacz-package","wacz_version":"1.1.1","resources":resources})).into_response())
        }
        "retention"=>Ok(Json(json!({"archiveId":a.id,"retainedBytes":a.archive_bytes,"reclaimableBytes":0,"restorable":true,"dependencies":a.dependencies,"dependents":s.database.dependents(&a.id,&u.username)?,"reason":"Trash is reversible; permanent deletion is not enabled"})).into_response()),
        "compare" => {
            let other = owned(
                &s,
                params
                    .get("other")
                    .ok_or_else(|| ApiError::bad_request("other archive required"))?,
                &u.username,
            )?;
            let left = archive_path(&s, &a)?;
            let right = archive_path(&s, &other)?;
            let config = s.config.clone();
            let db = s.database.clone();
            let report = crate::library::analyze(move || {
                let left_deps = crate::library::authorized_view_dependencies(&config, &db, &a)?;
                let right_deps = crate::library::authorized_view_dependencies(&config, &db, &other)?;
                archive_engine::compare_archives_authorized(&left, &left_deps, &right, &right_deps)
            })
            .await
            .map_err(ApiError::internal)?
            .map_err(ApiError::bad_request)?;
            Ok(value(report)?.into_response())
        }
        "timeline" => {
            let host = url::Url::parse(&a.url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_owned))
                .unwrap_or_default();
            let list = s.database.archives(
                &u.username,
                &ListQuery {
                    q: host,
                    ..Default::default()
                },
            )?;
            Ok(value(archive_page(list))?.into_response())
        }
        "reader" => {
            let format = params
                .get("format")
                .map(String::as_str)
                .unwrap_or("markdown");
            if !matches!(format, "markdown" | "html") {
                return Err(ApiError::bad_request("format must be markdown or html"));
            }
            let path = archive_path(&s, &a)?;
            let format = format.to_owned();
            let kind = format.clone();
            let config = s.config.clone();
            let db = s.database.clone();
            let content =
                crate::library::analyze(move || {
                    let deps = crate::library::authorized_view_dependencies(&config, &db, &a)?;
                    archive_engine::reader_export_authorized(&path, &kind, &deps)
                })
                    .await
                    .map_err(ApiError::internal)?
                    .map_err(ApiError::bad_request)?;
            let mime = if format == "html" {
                "text/html; charset=utf-8"
            } else {
                "text/markdown; charset=utf-8"
            };
            Ok((
                [
                    (header::CONTENT_TYPE, mime),
                    (header::CONTENT_DISPOSITION, "attachment"),
                    (
                        header::CONTENT_SECURITY_POLICY,
                        "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:",
                    ),
                ],
                content,
            )
                .into_response())
        }
        "preview" => {
            let target = params
                .get("url")
                .ok_or_else(|| ApiError::bad_request("url required"))?
                .clone();
            if target.len() > 2048 {
                return Err(ApiError::bad_request("url too long"));
            }
            let path = archive_path(&s, &a)?;
            let config = s.config.clone();
            let db = s.database.clone();
            let html = crate::library::analyze(move || {
                let deps = crate::library::authorized_view_dependencies(&config, &db, &a)?;
                archive_engine::preview_document_authorized(&path, &target, &deps)
            })
            .await
            .map_err(ApiError::internal)?
            .map_err(ApiError::bad_request)?;
            Ok((
                [
                    (header::CONTENT_TYPE, "text/html; charset=utf-8"),
                    (
                        header::CONTENT_SECURITY_POLICY,
                        html.content_security_policy.as_str(),
                    ),
                    (header::REFERRER_POLICY, "no-referrer"),
                ],
                html.html,
            )
                .into_response())
        }
        _ => Err(ApiError::not_found("archive endpoint not found")),
    }
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct VerifyInput {
    mode: Option<String>,
    url: Option<String>,
    interactions: Option<Vec<Interaction>>,
}
async fn archive_write(
    State(s): State<AppState>,
    Path((id, action)): Path<(String, String)>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let mut a = owned(&s, &id, &u.username)?;
    let request = request_for_archive(&a);
    match action.as_str() {
        "restore" => {
            a.trashed = false;
            a.updated_at = catalog::now();
            s.database.save_archive_metadata(&a)?;
            value(a)
        }
        "verify" => {
            let input: VerifyInput =
                serde_json::from_value(input).map_err(|e| ApiError::bad_request(e.to_string()))?;
            let mode = input.mode.unwrap_or_else(|| "fixity".into());
            if !matches!(mode.as_str(), "fixity" | "browser") {
                return Err(ApiError::bad_request("mode must be fixity or browser"));
            }
            let interactions = input
                .interactions
                .unwrap_or_else(|| request.options.interactions.clone());
            crate::validation::validate_interactions(&interactions)
                .map_err(|e| ApiError::bad_request(e.to_string()))?;
            if input.url.as_ref().is_some_and(|v| v.len() > 2048) {
                return Err(ApiError::bad_request("url too long"));
            }
            queue(
                &s,
                &u.username,
                &request,
                Operation::Verify {
                    archive_id: id,
                    sha256: a.sha256,
                    mode,
                    url: input.url,
                    interactions,
                },
            )
        }
        "export" => {
            let options: archive_engine::ExportOptions =
                serde_json::from_value(input).map_err(|e| ApiError::bad_request(e.to_string()))?;
            crate::validation::validate_export(&options)
                .map_err(|e| ApiError::bad_request(e.to_string()))?;
            queue(
                &s,
                &u.username,
                &request,
                Operation::Export {
                    archive_id: id,
                    sha256: a.sha256,
                    options,
                },
            )
        }
        "repair" => {
            let urls: Vec<String> =
                serde_json::from_value(input.get("urls").cloned().unwrap_or(Value::Null))
                    .map_err(|_| ApiError::bad_request("urls array required"))?;
            if urls.is_empty() || urls.len() > 100 {
                return Err(ApiError::bad_request("select 1 to 100 repair URLs"));
            }
            for url in &urls {
                let parsed = parse_create_job(CreateJobInput::from_request(&CreateJobRequest {
                    url: url.clone(),
                    ..request.clone()
                }))
                .map_err(|e| ApiError::bad_request(e.to_string()))?;
                s.queue.validate_request(&parsed.request).await?;
            }
            queue(
                &s,
                &u.username,
                &request,
                Operation::Repair {
                    archive_id: id,
                    sha256: a.sha256,
                    urls,
                },
            )
        }
        _ => Err(ApiError::not_found("archive action not found")),
    }
}
async fn preflight(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: CreateJobInput = mutation_json(&h, &b)?;
    let parsed = parse_create_job(input).map_err(|e| ApiError::bad_request(e.to_string()))?;
    if parsed.request.options.profile_id.is_some() {
        return Err(ApiError::bad_request(
            "profile-backed discovery must use the queued /api/samples worker operation",
        ));
    }
    let result = crate::network::preflight(&s.database, &s.queue, &u.username, &parsed.request)
        .await
        .map_err(ApiError::bad_request)?;
    value(result)
}
async fn sample(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: CreateJobInput = mutation_json(&h, &b)?;
    let mut request = parse_create_job(input)
        .map_err(|e| ApiError::bad_request(e.to_string()))?
        .request;
    let target_pages = request.page_limit;
    request.page_limit = request.page_limit.min(3);
    request.time_limit_minutes = request.time_limit_minutes.min(5);
    request.options.size_limit_bytes = Some(
        request
            .options
            .size_limit_bytes
            .unwrap_or(256 * 1024 * 1024)
            .min(256 * 1024 * 1024),
    );
    s.queue.validate_request(&request).await?;
    queue(
        &s,
        &u.username,
        &request,
        Operation::Sample { target_pages },
    )
}
async fn batch(State(s): State<AppState>, h: HeaderMap, b: Bytes) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let requests: Vec<CreateJobInput> = serde_json::from_value(input["requests"].clone())
        .map_err(|_| ApiError::bad_request("requests array required"))?;
    if requests.is_empty() || requests.len() > 20 {
        return Err(ApiError::bad_request("batch size must be 1 to 20"));
    }
    let mut parsed = vec![];
    for input in requests {
        let request = parse_create_job(input)
            .map_err(|e| ApiError::bad_request(e.to_string()))?
            .request;
        s.queue.validate_request(&request).await?;
        parsed.push(request);
    }
    let ids = s.database.queue_batch(&u.username, &parsed)?;
    Ok(Json(json!({"jobIds":ids})))
}
async fn reconcile(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    queue(&s, &u.username, &placeholder(), Operation::Reconcile)
}
fn placeholder() -> CreateJobRequest {
    CreateJobRequest {
        url: "https://example.org/".into(),
        scope: CrawlScope::Page,
        page_limit: 1,
        time_limit_minutes: 1,
        collection: None,
        options: CaptureOptions::default(),
    }
}
async fn upload(s: &AppState, b: Bytes, max: usize) -> Result<String, ApiError> {
    if b.is_empty() || b.len() > max {
        return Err(ApiError::bad_request("upload exceeds nonzero byte limit"));
    }
    let id = random_job_id();
    let root = &s.config.inbox_root;
    tokio::fs::create_dir_all(root)
        .await
        .map_err(ApiError::internal)?;
    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o640);
    let mut file = options
        .open(root.join(&id))
        .await
        .map_err(ApiError::internal)?;
    use tokio::io::AsyncWriteExt;
    file.write_all(&b).await.map_err(ApiError::internal)?;
    file.sync_all().await.map_err(ApiError::internal)?;
    crate::custody::sync_directory(root).map_err(ApiError::internal)?;
    Ok(id)
}
fn raw_mutation(h: &HeaderMap) -> Result<(), ApiError> {
    assert_same_origin(h)?;
    let content = h
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("");
    if !matches!(
        content,
        "application/octet-stream"
            | "application/wacz+zip"
            | "application/zip"
            | "application/gzip"
    ) {
        return Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "raw archive content type required",
        ));
    }
    Ok(())
}
async fn import_archive(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    raw_mutation(&h)?;
    let inbox = upload(&s, b, UPLOAD_LIMIT).await?;
    queue(
        &s,
        &u.username,
        &placeholder(),
        Operation::Import { inbox_id: inbox },
    )
}
async fn list_recipes(State(s): State<AppState>, h: HeaderMap) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(s.database.records("recipe", &u.username)?)
}
async fn create_recipe(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let name = bounded_name(&input)?;
    let request = parse_create_job(
        serde_json::from_value(input["request"].clone())
            .map_err(|_| ApiError::bad_request("request required"))?,
    )
    .map_err(|e| ApiError::bad_request(e.to_string()))?
    .request;
    s.queue.validate_request(&request).await?;
    let id = random_job_id();
    let v = json!({"id":id,"name":name,"version":1,"request":request,"createdAt":catalog::now(),"updatedAt":catalog::now(),"software":"Browsertrix Crawler 1.14.3"});
    s.database.put_record("recipe", &id, &u.username, &v)?;
    value(v)
}
async fn get_recipe(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(
        s.database
            .record("recipe", &id, &u.username)?
            .ok_or_else(|| ApiError::not_found("recipe not found"))?,
    )
}
async fn edit_recipe(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let mut v = s
        .database
        .record("recipe", &id, &u.username)?
        .ok_or_else(|| ApiError::not_found("recipe not found"))?;
    if input.get("name").is_some() {
        v["name"] = json!(bounded_name(&input)?);
    }
    if let Some(r) = input.get("request") {
        let request = parse_create_job(
            serde_json::from_value(r.clone())
                .map_err(|_| ApiError::bad_request("invalid request"))?,
        )
        .map_err(|e| ApiError::bad_request(e.to_string()))?
        .request;
        s.queue.validate_request(&request).await?;
        v["request"] = json!(request);
    }
    v["version"] = json!(v["version"].as_u64().unwrap_or(1) + 1);
    v["updatedAt"] = json!(catalog::now());
    s.database.put_record("recipe", &id, &u.username, &v)?;
    value(v)
}
async fn delete_recipe(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    if s.database.delete_record("recipe", &id, &u.username)? == 0 {
        return Err(ApiError::not_found("recipe not found"));
    }
    Ok(Json(json!({"ok":true})))
}
async fn run_recipe(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    let recipe = s
        .database
        .record("recipe", &id, &u.username)?
        .ok_or_else(|| ApiError::not_found("recipe not found"))?;
    let request: CreateJobRequest =
        serde_json::from_value(recipe["request"].clone()).map_err(ApiError::internal)?;
    s.queue.validate_request(&request).await?;
    queue(&s, &u.username, &request, Operation::Capture)
}
async fn list_schedules(State(s): State<AppState>, h: HeaderMap) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(s.database.records("schedule", &u.username)?)
}
fn schedule_fields(v: &mut Value, input: &Value) -> Result<(), ApiError> {
    if let Some(interval) = input.get("intervalMinutes") {
        let n = interval
            .as_u64()
            .filter(|v| (60..=525600).contains(v))
            .ok_or_else(|| ApiError::bad_request("intervalMinutes must be 60 to 525600"))?;
        v["intervalMinutes"] = json!(n);
    }
    if let Some(enabled) = input.get("enabled") {
        v["enabled"] = json!(enabled
            .as_bool()
            .ok_or_else(|| ApiError::bad_request("enabled must be boolean"))?);
    }
    Ok(())
}
async fn create_schedule(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let recipe = input["recipeId"]
        .as_str()
        .ok_or_else(|| ApiError::bad_request("recipeId required"))?;
    s.database
        .record("recipe", recipe, &u.username)?
        .ok_or_else(|| ApiError::not_found("recipe not found"))?;
    let id = random_job_id();
    let mut v = json!({"id":id,"recipeId":recipe,"enabled":false,"intervalMinutes":1440,"nextRunAt":(chrono::Utc::now()+chrono::Duration::days(1)).to_rfc3339_opts(chrono::SecondsFormat::Millis,true)});
    schedule_fields(&mut v, &input)?;
    v["nextRunAt"] = json!((chrono::Utc::now()
        + chrono::Duration::minutes(v["intervalMinutes"].as_i64().unwrap_or(1440)))
    .to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    s.database.put_record("schedule", &id, &u.username, &v)?;
    value(v)
}
async fn edit_schedule(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let mut v = s
        .database
        .record("schedule", &id, &u.username)?
        .ok_or_else(|| ApiError::not_found("schedule not found"))?;
    schedule_fields(&mut v, &input)?;
    if let Some(recipe) = input["recipeId"].as_str() {
        s.database
            .record("recipe", recipe, &u.username)?
            .ok_or_else(|| ApiError::not_found("recipe not found"))?;
        v["recipeId"] = json!(recipe);
    }
    let patch = json!({"enabled":v["enabled"],"intervalMinutes":v["intervalMinutes"],"recipeId":v["recipeId"]});
    s.database
        .patch_record("schedule", &id, &u.username, &patch)?;
    value(
        s.database
            .record("schedule", &id, &u.username)?
            .ok_or_else(|| ApiError::not_found("schedule not found"))?,
    )
}
async fn delete_schedule(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    if s.database.delete_record("schedule", &id, &u.username)? == 0 {
        return Err(ApiError::not_found("schedule not found"));
    }
    Ok(Json(json!({"ok":true})))
}
fn bounded_name(input: &Value) -> Result<String, ApiError> {
    input["name"]
        .as_str()
        .filter(|v| !v.trim().is_empty() && v.len() <= 200 && !v.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or_else(|| ApiError::bad_request("name must be 1 to 200 characters"))
}
fn public_profile(mut v: Value) -> Value {
    if v["expiresAt"].as_str().is_some_and(|stamp| {
        chrono::DateTime::parse_from_rfc3339(stamp)
            .map(|expiry| expiry <= chrono::Utc::now())
            .unwrap_or(true)
    }) || v["revoked"] == true
    {
        v["available"] = json!(false);
    }
    if let Some(object) = v.as_object_mut() {
        object.remove("digest");
        object.remove("revoked");
    }
    v
}
async fn list_profiles(State(s): State<AppState>, h: HeaderMap) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    value(
        s.database
            .records("profile", &u.username)?
            .into_iter()
            .map(public_profile)
            .collect::<Vec<_>>(),
    )
}
async fn create_profile(
    State(s): State<AppState>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let input: Value = mutation_json(&h, &b)?;
    let name = bounded_name(&input)?;
    let expires = input.get("expiresAt").filter(|v| !v.is_null()).cloned();
    if let Some(e) = &expires {
        chrono::DateTime::parse_from_rfc3339(e.as_str().unwrap_or(""))
            .map_err(|_| ApiError::bad_request("invalid expiresAt"))?;
    }
    let id = random_job_id();
    let v = json!({"id":id,"name":name,"available":false,"revoked":false,"createdAt":catalog::now(),"updatedAt":catalog::now(),"expiresAt":expires});
    s.database.put_record("profile", &id, &u.username, &v)?;
    value(public_profile(v))
}
async fn import_profile(
    State(s): State<AppState>,
    Query(q): Query<BTreeMap<String, String>>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    raw_mutation(&h)?;
    let (id, v, create) = if let Some(id) = q.get("profileId") {
        let metadata = s
            .database
            .record("profile", id, &u.username)?
            .filter(|v| v["available"] != true && v["revoked"] != true)
            .ok_or_else(|| ApiError::not_found("uninitialised profile not found"))?;
        (id.clone(), metadata, false)
    } else {
        let name = bounded_name(&json!({"name":q.get("name")}))?;
        let expires = q.get("expiresAt");
        if let Some(stamp) = expires {
            chrono::DateTime::parse_from_rfc3339(stamp)
                .map_err(|_| ApiError::bad_request("invalid expiresAt"))?;
        }
        let id = random_job_id();
        let metadata = json!({"id":id,"name":name,"available":false,"revoked":false,"createdAt":catalog::now(),"updatedAt":catalog::now(),"expiresAt":expires});
        (id, metadata, true)
    };
    let inbox = upload(&s, b, crate::profiles::PROFILE_BYTES).await?;
    if create {
        s.database.put_record("profile", &id, &u.username, &v)?;
    }
    let mut result = queue(
        &s,
        &u.username,
        &placeholder(),
        Operation::ProfileImport {
            profile_id: id.clone(),
            inbox_id: inbox,
        },
    )?
    .0;
    result["profileId"] = json!(id);
    Ok(Json(result))
}
async fn revoke_profile(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    let mut v = s
        .database
        .record("profile", &id, &u.username)?
        .ok_or_else(|| ApiError::not_found("profile not found"))?;
    v["available"] = json!(false);
    v["revoked"] = json!(true);
    v["updatedAt"] = json!(catalog::now());
    s.database.put_record("profile", &id, &u.username, &v)?;
    Ok(Json(json!({"ok":true})))
}
pub(crate) async fn pause_job(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    control(s, id, h, b, "pause")
}
pub(crate) async fn stop_job(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    control(s, id, h, b, "stop")
}
fn control(
    s: AppState,
    id: String,
    h: HeaderMap,
    b: Bytes,
    action: &str,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let _: Value = mutation_json(&h, &b)?;
    s.database
        .job_for_user(&id, &u.username)?
        .ok_or_else(|| ApiError::not_found("job not found"))?;
    s.database
        .request_control(&id, &u.username, action)
        .map_err(conflict)?;
    Ok(Json(json!({"ok":true})))
}
pub(crate) async fn resume_job(
    State(s): State<AppState>,
    Path(id): Path<String>,
    h: HeaderMap,
    b: Bytes,
) -> Result<Json<Value>, ApiError> {
    let u = authenticated_user(&h)?;
    let ext: ResumeOptions = mutation_json(&h, &b)?;
    let job = s
        .database
        .job_for_user(&id, &u.username)?
        .ok_or_else(|| ApiError::not_found("job not found"))?;
    s.queue.validate_request(&job.request).await?;
    s.database
        .resume(&id, &u.username, &ext)
        .map_err(conflict)?;
    Ok(Json(json!({"jobId":id})))
}

fn archive_page(page: crate::catalog::Page<Archive>) -> Value {
    let items=page.items.into_iter().map(|a|json!({"id":a.id,"createdAt":a.created_at,"updatedAt":a.updated_at,"createdBy":a.created_by,"url":a.url,"title":a.title,"archiveBytes":a.archive_bytes,"sha256":a.sha256,"tags":a.tags,"collection":a.collection,"favorite":a.favorite,"trashed":a.trashed,"captureStatus":a.capture_status,"stopReason":a.stop_reason,"visibility":a.visibility,"pageCount":a.page_count,"resourceCount":a.resource_count,"parentId":a.parent_id,"verification":a.verification.as_ref().map(|v|json!({"valid":v.valid,"checkedAt":v.checked_at,"checks":v.checks.iter().take(10).map(|c|json!({"name":c.name,"status":c.status})).collect::<Vec<_>>()}))})).collect::<Vec<_>>();
    json!({"items":items,"total":page.total,"offset":page.offset,"limit":page.limit})
}
