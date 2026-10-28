import { describe, expect, it } from "vitest";
import { buildConfig, emptyConfig } from "../config";

const valid = () => ({
  NA: "3",
  l: "A1",
  id: "B1",
  lf: "0:3",
  sf: "0:5",
  fac: "1.00,1.00,0.00,0.00",
  fst: "2026-10-28T00:00:00",
  mG: "0",
  MG: "9",
  S: "1010",
  ltost: "5:0",
});

describe("firmware configuration safety", () => {
  it("requires deliberate entries for all eleven keys", () => {
    expect(Object.keys(buildConfig(emptyConfig()).errors)).toHaveLength(11);
  });
  it("serializes all strings in safe order without spaces", () => {
    const result = buildConfig(valid());
    expect(result.errors).toEqual({});
    expect(result.json).toBe(JSON.stringify(valid()));
    expect(result.bytes).toBeLessThanOrEqual(150);
    expect(result.json.indexOf('"l"')).toBeLessThan(
      result.json.indexOf('"lf"'),
    );
  });
  it("rejects parser collisions, escaping and oversized identifiers", () => {
    for (const value of ["SITE", "well", 'a"b', "1234567890", "é".repeat(9)]) {
      expect(
        Object.keys(buildConfig({ ...valid(), l: value }).errors).length,
      ).toBeGreaterThan(0);
    }
  });
  it("enforces logging and sending minimum intervals", () => {
    expect(
      buildConfig({ ...valid(), lf: "0:2", sf: "0:4" }).errors,
    ).toMatchObject({ lf: expect.any(String), sf: expect.any(String) });
  });
  it("rejects invalid calendars, calibration, noninteger thresholds and flags", () => {
    expect(
      buildConfig({
        ...valid(),
        fst: "2026-02-30T00:00:00",
        fac: "1.2,3.4",
        mG: "0.5",
        S: "1210",
      }).errors,
    ).toMatchObject({
      fst: expect.any(String),
      fac: expect.any(String),
      mG: expect.any(String),
      S: expect.any(String),
    });
  });
  it("matches server calibration and numeric limits", () => {
    for (const fac of [
      "1.0,1.00,0.00,0.00",
      "-1.25,1.00,0.00,0.00",
      "-0.25,1.00,0.00,0.00",
      "32768.00,1.00,0.00,0.00",
    ])
      expect(buildConfig({ ...valid(), fac }).errors.fac).toBeTruthy();
    expect(
      buildConfig({ ...valid(), fac: "-1.00,1.00,0.00,0.00" }).errors.fac,
    ).toBeUndefined();
    expect(
      buildConfig({
        ...valid(),
        lf: "24:0",
        ltost: "24:0",
        MG: "1001",
        NA: "256",
      }).errors,
    ).toMatchObject({
      lf: expect.any(String),
      ltost: expect.any(String),
      MG: expect.any(String),
      NA: expect.any(String),
    });
  });
  it("checks ordered thresholds and total UTF8 payload length", () => {
    expect(buildConfig({ ...valid(), mG: "10" }).errors.mG).toBeTruthy();
    const result = buildConfig({
      ...valid(),
      l: "123456789",
      id: "123456789012",
      fac: "100.99,100.99,100.99,100.99",
    });
    expect(result.bytes).toBeGreaterThan(150);
    expect(result.errors.payload).toBeTruthy();
  });
});
