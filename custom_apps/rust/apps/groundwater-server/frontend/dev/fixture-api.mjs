// Development-only HTTP fixtures for UI review. Never imported by src or the
// production build. Node is used here to exercise the frontend's pinned toolchain.
// Shapes follow frontend/README.md ("Protocol revision 2" and "Operations API").
import { createServer } from "node:http";

const V21 = ["8F3A21C04B9E77A1D25C01FE", "A13A21C04B9E77A1D25C01AB"];
const V22 = "6A1B2C3D4E5F60718293A4B5";
let role = "operator",
  mode = "normal",
  commands = [],
  nextId = 100;
const now = () => new Date().toISOString();
const ago = (ms) => new Date(Date.now() - ms).toISOString();
const ahead = (ms) => new Date(Date.now() + ms).toISOString();
const HOUR = 3600000,
  DAY = 86400000;
const id = () => nextId++;
const audit = [];
const log = (device_id, action, detail = null) =>
  audit.unshift({
    id: id(),
    device_id,
    actor: "fixture-user",
    action,
    detail,
    created_at: now(),
  });

const observation = (rev2) => ({
  recorded_at: ago(3 * 60000),
  received_at: now(),
  gwl: rev2 ? 12.345 : 4.23,
  gwl_text: rev2 ? "12.345" : "04.23",
  battery_v: rev2 ? 7.41 : 3.72,
  rssi: rev2 ? null : 68,
  solar_v: rev2 ? 5.12 : 3,
  time_quality: "plausible",
  time_reason: rev2
    ? "anchor at seq 412 + 3 x 900 s"
    : "Device-local timestamp normalized with enrollment offset.",
  quality_reasons: [],
  duplicate_outcome: "first",
  interpretation_version: rev2 ? "gw-adapter/2+v22" : "v21-1",
});

const rev2Settings = {
  read_s: 900,
  send_s: 86400,
  gps_mode: 1,
  gps_val: 7,
  tilt_mode: 0,
  tilt_val: 0,
  start: 0,
  fac: [0, 1, 1, 0],
  tap: 1,
  tap_sens: 5,
  gps_sens: 5,
  lo: 2,
  hi: 15,
  lo_hys: 0.2,
  hi_hys: 0.2,
  loc: "Bore 7",
  proj: "North",
  text: "",
  partial: 0,
  utc_off: 600,
  led: 0,
  attempts: 3,
  listen_s: 60,
};

const devices = new Map();
const baseDevice = (deviceId) => {
  const rev2 = deviceId === V22;
  return {
    device_id: deviceId,
    display_name: rev2
      ? "Bore 7 · North paddock"
      : deviceId === V21[0]
        ? "North bore · Upper field"
        : "South bore · Long location name for responsive review",
    profile: rev2 ? "V22" : "V21",
    clock_policy: rev2 ? "utc" : "local-offset",
    revoked: false,
    revoked_at: null,
    enrolled_at: ago(40 * DAY),
    status: rev2 ? "asleep" : deviceId === V21[0] ? "awake" : "asleep",
    status_reason: rev2
      ? `sleeping; next connection expected ${ahead(20 * HOUR)} (announced next connection)`
      : "Attributed device-status message",
    last_received_at: rev2 ? ago(4 * HOUR) : now(),
    observation_count: 1200,
    conflict_count: 2,
    latest_received: observation(rev2),
    latest_plausible: observation(rev2),
    min_limit: rev2 ? 2 : 2,
    max_limit: rev2 ? 15 : 5,
    min_hysteresis: rev2 ? 0.2 : null,
    max_hysteresis: rev2 ? 0.2 : null,
    location_id: rev2 ? "N7" : "A1",
    sensor_id: rev2 ? "S-12" : "B1",
    project: rev2 ? "North" : "",
    notes: rev2 ? "Casing measured 2026-10-02." : "",
    mqtt_auth: rev2 ? "dual" : "shared",
    local_offset_min: rev2 ? null : 300,
    last_ready_at: ago(60000),
    project_config: rev2 ? null : { l: "A1", lf: "0:3", ltost: "5:0" },
    clock_change_unverified: false,
    capabilities: rev2
      ? {
          test: false,
          project_settings: false,
          cfg_keys: [],
          danger_commands: [],
          protocol: 2,
          settings: true,
          basic_ops: [
            "self_test",
            "get_status",
            "get_settings",
            "get_debug",
            "flush_mqtt",
            "flush_sd",
            "file_list",
            "file_chunk",
            "clear_error_latch",
            "enable_logging",
            "sync_time",
          ],
          danger_ops: [
            "reboot",
            "wipe_sd",
            "wipe_mram",
            "factory_reset",
            "recover_mram",
            "disable_logging",
            "erase_keys",
            "rotate_keys",
            "enter_bootloader",
            "firmware_update",
          ],
          handshake_ops: [
            "wipe_sd",
            "wipe_mram",
            "factory_reset",
            "recover_mram",
            "disable_logging",
            "erase_keys",
            "rotate_keys",
            "enter_bootloader",
            "firmware_update",
          ],
          unsupported_by_firmware: [
            "erase_keys",
            "rotate_keys",
            "firmware_update",
          ],
          downloads: true,
        }
      : {
          test: true,
          project_settings: true,
          cfg_keys: [],
          danger_commands: ["Reboot"],
          protocol: 1,
        },
    desired_config: rev2 ? null : { Flush_mqtt: "1" },
    applied_config: rev2 ? null : { Flush_mqtt: "0" },
    open_alert_count: 1,
    ...(rev2
      ? {
          protocol_rev: 2,
          link_state: "sleep",
          link_state_at: ago(4 * HOUR),
          link_reason: null,
          link_retained: true,
          next_contact_at: ahead(20 * HOUR),
          expected_contact_at: ahead(20 * HOUR),
          stale_after: ahead(20.5 * HOUR),
          listen_window_s: 60,
          boot_count: 17,
          info: {
            v: 2,
            fw: "2.2.0",
            build: "Nov 16 2026",
            hw: "V1.08",
            proto: 2,
            schema: 1,
            uid: "0032001F3436511637383438",
            imei: "864292046589220",
            iccid: "8961012345678901234",
            modem: "EC21EFAR06A07M4G",
            net: "bench",
            stream: "bin",
            reset: "wdg",
          },
          info_at: ago(3 * DAY),
          health: {
            v: 2,
            t: Math.floor(Date.now() / 1000) - 4 * 3600,
            tv: 1,
            up: 5120,
            csq: 21,
            bat_mv: 7412,
            sol_mv: 5120,
            sd: "ok",
            sd_free_mb: 7400,
            mram: "ok",
            unsaved: 1234,
            usable: 122368,
            log: "on",
            gen: 5,
            next: Math.floor(Date.now() / 1000) + 20 * 3600,
            err: 0,
          },
          health_at: ago(4 * HOUR),
          settings_gen: 5,
          settings: { ...rev2Settings },
          settings_at: ago(2 * DAY),
          open_gap_count: 1,
          pending_challenge_count: 0,
        }
      : {}),
  };
};
for (const deviceId of [V22, ...V21])
  devices.set(deviceId, baseDevice(deviceId));

const deviceView = (d) => ({
  ...d,
  pending_challenge_count: commands.filter(
    (c) => c.device_id === d.device_id && c.state === "challenge",
  ).length,
});

let alerts = [
  {
    id: 1,
    device_id: V21[0],
    kind: "above_max",
    severity: "warning",
    state: "open",
    trigger_value: 5.6,
    opened_at: ago(2 * HOUR),
    resolved_at: null,
  },
  {
    id: 2,
    device_id: V21[0],
    kind: "below_min",
    severity: "warning",
    state: "resolved",
    trigger_value: 1.2,
    opened_at: ago(10 * HOUR),
    resolved_at: ago(8.3 * HOUR),
  },
  {
    id: 3,
    device_id: V22,
    kind: "battery_low",
    severity: "warning",
    state: "open",
    trigger_value: 6.91,
    opened_at: ago(5 * HOUR),
    resolved_at: null,
    acknowledged_at: ago(4 * HOUR),
    acknowledged_by: "fixture-user",
    ack_note: "Battery swap booked for Thursday",
  },
  {
    id: 4,
    device_id: V22,
    kind: "stale",
    severity: "warning",
    state: "resolved",
    trigger_value: 1.5,
    opened_at: ago(6 * DAY),
    resolved_at: ago(5.9 * DAY),
    detail: { margin_min: 30 },
  },
].map((a) => ({
  acknowledged_at: null,
  acknowledged_by: null,
  ack_note: null,
  resolved_by: null,
  resolve_note: null,
  detail: {},
  ...a,
}));

const health = Array.from({ length: 30 }, (_, i) => ({
  id: 30 - i,
  source: i % 7 === 3 ? "get_status" : "health",
  recorded_at: ago(i * 6 * HOUR + 4 * HOUR),
  time_source: "device",
  time_valid: true,
  received_at: ago(i * 6 * HOUR + 4 * HOUR - 2000),
  uptime_s: 5120 + i,
  csq: i === 5 ? 99 : 18 + (i % 6),
  bat_mv: 7412 - i * 12,
  sol_mv: i % 4 === 0 ? 300 : 5120 - i * 30,
  sd: i === 8 ? "error" : "ok",
  sd_free_mb: 7400 - i,
  mram: "ok",
  unsaved: 1234 + i * 1500,
  usable: 122368,
  log: "on",
  settings_gen: i > 20 ? 4 : 5,
  next_contact_at: ahead(20 * HOUR - i * 6 * HOUR),
  err: 0,
}));

const deviceEvents = [
  [
    "alert",
    "gwl_alarm_enter",
    { limit: "high", state: "enter", lvl: 15.2, thr: 15 },
    2,
    431,
  ],
  [
    "record",
    "gwl_alarm_enter",
    {
      limit: "high",
      state: "enter",
      level: 15.2,
      threshold: 15,
      settings_gen: 5,
      type_name: "gwl_alarm_enter",
    },
    2.01,
    431,
  ],
  ["record", "impact", { peak_mg: 2310 }, 26, 402],
  ["alert", "orientation", { tilt_deg: 12.3 }, 27, 401],
  ["record", "gps_moved", { dist_m: 41, thr_m: 25 }, 50, 380],
  [
    "record",
    "data_gap",
    {
      gap_end: 377,
      missed_readings: 12,
      missed_events: 0,
      reason: "power-loss-or-reset",
    },
    51,
    378,
  ],
  [
    "record",
    "sensor_fault",
    {
      state: "exit",
      sensor_status: 0,
      sensor_status_name: "ok",
      sensor_mv: 1234,
    },
    70,
    360,
  ],
  [
    "record",
    "power_critical",
    { state: "enter", kind: "battery-critical", bat_mv: 6550, sol_mv: 200 },
    90,
    340,
  ],
  [
    "record",
    "storage_warning",
    { kind: "sd_full", unsaved: 4096, usable: 122368 },
    120,
    300,
  ],
  [
    "record",
    "tail_lock",
    { head: 1, tail: 2, reason: "ring-full-unsaved" },
    121,
    299,
  ],
  [
    "record",
    "clock_set",
    {
      old_time: 5120,
      old_valid: false,
      new_time: 1763300000,
      new_valid: true,
      new_source: "gnss",
      uptime_s: 5120,
    },
    150,
    250,
  ],
  [
    "server",
    "gap_requested",
    { log_id: 1761000001, from_seq: 7, to_seq: 8, command_id: 55 },
    3,
    null,
  ],
  [
    "server",
    "challenge_held",
    { command_id: 77, unsaved_frames: 12 },
    30,
    null,
  ],
].map(([source, event, details, hours, seq], i) => ({
  id: i + 1,
  source,
  event,
  log_id: source === "server" ? null : 1761000001,
  seq,
  record_type: null,
  recorded_at: event === "clock_set" && false ? null : ago(hours * HOUR),
  time_valid: true,
  time_rel_s: null,
  time_source: source === "server" ? null : "rtc",
  received_at: ago(hours * HOUR - 60000),
  details,
  confirmed_by_record: source === "alert" ? event === "gwl_alarm_enter" : null,
}));
deviceEvents.push({
  ...deviceEvents[2],
  id: 99,
  event: "impact",
  recorded_at: null,
  time_valid: false,
  time_rel_s: 734,
  time_source: null,
  details: { peak_mg: 900 },
});

const positions = Array.from({ length: 8 }, (_, i) => ({
  id: 20 - i,
  source: i === 7 ? "json" : "record",
  log_id: 1761000001,
  seq: 420 - i * 10,
  recorded_at: ago(i * DAY + HOUR),
  time_valid: true,
  time_rel_s: null,
  time_source: "gnss",
  received_at: ago(i * DAY),
  settings_gen: 5,
  reason: 1,
  fix: i === 4 ? 2 : 3,
  lat: -33.8688197 + (i === 2 ? 0.00037 : i * 0.000004),
  lon: 151.2092955 + (i === 2 ? 0.00012 : -i * 0.000003),
  alt_m: 12 + i,
  hdop: 1.1 + i / 10,
  satellites: 8 - (i % 3),
  accel_x_mg: 15,
  accel_y_mg: -20,
  accel_z_mg: 1002,
  accel_status: 0,
}));
const tilt = Array.from({ length: 12 }, (_, i) => ({
  id: 40 - i,
  log_id: 1761000001,
  seq: 421 - i * 9,
  recorded_at: ago(i * DAY + 2 * HOUR),
  time_valid: true,
  time_rel_s: null,
  time_source: "rtc",
  received_at: ago(i * DAY),
  settings_gen: 5,
  reason: 1,
  accel_x_mg: 15 + i,
  accel_y_mg: -20,
  accel_z_mg: 1002,
  pitch_deg: 1.2 + (i === 3 ? 10 : i / 10),
  roll_deg: -3.4 + i / 20,
  accel_status: 0,
}));
const tests = [
  {
    id: 3,
    source: "json",
    trigger: "remote",
    command_id: 42,
    recorded_at: ago(DAY),
    received_at: ago(DAY),
    battery_mv: 7412,
    solar_mv: 5120,
    csq: 21,
    sensor_mv: 1234,
    sensor_ma: 8.23,
    level: 12.345,
    sensor_status: 0,
    status_bits: 1023,
    ok: true,
    details: {
      sd: "ok",
      sim: "ok",
      net: "ok",
      mqtt: "ok",
      gps: "fix",
      epd: "ok",
      acc: "ok",
      mram: "ok",
      warn: [],
    },
  },
  {
    id: 2,
    source: "record",
    trigger: "button",
    command_id: null,
    recorded_at: ago(9 * DAY),
    received_at: ago(8 * DAY),
    battery_mv: 6950,
    solar_mv: 120,
    csq: 9,
    sensor_mv: null,
    sensor_ma: null,
    level: null,
    sensor_status: 1,
    status_bits: 0b1111111110,
    ok: false,
    details: {
      status_flags: ["sd", "sim"],
      warn: ["Low battery", "No sensor"],
    },
  },
];
let settingsHistory = [
  {
    id: 4,
    settings_gen: 5,
    source: "ack",
    settings: { ...rev2Settings },
    activated: true,
    command_id: 61,
    log_id: null,
    seq: null,
    received_at: ago(2 * DAY),
    warnings: [],
  },
  {
    id: 3,
    settings_gen: 4,
    source: "snapshot",
    settings: {
      ...rev2Settings,
      read_s: 3600,
      hi: 14,
      gps_mode: 0,
      gps_val: 0,
    },
    activated: true,
    command_id: null,
    log_id: 1761000001,
    seq: 12,
    received_at: ago(20 * DAY),
    warnings: [],
  },
  {
    id: 1,
    settings_gen: 1,
    source: "snapshot",
    settings: {
      ...rev2Settings,
      read_s: 3600,
      send_s: 604800,
      hi: null,
      lo: null,
      loc: "",
    },
    activated: true,
    command_id: null,
    log_id: 1761000001,
    seq: 2,
    received_at: ago(39 * DAY),
    warnings: [],
  },
];
const logs = [
  {
    log_id: 1761000001,
    log_hex: "68F6A0E1",
    payload_schema: 1,
    start_reason: "blank-mram-formatted",
    started_at: ago(39 * DAY),
    firmware_version: "2.2.0",
    first_received_at: ago(39 * DAY),
    last_received_at: ago(4 * HOUR),
    frames: 412,
    min_seq: 1,
    max_seq: 431,
    decode_errors: 0,
    conflicting_copies: 0,
    resent_copies: 3,
    open_gaps: 1,
    unrecoverable_gaps: 1,
    pending_readings: 0,
  },
];
let gaps = [
  {
    id: 1,
    log_id: 1761000001,
    from_seq: 425,
    to_seq: 428,
    from_pos: null,
    to_pos: null,
    state: "requested",
    attempts: 1,
    last_requested_at: ago(3 * HOUR),
    command_id: 55,
    detected_at: ago(4 * HOUR),
    resolved_at: null,
  },
  {
    id: 2,
    log_id: 1761000001,
    from_seq: 7,
    to_seq: 8,
    state: "filled",
    attempts: 1,
    command_id: 12,
    detected_at: ago(30 * DAY),
    resolved_at: ago(29 * DAY),
  },
  {
    id: 3,
    log_id: 1761000001,
    from_seq: 101,
    to_seq: 140,
    state: "unrecoverable",
    attempts: 3,
    command_id: 33,
    detected_at: ago(20 * DAY),
    resolved_at: ago(18 * DAY),
  },
];
const batches = Array.from({ length: 6 }, (_, i) => ({
  id: 60 - i,
  received_at: ago(i * DAY + 4 * HOUR),
  channel: i === 2 ? "data/file" : "data/stream",
  encoding: i === 4 ? "hex" : "bin",
  size: 230 + i * 100,
  ok: i !== 3,
  error: i === 3 ? "crc: batch CRC-32 mismatch" : null,
  log_id: 1761000001,
  first_seq: 425 - i * 6,
  last_seq: 430 - i * 6,
  frame_count: 6,
  resend: i === 1,
  gap_before: i === 0,
  from_sd: false,
  frames_valid: 6,
  frames_new: i === 1 ? 2 : 6,
  frames_duplicate: i === 1 ? 4 : 0,
  issues: i === 3 ? [{ at: 12, issue: "crc8" }] : [],
  warnings: [],
  raw_retained: i < 4,
}));
let listings = [
  {
    path: "/GWL",
    page: 0,
    files: [
      ["68F6A0E1/", 0],
      ["EXPORT.DAT", 12],
      ["SETTINGS.BIN", 96],
    ],
    more: false,
    command_id: 61,
    received_at: ago(DAY),
  },
  {
    path: "/GWL/68F6A0E1",
    page: 0,
    files: [
      ["B0000001.BIN", 123456],
      ["B0000002.BIN", 98304],
    ],
    more: true,
    command_id: 62,
    received_at: ago(DAY),
  },
];
let downloads = [
  {
    id: 4,
    path: "/GWL/68F6A0E1/B0000001.BIN",
    requested_by: "fixture-user",
    state: "active",
    size: 123456,
    received_bytes: 40960,
    next_offset: 40960,
    current_command_id: 77,
    crc32: null,
    error: null,
    created_at: ago(HOUR),
    updated_at: ago(60000),
    completed_at: null,
  },
  {
    id: 3,
    path: "/GWL/EXPORT.DAT",
    requested_by: "fixture-user",
    state: "complete",
    size: 12,
    received_bytes: 12,
    next_offset: 12,
    current_command_id: null,
    crc32: "1A2B3C4D",
    error: null,
    created_at: ago(2 * DAY),
    updated_at: ago(2 * DAY),
    completed_at: ago(2 * DAY),
  },
];
let policies = [
  {
    scope: "fleet",
    target: null,
    battery_low_mv: null,
    battery_hys_mv: null,
    solar_low_mv: 900,
    solar_samples: null,
    stale_enabled: true,
    stale_margin_min: 45,
    updated_by: "fixture-user",
    updated_at: ago(DAY),
  },
  {
    scope: "project",
    target: "North",
    battery_low_mv: 6900,
    battery_hys_mv: null,
    solar_low_mv: null,
    solar_samples: null,
    stale_enabled: null,
    stale_margin_min: null,
    updated_by: "fixture-user",
    updated_at: ago(DAY),
  },
];
const DEFAULTS = {
  battery_low_mv: 7000,
  battery_hys_mv: 200,
  solar_low_mv: 1000,
  solar_samples: 3,
  stale_enabled: true,
  stale_margin_min: 30,
};
const RULES = [
  ["above_max", "Level above high limit", "alert", ["warning"]],
  ["below_min", "Level below low limit", "alert", ["warning"]],
  ["battery_low", "Battery low", "alert", ["warning"]],
  ["solar_low", "Solar low", "alert", ["info"]],
  ["stale", "Missed connection", "alert", ["warning"]],
  ["gwl_alarm", "Logger level alarm", "event", ["warning", "info"]],
  ["power_critical", "Power critical", "event", ["critical", "info"]],
  ["sensor_fault", "Sensor fault", "event", ["warning", "info"]],
  ["storage", "Storage", "event", ["critical", "warning", "info"]],
  ["tamper", "Impact / orientation / moved", "event", ["warning"]],
];
let rules = RULES.map(([kind, label, source, severities]) => ({
  kind,
  label,
  source,
  severities,
  enabled: kind !== "solar_low",
  min_severity: "warning",
  priority: kind === "power_critical" ? 5 : 4,
  cooldown_min: 60,
  notify_resolved: true,
  topic: null,
  updated_by: null,
  updated_at: null,
}));
const notifications = [
  {
    id: 3,
    device_id: V22,
    display_name: "Bore 7 · North paddock",
    kind: "battery_low",
    severity: "warning",
    transition: "open",
    title: "Battery low: Bore 7",
    message: "6.91 V below 7.00 V · N7 · North",
    state: "sent",
    reason: null,
    attempts: 1,
    alert_id: 3,
    event_id: null,
    suppressed_count: 0,
    created_at: ago(5 * HOUR),
    sent_at: ago(5 * HOUR),
  },
  {
    id: 2,
    device_id: V22,
    display_name: "Bore 7 · North paddock",
    kind: "tamper",
    severity: "warning",
    transition: "event",
    title: "Impact: Bore 7",
    message: "Impact peak 2310 mg",
    state: "suppressed",
    reason: "cooldown",
    attempts: 0,
    alert_id: null,
    event_id: 3,
    suppressed_count: 0,
    created_at: ago(26 * HOUR),
    sent_at: null,
  },
  {
    id: 1,
    device_id: V21[0],
    display_name: "North bore · Upper field",
    kind: "above_max",
    severity: "warning",
    transition: "open",
    title: "Level above high limit",
    message: "5.60 m above 5.00 m",
    state: "failed",
    reason: null,
    attempts: 5,
    alert_id: 1,
    event_id: null,
    suppressed_count: 2,
    created_at: ago(2 * HOUR),
    sent_at: null,
  },
];
const permissions = new Map([
  [
    V22,
    [
      {
        username: "alice",
        granted_at: ago(30 * DAY),
        granted_by: "fixture-user",
      },
    ],
  ],
]);
const datums = new Map([
  [
    V22,
    [
      {
        id: 1,
        effective_from: ago(39 * DAY),
        sensor_depth_m: 42,
        casing_height_m: 0.6,
        ground_elevation_m: 21.3,
        note: "Installed",
        created_by: "fixture-user",
        created_at: ago(39 * DAY),
      },
    ],
  ],
]);
const credentials = new Map([
  [
    V22,
    {
      mode: "dual",
      created_at: ago(3 * DAY),
      created_by: "fixture-user",
      rotated_at: null,
      mode_changed_at: ago(3 * DAY),
      published_at: ago(3 * DAY),
    },
  ],
]);
const CHANNELS = [
  "status",
  "info",
  "health",
  "data/stream",
  "data/file",
  "alerts",
  "test/result",
  "reading",
  "gps",
  "config/applied",
  "cmd/ack",
  "config/set",
  "cmd/basic",
  "cmd/danger",
  "storage",
  "motion",
  "config/desired",
  "cmd/test",
];

const command = (deviceId, extra) => ({
  id: id(),
  device_id: deviceId,
  kind: "basic",
  payload: {},
  state: "queued",
  requested_by: "fixture-user",
  created_at: now(),
  sent_at: null,
  acked_at: null,
  ack_payload: null,
  attempts: 0,
  firmware_ack_expected: true,
  supported: true,
  protocol: 2,
  op: null,
  args: {},
  expires_at: ahead(7 * DAY),
  publish_count: 0,
  last_published_at: null,
  final_status: null,
  status_reason: null,
  hold_until_sleep: false,
  parent_id: null,
  preconfirmed: false,
  challenge: null,
  challenge_expires_at: null,
  origin: "operator",
  download_id: null,
  ...extra,
});
commands.push(
  command(V22, {
    id: 61,
    op: "get_settings",
    state: "acked",
    final_status: "ok",
    sent_at: ago(2 * DAY),
    acked_at: ago(2 * DAY),
    publish_count: 1,
    last_published_at: ago(2 * DAY),
    origin: "auto-settings",
    ack_payload: { v: 2, id: 61, op: "get_settings", status: "ok" },
  }),
  command(V22, {
    id: 55,
    op: "flush_mqtt",
    args: { log_id: 1761000001, from_seq: 425, to_seq: 428 },
    state: "sent",
    sent_at: ago(3 * HOUR),
    publish_count: 2,
    last_published_at: ago(3 * HOUR),
    origin: "auto-gap",
  }),
  command(V22, {
    id: 50,
    kind: "danger",
    op: "disable_logging",
    state: "acked",
    final_status: "rejected",
    status_reason: "locked",
    acked_at: ago(5 * DAY),
    publish_count: 1,
  }),
);

const json = (res, body, code = 200) => {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};
const readBody = async (req) => {
  let text = "";
  for await (const chunk of req) text += chunk;
  return text ? JSON.parse(text) : {};
};

function series(url, deviceId) {
  const from = Date.parse(url.searchParams.get("from")),
    to = Date.parse(url.searchParams.get("to"));
  const datum = url.searchParams.get("datum") || "raw";
  const rev2 = deviceId === V22;
  const points =
    mode === "empty"
      ? []
      : Array.from({ length: 96 }, (_, i) => {
          const raw = rev2 ? 12 + Math.sin(i / 10) : 3.7 + Math.sin(i / 10);
          const value =
            datum === "dtw_bgl"
              ? 42 - 0.6 - raw
              : datum === "rl_ahd"
                ? 21.3 - (42 - 0.6 - raw)
                : raw;
          return {
            recorded_at: new Date(from + ((to - from) * i) / 95).toISOString(),
            gwl: value,
            raw_gwl: datum === "raw" ? null : raw,
            gwl_text: null,
            battery_v: rev2 ? 7.4 - i / 1000 : 3.6 + i / 1000,
            solar_v: Math.max(0, 5 * Math.sin(i / 8)),
            rssi: rev2 ? null : 65 + Math.sin(i / 4) * 10,
            csq: rev2 ? 18 + Math.round(Math.sin(i / 5) * 3) : null,
            sample_count: 5,
            conflict: i === 10,
          };
        }).filter((_, i) => i < 40 || i > 48);
  const d = devices.get(deviceId);
  const convert = (v) =>
    v == null
      ? null
      : datum === "dtw_bgl"
        ? 42 - 0.6 - v
        : datum === "rl_ahd"
          ? 21.3 - (42 - 0.6 - v)
          : v;
  const limits =
    datum === "raw"
      ? null
      : [convert(d.min_limit), convert(d.max_limit)].sort((a, b) => a - b);
  return {
    device_id: deviceId,
    points,
    min_gwl: 2.7,
    max_gwl: 4.7,
    bucket_minutes: Number(url.searchParams.get("bucket")),
    truncated: false,
    ...(datum === "raw"
      ? {}
      : {
          datum,
          inverted: datum === "dtw_bgl",
          unconverted: 3,
          limits: limits && { min: limits[0], max: limits[1] },
        }),
  };
}

const gapRow = (d) => {
  const rev2 = d.device_id === V22;
  return {
    device_id: d.device_id,
    display_name: d.display_name,
    protocol_rev: rev2 ? 2 : null,
    logs: rev2 ? 1 : 0,
    frames: rev2 ? 412 : 0,
    open: 0,
    requested: rev2 ? 1 : 0,
    unrecoverable: rev2 ? 1 : 0,
    filled: rev2 ? 1 : 0,
    missing_open: rev2 ? 4 : 0,
    missing_unrecoverable: rev2 ? 40 : 0,
    oldest_open_at: rev2 ? ago(4 * HOUR) : null,
    last_gap_at: rev2 ? ago(4 * HOUR) : null,
    data_gap_events: rev2 ? 1 : 0,
    last_stream_at: rev2 ? ago(4 * HOUR) : null,
  };
};

const policyLevel = (scope, target) => {
  const p = policies.find((x) => x.scope === scope && x.target === target);
  if (!p) return null;
  const {
    scope: _s,
    target: _t,
    updated_by: _u,
    updated_at: _a,
    ...values
  } = p;
  return values;
};

async function deviceRoute(req, res, url, deviceId, rest) {
  const d = devices.get(deviceId);
  if (!d) return json(res, { error: "device not found" }, 404);
  const method = req.method;
  const write = method !== "GET";
  if (write && role !== "operator")
    return json(res, { error: "operator role required" }, 403);
  const body = write ? await readBody(req) : {};
  const rev2 = deviceId === V22;
  const opOnly = [
    "permissions",
    "bindings",
    "audit",
    "mqtt-credentials",
    "batches",
  ];
  if (!write && role !== "operator" && opOnly.some((p) => rest.startsWith(p)))
    return json(res, { error: "operator role required" }, 403);
  if (rest === "") {
    if (method === "PATCH") {
      for (const key of [
        "display_name",
        "location_id",
        "sensor_id",
        "project",
        "notes",
      ])
        if (key in body) d[key] = body[key];
      log(deviceId, "updated", body);
    }
    return json(res, { device: deviceView(d) });
  }
  if (rest === "retire") {
    if (body.confirm !== "RETIRE")
      return json(res, { error: "type RETIRE to retire this device" }, 400);
    Object.assign(d, {
      revoked: true,
      revoked_at: now(),
      status: "revoked",
      mqtt_auth: "shared",
    });
    log(deviceId, "retired", { reason: body.reason });
    return json(res, { device: deviceView(d) });
  }
  if (rest === "reinstate") {
    Object.assign(d, { revoked: false, revoked_at: null, status: "asleep" });
    log(deviceId, "reinstated");
    return json(res, { device: deviceView(d) });
  }
  if (rest === "health") return json(res, { health: rev2 ? health : [] });
  if (rest === "events") {
    const source = url.searchParams.get("source");
    return json(res, {
      events: rev2
        ? deviceEvents.filter((e) => !source || e.source === source)
        : [],
    });
  }
  if (rest === "events/export") {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Content-Disposition": `attachment; filename="${deviceId}-events.json"`,
    });
    return res.end(
      JSON.stringify({
        device_id: deviceId,
        exported_at: now(),
        events: deviceEvents,
      }),
    );
  }
  if (rest === "positions")
    return json(res, { positions: rev2 ? positions : [] });
  if (rest === "positions/export") {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Content-Disposition": "attachment",
    });
    return res.end(JSON.stringify({ type: "FeatureCollection", features: [] }));
  }
  if (rest === "tilt") return json(res, { tilt: rev2 ? tilt : [] });
  if (rest === "tests") return json(res, { tests: rev2 ? tests : [] });
  if (rest === "settings") {
    if (method === "POST") {
      const c = command(deviceId, {
        kind: "config",
        op: "settings",
        args: body.settings,
        expires_at: ahead((body.expires_in_s || 604800) * 1000),
      });
      commands.unshift(c);
      return json(res, { command: c }, 201);
    }
    return json(res, {
      effective: {
        settings_gen: d.settings_gen,
        settings: d.settings,
        settings_at: d.settings_at,
        defaults: rev2Settings,
      },
      history: rev2 ? settingsHistory : [],
    });
  }
  if (rest === "logs")
    return json(res, { logs: rev2 ? logs : [], gaps: rev2 ? gaps : [] });
  if (rest === "gaps") return json(res, { gaps: rev2 ? gaps : [] });
  if (rest === "gaps/report")
    return json(res, { report: gapRow(d), gaps: rev2 ? gaps : [] });
  if (rest === "batches") return json(res, { batches: rev2 ? batches : [] });
  if (rest === "files") {
    if (method === "POST") {
      const c = command(deviceId, { op: "file_list", args: body });
      commands.unshift(c);
      return json(res, { command: c }, 201);
    }
    const path = url.searchParams.get("path");
    return json(res, {
      listings: rev2 ? listings.filter((l) => !path || l.path === path) : [],
    });
  }
  if (rest === "files/downloads") {
    if (method === "POST") {
      const c = command(deviceId, {
        op: "file_chunk",
        origin: "download",
        args: { path: body.path, off: 0, len: 1024 },
      });
      commands.unshift(c);
      const download = {
        id: id(),
        path: body.path,
        requested_by: "fixture-user",
        state: "active",
        size: 98304,
        received_bytes: 0,
        next_offset: 0,
        current_command_id: c.id,
        crc32: null,
        error: null,
        created_at: now(),
        updated_at: now(),
        completed_at: null,
      };
      downloads.unshift(download);
      return json(res, { download_id: download.id, command_id: c.id }, 201);
    }
    // Progress advances on every poll.
    for (const dl of downloads)
      if (dl.state === "active" && dl.size) {
        dl.received_bytes = Math.min(dl.size, dl.received_bytes + 8192);
        if (dl.received_bytes === dl.size)
          Object.assign(dl, {
            state: "complete",
            crc32: "0BADF00D",
            completed_at: now(),
          });
      }
    return json(res, { downloads: rev2 ? downloads : [] });
  }
  let m = /^files\/downloads\/(\d+)(\/(content|cancel))?$/.exec(rest);
  if (m) {
    const dl = downloads.find((x) => x.id === Number(m[1]));
    if (!dl) return json(res, { error: "download not found" }, 404);
    if (m[3] === "cancel") {
      if (dl.state === "active")
        Object.assign(dl, {
          state: "cancelled",
          error: "cancelled by fixture-user",
        });
      return json(res, { download: dl });
    }
    if (m[3] === "content") {
      if (dl.state !== "complete")
        return json(res, { error: `download is ${dl.state}` }, 409);
      res.writeHead(200, {
        "Content-Type": "application/octet-stream",
        "Content-Disposition": "attachment",
      });
      return res.end("fixture");
    }
    return json(res, { download: dl });
  }
  if (rest === "commands") {
    if (body.op) {
      if (body.op === "confirm")
        return json(res, { error: "confirm is issued through /confirm" }, 400);
      const handshake = d.capabilities.handshake_ops?.includes(body.op);
      if (
        d.capabilities.danger_ops?.includes(body.op) &&
        body.confirm !== "DANGER"
      )
        return json(res, { error: "type DANGER to confirm this command" }, 400);
      const c = command(deviceId, {
        kind: d.capabilities.danger_ops?.includes(body.op) ? "danger" : "basic",
        op: body.op,
        args: body.args || {},
        preconfirmed: !!body.auto_confirm,
        expires_at: ahead((body.expires_in_s || 604800) * 1000),
      });
      commands.unshift(c);
      if (handshake)
        // The fixture logger answers with a challenge two seconds later.
        setTimeout(() => {
          Object.assign(c, {
            state: "challenge",
            sent_at: now(),
            publish_count: 1,
            challenge: {
              nonce: "9F3A01C2",
              nexp: Math.floor(Date.now() / 1000) + 120,
              unsaved_frames: body.op === "wipe_mram" ? 12 : 0,
              unsaved_bytes: body.op === "wipe_mram" ? 1234 : 0,
              received_at: now(),
            },
            challenge_expires_at: ahead(120000),
          });
        }, 2000);
      return json(res, { command: c }, 201);
    }
    const c = command(deviceId, {
      protocol: 1,
      kind: body.kind,
      payload: body.payload,
      firmware_ack_expected: body.kind !== "danger",
    });
    commands.unshift(c);
    return json(res, { command: c }, 201);
  }
  m = /^commands\/(\d+)\/(cancel|confirm)$/.exec(rest);
  if (m) {
    const c = commands.find((x) => x.id === Number(m[1]));
    if (!c) return json(res, { error: "command not found" }, 404);
    if (m[2] === "cancel") {
      c.state = "cancelled";
      return json(res, { command: c });
    }
    if (c.state !== "challenge")
      return json(res, { error: "no challenge is waiting" }, 409);
    if ((c.challenge.unsaved_frames || 0) !== (body.confirm_unsaved ?? 0))
      return json(
        res,
        { error: "confirm_unsaved must equal the reported unsaved frames" },
        400,
      );
    Object.assign(c, { state: "acked", final_status: "ok", acked_at: now() });
    const confirm = command(deviceId, {
      kind: "danger",
      op: "confirm",
      parent_id: c.id,
      args: {
        ref: c.id,
        nonce: c.challenge.nonce,
        confirm_unsaved: body.confirm_unsaved,
      },
      origin: "operator",
    });
    commands.unshift(confirm);
    return json(res, { command: confirm }, 201);
  }
  if (rest === "alert-policy") {
    const levels = {
      device: policyLevel("device", deviceId),
      project: d.project ? policyLevel("project", d.project) : null,
      fleet: policyLevel("fleet", null),
    };
    const effective = {},
      sources = {};
    for (const key of Object.keys(DEFAULTS)) {
      const level = ["device", "project", "fleet"].find(
        (l) => levels[l]?.[key] != null,
      );
      effective[key] = level ? levels[level][key] : DEFAULTS[key];
      sources[key] = level || "default";
    }
    return json(res, {
      effective,
      sources,
      levels,
      project: d.project,
      defaults: DEFAULTS,
    });
  }
  if (rest === "limits") {
    if (rev2) {
      const c = command(deviceId, {
        kind: "config",
        op: "settings",
        args: {
          lo: body.min_limit,
          hi: body.max_limit,
          lo_hys: body.min_hysteresis,
          hi_hys: body.max_hysteresis,
        },
      });
      commands.unshift(c);
      return json(res, { command: c }, 201);
    }
    Object.assign(d, body);
    log(deviceId, "limits_changed", body);
    return json(res, { device: deviceView(d) });
  }
  if (rest === "permissions") {
    const list = permissions.get(deviceId) || [];
    if (method === "POST") {
      const p = {
        username: body.username,
        granted_at: now(),
        granted_by: "fixture-user",
      };
      permissions.set(deviceId, [
        ...list.filter((x) => x.username !== body.username),
        p,
      ]);
      log(deviceId, "permission_granted", { username: body.username });
      return json(res, { permission: p }, 201);
    }
    return json(res, { permissions: list });
  }
  m = /^permissions\/(.+)$/.exec(rest);
  if (m && method === "DELETE") {
    const name = decodeURIComponent(m[1]);
    permissions.set(
      deviceId,
      (permissions.get(deviceId) || []).filter((x) => x.username !== name),
    );
    log(deviceId, "permission_revoked", { username: name });
    return json(res, { deleted: true });
  }
  if (rest === "bindings")
    return json(res, {
      bindings: CHANNELS.map((channel) => ({
        binding_key: `v1-${deviceId}-${channel}`,
        topic: `gwl/v1/${deviceId}/${channel}`,
        source_profile: d.profile,
        established_at: d.enrolled_at,
        revoked_at: d.revoked_at,
      })),
    });
  if (rest === "audit")
    return json(res, { audit: audit.filter((a) => a.device_id === deviceId) });
  if (rest.startsWith("mqtt-credentials")) {
    const current = credentials.get(deviceId) || {
      mode: "shared",
      created_at: null,
      created_by: null,
      rotated_at: null,
      mode_changed_at: null,
      published_at: null,
    };
    const view = () => ({
      available: true,
      username: deviceId,
      ...(credentials.get(deviceId) || current),
    });
    if (rest === "mqtt-credentials/mode") {
      if (body.mode === "device" && body.confirm !== "DEVICE")
        return json(
          res,
          { error: "type DEVICE to deny the shared account" },
          400,
        );
      credentials.set(deviceId, {
        ...current,
        mode: body.mode,
        mode_changed_at: now(),
        published_at: now(),
      });
      d.mqtt_auth = body.mode;
      return json(res, { credentials: view() });
    }
    if (method === "POST") {
      const rotated = current.mode !== "shared";
      credentials.set(deviceId, {
        ...current,
        mode: rotated ? current.mode : "dual",
        created_at: current.created_at || now(),
        created_by: "fixture-user",
        rotated_at: rotated ? now() : null,
        published_at: now(),
      });
      d.mqtt_auth = credentials.get(deviceId).mode;
      log(
        deviceId,
        rotated ? "mqtt_credentials_rotated" : "mqtt_credentials_generated",
      );
      return json(
        res,
        {
          username: deviceId,
          password: "fixture-Zq7m4K2pW9xT3vB8",
          credentials: view(),
        },
        201,
      );
    }
    if (method === "DELETE") {
      credentials.delete(deviceId);
      d.mqtt_auth = "shared";
      return json(res, { credentials: view() });
    }
    return json(res, view());
  }
  if (rest === "datums") {
    const list = datums.get(deviceId) || [];
    if (method === "POST") {
      const datum = {
        id: id(),
        ...body,
        created_by: "fixture-user",
        created_at: now(),
      };
      datums.set(deviceId, [datum, ...list]);
      log(deviceId, "datum_added", body);
      return json(res, { datum }, 201);
    }
    return json(res, { datums: list });
  }
  m = /^datums\/(\d+)$/.exec(rest);
  if (m && method === "DELETE") {
    datums.set(
      deviceId,
      (datums.get(deviceId) || []).filter((x) => x.id !== Number(m[1])),
    );
    return json(res, { deleted: true });
  }
  return json(res, { error: "API route not found" }, 404);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname === "/__fixture") {
    role = url.searchParams.get("role") || "operator";
    mode = url.searchParams.get("mode") || "normal";
    return json(res, { role, mode });
  }
  if (url.pathname === "/api/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    });
    res.write(": fixture heartbeat\n\n");
    const timer = setInterval(() => res.write(": heartbeat\n\n"), 15000);
    req.on("close", () => clearInterval(timer));
    return;
  }
  if (mode === "error")
    return json(res, { error: "Fixture service unavailable" }, 503);
  const write = req.method !== "GET";
  if (write && role !== "operator")
    return json(res, { error: "operator role required" }, 403);
  const visible = () =>
    mode === "empty" ? [] : [...devices.values()].map(deviceView);
  const path = url.pathname;
  if (path === "/api/status")
    return json(res, {
      user: { username: "fixture-user", role },
      broker: { configured: true, connected: true },
      service: "groundwater-server",
      ingest: {},
    });
  if (path === "/api/devices") {
    if (req.method === "POST") {
      const body = await readBody(req);
      if (!/^[0-9A-F]{24}$/i.test(body.device_id || ""))
        return json(
          res,
          { error: "device_id must be 24 hexadecimal characters" },
          400,
        );
      const deviceId = body.device_id.toUpperCase();
      if (devices.has(deviceId))
        return json(res, { error: "device is already enrolled" }, 409);
      const d = {
        ...baseDevice(body.profile === "V22" ? V22 : V21[1]),
        health: null,
        info: null,
        link_state: null,
        mqtt_auth: "shared",
        device_id: deviceId,
        display_name: body.display_name,
        profile: body.profile,
        clock_policy: body.clock_policy,
        local_offset_min: body.local_offset_min,
        location_id: body.location_id,
        sensor_id: body.sensor_id,
        project: body.project,
        notes: body.notes,
        status: "never",
        status_reason:
          "no accepted observation or other attributed traffic yet",
        last_received_at: null,
        latest_received: null,
        latest_plausible: null,
        observation_count: 0,
        open_alert_count: 0,
        enrolled_at: now(),
      };
      devices.set(deviceId, d);
      permissions.set(
        deviceId,
        (body.viewers || []).map((username) => ({
          username,
          granted_at: now(),
          granted_by: "fixture-user",
        })),
      );
      log(deviceId, "enrolled", body);
      return json(res, { device: d }, 201);
    }
    return json(res, { devices: visible() });
  }
  const deviceMatch = /^\/api\/devices\/([^/]+)\/?(.*)$/.exec(path);
  if (deviceMatch)
    return deviceRoute(
      req,
      res,
      url,
      decodeURIComponent(deviceMatch[1]),
      deviceMatch[2],
    );
  if (path === "/api/alerts") {
    const state = url.searchParams.get("state") || "all";
    const device = url.searchParams.get("device");
    return json(res, {
      alerts: alerts
        .filter(
          (a) =>
            (state === "all" || a.state === state) &&
            (!device || a.device_id === device),
        )
        .map((a) => ({
          ...a,
          display_name: devices.get(a.device_id)?.display_name,
        })),
    });
  }
  let m = /^\/api\/alerts\/(\d+)\/(acknowledge|resolve)$/.exec(path);
  if (m) {
    const body = await readBody(req);
    const alert = alerts.find((a) => a.id === Number(m[1]));
    if (!alert) return json(res, { error: "alert not found" }, 404);
    if (m[2] === "acknowledge")
      Object.assign(alert, {
        acknowledged_at: now(),
        acknowledged_by: "fixture-user",
        ack_note: body.note || null,
      });
    else {
      if (alert.state !== "open")
        return json(res, { error: "alert is not open" }, 409);
      Object.assign(alert, {
        state: "resolved",
        resolved_at: now(),
        resolved_by: "fixture-user",
        resolve_note: body.note || null,
      });
    }
    log(
      alert.device_id,
      `alert_${m[2] === "acknowledge" ? "acknowledged" : "resolved"}`,
      { alert_id: alert.id },
    );
    return json(res, { alert });
  }
  if (path === "/api/alert-policies") {
    if (role !== "operator")
      return json(res, { error: "operator role required" }, 403);
    if (req.method === "PUT") {
      const body = await readBody(req);
      policies = policies.filter(
        (p) => !(p.scope === body.scope && p.target === body.target),
      );
      const policy = { ...body, updated_by: "fixture-user", updated_at: now() };
      policies.push(policy);
      return json(res, { policy });
    }
    if (req.method === "DELETE") {
      policies = policies.filter(
        (p) =>
          !(
            p.scope === url.searchParams.get("scope") &&
            (p.target || "") === (url.searchParams.get("target") || "")
          ),
      );
      return json(res, { deleted: true });
    }
    return json(res, { policies, defaults: DEFAULTS });
  }
  if (path.startsWith("/api/notifications") || path === "/api/audit") {
    if (role !== "operator")
      return json(res, { error: "operator role required" }, 403);
  }
  if (path === "/api/notifications/rules")
    return json(res, {
      rules,
      delivery: {
        configured: true,
        server: "http://127.0.0.1:8099",
        topic: "groundwater",
        public_url: "https://groundwater.example",
        max_per_hour: 30,
      },
    });
  m = /^\/api\/notifications\/rules\/(.+)$/.exec(path);
  if (m) {
    const body = await readBody(req);
    const rule = rules.find((r) => r.kind === m[1]);
    if (!rule) return json(res, { error: "unknown kind" }, 404);
    Object.assign(rule, body, {
      updated_by: "fixture-user",
      updated_at: now(),
    });
    return json(res, { rule });
  }
  if (path === "/api/notifications/test") return json(res, { sent: true });
  if (path === "/api/notifications") return json(res, { notifications });
  if (path === "/api/audit") return json(res, { audit });
  if (path === "/api/gaps/report") {
    const rows = visible().map(gapRow);
    const totals = {};
    for (const key of [
      "logs",
      "frames",
      "open",
      "requested",
      "unrecoverable",
      "filled",
      "missing_open",
      "missing_unrecoverable",
      "data_gap_events",
    ])
      totals[key] = rows.reduce((sum, r) => sum + r[key], 0);
    return json(res, {
      from: url.searchParams.get("from"),
      to: now(),
      devices: rows,
      totals,
    });
  }
  if (path === "/api/commands") {
    const device = url.searchParams.get("device");
    return json(res, {
      commands: commands.filter((c) => !device || c.device_id === device),
    });
  }
  if (path === "/api/series")
    return json(res, {
      series: series(url, url.searchParams.get("device") || V21[0]),
    });
  if (path === "/api/messages") {
    if (role !== "operator")
      return json(res, { error: "operator required" }, 403);
    return json(res, {
      deliveries: [
        {
          received_at: now(),
          topic: "azman1/feeds/testresults",
          kind: "test",
          device_id: url.searchParams.get("device") || null,
          claimed_device_id: null,
          qos: 1,
          payload: "~ GPS passed\nX SD card unavailable",
          state: "accepted",
          reason: null,
          detail: null,
          time_quality: null,
          duplicate_outcome: null,
          source_profile: "V21",
          binding_key: "fixture",
        },
      ],
    });
  }
  if (path === "/api/export") {
    res.writeHead(200, {
      "Content-Type": "text/csv",
      "Content-Disposition": 'attachment; filename="groundwater.csv"',
    });
    return res.end("recorded_at,gwl\n2026-10-28T00:00:00Z,4.23\n");
  }
  return json(res, { error: "not found" }, 404);
});
server.listen(5188, "127.0.0.1", () =>
  process.stdout.write("Development fixture API on 127.0.0.1:5188\n"),
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => server.close(() => process.exit()));
