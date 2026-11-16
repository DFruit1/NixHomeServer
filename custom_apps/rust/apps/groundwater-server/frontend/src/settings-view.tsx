// Revision 2 logger settings: effective values, editor and generation history.
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { errorText, query, stamp } from "./api";
import { nextContactText } from "./console";
import { EXPIRY_PRESETS, expiryError, show } from "./format";
import { devicePath, send, useJson } from "./hooks";
import {
  SETTING_DEFAULTS,
  SETTING_FIELDS,
  changedSettings,
  sameSetting,
  settingText,
  settingsDiff,
  validateSettings,
} from "./settings";
import type { Command, Device, SettingsResponse } from "./types";
import { Feedback, LoadState, TableRegion } from "./widgets";

type Props = { device: Device; revision: number; operator: boolean };

const GROUPS = [...new Set(SETTING_FIELDS.map((f) => f.group))];

export const SettingsView = component$<Props>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() =>
    devicePath(props.device.device_id, "/settings"),
  );
  const { state, reload } = useJson<SettingsResponse>(url, rev);
  const drafts = useStore<Record<string, string>>({});
  const replace = useSignal(false);
  const expiry = useSignal(7 * 86400);
  const action = useStore({ pending: false, message: "", failed: false });
  const effective = (state.data?.effective.settings ||
    props.device.settings ||
    {}) as Record<string, unknown>;
  const changes = useComputed$(() => {
    const base = (state.data?.effective.settings ||
      props.device.settings ||
      {}) as Record<string, unknown>;
    const edited = Object.fromEntries(
      Object.entries(drafts).filter(([, v]) => v !== undefined),
    );
    const diff = changedSettings(edited, base);
    return {
      diff,
      errors: Object.keys(diff).length
        ? validateSettings(diff, Math.floor(Date.now() / 1000))
        : [],
    };
  });
  const commandsUrl = useComputed$(
    () => `/api/commands?${query({ device: props.device.device_id })}`,
  );
  const commands = useJson<{ commands: Command[] }>(commandsUrl, rev);
  const dirty = Object.keys(changes.value.diff).length > 0;
  const dirtySignal = useComputed$(
    () => Object.keys(changes.value.diff).length > 0,
  );
  // Edits are lost on reload or when leaving the view; ask first.
  useVisibleTask$(({ track, cleanup }) => {
    if (!track(() => dirtySignal.value)) return;
    const message = "Discard unsent settings edits?";
    const unload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = message;
    };
    const click = (event: MouseEvent) => {
      const link = (event.target as Element | null)?.closest?.("a[href]");
      const href = link?.getAttribute("href") || "";
      if (href.startsWith("#") && !window.confirm(message)) {
        event.preventDefault();
        event.stopPropagation();
      }
    };
    window.addEventListener("beforeunload", unload);
    document.addEventListener("click", click, true);
    cleanup(() => {
      window.removeEventListener("beforeunload", unload);
      document.removeEventListener("click", click, true);
    });
  });
  const submit = $(async () => {
    const diff = changes.value.diff;
    if (
      action.pending ||
      !Object.keys(diff).length ||
      changes.value.errors.length
    )
      return;
    if (expiryError(expiry.value)) return;
    action.pending = true;
    action.message = "";
    try {
      await send("POST", devicePath(props.device.device_id, "/settings"), {
        settings: diff,
        replace: replace.value,
        expires_in_s: expiry.value,
      });
      action.message = `Settings queued. ${nextContactText(props.device)} Effective values change only when the logger acknowledges.`;
      action.failed = false;
      for (const key of Object.keys(drafts)) delete drafts[key];
      replace.value = false;
      reload();
      commands.reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const requests = (commands.state.data?.commands || []).filter(
    (c) => c.protocol === 2 && c.op === "settings",
  );
  const waiting = requests.filter((c) => ["queued", "sent"].includes(c.state));
  const history = state.data?.history || [];
  const changedKeys = Object.keys(changes.value.diff);
  return (
    <>
      <section aria-labelledby="settings-heading">
        <div class="section-heading">
          <h2 id="settings-heading">Logger settings</h2>
          <span class="muted">
            Generation{" "}
            {show(
              state.data?.effective.settings_gen ?? props.device.settings_gen,
            )}{" "}
            · reported{" "}
            {stamp(
              state.data?.effective.settings_at ?? props.device.settings_at,
            )}
          </span>
        </div>
        <LoadState
          loading={state.loading && !state.data}
          error={state.error}
          label="settings"
        />
        {!props.operator && (
          <p class="notice">
            Your viewer account has read-only access to settings.
          </p>
        )}
        <SettingsRequests
          requests={requests.slice(0, 3)}
          effective={effective}
          device={props.device}
          error={commands.state.error}
        />
        {dirty && (
          <p class="notice" role="status">
            Unsent edits: {Object.keys(changes.value.diff).join(", ")}. They are
            discarded if you leave this view.
          </p>
        )}
        <form preventdefault:submit onSubmit$={submit}>
          <fieldset disabled={!props.operator || action.pending}>
            <legend class="sr-only">Logger settings</legend>
            {GROUPS.map((group) => (
              <div key={group} class="settings-group">
                <h3>{group}</h3>
                <div class="config-fields">
                  {SETTING_FIELDS.filter((f) => f.group === group).map(
                    (field) => {
                      const current =
                        field.key in effective
                          ? effective[field.key]
                          : SETTING_DEFAULTS[field.key];
                      const value =
                        drafts[field.key] !== undefined
                          ? drafts[field.key]
                          : settingText(current);
                      const changed = field.key in changes.value.diff;
                      const id = `setting-${field.key}`;
                      return (
                        <label key={field.key} class="field" for={id}>
                          <span>
                            {field.label} <code>{field.key}</code>
                          </span>
                          {field.key === "text" ? (
                            <textarea
                              id={id}
                              rows={2}
                              value={value}
                              onInput$={(_, el) => {
                                drafts[field.key] = el.value;
                              }}
                            />
                          ) : (
                            <input
                              id={id}
                              value={value}
                              autoComplete="off"
                              spellcheck={false}
                              inputMode={
                                field.kind === "text" ||
                                field.kind === "factors"
                                  ? "text"
                                  : "decimal"
                              }
                              onInput$={(_, el) => {
                                drafts[field.key] = el.value;
                              }}
                            />
                          )}
                          {field.key === "start" &&
                            /^\d+$/.test(value.trim()) &&
                            Number(value) > 0 && (
                              <small>
                                ={" "}
                                {stamp(
                                  new Date(Number(value) * 1000).toISOString(),
                                )}{" "}
                                (your local time)
                              </small>
                            )}
                          {waiting
                            .filter(
                              (c) =>
                                // Qwik store proxies answer `has` for any
                                // key: test the value (null = unset lo/hi).
                                c.args?.[field.key] !== undefined,
                            )
                            .slice(0, 1)
                            .map((c) => (
                              <small key={c.id} class="changed">
                                requested{" "}
                                {settingText(c.args![field.key]) || "empty"} in
                                #{c.id}, waiting for the logger
                              </small>
                            ))}
                          <small>
                            {field.hint} · default{" "}
                            {settingText(SETTING_DEFAULTS[field.key]) ||
                              "empty"}
                            {changed && (
                              <strong class="changed">
                                {" "}
                                · changed from {settingText(current) || "empty"}
                              </strong>
                            )}
                          </small>
                        </label>
                      );
                    },
                  )}
                </div>
              </div>
            ))}
            {props.operator && (
              <div class="command-section">
                <h3>Queue change</h3>
                {changedKeys.length === 0 ? (
                  <p class="muted">
                    Edit a value to queue a change. Only changed keys are sent.
                  </p>
                ) : (
                  <pre>{JSON.stringify(changes.value.diff)}</pre>
                )}
                {changes.value.errors.map((error) => (
                  <p key={error} class="error-text" role="alert">
                    {error}
                  </p>
                ))}
                <label class="checkbox">
                  <input
                    type="checkbox"
                    checked={replace.value}
                    onChange$={(_, el) => {
                      replace.value = el.checked;
                    }}
                  />
                  Replace: reset every key not sent to its firmware default
                  first
                </label>
                {replace.value && (
                  <p class="notice error-text">
                    Replace resets schedule, alarms, calibration and labels that
                    are not part of this change to the defaults shown above.
                  </p>
                )}
                <div class="toolbar">
                  <label class="field" for="settings-expiry">
                    Expires after
                    <select
                      id="settings-expiry"
                      value={String(expiry.value)}
                      onChange$={(_, el) => {
                        expiry.value = Number(el.value);
                      }}
                    >
                      {EXPIRY_PRESETS.map(([seconds, label]) => (
                        <option key={seconds} value={String(seconds)}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <button
                    class="primary"
                    type="submit"
                    disabled={
                      action.pending ||
                      changedKeys.length === 0 ||
                      changes.value.errors.length > 0
                    }
                    aria-busy={action.pending}
                  >
                    {action.pending
                      ? "Queuing…"
                      : `Queue ${changedKeys.length || ""} setting${changedKeys.length === 1 ? "" : "s"}`}
                  </button>
                  <button
                    type="button"
                    disabled={
                      changedKeys.length === 0 &&
                      Object.keys(drafts).length === 0
                    }
                    onClick$={() => {
                      for (const key of Object.keys(drafts)) delete drafts[key];
                    }}
                  >
                    Discard edits
                  </button>
                </div>
              </div>
            )}
          </fieldset>
        </form>
        <Feedback message={action.message} failed={action.failed} />
      </section>
      <section aria-labelledby="settings-history-heading">
        <h2 id="settings-history-heading">Settings history</h2>
        {history.length === 0 ? (
          <p class="empty">No settings generations recorded.</p>
        ) : (
          <TableRegion label="Settings history">
            <table>
              <thead>
                <tr>
                  <th>Generation</th>
                  <th>Source</th>
                  <th>Changes from previous generation</th>
                </tr>
              </thead>
              <tbody>
                {history.map((row) => {
                  const previous = history.find(
                    (other) =>
                      other.settings_gen != null &&
                      row.settings_gen != null &&
                      other.settings_gen < row.settings_gen,
                  );
                  const diff = settingsDiff(row.settings, previous?.settings);
                  return (
                    <tr key={row.id}>
                      <td>
                        <strong>{row.settings_gen ?? "requested"}</strong>
                        <small>{stamp(row.received_at)}</small>
                        <small>
                          {row.activated
                            ? "activated (anchor seen)"
                            : "not yet activated"}
                        </small>
                      </td>
                      <td>
                        {row.source}
                        {row.command_id != null && (
                          <small>command #{row.command_id}</small>
                        )}
                        {row.seq != null && <small>seq {row.seq}</small>}
                        {row.warnings?.length > 0 && (
                          <small class="error-text">
                            {row.warnings.join("; ")}
                          </small>
                        )}
                      </td>
                      <td>
                        {!previous ? (
                          <small>First generation recorded.</small>
                        ) : diff.length === 0 ? (
                          <small>No differences.</small>
                        ) : (
                          <ul class="diff-list">
                            {diff.map((d) => (
                              <li key={d.key}>
                                <code>{d.key}</code>{" "}
                                {settingText(d.before) || "empty"} →{" "}
                                {settingText(d.after) || "empty"}
                              </li>
                            ))}
                          </ul>
                        )}
                        <details>
                          <summary>Full settings</summary>
                          <pre>{JSON.stringify(row.settings, null, 2)}</pre>
                        </details>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </TableRegion>
        )}
      </section>
    </>
  );
});

const STATE_TEXT: Record<string, string> = {
  queued: "queued",
  sent: "published to the broker",
  acked: "answered by the logger",
  expired: "expired",
  cancelled: "cancelled",
  unacknowledged: "no answer after repeated publishes",
};

/** The latest settings requests: per key what was asked, what the logger
 * answered and what is in effect now. A logger answers only at its next
 * connection, which can be days away. */
export const SettingsRequests = component$<{
  requests: Command[];
  effective: Record<string, unknown>;
  device: Device;
  error: string;
}>((props) => {
  if (props.error)
    return (
      <p class="notice error-text" role="alert">
        Settings requests could not be loaded: {props.error}
      </p>
    );
  if (props.requests.length === 0) return null;
  const expected =
    props.device.expected_contact_at || props.device.next_contact_at;
  return (
    <div class="command-section">
      <h3>Requested changes</h3>
      {props.requests.map((c) => {
        const ack = (c.ack_payload || {}) as Record<string, unknown>;
        const results = (
          ack.results && typeof ack.results === "object" ? ack.results : {}
        ) as Record<string, unknown>;
        const pending = ["queued", "sent"].includes(c.state);
        const keys = Object.keys(c.args || {});
        return (
          <div key={c.id} class="settings-request">
            <p>
              <strong>
                #{c.id} · {STATE_TEXT[c.state] || c.state}
                {c.final_status ? `: ${c.final_status}` : ""}
              </strong>{" "}
              <small>
                requested {stamp(c.created_at)} by {c.requested_by}
                {c.expires_at ? ` · expires ${stamp(c.expires_at)}` : ""}
              </small>
            </p>
            {pending && (
              <p class={props.device.status === "stale" ? "error-text" : ""}>
                {c.hold_until_sleep
                  ? "The logger was busy; it is re-sent after its next sleep."
                  : props.device.status === "awake"
                    ? "The logger is awake now; waiting for its answer."
                    : `Waiting for the logger's next connection${expected ? `, expected ${stamp(expected)}` : " (time unknown)"}. Nothing changes on the logger until then.`}
              </p>
            )}
            {c.status_reason && <p class="muted">{c.status_reason}</p>}
            {typeof ack.gen === "number" && (
              <p class="muted">Logger settings generation {ack.gen}.</p>
            )}
            <TableRegion label={`Settings request ${c.id}`}>
              <table>
                <thead>
                  <tr>
                    <th>Key</th>
                    <th>Requested</th>
                    <th>Logger result</th>
                    <th>In effect now</th>
                  </tr>
                </thead>
                <tbody>
                  {keys.map((key) => {
                    const requested = c.args![key];
                    const current = props.effective[key];
                    const result = results[key];
                    const applied =
                      key in props.effective && sameSetting(requested, current);
                    return (
                      <tr key={key}>
                        <td>
                          <code>{key}</code>
                        </td>
                        <td>{settingText(requested) || "empty"}</td>
                        <td
                          class={result && result !== "ok" ? "error-text" : ""}
                        >
                          {result != null
                            ? String(result)
                            : pending
                              ? "not answered yet"
                              : c.final_status === "ok"
                                ? "ok"
                                : "—"}
                        </td>
                        <td
                          class={
                            !pending && !applied && c.final_status
                              ? "error-text"
                              : ""
                          }
                        >
                          {key in props.effective
                            ? settingText(current) || "empty"
                            : "unknown"}
                          {applied ? " (matches)" : ""}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </TableRegion>
          </div>
        );
      })}
      <p class="muted">
        Cancel a waiting request on Commands. Cancelling cannot recall a request
        the logger has already received.
      </p>
    </div>
  );
});
