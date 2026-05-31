export type AccountStatus = {
  id: number;
  status_class: string;
  status_label: string;
  index_label: string;
  last_activity: string;
  archived_message_count: number;
  indexed_message_count: number;
  pending_index_count: number;
  index_coverage_percent: number;
  archive_file_count: number;
  overlap_file_count: number;
  progress_note: string;
  overlap_note?: string | null;
  last_sync_error?: string | null;
  diagnostic_phase?: string | null;
  diagnostic_code?: string | null;
  diagnostic_summary?: string | null;
  diagnostic_detail?: string | null;
  diagnostic_impact?: string | null;
  recommended_action?: string | null;
  progress_warning?: string | null;
  progress_warning_detail?: string | null;
  progress_warning_action?: string | null;
};

export type AccountStatusPayload = {
  totals: {
    archived_message_count: number;
    indexed_message_count: number;
    pending_index_count: number;
    index_coverage_percent: number;
  };
  accounts: AccountStatus[];
};
