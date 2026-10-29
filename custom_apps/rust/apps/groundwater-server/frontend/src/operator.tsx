import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  type QRL,
} from "@builder.io/qwik";
import { buildConfig, CONFIG_FIELDS, emptyConfig } from "./config";
import { errorText, request, stamp } from "./api";
import type { Command, Device } from "./types";

type Props = { device: Device; refresh: QRL<() => void> };
export const ConfigEditor = component$<Props>(({ device, refresh }) => {
  const config = useStore(emptyConfig());
  const touched = useStore<Record<string, boolean>>({});
  const confirm = useSignal(""),
    pending = useSignal(false),
    message = useSignal(""),
    failed = useSignal(false);
  const built = useComputed$(() => {
    const result = buildConfig(config);
    const [hours, minutes] = config.ltost.split(":").map(Number);
    const offset = device.clock_policy === "utc" ? 0 : device.local_offset_min;
    if (
      !result.errors.ltost &&
      (offset == null || hours * 60 + minutes !== offset)
    )
      result.errors.ltost =
        "Keep the commissioned UTC offset. This firmware cannot identify clock changes in SD backlog.";
    return result;
  });
  const submit = $(async () => {
    for (const [key] of CONFIG_FIELDS) touched[key] = true;
    if (
      pending.value ||
      Object.keys(built.value.errors).length ||
      confirm.value !== "DANGER"
    )
      return;
    pending.value = true;
    message.value = "";
    try {
      await request(
        `/api/devices/${encodeURIComponent(device.device_id)}/config`,
        undefined,
        { config: { ...config } },
      );
      message.value =
        "Project settings queued until the device wakes. This firmware does not acknowledge project settings.";
      failed.value = false;
      confirm.value = "";
      refresh();
    } catch (error) {
      message.value = errorText(error);
      failed.value = true;
    } finally {
      pending.value = false;
    }
  });
  return (
    <section aria-labelledby="config-heading">
      <h2 id="config-heading">Project settings</h2>
      <p>
        All eleven values are required. The device writes these settings to
        flash. Leave fields empty until you have the commissioned values.
      </p>
      <p class="notice">
        Queued until wake. Project settings have no firmware acknowledgement.
        GWL datum is uncommissioned; thresholds use raw metres.
      </p>
      <form preventdefault:submit onSubmit$={submit}>
        <fieldset disabled={pending.value}>
          <legend class="sr-only">Firmware project settings</legend>
          <div class="config-fields">
            {CONFIG_FIELDS.map(([key, label, hint]) => (
              <label key={key} class="field" for={`config-${key}`}>
                <span>
                  {label} <code>{key}</code>
                </span>
                <input
                  id={`config-${key}`}
                  value={config[key]}
                  autoComplete="off"
                  spellcheck={false}
                  aria-invalid={!!touched[key] && !!built.value.errors[key]}
                  aria-describedby={`hint-${key}${touched[key] && built.value.errors[key] ? ` error-${key}` : ""}`}
                  onInput$={(_, el) => {
                    config[key] = el.value;
                  }}
                  onBlur$={() => {
                    touched[key] = true;
                  }}
                />
                <small id={`hint-${key}`} class="muted">
                  {hint}
                </small>
                {touched[key] && built.value.errors[key] && (
                  <small id={`error-${key}`} class="error-text">
                    {built.value.errors[key]}
                  </small>
                )}
              </label>
            ))}
          </div>
          <div class="preview">
            <h3>
              Compact payload{" "}
              <span class={built.value.bytes > 150 ? "error-text" : "muted"}>
                {built.value.bytes}/150 UTF-8 bytes
              </span>
            </h3>
            <pre>{built.value.json}</pre>
            {built.value.errors.payload && (
              <p class="error-text">{built.value.errors.payload}</p>
            )}
          </div>
          <label class="field confirm" for="config-confirm">
            Type DANGER to queue these project settings
            <input
              id="config-confirm"
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
            disabled={
              pending.value ||
              confirm.value !== "DANGER" ||
              Object.keys(built.value.errors).length > 0
            }
            aria-busy={pending.value}
          >
            {pending.value ? "Queuing…" : "Queue project settings"}
          </button>
        </fieldset>
      </form>
      {message.value && (
        <p
          role={failed.value ? "alert" : "status"}
          class={failed.value ? "notice error-text" : "notice"}
        >
          {message.value}
        </p>
      )}
    </section>
  );
});

export const DeviceCommands = component$<Props>(({ device, refresh }) => {
  const danger = useSignal<string>(""),
    confirm = useSignal("");
  const pending = useSignal(false),
    message = useSignal(""),
    failed = useSignal(false);
  const send = $(async (kind: "test" | "danger") => {
    if (
      pending.value ||
      (kind === "danger" && (!danger.value || confirm.value !== "DANGER"))
    )
      return;
    const payload = kind === "test" ? {} : danger.value;
    pending.value = true;
    message.value = "";
    try {
      await request(
        `/api/devices/${encodeURIComponent(device.device_id)}/commands`,
        undefined,
        {
          kind,
          payload,
          ...(kind === "danger" ? { confirm: confirm.value } : {}),
        },
      );
      message.value = `${kind === "test" ? "Self-test" : danger.value} queued until wake.`;
      failed.value = false;
      confirm.value = "";
      refresh();
    } catch (error) {
      message.value = errorText(error);
      failed.value = true;
    } finally {
      pending.value = false;
    }
  });
  return (
    <section aria-labelledby="commands-heading">
      <h2 id="commands-heading">Remote commands</h2>
      <p>
        Commands wait for a Ready wake window. Unacknowledged commands are
        retried on the next Ready until cancelled.
      </p>
      {device.capabilities?.test && (
        <div class="command-section">
          <h3>Self-test</h3>
          <p>Results arrive in the delivery log on the testresults topic.</p>
          <button
            disabled={pending.value}
            aria-busy={pending.value}
            onClick$={() => send("test")}
          >
            Queue self-test
          </button>
        </div>
      )}
      <p class="notice">
        This firmware does not implement configuration toggles or wipe/reset
        actions. Its echoes confirm receipt only. These actions cannot be
        queued.
      </p>
      <ConfigSnapshot device={device} />
      {device.capabilities?.danger_commands.length > 0 && (
        <form
          class="command-section"
          preventdefault:submit
          onSubmit$={() => send("danger")}
        >
          <h3 class="error-text">Danger commands</h3>
          <p>Reboot restarts the logger and has no firmware acknowledgement.</p>
          <div class="toolbar">
            <label class="field" for="danger-command">
              Command
              <select
                id="danger-command"
                value={danger.value}
                onChange$={(_, el) => {
                  danger.value = el.value;
                  confirm.value = "";
                }}
              >
                <option value="">Choose a command</option>
                {device.capabilities.danger_commands.map((command) => (
                  <option key={command} value={command}>
                    {command}
                  </option>
                ))}
              </select>
            </label>
            <label class="field" for="danger-confirm">
              Type DANGER
              <input
                id="danger-confirm"
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
              disabled={
                pending.value || !danger.value || confirm.value !== "DANGER"
              }
              aria-busy={pending.value}
            >
              Queue danger command
            </button>
          </div>
        </form>
      )}
      {message.value && (
        <p
          role={failed.value ? "alert" : "status"}
          class={failed.value ? "notice error-text" : "notice"}
        >
          {message.value}
        </p>
      )}
    </section>
  );
});

export const ConfigSnapshot = component$<{ device: Device }>(({ device }) => (
  <details class="snapshot">
    <summary>Configuration record</summary>
    <h3>Last project settings sent</h3>
    <pre>
      {device.project_config
        ? JSON.stringify(device.project_config, null, 2)
        : "No project settings sent."}
    </pre>
    <p class="muted">
      Project settings have no firmware acknowledgement. This is the last
      broker-accepted payload, not proof of application.
    </p>
    {(device.desired_config || device.applied_config) && (
      <>
        <div class="snapshot-grid">
          <div>
            <h3>Requested toggles</h3>
            <pre>{JSON.stringify(device.desired_config || {}, null, 2)}</pre>
          </div>
          <div>
            <h3>Received toggle echoes</h3>
            <pre>{JSON.stringify(device.applied_config || {}, null, 2)}</pre>
          </div>
        </div>
        <p class="muted">
          Historical echoes record receipt. The bundled firmware does not
          implement these actions.
        </p>
      </>
    )}
  </details>
));

export const CommandQueue = component$<{
  device: string;
  commands: Command[];
  operator: boolean;
  refresh: QRL<() => void>;
  audit?: boolean;
}>((props) => {
  const pending = useSignal<number | null>(null),
    error = useSignal("");
  return (
    <section>
      <h2>{props.audit ? "Command audit" : "Command queue"}</h2>
      <p class="muted">
        Cancel stops future delivery attempts; it cannot undo a command already
        executed.
      </p>
      {error.value && (
        <p role="alert" class="error-text">
          {error.value}
        </p>
      )}
      {props.commands.length === 0 ? (
        <p class="empty">No commands recorded for this device.</p>
      ) : (
        <div
          class="table-scroll"
          role="region"
          aria-label="Command history"
          tabIndex={0}
        >
          <table>
            <thead>
              <tr>
                <th>Command / requested by</th>
                <th>State</th>
                <th>Created</th>
                <th>Sent / acknowledged</th>
                <th>Payload / action</th>
              </tr>
            </thead>
            <tbody>
              {props.commands.map((command) => (
                <tr key={`${command.id}-${command.state}`}>
                  <td>
                    <strong>
                      #{command.id} {command.kind}
                    </strong>
                    <small>{command.requested_by}</small>
                  </td>
                  <td>
                    <span class="state">{command.state}</span>
                    {command.supported === false &&
                      ["queued", "sent"].includes(command.state) && (
                        <small class="error-text">
                          Delivery blocked by firmware capability or clock
                          policy. Cancel to close.
                        </small>
                      )}
                    {command.firmware_ack_expected === false ? (
                      <small>No firmware ack</small>
                    ) : null}
                  </td>
                  <td>{stamp(command.created_at)}</td>
                  <td>
                    {stamp(command.sent_at)}
                    <small>Ack: {stamp(command.acked_at)}</small>
                  </td>
                  <td>
                    <details>
                      <summary>Payload and acknowledgement</summary>
                      <pre>{JSON.stringify(command.payload, null, 2)}</pre>
                      <pre>
                        {command.ack_payload == null
                          ? "No acknowledgement"
                          : JSON.stringify(command.ack_payload, null, 2)}
                      </pre>
                    </details>
                    {props.operator &&
                      ["queued", "sent", "awaiting_ack", "pending"].includes(
                        command.state,
                      ) && (
                        <button
                          disabled={pending.value !== null}
                          onClick$={async () => {
                            pending.value = command.id;
                            error.value = "";
                            try {
                              await request(
                                `/api/devices/${encodeURIComponent(props.device)}/commands/${command.id}/cancel`,
                                undefined,
                                {},
                              );
                              props.refresh();
                            } catch (e) {
                              error.value = errorText(e);
                            } finally {
                              pending.value = null;
                            }
                          }}
                        >
                          {pending.value === command.id
                            ? "Cancelling…"
                            : `Cancel #${command.id}`}
                        </button>
                      )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
});
