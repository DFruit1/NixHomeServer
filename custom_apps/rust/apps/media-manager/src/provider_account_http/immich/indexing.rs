use super::*;

// One page per account per round prevents a large library starving other users.
// Checkpoints advance only after the page is processed. Completed analyses are
// reused after a restart; failed photos retry on the next half-hour sweep.
pub(in crate::provider_account_http) async fn run_indexer(state: ProviderBrokerState) {
    let Some(runtime) = state.images.clone() else {
        return;
    };
    loop {
        match state.store.image_accounts(runtime.managed) {
            Ok(identities) => {
                for identity in identities {
                    let id = request_id();
                    let result = index_page(&state, &runtime, &identity, &id).await;
                    if result.is_err() {
                        eprintln!(
                            "{}",
                            json!({"service":"media-manager-provider-broker","event":"image_index_retry","requestId":id})
                        );
                    }
                }
            }
            Err(_) => eprintln!(
                "{}",
                json!({"service":"media-manager-provider-broker","event":"image_accounts_unavailable"})
            ),
        }
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

async fn index_page(
    state: &ProviderBrokerState,
    runtime: &Arc<Runtime>,
    identity: &Identity,
    id: &str,
) -> Result<(), ApiError> {
    // These are already-provisioned owner credentials, not forwarded identity
    // claims. HTTP reads still enforce the current Photos membership separately.
    let account = load_account(state, identity, runtime.clone(), id)?;
    let scope = account.scope(identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    let (page, generation, next_scan) = index.scan().map_err(|_| index_error(id))?;
    let now = unix_timestamp();
    if next_scan > now {
        return Ok(());
    }
    let result = process_page(state, &account, &index, page, generation, now, id).await;
    if result.is_err() {
        index.fail().map_err(|_| index_error(id))?;
    }
    result
}

async fn process_page(
    state: &ProviderBrokerState,
    account: &Account,
    index: &Index<'_>,
    page: u32,
    generation: i64,
    now: i64,
    id: &str,
) -> Result<(), ApiError> {
    // No visibility filter: include archived photos, but never locked, hidden,
    // trashed or non-image assets. Only authenticated API previews are read.
    let response: SearchResponse = account.json(state, Method::POST, "search/metadata",
        Some(json!({"type":"IMAGE","page":page,"size":PAGE_SIZE,"withExif":false,"withPeople":false,"withStacked":true})), id).await?;
    if response.assets.items.len() > PAGE_SIZE || response.assets.items.iter().any(|a| !a.valid()) {
        return Err(upstream_error(id));
    }
    let next = response
        .assets
        .next_page
        .map(|p| p.parse::<u32>())
        .transpose()
        .map_err(|_| upstream_error(id))?;
    if next.is_some_and(|p| p <= page || p > 100_000) {
        return Err(upstream_error(id));
    }
    let mut failed = false;
    for asset in response.assets.items {
        if asset.kind != "IMAGE"
            || asset.is_trashed
            || !matches!(asset.visibility.as_str(), "timeline" | "archive")
        {
            continue;
        }
        index
            .observe(
                &asset.id,
                &asset.original_file_name,
                &asset.file_created_at,
                generation,
            )
            .map_err(|_| index_error(id))?;
        if index
            .decision_retry(&asset.id, None)
            .map_err(|_| index_error(id))?
            <= now
            && decisions::background(state, account, index, &asset, id)
                .await
                .is_err()
        {
            index
                .decision_retry(&asset.id, Some(now + 1800))
                .map_err(|_| index_error(id))?;
            eprintln!(
                "{}",
                json!({"service":"media-manager-provider-broker","event":"decision_assessment_retry","requestId":id})
            );
        }
        if (index.tagged(&asset.id).map_err(|_| index_error(id))?
            && index
                .analysis(&asset.id)
                .map_err(|_| index_error(id))?
                .is_some())
            || index
                .retry_at(&asset.id, None)
                .map_err(|_| index_error(id))?
                > now
        {
            continue;
        }
        match analyze_asset(state, account, index, &asset.id, id, true).await {
            Ok(_) => {}
            Err(err)
                if matches!(
                    err.status(),
                    StatusCode::SERVICE_UNAVAILABLE
                        | StatusCode::TOO_MANY_REQUESTS
                        | StatusCode::FORBIDDEN
                ) =>
            {
                return Err(err)
            }
            Err(_) => {
                index
                    .retry_at(&asset.id, Some(now + 1800))
                    .map_err(|_| index_error(id))?;
                failed = true;
            }
        }
        // Bound background pressure; the shared gate also serializes interactive
        // inference with the worker, rather than causing EYE busy failures.
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    index
        .advance(next, generation, now, failed)
        .map_err(|_| index_error(id))?;
    Ok(())
}

pub(in crate::provider_account_http) async fn indexed(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    query: Result<Query<Search>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<Value>, ApiError> {
    let id = request_id();
    let identity = identity_from_headers(&headers, &id)?;
    let Query(query) = query.map_err(|_| {
        error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "image_query_invalid",
            "Supply valid photo filters and sort settings.",
            &id,
        )
    })?;
    if !query.valid() {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "image_query_invalid",
            "Supply valid photo filters and sort settings.",
            &id,
        ));
    }
    let account = account(&state, &identity, &id)?;
    let scope = account.scope(&identity);
    let index = Index {
        store: &state.store,
        scope: &scope,
    };
    if !query.semantic_query.trim().is_empty() {
        let (items, next_cursor) = semantic_page(&state, &account, &index, &query, &id).await?;
        return Ok(Json(
            json!({"items":items,"nextPage":null,"nextCursor":next_cursor,
            "canTag":false,"index":index.status().map_err(|_|index_error(&id))?,
            "tagMatches":[],"requestId":id}),
        ));
    }
    let mut ids = index.search(&query).map_err(|_| index_error(&id))?;
    let next = (ids.len() > PAGE_SIZE && query.page < 100_000).then_some(query.page + 1);
    ids.truncate(PAGE_SIZE);
    let mut items = Vec::new();
    let mut verified_ids = Vec::new();
    // Recheck current upstream authorization before returning *any* cached
    // filename, tag or score. Deletion, archive/lock changes, credential changes
    // and lost access must not expose previously indexed private metadata.
    for chunk in ids.chunks(6) {
        let mut pending = Vec::new();
        for asset_id in chunk {
            let state = state.clone();
            let account = account.clone();
            let id = id.clone();
            let asset_id = asset_id.clone();
            pending.push(tokio::spawn(async move {
                account.asset(&state, &asset_id, &id).await
            }));
        }
        for task in pending {
            let result = task.await.map_err(|_| index_error(&id))?;
            match result {
                Ok(asset) => {
                    verified_ids.push(asset.id.clone());
                    items.push(indexed_item(&index, asset, &id)?);
                }
                Err(err) if err.status() == StatusCode::NOT_FOUND => {}
                Err(err) => return Err(err),
            }
        }
    }
    let tag_matches = index
        .tag_matches(&query, &verified_ids)
        .map_err(|_| index_error(&id))?;
    Ok(Json(
        json!({"items":items,"nextPage":next,"canTag":false,"index":index.status().map_err(|_|index_error(&id))?,"tagMatches":tag_matches,"requestId":id}),
    ))
}

fn indexed_item(index: &Index<'_>, asset: Asset, id: &str) -> Result<Value, ApiError> {
    let analysis = index.analysis(&asset.id).map_err(|_| index_error(id))?;
    let tagged = index.tagged(&asset.id).map_err(|_| index_error(id))?;
    let decision_tags = index
        .decision_tags(&asset.id)
        .map_err(|_| index_error(id))?;
    let mut item = asset.public();
    item["analysis"] = json!(analysis);
    item["tagged"] = json!(tagged);
    item["decisionTags"] = json!(decision_tags);
    Ok(item)
}

/// Reuse Immich's image embeddings and text encoder. The cursor counts raw
/// upstream results, not filtered matches, so sparse filters cannot hide later
/// pages or skip the remainder of a page. Bound work even for a huge library;
/// an empty batch can still have a continuation, which the UI must retain.
async fn semantic_page(
    state: &ProviderBrokerState,
    account: &Account,
    index: &Index<'_>,
    query: &Search,
    id: &str,
) -> Result<(Vec<Value>, Option<u32>), ApiError> {
    let mut cursor = query.cursor;
    let mut items = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for _ in 0..8 {
        let page = cursor / PAGE_SIZE as u32 + 1;
        let offset = cursor as usize % PAGE_SIZE;
        let response: SearchResponse = account
            .json(
                state,
                Method::POST,
                "search/smart",
                Some(
                    json!({"query":query.semantic_query.trim(),"type":"IMAGE","page":page,
                "size":PAGE_SIZE,"withExif":false}),
                ),
                id,
            )
            .await?;
        if response.assets.items.len() > PAGE_SIZE
            || response.assets.items.iter().any(|a| !a.valid())
        {
            return Err(upstream_error(id));
        }
        let next = response
            .assets
            .next_page
            .map(|p| p.parse::<u32>())
            .transpose()
            .map_err(|_| upstream_error(id))?;
        if next.is_some_and(|p| p <= page || p > 100_000) {
            return Err(upstream_error(id));
        }
        let candidates: Vec<_> = response
            .assets
            .items
            .iter()
            .filter(|a| {
                a.kind == "IMAGE"
                    && !a.is_trashed
                    && matches!(a.visibility.as_str(), "timeline" | "archive")
            })
            .map(|a| {
                (
                    a.id.clone(),
                    a.original_file_name.clone(),
                    a.file_created_at.clone(),
                )
            })
            .collect();
        let allowed = index
            .filter_candidates(query, &candidates)
            .map_err(|_| index_error(id))?;
        let matches: Vec<_> = response
            .assets
            .items
            .into_iter()
            .enumerate()
            .skip(offset)
            .filter(|(_, candidate)| {
                allowed.contains(&candidate.id) && seen.insert(candidate.id.clone())
            })
            .collect();
        for chunk in matches.chunks(6) {
            // A stale search hit must not expose cached metadata after locking,
            // deletion, or an access change. Keep the existing per-asset check.
            // Limit concurrency to the same six reads as saved-tag browsing.
            let current = futures_util::future::join_all(chunk.iter().map(
                |(position, candidate)| async move {
                    (*position, account.asset(state, &candidate.id, id).await)
                },
            ))
            .await;
            for (position, result) in current {
                let asset = match result {
                    Ok(asset) => asset,
                    Err(err) if err.status() == StatusCode::NOT_FOUND => continue,
                    Err(err) => return Err(err),
                };
                if items.len() == PAGE_SIZE {
                    return Ok((items, Some((page - 1) * PAGE_SIZE as u32 + position as u32)));
                }
                items.push(indexed_item(index, asset, id)?);
            }
        }
        let Some(next) = next else {
            return Ok((items, None));
        };
        cursor = (next - 1) * PAGE_SIZE as u32;
    }
    Ok((items, Some(cursor)))
}
