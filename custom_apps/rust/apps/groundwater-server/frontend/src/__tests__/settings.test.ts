import { describe, expect, it } from "vitest";
import {
  SETTING_DEFAULTS,
  SETTING_FIELDS,
  changedSettings,
  parseSetting,
  settingsDiff,
  validateSettings,
} from "../settings";

const NOW = 1763300000;

// Mirrors src/settings.rs tests so the browser refuses exactly what the
// server refuses.
describe("revision 2 settings validation", () => {
  it("accepts the contract examples", () => {
    expect(
      validateSettings(
        { read_s: 900, send_s: 86400, hi: 10.5, hi_hys: 0.2 },
        NOW,
      ),
    ).toEqual([]);
    expect(
      validateSettings(
        {
          gps_mode: 2,
          gps_val: 3600,
          tilt_mode: 3,
          fac: [0, 1, 1, 0],
          lo: null,
          loc: "Bore 7",
          text: "line one\nline two",
          utc_off: 600,
          listen_s: 120,
          attempts: 5,
          led: 1,
          partial: 0,
          tap: 1,
          tap_sens: 10,
          gps_sens: 0,
          start: 0,
        },
        NOW,
      ),
    ).toEqual([]);
  });

  it("enforces every bound with the server's wording", () => {
    const cases: [Record<string, unknown>, string][] = [
      [{ read_s: 59 }, "read_s must be an integer in 60..2332800"],
      [{ read_s: 2332801 }, "read_s"],
      [{ read_s: 900.5 }, "read_s"],
      [{ send_s: 299 }, "send_s"],
      [{ gps_mode: 4 }, "gps_mode"],
      [{ gps_mode: 1, gps_val: 0 }, "gps_val must be an integer in 1..255"],
      [
        { gps_mode: 2, gps_val: 599 },
        "gps_val must be an integer in 600..2332800",
      ],
      [{ gps_mode: 1 }, "gps_mode 1 requires gps_val"],
      [{ tilt_val: 5 }, "tilt_val needs tilt_mode"],
      [{ start: NOW - 1 }, "start must be 0 (none) or a future UTC time"],
      [{ start: NOW }, "start must be 0"],
      [{ start: NOW + 367 * 86400 }, "start must be at most 366 days ahead"],
      [{ fac: [1, 2, 3] }, "fac must be [a,p,b,c]"],
      [{ fac: [1, 2, 3, "x"] }, "fac must be a finite number"],
      [{ fac: [1, 2, 3, 1e39] }, "fac must be a finite number"],
      [{ tap: 2 }, "tap"],
      [{ tap_sens: 0 }, "tap_sens"],
      [{ gps_sens: 11 }, "gps_sens"],
      [{ hi: "10" }, "hi must be a finite number"],
      [{ lo_hys: -0.1 }, "lo_hys must be ≥ 0"],
      [{ loc: "x".repeat(33) }, "loc is 33 bytes, limit 32"],
      [{ loc: "é".repeat(17) }, "loc is 34 bytes"],
      [{ proj: "a\nb" }, "proj allows at most 0 newline(s)"],
      [{ text: "a\nb\nc" }, "text allows at most 1 newline(s)"],
      [{ text: "tab\there" }, "text contains a control character"],
      [{ loc: "\u0085" }, "loc contains a control character"],
      [{ utc_off: -721 }, "utc_off"],
      [{ attempts: 11 }, "attempts"],
      [{ listen_s: 9 }, "listen_s"],
      [{ foo: 1 }, "foo is not a contract setting"],
    ];
    for (const [args, fragment] of cases) {
      const errors = validateSettings(args, NOW);
      expect(
        errors.some((e) => e.includes(fragment)),
        `${JSON.stringify(args)} → ${errors.join("; ")}`,
      ).toBe(true);
    }
    expect(validateSettings({}, NOW)).toEqual([
      "settings must name at least one key",
    ]);
    expect(validateSettings([1], NOW)).toEqual([
      "settings must be a JSON object",
    ]);
  });

  it("accepts boundary values and mode values without a range", () => {
    expect(
      validateSettings(
        {
          read_s: 60,
          send_s: 2332800,
          utc_off: -720,
          listen_s: 600,
          gps_mode: 0,
          gps_val: 0,
          tilt_mode: 3,
          start: NOW + 1,
          lo_hys: 0,
        },
        NOW,
      ),
    ).toEqual([]);
    expect(validateSettings({ gps_mode: 0 }, NOW)).toEqual([]);
  });

  it("covers every contract key with a default", () => {
    expect(SETTING_FIELDS.map((f) => f.key).sort()).toEqual(
      Object.keys(SETTING_DEFAULTS).sort(),
    );
  });
});

describe("settings editing", () => {
  const field = (key: string) => SETTING_FIELDS.find((f) => f.key === key)!;
  it("parses editor text into the key's JSON type", () => {
    expect(parseSetting(field("read_s"), " 900 ")).toBe(900);
    expect(parseSetting(field("read_s"), "9.5")).toBe("9.5");
    expect(parseSetting(field("lo"), "")).toBeNull();
    expect(parseSetting(field("hi_hys"), "0.25")).toBe(0.25);
    expect(parseSetting(field("fac"), "0, 1, 2.5, -0.25")).toEqual([
      0, 1, 2.5, -0.25,
    ]);
    expect(parseSetting(field("text"), "a\r\nb")).toBe("a\nb");
  });
  it("sends only changed keys and keeps GPS mode and value together", () => {
    const effective = { read_s: 900, gps_mode: 2, gps_val: 3600, hi: null };
    expect(changedSettings({ read_s: "900", hi: "" }, effective)).toEqual({});
    expect(changedSettings({ read_s: "1800" }, effective)).toEqual({
      read_s: 1800,
    });
    expect(changedSettings({ gps_val: "7200" }, effective)).toEqual({
      gps_mode: 2,
      gps_val: 7200,
    });
    // Unknown effective keys compare against firmware defaults.
    expect(changedSettings({ tap_sens: "5" }, {})).toEqual({});
  });
  it("diffs generations", () => {
    expect(
      settingsDiff({ read_s: 900, hi: 10 }, { read_s: 3600, hi: 10 }),
    ).toEqual([{ key: "read_s", before: 3600, after: 900 }]);
    expect(settingsDiff({ a: 1 }, null)).toEqual([
      { key: "a", before: undefined, after: 1 },
    ]);
  });
});
