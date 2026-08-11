use super::*;

pub(super) fn render_dashboard(
    identity: &Identity,
    accounts: &[DashboardAccountView],
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&render_toasts(flash, error));

    body.push_str(
        "<section class=\"hero dashboard-hero\">
          <div class=\"hero-headline\">
            <h1>Mail Archive</h1>
            <p class=\"lede\">Search saved messages and find documents in attachments.</p>
          </div>
          <div class=\"nav hero-actions\">
            <a href=\"/search\">Search mail</a>
            <a class=\"secondary\" href=\"/attachments\">Search attachments</a>
          </div>
        </section>",
    );

    body.push_str(
        "<section class=\"page-heading\" aria-label=\"Mailbox status\">
           <h2>Mailboxes</h2>
           <a class=\"button-link secondary\" href=\"/accounts/new\">Add mailbox</a>
         </section>",
    );
    body.push_str(
        "<div id=\"dashboard-status-island\" data-mail-archive-island=\"dashboard-status\"></div>",
    );
    if accounts.is_empty() {
        body.push_str(
            "<div class=\"empty-state\"><p class=\"meta\">No mailbox is configured yet. Start with Gmail or a generic IMAP account.</p><a class=\"button-link\" href=\"/accounts/new\">Add mailbox</a></div>",
        );
    } else {
        body.push_str("<div class=\"mailbox-list\" data-dashboard-status-root>");
        for view in accounts {
            body.push_str(&render_account_card(view));
        }
        body.push_str("</div>");
        body.push_str(
            "<div class=\"action-row\"><a class=\"button-link secondary\" href=\"/accounts/new\">Add another mailbox</a></div>",
        );
    }

    layout("Mail Archive", Some(identity), "dashboard", &body)
}

pub(super) fn render_toasts(flash: Option<&str>, error: Option<&str>) -> String {
    let mut toasts = Vec::new();
    if let Some(flash) = flash.filter(|value| !value.is_empty()) {
        toasts.push(format!(
            "<div class=\"toast success\" role=\"status\">{}</div>",
            escape_html(&flash.replace('+', " "))
        ));
    }
    if let Some(error) = error.filter(|value| !value.is_empty()) {
        toasts.push(format!(
            "<div class=\"toast error\" role=\"alert\">{}</div>",
            escape_html(&error.replace('+', " "))
        ));
    }
    if toasts.is_empty() {
        String::new()
    } else {
        format!(
            "<div class=\"toast-stack\" aria-live=\"polite\" aria-atomic=\"true\">{}</div>",
            toasts.join("")
        )
    }
}

pub(super) fn hidden_class(visible: bool) -> &'static str {
    if visible {
        ""
    } else {
        " hidden"
    }
}

pub(super) fn render_sync_diagnostic_notice(status: &AccountStatusPayload) -> String {
    let meta = match (
        status.diagnostic_phase.as_deref(),
        status.diagnostic_code.as_deref(),
    ) {
        (Some(phase), Some(code)) => Some(format!("Phase {phase} · Code {code}")),
        (Some(phase), None) => Some(format!("Phase {phase}")),
        (None, Some(code)) => Some(format!("Code {code}")),
        (None, None) => None,
    };

    format!(
        "<div class=\"notice sync{}\" data-sync-diagnostic>
          <p class=\"notice-title{}\" data-diagnostic-summary>{}</p>
          <p class=\"notice-copy{}\" data-diagnostic-impact>{}</p>
          <p class=\"notice-copy{}\" data-diagnostic-action>{}</p>
          <details class=\"notice-details{}\" data-diagnostic-details>
            <summary>Troubleshooting details</summary>
            <p class=\"meta notice-meta{}\" data-diagnostic-meta>{}</p>
            <pre data-diagnostic-detail>{}</pre>
          </details>
        </div>",
        hidden_class(status.diagnostic_summary.is_some()),
        hidden_class(status.diagnostic_summary.is_some()),
        escape_html(status.diagnostic_summary.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_impact.is_some()),
        escape_html(status.diagnostic_impact.as_deref().unwrap_or("")),
        hidden_class(status.recommended_action.is_some()),
        escape_html(status.recommended_action.as_deref().unwrap_or("")),
        hidden_class(status.diagnostic_detail.is_some()),
        hidden_class(meta.is_some()),
        escape_html(meta.as_deref().unwrap_or("")),
        escape_html(status.diagnostic_detail.as_deref().unwrap_or("")),
    )
}

pub(super) fn render_progress_warning_notice(status: &AccountStatusPayload) -> String {
    format!(
        "<div class=\"notice warning{}\" data-progress-warning>
          <p class=\"notice-title{}\" data-progress-warning-text>{}</p>
          <p class=\"notice-copy{}\" data-progress-warning-action>{}</p>
          <details class=\"notice-details{}\" data-progress-warning-details>
            <summary>Troubleshooting details</summary>
            <pre data-progress-warning-detail>{}</pre>
          </details>
        </div>",
        hidden_class(status.progress_warning.is_some()),
        hidden_class(status.progress_warning.is_some()),
        escape_html(status.progress_warning.as_deref().unwrap_or("")),
        hidden_class(status.progress_warning_action.is_some()),
        escape_html(status.progress_warning_action.as_deref().unwrap_or("")),
        hidden_class(status.progress_warning_detail.is_some()),
        escape_html(status.progress_warning_detail.as_deref().unwrap_or("")),
    )
}

pub(super) fn render_health_light(key: &str, label: &str, class_name: &str, title: &str) -> String {
    let aria_label = format!("{label}: {title}");
    format!(
        "<span class=\"health-light {}\" data-health-light=\"{}\" aria-label=\"{}\" title=\"{}\"></span>",
        escape_html(class_name),
        escape_html(key),
        escape_html(&aria_label),
        escape_html(title),
    )
}

pub(super) fn health_light_state(
    key: &str,
    account: &AccountRecord,
    status: &AccountStatusPayload,
) -> (&'static str, &'static str) {
    match key {
        "mailbox" => {
            if status.status_class == "error" {
                ("error", "Mailbox connection failed")
            } else if status.status_label == "syncing" {
                ("active pulse-fast", "Mailbox connection syncing")
            } else if status.status_class == "idle" {
                ("idle", "Mailbox connection idle")
            } else {
                ("ok", "Mailbox connection healthy")
            }
        }
        "index" => {
            if status
                .diagnostic_phase
                .as_deref()
                .is_some_and(|phase| matches!(phase, "index" | "reconcile"))
            {
                ("warning pulse-slow", "Search index needs attention")
            } else if status.pending_index_count > 0 {
                ("warning pulse-slow", "Search index is catching up")
            } else if status.index_label != "Indexed" {
                ("idle", "Search index has not been built")
            } else {
                ("ok", "Search index healthy")
            }
        }
        "storage" => {
            if status.progress_warning.is_some()
                || status.diagnostic_phase.as_deref() == Some("metrics")
            {
                ("warning pulse-slow", "Archive storage needs attention")
            } else {
                ("ok", "Archive storage healthy")
            }
        }
        "paperless" => {
            if status
                .progress_warning_detail
                .as_deref()
                .is_some_and(|detail| detail.to_ascii_lowercase().contains("paperless"))
            {
                ("warning pulse-slow", "Paperless handoff needs attention")
            } else {
                ("ok", "Paperless handoff ready")
            }
        }
        "sync" if account.last_sync_status.as_deref() == Some("running") => {
            ("active pulse-fast", "Sync is running")
        }
        "sync" if account.sync_enabled => ("ok", "Automatic sync is scheduled"),
        "sync" => ("idle", "Automatic sync is off"),
        _ => ("idle", "Status unavailable"),
    }
}

pub(super) fn render_health_lights(
    account: &AccountRecord,
    status: &AccountStatusPayload,
) -> String {
    let items = [
        ("mailbox", "Mailbox"),
        ("index", "Index"),
        ("storage", "Storage"),
        ("paperless", "Paperless"),
        ("sync", "Sync"),
    ];
    let mut body = String::new();
    body.push_str("<div class=\"health-lights\" aria-label=\"Mailbox health indicators\">");
    for (key, label) in items {
        let (class_name, title) = health_light_state(key, account, status);
        body.push_str(&render_health_light(key, label, class_name, title));
    }
    body.push_str("</div>");
    body
}

pub(super) fn render_account_card(view: &DashboardAccountView) -> String {
    let account = &view.account;
    let status = &view.status;
    let schedule_label = if account.sync_enabled {
        "Scheduled"
    } else {
        "Manual only"
    };
    let status_class = sanitized_status_class(&status.status_class);
    let status_label = if status.status_label.is_empty() {
        "—"
    } else {
        status.status_label.as_str()
    };
    let mut body = String::new();

    writeln!(
        &mut body,
        "<article class=\"account-card item-card item-card-{}\" data-account-card data-account-id=\"{}\">
          <div class=\"account-card-primary\">
            <span class=\"provider-icon {}\" aria-hidden=\"true\">{}</span>
            <div class=\"account-card-titles\">
              <h2 data-account-name>{}</h2>
              <span class=\"meta account-card-meta\">
                <strong data-progress-field=\"archived\">{}</strong>
                <span class=\"meta-sep\">·</span>
                <span><strong data-progress-field=\"pending\">{}</strong> indexing</span>
                <span class=\"meta-sep\">·</span>
                <span data-index-pill>{}</span>
              </span>
            </div>
            <span class=\"status {}\" data-status-badge title=\"Last activity: {}\">{}</span>
            <span class=\"account-card-actions\">
              <form method=\"post\" action=\"/accounts/{}/sync\" data-dashboard-action><button class=\"secondary\" type=\"submit\">Sync Now</button></form>
            </span>
          </div>
          <details class=\"account-settings\">
            <summary>Sync &amp; maintenance</summary>
            <div class=\"account-settings-body\">
              {}
              <p class=\"meta account-card-context\" data-last-activity>Last activity: {}</p>
              <p class=\"hint\">Provider: {} · Automatic updates: {}</p>
              <div class=\"action-row maintenance-actions\">
                <a class=\"button-link secondary\" href=\"/accounts/{}/edit\">Connection settings</a>
                <form method=\"post\" action=\"/accounts/{}/reindex\" data-dashboard-action><button class=\"secondary\" type=\"submit\">Repair search</button></form>
                <form method=\"post\" action=\"/accounts/{}/toggle-sync\" data-dashboard-action><button class=\"secondary\" type=\"submit\">{}</button></form>
              </div>
            </div>
          </details>
          {}
          {}",
        escape_html(status_class),
        account.id,
        escape_html(provider_icon_class(&account.provider_kind)),
        escape_html(provider_icon_label(&account.provider_kind)),
        escape_html(&account.display_name),
        status.archived_message_count,
        status.pending_index_count,
        escape_html(&status.index_label),
        escape_html(status_class),
        escape_html(&status.last_activity),
        escape_html(status_label),
        account.id,
        render_health_lights(account, status),
        escape_html(&status.last_activity),
        escape_html(provider_label(&account.provider_kind)),
        escape_html(schedule_label),
        account.id,
        account.id,
        account.id,
        if account.sync_enabled {
            "Turn off automatic updates"
        } else {
            "Turn on automatic updates"
        },
        render_sync_diagnostic_notice(status),
        render_progress_warning_notice(status),
    )
    .ok();

    body.push_str("</article>");
    body
}

pub(super) fn sanitized_status_class(raw: &str) -> &str {
    match raw {
        "ok" | "pending" | "error" | "idle" | "unindexed" => raw,
        _ => "idle",
    }
}

pub(super) fn account_status(
    account: &AccountRecord,
    index_state: IndexState,
    counts: &AccountProgressCounts,
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
) -> (&'static str, &'static str) {
    match account.last_sync_status.as_deref() {
        Some("running") => ("pending", "syncing"),
        Some("error")
            if sync_diagnostic
                .as_ref()
                .and_then(|value| value.phase)
                .is_some_and(|phase| matches!(phase, SyncPhase::Index | SyncPhase::Reconcile))
                && counts.pending_index_count > 0 =>
        {
            ("pending", "index behind")
        }
        Some("error") => ("error", "sync failed"),
        _ if metrics_diagnostic.is_some() => ("pending", "check archive"),
        Some("ok") if counts.pending_index_count > 0 => ("pending", "index behind"),
        Some("ok") if index_state == IndexState::Indexed => ("ok", "healthy"),
        _ if index_state != IndexState::Indexed => ("unindexed", "needs index"),
        _ if counts.pending_index_count > 0 => ("pending", "index behind"),
        _ => ("idle", "healthy"),
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn render_account_form(
    identity: &Identity,
    page_title: &str,
    heading: &str,
    lede: &str,
    action_url: &str,
    submit_label: &str,
    secret_required: bool,
    form: &CreateAccountForm,
    secret_help: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&format!(
        "<section class=\"page-heading\">
          <div>
            <p class=\"eyebrow\">Mailbox Setup</p>
            <h1>{}</h1>
            <p class=\"meta\">{}</p>
          </div>
        </section>",
        escape_html(heading),
        escape_html(lede),
    ));

    body.push_str("<section class=\"panel stack\">");
    if let Some(error) = error {
        writeln!(
            &mut body,
            "<div class=\"error\">{}</div>",
            escape_html(error)
        )
        .ok();
    }

    writeln!(
        &mut body,
        "<form method=\"post\" action=\"{}\" class=\"fields\">
          <div class=\"fields two\">
            <label>Mailbox type
              <select name=\"provider_kind\">
                <option value=\"gmail\" {}>Gmail</option>
                <option value=\"generic_imap\" {}>Other mailbox</option>
              </select>
            </label>
            <label>Name shown in the archive
              <input name=\"display_name\" value=\"{}\" placeholder=\"Personal Gmail\">
            </label>
          </div>
          <div class=\"fields two\">
            <label>Email address
              <input name=\"imap_username\" value=\"{}\" placeholder=\"you@example.com\">
            </label>
            <label>App password
              <input type=\"password\" name=\"secret\" value=\"\" autocomplete=\"new-password\" {}>
            </label>
          </div>
          <p class=\"form-hint\">{}</p>
          <details class=\"account-settings\">
            <summary>Advanced connection settings · folders · automatic sync</summary>
            <div class=\"fields two\">
              <label>Server
                <input name=\"imap_host\" value=\"{}\" placeholder=\"imap.gmail.com\">
              </label>
              <label>Port
                <input name=\"imap_port\" value=\"{}\" placeholder=\"993\">
              </label>
            </div>
            <label>Folders to save
              <textarea name=\"folder_patterns\" placeholder=\"One folder pattern per line\">{}</textarea>
            </label>
            <label class=\"checkbox-field\"><input type=\"checkbox\" name=\"sync_enabled\" {}> Update this mailbox automatically</label>
          </details>
          <div class=\"submit-actions\">
            <button type=\"submit\">{}</button>
          </div>
        </form>",
        escape_html(action_url),
        if form.provider_kind == "gmail" {
            "selected"
        } else {
            ""
        },
        if form.provider_kind == "generic_imap" {
            "selected"
        } else {
            ""
        },
        escape_html(&form.display_name),
        escape_html(&form.imap_username),
        if secret_required { "required" } else { "" },
        escape_html(
            secret_help.unwrap_or("Gmail usually needs an app password. Saved mail can be searched and attachments can be sent to Paperless.")
        ),
        escape_html(&form.imap_host),
        escape_html(&form.imap_port),
        escape_html(&form.folder_patterns),
        if form.sync_enabled.is_some() { "checked" } else { "" },
        escape_html(submit_label),
    )
    .ok();
    body.push_str("</section>");

    layout(page_title, Some(identity), "accounts", &body)
}

pub(super) fn render_attachments_page(
    identity: &Identity,
    data: &AttachmentPageData,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&render_toasts(flash, error));

    let return_to = attachment_return_to(&data.state);
    let filter_hiddens = render_attachment_filter_hiddens(data, &return_to);
    let preset_dialog = render_attachment_preset_dialog(data, &return_to);
    let advanced_dialog = render_attachment_advanced_dialog(data);
    let show_download_all = data.state.result_count > data.items.len();
    writeln!(
        &mut body,
        "<section class=\"page-heading\">
           <div>
             <p class=\"eyebrow\">Attachments</p>
             <h1>Search saved attachments</h1>
           </div>
         </section>",
    )
    .ok();
    writeln!(
        &mut body,
        "<section class=\"panel search-panel\">
           <form id=\"attachment-search-form\" method=\"get\" action=\"/attachments\" class=\"search-form\">
             <div class=\"primary-search-row\">
               <label class=\"primary-search-field\">Search attachments
                 <input class=\"primary-search-input\" name=\"q\" value=\"{}\">
               </label>
               <button class=\"search-submit\" type=\"submit\">Search</button>
             </div>
             <details class=\"filter-accordion\">
               <summary>Filters</summary>
               <div class=\"filter-grid\">
                 <section class=\"basic-filter-column\" aria-label=\"Basic attachment filters\">
                   {}
                   {}
                   {}
                   {}
                 </section>
                 <div class=\"filter-link-row\">
                   <button class=\"advanced-filter-link\" type=\"button\" data-open-dialog=\"attachment-advanced-dialog\">Advanced filters</button>
                   <button class=\"advanced-filter-link\" type=\"button\" data-open-dialog=\"attachment-presets-dialog\">Filter presets</button>
                   <a class=\"advanced-filter-link\" href=\"/attachments?q=\">Reset filters</a>
                 </div>
               </div>
             </details>
             {}
           </form>
         </section>
         {}
         <section class=\"attachment-toolbar\" aria-label=\"Bulk attachment actions\">
           <div class=\"toolbar-selection\">
             <div id=\"attachment-selection-island\" data-mail-archive-island=\"attachment-selection\"></div>
             <span class=\"selection-count\" data-selected-count data-total-results=\"{}\">0/{} results selected</span>
           </div>
           <div class=\"toolbar-actions\">
             <form id=\"attachment-download-form\" method=\"post\" action=\"/attachments/download\" class=\"icon-form\">
               {}
               <button class=\"bulk-action\" type=\"submit\" title=\"Download selected attachments\" aria-label=\"Download selected attachments\" data-bulk-action>Download</button>
               {}
             </form>
             <form id=\"attachment-paperless-form\" method=\"post\" action=\"/attachments/send-paperless\" class=\"icon-form\" data-paperless-form>
               <input type=\"hidden\" name=\"return_to\" value=\"{}\">
               <button class=\"secondary bulk-action paperless-send-button\" type=\"submit\" title=\"Send selected attachments to Paperless\" aria-label=\"Send selected attachments to Paperless\" data-paperless-button data-bulk-action>Send to Paperless</button>
             </form>
           </div>
         </section>",
        escape_html(&data.filters.message.q),
        render_attachment_mailbox_control(data),
        render_filter_row(
            "Extension",
            &format!(
                "<select name=\"extension\">{}</select>",
                render_common_attachment_extension_options(&data.filters.extension)
            )
        ),
        render_filter_row(
            "Sender address",
            &format!(
                "<input name=\"sender_address\" value=\"{}\">",
                escape_html(&data.filters.message.sender_address)
            )
        ),
        render_filter_row(
            "Date range",
            &format!(
                "<div class=\"date-range-fields\"><input type=\"date\" name=\"date_from\" value=\"{}\" aria-label=\"Date from\"><input type=\"date\" name=\"date_to\" value=\"{}\" aria-label=\"Date to\"></div>",
                escape_html(&data.filters.message.date_from),
                escape_html(&data.filters.message.date_to)
            )
        ),
        filter_hiddens,
        advanced_dialog,
        preset_dialog,
        data.state.result_count,
        data.state.result_count,
        if show_download_all {
            "<button class=\"secondary bulk-action\" type=\"submit\" name=\"selection_scope\" value=\"all_matching\" title=\"Download all matching attachments\" aria-label=\"Download all matching attachments\">Download all</button>"
        } else {
            ""
        },
        escape_html(&return_to),
    )
    .ok();

    if let Some(message) = data.state.empty_message.as_deref() {
        writeln!(
            &mut body,
            "<section class=\"empty-state\"><p class=\"meta\">{}</p></section>",
            escape_html(message)
        )
        .ok();
    }

    if !data.items.is_empty() {
        writeln!(
            &mut body,
            "<section class=\"attachment-list\">
              {}
              {}
            </section>",
            render_attachment_list_header(),
            data.items
                .iter()
                .map(|item| render_attachment_item(item, &return_to, data.show_mime_details))
                .collect::<Vec<_>>()
                .join("")
        )
        .ok();
    }

    if data.state.has_previous_page || data.state.has_next_page {
        body.push_str(&render_attachment_pagination(&data.state));
    }

    layout("Attachments", Some(identity), "attachments", &body)
}

pub(super) fn render_attachment_mailbox_control(data: &AttachmentPageData) -> String {
    format!(
        "<section class=\"attachment-control-column\" aria-label=\"Attachment search controls\">
           <div class=\"control-group\">
             <span class=\"control-kicker\">Mailbox</span>
             <select class=\"control-field\" name=\"account_id\" aria-label=\"Mailbox\"><option value=\"\">All mailboxes</option>{}</select>
           </div>
         </section>",
        render_account_options(&data.accounts, data.selected_account_id),
    )
}

pub(super) fn render_attachment_advanced_dialog(data: &AttachmentPageData) -> String {
    format!(
        "<dialog id=\"attachment-advanced-dialog\" class=\"app-dialog filter-dialog\">
          <div class=\"dialog-shell\">
            <div class=\"dialog-heading\">
              <h2>Advanced filters</h2>
              <button class=\"icon-button\" type=\"button\" data-close-dialog title=\"Close advanced filters\" aria-label=\"Close advanced filters\">×</button>
            </div>
          <div class=\"dialog-body stacked-filter-dialog\">
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
              {}
            </div>
            <div class=\"dialog-actions\">
              <button class=\"secondary\" type=\"button\" data-close-dialog>Done</button>
            </div>
          </div>
        </dialog>",
        render_filter_row(
            "Sender importance",
            &format!(
                "<select name=\"priority\">{}</select>",
                render_sender_priority_filter_options(data.state.priority_filter)
            )
        ),
        render_filter_row(
            "Sender name",
            &format!(
                "<input name=\"sender_name\" value=\"{}\">",
                escape_html(&data.filters.message.sender_name)
            )
        ),
        render_filter_row(
            "Sender domain",
            &format!(
                "<input name=\"sender_domain\" value=\"{}\">",
                escape_html(&data.filters.message.sender_domain)
            )
        ),
        render_filter_row(
            "Subject",
            &format!(
                "<input name=\"subject\" value=\"{}\">",
                escape_html(&data.filters.message.subject)
            )
        ),
        render_filter_row(
            "Body text",
            &format!(
                "<input name=\"body_text\" value=\"{}\">",
                escape_html(&data.filters.message.body_text)
            )
        ),
        render_filter_row(
            "Attachment name",
            &format!(
                "<input name=\"attachment_name\" value=\"{}\">",
                escape_html(&data.filters.attachment_name)
            )
        ),
        render_filter_row(
            "Custom extension",
            &format!(
                "<input name=\"extension_custom\" value=\"{}\" placeholder=\"xlsx\">",
                escape_html(custom_attachment_extension_value(&data.filters.extension))
            )
        ),
        render_filter_row(
            "Min size",
            &format!(
                "<input name=\"min_size\" value=\"{}\" inputmode=\"numeric\">",
                escape_html(&data.filters.min_size)
            )
        ),
        render_filter_row(
            "Max size",
            &format!(
                "<input name=\"max_size\" value=\"{}\" inputmode=\"numeric\">",
                escape_html(&data.filters.max_size)
            )
        ),
        render_filter_row(
            "Include body files",
            &format!(
                "<input type=\"checkbox\" name=\"include_inline\" value=\"1\" {}>",
                if data.include_inline { "checked" } else { "" }
            )
        ),
        render_filter_row(
            "Inline images",
            &format!(
                "<input type=\"checkbox\" name=\"include_inline_images\" value=\"1\" {}>",
                if data.include_inline_images { "checked" } else { "" }
            )
        ),
        render_filter_row(
            "Technical file type",
            &format!(
                "<input type=\"checkbox\" name=\"show_mime_details\" value=\"1\" {}>",
                if data.show_mime_details { "checked" } else { "" }
            )
        ),
        render_filter_row(
            "ZIP subfolder",
            &format!(
                "<input name=\"download_subfolder\" value=\"{}\">",
                escape_html(&data.download_subfolder)
            )
        ),
    )
}

pub(super) fn render_filter_row(label: &str, control: &str) -> String {
    format!(
        "<label class=\"filter-row\"><span>{}</span><span class=\"filter-control\">{}</span></label>",
        escape_html(label),
        control
    )
}

pub(super) fn render_attachment_preset_dialog(
    data: &AttachmentPageData,
    return_to: &str,
) -> String {
    let mut html = String::new();
    let auto_export_names = data
        .paperless_tasks
        .iter()
        .map(|task| task.name.as_str())
        .collect::<Vec<_>>()
        .join("\t");
    writeln!(
        &mut html,
        "<dialog id=\"attachment-presets-dialog\" class=\"app-dialog preset-dialog\">
          <div class=\"dialog-shell\">
            <div class=\"dialog-heading\">
              <h2>Filter Presets</h2>
              <button class=\"icon-button\" type=\"button\" data-close-dialog title=\"Close filter presets\" aria-label=\"Close filter presets\">×</button>
            </div>
            <div class=\"dialog-body\">
              <form method=\"post\" action=\"/attachments/presets\" class=\"preset-save-form\" data-copy-filters-from=\"attachment-search-form\" data-auto-export-preset-names=\"{}\">
                <label>Preset name
                  <input name=\"preset_name\" maxlength=\"80\">
                </label>
                <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                <span data-copied-filter-fields></span>
                <button class=\"secondary\" type=\"submit\">Save current settings</button>
              </form>",
        escape_html(&auto_export_names),
        escape_html(return_to),
    )
    .ok();

    if data.presets.is_empty() {
        html.push_str("<p class=\"meta preset-empty\">No saved attachment presets</p>");
    } else {
        html.push_str("<div class=\"preset-list\">");
        for preset in &data.presets {
            let href = if preset.query.trim().is_empty() {
                "/attachments".to_string()
            } else {
                format!("/attachments?{}", preset.query)
            };
            let current_class = if preset.query == data.state.base_query {
                " preset-card-current"
            } else {
                ""
            };
            let current_badge = if preset.query == data.state.base_query {
                "<span class=\"badge\">Current</span>"
            } else {
                ""
            };
            writeln!(
                &mut html,
                "<article class=\"preset-card{}\">
                  <div class=\"preset-card-main\">
                    <a class=\"button-link secondary\" href=\"{}\">{}</a>
                    {}
                    <form method=\"post\" action=\"/attachments/presets/delete\" class=\"icon-form\">
                      <input type=\"hidden\" name=\"preset_id\" value=\"{}\">
                      <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                      <button class=\"secondary icon-button\" type=\"submit\" title=\"Delete preset\" aria-label=\"Delete preset\">×</button>
                    </form>
                  </div>
                  {}
                </article>",
                current_class,
                escape_html(&href),
                escape_html(&preset.name),
                current_badge,
                preset.id,
                escape_html(return_to),
                render_preset_auto_export(data, preset, return_to),
            )
            .ok();
        }
        html.push_str("</div>");
    }
    html.push_str(&render_unlinked_paperless_tasks(data, return_to));
    html.push_str(
        "</div>
            <div class=\"dialog-actions\">
              <button class=\"secondary\" type=\"button\" data-close-dialog>Close</button>
            </div>
          </div>
        </dialog>",
    );
    html
}

pub(super) fn render_preset_auto_export(
    data: &AttachmentPageData,
    preset: &AttachmentFilterPreset,
    return_to: &str,
) -> String {
    let mut html = String::new();
    let task = data
        .paperless_tasks
        .iter()
        .find(|task| task.name == preset.name);
    let schedule_time = task
        .map(|task| task.schedule_time.as_str())
        .unwrap_or("06:30");
    let schedule_mode = task
        .map(|task| task.schedule_mode.as_str())
        .unwrap_or("daily");
    let interval_minutes = task.map(|task| task.interval_minutes).unwrap_or(60);
    let max_attachments = task
        .map(|task| task.max_attachments)
        .unwrap_or(DEFAULT_PAPERLESS_TASK_MAX_ATTACHMENTS);
    let retry_enabled = task.is_none_or(|task| task.retry_enabled);
    writeln!(
        &mut html,
        "<details class=\"preset-auto-export\">
          <summary>Auto-export to Paperless</summary>
          <form method=\"post\" action=\"/attachments/paperless-tasks\" class=\"auto-export-form\">
            <input type=\"hidden\" name=\"task_name\" value=\"{}\">
            <input type=\"hidden\" name=\"return_to\" value=\"{}\">
            {}
            {}
            <label class=\"filter-row\"><span>Cadence</span><span class=\"filter-control\"><select name=\"schedule_mode\"><option value=\"daily\" {}>Daily</option><option value=\"interval\" {}>Repeating interval</option></select></span></label>
            <label class=\"filter-row\"><span>Daily time</span><span class=\"filter-control\"><input type=\"time\" name=\"schedule_time\" value=\"{}\" required></span></label>
            <label class=\"filter-row\"><span>Repeat every (minutes)</span><span class=\"filter-control\"><input type=\"number\" name=\"interval_minutes\" min=\"{}\" max=\"{}\" value=\"{}\" required></span></label>
            <label class=\"filter-row\"><span>Maximum per run</span><span class=\"filter-control\"><input type=\"number\" name=\"paperless_max_documents\" min=\"1\" max=\"{}\" value=\"{}\" required></span></label>
            <label class=\"filter-row\"><span>Retry failures</span><span class=\"filter-control\"><select name=\"retry_enabled\"><option value=\"1\" {}>Enabled</option><option value=\"0\" {}>Disabled</option></select></span></label>
            <button class=\"secondary\" type=\"submit\">{}</button>
          </form>",
        escape_html(&preset.name),
        escape_html(return_to),
        render_query_hidden_inputs(&preset.query),
        if let Some(task) = task {
            format!(
                "<p class=\"meta\">{} · {}</p>",
                if task.enabled { "Enabled" } else { "Paused" },
                escape_html(&paperless_task_run_label(task))
            )
        } else {
            "<p class=\"meta\">No auto-export configured for this preset.</p>".to_string()
        },
        if schedule_mode == "daily" { "selected" } else { "" },
        if schedule_mode == "interval" { "selected" } else { "" },
        escape_html(schedule_time),
        MIN_PAPERLESS_TASK_INTERVAL_MINUTES,
        MAX_PAPERLESS_TASK_INTERVAL_MINUTES,
        interval_minutes,
        MAX_PAPERLESS_TASK_ATTACHMENTS,
        max_attachments,
        if retry_enabled { "selected" } else { "" },
        if retry_enabled { "" } else { "selected" },
        if task.is_some() {
            "Update auto-export"
        } else {
            "Enable auto-export"
        },
    )
    .ok();
    if let Some(task) = task {
        writeln!(
            &mut html,
            "<div class=\"auto-export-actions\">
              <form method=\"post\" action=\"/attachments/paperless-tasks/toggle\" class=\"icon-form\">
                <input type=\"hidden\" name=\"task_id\" value=\"{}\">
                <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                {}
                <button class=\"secondary\" type=\"submit\">{}</button>
              </form>
              <form method=\"post\" action=\"/attachments/paperless-tasks/delete\" class=\"icon-form\">
                <input type=\"hidden\" name=\"task_id\" value=\"{}\">
                <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                <button class=\"secondary\" type=\"submit\">Remove auto-export</button>
              </form>
            </div>",
            task.id,
            escape_html(return_to),
            if task.enabled {
                ""
            } else {
                "<input type=\"hidden\" name=\"enabled\" value=\"1\">"
            },
            if task.enabled { "Pause" } else { "Enable" },
            task.id,
            escape_html(return_to),
        )
        .ok();
        let last_run_label = paperless_task_run_label(task);
        let mut summary_parts: Vec<String> = Vec::new();
        summary_parts.push(format!(
            "{} · {}",
            if task.enabled { "Enabled" } else { "Paused" },
            escape_html(&last_run_label)
        ));
        summary_parts.push(format!(
            "Status: {}",
            escape_html(task.last_status.as_deref().unwrap_or("not run"))
        ));
        summary_parts.push(format!("{} successful", task.successful_runs));
        summary_parts.push(format!("{} failed", task.failed_runs));
        if let Some(summary) = task.last_summary.as_deref() {
            summary_parts.push(escape_html(summary));
        }
        if let Some(retry) = task.next_retry_at.as_deref() {
            summary_parts.push(format!("retry at {}", escape_html(retry)));
        }
        writeln!(
            &mut html,
            "<p class=\"meta task-summary\">{}</p>",
            summary_parts.join(" · ")
        )
        .ok();
    }
    html.push_str("</details>");
    html
}

pub(super) fn render_unlinked_paperless_tasks(
    data: &AttachmentPageData,
    return_to: &str,
) -> String {
    let preset_names = data
        .presets
        .iter()
        .map(|preset| preset.name.as_str())
        .collect::<HashSet<_>>();
    let unlinked = data
        .paperless_tasks
        .iter()
        .filter(|task| !preset_names.contains(task.name.as_str()))
        .collect::<Vec<_>>();
    if unlinked.is_empty() {
        return String::new();
    }
    let unlinked_count = unlinked.len();
    let mut html = format!(
        "<section class=\"notice info unlinked-auto-exports\">
           <p class=\"notice-title\">{unlinked_count} unlinked auto-export{plural}</p>
           <div class=\"unlinked-auto-export-list\">",
        plural = if unlinked_count == 1 { "" } else { "s" }
    );
    for task in unlinked {
        writeln!(
            &mut html,
            "<div class=\"unlinked-auto-export-row\">
              <span class=\"unlinked-name\">{}</span>
              <span class=\"meta\">{} · {}</span>
              <form method=\"post\" action=\"/attachments/paperless-tasks/delete\" class=\"icon-form\">
                <input type=\"hidden\" name=\"task_id\" value=\"{}\">
                <input type=\"hidden\" name=\"return_to\" value=\"{}\">
                <button class=\"secondary\" type=\"submit\">Remove</button>
              </form>
            </div>",
            escape_html(&task.name),
            if task.enabled { "Enabled" } else { "Paused" },
            escape_html(&paperless_task_run_label(task)),
            task.id,
            escape_html(return_to),
        )
        .ok();
    }
    html.push_str("</div></section>");
    html
}

pub(super) fn paperless_task_run_label(task: &AttachmentPaperlessTask) -> String {
    task.last_run_at
        .as_deref()
        .map(|last_run_at| format!("Last run: {last_run_at}"))
        .or_else(|| {
            task.last_run_date
                .as_deref()
                .map(|last_run_date| format!("Last run: {last_run_date}"))
        })
        .unwrap_or_else(|| "Not run yet".to_string())
}

pub(super) fn render_query_hidden_inputs(query: &str) -> String {
    let mut html = String::new();
    for (key, value) in form_urlencoded::parse(query.as_bytes()) {
        writeln!(
            &mut html,
            "<input type=\"hidden\" name=\"{}\" value=\"{}\">",
            escape_html(key.as_ref()),
            escape_html(value.as_ref()),
        )
        .ok();
    }
    html
}

pub(super) fn common_attachment_extensions() -> &'static [&'static str] {
    &[
        "pdf", "doc", "docx", "xls", "xlsx", "csv", "txt", "rtf", "odt", "jpg", "jpeg", "png",
        "zip",
    ]
}

pub(super) fn is_common_attachment_extension(extension: &str) -> bool {
    common_attachment_extensions().contains(&extension)
}

pub(super) fn custom_attachment_extension_value(extension: &str) -> &str {
    if is_common_attachment_extension(extension) {
        ""
    } else {
        extension
    }
}

pub(super) fn render_common_attachment_extension_options(selected_extension: &str) -> String {
    let mut html = String::from("<option value=\"\">Any extension</option>");
    for extension in common_attachment_extensions() {
        writeln!(
            &mut html,
            "<option value=\"{}\" {}>{}</option>",
            escape_html(extension),
            if *extension == selected_extension {
                "selected"
            } else {
                ""
            },
            escape_html(extension),
        )
        .ok();
    }
    html
}

pub(super) fn render_attachment_filter_hiddens(
    data: &AttachmentPageData,
    return_to: &str,
) -> String {
    let mut fields = Vec::new();
    fields.push(format!(
        "<input type=\"hidden\" name=\"return_to\" value=\"{}\">",
        escape_html(return_to)
    ));
    append_hidden_fields_for_message_filters(&mut fields, &data.filters.message);
    if let Some(account_id) = data.selected_account_id {
        fields.push(format!(
            "<input type=\"hidden\" name=\"account_id\" value=\"{}\">",
            account_id
        ));
    }
    if data.state.priority_filter != SenderPriorityFilter::All {
        fields.push(format!(
            "<input type=\"hidden\" name=\"priority\" value=\"{}\">",
            data.state.priority_filter.as_query_value()
        ));
    }
    append_hidden_fields_for_attachment_filters(&mut fields, &data.filters);
    if data.include_inline {
        fields.push("<input type=\"hidden\" name=\"include_inline\" value=\"1\">".to_string());
    }
    if data.include_inline_images {
        fields
            .push("<input type=\"hidden\" name=\"include_inline_images\" value=\"1\">".to_string());
    }
    if data.show_mime_details {
        fields.push("<input type=\"hidden\" name=\"show_mime_details\" value=\"1\">".to_string());
    }
    if !data.download_subfolder.trim().is_empty() {
        fields.push(format!(
            "<input type=\"hidden\" name=\"download_subfolder\" value=\"{}\">",
            escape_html(&data.download_subfolder)
        ));
    }
    fields.join("")
}

pub(super) fn append_hidden_fields_for_message_filters(
    fields: &mut Vec<String>,
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
            fields.push(format!(
                "<input type=\"hidden\" name=\"{}\" value=\"{}\">",
                key,
                escape_html(value)
            ));
        }
    }
    if let Some(value) = filters.has_attachments {
        fields.push(format!(
            "<input type=\"hidden\" name=\"has_attachments\" value=\"{}\">",
            if value { "1" } else { "0" }
        ));
    }
}

pub(super) fn append_hidden_fields_for_attachment_filters(
    fields: &mut Vec<String>,
    filters: &AttachmentSearchFilters,
) {
    for (key, value) in [
        ("extension", filters.extension.trim()),
        ("attachment_name", filters.attachment_name.trim()),
        ("min_size", filters.min_size.trim()),
        ("max_size", filters.max_size.trim()),
    ] {
        if !value.is_empty() {
            fields.push(format!(
                "<input type=\"hidden\" name=\"{}\" value=\"{}\">",
                key,
                escape_html(value)
            ));
        }
    }
}

pub(super) fn simple_attachment_type_label(attachment: &AttachmentRecord) -> String {
    if !attachment.extension.is_empty() {
        attachment.extension.clone()
    } else if attachment.mime_type == "application/pdf" {
        "pdf".to_string()
    } else if let Some((_, subtype)) = attachment.mime_type.split_once('/') {
        subtype.to_string()
    } else {
        attachment.mime_type.clone()
    }
}

pub(super) fn detailed_attachment_type_label(attachment: &AttachmentRecord) -> String {
    let simple = simple_attachment_type_label(attachment);
    if simple == attachment.mime_type {
        simple
    } else {
        format!("{} · {}", simple, attachment.mime_type)
    }
}

pub(super) fn attachment_column_date_label(timestamp: i64) -> String {
    format_timestamp_date_label(timestamp)
}

pub(super) fn attachment_display_filename(filename: &str) -> String {
    FsPath::new(filename)
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| filename.to_string())
}

pub(super) fn render_attachment_item(
    item: &AttachmentListItem,
    return_to: &str,
    show_mime_details: bool,
) -> String {
    let badge_label = simple_attachment_type_label(&item.attachment);
    let date_label = attachment_column_date_label(item.message.timestamp);
    let date_tooltip = format_timestamp_tooltip_label(item.message.timestamp);
    let source = format!("{} · {}", item.account_name, item.message.message_relpath);
    let display_subject = decode_display_header_value(&item.message.subject);
    let display_from = decode_display_header_value(&item.message.from);
    let context_title = format!("Email from {} on {}", display_from, date_tooltip);
    let display_filename = attachment_display_filename(&item.attachment.original_filename);
    let original_email_href = format!(
        "/attachments/{}/message/browser",
        url_encode_component(&item.attachment.attachment_key)
    );
    let preview = item
        .message_preview
        .as_deref()
        .unwrap_or("Message preview unavailable.");
    let cc_line = item
        .message_cc
        .as_deref()
        .map(|cc| {
            format!(
                "<span class=\"meta truncate\" title=\"{}\">Cc: {}</span>",
                escape_html(cc),
                escape_html(cc)
            )
        })
        .unwrap_or_default();
    let more_link = if item.message_preview_truncated {
        format!(
            " <a href=\"{}\" title=\"Open original email\">...More</a>",
            escape_html(&original_email_href)
        )
    } else {
        String::new()
    };
    let type_label = if show_mime_details {
        detailed_attachment_type_label(&item.attachment)
    } else {
        badge_label.clone()
    };

    let download_action = format!(
        "<form method=\"post\" action=\"/attachments/{}/download/browser\" class=\"icon-form\">
          <button class=\"row-action-button\" type=\"submit\" title=\"Download attachment locally\" aria-label=\"Download attachment locally\">↓</button>
        </form>",
        escape_html(&item.attachment.attachment_key),
    );
    let paperless_action = if let Some(sent_at) = item.paperless_sent_at.as_deref() {
        format!(
            "<button class=\"row-action-button paperless-sent-button\" type=\"button\" title=\"Successfully sent to Paperless on {}\" aria-label=\"Successfully sent to Paperless on {}\" data-paperless-sent-button>✓</button>",
            escape_html(sent_at),
            escape_html(sent_at),
        )
    } else {
        format!(
            "<form method=\"post\" action=\"/attachments/send-paperless\" class=\"icon-form\" data-paperless-form>
              <input type=\"hidden\" name=\"return_to\" value=\"{}\">
              <input type=\"hidden\" name=\"attachment_keys\" value=\"{}\">
              <button class=\"secondary row-action-button paperless-send-button\" type=\"submit\" title=\"Send attachment to Paperless\" aria-label=\"Send attachment to Paperless\" data-paperless-button>&#8594;</button>
            </form>",
            escape_html(return_to),
            escape_html(&item.attachment.attachment_key),
        )
    };
    let sender_importance = render_sender_importance_select(&item.sender_priority, return_to);

    format!(
        "<article class=\"attachment-row\" data-attachment-row data-attachment-key=\"{}\" tabindex=\"0\" aria-selected=\"false\">
          <span class=\"meta truncate\" title=\"{}\">{}</span>
          <div class=\"attachment-main\">
            <strong class=\"truncate\" title=\"{}\">{}</strong>
            <span class=\"meta truncate\" title=\"{}\">{} · {} · {} · {}</span>
            <div class=\"attachment-context\" hidden>
              <strong class=\"truncate\" title=\"{}\">{}</strong>
              <span class=\"meta truncate\" title=\"{}\">From: {}</span>
              {}
              <p class=\"attachment-context-preview\">{}{}</p>
            </div>
          </div>
          <span class=\"badge truncate\" title=\"{}\">{}</span>
          <div class=\"row-actions\">{}{}</div>
          <div class=\"priority-cell\">{}</div>
        </article>",
        escape_html(&item.attachment.attachment_key),
        escape_html(&date_tooltip),
        escape_html(&date_label),
        escape_html(&format!(
            "{} · Source: {}",
            item.attachment.original_filename, source
        )),
        escape_html(&display_filename),
        escape_html(&format!("{} · Source: {}", display_subject, source)),
        escape_html(&display_subject),
        escape_html(&item.account_name),
        escape_html(&display_from),
        escape_html(&format_file_size(item.attachment.size_bytes)),
        escape_html(&display_subject),
        escape_html(&display_subject),
        escape_html(&context_title),
        escape_html(&display_from),
        cc_line,
        escape_html(preview),
        more_link,
        escape_html(&type_label),
        escape_html(&type_label),
        download_action,
        paperless_action,
        sender_importance,
    )
}

pub(super) fn render_attachment_list_header() -> String {
    "<div class=\"attachment-list-header\" aria-hidden=\"true\">
      <span>Date</span>
      <span>Attachment</span>
      <span>Type</span>
      <span>Actions</span>
      <span>Sender importance</span>
    </div>"
        .to_string()
}

pub(super) fn render_attachment_pagination(state: &AttachmentListViewState) -> String {
    let previous_page = state.page.saturating_sub(1);
    let next_page = state.page + 1;
    let previous_href = attachment_page_href(&state.base_query, previous_page);
    let next_href = attachment_page_href(&state.base_query, next_page);
    format!(
        "<section class=\"panel pagination-row\">
          <a class=\"button-link secondary {}\" href=\"{}\">Previous page</a>
          <span class=\"meta\">Page {}</span>
          <a class=\"button-link secondary {}\" href=\"{}\">Next page</a>
        </section>",
        if state.has_previous_page {
            ""
        } else {
            "disabled"
        },
        escape_html(&previous_href),
        state.page,
        if state.has_next_page { "" } else { "disabled" },
        escape_html(&next_href),
    )
}

pub(super) fn attachment_return_to(state: &AttachmentListViewState) -> String {
    attachment_page_href(&state.base_query, state.page)
}

pub(super) fn attachment_page_href(base_query: &str, page: usize) -> String {
    let page = usize::max(page, 1);
    let mut query = base_query.to_string();
    if page > 1 {
        if !query.is_empty() {
            query.push('&');
        }
        query.push_str(&format!("page={page}"));
    }
    if query.is_empty() {
        "/attachments".to_string()
    } else {
        format!("/attachments?{query}")
    }
}

pub(super) fn format_file_size(size_bytes: i64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;

    let size = size_bytes.max(0) as f64;
    if size >= GIB {
        format!("{:.1} GiB", size / GIB)
    } else if size >= MIB {
        format!("{:.1} MiB", size / MIB)
    } else if size >= KIB {
        format!("{:.1} KiB", size / KIB)
    } else {
        format!("{} B", size_bytes.max(0))
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn render_search(
    identity: &Identity,
    accounts: &[AccountRecord],
    filters: &MessageSearchFilters,
    selected_account_id: Option<i64>,
    results: &[SearchResult],
    state: &SearchViewState,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut body = String::new();
    body.push_str(&render_toasts(flash, error));

body.push_str(
        "<section class=\"page-heading\">
           <div>
             <p class=\"eyebrow\">Mail</p>
             <h1>Search saved messages</h1>
           </div>
         </section>",
    );

    writeln!(
        &mut body,
        "<section class=\"panel search-panel\">
          <form method=\"get\" action=\"/search\" class=\"search-form\">
            <div class=\"primary-search-row\">
              <label class=\"primary-search-field\">Search mail
                <input class=\"primary-search-input\" name=\"q\" value=\"{}\">
              </label>
              <button class=\"icon-button search-submit\" type=\"submit\" title=\"Search mail\" aria-label=\"Search mail\">⌕</button>
            </div>
            <details class=\"filter-accordion\">
              <summary>Filters</summary>
              <div class=\"filter-grid\">
                <label class=\"field-wide\">Mailbox
                  <select name=\"account_id\">
                    <option value=\"\">All mailboxes</option>
                    {}
                  </select>
                </label>
                <label>Sender importance
                  <select name=\"priority\">{}</select>
                </label>
                <label class=\"field-wide\">Sender address
                  <input name=\"sender_address\" value=\"{}\">
                </label>
                <label>Sender name
                  <input name=\"sender_name\" value=\"{}\">
                </label>
                <label>Sender domain
                  <input name=\"sender_domain\" value=\"{}\">
                </label>
                <label class=\"field-wide\">Subject
                  <input name=\"subject\" value=\"{}\">
                </label>
                <label class=\"field-wide\">Body text
                  <input name=\"body_text\" value=\"{}\">
                </label>
                <label>Has attachments
                  <select name=\"has_attachments\">{}</select>
                </label>
                <label>Date from
                  <input type=\"date\" name=\"date_from\" value=\"{}\">
                </label>
                <label>Date to
                  <input type=\"date\" name=\"date_to\" value=\"{}\">
                </label>
                <div class=\"filter-link-row\">
                  <a class=\"advanced-filter-link\" href=\"/search?q=\">Reset filters</a>
                </div>
              </div>
            </details>
          </form>
        </section>",
        escape_html(&filters.q),
        render_account_options(accounts, selected_account_id),
        render_sender_priority_filter_options(state.priority_filter),
        escape_html(&filters.sender_address),
        escape_html(&filters.sender_name),
        escape_html(&filters.sender_domain),
        escape_html(&filters.subject),
        escape_html(&filters.body_text),
        render_optional_bool_options(filters.has_attachments),
        escape_html(&filters.date_from),
        escape_html(&filters.date_to),
    )
    .ok();

    if state.submitted {
        writeln!(
            &mut body,
            "<section class=\"result-summary\"><strong>{}</strong><span class=\"meta\"> matching messages across indexed mailboxes</span></section>",
            pluralize_results(state.result_count),
        )
        .ok();
    }

    if let Some(message) = state.empty_message.as_deref() {
        writeln!(
            &mut body,
            "<section class=\"empty-state\"><p class=\"meta\">{}</p></section>",
            escape_html(message)
        )
        .ok();
    }

    if !results.is_empty() {
        let return_to = search_page_href(filters, selected_account_id, state.priority_filter);
        writeln!(
            &mut body,
            "<section class=\"mail-list\">
              {}
              {}
            </section>",
            render_mail_list_header(),
            results
                .iter()
                .map(|result| render_search_result(result, &return_to))
                .collect::<Vec<_>>()
                .join("")
        )
        .ok();
    }

    layout("Search Mail", Some(identity), "search", &body)
}

pub(super) fn render_sender_priority_filter_options(selected: SenderPriorityFilter) -> String {
    [
        SenderPriorityFilter::All,
        SenderPriorityFilter::High,
        SenderPriorityFilter::Normal,
        SenderPriorityFilter::Low,
    ]
    .into_iter()
    .map(|option| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            option.as_query_value(),
            if option == selected { "selected" } else { "" },
            escape_html(option.label())
        )
    })
    .collect::<Vec<_>>()
    .join("")
}

pub(super) fn render_optional_bool_options(selected: Option<bool>) -> String {
    [
        ("", selected.is_none(), "Any"),
        ("1", selected == Some(true), "Yes"),
        ("0", selected == Some(false), "No"),
    ]
    .into_iter()
    .map(|(value, is_selected, label)| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            value,
            if is_selected { "selected" } else { "" },
            label
        )
    })
    .collect::<Vec<_>>()
    .join("")
}

pub(super) fn pluralize_results(count: usize) -> String {
    if count == 1 {
        "1 result".to_string()
    } else {
        format!("{count} results")
    }
}

pub(super) fn pluralize_attachments(count: usize) -> String {
    if count == 1 {
        "1 attachment".to_string()
    } else {
        format!("{count} attachments")
    }
}

pub(super) fn render_account_options(
    accounts: &[AccountRecord],
    selected_account_id: Option<i64>,
) -> String {
    accounts
        .iter()
        .map(|account| {
            format!(
                "<option value=\"{}\" {}>{}</option>",
                account.id,
                if selected_account_id == Some(account.id) {
                    "selected"
                } else {
                    ""
                },
                escape_html(&account.display_name)
            )
        })
        .collect::<Vec<_>>()
        .join("")
}

pub(super) fn search_page_href(
    filters: &MessageSearchFilters,
    selected_account_id: Option<i64>,
    priority_filter: SenderPriorityFilter,
) -> String {
    let mut pairs = Vec::new();
    append_message_filter_query_pairs(&mut pairs, filters);
    if let Some(account_id) = selected_account_id {
        pairs.push(("account_id", account_id.to_string()));
    }
    if priority_filter != SenderPriorityFilter::All {
        pairs.push(("priority", priority_filter.as_query_value().to_string()));
    }
    if pairs.is_empty() {
        "/search".to_string()
    } else {
        format!(
            "/search?{}",
            pairs
                .into_iter()
                .map(|(key, value)| format!("{key}={}", url_encode_component(&value)))
                .collect::<Vec<_>>()
                .join("&")
        )
    }
}

pub(super) fn render_sender_importance_select(
    view: &SenderPriorityView,
    return_to: &str,
) -> String {
    let Some(identity) = view.identity.as_ref() else {
        return String::new();
    };

    render_sender_priority_select(
        SenderRuleKind::Address,
        &identity.address,
        view.address_rule.unwrap_or(SenderPriority::Normal),
        return_to,
    )
}

pub(super) fn render_sender_priority_select(
    kind: SenderRuleKind,
    value: &str,
    selected: SenderPriority,
    return_to: &str,
) -> String {
    let label = "Sender importance";
    let options = [
        SenderPriority::High,
        SenderPriority::Normal,
        SenderPriority::Low,
    ]
    .into_iter()
    .map(|priority| {
        format!(
            "<option value=\"{}\" {}>{}</option>",
            priority.as_stored_value(),
            if priority == selected { "selected" } else { "" },
            escape_html(priority.dropdown_label())
        )
    })
    .collect::<Vec<_>>()
    .join("");
    format!(
        "<select class=\"priority-select {}\" name=\"priority\" data-priority-select data-sender-kind=\"{}\" data-sender-value=\"{}\" data-return-to=\"{}\" data-previous-priority=\"{}\" aria-label=\"{} for {}\" title=\"{} for {}\">{}</select>",
        priority_select_class(selected),
        kind.as_stored_value(),
        escape_html(value),
        escape_html(return_to),
        selected.as_stored_value(),
        escape_html(label),
        escape_html(value),
        escape_html(label),
        escape_html(value),
        options,
    )
}

pub(super) fn priority_select_class(priority: SenderPriority) -> &'static str {
    match priority {
        SenderPriority::High => "priority-select-high",
        SenderPriority::Normal => "priority-select-normal",
        SenderPriority::Low => "priority-select-low",
    }
}

pub(super) fn render_sender_cell(raw_sender: &str) -> String {
    let display = sender_display_from_header(raw_sender);
    let secondary = display
        .secondary
        .as_deref()
        .map(|value| {
            format!(
                "<span class=\"sender-email truncate\">{}</span>",
                escape_html(value)
            )
        })
        .unwrap_or_default();
    format!(
        "<div class=\"sender-cell\" title=\"{}\">
          <strong class=\"truncate\">{}</strong>
          {}
        </div>",
        escape_html(raw_sender),
        escape_html(&display.primary),
        secondary,
    )
}

pub(super) fn render_search_result(result: &SearchResult, return_to: &str) -> String {
    let sender_importance = render_sender_importance_select(&result.sender_priority, return_to);
    let source = format!("{} · {}", result.account_name, result.message_relpath);

    let tags = if result.tags.is_empty() {
        vec!["<span class=\"meta\">No tags</span>".to_string()]
    } else {
        result
            .tags
            .iter()
            .map(|tag| format!("<span class=\"tag\">{}</span>", escape_html(tag)))
            .collect::<Vec<_>>()
    };

    format!(
        "<article class=\"mail-row\">
          <span class=\"meta truncate\" title=\"{}\">{}</span>
          {}
          <div class=\"mail-subject\" title=\"{}\">
            <strong class=\"truncate\" title=\"{}\">{}</strong>
          </div>
          <div class=\"tag-list compact\">{}</div>
          <div class=\"priority-cell\">{}</div>
        </article>",
        escape_html(&format_timestamp_tooltip_label(result.timestamp)),
        escape_html(&result.date_label),
        render_sender_cell(&result.from),
        escape_html(&source),
        escape_html(&result.subject),
        escape_html(&result.subject),
        tags.join(""),
        sender_importance,
    )
}

pub(super) fn render_mail_list_header() -> String {
    "<div class=\"mail-list-header\" aria-hidden=\"true\">
      <span>Date</span>
      <span>Sender</span>
      <span>Message</span>
      <span>Tags</span>
      <span>Sender importance</span>
    </div>"
        .to_string()
}
