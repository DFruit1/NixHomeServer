import { afterEach, describe, expect, it, vi } from "vitest";
import { exportUrl, lag, rangeQuery, request } from "../api";
import { chartGeometry } from "../chart";
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
