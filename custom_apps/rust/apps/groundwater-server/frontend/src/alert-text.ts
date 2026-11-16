// How each alert kind reads to an operator: name, trigger value in its own
// unit, and the timing facts (late reports, latched kinds, resolution).
// Shapes: ops_api.rs ALERT_JSON, detail keys from alerting.sql.
import { number, stamp } from "./api";
import { latchedErrorText, sensorProblem } from "./events";
import { bytes, csqText, duration, humanize } from "./format";
import type { Alert } from "./types";

const LATCHED = ["impact", "orientation", "gps_moved"];

export const ALERT_KIND_LABEL: Record<string, string> = {
  above_max: "Level above high limit",
  below_min: "Level below low limit",
  battery_low: "Battery low",
  solar_low: "Solar low",
  stale: "Missed connection",
  gwl_alarm: "Logger level alarm",
  sensor_fault: "Sensor fault",
  power_critical: "Power critical",
  mram_almost_full: "MRAM almost full",
  mram_fault: "MRAM fault",
  tail_lock: "Tail Lock (logging stopped)",
  sd_card: "SD card problem",
  impact: "Impact",
  orientation: "Orientation changed",
  gps_moved: "Moved (GPS)",
  logger_error: "Logger error latched",
  logging_off: "Logging off",
  clock_invalid: "Clock not set",
  signal_low: "Weak signal",
  watchdog_resets: "Repeated watchdog resets",
  settings_lost: "Settings lost (logging stopped)",
  battery_unread: "Battery not read",
  boot_report: "Boot report",
  decoder_missing: "Data cannot be decoded (server update needed)",
};

type AlertFields = Pick<Alert, "kind" | "trigger_value" | "detail">;

const field = (d: Record<string, unknown>, ...keys: string[]) => {
  for (const key of keys)
    if (typeof d[key] === "number" && Number.isFinite(d[key]))
      return d[key] as number;
  return null;
};

/** The alert's name; a logger level alarm names its limit. */
export function alertLabel(alert: Pick<Alert, "kind" | "detail">) {
  const label = ALERT_KIND_LABEL[alert.kind] || humanize(alert.kind);
  const subject = alert.detail?.subject;
  return alert.kind === "gwl_alarm" && (subject === "high" || subject === "low")
    ? `${label} (${subject})`
    : label;
}

/** The value that raised the alert, in its own unit; "—" when the kind has
 * none. Logger copies and ring records name some fields differently. */
export function alertValue(alert: AlertFields) {
  const v = alert.trigger_value;
  const d = alert.detail || {};
  switch (alert.kind) {
    case "battery_low":
    case "solar_low":
    case "power_critical":
      // Firmware 2.2 leaves bat_mv out when the ADC reading failed.
      return alert.kind === "power_critical" && field(d, "bat_mv") == null && !v
        ? "battery not read"
        : `${number(v, 2)} V`;
    case "stale":
      return `${number(v, 1)} h overdue`;
    case "above_max":
    case "below_min":
      return `${number(v, 3)} m`;
    case "gwl_alarm": {
      const limit = field(d, "threshold", "thr");
      return `${number(v, 3)} m${limit == null ? "" : ` (limit ${number(limit, 3)} m)`}`;
    }
    case "sensor_fault":
      // Firmware 2.2 leaves mv out when the sensor was not read.
      return field(d, "sensor_mv", "mv") == null && !v
        ? "mV not read"
        : `${number(v, 0)} mV`;
    case "impact":
      return `${number(v, 0)} mg`;
    case "orientation":
      return `${number(v, 1)}° tilt`;
    case "gps_moved": {
      const limit = field(d, "threshold_m", "thr_m");
      return `${number(v, 0)} m${limit == null ? "" : ` (threshold ${number(limit, 0)} m)`}`;
    }
    case "signal_low":
      return `CSQ ${csqText(v)}`;
    case "watchdog_resets":
      return `${number(v, 0)} in 7 days`;
    case "logger_error":
      return `code ${number(v, 0)}`;
    case "settings_lost":
      return `error ${latchedErrorText(v)}`;
    case "battery_unread":
      return `${number(v, 0)} health reports without it`;
    case "decoder_missing":
      return `payload schema ${number(v, 0)}`;
    case "mram_almost_full":
    case "tail_lock": {
      const unsaved = field(d, "unsaved") ?? (v > 0 ? v : null);
      if (unsaved == null) return "—";
      const usable = field(d, "usable");
      return `${bytes(unsaved)}${usable ? ` of ${bytes(usable)}` : ""} unsaved`;
    }
    case "sd_card": {
      const kind = typeof d.kind === "string" ? d.kind : "";
      const state = typeof d.sd === "string" ? d.sd : kind.replace(/^sd_/, "");
      return state ? `SD ${state}` : "—";
    }
    case "mram_fault":
      return typeof d.mram === "string" ? `MRAM ${d.mram}` : "—";
    default:
      return "—";
  }
}

/** What the trigger value alone does not say: the sensor status, a time
 * the logger could not stamp, repeats of a latched alert. */
export function alertNotes(alert: AlertFields) {
  const d = alert.detail || {};
  const notes: string[] = [];
  if (alert.kind === "sensor_fault") {
    const status = field(d, "sensor_status", "ss");
    notes.push(
      status != null
        ? sensorProblem(status) || "sensor ok"
        : String(d.sensor_status_name ?? "status unknown"),
    );
  }
  if (alert.kind === "settings_lost") {
    if (typeof d.reason === "string") notes.push(d.reason);
    if (typeof d.command_id === "number")
      notes.push(
        `automatic restore #${d.command_id} ${[d.state, d.final_status].filter((x) => typeof x === "string").join(": ") || "ended"}${typeof d.status_reason === "string" ? ` (${d.status_reason})` : ""}`,
      );
    notes.push("send full settings with Replace on the Settings tab");
  }
  if (alert.kind === "boot_report" && Array.isArray(d.problems))
    notes.push(d.problems.map(String).join("; "));
  if (alert.kind === "decoder_missing")
    notes.push(
      "frames are kept raw; update the server and they are decoded at its first start",
    );
  if (alert.kind === "battery_unread")
    notes.push("battery low and power critical alerts cannot work meanwhile");
  if (alert.kind === "orientation" || alert.kind === "gps_moved")
    notes.push(
      "one alert per excursion: the logger re-arms only after the value is back within the re-arm margin",
    );
  if (alert.kind === "solar_low") {
    const days = field(d, "days"),
      threshold = field(d, "threshold_mv");
    if (days != null)
      notes.push(
        `no solar reading reached ${threshold == null ? "the threshold" : `${number(threshold / 1000, 2)} V`} in ${days} day${days === 1 ? "" : "s"}; value is the highest`,
      );
  }
  if (d.time_estimated === true)
    notes.push("logger clock not set: time is when it arrived");
  const repeats = field(d, "repeats");
  if (repeats)
    notes.push(
      `repeated ${repeats} time${repeats === 1 ? "" : "s"}${typeof d.last_at === "string" ? `, last ${stamp(d.last_at)}` : ""}`,
    );
  return notes;
}

/** "reported 3 d later" when the logger's event reached the server more than
 * 15 minutes after it happened (notifications use the same threshold). */
export function reportedLate(alert: Pick<Alert, "opened_at" | "detail">) {
  const received = alert.detail?.received_at;
  if (typeof received !== "string" || alert.detail?.time_estimated === true)
    return "";
  const lag = Date.parse(received) - Date.parse(alert.opened_at);
  return Number.isFinite(lag) && lag > 15 * 60000
    ? `reported ${duration(lag)} later`
    : "";
}

/** How a resolved alert closed. */
export function resolution(alert: Alert) {
  if (alert.state !== "resolved") return "";
  const by = alert.resolved_by
    ? ` by ${alert.resolved_by}`
    : alert.detail?.resolution === "logger"
      ? " (cleared by the logger)"
      : alert.detail?.resolution === "health"
        ? " (cleared by a health report)"
        : "";
  return `resolved ${stamp(alert.resolved_at)}${by}`;
}

export const isLatched = (kind: string) => LATCHED.includes(kind);
