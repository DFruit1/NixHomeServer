// Device installation: enrollment details, retire/reinstate, bindings,
// viewer permissions, datum history, per-device MQTT credentials and audit.
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  type QRL,
} from "@builder.io/qwik";
import { errorText, stamp } from "./api";
import { AuditList } from "./admin";
import { devicePath, send, useJson } from "./hooks";
import { DATUM_MODES, USERNAME, buildDatum, convertLevel } from "./ops";
import type {
  BindingRow,
  Datum,
  Device,
  MqttCredentials,
  Permission,
} from "./types";
import { Feedback, LoadState, TableRegion } from "./widgets";

type Props = {
  device: Device;
  revision: number;
  operator: boolean;
  refresh: QRL<() => void>;
};

const DETAIL_FIELDS = [
  ["display_name", "Name"],
  ["location_id", "Location ID"],
  ["sensor_id", "Sensor ID"],
  ["project", "Project"],
] as const;

export const DetailsPanel = component$<Props>((props) => {
  const d = props.device;
  const draft = useStore<Record<string, string>>({
    display_name: d.display_name || "",
    location_id: d.location_id || "",
    sensor_id: d.sensor_id || "",
    project: d.project || "",
    notes: d.notes || "",
  });
  const retireText = useSignal(""),
    reason = useSignal("");
  const action = useStore({ pending: false, message: "", failed: false });
  const run = $(
    async (
      method: "PATCH" | "POST",
      path: string,
      body: unknown,
      done: string,
    ) => {
      if (action.pending) return;
      action.pending = true;
      action.message = "";
      try {
        await send(method, devicePath(d.device_id, path), body);
        action.message = done;
        action.failed = false;
        retireText.value = "";
        await props.refresh();
      } catch (error) {
        action.message = errorText(error);
        action.failed = true;
      } finally {
        action.pending = false;
      }
    },
  );
  return (
    <section aria-labelledby="details-heading">
      <h2 id="details-heading">Enrollment</h2>
      <dl class="facts">
        <div>
          <dt>Profile / clock</dt>
          <dd>
            {d.profile} / {d.clock_policy}
            {d.local_offset_min != null ? ` (${d.local_offset_min} min)` : ""}
          </dd>
        </div>
        <div>
          <dt>Enrolled</dt>
          <dd>{stamp(d.enrolled_at)}</dd>
        </div>
        <div>
          <dt>State</dt>
          <dd class={d.revoked ? "error-text" : ""}>
            {d.revoked ? `retired ${stamp(d.revoked_at)}` : "active"}
          </dd>
        </div>
        <div>
          <dt>MQTT account</dt>
          <dd>{d.mqtt_auth || "shared"}</dd>
        </div>
      </dl>
      {!props.operator ? (
        <dl class="facts">
          {DETAIL_FIELDS.map(([key, label]) => (
            <div key={key}>
              <dt>{label}</dt>
              <dd>
                {(d as unknown as Record<string, string | null>)[key] || "—"}
              </dd>
            </div>
          ))}
          <div>
            <dt>Notes</dt>
            <dd>{d.notes || "—"}</dd>
          </div>
        </dl>
      ) : (
        <form
          preventdefault:submit
          onSubmit$={() => run("PATCH", "", { ...draft }, "Details saved.")}
        >
          <fieldset disabled={action.pending}>
            <legend class="sr-only">Device details</legend>
            <div class="config-fields">
              {DETAIL_FIELDS.map(([key, label]) => (
                <label key={key} class="field" for={`detail-${key}`}>
                  {label}
                  <input
                    id={`detail-${key}`}
                    value={draft[key]}
                    onInput$={(_, el) => {
                      draft[key] = el.value;
                    }}
                  />
                </label>
              ))}
            </div>
            <label class="field" for="detail-notes">
              Notes
              <textarea
                id="detail-notes"
                rows={3}
                value={draft.notes}
                onInput$={(_, el) => {
                  draft.notes = el.value;
                }}
              />
            </label>
            <button class="primary" type="submit">
              Save details
            </button>
          </fieldset>
        </form>
      )}
      {props.operator &&
        (d.revoked ? (
          <div class="command-section">
            <h3>Reinstate</h3>
            <p>
              Restores the enrollment and its gwl/v1 bindings. History was kept.
            </p>
            <button
              type="button"
              disabled={action.pending}
              onClick$={() =>
                run("POST", "/reinstate", {}, "Device reinstated.")
              }
            >
              Reinstate device
            </button>
          </div>
        ) : (
          <form
            class="command-section"
            preventdefault:submit
            onSubmit$={() => {
              if (retireText.value !== "RETIRE") return;
              return run(
                "POST",
                "/retire",
                { confirm: "RETIRE", reason: reason.value.trim() },
                "Device retired. New traffic from it is quarantined.",
              );
            }}
          >
            <h3 class="error-text">Retire</h3>
            <p>
              Revokes the enrollment and bindings, cancels queued and challenged
              commands and removes its own MQTT credentials. Observations and
              audit history stay.
            </p>
            <div class="toolbar">
              <label class="field" for="retire-reason">
                Reason
                <input
                  id="retire-reason"
                  value={reason.value}
                  onInput$={(_, el) => {
                    reason.value = el.value;
                  }}
                />
              </label>
              <label class="field" for="retire-confirm">
                Type RETIRE
                <input
                  id="retire-confirm"
                  autoComplete="off"
                  value={retireText.value}
                  onInput$={(_, el) => {
                    retireText.value = el.value;
                  }}
                />
              </label>
              <button
                class="danger"
                type="submit"
                disabled={action.pending || retireText.value !== "RETIRE"}
              >
                Retire device
              </button>
            </div>
          </form>
        ))}
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

export const PermissionsPanel = component$<Props>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() =>
    devicePath(props.device.device_id, "/permissions"),
  );
  const { state, reload } = useJson<{ permissions: Permission[] }>(url, rev);
  const username = useSignal("");
  const action = useStore({ pending: false, message: "", failed: false });
  const change = $(async (method: "POST" | "DELETE", name: string) => {
    if (action.pending) return;
    if (method === "POST" && !USERNAME.test(name)) {
      action.message = "Usernames use letters, digits, . _ @ - (up to 128).";
      action.failed = true;
      return;
    }
    action.pending = true;
    action.message = "";
    try {
      await send(
        method,
        devicePath(
          props.device.device_id,
          method === "POST"
            ? "/permissions"
            : `/permissions/${encodeURIComponent(name)}`,
        ),
        method === "POST" ? { username: name } : undefined,
      );
      action.message =
        method === "POST"
          ? `${name} can now view this device.`
          : `${name} no longer sees this device.`;
      action.failed = false;
      username.value = "";
      reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const rows = state.data?.permissions || [];
  return (
    <section aria-labelledby="permissions-heading">
      <h2 id="permissions-heading">Viewer access</h2>
      <p class="muted">
        Accounts in groundwater-user see only devices granted here. app-admin
        operators see all.
      </p>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No viewer grants."
        label="permissions"
      />
      {rows.length > 0 && (
        <TableRegion label="Viewer grants">
          <table>
            <thead>
              <tr>
                <th>Account</th>
                <th>Granted</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.username}>
                  <td>{p.username}</td>
                  <td>
                    {stamp(p.granted_at)}
                    {p.granted_by && <small>by {p.granted_by}</small>}
                  </td>
                  <td>
                    <button
                      type="button"
                      disabled={action.pending}
                      onClick$={() => change("DELETE", p.username)}
                    >
                      Revoke {p.username}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableRegion>
      )}
      <form
        class="toolbar"
        preventdefault:submit
        onSubmit$={() => change("POST", username.value.trim())}
      >
        <label class="field" for="grant-username">
          Grant viewer access to account
          <input
            id="grant-username"
            autoComplete="off"
            value={username.value}
            onInput$={(_, el) => {
              username.value = el.value;
            }}
          />
        </label>
        <button
          type="submit"
          disabled={action.pending || !username.value.trim()}
        >
          Grant access
        </button>
      </form>
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

export const BindingsPanel = component$<{ device: Device; revision: number }>(
  (props) => {
    const rev = useComputed$(() => props.revision);
    const url = useComputed$(() =>
      devicePath(props.device.device_id, "/bindings"),
    );
    const { state } = useJson<{ bindings: BindingRow[] }>(url, rev);
    const rows = state.data?.bindings || [];
    const live = rows.filter((b) => !b.revoked_at);
    return (
      <section aria-labelledby="bindings-heading">
        <h2 id="bindings-heading">Topic bindings</h2>
        <LoadState
          loading={state.loading && !state.data}
          error={state.error}
          empty={rows.length === 0}
          emptyText="No topic bindings: traffic from this unit is quarantined."
          label="bindings"
        />
        {rows.length > 0 && (
          <details>
            <summary>
              {live.length} live binding{live.length === 1 ? "" : "s"}
              {rows.length > live.length
                ? `, ${rows.length - live.length} revoked`
                : ""}
            </summary>
            <TableRegion label="Topic bindings" bounded>
              <table>
                <thead>
                  <tr>
                    <th>Topic</th>
                    <th>Profile</th>
                    <th>Established / revoked</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((b) => (
                    <tr key={b.binding_key}>
                      <td class="mono">{b.topic}</td>
                      <td>{b.source_profile}</td>
                      <td>
                        {stamp(b.established_at)}
                        {b.revoked_at && (
                          <small class="error-text">
                            revoked {stamp(b.revoked_at)}
                          </small>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </TableRegion>
          </details>
        )}
      </section>
    );
  },
);

export const DatumPanel = component$<Props>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() => devicePath(props.device.device_id, "/datums"));
  const { state, reload } = useJson<{ datums: Datum[] }>(url, rev);
  const draft = useStore<Record<string, string>>({
    effective_from: "",
    sensor_depth_m: "",
    casing_height_m: "",
    ground_elevation_m: "",
    note: "",
  });
  const touched = useSignal(false);
  const action = useStore({ pending: false, message: "", failed: false });
  const built = useComputed$(() => buildDatum(draft));
  const rawLevel =
    props.device.latest_plausible?.gwl ??
    props.device.latest_received?.gwl ??
    null;
  const add = $(async () => {
    touched.value = true;
    if (action.pending || Object.keys(built.value.errors).length) return;
    action.pending = true;
    action.message = "";
    try {
      await send(
        "POST",
        devicePath(props.device.device_id, "/datums"),
        built.value.body,
      );
      action.message =
        "Datum added. Charts and exports use it from its effective time.";
      action.failed = false;
      for (const key of Object.keys(draft)) draft[key] = "";
      touched.value = false;
      reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const remove = $(async (id: number) => {
    action.pending = true;
    action.message = "";
    try {
      await send("DELETE", devicePath(props.device.device_id, `/datums/${id}`));
      action.message = `Datum #${id} removed.`;
      action.failed = false;
      reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const rows = state.data?.datums || [];
  const preview =
    rawLevel != null &&
    built.value.body.sensor_depth_m != null &&
    built.value.body.casing_height_m != null &&
    !Object.keys(built.value.errors).length
      ? DATUM_MODES.slice(1).map(([mode, label]) => ({
          label,
          value: convertLevel(
            rawLevel,
            {
              sensor_depth_m: built.value.body.sensor_depth_m!,
              casing_height_m: built.value.body.casing_height_m!,
              ground_elevation_m: built.value.body.ground_elevation_m,
            },
            mode,
          ),
        }))
      : [];
  const fields = [
    ["sensor_depth_m", "Sensor depth below top of casing (m)"],
    ["casing_height_m", "Top of casing above ground (m)"],
    ["ground_elevation_m", "Ground elevation (m AHD, optional)"],
  ] as const;
  return (
    <section aria-labelledby="datum-heading">
      <h2 id="datum-heading">Installation datum</h2>
      <p class="muted">
        Converts the raw level (metres of water above the sensor) to depth to
        water below ground and to a reduced level in m AHD. Each reading uses
        the latest datum effective at its time.
      </p>
      <LoadState
        loading={state.loading && !state.data}
        error={state.error}
        empty={rows.length === 0}
        emptyText="No datum recorded: charts and exports show raw levels only."
        label="datums"
      />
      {rows.length > 0 && (
        <TableRegion label="Datum history">
          <table>
            <thead>
              <tr>
                <th>Effective from</th>
                <th>Sensor depth / casing / ground</th>
                <th>Recorded</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>
                    {stamp(r.effective_from)}
                    {r.note && <small>{r.note}</small>}
                  </td>
                  <td class="numeric">
                    {r.sensor_depth_m} m / {r.casing_height_m} m /{" "}
                    {r.ground_elevation_m == null
                      ? "—"
                      : `${r.ground_elevation_m} m AHD`}
                  </td>
                  <td>
                    {stamp(r.created_at)}
                    <small>{r.created_by}</small>
                  </td>
                  <td>
                    {props.operator && (
                      <button
                        type="button"
                        disabled={action.pending}
                        onClick$={() => remove(r.id)}
                      >
                        Delete #{r.id}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableRegion>
      )}
      {props.operator && (
        <form class="command-section" preventdefault:submit onSubmit$={add}>
          <h3>Add datum</h3>
          <fieldset disabled={action.pending}>
            <legend class="sr-only">New datum</legend>
            <div class="config-fields">
              <label class="field" for="datum-from">
                Effective from (local time)
                <input
                  id="datum-from"
                  type="datetime-local"
                  value={draft.effective_from}
                  onInput$={(_, el) => {
                    draft.effective_from = el.value;
                  }}
                />
                {touched.value && built.value.errors.effective_from && (
                  <small class="error-text">
                    {built.value.errors.effective_from}
                  </small>
                )}
              </label>
              {fields.map(([key, label]) => (
                <label key={key} class="field" for={`datum-${key}`}>
                  {label}
                  <input
                    id={`datum-${key}`}
                    inputMode="decimal"
                    value={draft[key]}
                    onInput$={(_, el) => {
                      draft[key] = el.value;
                    }}
                  />
                  {touched.value && built.value.errors[key] && (
                    <small class="error-text">{built.value.errors[key]}</small>
                  )}
                </label>
              ))}
              <label class="field" for="datum-note">
                Note
                <input
                  id="datum-note"
                  value={draft.note}
                  onInput$={(_, el) => {
                    draft.note = el.value;
                  }}
                />
              </label>
            </div>
            {preview.length > 0 && (
              <p class="muted">
                Latest raw level {rawLevel} m would read as{" "}
                {preview
                  .map(
                    (p) =>
                      `${p.value == null ? "—" : p.value.toFixed(3)} (${p.label.toLowerCase()})`,
                  )
                  .join(" and ")}
                .
              </p>
            )}
            <button class="primary" type="submit">
              Add datum
            </button>
          </fieldset>
        </form>
      )}
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

export const CredentialsPanel = component$<Props>((props) => {
  const rev = useComputed$(() => props.revision);
  const url = useComputed$(() =>
    devicePath(props.device.device_id, "/mqtt-credentials"),
  );
  const { state, reload } = useJson<MqttCredentials>(url, rev);
  const secret = useStore({ username: "", password: "" });
  const confirm = useSignal("");
  const action = useStore({ pending: false, message: "", failed: false });
  const id = props.device.device_id;
  const run = $(
    async (
      method: "POST" | "DELETE",
      path: string,
      body: unknown,
      done: string,
    ) => {
      if (action.pending) return;
      action.pending = true;
      action.message = "";
      try {
        const result = await send<{ username?: string; password?: string }>(
          method,
          devicePath(id, path),
          body,
        );
        if (result.password) {
          secret.username = result.username || id;
          secret.password = result.password;
        }
        action.message = done;
        action.failed = false;
        confirm.value = "";
        reload();
        await props.refresh();
      } catch (error) {
        action.message = errorText(error);
        action.failed = true;
      } finally {
        action.pending = false;
      }
    },
  );
  const c = state.data;
  return (
    <section aria-labelledby="mqtt-heading">
      <h2 id="mqtt-heading">MQTT credentials</h2>
      <LoadState
        loading={state.loading && !c}
        error={state.error}
        label="credentials"
      />
      {c && (
        <>
          <dl class="facts">
            <div>
              <dt>Mode</dt>
              <dd>
                {c.mode === "shared"
                  ? "shared groundwater-logger account"
                  : c.mode === "dual"
                    ? "own account; shared account still accepted"
                    : "own account only; shared account denied for this unit"}
              </dd>
            </div>
            <div>
              <dt>Username</dt>
              <dd class="mono">
                {c.mode === "shared" ? "groundwater-logger" : c.username}
              </dd>
            </div>
            <div>
              <dt>Generated / rotated</dt>
              <dd>
                {stamp(c.created_at)}
                {c.created_by && <small>by {c.created_by}</small>}
                {c.rotated_at && <small>rotated {stamp(c.rotated_at)}</small>}
              </dd>
            </div>
            <div>
              <dt>Broker files written</dt>
              <dd>{stamp(c.published_at)}</dd>
            </div>
          </dl>
          {!c.available && (
            <p class="notice">
              Per-device credentials are not enabled on this server (no
              GROUNDWATER_MQTT_AUTH_DIR). Units keep using the shared account.
            </p>
          )}
          {secret.password && (
            <div class="notice secret" role="status">
              <p>
                <strong>Copy this password now. It is not shown again.</strong>
              </p>
              <dl class="facts">
                <div>
                  <dt>Username</dt>
                  <dd class="mono">{secret.username}</dd>
                </div>
                <div>
                  <dt>Password</dt>
                  <dd>
                    <input
                      class="mono"
                      readOnly
                      value={secret.password}
                      aria-label="Generated MQTT password"
                      onFocus$={(_, el) => el.select()}
                    />
                  </dd>
                </div>
              </dl>
              <p>
                Store it in a 0600 file on the build host, then rebuild and
                flash the firmware:
              </p>
              <pre>{`umask 077; printf '%s\\n' '<password>' > ~/.config/gwl/${secret.username}.mqtt-password
tools/net-config.py --user ${secret.username} \\
  --password-file ~/.config/gwl/${secret.username}.mqtt-password
tools/build.sh --profile release && tools/flash.sh`}</pre>
              <button
                type="button"
                onClick$={() => {
                  secret.password = "";
                }}
              >
                I have stored it
              </button>
            </div>
          )}
          {props.operator && c.available && !props.device.revoked && (
            <div class="command-section">
              <div class="row-actions">
                <button
                  type="button"
                  class="primary"
                  disabled={action.pending}
                  onClick$={() =>
                    run(
                      "POST",
                      "/mqtt-credentials",
                      {},
                      c.mode === "shared"
                        ? "Credentials generated; the broker accepts both accounts for this unit (dual)."
                        : "Password rotated. Reflash the unit before the old password is needed again.",
                    )
                  }
                >
                  {c.mode === "shared"
                    ? "Generate credentials"
                    : "Rotate password"}
                </button>
                {c.mode === "device" && (
                  <button
                    type="button"
                    disabled={action.pending}
                    onClick$={() =>
                      run(
                        "POST",
                        "/mqtt-credentials/mode",
                        { mode: "dual" },
                        "Shared account accepted again (dual).",
                      )
                    }
                  >
                    Allow shared account again
                  </button>
                )}
                {c.mode !== "shared" && (
                  <button
                    type="button"
                    disabled={action.pending}
                    onClick$={() =>
                      run(
                        "DELETE",
                        "/mqtt-credentials",
                        undefined,
                        "Own account removed; the unit uses the shared account.",
                      )
                    }
                  >
                    Remove own account
                  </button>
                )}
              </div>
              {c.mode === "dual" && (
                <form
                  class="toolbar"
                  preventdefault:submit
                  onSubmit$={() => {
                    if (confirm.value !== "DEVICE") return;
                    return run(
                      "POST",
                      "/mqtt-credentials/mode",
                      { mode: "device", confirm: "DEVICE" },
                      "Shared account denied for this unit. Only its own account can publish or receive its topics.",
                    );
                  }}
                >
                  <label class="field" for="mqtt-enforce">
                    After the reflashed unit has connected with its own account,
                    type DEVICE to deny the shared account on its topics
                    <input
                      id="mqtt-enforce"
                      autoComplete="off"
                      value={confirm.value}
                      onInput$={(_, el) => {
                        confirm.value = el.value;
                      }}
                    />
                  </label>
                  <button
                    class="danger"
                    type="submit"
                    disabled={action.pending || confirm.value !== "DEVICE"}
                  >
                    Enforce own account
                  </button>
                </form>
              )}
            </div>
          )}
        </>
      )}
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

export const InstallationView = component$<Props>((props) => (
  <>
    <DetailsPanel
      key={props.device.device_id}
      device={props.device}
      revision={props.revision}
      operator={props.operator}
      refresh={props.refresh}
    />
    <DatumPanel
      device={props.device}
      revision={props.revision}
      operator={props.operator}
      refresh={props.refresh}
    />
    {props.operator && (
      <>
        <PermissionsPanel
          device={props.device}
          revision={props.revision}
          operator={props.operator}
          refresh={props.refresh}
        />
        <BindingsPanel device={props.device} revision={props.revision} />
        <CredentialsPanel
          device={props.device}
          revision={props.revision}
          operator={props.operator}
          refresh={props.refresh}
        />
        <AuditList
          url={devicePath(props.device.device_id, "/audit")}
          revision={props.revision}
          title="Device audit"
        />
      </>
    )}
  </>
));
