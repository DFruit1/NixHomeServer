import type { FirmwareConfig } from "./config";
export interface Observation {
  recorded_at: string | null;
  received_at: string;
  gwl: number;
  gwl_text: string;
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
  };
  open_alert_count: number;
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
