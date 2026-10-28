import {
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { errorText, lag, number, query, request, stamp } from "./api";
import { HistoryChart } from "./chart";
import { latestRequest } from "./live";
import type { Alert, Delivery, Device, Series } from "./types";

export const Fleet = component$<{ devices: Device[] }>((props) => {
  const search = useSignal("");
  const devices = props.devices.filter((device) =>
    `${device.display_name} ${device.device_id} ${device.location_id || ""}`
      .toLowerCase()
      .includes(search.value.toLowerCase()),
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
                <th>Battery</th>
                <th>RSSI</th>
                <th>Presence / last seen</th>
                <th>Delivery lag</th>
                <th>Alerts</th>
              </tr>
            </thead>
            <tbody>
              {devices.map((device) => {
                const reading =
                  device.latest_plausible || device.latest_received;
                const latest = device.latest_received;
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
                      <strong>{number(reading?.gwl)} m</strong>
                      <small>
                        {reading?.recorded_at
                          ? stamp(reading.recorded_at)
                          : "Clock unverified"}
                      </small>
                      {reading && reading.time_quality !== "plausible" && (
                        <small class="error-text">{reading.time_quality}</small>
                      )}
                    </td>
                    <td class="numeric">{number(reading?.battery_v)} V</td>
                    <td class="numeric">
                      {number(reading?.rssi, 0)}
                      <small>0–100</small>
                    </td>
                    <td>
                      <span title={device.status_reason}>{device.status}</span>
                      <small>{stamp(device.last_received_at)}</small>
                    </td>
                    <td>
                      {lag(latest?.recorded_at, latest?.received_at)}
                      {latest && <small>{latest.time_quality}</small>}
                    </td>
                    <td>
                      <a
                        class={device.open_alert_count ? "error-text" : ""}
                        href={`#${query({ device: device.device_id, view: "alerts" })}`}
                      >
                        {device.open_alert_count || 0} open
                      </a>
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
          Read-only. Alerts resolve automatically when the level returns to
          normal with 0.5 m hysteresis.
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
                        {alert.kind.replaceAll("_", " ")}
                      </strong>
                      <small>
                        #{alert.id} · {alert.state}
                      </small>
                    </td>
                    <td>{number(alert.trigger_value)} m</td>
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
}>((props) => {
  const reading = props.device.latest_received;
  const interval = props.device.desired_config?.lf?.split(":").map(Number);
  const expected =
    interval?.length === 2 && interval.every(Number.isFinite)
      ? interval[0] * 60 + interval[1]
      : null;
  const gap = Math.max(props.series?.bucket_minutes || 0, expected || 3) * 2;
  return (
    <>
      {props.series && (
        <section aria-label="Device history">
          <HistoryChart
            title="Groundwater level"
            unit="metres · raw datum"
            metric="gwl"
            points={props.series.points}
            from={props.from}
            to={props.to}
            gapMinutes={gap}
            min={props.device.min_limit}
            max={props.device.max_limit}
            alerts={props.alerts}
          />
          <p class="chart-key">
            Shaded band: configured limits {props.device.min_limit ?? "unset"}{" "}
            to {props.device.max_limit ?? "unset"} m. Dashed vertical lines:
            alert opened. Line breaks: intervals longer than {gap} min
            {expected ? "" : " (3 min assumed; logging interval unavailable)"}.
          </p>
          {props.series.truncated && (
            <p class="notice">
              Oldest points were truncated by the server. Choose a shorter range
              or a larger bucket. CSV exports observations for the full range.
            </p>
          )}
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
              title="Signal strength"
              unit="RSSI · 0–100, not dBm"
              metric="rssi"
              points={props.series.points}
              from={props.from}
              to={props.to}
              gapMinutes={gap}
            />
          </div>
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
                      <th>GWL (m)</th>
                      <th>Battery (V)</th>
                      <th>RSSI</th>
                      <th>Samples / quality</th>
                    </tr>
                  </thead>
                  <tbody>
                    {props.series.points.map((point, index) => (
                      <tr key={`${point.recorded_at}-${index}`}>
                        <td>{stamp(point.recorded_at)}</td>
                        <td>{number(point.gwl)}</td>
                        <td>{number(point.battery_v)}</td>
                        <td>{number(point.rssi, 0)}</td>
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
    useVisibleTask$(({ track, cleanup }) => {
      const device = track(() => props.device),
        revision = track(() => props.revision),
        selectedTopic = track(() => filter.topic),
        selectedSince = track(() => filter.since);
      void revision;
      const latest = latestRequest();
      data.loading = true;
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
        <h2>Raw delivery log</h2>
        <p>
          Operator-only ingress evidence, retained for 90 days. Self-test output
          appears on the testresults topic.
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
                <span class="state">{delivery.state}</span>
              </summary>
              <dl class="facts">
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
