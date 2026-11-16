// Revision 2 logger settings: effective values, editor and generation history.
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
} from "@builder.io/qwik";
import { errorText, stamp } from "./api";
import { EXPIRY_PRESETS, expiryError, show } from "./format";
import { devicePath, send, useJson } from "./hooks";
import {
  SETTING_DEFAULTS,
  SETTING_FIELDS,
  changedSettings,
  settingText,
  settingsDiff,
  validateSettings,
} from "./settings";
import type { Device, SettingsResponse } from "./types";
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
      action.message =
        "Settings queued. The logger receives them at its next connection; effective values change when it acknowledges.";
      action.failed = false;
      for (const key of Object.keys(drafts)) delete drafts[key];
      replace.value = false;
      reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
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
