use super::*;

pub(super) fn router(state: AppState) -> Router {
    let router = Router::new()
        .route("/", get(dashboard))
        .route("/api/accounts/status", get(account_status_api))
        .route("/accounts/new", get(new_account))
        .route("/accounts", post(create_account))
        .route("/accounts/{id}/edit", get(edit_account))
        .route("/accounts/{id}/update", post(update_account))
        .route("/accounts/{id}/toggle-sync", post(toggle_sync))
        .route("/accounts/{id}/sync", post(sync_account))
        .route("/accounts/{id}/reindex", post(reindex_account))
        .route("/search", get(search_page))
        .route("/sender-priorities", post(upsert_sender_priority))
        .route("/sender-priorities/clear", post(clear_sender_priority))
        .route("/attachments", get(attachments_page))
        .route("/attachments/dismiss", post(dismiss_attachments))
        .route("/attachments/restore", post(restore_attachments))
        .route("/attachments/presets", post(save_attachment_filter_preset))
        .route(
            "/attachments/presets/delete",
            post(delete_attachment_filter_preset),
        )
        .route(
            "/attachments/paperless-tasks",
            post(save_attachment_paperless_task),
        )
        .route(
            "/attachments/paperless-tasks/delete",
            post(delete_attachment_paperless_task),
        )
        .route(
            "/attachments/paperless-tasks/toggle",
            post(toggle_attachment_paperless_task),
        )
        .route("/attachments/refresh", post(refresh_attachments))
        .route(
            "/attachments/{attachment_key}/download/browser",
            post(download_attachment_browser),
        )
        .route(
            "/attachments/{attachment_key}/message/browser",
            get(download_attachment_message_browser),
        )
        .route("/attachments/download", post(download_attachments_zip))
        .route(
            "/attachments/send-paperless",
            post(send_attachments_paperless),
        )
        .route("/messages/dismiss", post(dismiss_messages))
        .route("/messages/restore", post(restore_messages))
        .route("/healthz", get(healthz))
        .route("/static/frontend/{*asset_path}", get(frontend_asset))
        .layer(axum::Extension(homelab_common::work::BlockingWork::new(2)))
        .with_state(state);
    homelab_common::work::isolate_handlers(router, 16)
}

async fn dashboard(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<DashboardParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    match load_dashboard_account_views(&state.config, &identity.username) {
        Ok(account_views) => html_response(render_dashboard(
            &identity,
            &account_views,
            params.flash.as_deref(),
            params.error.as_deref(),
        )),
        Err(error) => server_error_page("Failed to load accounts", &error, Some(&identity)),
    }
}

async fn account_status_api(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let payload = match tokio::task::spawn_blocking(move || {
        load_dashboard_status_payload(&config, &username)
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => {
            return no_store_response(json_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                ErrorPayload { error },
            ))
        }
        Err(_) => {
            return no_store_response(json_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                ErrorPayload {
                    error: "status task failed".to_string(),
                },
            ))
        }
    };

    no_store_response(json_response(StatusCode::OK, payload))
}

async fn new_account(headers: HeaderMap) -> Response {
    match identity_from_headers(&headers) {
        Ok(identity) => {
            let empty = CreateAccountForm {
                provider_kind: "gmail".to_string(),
                display_name: String::new(),
                imap_host: "imap.gmail.com".to_string(),
                imap_port: "993".to_string(),
                imap_username: identity.email.clone().unwrap_or_default(),
                secret: String::new(),
                folder_patterns: gmail_default_patterns().join("\n"),
                sync_enabled: Some("on".to_string()),
            };

            html_response(render_account_form(
                &identity,
                "Add Mailbox",
                "Add a mailbox",
                "Connect a mailbox so saved messages and attachments can be searched later.",
                "/accounts",
                "Save mailbox",
                true,
                &empty,
                None,
                None,
            ))
        }
        Err((status, message)) => auth_error(status, &message),
    }
}

async fn edit_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    match load_account_for_user(&state.config, &identity.username, account_id) {
        Ok(account) => {
            let form = account_form_from_account(&account);
            html_response(render_account_form(
                &identity,
                "Edit Mailbox",
                "Edit mailbox",
                "Leave the app password blank to keep the current saved password.",
                &format!("/accounts/{}/update", account.id),
                "Save changes",
                false,
                &form,
                Some("Leave blank to keep the current saved password."),
                None,
            ))
        }
        Err(error) => server_error_page("Failed to load mailbox", &error, Some(&identity)),
    }
}

async fn create_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<CreateAccountForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    match validate_account_form(&form, true) {
        Ok(validated) => match insert_account(&state.config, &identity.username, validated) {
            Ok(_) => redirect_response("/?flash=Mailbox+saved"),
            Err(error) => server_error_page("Failed to save mailbox", &error, Some(&identity)),
        },
        Err(error) => html_response(render_account_form(
            &identity,
            "Add Mailbox",
            "Add a mailbox",
            "Connect a mailbox so saved messages and attachments can be searched later.",
            "/accounts",
            "Save mailbox",
            true,
            &form,
            None,
            Some(&error),
        )),
    }
}

async fn update_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
    Form(form): Form<CreateAccountForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    match validate_account_form(&form, false) {
        Ok(validated) => {
            match update_account_for_user(&state.config, &identity.username, account_id, validated)
            {
                Ok(_) => redirect_response("/?flash=Mailbox+updated"),
                Err(error) => {
                    server_error_page("Failed to update mailbox", &error, Some(&identity))
                }
            }
        }
        Err(error) => html_response(render_account_form(
            &identity,
            "Edit Mailbox",
            "Edit mailbox",
            "Leave the app password blank to keep the current saved password.",
            &format!("/accounts/{account_id}/update"),
            "Save changes",
            false,
            &form,
            Some("Leave blank to keep the current saved password."),
            Some(&error),
        )),
    }
}

async fn toggle_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    match toggle_sync_for_user(&state.config, &identity.username, account_id) {
        Ok(true) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Automatic updates enabled",
            Some(account_id),
        ),
        Ok(false) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Automatic updates disabled",
            Some(account_id),
        ),
        Ok(true) => redirect_response("/?flash=Automatic+updates+enabled"),
        Ok(false) => redirect_response("/?flash=Automatic+updates+disabled"),
        Err(error) if wants_json => {
            action_json_response(StatusCode::BAD_REQUEST, false, &error, Some(account_id))
        }
        Err(error) => server_error_page("Failed to update schedule", &error, Some(&identity)),
    }
}

async fn sync_account(
    State(state): State<AppState>,
    axum::Extension(jobs): axum::Extension<homelab_common::work::BlockingWork>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        if wants_json {
            return action_json_response(StatusCode::NOT_FOUND, false, &error, Some(account_id));
        }
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    if jobs
        .try_spawn(move || {
            if let Err(error) =
                run_account_action_for_user(&config, &username, account_id, AccountAction::Sync)
            {
                eprintln!("mailbox action failed: {error}");
            }
        })
        .is_err()
    {
        let message = "Mailbox workers are busy. Try again shortly.";
        return if wants_json {
            action_json_response(
                StatusCode::SERVICE_UNAVAILABLE,
                false,
                message,
                Some(account_id),
            )
        } else {
            auth_error(StatusCode::SERVICE_UNAVAILABLE, message)
        };
    }

    if wants_json {
        action_json_response(
            StatusCode::ACCEPTED,
            true,
            "Mailbox update started",
            Some(account_id),
        )
    } else {
        redirect_response("/?flash=Mailbox+update+started")
    }
}

async fn reindex_account(
    State(state): State<AppState>,
    axum::Extension(jobs): axum::Extension<homelab_common::work::BlockingWork>,
    headers: HeaderMap,
    Path(account_id): Path<i64>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, Some(account_id))
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, Some(account_id));
        }
        return auth_error(status, &message);
    }

    if let Err(error) = load_account_for_user(&state.config, &identity.username, account_id) {
        if wants_json {
            return action_json_response(StatusCode::NOT_FOUND, false, &error, Some(account_id));
        }
        return server_error_page("Failed to load mailbox", &error, Some(&identity));
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    if jobs
        .try_spawn(move || {
            if let Err(error) =
                run_account_action_for_user(&config, &username, account_id, AccountAction::Reindex)
            {
                eprintln!("mailbox action failed: {error}");
            }
        })
        .is_err()
    {
        let message = "Mailbox workers are busy. Try again shortly.";
        return if wants_json {
            action_json_response(
                StatusCode::SERVICE_UNAVAILABLE,
                false,
                message,
                Some(account_id),
            )
        } else {
            auth_error(StatusCode::SERVICE_UNAVAILABLE, message)
        };
    }

    if wants_json {
        action_json_response(
            StatusCode::ACCEPTED,
            true,
            "Search repair started",
            Some(account_id),
        )
    } else {
        redirect_response("/?flash=Search+repair+started")
    }
}

async fn search_page(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let accounts = match list_accounts_for_user(&state.config, &identity.username) {
        Ok(accounts) => accounts,
        Err(error) => {
            return server_error_page("Failed to load mailboxes", &error, Some(&identity))
        }
    };

    // Visits without search parameters browse all saved mail; explicit filter
    // parameters turn the page into a search that also surfaces dismissed mail.
    let filters = message_filters_from_search_params(&params, String::new());
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let selected_account_id = normalize_selected_account_id(&accounts, params.account_id);
    let is_searching = message_filters_have_terms(&filters)
        || priority_filter != SenderPriorityFilter::All
        || selected_account_id.is_some();

    let results = {
        let config = state.config.clone();
        let username = identity.username.clone();
        let filters_clone = filters.clone();
        match tokio::task::spawn_blocking(move || {
            let mut results = search_mail(
                &config,
                &username,
                selected_account_id,
                filters_clone,
                priority_filter,
                is_searching,
            )?;
            results.sort_by(|left, right| {
                left.sender_priority
                    .priority
                    .sort_rank()
                    .cmp(&right.sender_priority.priority.sort_rank())
                    .then(right.timestamp.cmp(&left.timestamp))
            });
            Ok::<_, String>(results)
        })
        .await
        {
            Ok(Ok(results)) => results,
            Ok(Err(error)) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &filters,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some(error),
                        priority_filter,
                        page: 1,
                        has_previous_page: false,
                        has_next_page: false,
                    },
                    params.flash.as_deref(),
                    params.error.as_deref(),
                ))
            }
            Err(_) => {
                return html_response(render_search(
                    &identity,
                    &accounts,
                    &filters,
                    selected_account_id,
                    &[],
                    &SearchViewState {
                        submitted: true,
                        result_count: 0,
                        empty_message: Some("Search task failed".to_string()),
                        priority_filter,
                        page: 1,
                        has_previous_page: false,
                        has_next_page: false,
                    },
                    params.flash.as_deref(),
                    params.error.as_deref(),
                ))
            }
        }
    };

    let selected_accounts = accounts
        .iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
        .collect::<Vec<_>>();
    let indexed_selected_accounts = selected_accounts
        .iter()
        .filter(|account| {
            ensure_account_paths(&state.config, account)
                .map(|paths| account_index_state(&paths) == IndexState::Indexed)
                .unwrap_or(false)
        })
        .count();

    let empty_message = if selected_accounts.is_empty() {
        Some("No mailbox is available for this search filter.".to_string())
    } else if indexed_selected_accounts == 0 {
        Some(
            "This mailbox is not ready to search yet. Update it from the dashboard first."
                .to_string(),
        )
    } else if results.is_empty() {
        Some(if is_searching {
            "No saved messages matched the current filters.".to_string()
        } else {
            "No saved messages yet. Sync a mailbox from the dashboard to fill the archive."
                .to_string()
        })
    } else {
        None
    };

    let page = parse_page_number(params.page.as_deref());
    let total_count = results.len();
    let start = (page - 1).saturating_mul(MAIL_PER_PAGE);
    let end = usize::min(start + MAIL_PER_PAGE, total_count);
    let page_results = if start >= total_count {
        Vec::new()
    } else {
        results[start..end].to_vec()
    };
    let view_state = SearchViewState {
        submitted: true,
        result_count: total_count,
        empty_message,
        priority_filter,
        page,
        has_previous_page: page > 1 && start < total_count,
        has_next_page: end < total_count,
    };

    html_response(render_search(
        &identity,
        &accounts,
        &filters,
        selected_account_id,
        &page_results,
        &view_state,
        params.flash.as_deref(),
        params.error.as_deref(),
    ))
}

async fn attachments_page(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<AttachmentListParams>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let params_for_task = params.clone();
    let data = match tokio::task::spawn_blocking(move || {
        load_attachment_page_data(&config, &username, &params_for_task)
    })
    .await
    {
        Ok(Ok(data)) => data,
        Ok(Err(error)) => {
            return server_error_page("Failed to load attachments", &error, Some(&identity))
        }
        Err(_) => {
            return server_error_page(
                "Failed to load attachments",
                "Attachment task failed",
                Some(&identity),
            )
        }
    };

    html_response(render_attachments_page(
        &identity,
        &data,
        params.flash.as_deref(),
        params.error.as_deref(),
    ))
}

async fn save_attachment_filter_preset(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPresetSaveForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        save_attachment_filter_preset_for_user(&config, &username, &form)
    })
    .await;

    match result {
        Ok(Ok(preset)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(&format!("Saved attachment filter preset {}", preset.name)),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment preset task failed"),
        )),
    }
}

async fn delete_attachment_filter_preset(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPresetDeleteForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        delete_attachment_filter_preset_for_user(&config, &username, form.preset_id)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some("Attachment filter preset deleted"),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment preset delete task failed"),
        )),
    }
}

async fn save_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskSaveForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        save_attachment_paperless_task_for_user(&config, &username, &form)
    })
    .await;

    match result {
        Ok(Ok(task)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(&format!("Saved Paperless task {}", task.name)),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Paperless task save failed"),
        )),
    }
}

async fn delete_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskDeleteForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        delete_attachment_paperless_task_for_user(&config, &username, form.task_id)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some("Paperless task deleted"),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Paperless task delete failed"),
        )),
    }
}

async fn toggle_attachment_paperless_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentPaperlessTaskToggleForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let enabled = form.enabled.as_deref() == Some("1");
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        set_attachment_paperless_task_enabled(&config, &username, form.task_id, enabled)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(if enabled {
                "Paperless task enabled"
            } else {
                "Paperless task paused"
            }),
            None,
        )),
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Paperless task update failed"),
        )),
    }
}

async fn upsert_sender_priority(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<SenderPriorityForm>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return priority_change_json_response(status, false, &message, form.return_to.clone())
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return priority_change_json_response(status, false, &message, form.return_to.clone());
        }
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        set_sender_priority_rule(
            &config,
            &username,
            &form.sender_kind,
            &form.sender_value,
            &form.priority,
        )
    })
    .await;

    match result {
        Ok(Ok(Some(rule))) => {
            let message = format!(
                "Marked sender {} as {}",
                rule.value,
                rule.priority.dropdown_label().to_lowercase()
            );
            if wants_json {
                priority_change_json_response(StatusCode::OK, true, &message, return_to)
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    Some(&message),
                    None,
                ))
            }
        }
        Ok(Ok(None)) => {
            let message = "Sender importance cleared";
            if wants_json {
                priority_change_json_response(StatusCode::OK, true, message, return_to)
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    Some(message),
                    None,
                ))
            }
        }
        Ok(Err(error)) => {
            if wants_json {
                priority_change_json_response(
                    priority_error_status(&error),
                    false,
                    &error,
                    return_to,
                )
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&error),
                ))
            }
        }
        Err(_) => {
            let message = "Sender importance task failed";
            if wants_json {
                priority_change_json_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    false,
                    message,
                    return_to,
                )
            } else {
                redirect_response(&message_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(message),
                ))
            }
        }
    }
}

fn request_accepts_json(headers: &HeaderMap) -> bool {
    headers
        .get(ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value
                .split(',')
                .any(|part| part.trim().starts_with("application/json"))
        })
}

fn priority_error_status(error: &str) -> StatusCode {
    if error.starts_with("failed ") {
        StatusCode::INTERNAL_SERVER_ERROR
    } else {
        StatusCode::BAD_REQUEST
    }
}

fn priority_change_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    return_to: Option<String>,
) -> Response {
    json_response(
        status,
        PriorityChangePayload {
            ok,
            message: message.to_string(),
            return_to,
        },
    )
}

fn action_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    account_id: Option<i64>,
) -> Response {
    json_response(
        status,
        ActionPayload {
            ok,
            message: message.to_string(),
            account_id,
        },
    )
}

async fn clear_sender_priority(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<SenderPriorityClearForm>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        clear_sender_priority_rule(&config, &username, &form.sender_kind, &form.sender_value)
    })
    .await;

    match result {
        Ok(Ok(())) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            Some("Sender importance cleared"),
            None,
        )),
        Ok(Err(error)) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some("Sender importance task failed"),
        )),
    }
}

async fn refresh_attachments(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<AttachmentRefreshForm>,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, None)
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, None);
        }
        return auth_error(status, &message);
    }

    let selected_account_id = match parse_optional_query_i64(form.account_id.as_deref()) {
        Ok(value) => value,
        Err(error) if wants_json => {
            return action_json_response(StatusCode::BAD_REQUEST, false, &error, None);
        }
        Err(error) => {
            return redirect_response(&attachments_redirect_location(
                form.return_to.as_deref(),
                None,
                Some(error.as_str()),
            ))
        }
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let result = tokio::task::spawn_blocking(move || {
        refresh_attachment_catalog_for_user(&config, &username, selected_account_id)
    })
    .await;

    match result {
        Ok(Ok(())) if wants_json => action_json_response(
            StatusCode::OK,
            true,
            "Attachment list refreshed",
            selected_account_id,
        ),
        Ok(Ok(())) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            Some("Attachment catalog refreshed"),
            None,
        )),
        Ok(Err(error)) if wants_json => {
            action_json_response(StatusCode::BAD_REQUEST, false, &error, selected_account_id)
        }
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) if wants_json => action_json_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            false,
            "Attachment refresh task failed",
            selected_account_id,
        ),
        Err(_) => redirect_response(&attachments_redirect_location(
            form.return_to.as_deref(),
            None,
            Some("Attachment refresh task failed"),
        )),
    }
}

async fn download_attachment_browser(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(attachment_key): Path<String>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let payload = match tokio::task::spawn_blocking(move || {
        let (account, message, attachment) =
            load_attachment_for_user(&config, &username, &attachment_key)?;
        let (_dir, attachment_path) =
            resolve_attachment_payload(&config, &account, &message, &attachment)?;
        let bytes = fs::read(&attachment_path).map_err(|error| {
            format!(
                "failed to read extracted attachment {}: {error}",
                attachment_path.display()
            )
        })?;
        Ok::<_, String>((attachment.original_filename, attachment.mime_type, bytes))
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => return server_error_page("Download failed", &error, Some(&identity)),
        Err(_) => {
            return server_error_page(
                "Download failed",
                "Attachment download task failed",
                Some(&identity),
            )
        }
    };

    attachment_download_response(&payload.0, &payload.1, payload.2)
}

async fn download_attachment_message_browser(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(attachment_key): Path<String>,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    let config = state.config.clone();
    let username = identity.username.clone();
    let payload = match tokio::task::spawn_blocking(move || {
        let (account, message, _attachment) =
            load_attachment_for_user(&config, &username, &attachment_key)?;
        let account_paths = ensure_account_paths(&config, &account)?;
        let message_path = account_paths.maildir.join(&message.message_relpath);
        let bytes = fs::read(&message_path).map_err(|error| {
            format!(
                "failed to read source message {}: {error}",
                message_path.display()
            )
        })?;
        let filename = format!(
            "{} - {}.eml",
            safe_filename(&format_timestamp_date_label(message.timestamp)),
            safe_filename(&decode_display_header_value(&message.subject))
        );
        Ok::<_, String>((filename, bytes))
    })
    .await
    {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => {
            return server_error_page("Email download failed", &error, Some(&identity))
        }
        Err(_) => {
            return server_error_page(
                "Email download failed",
                "Email download task failed",
                Some(&identity),
            )
        }
    };

    attachment_download_response(&payload.0, "message/rfc822", payload.1)
}

async fn download_attachments_zip(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let form = parse_attachment_download_form_body(&body);
    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result =
        tokio::task::spawn_blocking(move || build_attachments_zip(&config, &username, &form)).await;

    match result {
        Ok(Ok(zip_file)) => zip_download_file_response(zip_file).await,
        Ok(Err(error)) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&error),
        )),
        Err(_) => redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some("Attachment ZIP task failed"),
        )),
    }
}

async fn send_attachments_paperless(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        return auth_error(status, &message);
    }

    let form = parse_attachment_paperless_form_body(&body);
    let config = state.config.clone();
    let username = identity.username.clone();
    let return_to = form.return_to.clone();
    let result = tokio::task::spawn_blocking(move || {
        send_attachments_to_paperless(&config, &username, &form.attachment_keys)
    })
    .await;

    match result {
        Ok(Ok(summary)) if summary.successful() > 0 => {
            let failure_message = if summary.failures.is_empty() {
                None
            } else {
                Some(summary.failure_message())
            };
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::OK,
                    true,
                    &summary.flash_message(),
                    failure_message.as_deref(),
                    summary.sent_attachment_keys,
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    Some(&summary.flash_message()),
                    failure_message.as_deref(),
                ))
            }
        }
        Ok(Ok(summary)) => {
            let message = summary.failure_message();
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::BAD_REQUEST,
                    false,
                    &message,
                    Some(&message),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&message),
                ))
            }
        }
        Ok(Err(error)) => {
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::BAD_REQUEST,
                    false,
                    &error,
                    Some(&error),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(&error),
                ))
            }
        }
        Err(_) => {
            let message = "Paperless handoff task failed";
            if wants_json {
                paperless_handoff_json_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    false,
                    message,
                    Some(message),
                    Vec::new(),
                    return_to,
                )
            } else {
                redirect_response(&attachments_redirect_location(
                    return_to.as_deref(),
                    None,
                    Some(message),
                ))
            }
        }
    }
}

fn paperless_handoff_json_response(
    status: StatusCode,
    ok: bool,
    message: &str,
    error: Option<&str>,
    sent_attachment_keys: Vec<String>,
    return_to: Option<String>,
) -> Response {
    json_response(
        status,
        PaperlessHandoffPayload {
            ok,
            message: message.to_string(),
            error: error.map(ToString::to_string),
            sent_attachment_keys,
            return_to,
        },
    )
}

async fn dismiss_attachments(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let form = parse_attachment_dismiss_form_body(&body);
    handle_attachment_dismissal_change(state, headers, form.attachment_keys, form.return_to, true)
        .await
}

async fn restore_attachments(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let form = parse_attachment_dismiss_form_body(&body);
    handle_attachment_dismissal_change(state, headers, form.attachment_keys, form.return_to, false)
        .await
}

async fn handle_attachment_dismissal_change(
    state: AppState,
    headers: HeaderMap,
    attachment_keys: Vec<String>,
    return_to: Option<String>,
    dismissed: bool,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, None)
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, None);
        }
        return auth_error(status, &message);
    }

    let config = state.config.clone();
    let username = identity.username.clone();
    let result = tokio::task::spawn_blocking(move || {
        set_attachment_dismissals(&config, &username, &attachment_keys, dismissed)
    })
    .await;

    let flash = match &result {
        Ok(Ok(changed)) if changed.len() == 1 => {
            if dismissed {
                "Attachment dismissed".to_string()
            } else {
                "Attachment restored".to_string()
            }
        }
        Ok(Ok(changed)) => format!(
            "{} attachments {}",
            changed.len(),
            if dismissed { "dismissed" } else { "restored" }
        ),
        Ok(Err(error)) => error.clone(),
        Err(_) => "Attachment dismissal task failed".to_string(),
    };
    let ok = matches!(&result, Ok(Ok(_)));

    if wants_json {
        action_json_response(
            if ok {
                StatusCode::OK
            } else {
                StatusCode::BAD_REQUEST
            },
            ok,
            &flash,
            None,
        )
    } else if ok {
        redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            Some(&flash),
            None,
        ))
    } else {
        redirect_response(&attachments_redirect_location(
            return_to.as_deref(),
            None,
            Some(&flash),
        ))
    }
}

async fn dismiss_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<MessageDismissForm>,
) -> Response {
    handle_message_dismissal_change(
        state,
        headers,
        form.account_id,
        &form.message_key,
        form.return_to,
        true,
    )
    .await
}

async fn restore_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(form): Form<MessageRestoreForm>,
) -> Response {
    handle_message_dismissal_change(
        state,
        headers,
        form.account_id,
        &form.message_key,
        form.return_to,
        false,
    )
    .await
}

async fn handle_message_dismissal_change(
    state: AppState,
    headers: HeaderMap,
    account_id: Option<i64>,
    message_key: &str,
    return_to: Option<String>,
    dismissed: bool,
) -> Response {
    let wants_json = request_accepts_json(&headers);
    let identity = match identity_from_headers(&headers) {
        Ok(identity) => identity,
        Err((status, message)) if wants_json => {
            return action_json_response(status, false, &message, None)
        }
        Err((status, message)) => return auth_error(status, &message),
    };

    if let Err((status, message)) = verify_same_origin_request(&headers) {
        if wants_json {
            return action_json_response(status, false, &message, None);
        }
        return auth_error(status, &message);
    }

    let message_key = message_key.trim().to_string();
    let config = state.config.clone();
    let username = identity.username.clone();
    let accounts = match list_accounts_for_user(&config, &username) {
        Ok(accounts) => accounts,
        Err(error) => {
            if wants_json {
                return action_json_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    false,
                    &error,
                    None,
                );
            }
            return server_error_page("Failed to load mailboxes", &error, Some(&identity));
        }
    };
    let Some(account_id) = normalize_selected_account_id(&accounts, account_id) else {
        let message = "Unknown mailbox for this message.";
        if wants_json {
            return action_json_response(StatusCode::BAD_REQUEST, false, message, None);
        }
        return redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some(message),
        ));
    };

    let result = tokio::task::spawn_blocking(move || {
        set_message_dismissals(
            &config,
            &username,
            account_id,
            std::slice::from_ref(&message_key),
            dismissed,
        )
    })
    .await;

    let flash = match &result {
        Ok(Ok(changed)) if !changed.is_empty() => {
            if dismissed {
                "Message dismissed".to_string()
            } else {
                "Message restored".to_string()
            }
        }
        Ok(Ok(_)) => "Message was already up to date".to_string(),
        Ok(Err(error)) => error.clone(),
        Err(_) => "Message dismissal task failed".to_string(),
    };
    let ok = matches!(&result, Ok(Ok(changed)) if !changed.is_empty());

    if wants_json {
        action_json_response(
            if ok {
                StatusCode::OK
            } else {
                StatusCode::BAD_REQUEST
            },
            ok,
            &flash,
            Some(account_id),
        )
    } else if ok {
        redirect_response(&message_redirect_location(
            return_to.as_deref(),
            Some(&flash),
            None,
        ))
    } else {
        redirect_response(&message_redirect_location(
            return_to.as_deref(),
            None,
            Some(&flash),
        ))
    }
}

async fn healthz(State(state): State<AppState>) -> Response {
    let (status, payload) = health_payload(&state.config);
    json_response(status, payload)
}

async fn frontend_asset(State(state): State<AppState>, Path(asset_path): Path<String>) -> Response {
    let root = PathBuf::from(state.config.frontend_dist_dir.as_ref());
    let relative = FsPath::new(asset_path.as_str());
    let bytes = match homelab_common::read_static_file(&root, relative).await {
        Ok(bytes) => bytes,
        Err(_) => {
            return html_response_with_status(
                StatusCode::NOT_FOUND,
                "frontend asset not found".to_string(),
            )
        }
    };
    let candidate = root.join(relative);
    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = StatusCode::OK;
    response.headers_mut().insert(
        CONTENT_TYPE,
        HeaderValue::from_static(homelab_common::content_type_for_path(&candidate)),
    );
    harden_response(response)
}
