import { describe, expect, it } from "vitest";
import { seriesGeometry } from "../chart";
import { opArgs } from "../commands";
import {
  eventCategory,
  eventSummary,
  eventTone,
  groupByDay,
  testStatusFlags,
} from "../events";
import {
  countdown,
  csqText,
  duration,
  expiryError,
  fraction,
  relative,
  secondsLeft,
} from "../format";
import {
  distanceM,
  fitBounds,
  graticule,
  osmLink,
  projector,
  validFix,
} from "../geo";
import {
  buildDatum,
  buildEnrollment,
  buildLimits,
  buildPolicy,
  convertLevel,
  datumLabel,
  emptyEnroll,
} from "../ops";
import { deviceViews } from "../routes";
import type { DeviceEvent } from "../types";

const event = (e: Partial<DeviceEvent>): DeviceEvent => ({
  id: 1,
  source: "record",
  event: "impact",
  log_id: null,
  seq: null,
  record_type: null,
  recorded_at: "2026-11-16T02:00:00Z",
  time_valid: true,
  time_rel_s: null,
  time_source: "rtc",
  received_at: "2026-11-16T02:05:00Z",
  details: {},
  confirmed_by_record: null,
  ...e,
});

describe("event timeline", () => {
  it("categorises record, alert and server events", () => {
    expect(eventCategory(event({ event: "gwl_alarm_enter" }))).toBe("alarm");
    expect(eventCategory(event({ event: "impact", source: "alert" }))).toBe(
      "tamper",
    );
    expect(eventCategory(event({ event: "orientation" }))).toBe("orientation");
    expect(eventCategory(event({ event: "gps_moved" }))).toBe("gps");
    expect(eventCategory(event({ event: "tail_lock" }))).toBe("tail-lock");
    expect(eventCategory(event({ event: "data_gap" }))).toBe("gap");
    expect(eventCategory(event({ event: "sensor_fault" }))).toBe("sensor");
    expect(eventCategory(event({ event: "power_critical" }))).toBe("power");
    expect(eventCategory(event({ event: "storage_warning" }))).toBe("storage");
    expect(eventCategory(event({ event: "clock_set" }))).toBe("clock");
    expect(
      eventCategory(event({ event: "danger_executed", source: "server" })),
    ).toBe("server");
    expect(eventCategory(event({ event: "unknown_record" }))).toBe("other");
  });
  it("marks exits and restored storage as recovery", () => {
    expect(
      eventTone(event({ event: "sensor_fault", details: { state: "exit" } })),
    ).toBe("ok");
    expect(
      eventTone(
        event({ event: "storage_warning", details: { kind: "sd_full" } }),
      ),
    ).toBe("problem");
    expect(
      eventTone(
        event({ event: "storage_warning", details: { kind: "sd_restored" } }),
      ),
    ).toBe("ok");
  });
  it("summarises record and alert-copy field names", () => {
    expect(
      eventSummary(
        event({
          event: "gwl_alarm_enter",
          details: { limit: "high", level: 12.5, threshold: 10.5 },
        }),
      ),
    ).toContain("12.500 m, threshold 10.500 m");
    expect(
      eventSummary(
        event({
          event: "gwl_alarm_exit",
          details: { limit: "low", lvl: 1, thr: 2 },
        }),
      ),
    ).toContain("cleared");
    expect(
      eventSummary(
        event({
          event: "power_critical",
          details: { state: "enter", bat_mv: 6550 },
        }),
      ),
    ).toContain("6.55 V");
  });
  it("groups consecutive events by local day", () => {
    const groups = groupByDay([
      event({ id: 1, recorded_at: "2026-11-16T12:00:00Z" }),
      event({ id: 2, recorded_at: "2026-11-16T11:00:00Z" }),
      event({ id: 3, recorded_at: null, received_at: "2026-11-10T11:00:00Z" }),
    ]);
    expect(groups.map((g) => g.events.length)).toEqual([2, 1]);
  });
  it("decodes the Type 5 test bitfield", () => {
    const flags = testStatusFlags(0b1000000011);
    expect(flags.passed).toEqual(["sensor", "sd", "solar"]);
    expect(flags.failed).toContain("sim");
  });
});

describe("time formatting", () => {
  const now = Date.parse("2026-11-16T00:00:00Z");
  it("formats durations and relative times", () => {
    expect(duration(0)).toBe("now");
    expect(duration(45000)).toBe("45 s");
    expect(duration(3 * 3600000 + 5 * 60000)).toBe("3 h 5 min");
    expect(duration(50 * 3600000)).toBe("2 d 2 h");
    expect(relative("2026-11-16T00:10:00Z", now)).toBe("in 10 min");
    expect(relative("2026-11-15T23:00:00Z", now)).toBe("1 h ago");
    expect(relative(null, now)).toBe("—");
  });
  it("counts down nonce windows and never goes negative", () => {
    expect(secondsLeft("2026-11-16T00:02:00Z", now)).toBe(120);
    expect(secondsLeft("2026-11-15T23:59:00Z", now)).toBe(0);
    expect(secondsLeft(null, now)).toBeNull();
    expect(countdown(119)).toBe("1:59");
    expect(countdown(null)).toBe("—");
  });
  it("labels CSQ with dBm and clamps fractions", () => {
    expect(csqText(21)).toBe("21 (≈ -71 dBm)");
    expect(csqText(99)).toBe("99 (unknown)");
    expect(fraction(1234, 122368)).toBeCloseTo(0.01);
    expect(fraction(5, 0)).toBeNull();
    expect(expiryError(59)).not.toBe("");
    expect(expiryError(2592000)).toBe("");
  });
});

describe("offline position plot", () => {
  const a = { lat: -33.8688197, lon: 151.2092955 };
  const b = { lat: -33.8698197, lon: 151.2092955 };
  it("measures great-circle distance", () => {
    expect(distanceM(a, b)).toBeCloseTo(111.2, 0);
    expect(distanceM(a, a)).toBe(0);
  });
  it("rejects null island and out-of-range fixes", () => {
    expect(validFix({ lat: 0, lon: 0 })).toBe(false);
    expect(validFix({ lat: 91, lon: 0 })).toBe(false);
    expect(validFix({ lat: null, lon: 1 })).toBe(false);
    expect(validFix(a)).toBe(true);
  });
  it("fits padded bounds and projects inside the box with square metres", () => {
    const bounds = fitBounds([a])!;
    expect(bounds.maxLat - bounds.minLat).toBeGreaterThan(0.0004);
    const wide = fitBounds([a, b])!;
    const p = projector(wide, 640, 360);
    for (const fix of [a, b]) {
      expect(p.x(fix.lon)).toBeGreaterThanOrEqual(0);
      expect(p.x(fix.lon)).toBeLessThanOrEqual(640);
      expect(p.y(fix.lat)).toBeGreaterThanOrEqual(0);
      expect(p.y(fix.lat)).toBeLessThanOrEqual(360);
    }
    // North is up.
    expect(p.y(a.lat)).toBeLessThan(p.y(b.lat));
    expect(fitBounds([])).toBeNull();
  });
  it("draws round graticule lines inside the bounds", () => {
    const grid = graticule(-33.871, -33.867);
    expect(grid.lines.length).toBeGreaterThanOrEqual(2);
    expect(grid.lines.every((v) => v >= -33.871 && v <= -33.867)).toBe(true);
    expect(osmLink(a)).toContain("mlat=-33.8688197");
  });
});

describe("operations forms", () => {
  it("validates enrollment like the API", () => {
    const valid = {
      ...emptyEnroll(),
      device_id: "6a1b2c3d4e5f60718293a4b5",
      viewers: "alice, bob",
    };
    const ok = buildEnrollment(valid);
    expect(ok.errors).toEqual({});
    expect(ok.body.device_id).toBe("6A1B2C3D4E5F60718293A4B5");
    expect(ok.body.clock_policy).toBe("utc");
    expect(ok.body.viewers).toEqual(["alice", "bob"]);
    const bad = buildEnrollment({
      ...valid,
      device_id: "XYZ",
      profile: "V21",
      clock_policy: "local-offset",
      local_offset_min: "900",
      viewers: "bad name!",
    });
    expect(Object.keys(bad.errors).sort()).toEqual([
      "device_id",
      "local_offset_min",
      "viewers",
    ]);
    expect(
      buildEnrollment({ ...valid, profile: "ML" }).errors.profile,
    ).toBeTruthy();
  });
  it("builds alert policies with inheritance and ranges", () => {
    const { errors, values } = buildPolicy({
      battery_low_mv: "6900",
      battery_hys_mv: "",
      solar_low_mv: "40000",
      solar_samples: "3",
      stale_margin_min: "4",
      stale_enabled: "false",
    });
    expect(values.battery_low_mv).toBe(6900);
    expect(values.battery_hys_mv).toBeNull();
    expect(values.stale_enabled).toBe(false);
    expect(Object.keys(errors).sort()).toEqual([
      "solar_low_mv",
      "stale_margin_min",
    ]);
    expect(buildPolicy({ stale_enabled: "" }).values.stale_enabled).toBeNull();
  });
  it("orders level limits and rejects negative hysteresis", () => {
    expect(
      buildLimits({ min_limit: "5", max_limit: "2" }).errors.min_limit,
    ).toBeTruthy();
    expect(
      buildLimits({ min_hysteresis: "-1" }).errors.min_hysteresis,
    ).toBeTruthy();
    expect(buildLimits({ min_limit: "", max_limit: "9.5" }).body).toEqual({
      min_limit: null,
      max_limit: 9.5,
      min_hysteresis: null,
      max_hysteresis: null,
    });
  });
  it("converts levels with the documented datum formulas", () => {
    const datum = {
      sensor_depth_m: 42,
      casing_height_m: 0.6,
      ground_elevation_m: 21.3,
    };
    expect(convertLevel(10, datum, "raw")).toBe(10);
    expect(convertLevel(10, datum, "dtw_bgl")).toBeCloseTo(31.4);
    expect(convertLevel(10, datum, "rl_ahd")).toBeCloseTo(-10.1);
    expect(
      convertLevel(10, { ...datum, ground_elevation_m: null }, "rl_ahd"),
    ).toBeNull();
    expect(datumLabel("dtw_bgl")).toContain("below ground");
    const draft = buildDatum({ effective_from: "", sensor_depth_m: "-1" });
    expect(Object.keys(draft.errors).sort()).toEqual([
      "casing_height_m",
      "effective_from",
      "sensor_depth_m",
    ]);
  });
  it("builds command arguments and refuses partial resend ranges", () => {
    expect(opArgs("flush_mqtt", {})).toEqual({ args: {}, errors: [] });
    expect(
      opArgs("flush_mqtt", { log_id: "1", from_seq: "7" }).errors,
    ).toHaveLength(1);
    expect(
      opArgs("flush_mqtt", { log_id: "1761000001", from_seq: "7", to_seq: "8" })
        .args,
    ).toEqual({ log_id: 1761000001, from_seq: 7, to_seq: 8 });
    expect(
      opArgs("flush_mqtt", { log_id: "1", from_seq: "9", to_seq: "8" }).errors,
    ).toHaveLength(1);
    expect(opArgs("file_list", { path: "/GWL", page: "0" }).args).toEqual({
      path: "/GWL",
      page: 0,
    });
    expect(
      opArgs("file_chunk", { path: "/a", off: "0", len: "2048" }).errors,
    ).toHaveLength(1);
    expect(opArgs("sync_time", { t: "1" }).args).toEqual({});
  });
  it("shows revision 2 tabs only for revision 2 units and raw logs only to operators", () => {
    expect(deviceViews(true, false)).toContain("settings");
    expect(deviceViews(true, false)).not.toContain("log");
    expect(deviceViews(false, true)).toContain("configuration");
    expect(deviceViews(false, true)).not.toContain("files");
  });
});

describe("generic chart geometry", () => {
  const samples: [number, number | null][] = [
    [0, 1],
    [60000, 2],
    [120000, null],
    [180000, 3],
  ];
  it("breaks on nulls and draws larger values lower when inverted", () => {
    const normal = seriesGeometry(samples, 0, 180000, 10);
    const inverted = seriesGeometry(samples, 0, 180000, 10, [], 960, true);
    expect(normal.path.match(/M/g)).toHaveLength(2);
    expect(normal.y(3)).toBeLessThan(normal.y(1));
    expect(inverted.y(3)).toBeGreaterThan(inverted.y(1));
    expect(inverted.y(inverted.min)).toBeCloseTo(22);
    expect(inverted.y(inverted.max)).toBeCloseTo(222);
  });
});

describe("event summaries read both record and alerts-copy fields", () => {
  it("formats GPS movement from either key set", async () => {
    const { eventSummary } = await import("../events");
    const ring = {
      event: "gps_moved",
      details: { distance_m: 230, threshold_m: 100 },
    };
    const copy = { event: "gps_moved", details: { dist_m: 230, thr_m: 100 } };
    expect(eventSummary(ring)).toBe(eventSummary(copy));
    expect(eventSummary(ring)).toContain("230");
  });
});
