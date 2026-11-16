// Pure validation for the operations API (enrollment, alert policies,
// level limits, datums). Ranges mirror frontend/README.md "Operations API".

export const DEVICE_ID = /^[0-9A-Fa-f]{24}$/;
export const USERNAME = /^[A-Za-z0-9._@-]{1,128}$/;
export const TOPIC = /^[A-Za-z0-9_-]{1,64}$/;

export interface EnrollDraft {
  device_id: string;
  display_name: string;
  profile: string;
  clock_policy: string;
  local_offset_min: string;
  location_id: string;
  sensor_id: string;
  project: string;
  notes: string;
  bindings: string;
  viewers: string;
}

export const emptyEnroll = (): EnrollDraft => ({
  device_id: "",
  display_name: "",
  profile: "V22",
  clock_policy: "utc",
  local_offset_min: "",
  location_id: "",
  sensor_id: "",
  project: "",
  notes: "",
  bindings: "gwl/v1",
  viewers: "",
});

export const viewerList = (text: string) =>
  text
    .split(/[\s,]+/)
    .map((name) => name.trim())
    .filter(Boolean);

/** Validates an enrollment form; returns field errors and the request body. */
export function buildEnrollment(draft: EnrollDraft) {
  const errors: Partial<Record<keyof EnrollDraft, string>> = {};
  const id = draft.device_id.trim();
  if (!DEVICE_ID.test(id))
    errors.device_id = "Enter the 24 hexadecimal characters of the DeviceID.";
  if (!["V22", "V21"].includes(draft.profile))
    errors.profile =
      "Only V22 and V21 enroll here; legacy shared-topic units stay an SQL procedure.";
  const policy = draft.profile === "V22" ? "utc" : draft.clock_policy;
  if (!["utc", "local-offset", "unknown"].includes(policy))
    errors.clock_policy = "Choose utc, local-offset or unknown.";
  let offset: number | null = null;
  if (policy === "local-offset") {
    const text = draft.local_offset_min.trim();
    offset = /^-?\d+$/.test(text) ? Number(text) : NaN;
    if (!Number.isInteger(offset) || offset < -720 || offset > 840)
      errors.local_offset_min =
        "Local offset needs whole minutes from −720 to 840.";
  }
  if (draft.display_name.length > 120)
    errors.display_name = "Keep the name under 120 characters.";
  const viewers = viewerList(draft.viewers);
  const badViewer = viewers.find((name) => !USERNAME.test(name));
  if (badViewer)
    errors.viewers = `${badViewer} is not a valid username (letters, digits, . _ @ -).`;
  if (!["gwl/v1", "none"].includes(draft.bindings))
    errors.bindings = "Choose gwl/v1 or none.";
  return {
    errors,
    body: {
      device_id: id.toUpperCase(),
      display_name: draft.display_name.trim(),
      profile: draft.profile,
      clock_policy: policy,
      local_offset_min: offset,
      location_id: draft.location_id.trim(),
      sensor_id: draft.sensor_id.trim(),
      project: draft.project.trim(),
      notes: draft.notes,
      bindings: draft.bindings,
      viewers,
    },
  };
}

export const POLICY_FIELDS = [
  ["battery_low_mv", "Battery low (mV)", 3000, 9000],
  ["battery_hys_mv", "Battery clear hysteresis (mV)", 0, 2000],
  ["solar_low_mv", "Solar low (mV)", 0, 30000],
  // Days, despite the name: the server reuses the column (rev2.sql
  // groundwater_power_alerts).
  ["solar_samples", "Days without solar before alert", 1, 10],
  ["stale_margin_min", "Missed-connection margin (min)", 5, 10080],
] as const;
/** What a threshold means where the label alone cannot say it. */
export const POLICY_HINTS: Partial<Record<string, string>> = {
  solar_samples:
    "Alert when no solar reading (health or self-test) in this many days reached Solar low and at least one of them was taken between 09:00 and 15:00 logger local time.",
};
export type PolicyKey = (typeof POLICY_FIELDS)[number][0] | "stale_enabled";
export const POLICY_KEYS: PolicyKey[] = [
  ...POLICY_FIELDS.map(([key]) => key),
  "stale_enabled",
];

/** Policy form strings → request values; "" inherits (null). */
export function buildPolicy(draft: Record<string, string>) {
  const errors: Record<string, string> = {};
  const values: Record<string, number | boolean | null> = {};
  for (const [key, label, min, max] of POLICY_FIELDS) {
    const text = (draft[key] ?? "").trim();
    if (text === "") {
      values[key] = null;
      continue;
    }
    const value = /^\d+$/.test(text) ? Number(text) : NaN;
    if (!Number.isInteger(value) || value < min || value > max)
      errors[key] = `${label} must be a whole number from ${min} to ${max}.`;
    values[key] = value;
  }
  const stale = draft.stale_enabled ?? "";
  values.stale_enabled = stale === "" ? null : stale === "true";
  return { errors, values };
}

export const policyDraft = (
  policy: Record<string, unknown> | null | undefined,
): Record<string, string> =>
  Object.fromEntries(
    POLICY_KEYS.map((key) => [
      key,
      policy?.[key] == null ? "" : String(policy[key]),
    ]),
  );

/** Level limit form → PUT /limits body. */
export function buildLimits(draft: Record<string, string>) {
  const errors: Record<string, string> = {};
  const value = (key: string, nonNegative: boolean) => {
    const text = (draft[key] ?? "").trim();
    if (text === "") return null;
    const n = /^-?\d+(\.\d+)?$/.test(text) ? Number(text) : NaN;
    if (!Number.isFinite(n) || (nonNegative && n < 0))
      errors[key] = nonNegative
        ? "Enter a number ≥ 0 or leave empty."
        : "Enter a number in metres or leave empty.";
    return n;
  };
  const body = {
    min_limit: value("min_limit", false),
    max_limit: value("max_limit", false),
    min_hysteresis: value("min_hysteresis", true),
    max_hysteresis: value("max_hysteresis", true),
  };
  if (
    !errors.min_limit &&
    !errors.max_limit &&
    body.min_limit != null &&
    body.max_limit != null &&
    body.min_limit >= body.max_limit
  )
    errors.min_limit = "The low limit must be below the high limit.";
  return { errors, body };
}

export const DATUM_MODES = [
  ["raw", "Raw level (m of water above sensor)"],
  ["dtw_bgl", "Depth to water below ground (m)"],
  ["rl_ahd", "Water level (m AHD)"],
] as const;
export type DatumMode = (typeof DATUM_MODES)[number][0];

export const datumLabel = (mode: string) =>
  DATUM_MODES.find(([key]) => key === mode)?.[1] || "Raw level";

export const datumUnit = (mode: string) =>
  mode === "dtw_bgl"
    ? "m below ground · depth increases downward"
    : mode === "rl_ahd"
      ? "m AHD"
      : "metres · raw datum";

export interface DatumValues {
  sensor_depth_m: number;
  casing_height_m: number;
  ground_elevation_m: number | null;
}

/** The server's conversion, used for previews in the datum form. */
export function convertLevel(raw: number, datum: DatumValues, mode: string) {
  if (mode === "raw") return raw;
  const dtw = datum.sensor_depth_m - datum.casing_height_m - raw;
  if (mode === "dtw_bgl") return dtw;
  return datum.ground_elevation_m == null
    ? null
    : datum.ground_elevation_m - dtw;
}

export function buildDatum(draft: Record<string, string>) {
  const errors: Record<string, string> = {};
  const number = (key: string, required: boolean) => {
    const text = (draft[key] ?? "").trim();
    if (text === "") {
      if (required) errors[key] = "Required.";
      return null;
    }
    const n = /^-?\d+(\.\d+)?$/.test(text) ? Number(text) : NaN;
    if (!Number.isFinite(n)) errors[key] = "Enter a number in metres.";
    return n;
  };
  const from = draft.effective_from ?? "";
  const at = Date.parse(from);
  if (!Number.isFinite(at)) errors.effective_from = "Choose a date and time.";
  const sensor = number("sensor_depth_m", true);
  if (sensor != null && sensor < 0)
    errors.sensor_depth_m = "Sensor depth below the top of casing is ≥ 0.";
  const body = {
    effective_from: Number.isFinite(at) ? new Date(at).toISOString() : "",
    sensor_depth_m: sensor,
    casing_height_m: number("casing_height_m", true),
    ground_elevation_m: number("ground_elevation_m", false),
    note: (draft.note ?? "").trim(),
  };
  return { errors, body };
}
