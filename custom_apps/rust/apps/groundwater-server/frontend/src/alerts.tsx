// Alert history with acknowledge/resolve, alert policies and level limits.
export { ALERT_KIND_LABEL, alertLabel, alertValue } from "./alert-text";
import { nextContactText } from "./console";
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  type QRL,
} from "@builder.io/qwik";
import { errorText, query, stamp } from "./api";
import {
  alertLabel,
  alertNotes,
  alertValue,
  isLatched,
  reportedLate,
  resolution,
} from "./alert-text";
import { devicePath, send, useJson } from "./hooks";
import { POLICY_FIELDS, buildLimits, buildPolicy, policyDraft } from "./ops";
import type { Alert, Device, DevicePolicy, PolicyValues } from "./types";
import { Feedback, LoadState, TableRegion } from "./widgets";

export const AlertHistory = component$<{
  device?: string;
  revision: number;
  operator: boolean;
  refresh?: QRL<() => void>;
}>((props) => {
  const state = useSignal("open");
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(
    () =>
      `/api/alerts?${query({ device: props.device || "", state: state.value, limit: 500 })}`,
  );
  const { state: data, reload } = useJson<{ alerts: Alert[] }>(url, rev);
  const editing = useStore({ id: 0, action: "", note: "" });
  const action = useStore({ pending: false, message: "", failed: false });
  const submit = $(async () => {
    if (action.pending || !editing.id) return;
    action.pending = true;
    action.message = "";
    try {
      await send("POST", `/api/alerts/${editing.id}/${editing.action}`, {
        note: editing.note.trim(),
      });
      action.message = `Alert #${editing.id} ${editing.action === "acknowledge" ? "acknowledged" : "resolved"}.`;
      action.failed = false;
      editing.id = 0;
      editing.note = "";
      reload();
      if (props.refresh) await props.refresh();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const alerts = data.data?.alerts || [];
  return (
    <section aria-labelledby="alert-history-heading">
      <div class="section-heading">
        <h2 id="alert-history-heading">
          {props.device ? "Alerts" : "Fleet alerts"}
        </h2>
        <label class="field" for="alert-history-state">
          State
          <select
            id="alert-history-state"
            value={state.value}
            onChange$={(_, el) => {
              state.value = el.value;
            }}
          >
            <option value="open">Open</option>
            <option value="resolved">Resolved</option>
            <option value="all">All</option>
          </select>
        </label>
      </div>
      <p class="muted">
        Most alerts close when the logger or its next health report clears them.
        Impact, orientation and GPS-moved alerts stay open until an operator
        resolves them after checking the site. Acknowledging records that
        someone is handling an alert.
      </p>
      <LoadState
        loading={data.loading && !data.data}
        error={data.error}
        empty={alerts.length === 0}
        emptyText={`No ${state.value === "all" ? "" : state.value + " "}alerts.`}
        label="alerts"
      />
      {alerts.length > 0 && (
        <TableRegion label="Alert history">
          <table>
            <thead>
              <tr>
                <th>Alert</th>
                <th>Trigger</th>
                <th>Opened / resolved</th>
                <th>Handling</th>
              </tr>
            </thead>
            <tbody>
              {alerts.map((alert) => (
                <tr key={alert.id}>
                  <td>
                    <strong class={alert.state === "open" ? "error-text" : ""}>
                      {alertLabel(alert)}
                    </strong>
                    <small>
                      #{alert.id} · {alert.state}
                      {alert.severity ? ` · ${alert.severity}` : ""}
                    </small>
                    {!props.device && (
                      <small>
                        <a
                          href={`#${query({ device: alert.device_id, view: "alerts" })}`}
                        >
                          {alert.display_name || alert.device_id}
                        </a>
                      </small>
                    )}
                  </td>
                  <td>
                    {alertValue(alert)}
                    {alertNotes(alert).map((note) => (
                      <small key={note}>{note}</small>
                    ))}
                  </td>
                  <td>
                    {stamp(alert.opened_at)}
                    {reportedLate(alert) && (
                      <small>{reportedLate(alert)}</small>
                    )}
                    <small>
                      {alert.state === "resolved"
                        ? resolution(alert)
                        : isLatched(alert.kind)
                          ? "open until an operator resolves it"
                          : "open"}
                    </small>
                    {alert.resolve_note && (
                      <small>“{alert.resolve_note}”</small>
                    )}
                  </td>
                  <td>
                    {alert.acknowledged_at ? (
                      <>
                        Acknowledged by {alert.acknowledged_by}
                        <small>{stamp(alert.acknowledged_at)}</small>
                        {alert.ack_note && <small>“{alert.ack_note}”</small>}
                      </>
                    ) : (
                      alert.state === "open" && (
                        <span class="muted">Not acknowledged</span>
                      )
                    )}
                    {props.operator &&
                      alert.state === "open" &&
                      editing.id !== alert.id && (
                        <div class="row-actions">
                          {!alert.acknowledged_at && (
                            <button
                              type="button"
                              onClick$={() => {
                                editing.id = alert.id;
                                editing.action = "acknowledge";
                                editing.note = "";
                              }}
                            >
                              Acknowledge
                            </button>
                          )}
                          <button
                            type="button"
                            onClick$={() => {
                              editing.id = alert.id;
                              editing.action = "resolve";
                              editing.note = "";
                            }}
                          >
                            Resolve
                          </button>
                        </div>
                      )}
                    {editing.id === alert.id && (
                      <form
                        class="inline-form"
                        preventdefault:submit
                        onSubmit$={submit}
                      >
                        <label class="field" for={`alert-note-${alert.id}`}>
                          Note (
                          {editing.action === "acknowledge"
                            ? "optional"
                            : "why it is closed"}
                          )
                          <input
                            id={`alert-note-${alert.id}`}
                            value={editing.note}
                            maxLength={500}
                            onInput$={(_, el) => {
                              editing.note = el.value;
                            }}
                          />
                        </label>
                        <div class="row-actions">
                          <button
                            class="primary"
                            type="submit"
                            disabled={action.pending}
                          >
                            {editing.action === "acknowledge"
                              ? "Acknowledge"
                              : "Resolve"}{" "}
                            #{alert.id}
                          </button>
                          <button
                            type="button"
                            onClick$={() => {
                              editing.id = 0;
                            }}
                          >
                            Cancel
                          </button>
                        </div>
                      </form>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableRegion>
      )}
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

const policyText = (key: string, value: unknown) =>
  value == null
    ? "—"
    : key === "stale_enabled"
      ? value
        ? "on"
        : "off"
      : String(value);

/** Editor for one policy level (fleet, project or device). Empty inherits. */
export const PolicyEditor = component$<{
  scope: "fleet" | "project" | "device";
  target: string | null;
  values: PolicyValues | null;
  inherited?: PolicyValues | null;
  saved: QRL<() => void>;
  title: string;
}>((props) => {
  const draft = useStore<Record<string, string>>(policyDraft(props.values));
  const action = useStore({ pending: false, message: "", failed: false });
  const built = useComputed$(() => buildPolicy(draft));
  const save = $(async () => {
    if (action.pending || Object.keys(built.value.errors).length) return;
    action.pending = true;
    action.message = "";
    try {
      await send("PUT", "/api/alert-policies", {
        scope: props.scope,
        target: props.target,
        ...built.value.values,
      });
      action.message = "Policy saved.";
      action.failed = false;
      await props.saved();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const remove = $(async () => {
    action.pending = true;
    action.message = "";
    try {
      await send(
        "DELETE",
        `/api/alert-policies?${query({ scope: props.scope, target: props.target || "" })}`,
      );
      for (const key of Object.keys(draft)) draft[key] = "";
      action.message = "Override removed; values are inherited.";
      action.failed = false;
      await props.saved();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const prefix = `policy-${props.scope}-${props.target || "all"}`.replace(
    /[^A-Za-z0-9-]/g,
    "_",
  );
  return (
    <form class="command-section" preventdefault:submit onSubmit$={save}>
      <h3>{props.title}</h3>
      <fieldset disabled={action.pending}>
        <legend class="sr-only">{props.title}</legend>
        <div class="config-fields">
          {POLICY_FIELDS.map(([key, label]) => (
            <label key={key} class="field" for={`${prefix}-${key}`}>
              {label}
              <input
                id={`${prefix}-${key}`}
                inputMode="numeric"
                value={draft[key]}
                placeholder={
                  props.inherited?.[key] != null
                    ? `inherit (${props.inherited[key]})`
                    : "inherit"
                }
                aria-invalid={!!built.value.errors[key]}
                onInput$={(_, el) => {
                  draft[key] = el.value;
                }}
              />
              {built.value.errors[key] && (
                <small class="error-text">{built.value.errors[key]}</small>
              )}
            </label>
          ))}
          <label class="field" for={`${prefix}-stale`}>
            Missed-connection alerts
            <select
              id={`${prefix}-stale`}
              value={draft.stale_enabled}
              onChange$={(_, el) => {
                draft.stale_enabled = el.value;
              }}
            >
              <option value="">
                {`inherit${
                  props.inherited?.stale_enabled != null
                    ? ` (${props.inherited.stale_enabled ? "on" : "off"})`
                    : ""
                }`}
              </option>
              <option value="true">on</option>
              <option value="false">off</option>
            </select>
          </label>
        </div>
        <div class="row-actions">
          <button
            class="primary"
            type="submit"
            disabled={Object.keys(built.value.errors).length > 0}
          >
            Save {props.scope} policy
          </button>
          {props.values && (
            <button type="button" onClick$={remove}>
              Remove {props.scope} override
            </button>
          )}
        </div>
      </fieldset>
      <Feedback message={action.message} failed={action.failed} />
    </form>
  );
});

export const DevicePolicyPanel = component$<{
  device: Device;
  revision: number;
  operator: boolean;
}>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() =>
    devicePath(props.device.device_id, "/alert-policy"),
  );
  const { state, reload } = useJson<DevicePolicy>(url, rev);
  const policy = state.data;
  const keys = [
    ...POLICY_FIELDS.map(([key, label]) => [key, label] as const),
    ["stale_enabled", "Missed-connection alerts"] as const,
  ];
  return (
    <section aria-labelledby="policy-heading">
      <h2 id="policy-heading">Alert thresholds</h2>
      <LoadState
        loading={state.loading && !policy}
        error={state.error}
        label="alert policy"
      />
      {policy && (
        <>
          <TableRegion label="Effective alert thresholds">
            <table>
              <thead>
                <tr>
                  <th>Threshold</th>
                  <th>Effective</th>
                  <th>From</th>
                </tr>
              </thead>
              <tbody>
                {keys.map(([key, label]) => (
                  <tr key={key}>
                    <td>{label}</td>
                    <td class="numeric">
                      {policyText(
                        key,
                        policy.effective[key as keyof PolicyValues],
                      )}
                    </td>
                    <td>
                      {policy.sources[key] === "project"
                        ? `project ${policy.project}`
                        : policy.sources[key] || "default"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableRegion>
          {props.operator && (
            <PolicyEditor
              key={`device-${props.device.device_id}`}
              scope="device"
              target={props.device.device_id}
              values={policy.levels.device}
              inherited={policy.effective}
              saved={reload}
              title="Device override"
            />
          )}
        </>
      )}
    </section>
  );
});

export const LimitsEditor = component$<{
  device: Device;
  operator: boolean;
  refresh: QRL<() => void>;
}>((props) => {
  const d = props.device;
  const rev2 = d.capabilities?.protocol === 2;
  const settings = (d.settings || {}) as Record<string, unknown>;
  const text = (v: unknown) => (v == null ? "" : String(v));
  const draft = useStore<Record<string, string>>({
    min_limit: text(d.min_limit),
    max_limit: text(d.max_limit),
    min_hysteresis: text(rev2 ? settings.lo_hys : d.min_hysteresis),
    max_hysteresis: text(rev2 ? settings.hi_hys : d.max_hysteresis),
  });
  const action = useStore({ pending: false, message: "", failed: false });
  const built = useComputed$(() => buildLimits(draft));
  const save = $(async () => {
    if (action.pending || Object.keys(built.value.errors).length) return;
    action.pending = true;
    action.message = "";
    try {
      const result = await send<{ command?: { id: number } }>(
        "PUT",
        devicePath(d.device_id, "/limits"),
        built.value.body,
      );
      action.message = result.command
        ? `Settings command #${result.command.id} queued (lo/hi/lo_hys/hi_hys). ${nextContactText(d)} The limits change when the logger acknowledges; Settings shows the per-key result.`
        : "Limits saved; level alerts are replayed with the new thresholds.";
      action.failed = false;
      await props.refresh();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const fields = [
    ["min_limit", "Low limit (m)"],
    ["min_hysteresis", "Low limit hysteresis (m)"],
    ["max_limit", "High limit (m)"],
    ["max_hysteresis", "High limit hysteresis (m)"],
  ] as const;
  return (
    <section aria-labelledby="limits-heading">
      <h2 id="limits-heading">Level limits</h2>
      <p class="muted">
        {rev2
          ? "Firmware 2.2 raises level alarms itself. Saving queues a settings command (lo, hi, lo_hys, hi_hys); the server limits follow the logger's acknowledged settings."
          : "Raw metres. An alert clears once the level is back inside the limit by the hysteresis (0.5 m when unset)."}
      </p>
      <dl class="facts">
        <div>
          <dt>Current low / high</dt>
          <dd>
            {d.min_limit ?? "unset"} / {d.max_limit ?? "unset"} m
          </dd>
        </div>
      </dl>
      {props.operator && (
        <form class="command-section" preventdefault:submit onSubmit$={save}>
          <fieldset disabled={action.pending || d.revoked}>
            <legend class="sr-only">Level limits</legend>
            <div class="config-fields">
              {fields.map(([key, label]) => (
                <label key={key} class="field" for={`limit-${key}`}>
                  {label}
                  <input
                    id={`limit-${key}`}
                    inputMode="decimal"
                    value={draft[key]}
                    placeholder="unset"
                    aria-invalid={!!built.value.errors[key]}
                    onInput$={(_, el) => {
                      draft[key] = el.value;
                    }}
                  />
                  {built.value.errors[key] && (
                    <small class="error-text">{built.value.errors[key]}</small>
                  )}
                </label>
              ))}
            </div>
            <button
              class="primary"
              type="submit"
              disabled={Object.keys(built.value.errors).length > 0}
            >
              {rev2 ? "Queue limit settings" : "Save limits"}
            </button>
          </fieldset>
          <Feedback message={action.message} failed={action.failed} />
        </form>
      )}
    </section>
  );
});
