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
    let connection = open_db(config)?;
    let paperless_handoffs = load_attachment_paperless_handoffs(&connection, username)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let mut items = Vec::new();
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

        let catalog_rows = load_attachment_catalog_rows_for_account(&connection, account.id)?;
        let mut attachment_counts = HashMap::<String, usize>::new();
        for (message, _) in &catalog_rows {
            *attachment_counts
                .entry(message.message_key.clone())
                .or_insert(0) += 1;
        }

        for (message, attachment) in catalog_rows {
            if message_filters_have_terms(&structured_message_filters.raw)
                && !query_relpaths_by_account
                    .get(&account.id)
                    .is_some_and(|relpaths| relpaths.contains(&message.message_relpath))
            {
                continue;
            }
            if !include_inline && attachment_is_body_artifact(&attachment) {
                continue;
            }
            if !include_inline_images && attachment_is_inline_image(&attachment) {
                continue;
            }

            let sender_priority = priority_rules.view_for_sender(&message.from);
            if !priority_filter.matches(sender_priority.priority) {
                continue;
            }

            let mut item = AttachmentListItem {
                account_name: account.display_name.clone(),
                attachment,
                message,
                sender_priority,
                paperless_sent_at: None,
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
                continue;
            }
            if !general_query.is_empty() {
                let message_body_match = general_query_relpaths_by_account
                    .get(&account.id)
                    .is_some_and(|relpaths| relpaths.contains(&item.message.message_relpath));
                if !attachment_general_query_matches(&item, &general_query, message_body_match) {
                    continue;
                }
            }
            let attachment_count = attachment_counts
                .get(&item.message.message_key)
                .copied()
                .unwrap_or(0);
            if !attachment_matches_filters(&item, &filters, attachment_count) {
                continue;
            }
            item.paperless_sent_at = paperless_handoffs
                .get(&item.attachment.attachment_key)
                .cloned();
            items.push(item);
        }
    }

    items.sort_by(|left, right| {
        left.sender_priority
            .priority
            .sort_rank()
            .cmp(&right.sender_priority.priority.sort_rank())
            .then(right.message.timestamp.cmp(&left.message.timestamp))
            .then(
                left.attachment
                    .attachment_index
                    .cmp(&right.attachment.attachment_index),
            )
    });

    let total_count = items.len();
    let start = (page - 1).saturating_mul(ATTACHMENTS_PER_PAGE);
    let end = usize::min(start + ATTACHMENTS_PER_PAGE, total_count);
    let mut page_items = if start >= total_count {
        Vec::new()
    } else {
        items[start..end].to_vec()
    };
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
    let empty_message =
        if selected_account_id.is_some() && page_items.is_empty() && total_count == 0 {
            Some("No attachments matched this mailbox filter.".to_string())
        } else if page_items.is_empty() && total_count == 0 {
            Some("No catalogued attachments matched the current filters.".to_string())
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
