// Protocol revision 2 logger settings: the config/set key table
// (docs/gwl-v1-rev2.md §5). validateSettings mirrors the server's
// src/settings.rs validate() message for message, so the operator sees the
// same refusal before queuing a week-long round trip to a sleeping logger.

export const MAX_INTERVAL_S = 2332800;
const F32_MAX = 3.4028234663852886e38;

export type SettingKind =
  | "int"
  | "bool"
  | "float"
  | "nullable-float"
  | "text"
  | "factors";

export interface SettingField {
  key: string;
  label: string;
  kind: SettingKind;
  hint: string;
  group: string;
}

export const SETTING_FIELDS: SettingField[] = [
  {
    key: "read_s",
    label: "Reading interval (s)",
    kind: "int",
    hint: "60 … 2,332,800",
    group: "Schedule",
  },
  {
    key: "send_s",
    label: "Send interval (s)",
    kind: "int",
    hint: "300 … 2,332,800",
    group: "Schedule",
  },
  {
    key: "start",
    label: "Start (UTC seconds)",
    kind: "int",
    hint: "0 = none, otherwise a future UTC time",
    group: "Schedule",
  },
  {
    key: "listen_s",
    label: "Command window (s)",
    kind: "int",
    hint: "10 … 600",
    group: "Schedule",
  },
  {
    key: "attempts",
    label: "MQTT connect attempts",
    kind: "int",
    hint: "1 … 10",
    group: "Schedule",
  },
  {
    key: "utc_off",
    label: "Display UTC offset (min)",
    kind: "int",
    hint: "−720 … 840",
    group: "Schedule",
  },
  {
    key: "gps_mode",
    label: "GPS mode",
    kind: "int",
    hint: "0 at send, 1 every N sends, 2 fixed seconds, 3 off",
    group: "GPS and tilt",
  },
  {
    key: "gps_val",
    label: "GPS value",
    kind: "int",
    hint: "Mode 1: 1 … 255 sends; mode 2: 600 … 2,332,800 s",
    group: "GPS and tilt",
  },
  {
    key: "gps_sens",
    label: "GPS movement sensitivity",
    kind: "int",
    hint: "0 … 10 (0 off)",
    group: "GPS and tilt",
  },
  {
    key: "tilt_mode",
    label: "Tilt mode",
    kind: "int",
    hint: "As GPS mode",
    group: "GPS and tilt",
  },
  {
    key: "tilt_val",
    label: "Tilt value",
    kind: "int",
    hint: "As GPS value",
    group: "GPS and tilt",
  },
  {
    key: "tap",
    label: "Tap detection",
    kind: "bool",
    hint: "0 / 1",
    group: "GPS and tilt",
  },
  {
    key: "tap_sens",
    label: "Tap sensitivity",
    kind: "int",
    hint: "1 … 10",
    group: "GPS and tilt",
  },
  {
    key: "fac",
    label: "Calibration factors [a,p,b,c]",
    kind: "factors",
    hint: "Four finite numbers, comma separated",
    group: "Sensor and alarms",
  },
  {
    key: "lo",
    label: "Low level alarm (m)",
    kind: "nullable-float",
    hint: "Empty = unset",
    group: "Sensor and alarms",
  },
  {
    key: "lo_hys",
    label: "Low alarm hysteresis (m)",
    kind: "float",
    hint: "≥ 0",
    group: "Sensor and alarms",
  },
  {
    key: "hi",
    label: "High level alarm (m)",
    kind: "nullable-float",
    hint: "Empty = unset",
    group: "Sensor and alarms",
  },
  {
    key: "hi_hys",
    label: "High alarm hysteresis (m)",
    kind: "float",
    hint: "≥ 0",
    group: "Sensor and alarms",
  },
  {
    key: "partial",
    label: "Partial uploads",
    kind: "bool",
    hint: "0 / 1",
    group: "Sensor and alarms",
  },
  {
    key: "led",
    label: "Operation LED",
    kind: "bool",
    hint: "0 / 1",
    group: "Sensor and alarms",
  },
  {
    key: "loc",
    label: "Location text",
    kind: "text",
    hint: "≤ 32 bytes, one line",
    group: "Labels",
  },
  {
    key: "proj",
    label: "Project text",
    kind: "text",
    hint: "≤ 32 bytes, one line",
    group: "Labels",
  },
  {
    key: "text",
    label: "Display text",
    kind: "text",
    hint: "≤ 64 bytes, at most one newline",
    group: "Labels",
  },
];

export const SETTING_DEFAULTS: Record<string, unknown> = {
  read_s: 3600,
  send_s: 604800,
  gps_mode: 0,
  gps_val: 0,
  tilt_mode: 0,
  tilt_val: 0,
  start: 0,
  fac: [0, 1, 1, 0],
  tap: 1,
  tap_sens: 5,
  gps_sens: 5,
  lo: null,
  hi: null,
  lo_hys: 0,
  hi_hys: 0,
  loc: "",
  proj: "",
  text: "",
  partial: 0,
  utc_off: 0,
  led: 0,
  attempts: 3,
  listen_s: 60,
};

const isInt = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value);

function int(value: unknown, key: string, min: number, max: number) {
  return isInt(value) && value >= min && value <= max
    ? ""
    : `${key} must be an integer in ${min}..${max}`;
}

function finite(value: unknown, key: string) {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    Math.abs(value) <= F32_MAX
    ? ""
    : `${key} must be a finite number`;
}

export const utf8Length = (text: string) =>
  new TextEncoder().encode(text).length;

// Rust char::is_control: Unicode Cc (U+0000–U+001F, U+007F–U+009F).
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/;

function text(value: unknown, key: string, max: number, newlines: number) {
  if (typeof value !== "string") return `${key} must be a string`;
  const length = utf8Length(value);
  if (length > max) return `${key} is ${length} bytes, limit ${max}`;
  if ((value.match(/\n/g) || []).length > newlines)
    return `${key} allows at most ${newlines} newline(s)`;
  if (CONTROL.test(value)) return `${key} contains a control character`;
  return "";
}

function modePair(args: Record<string, unknown>, prefix: string) {
  const modeKey = `${prefix}_mode`,
    valKey = `${prefix}_val`;
  const has = (key: string) => Object.prototype.hasOwnProperty.call(args, key);
  if (!has(modeKey) && !has(valKey)) return "";
  if (!has(modeKey))
    return `${valKey} needs ${modeKey}: its range depends on the mode`;
  const modeError = int(args[modeKey], modeKey, 0, 3);
  if (modeError) return modeError;
  const mode = args[modeKey] as number;
  if ((mode === 1 || mode === 2) && !has(valKey))
    return `${modeKey} ${mode} requires ${valKey}`;
  if (!has(valKey)) return "";
  if (mode === 1) return int(args[valKey], valKey, 1, 255);
  if (mode === 2) return int(args[valKey], valKey, 600, MAX_INTERVAL_S);
  return int(args[valKey], valKey, 0, MAX_INTERVAL_S);
}

/** Validates a config/set `args` object exactly like settings.rs. Returns
 * the list of errors (empty when valid). `now` is UTC seconds. */
export function validateSettings(args: unknown, now: number): string[] {
  if (args == null || typeof args !== "object" || Array.isArray(args))
    return ["settings must be a JSON object"];
  const object = args as Record<string, unknown>;
  const keys = Object.keys(object);
  if (keys.length === 0) return ["settings must name at least one key"];
  const errors: string[] = [];
  for (const key of keys) {
    const value = object[key];
    let error = "";
    switch (key) {
      case "read_s":
        error = int(value, key, 60, MAX_INTERVAL_S);
        break;
      case "send_s":
        error = int(value, key, 300, MAX_INTERVAL_S);
        break;
      case "gps_mode":
      case "gps_val":
      case "tilt_mode":
      case "tilt_val":
        break;
      case "start":
        // The firmware rejects a start after 2099 or over 366 days ahead.
        error = int(value, key, 0, 4102444799);
        if (!error && value !== 0 && (value as number) <= now)
          error = "start must be 0 (none) or a future UTC time";
        else if (!error && (value as number) > now + 366 * 86400)
          error = "start must be at most 366 days ahead";
        break;
      case "fac":
        if (!Array.isArray(value) || value.length !== 4)
          error = "fac must be [a,p,b,c]: four finite numbers";
        else
          error = value.map((item) => finite(item, "fac")).find(Boolean) || "";
        break;
      case "tap":
      case "partial":
      case "led":
        error = int(value, key, 0, 1);
        break;
      case "tap_sens":
        error = int(value, key, 1, 10);
        break;
      case "gps_sens":
        error = int(value, key, 0, 10);
        break;
      case "lo":
      case "hi":
        error = value === null ? "" : finite(value, key);
        break;
      case "lo_hys":
      case "hi_hys":
        error = finite(value, key);
        if (!error && (value as number) < 0) error = `${key} must be ≥ 0`;
        break;
      case "loc":
      case "proj":
        error = text(value, key, 32, 0);
        break;
      case "text":
        error = text(value, key, 64, 1);
        break;
      case "utc_off":
        error = int(value, key, -720, 840);
        break;
      case "attempts":
        error = int(value, key, 1, 10);
        break;
      case "listen_s":
        error = int(value, key, 10, 600);
        break;
      default:
        error = `${key} is not a contract setting`;
    }
    if (error) errors.push(error);
  }
  for (const prefix of ["gps", "tilt"]) {
    const error = modePair(object, prefix);
    if (error) errors.push(error);
  }
  return errors;
}

/** Text shown in an editor input for a settings value. */
export function settingText(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (Array.isArray(value)) return value.join(", ");
  return String(value);
}

/** Parses an editor input back into the JSON type of its key. Returns
 * `undefined` for malformed text so validation can name it. */
export function parseSetting(field: SettingField, raw: string): unknown {
  const text = raw.trim();
  switch (field.kind) {
    case "text":
      return raw.replace(/\r\n/g, "\n");
    case "nullable-float":
      if (text === "") return null;
      return /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(text) ? Number(text) : text;
    case "float":
      return /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(text) ? Number(text) : text;
    case "factors": {
      const parts = text.split(",").map((part) => part.trim());
      return parts.map((part) =>
        /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(part) ? Number(part) : part,
      );
    }
    default:
      return /^-?\d+$/.test(text) ? Number(text) : text;
  }
}

const same = (a: unknown, b: unknown) =>
  JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

/** Whether a requested value is in effect. The logger reports floats with
 * 7 significant digits (contract §4), so floats compare relatively. */
export function sameSetting(requested: unknown, effective: unknown): boolean {
  if (typeof requested === "number" && typeof effective === "number")
    return (
      Math.abs(requested - effective) <=
      1e-6 * Math.max(1, Math.abs(requested), Math.abs(effective))
    );
  if (Array.isArray(requested) && Array.isArray(effective))
    return (
      requested.length === effective.length &&
      requested.every((value, i) => sameSetting(value, effective[i]))
    );
  return same(requested, effective);
}

/** The keys whose edited value differs from the effective settings, with
 * GPS/tilt mode and value always sent as a pair (their ranges depend on
 * each other). */
export function changedSettings(
  drafts: Record<string, string>,
  effective: Record<string, unknown>,
): Record<string, unknown> {
  const changes: Record<string, unknown> = {};
  for (const field of SETTING_FIELDS) {
    const raw = drafts[field.key];
    if (raw === undefined) continue;
    const value = parseSetting(field, raw);
    const current =
      field.key in effective
        ? effective[field.key]
        : SETTING_DEFAULTS[field.key];
    if (!same(value, current)) changes[field.key] = value;
  }
  for (const prefix of ["gps", "tilt"]) {
    const mode = `${prefix}_mode`,
      val = `${prefix}_val`;
    if (mode in changes || val in changes) {
      for (const key of [mode, val])
        if (!(key in changes)) {
          const field = SETTING_FIELDS.find((f) => f.key === key)!;
          changes[key] =
            drafts[key] !== undefined
              ? parseSetting(field, drafts[key])
              : (effective[key] ?? SETTING_DEFAULTS[key]);
        }
    }
  }
  return changes;
}

/** Keys that differ between two settings generations. */
export function settingsDiff(
  current: Record<string, unknown> | null | undefined,
  previous: Record<string, unknown> | null | undefined,
): { key: string; before: unknown; after: unknown }[] {
  if (!current) return [];
  const keys = new Set([
    ...Object.keys(current),
    ...Object.keys(previous || {}),
  ]);
  return [...keys]
    .filter((key) => !same(current[key], previous?.[key]))
    .sort()
    .map((key) => ({ key, before: previous?.[key], after: current[key] }));
}

/** Settings-lost RECOVERY as the server detects it (rev2_commands.rs
 * `settings_lost`): `mram:"recovery"` with any latched error but 3. The
 * logger runs on firmware defaults and does not log until it is sent
 * settings. err 3 is the read-only RECOVERY that refuses settings. */
export function settingsLost(
  health: Record<string, unknown> | null | undefined,
): boolean {
  return health?.mram === "recovery" && health.err !== 3;
}

/** Editor drafts holding every key of `settings` (a generation the logger
 * acknowledged), with a delayed start that has already passed sent as 0,
 * as the server's automatic restore does. */
export function restoreDrafts(
  settings: Record<string, unknown>,
  now: number,
): Record<string, string> {
  const drafts: Record<string, string> = {};
  for (const field of SETTING_FIELDS) {
    if (!(field.key in settings)) continue;
    const value = settings[field.key];
    drafts[field.key] =
      field.key === "start" && typeof value === "number" && value <= now
        ? "0"
        : settingText(value);
  }
  return drafts;
}
