import {
  component$,
  useComputed$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { errorText, lag, number, query, request, stamp } from "./api";
import { HistoryChart, faultAt, faultSpans } from "./chart";
import { devicePath, useJson } from "./hooks";
import { latestRequest } from "./live";
import type {
  Alert,
  Delivery,
  Device,
  DeviceEvent,
  Series,
  SeriesPoint,
} from "./types";
import { datumLabel, datumUnit } from "./ops";
import { alertLabel, alertValue } from "./alerts";
import { deviceProblems } from "./attention";
import { observationProblem } from "./events";
import { csqText, millivolts } from "./format";

export const Fleet = component$<{
  devices: Device[];
  openAlerts?: Alert[];
}>((props) => {
  const search = useSignal("");
  // Loggers that need attention come first; the order is otherwise stable.
  const devices = props.devices
    .filter((device) =>
      `${device.display_name} ${device.device_id} ${device.location_id || ""}`
        .toLowerCase()
        .includes(search.value.toLowerCase()),
    )
    .map((device) => ({
      device,
      problems: deviceProblems(
        device,
        props.openAlerts?.filter((a) => a.device_id === device.device_id),
      ),
    }))
    .sort(
      (a, b) => Number(b.problems.length > 0) - Number(a.problems.length > 0),
    );
  return (
    <section aria-labelledby="fleet-title">
      <div class="section-heading">
        <h1 id="fleet-title">Devices</h1>
        <label class="field" for="device-search">
          Find a device
          <input
            id="device-search"
            type="search"
            value={search.value}
            onInput$={(_, el) => {
              search.value = el.value;
            }}
            placeholder="Name, location or device ID"
          />
        </label>
      </div>
      {props.devices.length === 0 ? (
        <p class="empty">
          No devices are visible to your account. An operator can check
          enrollment and device permissions.
        </p>
      ) : devices.length === 0 ? (
        <p class="empty">No devices match this search.</p>
      ) : (
        <div
          class="table-scroll"
          role="region"
          aria-label="Device fleet"
          tabIndex={0}
        >
          <table class="fleet-table">
            <thead>
              <tr>
                <th>Device</th>
                <th>Groundwater</th>
                <th>Power / signal</th>
                <th>Presence</th>
                <th>Needs attention</th>
              </tr>
            </thead>
            <tbody>
              {devices.map(({ device, problems }) => {
                const reading =
                  device.latest_plausible || device.latest_received;
                const latest = device.latest_received;
                const fault = observationProblem(reading);
                const rev2 = device.capabilities?.protocol === 2;
                const health = (device.health || {}) as Record<string, unknown>;
                const expected =
                  device.expected_contact_at || device.next_contact_at;
                return (
                  <tr key={device.device_id}>
                    <td>
                      <a
                        class="device-link"
                        href={`#${query({ device: device.device_id, view: "history" })}`}
                      >
                        {device.display_name || device.device_id}
                      </a>
                      <small class="mono">{device.device_id}</small>
                      {device.location_id && (
                        <small>Location {device.location_id}</small>
                      )}
                    </td>
                    <td class="numeric">
                      {!reading ? (
                        <span class="muted">No readings yet</span>
                      ) : fault ? (
                        <strong class="error-text">{fault}</strong>
                      ) : (
                        <strong>
                          {reading.gwl == null
                            ? "unknown"
                            : `${number(reading.gwl)} m`}
                        </strong>
                      )}
                      {reading && (
                        <small>
                          {reading.recorded_at
                            ? stamp(reading.recorded_at)
                            : "Clock unverified"}
                        </small>
                      )}
                      {reading && reading.time_quality !== "plausible" && (
                        <small class="error-text">{reading.time_quality}</small>
                      )}
                      {latest?.recorded_at && (
                        <small>
                          delivery lag{" "}
                          {lag(latest.recorded_at, latest.received_at)}
                        </small>
                      )}
                    </td>
                    <td class="numeric">
                      {rev2 ? (
                        <>
                          {millivolts(health.bat_mv)}
                          <small>solar {millivolts(health.sol_mv)}</small>
                          <small>CSQ {csqText(health.csq)}</small>
                        </>
                      ) : (
                        <>
                          {number(reading?.battery_v)} V
                          <small>RSSI {number(reading?.rssi, 0)} (0–100)</small>
                        </>
                      )}
                    </td>
                    <td>
                      <span
                        class={
                          ["stale", "offline"].includes(device.status)
                            ? "error-text"
                            : ""
                        }
                        title={device.status_reason}
                      >
                        {device.status}
                      </span>
                      {rev2 && expected && !device.revoked ? (
                        <small>next connection {stamp(expected)}</small>
                      ) : null}
                      <small>last seen {stamp(device.last_received_at)}</small>
                    </td>
                    <td>
                      {problems.length === 0 ? (
                        <span class="muted">nothing</span>
                      ) : (
                        <ul class="problem-list">
                          {problems.map((problem) => (
                            <li key={problem.text}>
                              <a
                                class="error-text"
                                href={`#${query({ device: device.device_id, view: problem.view })}`}
                              >
                                {problem.text}
                              </a>
                            </li>
                          ))}
                        </ul>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
});

export const AlertList = component$<{ alerts: Alert[]; compact?: boolean }>(
  (props) => {
    const state = useSignal("open");
    const alerts = props.compact
      ? props.alerts.filter((a) => a.state === "open")
      : props.alerts.filter((a) => a.state === state.value);
    return (
      <section>
        <div class="section-heading">
          <h2>{props.compact ? "Open alerts" : "Alerts"}</h2>
          {!props.compact && (
            <label class="field" for="alert-state">
              State
              <select
                id="alert-state"
                value={state.value}
                onChange$={(_, el) => {
                  state.value = el.value;
                }}
              >
                <option value="open">Open</option>
                <option value="resolved">Resolved</option>
              </select>
            </label>
          )}
        </div>
        <p class="muted">
          Alerts resolve automatically. Acknowledge or resolve them on the
          Alerts tab.
        </p>
        {alerts.length === 0 ? (
          <p class="empty">No {props.compact ? "open" : state.value} alerts.</p>
        ) : (
          <div
            class="table-scroll"
            role="region"
            aria-label="Device alerts"
            tabIndex={0}
          >
            <table>
              <thead>
                <tr>
                  <th>Alert</th>
                  <th>Trigger</th>
                  <th>Opened</th>
                  <th>Resolved</th>
                </tr>
              </thead>
              <tbody>
                {alerts.map((alert) => (
                  <tr key={alert.id}>
                    <td>
                      <strong
                        class={alert.state === "open" ? "error-text" : ""}
                      >
                        {alertLabel(alert)}
                      </strong>
                      <small>
                        #{alert.id} · {alert.state}
                      </small>
                    </td>
                    <td>{alertValue(alert)}</td>
                    <td>{stamp(alert.opened_at)}</td>
                    <td>{stamp(alert.resolved_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    );
  },
);

export const History = component$<{
  device: Device;
  series?: Series;
  alerts: Alert[];
  from: string;
  to: string;
  revision: number;
}>((props) => {
  // The series carries no sensor status: out-of-range and fault spans come
  // from the logger's sensor_fault ring records (firmware 2.2 only).
  const faultUrl = useComputed$(() =>
    props.device.capabilities?.protocol === 2
      ? devicePath(
          props.device.device_id,
          `/events?${query({ source: "record", event: "sensor_fault", to: props.to, limit: 1000 })}`,
        )
      : "",
  );
  const rev = useComputed$(() => props.revision);
  const faultEvents = useJson<{ events: DeviceEvent[] }>(faultUrl, rev);
  const faults = faultSpans(faultEvents.state.data?.events || []);
  const bucketMs = (props.series?.bucket_minutes || 0) * 60000;
  const faultOf = (point: SeriesPoint) =>
    faultAt(faults, Date.parse(point.recorded_at), bucketMs);
  const reading = props.device.latest_received;
  const lf = props.device.desired_config?.lf?.split(":").map(Number);
  const expected =
    lf?.length === 2 && lf.every(Number.isFinite) ? lf[0] * 60 + lf[1] : null;
  const readS = props.device.settings?.read_s;
  const rev2Interval =
    typeof readS === "number" && readS > 0 ? Math.ceil(readS / 60) : null;
  const interval = expected ?? rev2Interval;
  const gap = Math.max(props.series?.bucket_minutes || 0, interval || 3) * 2;
  const datum = props.series?.datum || "raw";
  const converted = datum !== "raw";
  const low = converted
    ? (props.series?.limits?.min ?? null)
    : props.device.min_limit;
  const high = converted
    ? (props.series?.limits?.max ?? null)
    : props.device.max_limit;
  const points = props.series?.points || [];
  const levelPoints = points.map((point) =>
    faultOf(point) ? { ...point, gwl: null as unknown as number } : point,
  );
  const faultCount =
    points.length - levelPoints.filter((p) => p.gwl != null).length;
  const hasSolar = points.some((p) => p.solar_v != null);
  const hasBattery = points.some((p) => p.battery_v != null);
  const rev2 = props.device.capabilities?.protocol === 2;
  const hasCsq = points.some((p) => p.csq != null);
  const hasRssi = points.some((p) => p.rssi != null);
  return (
    <>
      {props.series && (
        <section aria-label="Device history">
          <HistoryChart
            title={converted ? datumLabel(datum) : "Groundwater level"}
            unit={datumUnit(datum)}
            metric="gwl"
            points={levelPoints}
            faults={faults}
            from={props.from}
            to={props.to}
            gapMinutes={gap}
            min={low}
            max={high}
            alerts={props.alerts.filter((a) =>
              ["above_max", "below_min"].includes(a.kind),
            )}
            inverted={!!props.series.inverted}
          />
          <p class="chart-key">
            Shaded band: configured limits {low ?? "unset"} to {high ?? "unset"}
            {converted ? " (converted with the latest datum)" : " m"}. Dashed
            vertical lines: alert opened. Line breaks: intervals longer than{" "}
            {gap} min
            {interval ? "" : " (3 min assumed; logging interval unavailable)"}.
            {faults.length > 0 &&
              " Red dotted spans: the logger reported a sensor fault or an out-of-range reading; levels there are not plotted."}
          </p>
          {faultEvents.state.error && (
            <p class="notice error-text" role="alert">
              Sensor fault records could not be loaded (
              {faultEvents.state.error}): out-of-range readings cannot be marked
              on this chart.
            </p>
          )}
          {faultCount > 0 && (
            <p class="notice error-text">
              {faultCount} point{faultCount === 1 ? "" : "s"} in this range{" "}
              {faultCount === 1 ? "falls" : "fall"} inside a sensor fault and{" "}
              {faultCount === 1 ? "is" : "are"} not plotted as a level: out of
              range, possible sensor failure.
            </p>
          )}
          {converted && (props.series.unconverted || 0) > 0 && (
            <p class="notice">
              {props.series.unconverted} reading
              {props.series.unconverted === 1 ? " predates" : "s predate"} the
              first installation datum and are not shown in this view.
            </p>
          )}
          {props.series.truncated && (
            <p class="notice">
              Oldest points were truncated by the server. Choose a shorter range
              or a larger bucket. CSV exports observations for the full range.
            </p>
          )}
          {rev2 && !hasBattery && !hasSolar && !hasCsq ? (
            <p>
              Firmware 2.2 readings carry no power or signal values: battery,
              solar and signal history are on{" "}
              <a
                href={`#${query({ device: props.device.device_id, view: "health" })}`}
              >
                Health
              </a>
              .
            </p>
          ) : (
            <div class="secondary-charts">
              <HistoryChart
                title="Battery"
                unit="V"
                metric="battery_v"
                points={props.series.points}
                from={props.from}
                to={props.to}
                gapMinutes={gap}
              />
              <HistoryChart
                title="Solar"
                unit={hasSolar ? "V" : "V · not reported in this range"}
                metric="solar_v"
                points={props.series.points}
                from={props.from}
                to={props.to}
                gapMinutes={gap}
              />
              {(hasRssi || !hasCsq) && (
                <HistoryChart
                  title="Signal strength"
                  unit="RSSI · 0–100, not dBm"
                  metric="rssi"
                  points={props.series.points}
                  from={props.from}
                  to={props.to}
                  gapMinutes={gap}
                />
              )}
              {hasCsq && (
                <HistoryChart
                  title="Signal quality"
                  unit="CSQ · 0–31"
                  metric="csq"
                  points={props.series.points}
                  from={props.from}
                  to={props.to}
                  gapMinutes={gap}
                />
              )}
            </div>
          )}
          <details>
            <summary>
              Measurement data ({props.series.points.length} points)
            </summary>
            {props.series.points.length === 0 ? (
              <p>No plausible-time observations in this range.</p>
            ) : (
              <div
                class="table-scroll bounded"
                role="region"
                aria-label="Chart measurement data"
                tabIndex={0}
              >
                <table>
                  <thead>
                    <tr>
                      <th>Recorded</th>
                      <th>{converted ? datumLabel(datum) : "GWL (m)"}</th>
                      <th>Battery / solar (V)</th>
                      <th>{hasCsq ? "CSQ" : "RSSI"}</th>
                      <th>Samples / quality</th>
                    </tr>
                  </thead>
                  <tbody>
                    {props.series.points.map((point, index) => (
                      <tr key={`${point.recorded_at}-${index}`}>
                        <td>{stamp(point.recorded_at)}</td>
                        <td>
                          {faultOf(point) ? (
                            <>
                              <span class="error-text">
                                {faultOf(point)!.text}
                              </span>
                              <small>
                                untrusted reading{" "}
                                {number(point.gwl, converted ? 3 : 2)}
                              </small>
                            </>
                          ) : (
                            number(point.gwl, converted ? 3 : 2)
                          )}
                          {converted && point.raw_gwl != null && (
                            <small>raw {number(point.raw_gwl, 3)} m</small>
                          )}
                        </td>
                        <td>
                          {number(point.battery_v)} / {number(point.solar_v)}
                        </td>
                        <td>{number(hasCsq ? point.csq : point.rssi, 0)}</td>
                        <td>
                          {point.sample_count}
                          {point.conflict ? " · conflicting samples" : ""}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </details>
        </section>
      )}
      <section>
        <h2>Clock and delivery quality</h2>
        <p>
          History uses plausible device time normalized to UTC. Uninterpretable
          clocks are excluded; delayed deliveries may contain old readings.
        </p>
        <dl class="facts">
          <div>
            <dt>Latest received</dt>
            <dd>{stamp(reading?.received_at)}</dd>
          </div>
          <div>
            <dt>Device recorded</dt>
            <dd>{stamp(reading?.recorded_at)}</dd>
          </div>
          <div>
            <dt>Delivery lag</dt>
            <dd>{lag(reading?.recorded_at, reading?.received_at)}</dd>
          </div>
          <div>
            <dt>Time quality</dt>
            <dd>{reading?.time_quality || "No readings"}</dd>
          </div>
          <div>
            <dt>Clock policy / offset</dt>
            <dd>
              {props.device.clock_policy} /{" "}
              {props.device.local_offset_min == null
                ? "unknown"
                : `${props.device.local_offset_min} min`}
            </dd>
          </div>
          <div>
            <dt>Conflicting observations</dt>
            <dd>{props.device.conflict_count}</dd>
          </div>
        </dl>
        {reading && (
          <p class="notice">
            {reading.time_reason}
            {reading.quality_reasons.length > 0
              ? ` · ${reading.quality_reasons.join(", ")}`
              : ""}
          </p>
        )}
      </section>
      <AlertList alerts={props.alerts} compact />
    </>
  );
});

export const RawLog = component$<{ device: string; revision: number }>(
  (props) => {
    const topic = useSignal(""),
      since = useSignal(""),
      filter = useStore({ topic: "", since: "" });
    const data = useStore<{
      deliveries: Delivery[];
      error: string;
      loading: boolean;
    }>({ deliveries: [], error: "", loading: true });
    const refresh = useSignal(0),
      fetchedRevision = useSignal(-1);
    useVisibleTask$(({ track }) => {
      const revision = track(() => props.revision),
        fetched = track(() => fetchedRevision.value),
        loading = track(() => data.loading);
      if (!loading && revision !== fetched) refresh.value++;
    });
    useVisibleTask$(({ track, cleanup }) => {
      const device = track(() => props.device),
        selectedTopic = track(() => filter.topic),
        selectedSince = track(() => filter.since);
      track(() => refresh.value);
      const latest = latestRequest();
      data.loading = true;
      fetchedRevision.value = props.revision;
      latest.run(
        (signal) =>
          request<{ deliveries: Delivery[] }>(
            `/api/messages?${query({ device, topic: selectedTopic, since: selectedSince ? new Date(selectedSince).toISOString() : "" })}`,
            signal,
          ),
        (result) => {
          data.deliveries = result.deliveries;
          data.error = "";
          data.loading = false;
        },
        (error) => {
          data.error = errorText(error);
          data.loading = false;
        },
      );
      cleanup(() => latest.cancel());
    });
    return (
      <section>
        <h2>{props.device ? "Device delivery log" : "All raw deliveries"}</h2>
        {props.device && (
          <p>
            <a href="#view=log">
              Inspect all deliveries, including unattributed quarantines
            </a>
          </p>
        )}
        <p class="muted">
          The latest 100 matching deliveries, newest first
          {props.device ? "" : ", including unattributed and quarantined ones"}.
        </p>
        <form
          class="toolbar"
          preventdefault:submit
          onSubmit$={() => {
            filter.topic = topic.value;
            filter.since = since.value;
          }}
        >
          <label class="field" for="log-topic">
            Exact topic
            <input
              id="log-topic"
              value={topic.value}
              onInput$={(_, el) => {
                topic.value = el.value;
              }}
            />
          </label>
          <label class="field" for="log-since">
            Received since (local)
            <input
              id="log-since"
              type="datetime-local"
              value={since.value}
              onInput$={(_, el) => {
                since.value = el.value;
              }}
            />
          </label>
          <button type="submit">Apply filters</button>
        </form>
        {data.error && (
          <p role="alert" class="notice error-text">
            {data.error}
          </p>
        )}
        {data.loading && <p role="status">Loading deliveries…</p>}
        {!data.loading && !data.error && data.deliveries.length === 0 && (
          <p class="empty">No deliveries match these filters.</p>
        )}
        <div class="delivery-list" aria-busy={data.loading}>
          {data.deliveries.map((delivery, index) => (
            <details key={`${delivery.received_at}-${index}`}>
              <summary>
                {stamp(delivery.received_at)} · {delivery.topic}
                <span
                  class={
                    delivery.state === "accepted" ? "state" : "state error-text"
                  }
                >
                  {delivery.state}
                </span>
                {delivery.state !== "accepted" && delivery.reason && (
                  <small class="error-text">{delivery.reason}</small>
                )}
              </summary>
              <dl class="facts">
                <div>
                  <dt>Device / claimed identity</dt>
                  <dd>
                    {delivery.device_id || "Unattributed"} /{" "}
                    {delivery.claimed_device_id || "—"}
                  </dd>
                </div>
                <div>
                  <dt>Kind / QoS</dt>
                  <dd>
                    {delivery.kind} / {delivery.qos}
                  </dd>
                </div>
                <div>
                  <dt>Reason</dt>
                  <dd>{delivery.reason || "—"}</dd>
                </div>
                <div>
                  <dt>Clock / duplicate</dt>
                  <dd>
                    {delivery.time_quality || "—"} /{" "}
                    {delivery.duplicate_outcome || "—"}
                  </dd>
                </div>
                <div>
                  <dt>Profile / binding</dt>
                  <dd>
                    {delivery.source_profile || "—"} /{" "}
                    {delivery.binding_key || "—"}
                  </dd>
                </div>
              </dl>
              {delivery.detail && <p>{delivery.detail}</p>}
              <pre>{delivery.payload}</pre>
            </details>
          ))}
        </div>
      </section>
    );
  },
);
