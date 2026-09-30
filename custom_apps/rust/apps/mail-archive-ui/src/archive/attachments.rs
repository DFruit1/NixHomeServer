use super::super::*;

pub(crate) fn load_attachment_page_data(
    config: &AppConfig,
    username: &str,
    params: &AttachmentListParams,
) -> Result<AttachmentPageData, String> {
    let accounts = list_accounts_for_user(config, username)?;
    let presets = list_attachment_filter_presets(config, username)?;
    let paperless_tasks = list_attachment_paperless_tasks(config, username)?;
    let selected_account_id = normalize_selected_account_id(&accounts, params.account_id);
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let raw_filters = attachment_filters_from_params(params);
    let filters = parse_attachment_search_filters(raw_filters)?;
    let general_query = filters.raw.message.q.trim().to_string();
    let structured_message_filters =
        parse_message_search_filters(message_filters_without_general_query(&filters.raw.message))?;
    let general_query_filters = if general_query.is_empty() {
        None
    } else {
        Some(parse_message_search_filters(MessageSearchFilters {
            q: general_query.clone(),
            ..Default::default()
        })?)
    };
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;
    let page = parse_page_number(params.page.as_deref());
    let mut connection = open_db(config)?;
    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to open attachment snapshot: {error}"))?;
    let connection = &transaction;
    let paperless_handoffs = load_attachment_paperless_handoffs(connection, username)?;
    let dismissals = load_attachment_dismissals(connection, username)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let has_search_terms = message_filters_have_terms(&filters.raw.message)
        || priority_filter != SenderPriorityFilter::All
        || selected_account_id.is_some()
        || !filters.raw.extension.is_empty()
        || !filters.raw.attachment_name.is_empty()
        || !filters.raw.min_size.is_empty()
        || !filters.raw.max_size.is_empty()
        || include_inline
        || include_inline_images;
    let mut indexed_accounts = Vec::new();
    let mut query_relpaths_by_account = HashMap::<i64, HashSet<String>>::new();
    let mut general_query_relpaths_by_account = HashMap::<i64, HashSet<String>>::new();

    for account in accounts
        .iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        let account_paths = ensure_account_paths(config, account)?;
        if account_index_state(&account_paths) != IndexState::Indexed {
            continue;
        }

        if message_filters_have_terms(&structured_message_filters.raw) {
            let relpaths = list_notmuch_message_files(
                &account_paths,
                &notmuch_query_for_filters(&structured_message_filters),
            )?
            .into_iter()
            .map(|path| {
                message_relative_path(&account_paths, &path)
                    .map(|relative| relative.to_string_lossy().to_string())
            })
            .collect::<Result<HashSet<_>, _>>()?;
            query_relpaths_by_account.insert(account.id, relpaths);
        }
        if let Some(general_query_filters) = general_query_filters.as_ref() {
            let relpaths = list_notmuch_message_files(
                &account_paths,
                &notmuch_query_for_filters(general_query_filters),
            )?
            .into_iter()
            .map(|path| {
                message_relative_path(&account_paths, &path)
                    .map(|relative| relative.to_string_lossy().to_string())
            })
            .collect::<Result<HashSet<_>, _>>()?;
            general_query_relpaths_by_account.insert(account.id, relpaths);
        }

        indexed_accounts.push(account.id);
    }

    // SQLite owns filtering/order/pagination. The UDF reuses the exact MIME,
    // priority and Notmuch predicates instead of changing their semantics.
    // Only the bounded display page is retained as Rust attachment records.
    let page_filters = filters.clone();
    let page_priorities = priority_rules.clone();
    let account_names = accounts
        .iter()
        .map(|account| (account.id, account.display_name.clone()))
        .collect::<HashMap<_, _>>();
    let page_handoffs = paperless_handoffs.clone();
    let page_dismissals = dismissals.clone();
    connection
        .create_scalar_function(
            "attachment_rank",
            28,
            rusqlite::functions::FunctionFlags::SQLITE_UTF8
                | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC,
            move |context| {
                let filters = &page_filters;
                let priority_rules = &page_priorities;
                let paperless_handoffs = &page_handoffs;
                let dismissals = &page_dismissals;
                let (message, attachment) = attachment_catalog_row(context)?;
                if message_filters_have_terms(&structured_message_filters.raw)
                    && !query_relpaths_by_account
                        .get(&message.account_id)
                        .is_some_and(|relpaths| relpaths.contains(&message.message_relpath))
                {
                    return Ok(-1_i64);
                }
                if !include_inline && attachment_is_body_artifact(&attachment) {
                    return Ok(-1_i64);
                }
                if !include_inline_images && attachment_is_inline_image(&attachment) {
                    return Ok(-1_i64);
                }

                let sender_priority = priority_rules.view_for_sender(&message.from);
                if !priority_filter.matches(sender_priority.priority) {
                    return Ok(-1_i64);
                }

                let mut item = AttachmentListItem {
                    account_name: account_names
                        .get(&message.account_id)
                        .cloned()
                        .unwrap_or_default(),
                    attachment,
                    message,
                    sender_priority,
                    paperless_sent_at: None,
                    dismissed_at: None,
                    message_preview: None,
                    message_preview_truncated: false,
                    message_cc: None,
                };
                if !message_matches_filters(
                    &LiveMessageRecord {
                        message_key: item.message.message_key.clone(),
                        message_relpaths: vec![item.message.message_relpath.clone()],
                        subject: item.message.subject.clone(),
                        from: item.message.from.clone(),
                        timestamp: item.message.timestamp,
                    },
                    &structured_message_filters,
                    Some(item.message.has_attachments),
                ) {
                    return Ok(-1_i64);
                }
                if !general_query.is_empty() {
                    let message_body_match = general_query_relpaths_by_account
                        .get(&item.message.account_id)
                        .is_some_and(|relpaths| relpaths.contains(&item.message.message_relpath));
                    if !attachment_general_query_matches(&item, &general_query, message_body_match)
                    {
                        return Ok(-1_i64);
                    }
                }
                let attachment_count = context.get::<i64>(27)? as usize;
                if !attachment_matches_filters(&item, filters, attachment_count) {
                    return Ok(-1_i64);
                }
                item.paperless_sent_at = paperless_handoffs
                    .get(&item.attachment.attachment_key)
                    .cloned();
                item.dismissed_at = dismissals.get(&item.attachment.attachment_key).cloned();
                if !has_search_terms
                    && (item.paperless_sent_at.is_some() || item.dismissed_at.is_some())
                {
                    return Ok(-2_i64);
                }
                Ok(i64::from(item.sender_priority.priority.sort_rank()))
            },
        )
        .map_err(|error| format!("failed to prepare attachment filters: {error}"))?;
    let account_scope = if indexed_accounts.is_empty() {
        "NULL".to_string()
    } else {
        indexed_accounts
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(",")
    };
    let account_order = indexed_accounts
        .iter()
        .enumerate()
        .map(|(order, id)| format!("WHEN {id} THEN {order}"))
        .collect::<Vec<_>>()
        .join(" ");
    let account_order = if account_order.is_empty() {
        "0".to_string()
    } else {
        format!("CASE c.account_id {account_order} END")
    };
    connection.execute("CREATE TEMP TABLE attachment_page_matches AS SELECT c.attachment_key, m.timestamp, c.attachment_index, c.rowid AS tie, 0 AS account_order, -1 AS rank FROM attachment_catalog c JOIN attachment_messages m ON m.account_id=c.account_id AND m.message_key=c.message_key WHERE 0", [])
        .map_err(|error| format!("failed to prepare attachment page: {error}"))?;
    connection.execute(&format!(
        "INSERT INTO attachment_page_matches SELECT c.attachment_key,m.timestamp,c.attachment_index,c.rowid,{account_order},
         attachment_rank({ATTACHMENT_COLUMNS}, 0)
         FROM attachment_catalog c JOIN attachment_messages m ON m.account_id=c.account_id AND m.message_key=c.message_key
         WHERE c.account_id IN ({account_scope}) AND (?1='' OR c.extension=?1)
           AND (?2 IS NULL OR c.size_bytes>=?2) AND (?3 IS NULL OR c.size_bytes<=?3)"
    ), params![filters.raw.extension, filters.min_size_bytes, filters.max_size_bytes])
        .map_err(|error| format!("failed to filter attachment page: {error}"))?;
    let (total_count, hidden_unfiled): (i64, i64) = connection
        .query_row(
            "SELECT COALESCE(SUM(rank>=0),0),COALESCE(SUM(rank=-2),0) FROM attachment_page_matches",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| format!("failed to count attachment page: {error}"))?;
    let total_count = total_count as usize;
    let hidden_unfiled = hidden_unfiled as usize;
    connection.execute_batch("DELETE FROM attachment_page_matches WHERE rank<0; CREATE INDEX temp.attachment_page_order ON attachment_page_matches(rank, timestamp DESC, attachment_index, account_order, tie)")
        .map_err(|error| format!("failed to order attachment page: {error}"))?;
    let start = (page - 1).saturating_mul(ATTACHMENTS_PER_PAGE);
    let end = start.saturating_add(ATTACHMENTS_PER_PAGE).min(total_count);
    let mut statement = connection.prepare(&format!(
        "SELECT {ATTACHMENT_COLUMNS} FROM attachment_page_matches page
         JOIN attachment_catalog c ON c.attachment_key=page.attachment_key
         JOIN attachment_messages m ON m.account_id=c.account_id AND m.message_key=c.message_key
         WHERE page.rank>=0 ORDER BY page.rank,page.timestamp DESC,page.attachment_index,page.account_order,page.tie LIMIT ?1 OFFSET ?2"
    )).map_err(|error| format!("failed to prepare attachment page: {error}"))?;
    let records = statement
        .query_map(
            params![
                ATTACHMENTS_PER_PAGE as i64,
                i64::try_from(start).unwrap_or(i64::MAX)
            ],
            |row| attachment_catalog_row(row),
        )
        .map_err(|error| format!("failed to query attachment page: {error}"))?;
    let mut page_items = Vec::with_capacity(ATTACHMENTS_PER_PAGE);
    for record in records {
        let (message, attachment) =
            record.map_err(|error| format!("failed to decode attachment page: {error}"))?;
        page_items.push(AttachmentListItem {
            account_name: accounts
                .iter()
                .find(|account| account.id == message.account_id)
                .map(|account| account.display_name.clone())
                .unwrap_or_default(),
            sender_priority: priority_rules.view_for_sender(&message.from),
            message,
            attachment,
            paperless_sent_at: None,
            dismissed_at: None,
            message_preview: None,
            message_preview_truncated: false,
            message_cc: None,
        });
    }
    for item in &mut page_items {
        item.paperless_sent_at = paperless_handoffs
            .get(&item.attachment.attachment_key)
            .cloned();
        item.dismissed_at = dismissals.get(&item.attachment.attachment_key).cloned();
    }

    let accounts_by_id = accounts
        .iter()
        .map(|account| (account.id, account))
        .collect::<HashMap<_, _>>();
    for item in &mut page_items {
        let Some(account) = accounts_by_id.get(&item.message.account_id) else {
            continue;
        };
        let Ok(account_paths) = ensure_account_paths(config, account) else {
            continue;
        };
        let message_path = account_paths.maildir.join(&item.message.message_relpath);
        if let Ok(context) = read_message_context_preview(&message_path, 760) {
            item.message_preview = context.body;
            item.message_preview_truncated = context.truncated;
            item.message_cc = context.cc;
        }
    }
    let base_query = build_attachment_base_query(AttachmentBaseQuery {
        filters: &filters.raw,
        selected_account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    });
    let empty_message = if selected_account_id.is_some()
        && page_items.is_empty()
        && total_count == 0
    {
        Some("No attachments matched this mailbox filter.".to_string())
    } else if page_items.is_empty() && total_count == 0 {
        if !has_search_terms && hidden_unfiled > 0 {
            Some(
                    "Every matching attachment is already sent to Paperless or dismissed. Search to see them again."
                        .to_string(),
                )
        } else {
            Some("No catalogued attachments matched the current filters.".to_string())
        }
    } else {
        None
    };

    Ok(AttachmentPageData {
        accounts,
        selected_account_id,
        presets,
        paperless_tasks,
        filters: filters.raw,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder,
        items: page_items,
        state: AttachmentListViewState {
            priority_filter,
            page,
            result_count: total_count,
            has_previous_page: page > 1 && start < total_count,
            has_next_page: end < total_count,
            empty_message,
            base_query,
        },
    })
}

pub(crate) fn download_attachment_keys_for_form(
    config: &AppConfig,
    username: &str,
    form: &AttachmentDownloadForm,
) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();

    if form.selection_scope.as_deref() == Some(ATTACHMENT_SELECTION_ALL_MATCHING) {
        let selected_account_id = parse_optional_query_i64(form.account_id.as_deref())?;
        let mut page = 1;
        loop {
            let params = AttachmentListParams {
                q: form.q.clone(),
                account_id: selected_account_id,
                priority: form.priority.clone(),
                sender_address: form.sender_address.clone(),
                sender_name: form.sender_name.clone(),
                sender_domain: form.sender_domain.clone(),
                subject: form.subject.clone(),
                body_text: form.body_text.clone(),
                date_from: form.date_from.clone(),
                date_to: form.date_to.clone(),
                has_attachments: form.has_attachments.clone(),
                extension: form.extension.clone(),
                extension_custom: None,
                attachment_name: form.attachment_name.clone(),
                mime_type: form.mime_type.clone(),
                min_size: form.min_size.clone(),
                max_size: form.max_size.clone(),
                min_attachments: form.min_attachments.clone(),
                max_attachments: form.max_attachments.clone(),
                include_inline: form.include_inline.clone(),
                include_inline_images: form.include_inline_images.clone(),
                show_mime_details: form.show_mime_details.clone(),
                download_subfolder: form.download_subfolder.clone(),
                page: Some(page.to_string()),
                flash: None,
                error: None,
            };
            let data = load_attachment_page_data(config, username, &params)?;
            for item in data.items {
                if seen.insert(item.attachment.attachment_key.clone()) {
                    keys.push(item.attachment.attachment_key);
                }
                if keys.len() > MAX_ZIP_ATTACHMENTS {
                    return Err(format!(
                        "Too many attachments matched. Narrow the filters to {} files or fewer.",
                        MAX_ZIP_ATTACHMENTS
                    ));
                }
            }
            if !data.state.has_next_page {
                break;
            }
            page += 1;
        }
    } else {
        for key in &form.attachment_keys {
            let key = key.trim();
            if !key.is_empty() && seen.insert(key.to_string()) {
                keys.push(key.to_string());
            }
        }
    }

    if keys.is_empty() {
        return Err("Select at least one downloadable attachment.".to_string());
    }
    if keys.len() > MAX_ZIP_ATTACHMENTS {
        return Err(format!(
            "Select {} attachments or fewer for one ZIP download.",
            MAX_ZIP_ATTACHMENTS
        ));
    }

    Ok(keys)
}

pub(crate) fn attachment_keys_for_params(
    config: &AppConfig,
    username: &str,
    params: &AttachmentListParams,
    max_keys: usize,
) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();
    let mut page = 1;

    loop {
        let mut page_params = params.clone();
        page_params.page = Some(page.to_string());
        page_params.flash = None;
        page_params.error = None;
        let data = load_attachment_page_data(config, username, &page_params)?;
        for item in data.items {
            if seen.insert(item.attachment.attachment_key.clone())
                && item.paperless_sent_at.is_none()
                && item.dismissed_at.is_none()
            {
                keys.push(item.attachment.attachment_key);
            }
            if keys.len() >= max_keys {
                return Ok(keys);
            }
        }
        if !data.state.has_next_page {
            break;
        }
        page += 1;
    }

    Ok(keys)
}

pub(crate) fn send_attachment_filter_to_paperless(
    config: &AppConfig,
    username: &str,
    query: &str,
    max_attachments: usize,
) -> Result<PaperlessHandoffSummary, String> {
    let params = attachment_params_from_query(query)?;
    let keys = attachment_keys_for_params(config, username, &params, max_attachments)?;
    if keys.is_empty() {
        return Ok(PaperlessHandoffSummary {
            skipped: 0,
            ..Default::default()
        });
    }

    send_attachments_to_paperless(config, username, &keys)
}

pub(crate) fn parse_attachment_download_form_body(body: &[u8]) -> AttachmentDownloadForm {
    let mut form = AttachmentDownloadForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "selection_scope" => form.selection_scope = Some(value),
            "q" => form.q = Some(value),
            "account_id" => form.account_id = Some(value),
            "priority" => form.priority = Some(value),
            "sender_address" => form.sender_address = Some(value),
            "sender_name" => form.sender_name = Some(value),
            "sender_domain" => form.sender_domain = Some(value),
            "subject" => form.subject = Some(value),
            "body_text" => form.body_text = Some(value),
            "date_from" => form.date_from = Some(value),
            "date_to" => form.date_to = Some(value),
            "has_attachments" => form.has_attachments = Some(value),
            "extension" => form.extension = Some(value),
            "attachment_name" => form.attachment_name = Some(value),
            "mime_type" => form.mime_type = Some(value),
            "min_size" => form.min_size = Some(value),
            "max_size" => form.max_size = Some(value),
            "min_attachments" => form.min_attachments = Some(value),
            "max_attachments" => form.max_attachments = Some(value),
            "include_inline" => form.include_inline = Some(value),
            "include_inline_images" => form.include_inline_images = Some(value),
            "show_mime_details" => form.show_mime_details = Some(value),
            "download_subfolder" => form.download_subfolder = Some(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

pub(crate) fn parse_attachment_paperless_form_body(body: &[u8]) -> AttachmentPaperlessForm {
    let mut form = AttachmentPaperlessForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

pub(crate) fn parse_attachment_dismiss_form_body(body: &[u8]) -> AttachmentDismissForm {
    let mut form = AttachmentDismissForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}
