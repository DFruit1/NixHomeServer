// What needs an operator's attention on a logger right now, from the fields
// the device list already returns. Each item names the view that explains it.
import { observationProblem } from "./events";
import type { Device } from "./types";

export interface Problem {
  text: string;
  /** Device view that shows the evidence. */
  view: string;
}

export function deviceProblems(device: Device): Problem[] {
  if (device.revoked) return [];
  const problems: Problem[] = [];
  const rev2 = device.capabilities?.protocol === 2;
  if (device.status === "stale")
    problems.push({ text: "missed its expected connection", view: "" });
  if (device.status === "offline")
    problems.push({
      text: "connection lost without a clean sleep",
      view: "",
    });
  if (device.open_alert_count > 0)
    problems.push({
      text: `${device.open_alert_count} open alert${device.open_alert_count === 1 ? "" : "s"}`,
      view: "alerts",
    });
  const sensor = observationProblem(device.latest_received);
  if (sensor)
    problems.push({ text: `latest reading ${sensor}`, view: "history" });
  const h = (device.health || {}) as Record<string, unknown>;
  if (rev2 && device.health) {
    if (typeof h.sd === "string" && h.sd !== "ok")
      problems.push({ text: `SD card ${h.sd}`, view: "health" });
    if (h.mram === "locked")
      problems.push({
        text: "MRAM ring locked (Tail Lock): logging stops until data is saved",
        view: "health",
      });
    else if (typeof h.mram === "string" && h.mram !== "ok")
      problems.push({ text: `MRAM ${h.mram}`, view: "health" });
    if (h.log === "off") problems.push({ text: "logging off", view: "health" });
    if (typeof h.err === "number" && h.err !== 0)
      problems.push({ text: `latched error ${h.err}`, view: "health" });
  }
  if ((device.pending_challenge_count || 0) > 0)
    problems.push({
      text: "danger command waiting for confirmation",
      view: "commands",
    });
  if ((device.open_gap_count || 0) > 0)
    problems.push({
      text: `${device.open_gap_count} open data gap${device.open_gap_count === 1 ? "" : "s"}`,
      view: "stream",
    });
  if (device.clock_change_unverified)
    problems.push({ text: "clock offset change unverified", view: "history" });
  return problems;
}
