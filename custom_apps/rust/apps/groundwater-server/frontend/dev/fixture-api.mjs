// Development-only HTTP fixtures for UI review. Never imported by src or the
// production build. Node is used here to exercise the frontend's pinned toolchain.
import { createServer } from "node:http";
const ids = ["8F3A21C04B9E77A1D25C01FE", "A13A21C04B9E77A1D25C01AB"];
let role = "operator",
  mode = "normal",
  commands = [],
  nextId = 1;
const now = () => new Date().toISOString();
const observation = () => ({
  recorded_at: new Date(Date.now() - 3 * 60000).toISOString(),
  received_at: now(),
  gwl: 4.23,
  gwl_text: "04.23",
  battery_v: 3.72,
  rssi: 68,
  solar_v: 3,
  time_quality: "plausible",
  time_reason: "Device-local timestamp normalized with enrollment offset.",
  quality_reasons: [],
  duplicate_outcome: "first",
  interpretation_version: "v21-1",
});
const device = (id) => ({
  device_id: id,
  display_name:
    id === ids[0]
      ? "North bore · Upper field"
      : "South bore · Long location name for responsive review",
  profile: "V21",
  clock_policy: "fixed_offset",
  revoked: false,
  status: id === ids[0] ? "awake" : "asleep",
  status_reason: "Attributed device-status message",
  last_received_at: now(),
  observation_count: 1200,
  conflict_count: 2,
  latest_received: observation(),
  latest_plausible: observation(),
  min_limit: 2,
  max_limit: 5,
  location_id: "A1",
  sensor_id: "B1",
  local_offset_min: 300,
  last_ready_at: new Date(Date.now() - 60000).toISOString(),
  desired_config: { Flush_mqtt: "1" },
  applied_config: { Flush_mqtt: "0" },
  open_alert_count: 1,
});
const alerts = (id) => [
  {
    id: 1,
    device_id: id,
    kind: "ABOVE_MAX",
    state: "open",
    trigger_value: 5.6,
    opened_at: new Date(Date.now() - 7200000).toISOString(),
    resolved_at: null,
  },
  {
    id: 2,
    device_id: id,
    kind: "BELOW_MIN",
    state: "resolved",
    trigger_value: 1.2,
    opened_at: new Date(Date.now() - 36000000).toISOString(),
    resolved_at: new Date(Date.now() - 30000000).toISOString(),
  },
];
const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const send = (body, code = 200) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (url.pathname === "/__fixture") {
    role = url.searchParams.get("role") || "operator";
    mode = url.searchParams.get("mode") || "normal";
    send({ role, mode });
    return;
  }
  if (url.pathname === "/api/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    });
    res.write(": fixture heartbeat\n\n");
    const timer = setInterval(() => res.write(": heartbeat\n\n"), 15000);
    req.on("close", () => clearInterval(timer));
    return;
  }
  if (mode === "error") {
    send({ error: "Fixture service unavailable" }, 503);
    return;
  }
  if (url.pathname === "/api/status") {
    send({
      user: { username: "fixture-user", role },
      broker: { configured: true, connected: true },
      service: "groundwater-server",
      ingest: {},
    });
    return;
  }
  if (url.pathname === "/api/devices") {
    send({ devices: mode === "empty" ? [] : ids.map(device) });
    return;
  }
  const id =
    url.pathname.split("/")[3] || url.searchParams.get("device") || ids[0];
  if (req.method === "POST") {
    if (role !== "operator") {
      send({ error: "operator required" }, 403);
      return;
    }
    let text = "";
    for await (const chunk of req) text += chunk;
    const body = JSON.parse(text || "{}");
    if (url.pathname.endsWith("/cancel")) {
      const command = commands.find(
        (c) => c.id === Number(url.pathname.split("/")[5]),
      );
      if (command) command.state = "cancelled";
      send({ command });
      return;
    }
    const command = {
      id: nextId++,
      device_id: id,
      kind: body.config ? "project_settings" : body.kind,
      payload: body.config || body.payload,
      state: "queued",
      requested_by: "fixture-user",
      created_at: now(),
      sent_at: null,
      acked_at: null,
      ack_payload: null,
    };
    commands.unshift(command);
    send({ command });
    return;
  }
  if (url.pathname.startsWith("/api/devices/")) {
    send({ device: device(id) });
    return;
  }
  if (url.pathname === "/api/alerts") {
    send({
      alerts: alerts(id).filter(
        (a) => a.state === url.searchParams.get("state"),
      ),
    });
    return;
  }
  if (url.pathname === "/api/commands") {
    send({ commands: commands.filter((c) => c.device_id === id) });
    return;
  }
  if (url.pathname === "/api/series") {
    const from = Date.parse(url.searchParams.get("from")),
      to = Date.parse(url.searchParams.get("to"));
    const points =
      mode === "empty"
        ? []
        : Array.from({ length: 96 }, (_, i) => ({
            recorded_at: new Date(from + ((to - from) * i) / 95).toISOString(),
            gwl: 3.7 + Math.sin(i / 10),
            gwl_text: null,
            battery_v: 3.6 + i / 1000,
            rssi: 65 + Math.sin(i / 4) * 10,
            sample_count: 5,
            conflict: i === 10,
          })).filter((_, i) => i < 40 || i > 48);
    send({
      series: {
        device_id: id,
        points,
        min_gwl: 2.7,
        max_gwl: 4.7,
        bucket_minutes: Number(url.searchParams.get("bucket")),
        truncated: false,
      },
    });
    return;
  }
  if (url.pathname === "/api/messages") {
    if (role !== "operator") {
      send({ error: "operator required" }, 403);
      return;
    }
    send({
      deliveries: [
        {
          received_at: now(),
          topic: "azman1/feeds/testresults",
          kind: "test",
          device_id: id,
          claimed_device_id: null,
          qos: 1,
          payload: "~ GPS passed\nX SD card unavailable",
          state: "accepted",
          reason: null,
          detail: null,
          time_quality: null,
          duplicate_outcome: null,
          source_profile: "V21",
          binding_key: "fixture",
        },
      ],
    });
    return;
  }
  if (url.pathname === "/api/export") {
    res.writeHead(200, {
      "Content-Type": "text/csv",
      "Content-Disposition": 'attachment; filename="groundwater.csv"',
    });
    res.end("recorded_at,gwl\n2026-10-28T00:00:00Z,4.23\n");
    return;
  }
  send({ error: "not found" }, 404);
});
server.listen(5188, "127.0.0.1", () =>
  process.stdout.write("Development fixture API on 127.0.0.1:5188\n"),
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => server.close(() => process.exit()));
