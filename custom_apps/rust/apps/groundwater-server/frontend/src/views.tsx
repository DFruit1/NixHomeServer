import {
  $,
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { errorText, lag, number, query, request, stamp } from "./api";
import {
  HistoryChart,
  faultSpans,
  faultText,
  isFaultPoint,
  levelSeries,
} from "./chart";
import { latestRequest } from "./live";
import type { Alert, Delivery, Device, Series, SeriesPoint } from "./types";
import { datumLabel, datumUnit } from "./ops";
import { alertLabel, alertValue } from "./alerts";
import { deviceProblems } from "./attention";
import { observationProblem, sensorProblem } from "./events";
import { csqText, millivolts } from "./format";

export const Fleet = component$<{
  devices: Device[];
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
      problems: deviceProblems(device),
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
                const health = device.health || {};
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
  // Fault readings come from the series itself: raw fault points and
  // fault-only buckets are never drawn as a level (chartGeometry), and
  // buckets that mixed valid and fault samples are marked.
  const level = levelSeries({
    points,
    faults: props.series?.faults,
    bucket_minutes: props.series?.bucket_minutes || 0,
  });
  const spans = faultSpans(
    level.marks,
    level.samples,
    props.series?.bucket_minutes || 0,
    gap,
  );
  const mixed = level.marks.filter((m) => m.valid > 0);
  const faultReadings = level.marks.reduce((sum, m) => sum + m.count, 0);
  const faultSummary = faultText(
    [
      ...new Set((props.series?.faults || []).flatMap((f) => f.fault_kinds)),
    ].sort(),
  );
  const bucketed = (props.series?.bucket_minutes || 0) > 0;
  // Table rows: every point, plus faults that have no point (no level, or a
  // bucket of faults only), in time order.
  const pointTimes = new Set(points.map((p) => Date.parse(p.recorded_at)));
  const rows = [
    ...points.map((point) => ({ at: Date.parse(point.recorded_at), point })),
    ...(props.series?.faults || [])
      .filter((f) => !pointTimes.has(Date.parse(f.recorded_at)))
      .map((fault) => ({ at: Date.parse(fault.recorded_at), fault })),
  ].sort((a, b) => a.at - b.at);
  const faultOf = (at: number) => level.marks.find((m) => m.at === at);
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
            points={points}
            faults={spans}
            mixed={mixed}
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
            {spans.length > 0 &&
              " Red dotted spans: sensor fault readings, no level."}
            {mixed.length > 0 &&
              " Ringed points: average of the valid samples in a bucket that also held fault readings."}
          </p>
          {faultReadings > 0 && (
            <p class="notice error-text">
              {faultReadings} reading{faultReadings === 1 ? "" : "s"} in this
              range {faultReadings === 1 ? "was" : "were"} not a valid level and{" "}
              {faultReadings === 1 ? "is" : "are"} left out of the line
              {bucketed ? ", the averages" : ""} and the axis: {faultSummary}.
            </p>
          )}
          {props.series.faults_truncated && (
            <p class="notice">
              The fault list was cut with the points: older fault readings in
              this range are not marked. Choose a shorter range or a larger
              bucket.
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
            <summary>Measurement data ({rows.length} rows)</summary>
            {rows.length === 0 ? (
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
                    {rows.map((row, index) => {
                      const mark = faultOf(row.at);
                      if ("fault" in row && row.fault) {
                        const f = row.fault;
                        return (
                          <tr key={`${f.recorded_at}-f${index}`}>
                            <td>{stamp(f.recorded_at)}</td>
                            <td>
                              <span class="error-text">{mark?.text}</span>
                              <small>no level</small>
                            </td>
                            <td>—</td>
                            <td>—</td>
                            <td>
                              {bucketed
                                ? `0 valid · ${f.fault_count} fault${f.fault_count === 1 ? "" : "s"}`
                                : "fault reading"}
                            </td>
                          </tr>
                        );
                      }
                      const point = (row as { point: SeriesPoint }).point;
                      const fault = isFaultPoint(point);
                      return (
                        <tr key={`${point.recorded_at}-${index}`}>
                          <td>{stamp(point.recorded_at)}</td>
                          <td>
                            {fault ? (
                              <>
                                <span class="error-text">
                                  {sensorProblem(point.sensor_status)}
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
                            {fault
                              ? "fault reading"
                              : bucketed
                                ? `${point.sample_count} valid`
                                : point.sample_count}
                            {!fault && mark && (
                              <small class="error-text">
                                {mark.count} fault
                                {mark.count === 1 ? "" : "s"} left out:{" "}
                                {mark.text}
                              </small>
                            )}
                            {point.conflict ? (
                              <small>conflicting samples</small>
                            ) : null}
                          </td>
                        </tr>
                      );
                    })}
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

/** `/api/messages` filters of the raw log. */
const deliveryQuery = (f: {
  device: string;
  topic: string;
  since: string;
  quarantined: boolean;
}) => ({
  device: f.device,
  topic: f.topic,
  since: f.since ? new Date(f.since).toISOString() : "",
  state: f.quarantined ? "quarantined" : "",
});

/** The live newest page followed by the older pages, without repeats. */
const mergedDeliveries = (newest: Delivery[], older: Delivery[]) => {
  const ids = new Set(newest.map((d) => d.id));
  return [...newest, ...older.filter((d) => !ids.has(d.id))];
};

export const RawLog = component$<{ device: string; revision: number }>(
  (props) => {
    const topic = useSignal(""),
      since = useSignal(""),
      quarantined = useSignal(false),
      filter = useStore({ topic: "", since: "", quarantined: false });
    const data = useStore<{
      deliveries: Delivery[];
      /** The server has more deliveries after the newest page. */
      more: boolean;
      /** Older pages from "Show older deliveries", kept across refreshes. */
      older: Delivery[];
      olderMore: boolean;
      olderLoading: boolean;
      error: string;
      loading: boolean;
    }>({
      deliveries: [],
      more: false,
      older: [],
      olderMore: false,
      olderLoading: false,
      error: "",
      loading: true,
    });
    const refresh = useSignal(0),
      fetchedRevision = useSignal(-1),
      loadedSelection = useSignal("");
    const loadOlder = $(async () => {
      const list = mergedDeliveries(data.deliveries, data.older);
      const last = list[list.length - 1];
      if (!last || data.olderLoading) return;
      data.olderLoading = true;
      try {
        const result = await request<{
          deliveries: Delivery[];
          more?: boolean;
        }>(
          `/api/messages?${query({ ...deliveryQuery({ ...filter, device: props.device }), before: String(last.id) })}`,
        );
        data.older = [...data.older, ...result.deliveries];
        data.olderMore = result.more === true;
      } catch (error) {
        data.error = errorText(error);
      } finally {
        data.olderLoading = false;
      }
    });
    const list = mergedDeliveries(data.deliveries, data.older);
    const more = data.older.length ? data.olderMore : data.more;
    useVisibleTask$(({ track }) => {
      const revision = track(() => props.revision),
        fetched = track(() => fetchedRevision.value),
        loading = track(() => data.loading);
      if (!loading && revision !== fetched) refresh.value++;
    });
    useVisibleTask$(({ track, cleanup }) => {
      const selection = JSON.stringify([
        track(() => props.device),
        track(() => filter.topic),
        track(() => filter.since),
        track(() => filter.quarantined),
      ]);
      track(() => refresh.value);
      if (selection !== loadedSelection.value) {
        data.older = [];
        data.olderMore = false;
        loadedSelection.value = selection;
      }
      const latest = latestRequest();
      data.loading = true;
      fetchedRevision.value = props.revision;
      latest.run(
        (signal) =>
          request<{ deliveries: Delivery[]; more?: boolean }>(
            `/api/messages?${query(deliveryQuery({ ...filter, device: props.device }))}`,
            signal,
          ),
        (result) => {
          // With older pages shown, the previous newest page joins them, so
          // rows pushed off the newest page by new arrivals stay listed.
          if (data.older.length)
            data.older = mergedDeliveries(data.deliveries, data.older);
          data.deliveries = result.deliveries;
          data.more = result.more === true;
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
          Matching deliveries, newest first, 100 at a time
          {props.device ? "" : ", including unattributed and quarantined ones"}.
        </p>
        <form
          class="toolbar"
          preventdefault:submit
          onSubmit$={() => {
            filter.topic = topic.value;
            filter.since = since.value;
            filter.quarantined = quarantined.value;
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
          <label class="checkbox" for="log-quarantined">
            <input
              id="log-quarantined"
              type="checkbox"
              checked={quarantined.value}
              onChange$={(_, el) => {
                quarantined.value = el.checked;
              }}
            />
            Quarantined only
          </label>
          <button type="submit">Apply filters</button>
        </form>
        {data.error && (
          <p role="alert" class="notice error-text">
            {data.error}
          </p>
        )}
        {data.loading && <p role="status">Loading deliveries…</p>}
        {!data.loading && !data.error && list.length === 0 && (
          <p class="empty">No deliveries match these filters.</p>
        )}
        <div class="delivery-list" aria-busy={data.loading}>
          {list.map((delivery) => (
            <details key={delivery.id}>
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
        {more && (
          <p class="toolbar">
            <span class="muted">{list.length} shown.</span>
            <button
              type="button"
              disabled={data.olderLoading}
              aria-busy={data.olderLoading}
              onClick$={loadOlder}
            >
              {data.olderLoading ? "Loading…" : "Show older deliveries"}
            </button>
          </p>
        )}
      </section>
    );
  },
);
