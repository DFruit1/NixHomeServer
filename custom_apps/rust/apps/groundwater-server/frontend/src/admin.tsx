// Fleet pages: gap report and the operator admin page (enrollment, alert
// policies, notifications, audit).
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  type QRL,
} from "@builder.io/qwik";
import { errorText, query, stamp } from "./api";
import { PolicyEditor } from "./alerts";
import { show } from "./format";
import { send, useJson } from "./hooks";
import { TOPIC, buildEnrollment, emptyEnroll, type EnrollDraft } from "./ops";
import type {
  AlertPolicy,
  AuditRow,
  Device,
  GapReportRow,
  NotificationDelivery,
  NotificationRow,
  NotificationRule,
  PolicyValues,
} from "./types";
import { Feedback, LoadState, TableRegion, WindowPicker } from "./widgets";

export const GapsPage = component$<{ revision: number }>((props) => {
  const hours = useSignal(720);
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() => {
    void props.revision;
    const from = new Date(Date.now() - hours.value * 3600000).toISOString();
    return `/api/gaps/report?${query({ from })}`;
  });
  const { state } = useJson<{
    from: string;
    to: string;
    devices: GapReportRow[];
    totals: Partial<GapReportRow>;
  }>(url, rev);
  const rows = state.data?.devices || [];
  const totals = state.data?.totals || {};
  return (
    <section aria-labelledby="gaps-page-heading">
      <div class="section-heading">
        <h1 id="gaps-page-heading">Data gaps</h1>
        <WindowPicker
          hours={hours}
          options={[168, 720, 2160, 8760]}
          label="Gap report window"
        />
      </div>
      <p class="muted">
        Sequence gaps detected in uploaded ring data and gaps the loggers
        reported themselves, per device, for the chosen window.
      </p>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No devices are visible to your account."
        label="gap report"
      />
      {rows.length > 0 && (
        <TableRegion label="Gap report">
          <table>
            <thead>
              <tr>
                <th>Device</th>
                <th>Open / requested</th>
                <th>Unrecoverable</th>
                <th>Filled</th>
                <th>Logger gaps</th>
                <th>Frames / logs</th>
                <th>Oldest open / last batch</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.device_id}>
                  <td>
                    <a
                      class="device-link"
                      href={`#${query({ device: r.device_id, view: r.protocol_rev === 2 ? "stream" : "history" })}`}
                    >
                      {r.display_name || r.device_id}
                    </a>
                    <small class="mono">{r.device_id}</small>
                  </td>
                  <td
                    class={
                      r.open + r.requested ? "numeric error-text" : "numeric"
                    }
                  >
                    {r.open} / {r.requested}
                    <small>{r.missing_open} frames</small>
                  </td>
                  <td
                    class={r.unrecoverable ? "numeric error-text" : "numeric"}
                  >
                    {r.unrecoverable}
                    <small>{r.missing_unrecoverable} frames</small>
                  </td>
                  <td class="numeric">{r.filled}</td>
                  <td class="numeric">{r.data_gap_events}</td>
                  <td class="numeric">
                    {r.frames.toLocaleString()} / {r.logs}
                  </td>
                  <td>
                    {stamp(r.oldest_open_at)}
                    <small>{stamp(r.last_stream_at)}</small>
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <th scope="row">Fleet</th>
                <td class="numeric">
                  {show(totals.open)} / {show(totals.requested)}
                  <small>{show(totals.missing_open)} frames</small>
                </td>
                <td class="numeric">
                  {show(totals.unrecoverable)}
                  <small>{show(totals.missing_unrecoverable)} frames</small>
                </td>
                <td class="numeric">{show(totals.filled)}</td>
                <td class="numeric">{show(totals.data_gap_events)}</td>
                <td class="numeric">
                  {show(totals.frames)} / {show(totals.logs)}
                </td>
                <td></td>
              </tr>
            </tfoot>
          </table>
        </TableRegion>
      )}
    </section>
  );
});

export const EnrollForm = component$<{ refresh: QRL<() => void> }>((props) => {
  const draft = useStore<EnrollDraft>(emptyEnroll());
  const touched = useSignal(false);
  const action = useStore({
    pending: false,
    message: "",
    failed: false,
    device: "",
  });
  const built = useComputed$(() => buildEnrollment(draft));
  const submit = $(async () => {
    touched.value = true;
    if (action.pending || Object.keys(built.value.errors).length) return;
    action.pending = true;
    action.message = "";
    try {
      const result = await send<{ device: Device }>(
        "POST",
        "/api/devices",
        built.value.body,
      );
      action.device = result.device?.device_id || built.value.body.device_id;
      action.message = `Enrolled ${action.device}. The ingest registry picks it up within a minute.`;
      action.failed = false;
      Object.assign(draft, emptyEnroll());
      touched.value = false;
      await props.refresh();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
      action.device = "";
    } finally {
      action.pending = false;
    }
  });
  const error = (key: keyof EnrollDraft) =>
    touched.value && built.value.errors[key] ? (
      <small class="error-text">{built.value.errors[key]}</small>
    ) : null;
  const text = (key: keyof EnrollDraft, label: string, hint = "") => (
    <label class="field" for={`enroll-${key}`}>
      {label}
      <input
        id={`enroll-${key}`}
        value={draft[key]}
        autoComplete="off"
        spellcheck={false}
        aria-invalid={touched.value && !!built.value.errors[key]}
        onInput$={(_, el) => {
          draft[key] = el.value;
        }}
      />
      {hint && <small>{hint}</small>}
      {error(key)}
    </label>
  );
  return (
    <section aria-labelledby="enroll-heading">
      <h2 id="enroll-heading">Enroll a device</h2>
      <p class="muted">
        Creates the enrollment, every gwl/v1/&lt;DeviceID&gt;/ topic binding
        (both protocol revisions) and viewer grants in one step. Legacy
        shared-topic units (V20, MQTT-Logger) stay an SQL procedure.
      </p>
      <form preventdefault:submit onSubmit$={submit}>
        <fieldset disabled={action.pending}>
          <legend class="sr-only">New device</legend>
          <div class="config-fields">
            {text("device_id", "DeviceID", "24 hexadecimal characters")}
            {text("display_name", "Name")}
            <label class="field" for="enroll-profile">
              Firmware profile
              <select
                id="enroll-profile"
                value={draft.profile}
                onChange$={(_, el) => {
                  draft.profile = el.value;
                  if (el.value === "V22") draft.clock_policy = "utc";
                }}
              >
                <option value="V22">
                  V22 (firmware 2.2, protocol revision 2)
                </option>
                <option value="V21">V21 (firmware 2.1 on gwl/v1)</option>
              </select>
              {error("profile")}
            </label>
            <label class="field" for="enroll-clock">
              Clock policy
              <select
                id="enroll-clock"
                value={draft.profile === "V22" ? "utc" : draft.clock_policy}
                disabled={draft.profile === "V22"}
                onChange$={(_, el) => {
                  draft.clock_policy = el.value;
                }}
              >
                <option value="utc">utc</option>
                <option value="local-offset">local-offset</option>
                <option value="unknown">unknown</option>
              </select>
              <small>
                {draft.profile === "V22"
                  ? "Firmware 2.2 sends UTC with a validity flag."
                  : "Confirm what the firmware writes before choosing."}
              </small>
              {error("clock_policy")}
            </label>
            {draft.profile !== "V22" &&
              draft.clock_policy === "local-offset" &&
              text("local_offset_min", "Local offset (minutes)", "−720 … 840")}
            {text("location_id", "Location ID")}
            {text("sensor_id", "Sensor ID")}
            {text("project", "Project", "Groups alert policies")}
            <label class="field" for="enroll-bindings">
              Topic bindings
              <select
                id="enroll-bindings"
                value={draft.bindings}
                onChange$={(_, el) => {
                  draft.bindings = el.value;
                }}
              >
                <option value="gwl/v1">
                  gwl/v1/&lt;DeviceID&gt;/… (all channels)
                </option>
                <option value="none">None (add later)</option>
              </select>
            </label>
            {text(
              "viewers",
              "Viewer accounts",
              "Usernames separated by commas or spaces",
            )}
          </div>
          <label class="field" for="enroll-notes">
            Notes
            <textarea
              id="enroll-notes"
              rows={2}
              value={draft.notes}
              onInput$={(_, el) => {
                draft.notes = el.value;
              }}
            />
          </label>
          <button class="primary" type="submit" aria-busy={action.pending}>
            {action.pending ? "Enrolling…" : "Enroll device"}
          </button>
        </fieldset>
      </form>
      <Feedback message={action.message} failed={action.failed} />
      {action.device && (
        <p>
          <a
            href={`#${query({ device: action.device, view: "installation" })}`}
          >
            Open the new device's installation page
          </a>
        </p>
      )}
    </section>
  );
});

export const PoliciesAdmin = component$<{
  revision: number;
  projects: string[];
}>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() => "/api/alert-policies");
  const { state, reload } = useJson<{
    policies: AlertPolicy[];
    defaults: PolicyValues;
  }>(url, rev);
  const newProject = useSignal("");
  const policies = state.data?.policies || [];
  const fleet = policies.find((p) => p.scope === "fleet") || null;
  const projects = policies.filter((p) => p.scope === "project");
  const devices = policies.filter((p) => p.scope === "device");
  const candidates = props.projects.filter(
    (name) => name && !projects.some((p) => p.target === name),
  );
  return (
    <section aria-labelledby="policies-heading">
      <h2 id="policies-heading">Alert policies</h2>
      <p class="muted">
        Each threshold resolves device → project → fleet → built-in default.
        Empty fields inherit. Device overrides are edited on each device's
        Alerts tab.
      </p>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        label="policies"
      />
      {state.data && (
        <>
          <PolicyEditor
            key="fleet"
            scope="fleet"
            target={null}
            values={fleet}
            inherited={state.data.defaults}
            saved={reload}
            title="Fleet default"
          />
          {projects.map((p) => (
            <PolicyEditor
              key={`project-${p.target}`}
              scope="project"
              target={p.target}
              values={p}
              inherited={fleet || state.data!.defaults}
              saved={reload}
              title={`Project ${p.target}`}
            />
          ))}
          {newProject.value ? (
            <PolicyEditor
              key={`new-${newProject.value}`}
              scope="project"
              target={newProject.value}
              values={null}
              inherited={fleet || state.data.defaults}
              saved={reload}
              title={`Project ${newProject.value} (new)`}
            />
          ) : (
            <form
              class="toolbar"
              preventdefault:submit
              onSubmit$={(_, form) => {
                const value = (
                  form.elements.namedItem("project-name") as HTMLInputElement
                ).value.trim();
                if (value) newProject.value = value;
              }}
            >
              <label class="field" for="project-name">
                Add a project policy
                <input id="project-name" name="project-name" />
                {candidates.length > 0 && (
                  <small>
                    Projects without a policy: {candidates.join(", ")}
                  </small>
                )}
              </label>
              <button type="submit">Add project policy</button>
            </form>
          )}
          {devices.length > 0 && (
            <p class="muted">
              Device overrides:{" "}
              {devices.map((p, i) => (
                <span key={p.target!}>
                  {i ? ", " : ""}
                  <a href={`#${query({ device: p.target!, view: "alerts" })}`}>
                    {p.target}
                  </a>
                </span>
              ))}
            </p>
          )}
        </>
      )}
    </section>
  );
});

const SEVERITIES = ["info", "warning", "critical"];

export const NotificationsAdmin = component$<{ revision: number }>((props) => {
  const rev = useComputed$(() => props.revision);
  const rulesUrl = useComputed$(() => "/api/notifications/rules");
  const logUrl = useComputed$(() => "/api/notifications?limit=100");
  const rules = useJson<{
    rules: NotificationRule[];
    delivery: NotificationDelivery;
  }>(rulesUrl, rev);
  const log = useJson<{ notifications: NotificationRow[] }>(logUrl, rev);
  const drafts = useStore<Record<string, Record<string, string | boolean>>>({});
  const action = useStore({ pending: "", message: "", failed: false });
  const save = $(async (rule: NotificationRule) => {
    const d = { ...ruleDraft(rule), ...(drafts[rule.kind] || {}) };
    const cooldown = Number(d.cooldown_min);
    const topic = String(d.topic || "").trim();
    if (!Number.isInteger(cooldown) || cooldown < 0 || cooldown > 10080) {
      action.message = "Cooldown must be 0 … 10080 minutes.";
      action.failed = true;
      return;
    }
    if (topic && !TOPIC.test(topic)) {
      action.message =
        "Topic overrides use letters, digits, - and _ (up to 64).";
      action.failed = true;
      return;
    }
    action.pending = rule.kind;
    action.message = "";
    try {
      await send(
        "PUT",
        `/api/notifications/rules/${encodeURIComponent(rule.kind)}`,
        {
          enabled: !!d.enabled,
          min_severity: d.min_severity,
          priority: Number(d.priority),
          cooldown_min: cooldown,
          notify_resolved: !!d.notify_resolved,
          topic: topic || null,
        },
      );
      delete drafts[rule.kind];
      action.message = `${rule.label} saved.`;
      action.failed = false;
      rules.reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = "";
    }
  });
  const test = $(async () => {
    action.pending = "test";
    action.message = "";
    try {
      await send("POST", "/api/notifications/test", {});
      action.message = "Test notification sent to ntfy.";
      action.failed = false;
      log.reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = "";
    }
  });
  const delivery = rules.state.data?.delivery;
  const rows = log.state.data?.notifications || [];
  return (
    <section aria-labelledby="notify-heading">
      <h2 id="notify-heading">Notifications</h2>
      <LoadState
        loading={rules.state.loading && !rules.state.data}
        error={rules.state.error}
        label="notification rules"
      />
      {delivery && (
        <>
          <dl class="facts">
            <div>
              <dt>ntfy delivery</dt>
              <dd class={delivery.configured ? "" : "error-text"}>
                {delivery.configured
                  ? `${delivery.server}/${delivery.topic}`
                  : "Not configured (GROUNDWATER_NTFY_URL unset): notifications are recorded as skipped."}
              </dd>
            </div>
            <div>
              <dt>Links point to</dt>
              <dd>{delivery.public_url || "—"}</dd>
            </div>
            <div>
              <dt>Fleet cap</dt>
              <dd>{delivery.max_per_hour} per hour</dd>
            </div>
          </dl>
          <button
            type="button"
            onClick$={test}
            disabled={!delivery.configured || !!action.pending}
          >
            Send test notification
          </button>
        </>
      )}
      {(rules.state.data?.rules || []).length > 0 && (
        <TableRegion label="Notification rules">
          <table>
            <thead>
              <tr>
                <th>Kind</th>
                <th>Send</th>
                <th>Minimum severity</th>
                <th>ntfy priority</th>
                <th>Cooldown (min)</th>
                <th>Topic override</th>
                <th>Save</th>
              </tr>
            </thead>
            <tbody>
              {rules.state.data!.rules.map((rule) => {
                const d = { ...ruleDraft(rule), ...(drafts[rule.kind] || {}) };
                const set = (key: string, value: string | boolean) => {
                  drafts[rule.kind] = {
                    ...(drafts[rule.kind] || {}),
                    [key]: value,
                  };
                };
                const id = `rule-${rule.kind}`;
                return (
                  <tr key={rule.kind}>
                    <td>
                      <strong>{rule.label}</strong>
                      <small>
                        {rule.kind} · {rule.source} ·{" "}
                        {rule.severities.join("/")}
                      </small>
                      {rule.updated_by && (
                        <small>
                          {rule.updated_by} · {stamp(rule.updated_at)}
                        </small>
                      )}
                    </td>
                    <td>
                      <label class="checkbox" for={`${id}-enabled`}>
                        <input
                          id={`${id}-enabled`}
                          type="checkbox"
                          checked={!!d.enabled}
                          onChange$={(_, el) => set("enabled", el.checked)}
                        />
                        enabled
                      </label>
                      <label class="checkbox" for={`${id}-resolved`}>
                        <input
                          id={`${id}-resolved`}
                          type="checkbox"
                          checked={!!d.notify_resolved}
                          onChange$={(_, el) =>
                            set("notify_resolved", el.checked)
                          }
                        />
                        resolutions
                      </label>
                    </td>
                    <td>
                      <select
                        aria-label={`${rule.label} minimum severity`}
                        value={String(d.min_severity)}
                        onChange$={(_, el) => set("min_severity", el.value)}
                      >
                        {SEVERITIES.map((s) => (
                          <option key={s} value={s}>
                            {s}
                          </option>
                        ))}
                      </select>
                    </td>
                    <td>
                      <select
                        aria-label={`${rule.label} ntfy priority`}
                        value={String(d.priority)}
                        onChange$={(_, el) => set("priority", el.value)}
                      >
                        {[1, 2, 3, 4, 5].map((p) => (
                          <option key={p} value={String(p)}>
                            {String(p)}
                          </option>
                        ))}
                      </select>
                    </td>
                    <td>
                      <input
                        aria-label={`${rule.label} cooldown minutes`}
                        inputMode="numeric"
                        value={String(d.cooldown_min)}
                        onInput$={(_, el) => set("cooldown_min", el.value)}
                      />
                    </td>
                    <td>
                      <input
                        aria-label={`${rule.label} topic override`}
                        value={String(d.topic || "")}
                        placeholder={delivery?.topic || "default"}
                        onInput$={(_, el) => set("topic", el.value)}
                      />
                    </td>
                    <td>
                      <button
                        type="button"
                        disabled={!drafts[rule.kind] || !!action.pending}
                        onClick$={() => save(rule)}
                      >
                        Save
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </TableRegion>
      )}
      <Feedback message={action.message} failed={action.failed} />
      <h3>Recent notifications</h3>
      <LoadState
        loading={log.state.loading && !log.state.data}
        error={log.state.error}
        empty={rows.length === 0}
        emptyText="No notifications yet."
        label="notifications"
      />
      {rows.length > 0 && (
        <TableRegion label="Recent notifications" bounded>
          <table>
            <thead>
              <tr>
                <th>Notification</th>
                <th>Device</th>
                <th>State</th>
                <th>Created / sent</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((n) => (
                <tr key={n.id}>
                  <td>
                    <strong>{n.title}</strong>
                    <small>
                      {n.kind} · {n.severity} · {n.transition}
                    </small>
                    <small>{n.message}</small>
                  </td>
                  <td>
                    <a
                      href={`#${query({ device: n.device_id, view: "alerts" })}`}
                    >
                      {n.display_name || n.device_id}
                    </a>
                  </td>
                  <td>
                    <span
                      class={
                        n.state === "failed" ? "state error-text" : "state"
                      }
                    >
                      {n.state}
                    </span>
                    {n.reason && <small>{n.reason}</small>}
                    {n.suppressed_count > 0 && (
                      <small>{n.suppressed_count} similar suppressed</small>
                    )}
                    {n.attempts > 1 && <small>{n.attempts} attempts</small>}
                  </td>
                  <td>
                    {stamp(n.created_at)}
                    <small>{stamp(n.sent_at)}</small>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableRegion>
      )}
    </section>
  );
});

function ruleDraft(rule: NotificationRule): Record<string, string | boolean> {
  return {
    enabled: rule.enabled,
    min_severity: rule.min_severity,
    priority: String(rule.priority),
    cooldown_min: String(rule.cooldown_min),
    notify_resolved: rule.notify_resolved,
    topic: rule.topic || "",
  };
}

export const AuditList = component$<{
  url: string;
  revision: number;
  title: string;
  fleet?: boolean;
}>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() => props.url);
  const { state } = useJson<{ audit: AuditRow[] }>(url, rev);
  const rows = state.data?.audit || [];
  return (
    <section>
      <h2>{props.title}</h2>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No audit entries."
        label="audit"
      />
      {rows.length > 0 && (
        <TableRegion label={props.title} bounded>
          <table>
            <thead>
              <tr>
                <th>When</th>
                <th>Who</th>
                <th>Action</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{stamp(r.created_at)}</td>
                  <td>{r.actor}</td>
                  <td>
                    {r.action.replaceAll("_", " ")}
                    {props.fleet && r.device_id && (
                      <small>
                        <a
                          href={`#${query({ device: r.device_id, view: "installation" })}`}
                        >
                          {r.device_id}
                        </a>
                      </small>
                    )}
                  </td>
                  <td>
                    {r.detail == null ? (
                      "—"
                    ) : (
                      <details>
                        <summary>Detail</summary>
                        <pre>{JSON.stringify(r.detail, null, 2)}</pre>
                      </details>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableRegion>
      )}
    </section>
  );
});

export const ADMIN_SECTIONS = [
  ["enroll", "Enroll"],
  ["policies", "Alert policies"],
  ["notifications", "Notifications"],
  ["audit", "Audit"],
] as const;

export const AdminPage = component$<{
  revision: number;
  devices: Device[];
  section: string;
  refresh: QRL<() => void>;
}>((props) => {
  const projects = [
    ...new Set(props.devices.map((d) => d.project || "").filter(Boolean)),
  ].sort();
  const section = ADMIN_SECTIONS.some(([key]) => key === props.section)
    ? props.section
    : "enroll";
  return (
    <>
      <h1>Administration</h1>
      <nav class="view-nav" aria-label="Administration sections">
        {ADMIN_SECTIONS.map(([key, label]) => (
          <a
            key={key}
            href={`#${query({ view: "admin", section: key })}`}
            aria-current={section === key ? "page" : undefined}
          >
            {label}
          </a>
        ))}
      </nav>
      {section === "enroll" && <EnrollForm refresh={props.refresh} />}
      {section === "policies" && (
        <PoliciesAdmin revision={props.revision} projects={projects} />
      )}
      {section === "notifications" && (
        <NotificationsAdmin revision={props.revision} />
      )}
      {section === "audit" && (
        <AuditList
          url="/api/audit?limit=200"
          revision={props.revision}
          title="Fleet audit"
          fleet
        />
      )}
    </>
  );
});
