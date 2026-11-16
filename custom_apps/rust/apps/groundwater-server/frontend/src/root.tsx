import {
  $,
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import {
  dateInput,
  download,
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
import { Fleet, History, RawLog, stuckIngest } from "./views";
import type { Alert, Command, Device, Series, Status } from "./types";
import {
  EventsView,
  HealthView,
  LocationView,
  Overview,
  TestsView,
} from "./device-rev2";
import { SettingsView } from "./settings-view";
import { Challenges, Rev2Console, Rev2Queue } from "./console";
import { FilesView } from "./files";
import { StreamView } from "./stream";
import { AlertHistory, DevicePolicyPanel, LimitsEditor } from "./alerts";
import { AdminPage, GapsPage } from "./admin";
import { InstallationView } from "./installation";
import { relative } from "./format";
import { useNow } from "./hooks";
import { DATUM_MODES } from "./ops";
import { deviceViews, viewLabel } from "./routes";

interface Workspace {
  device?: Device;
  series?: Series;
  seriesSelection: string;
  alerts: Alert[];
  commands: Command[];
  /** The server listed only its newest 500 commands. */
  commandsTruncated: boolean;
  /** Older pages loaded with "Show older commands" (`before=<id>`). */
  olderCommands: Command[];
  olderTruncated: boolean;
  olderLoading: boolean;
  olderError: string;
  errors: Record<string, string>;
  loading: boolean;
}
const fleetViews = ["alerts", "gaps", "admin", "log"];
export default component$(() => {
  const route = useStore({ device: "", view: "", section: "" });
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
    commandsTruncated: false,
    olderCommands: [],
    olderTruncated: false,
    olderLoading: false,
    olderError: "",
    errors: {},
    loading: false,
  });
  const clock = useNow(60000);
  const live = useSignal("Connecting…"),
    revision = useSignal(0),
    updated = useSignal("");
  const now = new Date();
  const range = useStore({
    from: new Date(now.getTime() - 86400000).toISOString(),
    to: now.toISOString(),
    bucket: 15,
    relativeHours: 24 as number | null,
    datum: "raw",
  });
  const draft = useStore({
    from: dateInput(new Date(range.from)),
    to: dateInput(new Date(range.to)),
    bucket: 15,
  });
  const rangeError = useSignal("");
  const exporting = useSignal(false);
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
      route.view = hash.get("view") || "";
      route.section = hash.get("section") || "";
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
        else if (!global.errors.includes(errorText(devices.reason)))
          global.errors.push(errorText(devices.reason));
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
      relativeHours = track(() => range.relativeHours),
      datum = track(() => range.datum);
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
      workspace.olderCommands = [];
      workspace.olderError = "";
      workspace.errors = {};
    }
    let params: string;
    try {
      params =
        rangeQuery(device, from, to, bucket) +
        (datum !== "raw" ? `&${query({ datum })}` : "");
    } catch (error) {
      workspace.errors = { series: errorText(error) };
      workspace.loading = false;
      return;
    }
    const selection = JSON.stringify([
      device,
      view,
      bucket,
      datum,
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
    if (view === "history" || view === "")
      tasks.push(["series", `/api/series?${params}`]);
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
          if (key === "commands") {
            // With older pages shown, the previous newest page joins them,
            // so commands pushed off it by new ones stay listed.
            if (workspace.olderCommands.length) {
              const known = new Set(workspace.olderCommands.map((c) => c.id));
              workspace.olderCommands = [
                ...workspace.commands.filter((c) => !known.has(c.id)),
                ...workspace.olderCommands,
              ].sort((a, b) => b.id - a.id);
            }
            workspace.commands = result!.commands as Command[];
            workspace.commandsTruncated = result!.truncated === true;
          }
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
  // The newest page refreshes live; older pages are appended below it.
  const newest = workspace.commands;
  const oldestShown = newest.length ? newest[newest.length - 1].id : Infinity;
  const commandList = [
    ...newest,
    ...workspace.olderCommands.filter((c) => c.id < oldestShown),
  ];
  const commandsTruncated = workspace.olderCommands.length
    ? workspace.olderTruncated
    : workspace.commandsTruncated;
  const loadOlder = $(async () => {
    const list = [
      ...workspace.commands,
      ...workspace.olderCommands.filter(
        (c) =>
          !workspace.commands.length ||
          c.id < workspace.commands[workspace.commands.length - 1].id,
      ),
    ];
    const last = list[list.length - 1];
    if (!last || workspace.olderLoading) return;
    const device = last.device_id;
    workspace.olderLoading = true;
    workspace.olderError = "";
    try {
      const result = await request<{ commands: Command[]; truncated: boolean }>(
        `/api/commands?${query({ device, before: String(last.id) })}`,
      );
      if (workspace.device?.device_id !== device) return;
      workspace.olderCommands = [
        ...workspace.olderCommands.filter((c) => c.id > last.id),
        ...result.commands,
      ];
      workspace.olderTruncated = result.truncated === true;
    } catch (error) {
      workspace.olderError = errorText(error);
    } finally {
      workspace.olderLoading = false;
    }
  });
  const paging = {
    truncated: commandsTruncated,
    more: loadOlder,
    moreLoading: workspace.olderLoading,
    moreError: workspace.olderError,
  };
  const operator = global.status?.user?.role === "operator";
  const stuck =
    operator && global.status
      ? stuckIngest(global.status.ingest, clock.value)
      : [];
  // With one logger the stuck content can only be its own.
  const onlyDevice =
    global.devices?.length === 1 ? global.devices[0] : undefined;
  const device =
    workspace.device?.device_id === route.device ? workspace.device : undefined;
  const rev2 = device?.capabilities?.protocol === 2;
  const tabs = device ? deviceViews(rev2, operator) : [];
  const view =
    route.view && tabs.includes(route.view)
      ? route.view
      : rev2
        ? "overview"
        : "history";
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
        <nav class="app-nav" aria-label="Fleet">
          {(
            [
              ["", "Devices"],
              ["alerts", "Alerts"],
              ["gaps", "Gaps"],
              ...(operator
                ? [
                    ["admin", "Admin"],
                    ["log", "Raw deliveries"],
                  ]
                : []),
            ] as [string, string][]
          ).map(([key, label]) => (
            <a
              key={key}
              href={key ? `#view=${key}` : "#"}
              aria-current={
                !route.device &&
                (route.view === key ||
                  (!key && !fleetViews.includes(route.view)))
                  ? "page"
                  : undefined
              }
            >
              {label}
            </a>
          ))}
        </nav>
        <div class="session">
          <span>
            {global.status?.user?.username || "Checking session"}
            {global.status?.user && ` · ${global.status.user.role}`}
          </span>
          <span class="muted" role="status">
            {live.value}
          </span>
          {operator && global.status && (
            <span
              class="muted"
              title={stamp(global.status.ingest.lastDeliveryAt)}
            >
              {global.status.ingest.lastDeliveryAt
                ? `last delivery ${relative(global.status.ingest.lastDeliveryAt, clock.value)}`
                : "no delivery stored"}
            </span>
          )}
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
      {operator && stuck.length > 0 && (
        <p class="notice error-text" role="status">
          Logger data not yet stored: {stuck.join("; ")}.{" "}
          {onlyDevice ? (
            <a
              href={`#device=${encodeURIComponent(onlyDevice.device_id)}&view=log`}
            >
              Raw log of {onlyDevice.display_name || onlyDevice.device_id}
            </a>
          ) : (
            <a href="#view=log">Raw deliveries</a>
          )}
        </p>
      )}
      <main id="main" tabIndex={-1}>
        {!route.device ? (
          <>
            {route.view === "log" && operator ? (
              <RawLog device="" revision={revision.value} />
            ) : route.view === "alerts" ? (
              <AlertHistory revision={revision.value} operator={operator} />
            ) : route.view === "gaps" ? (
              <GapsPage revision={revision.value} />
            ) : route.view === "admin" && operator ? (
              <AdminPage
                revision={revision.value}
                devices={global.devices || []}
                section={route.section}
                refresh={refresh}
              />
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
            {workspace.errors.device?.startsWith("404") ? (
              // The API answers 404 for both unknown and unpermitted devices.
              <p role="alert" class="notice error-text">
                This device does not exist or your account has no access to it.
              </p>
            ) : (
              Object.entries(workspace.errors).map(([key, error]) => (
                <p key={key} role="alert" class="notice error-text">
                  {key}: {error} <button onClick$={refresh}>Retry</button>
                </p>
              ))
            )}
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
                  {device.project ? (
                    <div>
                      <dt>Project</dt>
                      <dd>{device.project}</dd>
                    </div>
                  ) : null}
                  {rev2 ? (
                    <div>
                      <dt>Next expected connection</dt>
                      <dd>
                        {stamp(
                          device.expected_contact_at || device.next_contact_at,
                        )}
                      </dd>
                    </div>
                  ) : (
                    <div>
                      <dt>Last Ready</dt>
                      <dd>{stamp(device.last_ready_at)}</dd>
                    </div>
                  )}
                </dl>
                {device.revoked && (
                  <p class="notice error-text">
                    This enrollment is retired. Its history stays visible; new
                    traffic is quarantined.
                  </p>
                )}
                {device.clock_change_unverified && (
                  <p role="alert" class="notice error-text">
                    An earlier UTC offset change is unverified. Zoneless
                    readings retain an unknown clock until the logger is
                    re-commissioned.
                  </p>
                )}
                <nav class="view-nav" aria-label="Device views">
                  {tabs.map((tab) => (
                    <a
                      key={tab}
                      href={`#${query({ device: device.device_id, view: tab })}`}
                      aria-current={view === tab ? "page" : undefined}
                    >
                      {viewLabel(tab)}
                    </a>
                  ))}
                </nav>
                {view === "history" && (
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
                        <label class="field" for="range-datum">
                          Level as
                          <select
                            id="range-datum"
                            value={range.datum}
                            onChange$={(_, el) => {
                              range.datum = el.value;
                            }}
                          >
                            {DATUM_MODES.map(([key, label]) => (
                              <option key={key} value={key}>
                                {label}
                              </option>
                            ))}
                          </select>
                        </label>
                        <button class="primary" type="submit">
                          Apply range
                        </button>
                        <button
                          type="button"
                          disabled={exporting.value}
                          aria-busy={exporting.value}
                          onClick$={async () => {
                            if (exporting.value) return;
                            exporting.value = true;
                            rangeError.value = "";
                            try {
                              await download(
                                exportUrl(
                                  device.device_id,
                                  range.from,
                                  range.to,
                                ),
                                "groundwater-observations.csv",
                              );
                            } catch (error) {
                              rangeError.value = errorText(error);
                            } finally {
                              exporting.value = false;
                            }
                          }}
                        >
                          {exporting.value ? "Exporting…" : "Export CSV"}
                        </button>
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
                      revision={revision.value}
                    />
                  </>
                )}
                {view === "overview" && (
                  <Overview
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "health" && (
                  <HealthView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "events" && (
                  <EventsView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "location" && (
                  <LocationView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "tests" && (
                  <TestsView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "settings" && (
                  <SettingsView
                    key={device.device_id}
                    device={device}
                    alerts={workspace.alerts}
                    revision={revision.value}
                    operator={operator && !device.revoked}
                  />
                )}
                {view === "files" && (
                  <FilesView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator && !device.revoked}
                  />
                )}
                {view === "stream" && (
                  <StreamView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                  />
                )}
                {view === "installation" && (
                  <InstallationView
                    key={device.device_id}
                    device={device}
                    revision={revision.value}
                    operator={operator}
                    refresh={refresh}
                  />
                )}
                {view === "alerts" && (
                  <>
                    <AlertHistory
                      key={device.device_id}
                      device={device.device_id}
                      revision={revision.value}
                      operator={operator}
                      refresh={refresh}
                    />
                    <LimitsEditor
                      key={`limits-${device.device_id}`}
                      device={device}
                      operator={operator && !device.revoked}
                      refresh={refresh}
                    />
                    <DevicePolicyPanel
                      key={`policy-${device.device_id}`}
                      device={device}
                      revision={revision.value}
                      operator={operator}
                    />
                  </>
                )}
                {view === "configuration" && (
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
                {view === "commands" && rev2 && (
                  <>
                    <Challenges
                      device={device.device_id}
                      commands={workspace.commands}
                      operator={operator && !device.revoked}
                      refresh={refresh}
                    />
                    {operator && !device.revoked ? (
                      <Rev2Console
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
                    <Rev2Queue
                      device={device.device_id}
                      commands={commandList}
                      {...paging}
                      operator={operator && !device.revoked}
                      refresh={refresh}
                      expected={
                        device.expected_contact_at || device.next_contact_at
                      }
                    />
                  </>
                )}
                {view === "audit" && rev2 && (
                  <Rev2Queue
                    device={device.device_id}
                    commands={commandList}
                    {...paging}
                    operator={false}
                    refresh={refresh}
                    audit
                  />
                )}
                {view === "commands" && !rev2 && (
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
                      commands={commandList}
                      {...paging}
                      operator={operator && !device.revoked}
                      refresh={refresh}
                    />
                  </>
                )}
                {view === "audit" && !rev2 && (
                  <CommandQueue
                    device={device.device_id}
                    commands={commandList}
                    {...paging}
                    operator={false}
                    refresh={refresh}
                    audit
                  />
                )}
                {view === "log" &&
                  (operator ? (
                    <RawLog
                      key={device.device_id}
                      device={device.device_id}
                      revision={revision.value}
                      salvaged={global.status?.ingest.salvaged}
                      retentionDays={global.status?.retentionDays}
                      refresh={refresh}
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
        display in your browser’s local timezone. RSSI is the revision 1 0–100
        scale; CSQ is the modem's 0–31 scale.
      </footer>
    </div>
  );
});
