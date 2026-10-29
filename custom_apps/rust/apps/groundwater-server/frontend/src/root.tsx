import {
  $,
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import {
  dateInput,
  errorText,
  exportUrl,
  query,
  rangeQuery,
  request,
  stamp,
} from "./api";
import { connectLive, latestRequest } from "./live";
import {
  CommandQueue,
  ConfigEditor,
  ConfigSnapshot,
  DeviceCommands,
} from "./operator";
import { AlertList, Fleet, History, RawLog } from "./views";
import type { Alert, Command, Device, Series, Status } from "./types";

interface Workspace {
  device?: Device;
  series?: Series;
  seriesSelection: string;
  alerts: Alert[];
  commands: Command[];
  errors: Record<string, string>;
  loading: boolean;
}
const views = [
  "history",
  "alerts",
  "configuration",
  "commands",
  "audit",
  "log",
] as const;
export default component$(() => {
  const route = useStore({ device: "", view: "history" });
  const global = useStore<{
    status?: Status;
    devices?: Device[];
    errors: string[];
    loading: boolean;
  }>({ errors: [], loading: true });
  const workspace = useStore<Workspace>({
    seriesSelection: "",
    alerts: [],
    commands: [],
    errors: {},
    loading: false,
  });
  const live = useSignal("Connecting…"),
    revision = useSignal(0),
    updated = useSignal("");
  const now = new Date();
  const range = useStore({
    from: new Date(now.getTime() - 86400000).toISOString(),
    to: now.toISOString(),
    bucket: 15,
    relativeHours: 24 as number | null,
  });
  const draft = useStore({
    from: dateInput(new Date(range.from)),
    to: dateInput(new Date(range.to)),
    bucket: 15,
  });
  const rangeError = useSignal("");
  const refreshPending = useSignal(false);
  const refresh = $(() => {
    refreshPending.value = true;
  });
  useVisibleTask$(({ track }) => {
    const pending = track(() => refreshPending.value),
      globalLoading = track(() => global.loading),
      workspaceLoading = track(() => workspace.loading);
    // Background events wait for the current batch, rather than repeatedly
    // cancelling responses on connections slower than the SSE throttle.
    if (!pending || globalLoading || workspaceLoading) return;
    refreshPending.value = false;
    if (range.relativeHours !== null) {
      const end = new Date();
      range.from = new Date(
        end.getTime() - range.relativeHours * 3600000,
      ).toISOString();
      range.to = end.toISOString();
    }
    revision.value++;
  });
  useVisibleTask$(({ cleanup }) => {
    const readRoute = () => {
      const hash = new URLSearchParams(location.hash.slice(1));
      route.device = hash.get("device") || "";
      const view = hash.get("view") || "history";
      route.view = views.includes(view as (typeof views)[number])
        ? view
        : "history";
    };
    readRoute();
    window.addEventListener("hashchange", readRoute);
    const stop = connectLive(
      () => {
        void refresh();
      },
      (value) => {
        live.value = value;
      },
    );
    cleanup(() => {
      stop();
      window.removeEventListener("hashchange", readRoute);
    });
  });
  useVisibleTask$(({ track, cleanup }) => {
    track(() => revision.value);
    const latest = latestRequest();
    global.loading = true;
    latest.run(
      (signal) =>
        Promise.allSettled([
          request<Status>("/api/status", signal),
          request<{ devices: Device[] }>("/api/devices", signal),
        ]),
      (results) => {
        const [status, devices] = results;
        global.errors = [];
        if (status.status === "fulfilled") global.status = status.value;
        else {
          global.status = undefined;
          global.errors.push(errorText(status.reason));
        }
        if (devices.status === "fulfilled")
          global.devices = devices.value.devices;
        else global.errors.push(errorText(devices.reason));
        global.loading = false;
        updated.value = new Date().toISOString();
      },
      (error) => {
        global.errors = [errorText(error)];
        global.loading = false;
      },
    );
    cleanup(() => latest.cancel());
  });
  useVisibleTask$(({ track, cleanup }) => {
    const device = track(() => route.device),
      view = track(() => route.view);
    const from = track(() => range.from),
      to = track(() => range.to),
      bucket = track(() => range.bucket),
      relativeHours = track(() => range.relativeHours);
    track(() => revision.value);
    if (!device) {
      workspace.loading = false;
      return;
    }
    const latest = latestRequest();
    workspace.loading = true;
    if (workspace.device?.device_id !== device) {
      workspace.device = undefined;
      workspace.series = undefined;
      workspace.alerts = [];
      workspace.commands = [];
      workspace.errors = {};
    }
    let params: string;
    try {
      params = rangeQuery(device, from, to, bucket);
    } catch (error) {
      workspace.errors = { series: errorText(error) };
      workspace.loading = false;
      return;
    }
    const selection = JSON.stringify([
      device,
      view,
      bucket,
      relativeHours === null ? [from, to] : relativeHours,
    ]);
    if (workspace.seriesSelection !== selection) {
      workspace.series = undefined;
      workspace.seriesSelection = selection;
    }
    const tasks: [string, string][] = [
      ["device", `/api/devices/${encodeURIComponent(device)}`],
      ["open", `/api/alerts?${query({ device, state: "open" })}`],
      ["resolved", `/api/alerts?${query({ device, state: "resolved" })}`],
    ];
    if (view === "history") tasks.push(["series", `/api/series?${params}`]);
    if (view === "commands" || view === "audit")
      tasks.push(["commands", `/api/commands?${query({ device })}`]);
    latest.run(
      (signal) =>
        Promise.all(
          tasks.map(async ([key, path]) => {
            try {
              return {
                key,
                result: await request<Record<string, unknown>>(path, signal),
                error: "",
              };
            } catch (error) {
              return { key, result: undefined, error: errorText(error) };
            }
          }),
        ),
      (results) => {
        const alerts: Alert[] = [];
        workspace.errors = {};
        for (const { key, result, error } of results) {
          if (error) {
            workspace.errors[key] = error;
            if (key === "device") workspace.device = undefined;
            if (key === "commands") workspace.commands = [];
            continue;
          }
          if (key === "device") workspace.device = result!.device as Device;
          if (key === "series") workspace.series = result!.series as Series;
          if (key === "commands")
            workspace.commands = result!.commands as Command[];
          if (key === "open" || key === "resolved")
            alerts.push(...(result!.alerts as Alert[]));
        }
        workspace.alerts = alerts.sort(
          (a, b) => Date.parse(b.opened_at) - Date.parse(a.opened_at),
        );
        workspace.loading = false;
      },
      (error) => {
        workspace.errors = { device: errorText(error) };
        workspace.loading = false;
      },
    );
    cleanup(() => latest.cancel());
  });
  const operator = global.status?.user?.role === "operator";
  const device =
    workspace.device?.device_id === route.device ? workspace.device : undefined;
  const deviceViews = views.filter((view) => view !== "log" || operator);
  return (
    <div class="page">
      <a
        class="skip-link"
        href="#main"
        preventdefault:click
        onClick$={() => document.getElementById("main")?.focus()}
      >
        Skip to content
      </a>
      <header class="app-header">
        <a class="brand" href="#">
          Groundwater
        </a>
        <div class="session">
          <span>
            {global.status?.user?.username || "Checking session"}
            {global.status?.user && ` · ${global.status.user.role}`}
          </span>
          {operator && <a href="#view=log">Raw deliveries</a>}
          <span class="muted" role="status">
            {live.value}
          </span>
          <button
            onClick$={refresh}
            disabled={global.loading || workspace.loading}
          >
            Refresh
          </button>
        </div>
      </header>
      {global.errors.map((error, index) => (
        <p key={index} role="alert" class="notice error-text">
          {error} <button onClick$={refresh}>Retry</button>
        </p>
      ))}
      {global.status && !global.status.broker.connected && (
        <p class="notice error-text" role="status">
          MQTT broker disconnected.{" "}
          {global.status.broker.last_error ||
            global.status.broker.lastError ||
            "Telemetry and command delivery may be delayed."}
        </p>
      )}
      <main id="main" tabIndex={-1}>
        {!route.device ? (
          <>
            {route.view === "log" && operator ? (
              <RawLog device="" revision={revision.value} />
            ) : (
              <>
                {global.loading && !global.devices && (
                  <p role="status">Loading devices…</p>
                )}
                {global.devices && <Fleet devices={global.devices} />}
              </>
            )}
          </>
        ) : (
          <>
            <a href="#" class="back-link">
              All devices
            </a>
            {workspace.loading && !device && (
              <p role="status">Loading device…</p>
            )}
            {Object.entries(workspace.errors).map(([key, error]) => (
              <p key={key} role="alert" class="notice error-text">
                {key}: {error} <button onClick$={refresh}>Retry</button>
              </p>
            ))}
            {device && (
              <>
                <div class="device-heading">
                  <div>
                    <h1>{device.display_name || device.device_id}</h1>
                    <p class="mono muted">{device.device_id}</p>
                  </div>
                  <div>
                    <strong title={device.status_reason}>
                      {device.status}
                    </strong>
                    <small>Last seen {stamp(device.last_received_at)}</small>
                  </div>
                </div>
                <dl class="device-meta">
                  <div>
                    <dt>Location / sensor</dt>
                    <dd>
                      {device.location_id || "—"} / {device.sensor_id || "—"}
                    </dd>
                  </div>
                  <div>
                    <dt>Firmware profile</dt>
                    <dd>{device.profile}</dd>
                  </div>
                  <div>
                    <dt>Last Ready</dt>
                    <dd>{stamp(device.last_ready_at)}</dd>
                  </div>
                </dl>
                {device.clock_change_unverified && (
                  <p role="alert" class="notice error-text">
                    An earlier UTC offset change is unverified. Zoneless
                    readings retain an unknown clock until the logger is
                    re-commissioned.
                  </p>
                )}
                <nav class="view-nav" aria-label="Device views">
                  {deviceViews.map((view) => (
                    <a
                      key={view}
                      href={`#${query({ device: device.device_id, view })}`}
                      aria-current={route.view === view ? "page" : undefined}
                    >
                      {view === "log"
                        ? "Raw log"
                        : view[0].toUpperCase() + view.slice(1)}
                    </a>
                  ))}
                </nav>
                {route.view === "history" && (
                  <>
                    <form
                      class="range-form"
                      preventdefault:submit
                      onSubmit$={() => {
                        try {
                          rangeQuery(
                            device.device_id,
                            draft.from,
                            draft.to,
                            draft.bucket,
                          );
                          range.from = draft.from;
                          range.to = draft.to;
                          range.bucket = draft.bucket;
                          range.relativeHours = null;
                          rangeError.value = "";
                        } catch (error) {
                          rangeError.value = errorText(error);
                        }
                      }}
                    >
                      <div class="toolbar">
                        <label class="field" for="range-from">
                          From (local time)
                          <input
                            id="range-from"
                            type="datetime-local"
                            required
                            value={draft.from}
                            onInput$={(_, el) => {
                              draft.from = el.value;
                            }}
                          />
                        </label>
                        <label class="field" for="range-to">
                          To (local time)
                          <input
                            id="range-to"
                            type="datetime-local"
                            required
                            value={draft.to}
                            onInput$={(_, el) => {
                              draft.to = el.value;
                            }}
                          />
                        </label>
                        <label class="field" for="range-bucket">
                          Bucket
                          <select
                            id="range-bucket"
                            value={draft.bucket}
                            onChange$={(_, el) => {
                              draft.bucket = +el.value;
                            }}
                          >
                            <option value="0">Raw</option>
                            <option value="5">5 min</option>
                            <option value="15">15 min</option>
                            <option value="60">1 hour</option>
                            <option value="360">6 hours</option>
                            <option value="1440">1 day</option>
                          </select>
                        </label>
                        <button class="primary" type="submit">
                          Apply range
                        </button>
                        <a
                          class="button"
                          href={exportUrl(
                            device.device_id,
                            range.from,
                            range.to,
                          )}
                        >
                          Export CSV
                        </a>
                      </div>
                      <div class="quick-range" aria-label="Recent history">
                        {[24, 168, 720].map((hours) => (
                          <button
                            key={hours}
                            type="button"
                            onClick$={() => {
                              const end = new Date();
                              const start = new Date(
                                end.getTime() - hours * 3600000,
                              );
                              range.from = start.toISOString();
                              range.to = end.toISOString();
                              draft.from = dateInput(start);
                              draft.to = dateInput(end);
                              range.relativeHours = hours;
                              range.bucket = draft.bucket =
                                hours === 24 ? 15 : hours === 168 ? 60 : 360;
                              rangeError.value = "";
                            }}
                          >
                            {hours === 24
                              ? "24 hours"
                              : hours === 168
                                ? "7 days"
                                : "30 days"}
                          </button>
                        ))}
                      </div>
                      {rangeError.value && (
                        <p class="error-text" role="alert">
                          {rangeError.value}
                        </p>
                      )}
                    </form>
                    {workspace.loading && (
                      <p role="status">Updating history…</p>
                    )}
                    <History
                      device={device}
                      series={workspace.series}
                      alerts={workspace.alerts}
                      from={range.from}
                      to={range.to}
                    />
                  </>
                )}
                {route.view === "alerts" && (
                  <AlertList alerts={workspace.alerts} />
                )}
                {route.view === "configuration" && (
                  <>
                    {operator &&
                    !device.revoked &&
                    device.capabilities?.project_settings ? (
                      <ConfigEditor
                        key={device.device_id}
                        device={device}
                        refresh={refresh}
                      />
                    ) : (
                      <p class="notice">
                        {device.revoked
                          ? "This enrollment is revoked."
                          : !operator
                            ? "Your viewer account has read-only access to configuration."
                            : "Commission the device clock before sending project settings. Offset changes cannot be applied safely to zoneless SD backlog."}
                      </p>
                    )}
                    <ConfigSnapshot device={device} />
                  </>
                )}
                {route.view === "commands" && (
                  <>
                    {operator && !device.revoked ? (
                      <DeviceCommands
                        key={device.device_id}
                        device={device}
                        refresh={refresh}
                      />
                    ) : (
                      <p class="notice">
                        {device.revoked
                          ? "This enrollment is revoked."
                          : "Your viewer account has read-only access to commands."}
                      </p>
                    )}
                    <CommandQueue
                      device={device.device_id}
                      commands={workspace.commands}
                      operator={operator && !device.revoked}
                      refresh={refresh}
                    />
                  </>
                )}
                {route.view === "audit" && (
                  <CommandQueue
                    device={device.device_id}
                    commands={workspace.commands}
                    operator={false}
                    refresh={refresh}
                    audit
                  />
                )}
                {route.view === "log" &&
                  (operator ? (
                    <RawLog
                      key={device.device_id}
                      device={device.device_id}
                      revision={revision.value}
                    />
                  ) : (
                    <p class="notice">
                      Raw delivery logs are available to operators only.
                    </p>
                  ))}
              </>
            )}
          </>
        )}
      </main>
      <footer class="muted">
        {updated.value && `Last refreshed ${stamp(updated.value)}. `}Times
        display in your browser’s local timezone. RSSI is a 0–100 scale.
      </footer>
    </div>
  );
});
