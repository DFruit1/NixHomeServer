use super::super::*;

pub(crate) fn parse_page_number(raw: Option<&str>) -> usize {
    raw.and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(1)
}

pub(crate) fn optional_trimmed(raw: Option<&String>) -> String {
    raw.map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
}

pub(crate) fn parse_query_bool(raw: Option<&str>) -> Result<Option<bool>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => match value.to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Ok(Some(true)),
            "0" | "false" | "no" | "off" => Ok(Some(false)),
            _ => Err(format!("invalid boolean query value '{value}'")),
        },
        None => Ok(None),
    }
}

pub(crate) fn query_bool_is_true(raw: Option<&str>) -> bool {
    matches!(parse_query_bool(raw).ok().flatten(), Some(true))
}

pub(crate) fn parse_optional_usize(
    raw: Option<&str>,
    label: &str,
) -> Result<Option<usize>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => value
            .parse::<usize>()
            .map(Some)
            .map_err(|error| format!("invalid {label} '{value}': {error}")),
        None => Ok(None),
    }
}

pub(crate) fn parse_optional_nonnegative_i64(
    raw: Option<&str>,
    label: &str,
) -> Result<Option<i64>, String> {
    match parse_optional_query_i64(raw)? {
        Some(value) if value < 0 => Err(format!("{label} cannot be negative")),
        value => Ok(value),
    }
}

pub(crate) fn parse_date_start(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(0, 0, 0)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

pub(crate) fn parse_date_end(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(23, 59, 59)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

pub(crate) fn message_filters_from_search_params(
    params: &SearchParams,
    fallback_query: String,
) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()).if_empty_then(fallback_query),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: parse_query_bool(params.has_attachments.as_deref())
            .ok()
            .flatten(),
    }
}

trait EmptyStringFallback {
    fn if_empty_then(self, fallback: String) -> String;
}

impl EmptyStringFallback for String {
    fn if_empty_then(self, fallback: String) -> String {
        if self.is_empty() {
            fallback
        } else {
            self
        }
    }
}

pub(crate) fn message_filters_from_attachment_params(
    params: &AttachmentListParams,
) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: None,
    }
}

pub(crate) fn message_filters_without_general_query(
    filters: &MessageSearchFilters,
) -> MessageSearchFilters {
    let mut structured = filters.clone();
    structured.q.clear();
    structured
}

pub(crate) fn attachment_filters_from_params(
    params: &AttachmentListParams,
) -> AttachmentSearchFilters {
    let custom_extension = optional_trimmed(params.extension_custom.as_ref()).to_ascii_lowercase();
    let extension = if custom_extension.is_empty() {
        optional_trimmed(params.extension.as_ref()).to_ascii_lowercase()
    } else {
        custom_extension
    };
    AttachmentSearchFilters {
        message: message_filters_from_attachment_params(params),
        extension,
        attachment_name: optional_trimmed(params.attachment_name.as_ref()),
        mime_type: String::new(),
        min_size: optional_trimmed(params.min_size.as_ref()),
        max_size: optional_trimmed(params.max_size.as_ref()),
        min_attachments: String::new(),
        max_attachments: String::new(),
    }
}

pub(crate) fn attachment_params_from_preset_form(
    form: &AttachmentPresetSaveForm,
) -> Result<AttachmentListParams, String> {
    Ok(AttachmentListParams {
        q: form.q.clone(),
        account_id: parse_optional_query_i64(form.account_id.as_deref())?,
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
        page: None,
        flash: None,
        error: None,
    })
}

pub(crate) fn attachment_params_from_paperless_task_form(
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<AttachmentListParams, String> {
    Ok(AttachmentListParams {
        q: form.q.clone(),
        account_id: parse_optional_query_i64(form.account_id.as_deref())?,
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
        page: None,
        flash: None,
        error: None,
    })
}

pub(crate) fn attachment_params_from_query(query: &str) -> Result<AttachmentListParams, String> {
    let mut params = AttachmentListParams::default();
    for (key, value) in form_urlencoded::parse(query.as_bytes()) {
        let value = value.into_owned();
        match key.as_ref() {
            "q" => params.q = Some(value),
            "account_id" => params.account_id = parse_optional_query_i64(Some(&value))?,
            "priority" => params.priority = Some(value),
            "sender_address" => params.sender_address = Some(value),
            "sender_name" => params.sender_name = Some(value),
            "sender_domain" => params.sender_domain = Some(value),
            "subject" => params.subject = Some(value),
            "body_text" => params.body_text = Some(value),
            "date_from" => params.date_from = Some(value),
            "date_to" => params.date_to = Some(value),
            "has_attachments" => params.has_attachments = Some(value),
            "extension" => params.extension = Some(value),
            "extension_custom" => params.extension_custom = Some(value),
            "attachment_name" => params.attachment_name = Some(value),
            "mime_type" => params.mime_type = Some(value),
            "min_size" => params.min_size = Some(value),
            "max_size" => params.max_size = Some(value),
            "min_attachments" => params.min_attachments = Some(value),
            "max_attachments" => params.max_attachments = Some(value),
            "include_inline" => params.include_inline = Some(value),
            "include_inline_images" => params.include_inline_images = Some(value),
            "show_mime_details" => params.show_mime_details = Some(value),
            "download_subfolder" => params.download_subfolder = Some(value),
            _ => {}
        }
    }
    Ok(params)
}

pub(crate) fn parse_message_search_filters(
    filters: MessageSearchFilters,
) -> Result<ParsedMessageSearchFilters, String> {
    let normalized_sender_address = if filters.sender_address.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_address(&filters.sender_address)
                .map(|identity| identity.address)
                .ok_or_else(|| "Sender address must be a valid email address.".to_string())?,
        )
    };
    let normalized_sender_domain = if filters.sender_domain.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_domain(&filters.sender_domain)
                .ok_or_else(|| "Sender domain must be a valid mail domain.".to_string())?,
        )
    };
    let date_from_timestamp = parse_date_start(&filters.date_from, "from")?;
    let date_to_timestamp = parse_date_end(&filters.date_to, "to")?;
    if let (Some(from), Some(to)) = (date_from_timestamp, date_to_timestamp) {
        if from > to {
            return Err("Date from must be before date to.".to_string());
        }
    }

    Ok(ParsedMessageSearchFilters {
        raw: filters,
        normalized_sender_address,
        normalized_sender_domain,
        date_from_timestamp,
        date_to_timestamp,
    })
}

pub(crate) fn parse_attachment_search_filters(
    filters: AttachmentSearchFilters,
) -> Result<ParsedAttachmentSearchFilters, String> {
    parse_message_search_filters(filters.message.clone())?;
    let min_size_bytes = parse_optional_nonnegative_i64(Some(&filters.min_size), "minimum size")?;
    let max_size_bytes = parse_optional_nonnegative_i64(Some(&filters.max_size), "maximum size")?;
    if let (Some(min), Some(max)) = (min_size_bytes, max_size_bytes) {
        if min > max {
            return Err("Minimum size must be less than or equal to maximum size.".to_string());
        }
    }
    let min_attachment_count =
        parse_optional_usize(Some(&filters.min_attachments), "minimum attachment count")?;
    let max_attachment_count =
        parse_optional_usize(Some(&filters.max_attachments), "maximum attachment count")?;
    if let (Some(min), Some(max)) = (min_attachment_count, max_attachment_count) {
        if min > max {
            return Err(
                "Minimum attachment count must be less than or equal to maximum attachment count."
                    .to_string(),
            );
        }
    }

    Ok(ParsedAttachmentSearchFilters {
        raw: filters,
        min_size_bytes,
        max_size_bytes,
        min_attachment_count,
        max_attachment_count,
    })
}

pub(crate) fn notmuch_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value.replace('\\', "\\\\").replace('"', "\\\"").trim()
    )
}

pub(crate) fn notmuch_query_for_filters(filters: &ParsedMessageSearchFilters) -> String {
    let mut terms = Vec::new();
    if !filters.raw.q.trim().is_empty() {
        terms.push(filters.raw.q.trim().to_string());
    }
    if let Some(address) = filters.normalized_sender_address.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(address)));
    }
    if !filters.raw.sender_name.trim().is_empty() {
        terms.push(format!("from:{}", notmuch_quote(&filters.raw.sender_name)));
    }
    if let Some(domain) = filters.normalized_sender_domain.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(domain)));
    }
    if !filters.raw.subject.trim().is_empty() {
        terms.push(format!("subject:{}", notmuch_quote(&filters.raw.subject)));
    }
    if !filters.raw.body_text.trim().is_empty() {
        terms.push(notmuch_quote(&filters.raw.body_text));
    }
    if terms.is_empty() {
        "*".to_string()
    } else {
        terms.join(" ")
    }
}

pub(crate) fn message_matches_filters(
    metadata: &LiveMessageRecord,
    filters: &ParsedMessageSearchFilters,
    has_attachments: Option<bool>,
) -> bool {
    if let Some(from_timestamp) = filters.date_from_timestamp {
        if metadata.timestamp < from_timestamp {
            return false;
        }
    }
    if let Some(to_timestamp) = filters.date_to_timestamp {
        if metadata.timestamp > to_timestamp {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_address.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.address != expected)
        {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_domain.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.domain != expected)
        {
            return false;
        }
    }
    if !filters.raw.sender_name.trim().is_empty() {
        let needle = filters.raw.sender_name.to_ascii_lowercase();
        let display = sender_display_from_header(&metadata.from);
        if !display.primary.to_ascii_lowercase().contains(&needle)
            && !metadata.from.to_ascii_lowercase().contains(&needle)
        {
            return false;
        }
    }
    if !filters.raw.subject.trim().is_empty()
        && !metadata
            .subject
            .to_ascii_lowercase()
            .contains(&filters.raw.subject.to_ascii_lowercase())
    {
        return false;
    }
    if let Some(expected) = filters.raw.has_attachments {
        if has_attachments != Some(expected) {
            return false;
        }
    }
    true
}

pub(crate) fn attachment_matches_filters(
    item: &AttachmentListItem,
    filters: &ParsedAttachmentSearchFilters,
    attachment_count: usize,
) -> bool {
    if !filters.raw.extension.is_empty() && item.attachment.extension != filters.raw.extension {
        return false;
    }
    if !filters.raw.attachment_name.is_empty()
        && !item
            .attachment
            .original_filename
            .to_ascii_lowercase()
            .contains(&filters.raw.attachment_name.to_ascii_lowercase())
    {
        return false;
    }
    if !filters.raw.mime_type.is_empty()
        && !item
            .attachment
            .mime_type
            .to_ascii_lowercase()
            .contains(&filters.raw.mime_type)
    {
        return false;
    }
    if let Some(min_size) = filters.min_size_bytes {
        if item.attachment.size_bytes < min_size {
            return false;
        }
    }
    if let Some(max_size) = filters.max_size_bytes {
        if item.attachment.size_bytes > max_size {
            return false;
        }
    }
    if let Some(min_count) = filters.min_attachment_count {
        if attachment_count < min_count {
            return false;
        }
    }
    if let Some(max_count) = filters.max_attachment_count {
        if attachment_count > max_count {
            return false;
        }
    }
    true
}

pub(crate) fn attachment_general_query_matches(
    item: &AttachmentListItem,
    query: &str,
    message_body_match: bool,
) -> bool {
    if message_body_match {
        return true;
    }
    let needle = query.trim().to_ascii_lowercase();
    if needle.is_empty() {
        return true;
    }
    let subject = decode_display_header_value(&item.message.subject);
    let sender = decode_display_header_value(&item.message.from);
    [
        item.attachment.original_filename.as_str(),
        item.attachment.safe_filename.as_str(),
        item.attachment.extension.as_str(),
        item.attachment.mime_type.as_str(),
        item.account_name.as_str(),
        subject.as_str(),
        sender.as_str(),
    ]
    .iter()
    .any(|value| value.to_ascii_lowercase().contains(&needle))
}

pub(crate) fn build_attachment_base_query(state: AttachmentBaseQuery<'_>) -> String {
    let mut pairs = Vec::new();
    append_message_filter_query_pairs(&mut pairs, &state.filters.message);
    if let Some(account_id) = state.selected_account_id {
        pairs.push(("account_id", account_id.to_string()));
    }
    if state.priority_filter != SenderPriorityFilter::All {
        pairs.push((
            "priority",
            state.priority_filter.as_query_value().to_string(),
        ));
    }
    append_attachment_filter_query_pairs(&mut pairs, state.filters);
    if state.include_inline {
        pairs.push(("include_inline", "1".to_string()));
    }
    if state.include_inline_images {
        pairs.push(("include_inline_images", "1".to_string()));
    }
    if state.show_mime_details {
        pairs.push(("show_mime_details", "1".to_string()));
    }
    if !state.download_subfolder.trim().is_empty() {
        pairs.push((
            "download_subfolder",
            state.download_subfolder.trim().to_string(),
        ));
    }
    pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={}", url_encode_component(&value)))
        .collect::<Vec<_>>()
        .join("&")
}

pub(crate) fn attachment_preset_query_from_form(
    form: &AttachmentPresetSaveForm,
) -> Result<String, String> {
    let params = attachment_params_from_preset_form(form)?;
    let filters = attachment_filters_from_params(&params);
    let parsed_filters = parse_attachment_search_filters(filters)?;
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;

    Ok(build_attachment_base_query(AttachmentBaseQuery {
        filters: &parsed_filters.raw,
        selected_account_id: params.account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    }))
}

pub(crate) fn attachment_paperless_task_query_from_form(
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<String, String> {
    let params = attachment_params_from_paperless_task_form(form)?;
    let filters = attachment_filters_from_params(&params);
    let parsed_filters = parse_attachment_search_filters(filters)?;
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;

    Ok(build_attachment_base_query(AttachmentBaseQuery {
        filters: &parsed_filters.raw,
        selected_account_id: params.account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    }))
}

pub(crate) fn append_message_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &MessageSearchFilters,
) {
    for (key, value) in [
        ("q", filters.q.trim()),
        ("sender_address", filters.sender_address.trim()),
        ("sender_name", filters.sender_name.trim()),
        ("sender_domain", filters.sender_domain.trim()),
        ("subject", filters.subject.trim()),
        ("body_text", filters.body_text.trim()),
        ("date_from", filters.date_from.trim()),
        ("date_to", filters.date_to.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
    if let Some(value) = filters.has_attachments {
        pairs.push(("has_attachments", if value { "1" } else { "0" }.to_string()));
    }
}

pub(crate) fn append_attachment_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &AttachmentSearchFilters,
) {
    for (key, value) in [
        ("extension", filters.extension.trim()),
        ("attachment_name", filters.attachment_name.trim()),
        ("min_size", filters.min_size.trim()),
        ("max_size", filters.max_size.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
}

pub(crate) fn message_filters_have_terms(filters: &MessageSearchFilters) -> bool {
    [
        filters.q.as_str(),
        filters.sender_address.as_str(),
        filters.sender_name.as_str(),
        filters.sender_domain.as_str(),
        filters.subject.as_str(),
        filters.body_text.as_str(),
        filters.date_from.as_str(),
        filters.date_to.as_str(),
    ]
    .iter()
    .any(|value| !value.trim().is_empty())
        || filters.has_attachments.is_some()
}
