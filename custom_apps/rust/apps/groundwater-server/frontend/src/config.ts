export const CONFIG_FIELDS = [
  [
    "NA",
    "Reconnect attempts",
    "Positive integer; firmware may ignore this field",
  ],
  ["l", "Location ID", "Up to 9 ASCII bytes"],
  ["id", "Sensor ID", "Up to 12 ASCII bytes"],
  ["lf", "Logging interval", "Hours:minutes; minimum 0:3"],
  ["sf", "Sending interval", "Hours:minutes; minimum 0:5 (firmware uses H:M)"],
  [
    "fac",
    "Calibration factors",
    "Four coefficients: a.pp,b.pp,c.pp,d.pp; negatives .00 only",
  ],
  ["fst", "Future start", "Device-local time: YYYY-MM-DDTHH:MM:SS"],
  ["mG", "Minimum level (m)", "Integer, raw datum"],
  ["MG", "Maximum level (m)", "Integer, greater than minimum"],
  ["S", "Feature flags", "Four bits: GPS, SD overwrite, LED, logger button"],
  [
    "ltost",
    "Local UTC offset",
    "Hours:minutes; positive offsets only in this firmware",
  ],
] as const;
export type ConfigKey = (typeof CONFIG_FIELDS)[number][0];
export type FirmwareConfig = Record<ConfigKey, string>;
export const emptyConfig = (): FirmwareConfig =>
  Object.fromEntries(CONFIG_FIELDS.map(([key]) => [key, ""])) as FirmwareConfig;

export function buildConfig(config: FirmwareConfig) {
  const errors: Partial<Record<ConfigKey | "payload", string>> = {};
  const ordered = emptyConfig();
  for (const [key] of CONFIG_FIELDS) {
    const value = config[key];
    ordered[key] = value;
    if (!value) errors[key] = "Required: the firmware needs all eleven keys.";
    else if (!/^[a-zA-Z0-9._,:-]+$/.test(value))
      errors[key] =
        "Use ASCII letters, digits, dot, underscore, comma, colon or hyphen.";
  }
  const setError = (key: ConfigKey, message: string) => {
    if (!errors[key]) errors[key] = message;
  };
  if (!/^\d+$/.test(config.NA) || +config.NA < 1 || +config.NA > 255)
    setError("NA", "Enter an integer from 1 to 255.");
  if (config.l.length > 9) setError("l", "Maximum 9 bytes.");
  if (config.id.length > 12) setError("id", "Maximum 12 bytes.");
  for (const key of ["lf", "sf", "ltost"] as const) {
    const match = /^(\d{1,3}):(\d{1,2})$/.exec(config[key]);
    const hours = match ? +match[1] : NaN,
      minutes = match ? +match[2] : NaN;
    if (!match || hours > 23 || minutes > 59)
      setError(key, "Use H:M with minutes 0–59 and valid nonnegative hours.");
    else if (key !== "ltost" && hours * 60 + minutes < (key === "lf" ? 3 : 5))
      setError(key, `Minimum interval is ${key === "lf" ? 3 : 5} minutes.`);
  }
  const factors = config.fac.split(",");
  if (
    factors.length !== 4 ||
    factors.some((factor) => {
      const match = /^(-?\d+)\.(\d{2})$/.exec(factor);
      return (
        !match ||
        +match[1] < -32768 ||
        +match[1] > 32767 ||
        (match[1].startsWith("-") && match[2] !== "00")
      );
    })
  )
    setError(
      "fac",
      "Use four coefficients with two fractional digits; negatives must end in .00 (firmware sign limitation).",
    );
  const date = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(config.fst)
    ? new Date(config.fst + "Z")
    : new Date(NaN);
  if (
    !Number.isFinite(date.getTime()) ||
    date.toISOString().slice(0, 19) !== config.fst ||
    !config.fst.startsWith("20")
  )
    setError("fst", "Enter a real date in 2000–2099 as YYYY-MM-DDTHH:MM:SS.");
  for (const key of ["mG", "MG"] as const)
    if (!/^-?\d+$/.test(config[key]) || Math.abs(+config[key]) > 1000)
      setError(key, "Enter an integer from -1000 to 1000 metres.");
  if (!errors.mG && !errors.MG && +config.mG >= +config.MG)
    setError("mG", "Minimum must be less than maximum.");
  if (!/^[01]{4}$/.test(config.S))
    setError("S", "Enter exactly four 0/1 flags.");
  const json = JSON.stringify(ordered);
  for (const [key] of CONFIG_FIELDS) {
    const offset = json.indexOf(key) + key.length + 3;
    if (json.slice(offset).split('"')[0] !== config[key])
      setError(
        key,
        "A value contains a key substring that hijacks firmware extraction. Change that value.",
      );
  }
  const bytes = new TextEncoder().encode(json).length;
  if (bytes > 150)
    errors.payload =
      "Compact payload exceeds 150 bytes. Shorten values before queuing.";
  return { json, bytes, errors };
}

// Verified against V2.1 Core/Src/danger_commands.c cfg_key_map.
export const CFG_KEYS = [
  "Flush_mqtt",
  "Flush_sd",
  "Self_test",
  "Get_debuging",
  "Get_Status",
  "Fetch_File_List",
  "Fetch_File_Chunk",
  "CLEAR_ERROR_LATCH",
  "Disable_Logging",
] as const;
export const DANGER_COMMANDS = [
  "Factory reset",
  "Wipe_MRAM",
  "Wipe_sd",
  "Disable Logging",
  "Reboot",
  "Erase keys",
] as const;

export const CFG_LABELS: Record<(typeof CFG_KEYS)[number], string> = {
  Flush_mqtt: "Flush MQTT data",
  Flush_sd: "Flush SD data",
  Self_test: "Run self-test",
  Get_debuging: "Request debugging",
  Get_Status: "Request device status",
  Fetch_File_List: "Request file list",
  Fetch_File_Chunk: "Request file chunk",
  CLEAR_ERROR_LATCH: "Clear error latch",
  Disable_Logging: "Stop / allow logging",
};
