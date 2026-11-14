//! CBR → CBZ: listing for the Conversions page and the confirmable plan used
//! by both Conversions and Library health.
use super::*;
use crate::broker::ConvertComicArchiveAction;
use crate::comic_archive::{self, ArchiveFormat};
use crate::media::LibraryCategory;

pub(super) const OPERATION_KIND: &str = "comic_archive_to_cbz";
const MAX_LISTED_PER_ROOT: usize = 1000;

/// Every `.cbr` in the visible book libraries, with what is inside it.
pub(super) async fn list(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let config = state.config.clone();
    let catalog = state.catalog.clone();
    let listed = tokio::task::spawn_blocking(move || -> Result<(Vec<Value>, bool), String> {
        let catalog = catalog.open().map_err(|error| error.to_string())?;
        let mut items = Vec::new();
        let mut truncated = false;
        for root in config.visible_roots(&identity) {
            if root.category != LibraryCategory::Books || !root.available {
                continue;
            }
            let owner = (root.scope == RootScope::Personal).then_some(identity.username.as_str());
            let found = catalog
                .list_items_matching_after(&root.id, owner, None, ".cbr", MAX_LISTED_PER_ROOT)
                .map_err(|error| error.to_string())?;
            truncated |= found.len() >= MAX_LISTED_PER_ROOT;
            for item in found {
                if item.media_kind != MediaKind::Book || !comic_archive::is_cbr(&item.relative_path)
                {
                    continue;
                }
                let format = comic_archive::sniff_beneath(
                    FilePath::new(&root.resolved_path),
                    &item.relative_path,
                )
                .map_or("unreadable", ArchiveFormat::as_str);
                items.push(json!({
                    "itemId": item.id,
                    "rootId": item.root_id,
                    "rootLabel": root.label,
                    "relativePath": item.relative_path,
                    "sizeBytes": item.size_bytes,
                    "format": format,
                }));
            }
        }
        Ok((items, truncated))
    })
    .await;
    match listed {
        Ok(Ok((items, truncated))) => Json(json!({
            "items": items,
            "truncated": truncated,
            "conversionAvailable": state.config.bsdtar_path.is_some(),
        }))
        .into_response(),
        Ok(Err(error)) => {
            log_event(
                "comic_archive_list_failed",
                &request_id,
                json!({ "error": error }),
            );
            ApiError::internal(request_id).into_response()
        }
        Err(_) => ApiError::internal(request_id).into_response(),
    }
}

fn conflict(code: &'static str, message: impl Into<String>, request_id: &str) -> Response {
    ApiError::new(StatusCode::CONFLICT, code, message, request_id.to_string()).into_response()
}

/// Preview a CBR → CBZ change for exactly one item. A ZIP disguised as CBR is
/// renamed; a RAR or 7z archive is repacked, verified and staged.
pub(super) async fn preview(
    state: &AppState,
    identity: &Identity,
    mut catalog: Catalog,
    request: &super::plans::PlanRequest,
    request_id: String,
) -> Response {
    if request.operation.as_object().is_none_or(|op| op.len() != 1) || request.item_ids.len() != 1 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_comic_conversion",
            "Convert one CBR comic at a time.",
            request_id,
        )
        .into_response();
    }
    let item = match visible_catalog_item(&state.config, identity, &catalog, &request.item_ids[0]) {
        Ok(item) => item,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let Some(destination) = comic_archive::cbz_destination(&item.relative_path)
        .filter(|_| item.media_kind == MediaKind::Book)
    else {
        return conflict(
            "not_a_cbr_comic",
            "Only .cbr comics in a book library can be converted to CBZ.",
            &request_id,
        );
    };
    let Some(root) = state.config.resolve_visible_root(identity, &item.root_id) else {
        return ApiError::internal(request_id).into_response();
    };
    let root_path = FilePath::new(&root.resolved_path);
    if std::fs::symlink_metadata(root_path.join(&destination)).is_ok() {
        return conflict(
            "cbz_already_exists",
            format!(
                "{} already exists. Move or remove it before converting this comic.",
                destination.rsplit('/').next().unwrap_or(&destination)
            ),
            &request_id,
        );
    }
    let mut source = match open_regular_file_beneath(root_path, &item.relative_path) {
        Ok(file) => file,
        Err(_) => {
            return conflict(
                "unsafe_comic_source",
                "The comic could not be opened safely. Rescan the library and try again.",
                &request_id,
            )
        }
    };
    let Ok(expected_source) = opened_file_fingerprint(&source) else {
        return ApiError::internal(request_id).into_response();
    };
    let format = match comic_archive::sniff(&mut source) {
        Ok(format) => format,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let (action, staging_path, files, warnings): (BrokerAction, _, Option<usize>, Vec<&str>) =
        match format {
            ArchiveFormat::Zip => (
                BrokerAction::Move(MoveAction {
                    source_root_id: item.root_id.clone(),
                    source_relative_path: item.relative_path.clone(),
                    destination_root_id: item.root_id.clone(),
                    destination_relative_path: destination.clone(),
                    expected: expected_source,
                }),
                None,
                None,
                vec![
                    "This .cbr file is already a ZIP archive, so only its extension changes to .cbz. Its contents are not modified.",
                ],
            ),
            ArchiveFormat::Rar | ArchiveFormat::SevenZip => {
                let Some(bsdtar) = state.config.bsdtar_path.clone() else {
                    return ApiError::new(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "comic_conversion_unavailable",
                        "Comic conversion is not available on this server.",
                        request_id,
                    )
                    .into_response();
                };
                match stage_repack(state, &bsdtar, &source, &request_id).await {
                    Ok((staged, files)) => {
                        let (parent, filename) = item
                            .relative_path
                            .rsplit_once('/')
                            .unwrap_or(("", item.relative_path.as_str()));
                        let stem = filename.rsplit_once('.').map_or(filename, |(stem, _)| stem);
                        let extension = filename.rsplit_once('.').map_or("cbr", |(_, ext)| ext);
                        (
                            BrokerAction::ConvertComicArchive(ConvertComicArchiveAction {
                                staging_filename: staged.filename,
                                root_id: item.root_id.clone(),
                                source_relative_path: item.relative_path.clone(),
                                archived_relative_path: join_relative(
                                    parent,
                                    &format!("superseded/{stem}-{request_id}.{extension}"),
                                ),
                                replacement_relative_path: destination.clone(),
                                expected_source,
                                expected_replacement: staged.expected,
                            }),
                            Some(staged.path),
                            Some(files),
                            vec![
                                "Every page is copied into the CBZ unchanged and was checked against the original.",
                                "The original CBR is kept in the superseded subfolder.",
                            ],
                        )
                    }
                    Err(message) => {
                        return conflict("comic_conversion_failed", message, &request_id);
                    }
                }
            }
            ArchiveFormat::Unknown => {
                return conflict(
                    "unrecognised_comic_archive",
                    "This file is not a RAR, 7z or ZIP archive, so it cannot be converted.",
                    &request_id,
                );
            }
        };
    let discard = |staging_path: &Option<std::path::PathBuf>| {
        if let Some(path) = staging_path {
            let _ = std::fs::remove_file(path);
        }
    };
    // The source must not have changed while it was being repacked.
    if file_fingerprint(&root_path.join(&item.relative_path))
        .ok()
        .as_deref()
        != Some(match &action {
            BrokerAction::Move(action) => action.expected.as_str(),
            BrokerAction::ConvertComicArchive(action) => action.expected_source.as_str(),
            _ => unreachable!("comic previews create only these actions"),
        })
    {
        discard(&staging_path);
        return conflict(
            "comic_changed",
            "The comic changed while it was being prepared. Try again.",
            &request_id,
        );
    }
    let mut warnings = warnings;
    warnings.push(
        "Kavita sees the .cbz as a new file after its next scan, so reading progress for this comic may reset.",
    );
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let actions = vec![action];
    let digest = sha256_hex(
        &serde_json::to_vec(&json!({
            "actor": identity.username,
            "request": request,
            "actions": actions,
            "expiresAt": expires_at,
        }))
        .expect("serializable comic plan"),
    );
    let plan_id = format!("plan-{request_id}");
    let created = catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json: serde_json::to_string(request).expect("serializable request"),
            expires_at,
            actions: actions.clone(),
        })
        .and_then(|_| {
            catalog.insert_audit_event(
                &request_id,
                &identity.username,
                "comic_archive_conversion_previewed",
                Some(&plan_id),
                &json!({"digest": digest, "itemId": item.id, "format": format.as_str()})
                    .to_string(),
            )
        });
    if created.is_err() {
        discard(&staging_path);
        return ApiError::internal(request_id).into_response();
    }
    (
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "expiresAt": expires_at,
            "actions": actions,
            "warnings": warnings,
            "comicArchive": {
                "format": format.as_str(),
                "destinationRelativePath": destination,
                "files": files,
            },
            "requestId": request_id,
        })),
    )
        .into_response()
}

struct StagedCbz {
    filename: String,
    path: std::path::PathBuf,
    expected: String,
}

async fn stage_repack(
    state: &AppState,
    bsdtar: &FilePath,
    source: &std::fs::File,
    request_id: &str,
) -> Result<(StagedCbz, usize), String> {
    let size = source
        .metadata()
        .map_err(|error| format!("inspect comic: {error}"))?
        .len();
    if size > comic_archive::MAX_CONVERTIBLE_BYTES {
        return Err("Comics larger than 4 GiB cannot be converted here.".into());
    }
    let staging_directory = state.config.state_dir.join("provider-staging");
    tokio::fs::create_dir_all(&staging_directory)
        .await
        .map_err(|error| format!("prepare staging: {error}"))?;
    let filename = format!("comic-{request_id}.cbz");
    let path = staging_directory.join(&filename);
    let output = std::fs::OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(0o660)
        .open(&path)
        .map_err(|error| format!("create staging file: {error}"))?;
    let result = comic_archive::repack_as_cbz(bsdtar, source, &output).await;
    let files = match result {
        Ok(files) => files,
        Err(message) => {
            let _ = tokio::fs::remove_file(&path).await;
            return Err(if message.contains("Encryption is not supported") {
                "This comic is password-protected, so it cannot be converted.".into()
            } else {
                format!("The comic could not be converted: {message}.")
            });
        }
    };
    let expected = match file_fingerprint(&path) {
        Ok(expected) => expected,
        Err(error) => {
            let _ = tokio::fs::remove_file(&path).await;
            return Err(format!("inspect staged CBZ: {error}"));
        }
    };
    Ok((
        StagedCbz {
            filename,
            path,
            expected,
        },
        files,
    ))
}
