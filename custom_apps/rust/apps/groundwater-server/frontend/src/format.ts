import { CLOCK_FLOOR_MS } from "./api";
// Pure formatting helpers shared by the revision 2 and operations views.

/** "in 3 h 5 min" / "4 min ago" for an instant relative to `now`. */
export function relative(
  value: string | null | undefined,
  now: number = Date.now(),
): string {
  if (!value) return "—";
  const at = Date.parse(value);
  if (!Number.isFinite(at)) return "—";
  if (at < CLOCK_FLOOR_MS) return "clock not set";
  const delta = at - now;
  const text = duration(Math.abs(delta));
  if (text === "now") return "now";
  return delta >= 0 ? `in ${text}` : `${text} ago`;
}

/** Compact duration: "now", "45 s", "12 min", "3 h 5 min", "2 d 4 h". */
export function duration(ms: number): string {
  if (!Number.isFinite(ms)) return "—";
  const seconds = Math.floor(Math.abs(ms) / 1000);
  if (seconds < 1) return "now";
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48)
    return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`;
  const days = Math.floor(hours / 24);
  return hours % 24 ? `${days} d ${hours % 24} h` : `${days} d`;
}

/** Seconds left until `deadline` (never negative), or null when unknown. */
export function secondsLeft(
  deadline: string | null | undefined,
  now: number = Date.now(),
): number | null {
  if (!deadline) return null;
  const at = Date.parse(deadline);
  if (!Number.isFinite(at) || at < CLOCK_FLOOR_MS) return null;
  return Math.max(0, Math.floor((at - now) / 1000));
}

/** mm:ss countdown for a short window such as the ~120 s danger nonce. */
export function countdown(seconds: number | null): string {
  if (seconds == null) return "—";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

/** Integer millivolts as volts with two decimals. */
export function millivolts(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value)
    ? `${(value / 1000).toFixed(2)} V`
    : "—";
}

/** Quectel CSQ (0–31, 99 unknown) and its approximate dBm. */
export function csqText(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "—";
  if (value === 99) return "99 (unknown)";
  if (value < 0 || value > 31) return String(value);
  return `${value} (≈ ${-113 + 2 * value} dBm)`;
}

export function bytes(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "—";
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

/** Fraction 0–1 of `part` in `whole`, clamped; null when unknown. */
export function fraction(part: unknown, whole: unknown): number | null {
  if (
    typeof part !== "number" ||
    typeof whole !== "number" ||
    !Number.isFinite(part) ||
    !Number.isFinite(whole) ||
    whole <= 0
  )
    return null;
  return Math.min(1, Math.max(0, part / whole));
}

export function percent(value: number | null): string {
  return value == null ? "—" : `${(value * 100).toFixed(1)} %`;
}

/** Plain display of an unknown JSON value. */
export function show(value: unknown): string {
  if (value == null || value === "") return "—";
  if (typeof value === "boolean") return value ? "yes" : "no";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** Expiry presets offered by command and settings forms (seconds). */
export const EXPIRY_PRESETS: [number, string][] = [
  [3600, "1 hour"],
  [86400, "1 day"],
  [3 * 86400, "3 days"],
  [7 * 86400, "7 days"],
  [14 * 86400, "14 days"],
  [30 * 86400, "30 days"],
];

export function expiryError(seconds: number): string {
  return Number.isInteger(seconds) && seconds >= 60 && seconds <= 2592000
    ? ""
    : "Expiry must be a whole number of seconds from 60 to 2592000 (30 days).";
}

export const humanize = (value: string) =>
  value.replaceAll("_", " ").replaceAll("-", " ");

/** The device's latest `health` object is the logger's JSON as sent, so it
 * still carries the firmware's "not read" markers (65535 mV, CSQ 99) and a
 * stale free-space figure while the SD card is not ok. They become null,
 * which every formatter shows as "—", as the stored health rows already do. */
export function readHealth(
  health: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
  const h = { ...(health || {}) };
  for (const key of ["bat_mv", "sol_mv"]) if (h[key] === 65535) h[key] = null;
  if (h.csq === 99) h.csq = null;
  if (h.sd !== "ok") h.sd_free_mb = null;
  return h;
}
