// Development-only HTTP fixtures for UI review. Never imported by src or the
// production build. Node is used here to exercise the frontend's pinned toolchain.
// Shapes follow frontend/README.md ("Protocol revision 2" and "Operations API").
import { createServer } from "node:http";

const V21 = ["8F3A21C04B9E77A1D25C01FE", "A13A21C04B9E77A1D25C01AB"];
const V22 = "6A1B2C3D4E5F60718293A4B5";
// mode: normal | fault (sensor over-range, ring locked, err 7) | lost
// (settings-lost RECOVERY after an automatic restore that expired, health
// with not-read values) | restoring (the same, restore still on its way) |
// ram (fallback mode: MRAM faulted at boot, settings held in RAM only) |
// stuck (one uplink held, a log whose re-run keeps failing, salvaged raw
// content until the operator releases it) | empty | error.
let role = "operator",
  mode = "normal",
  // busy: the CSV export answers 429 as when four exports already run.
  // crossorigin: every write is refused as the API refuses a write the
  // browser marks as sent from another origin.
  busy = false,
  crossOrigin = false,
  // cut: JSON exports come back truncated, and the logger has 1,200 older
  // commands, so the command list pages (`before`).
  cut = false,
  commands = [],
  nextId = 100;
const now = () => new Date().toISOString();
const ago = (ms) => new Date(Date.now() - ms).toISOString();
const ahead = (ms) => new Date(Date.now() + ms).toISOString();
const HOUR = 3600000,
  DAY = 86400000;
const id = () => nextId++;
// mode=stuck: /api/status ingest.salvaged until …/salvaged/dismiss (the
// fixture keeps all of it on the V2.2 logger).
let salvaged = null;
const SALVAGED = () => ({
  rawBatches: 2,
  oldestRawBatchAt: ago(5 * DAY),
  storeFailedMessages: 1,
  oldestStoreFailedAt: ago(2 * DAY),
});
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
  // Firmware 2.2 ring readings carry no power or signal values: those come
  // from health (observations hold them only for the fallback reading).
  battery_v: rev2 ? null : 3.72,
  rssi: rev2 ? null : 68,
  solar_v: rev2 ? null : 3,
  time_quality: "plausible",
  time_reason: rev2
    ? "anchor at seq 412 + 3 x 900 s"
    : "Device-local timestamp normalized with enrollment offset.",
  quality_reasons: rev2 && mode === "fault" ? ["sensor-over-range"] : [],
  sensor_status: rev2 ? (mode === "fault" ? 3 : 0) : null,
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
  ...(d.device_id === V22 && d.latest_received
    ? {
        latest_received: observation(true),
        latest_plausible: observation(true),
        health:
          mode === "fault"
            ? { ...d.health, mram: "locked", err: 7, log: "off" }
            : mode === "ram"
              ? // Fallback mode: MRAM faulted at boot, no ring (usable 0).
                { ...d.health, mram: "fault", usable: 0, unsaved: 0, gen: 2 }
              : lostMode()
                ? {
                    ...d.health,
                    // Settings lost (err 4). The logger sent 65535 mV and
                    // CSQ 99 (not read); rev2.rs normalised_health serves
                    // them, and free space of a card that is not ok, as null.
                    mram: "recovery",
                    err: 4,
                    log: "off",
                    gen: 0,
                    bat_mv: null,
                    csq: null,
                    sd: "error",
                    sd_free_mb: null,
                  }
                : d.health,
        // db.rs scoped_devices: the episode and its automatic restore.
        settings_lost_since: lostMode() ? ago(2 * DAY) : null,
        // rev2_commands.rs: settings acked with "persist":false.
        settings_ram_only: mode === "ram",
        ...(mode === "ram" ? { settings_gen: 2 } : {}),
        settings_restore: lostMode()
          ? (({ id, state, final_status, status_reason, created_at }) => ({
              id,
              state,
              final_status,
              status_reason,
              created_at,
              expires_at: restoreCommand().expires_at,
              acked_at: restoreCommand().acked_at,
            }))(restoreCommand())
          : null,
      }
    : {}),
  open_alert_kinds: [
    ...new Map(
      allAlerts()
        .filter((a) => a.device_id === d.device_id && a.state === "open")
        .map((a) => {
          const subject = ["high", "low"].includes(a.detail?.subject)
            ? a.detail.subject
            : null;
          return [`${a.kind}/${subject}`, { kind: a.kind, subject }];
        }),
    ).values(),
  ].sort((a, b) => a.kind.localeCompare(b.kind)),
  open_alert_count: allAlerts().filter(
    (a) => a.device_id === d.device_id && a.state === "open",
  ).length,
  pending_challenge_count: commands.filter(
    (c) => c.device_id === d.device_id && c.state === "challenge",
  ).length,
});

// As ops_api.rs ALERT_JSON; `detail` carries what alerting.sql stores: the
// event's own details (copy keys lvl/thr/ss/mv/dist_m/thr_m, record keys
// level/threshold/sensor_status/sensor_mv/distance_m/threshold_m) plus
// subject, event, source, seq, log_id, time_estimated and received_at.
const severity = (kind) =>
  ["power_critical", "tail_lock", "mram_fault", "settings_lost"].includes(kind)
    ? "critical"
    : ["solar_low", "signal_low"].includes(kind)
      ? "info"
      : "warning";
const logged = (event, source, seq, receivedAt, extra) => ({
  subject: "",
  event,
  event_id: seq,
  source,
  seq,
  log_id: source === "record" ? 1761000001 : null,
  time_estimated: false,
  received_at: receivedAt,
  ...extra,
});
let alerts = [
  {
    id: 1,
    device_id: V21[0],
    kind: "above_max",
    state: "open",
    trigger_value: 5.6,
    opened_at: ago(2 * HOUR),
  },
  {
    id: 2,
    device_id: V21[0],
    kind: "below_min",
    state: "resolved",
    trigger_value: 1.2,
    opened_at: ago(10 * HOUR),
    resolved_at: ago(8.3 * HOUR),
  },
  {
    id: 3,
    device_id: V22,
    kind: "battery_low",
    state: "open",
    trigger_value: 6.91,
    opened_at: ago(5 * HOUR),
    acknowledged_at: ago(4 * HOUR),
    acknowledged_by: "fixture-user",
    ack_note: "Battery swap booked for Thursday",
  },
  {
    id: 6,
    device_id: V22,
    kind: "solar_low",
    state: "resolved",
    // rev2.sql groundwater_power_alerts: the highest solar reading (V).
    trigger_value: 0.31,
    opened_at: ago(6 * DAY),
    resolved_at: ago(5 * DAY),
    detail: {
      threshold_mv: 1000,
      days: 3,
      daylight_samples: 4,
      max_mv: 310,
      resolution: "health",
    },
  },
  {
    id: 4,
    device_id: V22,
    kind: "stale",
    state: "resolved",
    trigger_value: 1.5,
    opened_at: ago(6 * DAY),
    resolved_at: ago(5.9 * DAY),
    detail: {
      expected_at: ago(6 * DAY + 40 * 60000),
      stale_after: ago(6 * DAY),
      margin_min: 40,
    },
  },
  {
    id: 5,
    device_id: V22,
    kind: "sensor_fault",
    state: "open",
    trigger_value: 2150,
    opened_at: ago(40 * HOUR),
    detail: logged("sensor_fault", "record", 370, ago(20 * HOUR), {
      state: "enter",
      sensor_status: 3,
      sensor_status_name: "over-range",
      sensor_mv: 2150,
      settings_gen: 5,
    }),
  },
  {
    id: 6,
    device_id: V22,
    kind: "gwl_alarm",
    state: "resolved",
    trigger_value: 15.2,
    opened_at: ago(2 * HOUR),
    resolved_at: ago(1.5 * HOUR),
    detail: {
      ...logged("gwl_alarm_enter", "alert", 431, ago(2 * HOUR - 60000), {
        limit: "high",
        state: "enter",
        lvl: 15.2,
        thr: 15,
        subject: "high",
      }),
      resolution: "logger",
      exit: { limit: "high", state: "exit", lvl: 14.7, thr: 15 },
    },
  },
  {
    id: 7,
    device_id: V22,
    kind: "impact",
    state: "open",
    trigger_value: 2310,
    opened_at: ago(3 * DAY),
    detail: {
      ...logged("impact", "record", 402, ago(26 * HOUR), {
        source: "tap",
        peak_mg: 2310,
      }),
      repeats: 1,
      last_at: ago(2 * DAY),
    },
  },
  {
    id: 8,
    device_id: V22,
    kind: "gps_moved",
    state: "open",
    trigger_value: 41,
    opened_at: ago(50 * HOUR),
    detail: logged("gps_moved", "alert", null, ago(50 * HOUR - 60000), {
      dist_m: 41,
      thr_m: 25,
    }),
  },
  {
    id: 9,
    device_id: V22,
    kind: "power_critical",
    state: "resolved",
    trigger_value: 6.55,
    opened_at: ago(90 * HOUR),
    resolved_at: ago(80 * HOUR),
    detail: {
      ...logged("power_critical", "record", 340, ago(70 * HOUR), {
        state: "enter",
        kind: "battery-critical",
        bat_mv: 6550,
        sol_mv: 200,
      }),
      resolution: "logger",
    },
  },
  {
    id: 10,
    device_id: V22,
    kind: "orientation",
    state: "resolved",
    trigger_value: 12.3,
    opened_at: ago(27 * HOUR),
    resolved_at: ago(20 * HOUR),
    resolved_by: "fixture-user",
    resolve_note: "Casing knocked during mowing; re-seated",
    detail: logged("orientation", "alert", 401, ago(27 * HOUR - 60000), {
      tilt_deg: 12.3,
    }),
  },
  {
    id: 11,
    device_id: V22,
    kind: "sd_card",
    state: "resolved",
    trigger_value: 0,
    opened_at: ago(48 * HOUR),
    resolved_at: ago(42 * HOUR),
    detail: {
      sd: "error",
      sd_free_mb: 7392,
      source: "server",
      resolution: "health",
    },
  },
  {
    id: 12,
    device_id: V22,
    kind: "signal_low",
    state: "resolved",
    trigger_value: 6,
    opened_at: ago(9 * DAY),
    resolved_at: ago(8 * DAY),
    detail: { csq: 6, source: "server", resolution: "health" },
  },
  {
    id: 13,
    device_id: V22,
    kind: "watchdog_resets",
    state: "resolved",
    trigger_value: 2,
    opened_at: ago(12 * DAY),
    resolved_at: ago(5 * DAY),
    detail: { resets_7d: 2, source: "server", resolution: "health" },
  },
  {
    id: 14,
    device_id: V22,
    kind: "clock_invalid",
    state: "resolved",
    trigger_value: 0,
    opened_at: ago(30 * DAY),
    resolved_at: ago(29.9 * DAY),
    detail: { source: "server", resolution: "health" },
  },
  {
    id: 15,
    device_id: V22,
    kind: "tail_lock",
    state: "resolved",
    trigger_value: 0,
    opened_at: ago(121 * HOUR),
    resolved_at: ago(118 * HOUR),
    detail: {
      ...logged("tail_lock", "record", 299, ago(110 * HOUR), {
        head: 1,
        tail: 2,
        reason: "ring-full-unsaved",
      }),
      resolution: "logger",
    },
  },
  {
    id: 16,
    device_id: V22,
    kind: "mram_almost_full",
    state: "resolved",
    trigger_value: 94000,
    opened_at: ago(125 * HOUR),
    resolved_at: ago(117 * HOUR),
    detail: {
      ...logged("storage_warning", "alert", null, ago(124 * HOUR), {
        kind: "mram_almost_full",
        unsaved: 94000,
        usable: 122368,
      }),
      resolution: "health",
    },
  },
].map((a) => ({
  severity: severity(a.kind),
  resolved_at: null,
  acknowledged_at: null,
  acknowledged_by: null,
  ack_note: null,
  resolved_by: null,
  resolve_note: null,
  detail: {},
  ...a,
}));
// Fault mode: what the server raises from that state (health err 7, ring
// locked) on top of the logger's own alerts.
const faultAlerts = () =>
  (mode === "fault"
    ? [
        ["logger_error", 7, { err: 7 }],
        ["tail_lock", 1234, { mram: "locked", unsaved: 1234, usable: 122368 }],
        ["logging_off", 0, { log: "off" }],
      ]
    : mode === "lost"
      ? [
          // rev2_commands.rs maybe_restore_settings, restore ended.
          [
            "settings_lost",
            4,
            {
              reason:
                "the automatic settings restore ended and the logger still has no settings",
              command_id: 66,
              state: "expired",
              final_status: null,
              status_reason: "expired before the logger received it",
              err: 4,
              action: "send settings",
            },
          ],
          ["logger_error", 4, { err: 4 }],
          ["logging_off", 0, { log: "off" }],
        ]
      : []
  ).map(([kind, value, detail], i) => ({
    id: 200 + i,
    device_id: V22,
    kind,
    severity: severity(kind),
    state: "open",
    trigger_value: value,
    opened_at: ago(4 * HOUR),
    resolved_at: null,
    acknowledged_at: null,
    acknowledged_by: null,
    ack_note: null,
    resolved_by: null,
    resolve_note: null,
    detail: { ...detail, source: "server" },
  }));
const allAlerts = () => [...alerts, ...faultAlerts()];
const lostMode = () => mode === "lost" || mode === "restoring";
/** Command #66 (the automatic restore) as the current mode has it. */
const restoreCommand = () => {
  const c = commands.find((x) => x.id === 66);
  if (mode === "lost")
    return {
      ...c,
      state: "expired",
      final_status: null,
      status_reason: "expired before the logger received it",
      created_at: ago(2 * DAY),
      sent_at: ago(2 * DAY),
      acked_at: null,
      ack_payload: null,
      expires_at: ago(DAY),
    };
  if (mode === "restoring")
    return {
      ...c,
      state: "queued",
      final_status: null,
      created_at: ago(2 * DAY),
      sent_at: null,
      acked_at: null,
      ack_payload: null,
      publish_count: 0,
      expires_at: ahead(5 * DAY),
    };
  return c;
};
/** cut=1: 1,200 older acknowledged commands below the fixture's own. */
const olderCommands = Array.from({ length: 1200 }, (_, i) => ({
  id: 40 - i,
  device_id: V22,
  kind: "basic",
  protocol: 2,
  op: "get_status",
  args: {},
  payload: null,
  state: "acked",
  final_status: "ok",
  status_reason: null,
  requested_by: "fixture-user",
  origin: "operator",
  created_at: ago(40 * DAY + i * HOUR),
  sent_at: ago(40 * DAY + i * HOUR),
  acked_at: ago(40 * DAY + i * HOUR),
  ack_payload: null,
  publish_count: 1,
  last_published_at: ago(40 * DAY + i * HOUR),
  expires_at: null,
  hold_until_sleep: false,
  parent_id: null,
  preconfirmed: false,
  challenge: null,
  replace_settings: false,
}));

const health = Array.from({ length: 30 }, (_, i) => ({
  id: 30 - i,
  source: i % 7 === 3 ? "get_status" : "health",
  recorded_at: ago(i * 6 * HOUR + 4 * HOUR),
  time_source: "device",
  time_valid: true,
  received_at: ago(i * 6 * HOUR + 4 * HOUR - 2000),
  uptime_s: 5120 + i,
  // Not read: the server stores null (65535 mV, CSQ 99, free space
  // unless the SD card is ok).
  csq: i === 5 ? null : 18 + (i % 6),
  bat_mv: i === 9 ? null : 7412 - i * 12,
  sol_mv: i === 9 ? null : i % 4 === 0 ? 300 : 5120 - i * 30,
  sd: i === 8 ? "error" : "ok",
  sd_free_mb: i === 8 ? null : 7400 - i,
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
      state: "enter",
      sensor_status: 3,
      sensor_status_name: "over-range",
      sensor_mv: 2150,
      settings_gen: 5,
    },
    40,
    370,
  ],
  [
    "record",
    "sensor_fault",
    {
      state: "exit",
      sensor_status: 3,
      sensor_status_name: "over-range",
      sensor_mv: 1234,
      settings_gen: 5,
    },
    30,
    375,
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
  [
    "server",
    "clock_sync_unchanged",
    {
      command_id: 58,
      t: Math.floor(Date.now() / 1000) - 20 * 3600,
      tv: 1,
      set: false,
    },
    20,
    null,
  ],
  [
    "server",
    "settings_restore_requested",
    {
      command_id: 49,
      gen: 4,
      source: "ack",
      acknowledged_at: ago(21 * DAY),
      err: 4,
    },
    240,
    null,
  ],
  [
    "server",
    "settings_recovery_ended",
    { since: ago(10 * DAY), command_id: 49, gen: 5 },
    216,
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
// api_rev2.rs events: firmware 2.2 writes the accelerometer at the alarm as
// the next record (Type 2 reason 2, no fix).
deviceEvents.push({
  ...deviceEvents[2],
  id: 98,
  source: "record",
  event: "impact",
  seq: 444,
  recorded_at: ago(5 * HOUR),
  received_at: ago(4 * HOUR),
  details: { peak_mg: 1450 },
  confirmed_by_record: null,
  attitude: {
    position_id: 21,
    seq: 445,
    accel_x_mg: 180,
    accel_y_mg: -40,
    accel_z_mg: 985,
    accel_status: 0,
  },
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
  // The API serves every source on the record scale: 0 none, 1 2D, 2 3D.
  fix: i === 5 ? 0 : i === 4 ? 1 : 2,
  // i 5: no fix; lat/lon/alt/hdop not read (null).
  lat: i === 5 ? null : -33.8688197 + (i === 2 ? 0.00037 : i * 0.000004),
  lon: i === 5 ? null : 151.2092955 + (i === 2 ? 0.00012 : -i * 0.000003),
  alt_m: i === 5 ? null : 12 + i,
  hdop: i === 5 ? null : 1.1 + i / 10,
  satellites: 8 - (i % 3),
  accel_x_mg: 15,
  accel_y_mg: -20,
  accel_z_mg: 1002,
  accel_status: 0,
}));
// api_rev2.rs ALARM_ATTITUDE: the accelerometer at an impact alarm, not a
// failed fix; drawn nowhere on the plot.
positions.unshift({
  ...positions[0],
  id: 21,
  seq: 445,
  recorded_at: ago(5 * HOUR),
  received_at: ago(4 * HOUR),
  reason: 2,
  fix: 0,
  lat: null,
  lon: null,
  alt_m: null,
  hdop: null,
  satellites: 0,
  accel_x_mg: 180,
  accel_y_mg: -40,
  accel_z_mg: 985,
  alarm_event: "impact",
});
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
    // api_rev2.rs tests: a Type 5 record and its test/result JSON merged.
    id: 3,
    source: "record",
    sources: ["record", "json"],
    json_id: 41,
    json_ok: true,
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
      up: 30,
      status_flags: [
        "sensor",
        "sd",
        "sim",
        "network",
        "mqtt",
        "gnss_fix",
        "display",
        "accelerometer",
        "mram",
        "solar",
      ],
    },
  },
  {
    // The logger's JSON said ok, but MRAM failed: the server's rule
    // (sensor, SD, SIM, network, MQTT, display, accelerometer, MRAM) fails it.
    id: 5,
    source: "record",
    sources: ["record", "json"],
    json_id: 44,
    json_ok: true,
    trigger: "power_on",
    command_id: null,
    recorded_at: ago(30 * HOUR),
    received_at: ago(30 * HOUR),
    battery_mv: null,
    solar_mv: null,
    csq: null,
    sensor_mv: 1230,
    sensor_ma: 8.2,
    level: 12.3,
    sensor_status: 0,
    status_bits: 0b1011111111,
    ok: false,
    details: {
      sd: "ok",
      sim: "ok",
      net: "ok",
      mqtt: "ok",
      gps: "nofix",
      epd: "ok",
      acc: "ok",
      mram: "fail",
      warn: ["No solar"],
    },
  },
  {
    id: 4,
    source: "json",
    sources: ["json"],
    json_id: 4,
    json_ok: false,
    trigger: "button",
    command_id: null,
    recorded_at: ago(35 * HOUR),
    received_at: ago(35 * HOUR),
    battery_mv: 7390,
    solar_mv: 4100,
    csq: 20,
    sensor_mv: 2150,
    sensor_ma: 21.5,
    level: 25.104,
    sensor_status: 3,
    status_bits: 1022,
    ok: false,
    // gps_mode off: the logger reports gps "off" and no "No GPS" warning.
    details: { sd: "ok", mram: "ok", gps: "off", warn: ["Sensor over-range"] },
  },
  {
    id: 2,
    source: "record",
    sources: ["record"],
    json_id: null,
    json_ok: null,
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
    // A firmware with payload schema 2 started a new log (Type 14 reason 6);
    // this server has no schema 2 decoder (api_rev2.rs logs `undecodable`).
    log_id: 1761000002,
    log_hex: "68F6A0E2",
    payload_schema: 2,
    start_reason: null,
    started_at: null,
    firmware_version: null,
    first_received_at: ago(3 * HOUR),
    last_received_at: ago(3 * HOUR),
    frames: 18,
    min_seq: 1,
    max_seq: 18,
    decode_errors: 0,
    conflicting_copies: 0,
    resent_copies: 0,
    open_gaps: 0,
    unrecoverable_gaps: 0,
    pending_readings: 0,
    derive_pending: 0,
    undecodable: 18,
    decoder_available: false,
    resolve_pending: false,
    resolve_error: null,
    pending_reasons: [],
  },
  {
    log_id: 1761000003,
    log_hex: "68F6A0E3",
    payload_schema: 1,
    start_reason: "payload-schema-changed",
    started_at: ago(60 * DAY),
    firmware_version: "2.2.0",
    first_received_at: ago(60 * DAY),
    last_received_at: ago(40 * DAY),
    frames: 96,
    min_seq: 1,
    max_seq: 96,
    decode_errors: 0,
    conflicting_copies: 0,
    resent_copies: 0,
    open_gaps: 0,
    unrecoverable_gaps: 0,
    pending_readings: 0,
    derive_pending: 0,
    undecodable: 0,
    decoder_available: true,
    resolve_pending: false,
    resolve_error: null,
    pending_reasons: [],
  },
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
    pending_readings: 14,
    // rev2_store.rs: derived data waiting for the background re-run; in
    // mode=stuck the re-run itself keeps failing.
    derive_pending: 2,
    resolve_pending: true,
    get resolve_error() {
      return mode === "stuck"
        ? "re-run attempt 4 failed: settings: invalid byte sequence for encoding UTF8: 0x00"
        : "settings: invalid byte sequence for encoding UTF8: 0x00";
    },
    // api_rev2.rs logs: readings with no time, by reason.
    pending_reasons: [
      {
        reason: "no anchor follows the unrecoverable gap at seq 101-140",
        state: "gap_unrecoverable",
        count: 10,
        min_seq: 141,
        max_seq: 150,
      },
      {
        reason: "awaiting the anchor before this reading",
        state: "awaiting_anchor",
        count: 4,
        min_seq: 429,
        max_seq: 432,
      },
    ],
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
  ok: i !== 3 && i !== 5,
  // i 5: ingest.rs raw salvage of a batch the store failed on.
  error:
    i === 3
      ? "crc: batch CRC-32 mismatch"
      : i === 5
        ? "not stored: database: deadlock detected"
        : null,
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
  raw_retained: i < 4 || i === 5,
  derive_error:
    i === 1
      ? "derived data failed (frame 427: numeric field overflow); raw frames kept and flagged for the re-run"
      : null,
  frames_derive_pending: i === 1 ? 2 : 0,
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
    id: 2,
    path: "/GWL/68F6A0E1/B0000002.BIN",
    requested_by: "fixture-user",
    state: "failed",
    size: 65536,
    received_bytes: 8192,
    next_offset: 8192,
    current_command_id: null,
    crc32: null,
    // rev2_commands.rs file_chunk_received (C8).
    error:
      "the file changed size during the download (65536 → 98304 bytes); download it again",
    created_at: ago(3 * DAY),
    updated_at: ago(3 * DAY),
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
// notify.rs KINDS (11 rules).
const RULES = [
  ["above_max", "Level above maximum", "alert", ["warning"]],
  ["below_min", "Level below minimum", "alert", ["warning"]],
  ["battery_low", "Battery low", "alert", ["warning"]],
  ["solar_low", "Solar low", "alert", ["info"]],
  ["stale", "Missed connection", "alert", ["warning"]],
  ["gwl_alarm", "Logger level alarm", "alert", ["warning"]],
  ["power_critical", "Power critical", "alert", ["critical"]],
  ["sensor_fault", "Sensor fault", "alert", ["warning"]],
  ["storage", "Storage (SD/MRAM)", "alert", ["warning", "critical"]],
  ["tamper", "Impact, orientation or movement", "alert", ["warning"]],
  [
    "health",
    "Logger health (errors, settings lost, logging off, clock, signal, resets)",
    "alert",
    ["info", "warning", "critical"],
  ],
];
let rules = RULES.map(([kind, label, source, severities]) => ({
  kind,
  label,
  source,
  severities,
  enabled: kind !== "solar_low",
  min_severity: "warning",
  priority: kind === "power_critical" ? 5 : kind === "health" ? 3 : 4,
  cooldown_min: kind === "health" ? 720 : 60,
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
    kind: "impact",
    severity: "warning",
    transition: "open",
    title: "Impact: Bore 7",
    message: "Impact peak 2310 mg",
    state: "suppressed",
    reason: "cooldown",
    attempts: 0,
    alert_id: 7,
    event_id: null,
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
  replace_settings: false,
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
    id: 63,
    kind: "config",
    op: "settings",
    args: { read_s: 900, hi: 15, foo_s: 3 },
    state: "acked",
    final_status: "partial",
    sent_at: ago(2 * DAY),
    acked_at: ago(2 * DAY),
    publish_count: 1,
    last_published_at: ago(2 * DAY),
    ack_payload: {
      v: 2,
      id: 63,
      op: "settings",
      status: "partial",
      gen: 5,
      results: { read_s: "ok", hi: "ok", foo_s: "unsupported" },
      settings: { ...rev2Settings },
    },
  }),
  command(V22, {
    // rev2_commands.rs maybe_fetch_debug: after an unexpected reset.
    id: 67,
    op: "get_debug",
    origin: "auto-debug",
    requested_by: "auto-debug",
    state: "acked",
    final_status: "ok",
    sent_at: ago(3 * HOUR),
    acked_at: ago(3 * HOUR),
    publish_count: 1,
    last_published_at: ago(3 * HOUR),
    ack_payload: {
      v: 2,
      id: 67,
      op: "get_debug",
      status: "ok",
      data: {
        fw: "2.2.0",
        reset: "sw",
        wdg: 2,
        last_error: 0,
        reset_flags: 0x10000141,
        boot_report: 0x0180,
      },
    },
  }),
  command(V22, {
    // A watchdog reset cut it: duplicate/"prev":"failed" (rev2_commands.rs).
    id: 68,
    op: "flush_sd",
    state: "acked",
    final_status: "interrupted",
    status_reason:
      "interrupted by a logger reset, outcome unknown: the logger answered duplicate, previously failed, and did not run flush_sd again. A watchdog or fault reset cut it while it ran (or its ack was lost), so it may have done part or all of its work; it may have sent or saved data before the reset; the data received shows what arrived",
    sent_at: ago(5 * HOUR),
    acked_at: ago(3 * HOUR),
    publish_count: 2,
    last_published_at: ago(3 * HOUR),
    ack_payload: {
      v: 2,
      id: 68,
      op: "flush_sd",
      status: "duplicate",
      prev: "failed",
    },
  }),
  command(V22, {
    id: 64,
    op: "get_status",
    state: "acked",
    final_status: "ok",
    sent_at: ago(DAY),
    acked_at: ago(DAY),
    publish_count: 1,
    last_published_at: ago(DAY),
    ack_payload: {
      v: 2,
      id: 64,
      op: "get_status",
      status: "ok",
      data: {
        t: Math.floor(Date.now() / 1000) - 86400,
        tv: 1,
        bat_mv: 7412,
        sol_mv: 5120,
        csq: 21,
        sd: "ok",
        mram: "ok",
        unsaved: 1234,
        usable: 122368,
        boot: 17,
        head: 4120,
        tail: 2896,
        log_id: 1761000001,
        last_seq: 431,
      },
    },
  }),
  // The automatic re-send of lost settings (rev2_commands.rs
  // maybe_restore_settings); expires in mode=lost (see /api/commands).
  command(V22, {
    id: 66,
    kind: "config",
    op: "settings",
    args: { ...rev2Settings },
    replace_settings: true,
    state: "acked",
    final_status: "ok",
    requested_by: "auto-restore",
    origin: "auto-restore",
    created_at: ago(10 * DAY),
    sent_at: ago(10 * DAY),
    acked_at: ago(10 * DAY),
    publish_count: 1,
    last_published_at: ago(10 * DAY),
    expires_at: ago(3 * DAY),
    ack_payload: { v: 2, id: 66, op: "settings", status: "ok", gen: 5 },
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

const deliveryLog = Array.from({ length: 260 }, (_, i) =>
  i === 24
    ? {
        // ingest.rs: an uplink acknowledged but not stored (raw kept).
        id: 5000 - i,
        received_at: ago(2 * DAY),
        topic: `gwl/v1/${V22}/health`,
        kind: "health",
        device_id: V22,
        claimed_device_id: V22,
        qos: 1,
        payload: '{"v":2,"t":1763300000,"tv":1,"bat_mv":7400}',
        state: "quarantined",
        reason: "rev2-store-failed",
        detail: "storing failed: database: deadlock detected",
        time_quality: null,
        duplicate_outcome: null,
        source_profile: "V22",
        binding_key: null,
        direction: "in",
      }
    : i % 25 === 7
      ? {
          id: 5000 - i,
          received_at: ago(i * 2 * HOUR),
          topic: "gwl/v1/0000000000000000000000AA/health",
          kind: "health",
          device_id: null,
          claimed_device_id: "0000000000000000000000AA",
          qos: 1,
          payload: '{"v":2,"t":1763300000,"tv":1,"bat_mv":7400}',
          state: "quarantined",
          reason: "unknown-device",
          detail: "no enrolled device has this DeviceID",
          time_quality: null,
          duplicate_outcome: null,
          source_profile: null,
          binding_key: null,
          direction: "in",
        }
      : {
          id: 5000 - i,
          received_at: ago(i * 2 * HOUR),
          topic: `gwl/v1/${V22}/data/stream`,
          kind: "data/stream",
          device_id: V22,
          claimed_device_id: V22,
          qos: 1,
          payload: "47574231…",
          state: "accepted",
          reason: null,
          detail:
            i === 1
              ? "6 frames (2 new); derived data failed (frame 427: numeric field overflow); raw frames kept and flagged for the re-run"
              : null,
          time_quality: null,
          duplicate_outcome: null,
          source_profile: "V22",
          binding_key: null,
          direction: "in",
        },
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
  const bucket = Number(url.searchParams.get("bucket")) || 0;
  const rev2 = deviceId === V22;
  const toDatum = (raw) =>
    datum === "dtw_bgl"
      ? 42 - 0.6 - raw
      : datum === "rl_ahd"
        ? 21.3 - (42 - 0.6 - raw)
        : raw;
  // db.rs device_series. Firmware 2.2 faults: raw mode has over-range
  // readings that keep the firmware's 25.1 m (points with sensor_status 3)
  // and no-sensor readings without a level (faults only); bucketed mode has
  // a bucket mixing valid and fault samples (a point plus a fault entry)
  // and buckets of faults only (fault entries, no point).
  const fault = (i) =>
    !rev2
      ? null
      : bucket === 0
        ? i >= 20 && i <= 22
          ? { status: 3, kinds: ["over-range"], level: 25.1 }
          : i >= 60 && i <= 63
            ? { status: 1, kinds: ["no-sensor"], level: null }
            : null
        : i === 20
          ? { valid: 3, count: 2, kinds: ["over-range"] }
          : i >= 60 && i <= 63
            ? { valid: 0, count: 4, kinds: ["no-sensor"] }
            : i === 70
              ? { valid: 0, count: 1, kinds: ["adc-fault", "under-range"] }
              : null;
  const points = [],
    faults = [];
  if (mode !== "empty")
    for (let i = 0; i < 96; i++) {
      if (i > 40 && i < 48) continue;
      const recorded_at = new Date(from + ((to - from) * i) / 95).toISOString();
      const f = fault(i);
      const raw = rev2 ? 12 + Math.sin(i / 10) : 3.7 + Math.sin(i / 10);
      if (f && bucket === 0) {
        faults.push({
          recorded_at,
          sensor_status: f.status,
          fault_count: 1,
          fault_kinds: f.kinds,
          valid_count: 0,
        });
        if (f.level == null) continue;
      } else if (f) {
        faults.push({
          recorded_at,
          sensor_status: null,
          fault_count: f.count,
          fault_kinds: f.kinds,
          valid_count: f.valid,
        });
        if (f.valid === 0) continue;
      }
      const level = f && bucket === 0 ? f.level : raw;
      points.push({
        recorded_at,
        gwl: toDatum(level),
        raw_gwl: level,
        gwl_text: null,
        battery_v: rev2 ? null : 3.6 + i / 1000,
        solar_v: rev2 ? null : Math.max(0, 5 * Math.sin(i / 8)),
        rssi: rev2 ? null : 65 + Math.sin(i / 4) * 10,
        csq: null,
        // Valid samples only; a raw point is 1.
        sample_count: bucket === 0 ? 1 : f ? f.valid : 5,
        conflict: i === 10,
        sensor_status: bucket > 0 || !rev2 ? null : f ? f.status : 0,
        fault_count: f ? (bucket === 0 ? 1 : f.count) : 0,
        fault_kinds: f ? f.kinds : [],
      });
    }
  const valid = points.filter((p) => !p.sensor_status).map((p) => p.gwl);
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
    min_gwl: valid.length ? Math.min(...valid) : null,
    max_gwl: valid.length ? Math.max(...valid) : null,
    bucket_minutes: bucket,
    truncated: false,
    faults,
    faults_truncated: false,
    // The real API always sends these (raw: limits in raw metres).
    datum,
    inverted: datum === "dtw_bgl",
    unconverted: datum === "raw" ? 0 : 3,
    limits: limits
      ? { min: limits[0], max: limits[1] }
      : { min: d.min_limit, max: d.max_limit },
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
    const source = url.searchParams.get("source"),
      event = url.searchParams.get("event");
    return json(res, {
      events: rev2
        ? deviceEvents.filter(
            (e) =>
              (!source || e.source === source) && (!event || e.event === event),
          )
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
        from: url.searchParams.get("from"),
        to: null,
        // ops_api.rs: oldest first, 20,000 rows at most.
        // Cut once; a continuation from the newest row's time is not.
        truncated:
          cut &&
          !(
            Date.parse(url.searchParams.get("from") || "") >
            Date.now() - 3 * HOUR
          ),
        limit: 20000,
        events: [...deviceEvents].sort(
          (a, b) =>
            Date.parse(a.recorded_at || a.received_at) -
            Date.parse(b.recorded_at || b.received_at),
        ),
      }),
    );
  }
  if (rest === "positions")
    return json(res, { positions: rev2 ? positions : [] });
  if (rest === "positions/export") {
    const geojson = url.searchParams.get("format") === "geojson";
    const rows = [...(rev2 ? positions : [])].reverse();
    const truncated = cut && !url.searchParams.get("from");
    res.writeHead(200, {
      "Content-Type": geojson ? "application/geo+json" : "application/json",
      "Content-Disposition": `attachment; filename="${deviceId}-positions.${geojson ? "geojson" : "json"}"`,
    });
    return res.end(
      JSON.stringify(
        geojson
          ? {
              type: "FeatureCollection",
              features: rows
                .filter((p) => p.lat != null && p.lon != null)
                .map(({ lat, lon, alt_m, ...properties }) => ({
                  type: "Feature",
                  geometry: {
                    type: "Point",
                    coordinates: alt_m == null ? [lon, lat] : [lon, lat, alt_m],
                  },
                  properties,
                })),
              properties: {
                device_id: deviceId,
                exported_at: now(),
                truncated,
                limit: 20000,
              },
            }
          : {
              device_id: deviceId,
              exported_at: now(),
              truncated,
              limit: 20000,
              positions: rows,
            },
      ),
    );
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
      setTimeout(
        () =>
          Object.assign(c, {
            state: "sent",
            sent_at: now(),
            publish_count: 1,
            last_published_at: now(),
          }),
        1000,
      );
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
    downloads.sort(
      (a, b) => Date.parse(b.created_at) - Date.parse(a.created_at),
    );
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
      // platform.rs cancel_command: confirmations go with their command; a
      // confirmation already published gets the warning.
      const sent = commands.filter(
        (k) => k.parent_id === c.id && ["queued", "sent"].includes(k.state),
      );
      for (const k of sent) k.state = "cancelled";
      const published = sent.filter((k) => k.publish_count > 0);
      const warning = published.length
        ? `cancelled, but confirmation ${published.map((k) => k.id).join(", ")} was already sent to the logger: the operation may still run; its ack will show the outcome`
        : null;
      return json(res, { command: c, warning });
    }
    if (c.state !== "challenge")
      return json(
        res,
        { error: `command is ${c.state}, not awaiting confirmation` },
        409,
      );
    if (Date.parse(c.challenge_expires_at) <= Date.now())
      return json(
        res,
        {
          error: "the challenge expired (nexp passed); queue the command again",
        },
        409,
      );
    if (
      commands.some(
        (k) => k.parent_id === c.id && ["queued", "sent"].includes(k.state),
      )
    )
      return json(res, { error: "a confirmation is already pending" }, 409);
    if ((c.challenge.unsaved_frames || 0) !== (body.confirm_unsaved ?? 0))
      return json(
        res,
        {
          error: `the logger reported ${c.challenge.unsaved_frames} unsaved frames; confirm_unsaved must equal ${c.challenge.unsaved_frames}`,
        },
        400,
      );
    // As on the server: the parent stays in challenge until the logger acks
    // the confirmation (the fixture logger does so after five seconds).
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
      expires_at: c.challenge_expires_at,
    });
    commands.unshift(confirm);
    setTimeout(
      () => Object.assign(confirm, { state: "sent", publish_count: 1 }),
      1000,
    );
    setTimeout(() => {
      const ack = {
        v: 2,
        id: confirm.id,
        op: c.op,
        ref: c.id,
        status: "ok",
      };
      for (const target of [confirm, c])
        Object.assign(target, {
          state: "acked",
          final_status: "ok",
          acked_at: now(),
          ack_payload: ack,
        });
    }, 5000);
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
      if (rotated && body.confirm !== "ROTATE")
        return json(
          res,
          {
            error:
              "type ROTATE to replace this unit's password; a unit already using its own account stays offline until reflashed",
          },
          400,
        );
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
      if (body.confirm !== "REMOVE")
        return json(
          res,
          {
            error:
              "type REMOVE to delete this unit's own account; a unit flashed with it stays offline until reflashed with the shared account",
          },
          400,
        );
      if (current.mode === "shared")
        return json(res, { error: "this unit uses the shared account" }, 404);
      credentials.delete(deviceId);
      d.mqtt_auth = "shared";
      return json(res, { credentials: view() });
    }
    return json(res, view());
  }
  if (rest === "salvaged/dismiss" && method === "POST") {
    // api.rs dismiss_salvaged: counts released (0 when nothing waited).
    const mine = deviceId === V22 && salvaged;
    const released = {
      rawBatches: mine ? salvaged.rawBatches : 0,
      storeFailedMessages: mine ? salvaged.storeFailedMessages : 0,
    };
    if (mine) salvaged = null;
    log(deviceId, "salvaged_dismissed", released);
    return json(res, released);
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
    busy = url.searchParams.get("busy") === "1";
    crossOrigin = url.searchParams.get("crossorigin") === "1";
    cut = url.searchParams.get("cut") === "1";
    salvaged = mode === "stuck" ? SALVAGED() : null;
    return json(res, { role, mode, busy, crossOrigin, cut });
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
  // api.rs cross_origin(): Sec-Fetch-Site other than same-origin/none.
  const site = req.headers["sec-fetch-site"];
  if (
    write &&
    (crossOrigin || (site && !["same-origin", "none"].includes(site)))
  )
    return json(
      res,
      { error: "cross-origin requests may not change state" },
      403,
    );
  const visible = () =>
    mode === "empty" ? [] : [...devices.values()].map(deviceView);
  const path = url.pathname;
  if (path === "/api/status")
    return json(res, {
      user: { username: "fixture-user", role },
      broker: { configured: true, connected: true },
      service: "groundwater-server",
      ingest: {
        deliveries: 42,
        observations: 40,
        lastDeliveryAt: role === "operator" ? ago(4 * HOUR) : null,
        held: mode === "stuck" ? 1 : 0,
        // api.rs status: operators only, null for viewers.
        rerun:
          role === "operator"
            ? mode === "stuck"
              ? { pendingLogs: 1, failingLogs: 1 }
              : { pendingLogs: 0, failingLogs: 0 }
            : null,
        salvaged:
          role === "operator"
            ? salvaged || {
                rawBatches: 0,
                oldestRawBatchAt: null,
                storeFailedMessages: 0,
                oldestStoreFailedAt: null,
              }
            : null,
      },
      retentionDays: 90,
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
    const kind = url.searchParams.get("kind");
    return json(res, {
      alerts: allAlerts()
        .filter(
          (a) =>
            (state === "all" || a.state === state) &&
            (!device || a.device_id === device) &&
            (!kind || a.kind === kind),
        )
        .sort((a, b) => Date.parse(b.opened_at) - Date.parse(a.opened_at))
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
        return json(res, { error: "the alert is no longer open" }, 409);
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
    const before = Number(url.searchParams.get("before") || Infinity);
    const list = [...commands, ...(cut ? olderCommands : [])]
      .filter((c) => (!device || c.device_id === device) && c.id < before)
      .map((c) => (c.id === 66 ? restoreCommand() : c))
      .sort((a, b) => b.id - a.id);
    // api.rs commands: 500 per page (id order), `truncated` when there are
    // more, `before=<last id>` for the next page.
    return json(res, {
      commands: list.slice(0, 500),
      truncated: list.length > 500,
    });
  }
  if (path === "/api/series") {
    if (!devices.has(url.searchParams.get("device") || ""))
      return json(res, { error: "device not found" }, 404);
    return json(res, {
      series: series(url, url.searchParams.get("device")),
    });
  }
  if (path === "/api/messages") {
    if (role !== "operator")
      return json(res, { error: "operator required" }, 403);
    // api.rs deliveries: newest first, `state`/`topic`/`device` filters,
    // `before=<id>` paging, `more` when another page exists. 260 rows; every
    // 25th is a quarantined delivery from an unknown DeviceID.
    const q = url.searchParams;
    const before = Number(q.get("before") || Infinity);
    const limit = Math.min(Math.max(Number(q.get("limit") || 100), 1), 500);
    const rows = deliveryLog.filter(
      (d) =>
        d.id < before &&
        (!q.get("state") || d.state === q.get("state")) &&
        (!q.get("topic") || d.topic === q.get("topic")) &&
        (!q.get("device") || d.device_id === q.get("device")) &&
        (!q.get("since") || d.received_at >= q.get("since")),
    );
    return json(res, {
      deliveries: rows.slice(0, limit),
      more: rows.length > limit,
    });
  }
  if (path === "/api/export") {
    if (busy)
      return json(
        res,
        { error: "other exports are running; try again shortly" },
        429,
      );
    res.writeHead(200, {
      "Content-Type": "text/csv",
      "Content-Disposition": 'attachment; filename="groundwater.csv"',
    });
    return res.end("recorded_at,gwl\n2026-10-28T00:00:00Z,4.23\n");
  }
  return json(res, { error: "not found" }, 404);
});
const port = Number(process.env.FIXTURE_PORT || 5188);
server.listen(port, "127.0.0.1", () =>
  process.stdout.write(`Development fixture API on 127.0.0.1:${port}\n`),
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => server.close(() => process.exit()));
