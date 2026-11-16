import { afterEach, describe, expect, it, vi } from "vitest";
import { exportUrl, lag, rangeQuery, request } from "../api";
import { chartGeometry, faultSpans, levelSeries } from "../chart";
import type { SeriesPoint } from "../types";
afterEach(() => vi.unstubAllGlobals());
describe("API boundary", () => {
  it("exports observation CSV over the applied UTC range", () => {
    const url = new URL(
      exportUrl("A/B", "2026-10-28T00:00:00Z", "2026-10-29T00:00:00Z"),
      "http://localhost",
    );
    expect(url.pathname).toBe("/api/export");
    expect(url.searchParams.get("device")).toBe("A/B");
    expect(url.searchParams.get("from")).toBe("2026-10-28T00:00:00.000Z");
    expect(url.searchParams.get("format")).toBe("csv");
    expect(() => rangeQuery("A", "invalid", "", 15)).toThrow();
    expect(() => rangeQuery("A", "2026-10-29", "2026-10-28", 15)).toThrow();
  });
  it("reports permission and session failures, preserving same-origin credentials", async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(
        new Response('{"error":"forbidden"}', { status: 403 }),
      );
    vi.stubGlobal("fetch", fetch);
    await expect(request("/api/commands")).rejects.toThrow("permission");
    expect(fetch.mock.calls[0][1].credentials).toBe("same-origin");
    fetch.mockResolvedValue(new Response("", { status: 401 }));
    await expect(request("/api/status")).rejects.toThrow("session expired");
  });
  it("keeps device time and delivery time distinct", () => {
    expect(lag(null, "2026-10-28T00:00:00Z")).toBe("Unknown clock");
    expect(lag("2026-10-29T00:00:00Z", "2026-10-28T00:00:00Z")).toBe(
      "Clock ahead",
    );
    expect(lag("2026-10-27T00:00:00Z", "2026-10-28T00:00:00Z")).toBe("1.0 d");
  });
});
describe("history rendering", () => {
  it("breaks lines across gaps and includes threshold bands in the scale", () => {
    const point = (minutes: number, value: number): SeriesPoint => ({
      recorded_at: new Date(minutes * 60000).toISOString(),
      gwl: value,
      gwl_text: null,
      battery_v: null,
      rssi: null,
      sample_count: 1,
      conflict: false,
    });
    const geometry = chartGeometry(
      [point(0, 2), point(3, 3), point(60, 4)],
      "gwl",
      0,
      60 * 60000,
      6,
      [0, 10],
    );
    expect(geometry.path.match(/M/g)).toHaveLength(2);
    expect(geometry.gaps).toBe(1);
    expect(geometry.min).toBeLessThan(0);
    expect(geometry.max).toBeGreaterThan(10);
  });
  it("draws samples isolated by gaps as dots instead of nothing", () => {
    const point = (minutes: number, value: number): SeriesPoint => ({
      recorded_at: new Date(minutes * 60000).toISOString(),
      gwl: value,
      gwl_text: null,
      battery_v: null,
      rssi: null,
      sample_count: 1,
      conflict: false,
    });
    // Hourly samples on a 30-minute gap threshold: three separate runs.
    const geometry = chartGeometry(
      [point(0, 1), point(60, 2), point(120, 3)],
      "gwl",
      0,
      120 * 60000,
      30,
    );
    expect(geometry.path.match(/M/g)).toHaveLength(3);
    expect(geometry.path.match(/l0,0/g)).toHaveLength(3);
    expect(geometry.gaps).toBe(2);
  });
  it("does not bridge missing secondary measurements", () => {
    const points = [1, null, 3].map((value, i) => ({
      recorded_at: new Date(i * 60000).toISOString(),
      gwl: 1,
      battery_v: value,
      rssi: null,
      sample_count: 1,
      conflict: false,
      gwl_text: null,
    }));
    expect(
      chartGeometry(points, "battery_v", 0, 120000, 6).path.match(/M/g),
    ).toHaveLength(2);
  });
});
describe("level series faults", () => {
  const at = (minutes: number) => new Date(minutes * 60000).toISOString();
  const point = (
    minutes: number,
    gwl: number,
    extra: Partial<SeriesPoint> = {},
  ): SeriesPoint => ({
    recorded_at: at(minutes),
    gwl,
    gwl_text: null,
    battery_v: null,
    rssi: null,
    sample_count: 1,
    conflict: false,
    sensor_status: 0,
    fault_count: 0,
    fault_kinds: [],
    ...extra,
  });
  it("never draws or scales a raw fault reading as a level", () => {
    const points = [
      point(0, 10),
      point(15, 25.1, {
        sensor_status: 3,
        sample_count: 0,
        fault_count: 1,
        fault_kinds: ["over-range"],
      }),
      point(30, 11),
    ];
    const geometry = chartGeometry(points, "gwl", 0, 30 * 60000, 60);
    // The fault splits the line and stays out of the axis range.
    expect(geometry.path.match(/M/g)).toHaveLength(2);
    expect(geometry.max).toBeLessThan(12);
    const { samples, marks } = levelSeries({
      points,
      bucket_minutes: 0,
      faults: [
        {
          recorded_at: at(15),
          sensor_status: 3,
          fault_count: 1,
          fault_kinds: ["over-range"],
          valid_count: 0,
        },
      ],
    });
    expect(samples[1][1]).toBeNull();
    expect(marks[0].text).toBe(
      "out of range: possible sensor failure (over-range, above 20 mA)",
    );
  });
  it("keeps a mixed bucket's valid average and marks fault-only buckets", () => {
    const points = [
      point(0, 10, { sensor_status: null, sample_count: 3 }),
      point(60, 10.5, {
        sensor_status: null,
        sample_count: 2,
        fault_count: 1,
        fault_kinds: ["over-range"],
      }),
      point(180, 11, { sensor_status: null, sample_count: 4 }),
    ];
    const faults = [
      { at: 60, valid: 2, kinds: ["over-range"] },
      { at: 120, valid: 0, kinds: ["no-sensor", "under-range"] },
      { at: 240, valid: 0, kinds: ["adc-fault"] },
      { at: 300, valid: 0, kinds: ["adc-fault"] },
    ].map((f) => ({
      recorded_at: at(f.at),
      sensor_status: null,
      fault_count: 2,
      fault_kinds: f.kinds,
      valid_count: f.valid,
    }));
    const series = { points, faults, bucket_minutes: 60 };
    const { samples, marks } = levelSeries(series);
    expect(samples.map(([, v]) => v)).toEqual([10, 10.5, 11]);
    expect(marks.filter((m) => m.valid > 0)).toHaveLength(1);
    expect(marks[1].text).toBe(
      "out of range: possible sensor failure (under-range); sensor fault: no-sensor",
    );
    // 120 stands alone (valid buckets either side); 240 and 300 merge into
    // one span covering both buckets.
    const spans = faultSpans(marks, samples, 60, 120);
    expect(spans.map((s) => [s.from / 60000, s.to / 60000, s.count])).toEqual([
      [120, 180, 2],
      [240, 360, 4],
    ]);
    // A silence longer than the gap threshold stays a gap.
    expect(faultSpans(marks, samples, 60, 30)).toHaveLength(3);
  });
});
