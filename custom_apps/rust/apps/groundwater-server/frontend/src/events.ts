// Event timeline categorisation and one-line summaries for revision 2
// device events (ring records, `alerts` copies and server actions).
import type { DeviceEvent } from "./types";

export const EVENT_CATEGORIES = [
  ["alarm", "Level alarms"],
  ["tamper", "Impact / tamper"],
  ["orientation", "Orientation"],
  ["gps", "GPS moved"],
  ["tail-lock", "Tail lock"],
  ["gap", "Data gaps"],
  ["sensor", "Sensor faults"],
  ["power", "Power critical"],
  ["storage", "Storage"],
  ["clock", "Clock and log"],
  ["server", "Server actions"],
  ["other", "Other"],
] as const;
export type EventCategory = (typeof EVENT_CATEGORIES)[number][0];

const CATEGORY: Record<string, EventCategory> = {
  gwl_alarm_enter: "alarm",
  gwl_alarm_exit: "alarm",
  impact: "tamper",
  orientation: "orientation",
  gps_moved: "gps",
  tail_lock: "tail-lock",
  tail_unlocked: "tail-lock",
  data_gap: "gap",
  gap_requested: "gap",
  sensor_fault: "sensor",
  power_critical: "power",
  storage_warning: "storage",
  sd_flush: "storage",
  mqtt_flush: "storage",
  clock_set: "clock",
  log_start: "clock",
  clock_sync_requested: "clock",
  clock_synced: "clock",
};

export function eventCategory(event: Pick<DeviceEvent, "event" | "source">) {
  if (CATEGORY[event.event]) return CATEGORY[event.event];
  return event.source === "server" ? "server" : "other";
}

export const categoryLabel = (category: string) =>
  EVENT_CATEGORIES.find(([key]) => key === category)?.[1] || category;

/** Severity used for styling: "problem" events need attention. */
export function eventTone(event: Pick<DeviceEvent, "event" | "details">) {
  const d = event.details || {};
  const state = typeof d.state === "string" ? d.state : "";
  if (state === "exit") return "ok";
  if (
    [
      "gwl_alarm_enter",
      "impact",
      "orientation",
      "gps_moved",
      "tail_lock",
      "data_gap",
      "sensor_fault",
      "power_critical",
      "unmatched_ack",
      "link_lost",
    ].includes(event.event)
  )
    return "problem";
  if (event.event === "storage_warning") {
    const kind = String(d.kind || "");
    return ["mram_ok", "sd_restored"].includes(kind) ? "ok" : "problem";
  }
  if (["gwl_alarm_exit", "tail_unlocked", "clock_synced"].includes(event.event))
    return "ok";
  return "info";
}

const num = (value: unknown, digits = 2) =>
  typeof value === "number" && Number.isFinite(value)
    ? value.toFixed(digits)
    : "?";
const mv = (value: unknown) =>
  typeof value === "number" ? `${(value / 1000).toFixed(2)} V` : "?";

/** Short human summary of an event's details. */
export function eventSummary(event: Pick<DeviceEvent, "event" | "details">) {
  const d = event.details || {};
  switch (event.event) {
    case "gwl_alarm_enter":
    case "gwl_alarm_exit":
      return `${d.limit ?? "level"} limit ${event.event.endsWith("enter") ? "entered" : "cleared"} · level ${num(d.level ?? d.lvl, 3)} m, threshold ${num(d.threshold ?? d.thr, 3)} m`;
    case "impact":
      return `Impact peak ${d.peak_mg ?? "?"} mg`;
    case "orientation":
      return `Tilt ${num(d.tilt_deg, 1)}°`;
    case "gps_moved":
      return `Moved ${num(d.dist_m, 0)} m (threshold ${num(d.thr_m, 0)} m)`;
    case "tail_lock":
      return "Ring full with unsaved data: logging stops until data is saved";
    case "tail_unlocked":
      return `Tail unlocked after ${d.locked_seconds ?? "?"} s`;
    case "data_gap":
      return `Logger gap: ${d.missed_readings ?? "?"} readings, ${d.missed_events ?? "?"} events missed (${d.reason ?? "unknown"})`;
    case "sensor_fault":
      return `Sensor ${d.state ?? ""} · ${d.sensor_status_name ?? d.ss ?? "?"} · ${d.sensor_mv ?? d.mv ?? "?"} mV`;
    case "power_critical":
      return `Power ${d.state ?? ""} · battery ${mv(d.bat_mv)}, solar ${mv(d.sol_mv)}`;
    case "storage_warning":
      return `${String(d.kind ?? "storage").replaceAll("_", " ")}${typeof d.unsaved === "number" ? ` · ${d.unsaved} of ${d.usable ?? "?"} bytes unsaved` : ""}`;
    case "clock_set":
      return `Clock set ${d.old_valid ? "" : "from uptime "}to ${typeof d.new_time === "number" ? new Date(d.new_time * 1000).toISOString() : "?"} (${d.new_source ?? "?"})`;
    case "log_start":
      return `New log ${d.log_id ?? ""} (${d.reason ?? "?"}), firmware ${d.firmware_version ?? "?"}`;
    case "sd_flush":
    case "mqtt_flush":
      return `${event.event === "sd_flush" ? "SD" : "MQTT"} flush (${d.reason ?? "routine"})`;
    default: {
      const entries = Object.entries(d).filter(([k]) => k !== "type_name");
      return entries.length
        ? entries
            .slice(0, 4)
            .map(
              ([k, v]) =>
                `${k} ${typeof v === "object" ? JSON.stringify(v) : String(v)}`,
            )
            .join(" · ")
        : "";
    }
  }
}

/** Local calendar day used to group the timeline. */
export function eventDay(
  event: Pick<DeviceEvent, "recorded_at" | "received_at">,
) {
  const at = event.recorded_at || event.received_at;
  const date = new Date(at);
  return Number.isFinite(date.getTime())
    ? date.toLocaleDateString(undefined, {
        weekday: "short",
        year: "numeric",
        month: "short",
        day: "numeric",
      })
    : "Unknown day";
}

export function groupByDay<
  T extends Pick<DeviceEvent, "recorded_at" | "received_at">,
>(events: T[]) {
  const groups: { day: string; events: T[] }[] = [];
  for (const event of events) {
    const day = eventDay(event);
    const last = groups[groups.length - 1];
    if (last && last.day === day) last.events.push(event);
    else groups.push({ day, events: [event] });
  }
  return groups;
}

/** Test status bitfield (Rev2 Type 5), as the server names its bits. */
export const TEST_STATUS_BITS = [
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
];
export function testStatusFlags(status: number | null | undefined) {
  if (typeof status !== "number") return { passed: [], failed: [] };
  const passed: string[] = [],
    failed: string[] = [];
  TEST_STATUS_BITS.forEach((name, bit) =>
    (status & (1 << bit) ? passed : failed).push(name),
  );
  return { passed, failed };
}

export const SENSOR_STATUS = [
  "ok",
  "no-sensor",
  "under-range",
  "over-range",
  "adc-fault",
  "factors-invalid",
];
export const sensorStatusName = (status: number | null | undefined) =>
  status == null ? "—" : SENSOR_STATUS[status] || `unknown (${status})`;
