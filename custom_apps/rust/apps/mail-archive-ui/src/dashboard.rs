use super::*;

pub(super) fn load_dashboard_account_views(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<DashboardAccountView>, String> {
    reconcile_interrupted_syncs(config)?;
    let accounts = list_accounts_for_user(config, username)?;
    Ok(accounts
        .into_iter()
        .map(|account| build_dashboard_account_view(config, account))
        .collect())
}

pub(super) fn load_dashboard_status_payload(
    config: &AppConfig,
    username: &str,
) -> Result<DashboardStatusPayload, String> {
    let accounts = load_dashboard_account_views(config, username)?;
    let statuses = accounts
        .iter()
        .map(|view| view.status.clone())
        .collect::<Vec<_>>();
    Ok(DashboardStatusPayload {
        generated_at: Utc::now().to_rfc3339(),
        totals: dashboard_totals(statuses.clone()),
        accounts: statuses,
    })
}

pub(super) fn build_dashboard_account_view(
    config: &AppConfig,
    account: AccountRecord,
) -> DashboardAccountView {
    let last_activity = last_activity_label(&account);
    let sync_diagnostic = stored_sync_diagnostic(&account);
    let (index_state, counts, progress_error) = match ensure_account_paths(config, &account) {
        Ok(account_paths) => {
            let index_state = account_index_state(&account_paths);
            match load_account_progress_snapshot(config, account.id) {
                Ok(Some(snapshot)) => {
                    let note = match snapshot.snapshot_status.as_str() {
                        "error" => snapshot.snapshot_note.clone().or_else(|| {
                            Some(
                                "Dashboard counts could not be refreshed for this mailbox."
                                    .to_string(),
                            )
                        }),
                        "stale" => snapshot.snapshot_note.clone().or_else(|| {
                            Some(
                                "Dashboard counts are waiting for the next sync or reindex."
                                    .to_string(),
                            )
                        }),
                        _ => None,
                    };
                    (index_state, snapshot_counts(&snapshot), note)
                }
                Ok(None) => (
                    index_state,
                    AccountProgressCounts::default(),
                    Some(
                        "Dashboard counts will appear after the next sync or reindex.".to_string(),
                    ),
                ),
                Err(error) => (index_state, AccountProgressCounts::default(), Some(error)),
            }
        }
        Err(error) => (
            IndexState::NotConfigured,
            AccountProgressCounts::default(),
            Some(error),
        ),
    };
    let metrics_diagnostic = progress_error.map(metrics_sync_diagnostic);
    let (status_class, status_label) = account_status(
        &account,
        index_state,
        &counts,
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
    );
    let progress_note = account_progress_note(
        &account,
        &counts,
        index_state,
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
    );
    let overlap_note = account_overlap_note(&counts, metrics_diagnostic.as_ref());
    let sync_notice = dashboard_sync_notice(
        sync_diagnostic.as_ref(),
        metrics_diagnostic.as_ref(),
        &counts,
        index_state,
    );
    let last_sync_error = account
        .last_sync_detail
        .clone()
        .or_else(|| account.last_sync_error.clone());

    DashboardAccountView {
        status: AccountStatusPayload {
            id: account.id,
            status_class: status_class.to_string(),
            status_label: status_label.to_string(),
            index_label: account_index_label(index_state).to_string(),
            last_activity,
            archived_message_count: counts.archived_message_count as usize,
            indexed_message_count: counts.indexed_message_count as usize,
            pending_index_count: counts.pending_index_count as usize,
            index_coverage_percent: counts.index_coverage_percent as usize,
            archive_file_count: counts.archive_file_count as usize,
            overlap_file_count: counts.overlap_file_count as usize,
            progress_note,
            overlap_note,
            last_sync_error,
            diagnostic_phase: sync_notice.diagnostic_phase,
            diagnostic_code: sync_notice.diagnostic_code,
            diagnostic_summary: sync_notice.diagnostic_summary,
            diagnostic_detail: sync_notice.diagnostic_detail,
            diagnostic_impact: sync_notice.diagnostic_impact,
            recommended_action: sync_notice.recommended_action,
            progress_warning: sync_notice.progress_warning,
            progress_warning_detail: sync_notice.progress_warning_detail,
            progress_warning_action: sync_notice.progress_warning_action,
        },
        account,
    }
}

#[cfg(test)]
pub(super) fn scan_maildir_inventory(maildir: &FsPath) -> Result<MaildirInventory, String> {
    let mut message_keys = HashSet::new();
    let mut archive_file_count = 0;
    scan_maildir_inventory_inner(maildir, false, &mut archive_file_count, &mut message_keys)?;
    let logical_message_count = message_keys.len();
    Ok(MaildirInventory {
        archive_file_count,
        logical_message_count,
        overlap_file_count: archive_file_count.saturating_sub(logical_message_count),
    })
}

#[cfg(test)]
fn scan_maildir_inventory_inner(
    path: &FsPath,
    count_files_here: bool,
    archive_file_count: &mut usize,
    message_keys: &mut HashSet<String>,
) -> Result<(), String> {
    let entries = fs::read_dir(path)
        .map_err(|error| format!("failed to read {}: {error}", path.display()))?;

    for entry in entries {
        let entry = entry.map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;

        if file_type.is_dir() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            scan_maildir_inventory_inner(
                &entry.path(),
                name.as_ref() == "cur" || name.as_ref() == "new",
                archive_file_count,
                message_keys,
            )?;
        } else if count_files_here && file_type.is_file() {
            *archive_file_count += 1;
            let metadata = read_message_metadata(&entry.path())?;
            message_keys.insert(message_key_from_metadata(&metadata)?);
        }
    }

    Ok(())
}

pub(super) fn count_indexed_messages(account_paths: &AccountPaths) -> Result<usize, String> {
    let output = execute_command(
        "notmuch",
        &["count", "*"],
        &[
            (
                "HOME",
                account_paths.account_state_root.to_string_lossy().as_ref(),
            ),
            (
                "NOTMUCH_CONFIG",
                account_paths.notmuch_config.to_string_lossy().as_ref(),
            ),
        ],
    )?;

    if !output.status.success() {
        let detail = command_failure_detail("notmuch", &output);
        if detail.contains("No database found") || detail.contains("not initialized") {
            return Ok(0);
        }
        return Err(detail);
    }

    let trimmed = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if trimmed.is_empty() {
        return Ok(0);
    }
    trimmed.parse::<usize>().map_err(|error| {
        format!(
            "failed to parse indexed message count from '{}': {error}",
            trimmed
        )
    })
}

pub(super) fn message_key_from_metadata(metadata: &MessageMetadata) -> Result<String, String> {
    metadata
        .normalized_message_id
        .as_ref()
        .map(|value| format!("message-id:{value}"))
        .or_else(|| {
            metadata
                .message_sha256
                .as_ref()
                .map(|value| format!("sha256:{value}"))
        })
        .ok_or_else(|| "message metadata must provide an identity key".to_string())
}

pub(super) fn progress_counts(
    inventory: &MaildirInventory,
    indexed_message_count: usize,
) -> AccountProgressCounts {
    let archived_message_count = inventory.logical_message_count;
    let pending_index_count = archived_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = indexed_message_count
        .min(archived_message_count)
        .saturating_mul(100)
        .checked_div(archived_message_count)
        .unwrap_or_else(|| usize::from(indexed_message_count > 0) * 100);
    AccountProgressCounts {
        archived_message_count: archived_message_count as i64,
        indexed_message_count: indexed_message_count as i64,
        pending_index_count: pending_index_count as i64,
        index_coverage_percent: index_coverage_percent as i64,
        archive_file_count: inventory.archive_file_count as i64,
        overlap_file_count: inventory.overlap_file_count as i64,
    }
}

fn dashboard_totals(accounts: Vec<AccountStatusPayload>) -> DashboardTotals {
    let archived_message_count = accounts
        .iter()
        .map(|account| account.archived_message_count)
        .sum::<usize>();
    let indexed_message_count = accounts
        .iter()
        .map(|account| account.indexed_message_count)
        .sum::<usize>();
    let archive_file_count = accounts
        .iter()
        .map(|account| account.archive_file_count)
        .sum::<usize>();
    let overlap_file_count = accounts
        .iter()
        .map(|account| account.overlap_file_count)
        .sum::<usize>();
    let pending_index_count = archived_message_count.saturating_sub(indexed_message_count);
    let index_coverage_percent = indexed_message_count
        .min(archived_message_count)
        .saturating_mul(100)
        .checked_div(archived_message_count)
        .unwrap_or_else(|| usize::from(indexed_message_count > 0) * 100);

    DashboardTotals {
        archived_message_count,
        indexed_message_count,
        pending_index_count,
        index_coverage_percent,
        archive_file_count,
        overlap_file_count,
    }
}

fn account_index_label(index_state: IndexState) -> &'static str {
    match index_state {
        IndexState::Indexed => "Indexed",
        IndexState::ConfiguredNoDatabase | IndexState::NotConfigured => "Unindexed",
    }
}

pub(super) fn account_progress_note(
    account: &AccountRecord,
    counts: &AccountProgressCounts,
    index_state: IndexState,
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
) -> String {
    if metrics_diagnostic.is_some() {
        "Counts are unavailable because the archive or search index could not be read.".to_string()
    } else if account.last_sync_status.as_deref() == Some("running")
        && counts.pending_index_count > 0
    {
        "Sync is active. Archived message count should rise first, then the index will catch up."
            .to_string()
    } else if sync_diagnostic
        .as_ref()
        .and_then(|value| value.phase)
        .is_some_and(|phase| matches!(phase, SyncPhase::Index | SyncPhase::Reconcile))
        && counts.pending_index_count > 0
    {
        "Saved messages are ahead of search. Use Repair search to catch up.".to_string()
    } else if counts.archived_message_count == 0 {
        "No archived messages yet.".to_string()
    } else if counts.pending_index_count > 0 {
        "Saved messages are ahead of search. Use Repair search to catch up.".to_string()
    } else if index_state == IndexState::Indexed {
        "Search index is caught up with the archived messages.".to_string()
    } else {
        "Use Sync Now or Repair search to prepare saved mail for search.".to_string()
    }
}

pub(super) fn account_overlap_note(
    counts: &AccountProgressCounts,
    metrics_diagnostic: Option<&SyncDiagnostic>,
) -> Option<String> {
    if metrics_diagnostic.is_some() || counts.overlap_file_count == 0 {
        return None;
    }

    Some(format!(
        "Archive contains {} physical message files representing {} logical messages because synced folders overlap.",
        counts.archive_file_count, counts.archived_message_count
    ))
}

fn metrics_sync_diagnostic(error: String) -> SyncDiagnostic {
    SyncDiagnostic::new(
        SyncPhase::Metrics,
        "metrics_unavailable",
        "Archive counts could not be verified for this mailbox.",
        error,
    )
}

fn diagnostic_impact(
    diagnostic: &SyncDiagnostic,
    counts: &AccountProgressCounts,
    index_state: IndexState,
) -> Option<String> {
    match diagnostic.phase {
        Some(SyncPhase::Download) => Some(
            "The sync did not reach the indexing step, so newly downloaded mail may still be missing."
                .to_string(),
        ),
        Some(SyncPhase::Index | SyncPhase::Reconcile)
            if counts.pending_index_count > 0 =>
        {
            Some(format!(
                "{} archived messages are not searchable yet.",
                counts.pending_index_count
            ))
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) => Some(
            "Archived messages may be missing from search until reindex succeeds.".to_string(),
        ),
        Some(SyncPhase::Preflight) => Some(
            "The sync stopped before the mailbox download step started.".to_string(),
        ),
        Some(SyncPhase::Metrics) => Some(
            "Archive and index counts are hidden until the archive can be read again."
                .to_string(),
        ),
        None if counts.pending_index_count > 0 => Some(format!(
            "{} archived messages may not be searchable yet.",
            counts.pending_index_count
        )),
        None if index_state != IndexState::Indexed => Some(
            "The archive has not been fully indexed yet.".to_string(),
        ),
        None => Some("Review the technical detail below before retrying.".to_string()),
    }
}

fn diagnostic_recommended_action(
    diagnostic: &SyncDiagnostic,
    counts: &AccountProgressCounts,
) -> Option<String> {
    match diagnostic.phase {
        Some(SyncPhase::Download | SyncPhase::Preflight) => {
            Some("Check the mailbox credentials, then use Sync Now again.".to_string())
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) if counts.pending_index_count > 0 => {
            Some("Use Repair search to catch search up with saved messages.".to_string())
        }
        Some(SyncPhase::Index | SyncPhase::Reconcile) => {
            Some("Run Repair search after checking that the archive is available.".to_string())
        }
        Some(SyncPhase::Metrics) => {
            Some("Check that the archive is available, then refresh the dashboard.".to_string())
        }
        None => Some(
            "Open troubleshooting details if needed, then retry Sync Now or Repair search."
                .to_string(),
        ),
    }
}

fn dashboard_sync_notice(
    sync_diagnostic: Option<&SyncDiagnostic>,
    metrics_diagnostic: Option<&SyncDiagnostic>,
    counts: &AccountProgressCounts,
    index_state: IndexState,
) -> DashboardSyncNotice {
    let mut notice = DashboardSyncNotice {
        diagnostic_phase: None,
        diagnostic_code: None,
        diagnostic_summary: None,
        diagnostic_detail: None,
        diagnostic_impact: None,
        recommended_action: None,
        progress_warning: None,
        progress_warning_detail: None,
        progress_warning_action: None,
    };

    if let Some(diagnostic) = sync_diagnostic {
        notice.diagnostic_phase = diagnostic.phase.map(SyncPhase::as_str).map(str::to_string);
        notice.diagnostic_code = Some(diagnostic.code.clone());
        notice.diagnostic_summary = Some(diagnostic.summary.clone());
        notice.diagnostic_detail = Some(diagnostic.detail.clone());
        notice.diagnostic_impact = diagnostic_impact(diagnostic, counts, index_state);
        notice.recommended_action = diagnostic_recommended_action(diagnostic, counts);
    }

    if let Some(diagnostic) = metrics_diagnostic {
        notice.progress_warning = Some(diagnostic.summary.clone());
        notice.progress_warning_detail = Some(diagnostic.detail.clone());
        notice.progress_warning_action = diagnostic_recommended_action(diagnostic, counts);

        if notice.diagnostic_summary.is_none() {
            notice.diagnostic_phase = diagnostic.phase.map(SyncPhase::as_str).map(str::to_string);
            notice.diagnostic_code = Some(diagnostic.code.clone());
            notice.diagnostic_summary = Some(diagnostic.summary.clone());
            notice.diagnostic_detail = Some(diagnostic.detail.clone());
            notice.diagnostic_impact = diagnostic_impact(diagnostic, counts, index_state);
            notice.recommended_action = diagnostic_recommended_action(diagnostic, counts);
        }
    }

    notice
}

pub(super) fn provider_label(provider: &str) -> &str {
    match provider {
        "gmail" => "Gmail",
        "generic_imap" => "Other mailbox",
        _ => "Custom mailbox",
    }
}

pub(super) fn provider_icon_label(provider: &str) -> &'static str {
    match provider {
        "gmail" => "M",
        _ => "✉",
    }
}

pub(super) fn provider_icon_class(provider: &str) -> &'static str {
    match provider {
        "gmail" => "gmail",
        _ => "imap",
    }
}

fn last_activity_label(account: &AccountRecord) -> String {
    let Some(value) = account
        .last_sync_finished_at
        .as_deref()
        .or(account.last_sync_started_at.as_deref())
    else {
        return "Never synced".to_string();
    };

    let Ok(synced_at) = DateTime::parse_from_rfc3339(value) else {
        return "Synced recently".to_string();
    };
    let elapsed = Utc::now().signed_duration_since(synced_at.with_timezone(&Utc));
    let elapsed_seconds = elapsed.num_seconds().max(0);

    if elapsed_seconds < 60 {
        "Synced <1 minute ago".to_string()
    } else if elapsed_seconds < 60 * 60 {
        let minutes = elapsed_seconds / 60;
        format!(
            "Synced {minutes} {} ago",
            if minutes == 1 { "minute" } else { "minutes" }
        )
    } else if elapsed_seconds < 24 * 60 * 60 {
        let hours = elapsed_seconds / (60 * 60);
        format!(
            "Synced {hours} {} ago",
            if hours == 1 { "hour" } else { "hours" }
        )
    } else {
        let days = elapsed_seconds / (24 * 60 * 60);
        format!(
            "Synced {days} {} ago",
            if days == 1 { "day" } else { "days" }
        )
    }
}
