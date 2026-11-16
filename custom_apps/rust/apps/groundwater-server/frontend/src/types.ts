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
  /** Firmware sensor status (0 ok); non-zero is never a valid level.
   * null for profiles that report none. */
  sensor_status?: number | null;
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
  /** One entry per open alert kind and subject (a logger level alarm names
   * high/low), so attention items can name the alert. */
  open_alert_kinds?: OpenAlertKind[];
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
  /** The logger's latest `health` JSON with "not read" values (65535 mV,
   * CSQ 99, free space of a card that is not ok) as null. */
  health?: Record<string, unknown> | null;
  health_at?: string | null;
  settings_gen?: number | null;
  settings?: Record<string, unknown> | null;
  settings_at?: string | null;
  open_gap_count?: number;
  pending_challenge_count?: number;
  // Operations additions (README "Operations API").
  project?: string;
  notes?: string;
  enrolled_at?: string | null;
  revoked_at?: string | null;
  mqtt_auth?: "shared" | "dual" | "device";
  /** Level alarm hysteresis (null = server default 0.5 m for revision 1). */
  min_hysteresis?: number | null;
  max_hysteresis?: number | null;
  /** Settings-lost RECOVERY: when the logger first reported it (null when
   * it has settings). */
  settings_lost_since?: string | null;
  /** Fallback mode: the effective settings are held in RAM only
   * (`"persist":false`) and are lost at the logger's next reset. */
  settings_ram_only?: boolean;
  /** The episode's automatic restore command, null when none was sent. */
  settings_restore?: SettingsRestore | null;
}
export interface OpenAlertKind {
  kind: string;
  subject: string | null;
}
export interface SettingsRestore {
  id: number;
  state: string;
  final_status: string | null;
  status_reason: string | null;
  created_at: string;
  expires_at: string | null;
  acked_at: string | null;
}
export interface SeriesPoint {
  recorded_at: string;
  gwl: number;
  gwl_text: string | null;
  battery_v: number | null;
  rssi: number | null;
  sample_count: number;
  conflict: boolean;
  solar_v?: number | null;
  csq?: number | null;
  /** Raw level when `gwl` holds a datum-converted value. */
  raw_gwl?: number | null;
  /** Raw point: the reading's status (non-zero: `gwl` is the firmware's
   * untrustworthy level, never a level). Always null on a bucket. */
  sensor_status?: number | null;
  /** Fault samples behind the point (left out of the bucket average). */
  fault_count?: number;
  fault_kinds?: string[];
}
/** A raw fault reading, or a bucket that held fault samples (buckets with
 * only faults and readings without a level have no point). */
export interface SeriesFault {
  recorded_at: string;
  sensor_status: number | null;
  fault_count: number;
  fault_kinds: string[];
  /** Valid samples in the same bucket (0 for a raw fault). */
  valid_count: number;
}
export interface Series {
  device_id: string;
  points: SeriesPoint[];
  min_gwl: number | null;
  max_gwl: number | null;
  bucket_minutes: number;
  truncated: boolean;
  datum?: string;
  inverted?: boolean;
  unconverted?: number;
  limits?: { min: number | null; max: number | null } | null;
  faults?: SeriesFault[];
  faults_truncated?: boolean;
}
export interface Alert {
  id: number;
  device_id: string;
  kind: string;
  state: string;
  trigger_value: number;
  opened_at: string;
  resolved_at: string | null;
  display_name?: string;
  severity?: "info" | "warning" | "critical";
  acknowledged_at?: string | null;
  acknowledged_by?: string | null;
  ack_note?: string | null;
  resolved_by?: string | null;
  resolve_note?: string | null;
  detail?: Record<string, unknown> | null;
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
  replace_settings?: boolean;
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
  /** Impact/orientation records: the accelerometer reading written at the
   * alarm (the next ring record, Type 2 without a fix). */
  attitude?: {
    position_id: number;
    seq: number;
    accel_x_mg: number | null;
    accel_y_mg: number | null;
    accel_z_mg: number | null;
    accel_status: number | null;
  } | null;
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
  next_offset?: number;
  current_command_id?: number | null;
  requested_by?: string;
  crc32: string | null;
  error: string | null;
  created_at: string;
  updated_at?: string;
  completed_at: string | null;
}
export interface FileListing {
  path: string;
  page: number;
  files: [string, number][];
  more: boolean;
  command_id: number | null;
  received_at: string;
}
interface Timed {
  id: number;
  log_id?: number | null;
  seq?: number | null;
  recorded_at: string | null;
  time_valid?: boolean | null;
  time_rel_s?: number | null;
  time_source?: string | null;
  received_at: string;
  settings_gen?: number | null;
}
export interface Position extends Timed {
  source: string;
  reason: number | null;
  fix: number | null;
  lat: number | null;
  lon: number | null;
  alt_m: number | null;
  hdop: number | null;
  satellites: number | null;
  accel_x_mg?: number | null;
  accel_y_mg?: number | null;
  accel_z_mg?: number | null;
  accel_status?: number | null;
  /** `impact`/`orientation`: an accelerometer-only record written at that
   * alarm (reason 2, no GPS search), not a failed fix. */
  alarm_event?: string | null;
}
export interface TiltSample extends Timed {
  reason: number | null;
  pitch_deg: number | null;
  roll_deg: number | null;
  accel_x_mg: number | null;
  accel_y_mg: number | null;
  accel_z_mg: number | null;
  accel_status: number | null;
}
export interface TestResult extends Timed {
  source: string;
  trigger: string | null;
  command_id: number | null;
  battery_mv: number | null;
  solar_mv: number | null;
  csq: number | null;
  sensor_mv: number | null;
  sensor_ma: number | null;
  level: number | null;
  sensor_status: number | null;
  status_bits: number | null;
  ok: boolean | null;
  details: Record<string, unknown>;
  /** "record" (Type 5 ring record), "json" (test/result) or both. */
  sources?: string[];
  json_id?: number | null;
  json_ok?: boolean | null;
}
export interface SettingsHistoryRow {
  id: number;
  settings_gen: number | null;
  source: string;
  settings: Record<string, unknown>;
  activated: boolean;
  command_id: number | null;
  log_id: number | null;
  seq: number | null;
  received_at: string;
  warnings: string[];
}
export interface SettingsResponse {
  effective: {
    settings_gen: number | null;
    settings: Record<string, unknown> | null;
    settings_at: string | null;
    defaults: Record<string, unknown>;
  };
  history: SettingsHistoryRow[];
}
export interface StreamLog {
  log_id: number;
  log_hex: string;
  payload_schema: number | null;
  start_reason: string | null;
  started_at: string | null;
  firmware_version: string | null;
  first_received_at?: string;
  last_received_at?: string;
  frames: number;
  min_seq: number | null;
  max_seq: number | null;
  decode_errors: number;
  conflicting_copies: number;
  resent_copies: number;
  open_gaps: number;
  unrecoverable_gaps: number;
  pending_readings: number;
  pending_reasons?: PendingReason[];
  /** Frames whose derived data failed and is re-run at the next start. */
  derive_pending?: number;
  /** Frames of a payload schema this server has no decoder for (kept raw). */
  undecodable?: number;
  decoder_available?: boolean | null;
  /** Time resolution and settings assembly for the log failed. */
  resolve_pending?: boolean;
  resolve_error?: string | null;
}
/** Readings of a log that have no time yet, grouped by why. */
export interface PendingReason {
  reason: string;
  state:
    | "awaiting_anchor"
    | "gap_unrecoverable"
    | "awaiting_clock_set"
    | "no_time";
  count: number;
  min_seq: number | null;
  max_seq: number | null;
}
export interface StreamBatch {
  id: number;
  received_at: string;
  channel: string;
  encoding: string;
  size: number;
  ok: boolean;
  error: string | null;
  log_id: number | null;
  first_seq: number | null;
  last_seq: number | null;
  frame_count: number | null;
  resend: boolean;
  gap_before: boolean;
  from_sd: boolean;
  frames_valid: number;
  frames_new: number;
  frames_duplicate: number;
  issues: unknown[];
  warnings: unknown[];
  raw_retained: boolean;
  /** Derived data (readings, events, times) failed when this batch was
   * stored; the raw frames were kept. */
  derive_error?: string | null;
  /** Frames first stored by this batch still waiting to be re-derived. */
  frames_derive_pending?: number;
}
export interface GapReportRow {
  device_id: string;
  display_name: string;
  protocol_rev: number | null;
  logs: number;
  frames: number;
  open: number;
  requested: number;
  unrecoverable: number;
  filled: number;
  missing_open: number;
  missing_unrecoverable: number;
  oldest_open_at: string | null;
  last_gap_at: string | null;
  data_gap_events: number;
  last_stream_at: string | null;
}
export type PolicyValues = {
  battery_low_mv: number | null;
  battery_hys_mv: number | null;
  solar_low_mv: number | null;
  solar_samples: number | null;
  stale_enabled: boolean | null;
  stale_margin_min: number | null;
};
export interface AlertPolicy extends PolicyValues {
  scope: "fleet" | "project" | "device";
  target: string | null;
  updated_by?: string | null;
  updated_at?: string | null;
}
export interface DevicePolicy {
  effective: PolicyValues;
  sources: Record<string, string>;
  levels: {
    device: PolicyValues | null;
    project: PolicyValues | null;
    fleet: PolicyValues | null;
  };
  project: string;
  defaults: PolicyValues;
}
export interface NotificationRule {
  kind: string;
  label: string;
  source: string;
  severities: string[];
  enabled: boolean;
  min_severity: string;
  priority: number;
  cooldown_min: number;
  notify_resolved: boolean;
  topic: string | null;
  updated_by: string | null;
  updated_at: string | null;
}
export interface NotificationDelivery {
  configured: boolean;
  server: string | null;
  topic: string | null;
  public_url: string | null;
  max_per_hour: number;
}
export interface NotificationRow {
  id: number;
  device_id: string;
  display_name: string;
  kind: string;
  severity: string;
  transition: string;
  title: string;
  message: string;
  state: string;
  reason: string | null;
  attempts: number;
  alert_id: number | null;
  event_id: number | null;
  suppressed_count: number;
  created_at: string;
  sent_at: string | null;
}
export interface Permission {
  username: string;
  granted_at: string | null;
  granted_by: string | null;
}
export interface AuditRow {
  id: number;
  device_id: string | null;
  actor: string;
  action: string;
  detail: unknown;
  created_at: string;
}
export interface BindingRow {
  binding_key: string;
  topic: string;
  source_profile: string;
  established_at: string;
  revoked_at: string | null;
}
export interface MqttCredentials {
  available: boolean;
  mode: "shared" | "dual" | "device";
  username: string;
  created_at: string | null;
  created_by: string | null;
  rotated_at: string | null;
  mode_changed_at: string | null;
  published_at: string | null;
}
export interface Datum {
  id: number;
  effective_from: string;
  sensor_depth_m: number;
  casing_height_m: number;
  ground_elevation_m: number | null;
  note: string;
  created_by: string;
  created_at: string;
}
export interface Delivery {
  id: number;
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
  ingest: {
    /** Newest stored inbound delivery (operators only; null otherwise). */
    lastDeliveryAt?: string | null;
    [key: string]: unknown;
  };
}
