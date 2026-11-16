import type { FirmwareConfig } from "./config";
export interface Observation {
  recorded_at: string | null;
  received_at: string;
  /** null for a fault reading (sensor not read); never a zero. */
  gwl: number | null;
  gwl_text: string | null;
  rssi: number | null;
  battery_v: number | null;
  solar_v: number | null;
  time_quality: string;
  time_reason: string;
  quality_reasons: string[];
  duplicate_outcome: string;
  interpretation_version: string;
}
export interface Device {
  device_id: string;
  display_name: string;
  profile: string;
  clock_policy: string;
  revoked: boolean;
  status: string;
  status_reason: string;
  last_received_at: string | null;
  observation_count: number;
  conflict_count: number;
  latest_received: Observation | null;
  latest_plausible: Observation | null;
  min_limit: number | null;
  max_limit: number | null;
  location_id: string | null;
  sensor_id: string | null;
  local_offset_min: number | null;
  last_ready_at: string | null;
  desired_config: Record<string, string> | null;
  applied_config: Record<string, string> | null;
  project_config: Record<string, string> | null;
  clock_change_unverified: boolean;
  capabilities: {
    test: boolean;
    project_settings: boolean;
    cfg_keys: string[];
    danger_commands: string[];
    /** 1 = legacy payloads, 2 = firmware 2.2 `{op,args}` commands. */
    protocol?: 1 | 2;
    settings?: boolean;
    basic_ops?: string[];
    danger_ops?: string[];
    handshake_ops?: string[];
    unsupported_by_firmware?: string[];
    downloads?: boolean;
  };
  open_alert_count: number;
  // Protocol revision 2 (null/absent for revision 1 units); see README.
  protocol_rev?: number | null;
  link_state?: "online" | "ready" | "sleep" | "offline" | null;
  link_state_at?: string | null;
  link_reason?: string | null;
  link_retained?: boolean;
  next_contact_at?: string | null;
  expected_contact_at?: string | null;
  stale_after?: string | null;
  listen_window_s?: number | null;
  boot_count?: number | null;
  info?: Record<string, unknown> | null;
  info_at?: string | null;
  health?: Record<string, unknown> | null;
  health_at?: string | null;
  settings_gen?: number | null;
  settings?: Record<string, unknown> | null;
  settings_at?: string | null;
  open_gap_count?: number;
  pending_challenge_count?: number;
}
export interface SeriesPoint {
  recorded_at: string;
  gwl: number;
  gwl_text: string | null;
  battery_v: number | null;
  rssi: number | null;
  sample_count: number;
  conflict: boolean;
}
export interface Series {
  device_id: string;
  points: SeriesPoint[];
  min_gwl: number | null;
  max_gwl: number | null;
  bucket_minutes: number;
  truncated: boolean;
}
export interface Alert {
  id: number;
  device_id: string;
  kind: string;
  state: string;
  trigger_value: number;
  opened_at: string;
  resolved_at: string | null;
}
export interface Command {
  id: number;
  device_id: string;
  kind: string;
  payload: FirmwareConfig | Record<string, string> | string;
  state: string;
  requested_by: string;
  created_at: string;
  sent_at: string | null;
  acked_at: string | null;
  ack_payload: unknown;
  firmware_ack_expected: boolean;
  supported?: boolean;
  // Protocol revision 2 fields (protocol = 2).
  protocol?: number;
  op?: string | null;
  args?: Record<string, unknown> | null;
  expires_at?: string | null;
  publish_count?: number;
  last_published_at?: string | null;
  final_status?: string | null;
  status_reason?: string | null;
  hold_until_sleep?: boolean;
  parent_id?: number | null;
  preconfirmed?: boolean;
  challenge?: {
    nonce: string;
    nexp: number;
    unsaved_frames: number | null;
    unsaved_bytes: number | null;
    received_at: string;
  } | null;
  challenge_expires_at?: string | null;
  origin?: string;
  download_id?: number | null;
}
/** Revision 2 rows; shapes are documented in README "Protocol revision 2 API". */
export interface HealthSample {
  id: number;
  source: string;
  recorded_at: string;
  time_source: string;
  received_at: string;
  uptime_s: number | null;
  csq: number | null;
  bat_mv: number | null;
  sol_mv: number | null;
  sd: string | null;
  sd_free_mb: number | null;
  mram: string | null;
  unsaved: number | null;
  usable: number | null;
  log: string | null;
  settings_gen: number | null;
  next_contact_at: string | null;
  err: number | null;
}
export interface DeviceEvent {
  id: number;
  source: "record" | "alert" | "server";
  event: string;
  log_id: number | null;
  seq: number | null;
  record_type: number | null;
  recorded_at: string | null;
  time_valid: boolean | null;
  time_rel_s: number | null;
  time_source: string | null;
  received_at: string;
  details: Record<string, unknown>;
  confirmed_by_record: boolean | null;
}
export interface StreamGap {
  id: number;
  log_id: number;
  from_seq: number;
  to_seq: number;
  state: "open" | "requested" | "unrecoverable" | "filled";
  attempts: number;
  command_id: number | null;
  detected_at: string;
  resolved_at: string | null;
}
export interface FileDownload {
  id: number;
  path: string;
  state: "active" | "complete" | "failed" | "cancelled";
  size: number | null;
  received_bytes: number;
  crc32: string | null;
  error: string | null;
  created_at: string;
  completed_at: string | null;
}
export interface Delivery {
  received_at: string;
  topic: string;
  kind: string;
  device_id: string | null;
  claimed_device_id: string | null;
  qos: number;
  payload: string;
  state: string;
  reason: string | null;
  detail: string | null;
  time_quality: string | null;
  duplicate_outcome: string | null;
  source_profile: string | null;
  binding_key: string | null;
}
export interface Status {
  user: { username: string; role: "operator" | "viewer" };
  service: string;
  broker: {
    connected: boolean;
    configured: boolean;
    lastError?: string | null;
    last_error?: string | null;
  };
  ingest: Record<string, unknown>;
}
