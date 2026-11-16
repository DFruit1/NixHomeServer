// Revision 2 read views: overview, health, events, location/tilt and tests.
import { component$, useComputed$, useSignal } from "@builder.io/qwik";
import { number, query, stamp } from "./api";
import { TimeChart, type Sample } from "./chart";
import {
  EVENT_CATEGORIES,
  categoryLabel,
  eventCategory,
  eventSummary,
  eventTone,
  groupByDay,
  sensorProblem,
  sensorStatusName,
  testStatusFlags,
  latchedErrorText,
} from "./events";
import {
  bytes,
  csqText,
  duration,
  fraction,
  humanize,
  millivolts,
  percent,
  relative,
  secondsLeft,
  show,
} from "./format";
import {
  distanceM,
  fitBounds,
  formatDistance,
  graticule,
  osmLink,
  projector,
  validFix,
  type Fix,
} from "./geo";
import { deviceProblems } from "./attention";
import { devicePath, useJson, useNow } from "./hooks";
import type {
  Alert,
  Device,
  DeviceEvent,
  HealthSample,
  Position,
  TestResult,
  TiltSample,
} from "./types";
import { LoadState, Meter, TableRegion, When, WindowPicker } from "./widgets";

type ViewProps = { device: Device; revision: number; operator: boolean };
/** `openAlerts`: this device's open alerts, named in "Needs attention". */
type OverviewProps = ViewProps & { openAlerts?: Alert[] };

const viewHref = (device: string, view: string) =>
  `#${query({ device, view })}`;

const PRESENCE_TEXT: Record<string, string> = {
  awake: "Awake: commands are delivered now",
  asleep: "Asleep: commands wait in the broker session",
  offline: "Offline: connection lost without a clean sleep (Last Will)",
  stale: "Stale: missed its expected connection",
  receiving: "Receiving traffic without wake-state evidence",
  never: "No traffic yet",
  revoked: "Enrollment revoked",
};

/** Latest health object as a description list (used by Overview). */
export const HealthFacts = component$<{
  health: Record<string, unknown> | null | undefined;
  at: string | null | undefined;
}>((props) => {
  const h = props.health || {};
  const unsaved = fraction(h.unsaved, h.usable);
  return (
    <>
      <dl class="facts">
        <div>
          <dt>Battery</dt>
          <dd>{millivolts(h.bat_mv)}</dd>
        </div>
        <div>
          <dt>Solar</dt>
          <dd>{millivolts(h.sol_mv)}</dd>
        </div>
        <div>
          <dt>Signal (CSQ)</dt>
          <dd>{csqText(h.csq)}</dd>
        </div>
        <div>
          <dt>SD card</dt>
          <dd class={h.sd && h.sd !== "ok" ? "error-text" : ""}>
            {show(h.sd)}
            {typeof h.sd_free_mb === "number" &&
              ` · ${h.sd_free_mb.toLocaleString()} MB free`}
          </dd>
        </div>
        <div>
          <dt>MRAM ring</dt>
          <dd class={h.mram && h.mram !== "ok" ? "error-text" : ""}>
            {h.mram === "locked" ? "locked (Tail Lock)" : show(h.mram)}
          </dd>
        </div>
        <div>
          <dt>Logging</dt>
          <dd class={h.log === "off" ? "error-text" : ""}>{show(h.log)}</dd>
        </div>
        <div>
          <dt>Settings generation</dt>
          <dd>{show(h.gen)}</dd>
        </div>
        <div>
          <dt>Latched error</dt>
          <dd class={h.err ? "error-text" : ""}>{latchedErrorText(h.err)}</dd>
        </div>
        <div>
          <dt>Health received</dt>
          <dd>{stamp(props.at)}</dd>
        </div>
      </dl>
      <div class="field">
        <span>Unsaved data in the MRAM ring</span>
        <Meter
          value={unsaved}
          label="Unsaved bytes of usable ring capacity"
          text={`${bytes(h.unsaved)} of ${bytes(h.usable)} usable (${percent(unsaved)})`}
        />
      </div>
    </>
  );
});

export const Overview = component$<OverviewProps>((props) => {
  const now = useNow(1000);
  const d = props.device;
  const info = (d.info || {}) as Record<string, unknown>;
  const expected = d.expected_contact_at || d.next_contact_at;
  const left = secondsLeft(expected, now.value);
  const problems = deviceProblems(d, props.openAlerts);
  return (
    <>
      {problems.length > 0 && (
        <section aria-labelledby="attention-heading" class="challenge">
          <h2 id="attention-heading" class="error-text">
            Needs attention
          </h2>
          <ul class="problem-list">
            {problems.map((problem) => (
              <li key={problem.text}>
                <a href={viewHref(d.device_id, problem.view || "overview")}>
                  {problem.text}
                </a>
              </li>
            ))}
          </ul>
        </section>
      )}
      <section aria-labelledby="presence-heading">
        <h2 id="presence-heading">Presence</h2>
        <p>
          <strong
            class={["stale", "offline"].includes(d.status) ? "error-text" : ""}
          >
            {PRESENCE_TEXT[d.status] || d.status}
          </strong>
          <small>{d.status_reason}</small>
        </p>
        <dl class="facts">
          <div>
            <dt>Link state</dt>
            <dd>
              {d.link_state || "—"}
              {d.link_retained ? " (retained)" : ""}
              {d.link_reason ? ` · ${d.link_reason}` : ""}
            </dd>
          </div>
          <div>
            <dt>Since</dt>
            <dd>
              <When at={d.link_state_at} now={now.value} />
            </dd>
          </div>
          <div>
            <dt>Next expected connection</dt>
            <dd>
              {stamp(expected)}
              {left != null && (
                <small>
                  {left > 0
                    ? `in ${duration(left * 1000)}`
                    : `overdue by ${duration(now.value - Date.parse(expected!))}`}
                </small>
              )}
            </dd>
          </div>
          <div>
            <dt>Stale after</dt>
            <dd>
              {stamp(d.stale_after)}
              {d.stale_after && (
                <small>{relative(d.stale_after, now.value)}</small>
              )}
            </dd>
          </div>
          <div>
            <dt>Listen window</dt>
            <dd>
              {d.listen_window_s != null ? `${d.listen_window_s} s` : "—"}
            </dd>
          </div>
          <div>
            <dt>Last seen</dt>
            <dd>
              <When at={d.last_received_at} now={now.value} />
            </dd>
          </div>
        </dl>
      </section>
      <section aria-labelledby="health-heading">
        <h2 id="health-heading">Latest health</h2>
        {d.health ? (
          <HealthFacts health={d.health} at={d.health_at} />
        ) : (
          <p class="empty">No health heartbeat received yet.</p>
        )}
        <p>
          <a href={viewHref(d.device_id, "health")}>Health history</a>
        </p>
      </section>
      <section aria-labelledby="info-heading">
        <h2 id="info-heading">Device information</h2>
        <dl class="facts">
          {[
            [
              "Firmware",
              `${show(info.fw)}${info.build ? ` (${String(info.build)})` : ""}`,
            ],
            ["Hardware", show(info.hw)],
            ["Protocol / schema", `${show(info.proto)} / ${show(info.schema)}`],
            ["IMEI", show(info.imei)],
            ["ICCID", show(info.iccid)],
            ["Modem", show(info.modem)],
            ["Network profile", show(info.net)],
            [
              "Stream encoding",
              info.stream === "hex"
                ? "hex (fallback, half-size batches)"
                : show(info.stream),
            ],
            ["Last reset cause", show(info.reset)],
            ["Boot count", show(d.boot_count)],
            ["MCU UID", show(info.uid)],
            ["Info received", stamp(d.info_at)],
          ].map(([label, value]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd
                class={
                  label === "MCU UID" || label === "ICCID" || label === "IMEI"
                    ? "mono"
                    : ""
                }
              >
                {value}
              </dd>
            </div>
          ))}
        </dl>
        {info.reset === "wdg" && (
          <p class="notice">
            The last reset was a watchdog reset. Check get_debug for the
            watchdog count and latched error.
          </p>
        )}
      </section>
    </>
  );
});

const toV = (mv: number | null) => (mv == null ? null : mv / 1000);

/** SD or MRAM state across a window of health samples (newest first): the
 * states the charts cannot show. */
export function storageText(
  label: string,
  rows: { recorded_at: string; state: string | null | undefined }[],
) {
  const known = rows.filter((r) => r.state);
  if (known.length === 0) return `${label} not reported`;
  const bad = known.filter((r) => r.state !== "ok");
  if (bad.length === 0) return `${label} ok in every sample`;
  const states = [...new Set(bad.map((r) => r.state))].join("/");
  return `${label} ${states} in ${bad.length} of ${known.length} samples, last ${stamp(bad[0].recorded_at)}; latest ${known[0].state}`;
}

export const HealthView = component$<ViewProps>((props) => {
  const hours = useSignal(168);
  const url = useComputed$(() => {
    void props.revision;
    const from = new Date(Date.now() - hours.value * 3600000).toISOString();
    return devicePath(
      props.device.device_id,
      `/health?${query({ from, limit: 5000 })}`,
    );
  });
  const rev = useComputed$(() => props.revision);
  const { state } = useJson<{ health: HealthSample[] }>(url, rev);
  const rows = state.data?.health || [];
  const ordered = [...rows].reverse();
  const t = (r: HealthSample) => Date.parse(r.recorded_at);
  const to = Date.now(),
    from = to - hours.value * 3600000;
  const gap = Math.max(
    60,
    ((props.device.settings?.send_s as number | undefined) || 86400) / 30,
  );
  const series = (pick: (r: HealthSample) => number | null): Sample[] =>
    ordered.map((r) => [t(r), pick(r)]);
  return (
    <section aria-labelledby="health-history">
      <div class="section-heading">
        <h2 id="health-history">Health history</h2>
        <WindowPicker hours={hours} label="Health window" />
      </div>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No health heartbeats in this window."
        label="health"
      />
      {rows.length > 0 && (
        <>
          <p>
            {storageText(
              "SD",
              rows.map((r) => ({ recorded_at: r.recorded_at, state: r.sd })),
            )}
            {" · "}
            {storageText(
              "MRAM",
              rows.map((r) => ({ recorded_at: r.recorded_at, state: r.mram })),
            )}
          </p>
          <div class="secondary-charts">
            <TimeChart
              title="Battery"
              unit="V · alert threshold in Alerts"
              series={[
                {
                  name: "Battery",
                  cls: "battery_v",
                  samples: series((r) => toV(r.bat_mv)),
                },
              ]}
              from={from}
              to={to}
              gapMinutes={gap}
              nonNegative
            />
            <TimeChart
              title="Solar"
              unit="V"
              series={[
                {
                  name: "Solar",
                  cls: "solar_v",
                  samples: series((r) => toV(r.sol_mv)),
                },
              ]}
              from={from}
              to={to}
              gapMinutes={gap}
              nonNegative
            />
            <TimeChart
              title="Signal"
              unit="CSQ 0–31 (99 unknown is omitted)"
              series={[
                {
                  name: "CSQ",
                  cls: "rssi",
                  samples: series((r) =>
                    r.csq == null || r.csq === 99 ? null : r.csq,
                  ),
                },
              ]}
              from={from}
              to={to}
              gapMinutes={gap}
              nonNegative
              digits={0}
            />
            <TimeChart
              title="Unsaved ring data"
              unit="KiB, unsaved vs usable"
              series={[
                {
                  name: "Unsaved",
                  cls: "gwl",
                  samples: series((r) =>
                    r.unsaved == null ? null : r.unsaved / 1024,
                  ),
                },
                {
                  name: "Usable",
                  cls: "usable",
                  samples: series((r) =>
                    r.usable == null ? null : r.usable / 1024,
                  ),
                },
              ]}
              from={from}
              to={to}
              gapMinutes={gap}
              nonNegative
              digits={0}
            />
          </div>
          <details>
            <summary>Health samples ({rows.length})</summary>
            <TableRegion label="Health samples" bounded>
              <table>
                <thead>
                  <tr>
                    <th>Recorded</th>
                    <th>Battery / solar</th>
                    <th>CSQ</th>
                    <th>SD / MRAM</th>
                    <th>Unsaved / usable</th>
                    <th>Log / gen / err</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id}>
                      <td>
                        {stamp(r.recorded_at)}
                        <small>
                          {r.source} · time from {r.time_source}
                        </small>
                      </td>
                      <td>
                        {millivolts(r.bat_mv)} / {millivolts(r.sol_mv)}
                      </td>
                      <td>{csqText(r.csq)}</td>
                      <td>
                        {show(r.sd)}
                        {r.sd_free_mb != null && (
                          <small>{r.sd_free_mb} MB free</small>
                        )}
                        <small>MRAM {show(r.mram)}</small>
                      </td>
                      <td>
                        {bytes(r.unsaved)} / {bytes(r.usable)}
                      </td>
                      <td>
                        {show(r.log)} · {show(r.settings_gen)} · {show(r.err)}
                        {r.next_contact_at && (
                          <small>next {stamp(r.next_contact_at)}</small>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </TableRegion>
          </details>
        </>
      )}
    </section>
  );
});

function eventTime(e: DeviceEvent) {
  if (e.recorded_at) {
    // Loggers report at their next connection; say when it arrived if late.
    const lag = Date.parse(e.received_at) - Date.parse(e.recorded_at);
    return `${stamp(e.recorded_at)}${lag > 15 * 60000 ? ` · reported ${duration(lag)} later` : ""}`;
  }
  if (e.time_valid === false && e.time_rel_s != null)
    return `Clock not set · ${duration(e.time_rel_s * 1000)} after boot · received ${stamp(e.received_at)}`;
  return `Received ${stamp(e.received_at)}`;
}

export const EventsView = component$<ViewProps>((props) => {
  const hours = useSignal(720);
  const source = useSignal("");
  const category = useSignal("");
  const url = useComputed$(() => {
    void props.revision;
    const from = new Date(Date.now() - hours.value * 3600000).toISOString();
    return devicePath(
      props.device.device_id,
      `/events?${query({ from, source: source.value, limit: 2000 })}`,
    );
  });
  const rev = useComputed$(() => props.revision);
  const { state } = useJson<{ events: DeviceEvent[] }>(url, rev);
  const at = (e: DeviceEvent) => Date.parse(e.recorded_at || e.received_at);
  const all = [...(state.data?.events || [])].sort((a, b) => at(b) - at(a));
  const events = category.value
    ? all.filter((e) => eventCategory(e) === category.value)
    : all;
  const exportFrom = new Date(Date.now() - hours.value * 3600000).toISOString();
  return (
    <section aria-labelledby="events-heading">
      <div class="section-heading">
        <h2 id="events-heading">Events</h2>
        <a
          class="button"
          href={devicePath(
            props.device.device_id,
            `/events/export?${query({ from: exportFrom })}`,
          )}
        >
          Export JSON
        </a>
      </div>
      <div class="toolbar">
        <label class="field" for="event-category">
          Category
          <select
            id="event-category"
            value={category.value}
            onChange$={(_, el) => {
              category.value = el.value;
            }}
          >
            <option value="">All categories</option>
            {EVENT_CATEGORIES.map(([key, label]) => (
              <option key={key} value={key}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label class="field" for="event-source">
          Source
          <select
            id="event-source"
            value={source.value}
            onChange$={(_, el) => {
              source.value = el.value;
            }}
          >
            <option value="">All sources</option>
            <option value="record">Ring records (authoritative)</option>
            <option value="alert">Alerts channel copies</option>
            <option value="server">Server actions</option>
          </select>
        </label>
      </div>
      <WindowPicker
        hours={hours}
        options={[24, 168, 720, 4320]}
        label="Event window"
      />
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={events.length === 0}
        emptyText="No events match these filters."
        label="events"
      />
      {groupByDay(events).map((group) => (
        <div key={group.day} class="timeline-day">
          <h3>{group.day}</h3>
          <ol class="timeline">
            {group.events.map((e) => (
              <li key={e.id} class={`timeline-item tone-${eventTone(e)}`}>
                <div class="timeline-head">
                  <strong>{humanize(e.event)}</strong>
                  <span class="badge">{categoryLabel(eventCategory(e))}</span>
                  <span class="badge">{e.source}</span>
                  {e.source === "alert" && (
                    <span class="badge">
                      {e.confirmed_by_record
                        ? "confirmed by ring record"
                        : "awaiting ring record"}
                    </span>
                  )}
                </div>
                <p class="timeline-summary">{eventSummary(e)}</p>
                <small>
                  {eventTime(e)}
                  {e.seq != null && ` · seq ${e.seq}`}
                  {e.log_id != null && ` · log ${e.log_id}`}
                  {e.time_source && ` · time ${e.time_source}`}
                </small>
                <details>
                  <summary>Details</summary>
                  <pre>{JSON.stringify(e.details, null, 2)}</pre>
                </details>
              </li>
            ))}
          </ol>
        </div>
      ))}
    </section>
  );
});

/** Ring records (Type 3) code the fix 0 none, 1 2D, 2 3D; the `gps` JSON
 * sends that plus one (NMEA style, 3 = 3D). The API stores both as sent. */
/** Type 4 tilt record reason (design extract). */
const TILT_REASON: Record<number, string> = {
  1: "scheduled",
  2: "test",
  3: "commanded",
};

export function fixText(p: Pick<Position, "fix" | "source">) {
  if (p.fix == null) return "fix unknown";
  const fix = p.source === "json" ? p.fix - 1 : p.fix;
  return ["no fix", "2D", "3D"][fix] ?? `fix ${p.fix}`;
}
const PLOT_W = 640,
  PLOT_H = 360;

export const LocationView = component$<ViewProps>((props) => {
  const rev = useComputed$(() => props.revision);
  const positionsUrl = useComputed$(() =>
    devicePath(props.device.device_id, "/positions?limit=2000"),
  );
  const tiltUrl = useComputed$(() =>
    devicePath(props.device.device_id, "/tilt?limit=2000"),
  );
  const positions = useJson<{ positions: Position[] }>(positionsUrl, rev);
  const tilt = useJson<{ tilt: TiltSample[] }>(tiltUrl, rev);
  const rows = positions.state.data?.positions || [];
  const fixes = rows.filter((p) => validFix(p)) as (Position & Fix)[];
  const latest = fixes[0];
  const bounds = fitBounds(fixes);
  const proj = bounds ? projector(bounds, PLOT_W, PLOT_H) : null;
  const lat = bounds ? graticule(bounds.minLat, bounds.maxLat) : null;
  const lon = bounds ? graticule(bounds.minLon, bounds.maxLon) : null;
  const track = proj
    ? [...fixes]
        .reverse()
        .map(
          (f, i) =>
            `${i ? "L" : "M"}${proj.x(f.lon).toFixed(1)},${proj.y(f.lat).toFixed(1)}`,
        )
        .join(" ")
    : "";
  // Whether it moved: the fix in this list farthest from the latest one.
  const farthest = latest
    ? fixes.reduce<{ fix: (typeof fixes)[number]; m: number } | null>(
        (best, f) => {
          const m = distanceM(f, latest as Fix);
          return !best || m > best.m ? { fix: f, m } : best;
        },
        null,
      )
    : null;
  const tiltRows = tilt.state.data?.tilt || [];
  const tiltOrdered = [...tiltRows].reverse().filter((r) => r.recorded_at);
  const tFrom = tiltOrdered.length
    ? Date.parse(tiltOrdered[0].recorded_at!)
    : Date.now() - 86400000;
  const tTo = tiltOrdered.length
    ? Math.max(
        Date.parse(tiltOrdered[tiltOrdered.length - 1].recorded_at!),
        tFrom + 3600000,
      )
    : Date.now();
  const id = props.device.device_id;
  return (
    <>
      <section aria-labelledby="position-heading">
        <div class="section-heading">
          <h2 id="position-heading">Positions</h2>
          <div class="toolbar">
            <a
              class="button"
              href={devicePath(id, "/positions/export?format=geojson")}
            >
              GeoJSON
            </a>
            <a
              class="button"
              href={devicePath(id, "/positions/export?format=json")}
            >
              JSON
            </a>
          </div>
        </div>
        <LoadState
          loading={positions.state.loading && !positions.state.data}
          error={positions.state.error}
          empty={rows.length === 0}
          emptyText="No GPS positions recorded."
          label="positions"
        />
        {latest && proj && lat && lon && bounds && (
          <>
            <dl class="facts">
              <div>
                <dt>Latest fix</dt>
                <dd class="mono">
                  {latest.lat.toFixed(6)}, {latest.lon.toFixed(6)}
                </dd>
              </div>
              <div>
                <dt>Recorded</dt>
                <dd>{stamp(latest.recorded_at || latest.received_at)}</dd>
              </div>
              <div>
                <dt>Quality</dt>
                <dd>
                  {fixText(latest)} · HDOP {number(latest.hdop, 1)} ·{" "}
                  {latest.satellites ?? "?"} satellites
                </dd>
              </div>
              <div>
                <dt>Farthest earlier fix</dt>
                <dd>
                  {farthest && farthest.m > 0
                    ? `${formatDistance(farthest.m)} away, ${stamp(farthest.fix.recorded_at || farthest.fix.received_at)}`
                    : "—"}
                </dd>
              </div>
            </dl>
            <p>
              <a
                href={osmLink(latest)}
                target="_blank"
                rel="noopener noreferrer"
              >
                Open the latest fix on OpenStreetMap
              </a>{" "}
              <span class="muted">(external site)</span>
            </p>
            <figure class="position-plot">
              <svg
                viewBox={`0 0 ${PLOT_W} ${PLOT_H}`}
                role="img"
                aria-label={`${fixes.length} GPS fixes plotted on a latitude/longitude grid. The table lists every fix.`}
              >
                <rect
                  class="plot-frame"
                  x="0"
                  y="0"
                  width={PLOT_W}
                  height={PLOT_H}
                />
                {lat.lines.map((v) => (
                  <g key={`lat${v}`}>
                    <line
                      class="grid-line"
                      x1="0"
                      x2={PLOT_W}
                      y1={proj.y(v)}
                      y2={proj.y(v)}
                    />
                    <text x="4" y={Math.max(12, proj.y(v) - 3)}>
                      {v.toFixed(lat.digits)}°
                    </text>
                  </g>
                ))}
                {lon.lines.map((v) => (
                  <g key={`lon${v}`}>
                    <line
                      class="grid-line"
                      y1="0"
                      y2={PLOT_H}
                      x1={proj.x(v)}
                      x2={proj.x(v)}
                    />
                    <text x={proj.x(v) + 3} y={PLOT_H - 4}>
                      {v.toFixed(lon.digits)}°
                    </text>
                  </g>
                ))}
                <path class="track-line" d={track} />
                {fixes.map((f) => (
                  <circle
                    key={f.id}
                    class="fix-dot"
                    cx={proj.x(f.lon)}
                    cy={proj.y(f.lat)}
                    r="3"
                  >
                    <title>{`${stamp(f.recorded_at || f.received_at)}: ${f.lat.toFixed(6)}, ${f.lon.toFixed(6)}`}</title>
                  </circle>
                ))}
                <circle
                  class="fix-latest"
                  cx={proj.x(latest.lon)}
                  cy={proj.y(latest.lat)}
                  r="7"
                />
              </svg>
              <figcaption class="chart-key">
                Grid in decimal degrees, equal metres on both axes (≈{" "}
                {formatDistance(proj.metresPerPixel * 100)} per 100 px). Large
                ring: latest fix. Map tiles are not loaded: the app allows only
                same-origin content and works offline.
              </figcaption>
            </figure>
          </>
        )}
        {rows.length > 0 && (
          <details>
            <summary>Position records ({rows.length})</summary>
            <TableRegion label="Position records" bounded>
              <table>
                <thead>
                  <tr>
                    <th>Recorded</th>
                    <th>Latitude, longitude</th>
                    <th>Fix / HDOP / sats</th>
                    <th>Altitude</th>
                    <th>Step</th>
                    <th>Source</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((p, i) => {
                    const prev = rows[i + 1];
                    return (
                      <tr key={p.id}>
                        <td>{stamp(p.recorded_at || p.received_at)}</td>
                        <td class="mono">
                          {validFix(p)
                            ? `${p.lat!.toFixed(6)}, ${p.lon!.toFixed(6)}`
                            : "no position"}
                        </td>
                        <td>
                          {fixText(p)} / {number(p.hdop, 1)} /{" "}
                          {p.satellites ?? "—"}
                        </td>
                        <td>{p.alt_m != null ? `${p.alt_m} m` : "—"}</td>
                        <td>
                          {prev && validFix(p) && validFix(prev)
                            ? formatDistance(distanceM(prev as Fix, p as Fix))
                            : "—"}
                        </td>
                        <td>
                          {p.source}
                          {p.seq != null && <small>seq {p.seq}</small>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </TableRegion>
          </details>
        )}
      </section>
      <section aria-labelledby="tilt-heading">
        <h2 id="tilt-heading">Tilt history</h2>
        <LoadState
          loading={tilt.state.loading && !tilt.state.data}
          error={tilt.state.error}
          empty={tiltRows.length === 0}
          emptyText="No tilt records."
          label="tilt"
        />
        {tiltOrdered.length > 0 && (
          <TimeChart
            title="Pitch and roll"
            unit="degrees"
            series={[
              {
                name: "Pitch",
                cls: "gwl",
                samples: tiltOrdered.map((r) => [
                  Date.parse(r.recorded_at!),
                  r.pitch_deg,
                ]),
              },
              {
                name: "Roll",
                cls: "rssi",
                samples: tiltOrdered.map((r) => [
                  Date.parse(r.recorded_at!),
                  r.roll_deg,
                ]),
              },
            ]}
            from={tFrom}
            to={tTo}
            gapMinutes={60 * 24 * 30}
            digits={1}
          />
        )}
        {tiltRows.length > 0 && (
          <TableRegion label="Tilt records" bounded>
            <table>
              <thead>
                <tr>
                  <th>Recorded</th>
                  <th>Pitch / roll</th>
                  <th>Acceleration x / y / z (mg)</th>
                  <th>Accelerometer / reason</th>
                </tr>
              </thead>
              <tbody>
                {tiltRows.map((r) => (
                  <tr key={r.id}>
                    <td>
                      {r.recorded_at ? stamp(r.recorded_at) : "Clock not set"}
                      {r.seq != null && <small>seq {r.seq}</small>}
                    </td>
                    <td>
                      {number(r.pitch_deg, 1)}° / {number(r.roll_deg, 1)}°
                    </td>
                    <td class="numeric">
                      {r.accel_x_mg ?? "—"} / {r.accel_y_mg ?? "—"} /{" "}
                      {r.accel_z_mg ?? "—"}
                    </td>
                    <td>
                      {r.accel_status === 0
                        ? "ok"
                        : r.accel_status === 1
                          ? "no response"
                          : show(r.accel_status)}{" "}
                      / {TILT_REASON[r.reason ?? -1] ?? show(r.reason)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableRegion>
        )}
      </section>
    </>
  );
});

const DETAIL_KEYS = ["sd", "sim", "net", "mqtt", "gps", "epd", "acc", "mram"];

export const TestsView = component$<ViewProps>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() =>
    devicePath(props.device.device_id, "/tests?limit=200"),
  );
  const { state } = useJson<{ tests: TestResult[] }>(url, rev);
  const rows = state.data?.tests || [];
  return (
    <section aria-labelledby="tests-heading">
      <h2 id="tests-heading">Self-test results</h2>
      <p class="muted">
        Queue a remote self-test from Commands (self_test). Button, power-on and
        scheduled tests arrive too.
      </p>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No self-test results."
        label="tests"
      />
      {rows.length > 0 && (
        <TableRegion label="Self-test results">
          <table>
            <thead>
              <tr>
                <th>Test</th>
                <th>Sensor</th>
                <th>Power / signal</th>
                <th>Subsystems</th>
                <th>Warnings</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((t) => {
                const flags = testStatusFlags(t.status_bits);
                const warn = Array.isArray(t.details?.warn)
                  ? (t.details.warn as unknown[])
                  : [];
                return (
                  <tr key={t.id}>
                    <td>
                      <strong class={t.ok === false ? "error-text" : ""}>
                        {t.ok == null ? "unknown" : t.ok ? "passed" : "failed"}
                      </strong>
                      <small>
                        {stamp(t.recorded_at || t.received_at)} ·{" "}
                        {t.trigger || "—"}
                        {t.command_id != null && ` · command #${t.command_id}`}
                      </small>
                      <small>{t.source}</small>
                    </td>
                    <td>
                      {sensorProblem(t.sensor_status) ? (
                        <span class="error-text">
                          {sensorProblem(t.sensor_status)}
                        </span>
                      ) : t.level == null ? (
                        "level unknown"
                      ) : (
                        `${number(t.level, 3)} m`
                      )}
                      <small>
                        {t.sensor_mv ?? "—"} mV · {number(t.sensor_ma, 2)} mA
                      </small>
                      {!sensorProblem(t.sensor_status) && (
                        <small>
                          sensor {sensorStatusName(t.sensor_status)}
                        </small>
                      )}
                    </td>
                    <td>
                      {millivolts(t.battery_mv)} / {millivolts(t.solar_mv)}
                      <small>CSQ {csqText(t.csq)}</small>
                    </td>
                    <td>
                      {t.status_bits != null && (
                        <>
                          <small>
                            Passed: {flags.passed.join(", ") || "none"}
                          </small>
                          {flags.failed.length > 0 && (
                            <small class="error-text">
                              Not passed: {flags.failed.join(", ")}
                            </small>
                          )}
                        </>
                      )}
                      <small>
                        {DETAIL_KEYS.filter((k) => t.details?.[k] != null)
                          .map((k) => `${k} ${String(t.details[k])}`)
                          .join(" · ")}
                      </small>
                    </td>
                    <td>{warn.length ? warn.map(String).join("; ") : "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </TableRegion>
      )}
    </section>
  );
});
