// Revision 2 command console, danger handshake confirmation and queue.
import {
  $,
  component$,
  useSignal,
  useStore,
  type QRL,
  type Signal,
} from "@builder.io/qwik";
import { CLOCK_FLOOR_MS, errorText, stamp } from "./api";
import { ackOutcome } from "./config";
import {
  EXPIRY_PRESETS,
  countdown,
  duration,
  expiryError,
  secondsLeft,
  show,
} from "./format";
import { OP_HELP, TRUNCATED_COMMANDS, opArgs, originText } from "./commands";
import { devicePath, send, useNow } from "./hooks";
import type { Command, Device } from "./types";
import { Feedback, TableRegion } from "./widgets";

type ConsoleProps = { device: Device; refresh: QRL<() => void> };

/** When a queued command can reach the logger. */
export function nextContactText(device: Device) {
  if (device.status === "awake")
    return "The logger is awake now; it should answer within its listen window.";
  const expected = device.expected_contact_at || device.next_contact_at;
  return `It waits in the logger's broker session until the next connection${expected ? `, expected ${stamp(expected)}` : " (time unknown)"}; the result appears here after that.`;
}

export const Rev2Console = component$<ConsoleProps>((props) => {
  const caps = props.device.capabilities;
  const basic = useSignal("get_status");
  const danger = useSignal("");
  const args = useStore<Record<string, string>>({
    path: "/GWL",
    page: "0",
    off: "0",
    len: "1024",
  });
  const basicExpiry = useSignal(7 * 86400),
    // 0: the logger's next connection plus one hour (see dangerDefault).
    dangerExpiry = useSignal(0),
    customBasic = useSignal(""),
    customDanger = useSignal("");
  const confirm = useSignal(""),
    autoConfirm = useSignal(false);
  const action = useStore({ pending: false, message: "", failed: false });
  const unsupported = caps.unsupported_by_firmware || [];
  const queue = $(async (body: Record<string, unknown>, label: string) => {
    action.pending = true;
    action.message = "";
    try {
      const result = await send<{ command?: Command }>(
        "POST",
        devicePath(props.device.device_id, "/commands"),
        body,
      );
      action.message = `${label} queued as #${result.command?.id ?? "?"}. ${nextContactText(props.device)}`;
      action.failed = false;
      confirm.value = "";
      props.refresh();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const expiryValue = (preset: number, custom: string) =>
    custom.trim() ? Number(custom.trim()) : preset;
  const basicArgs = opArgs(basic.value, args);
  const now = useNow(30000);
  const basicSeconds = expiryValue(basicExpiry.value, customBasic.value);
  const untilNext = (at: number) => nextConnectionExpiry(props.device, at);
  const dangerSecondsAt = (at: number) =>
    expiryValue(
      dangerExpiry.value === 0 ? (untilNext(at) ?? 86400) : dangerExpiry.value,
      customDanger.value,
    );
  const dangerSeconds = dangerSecondsAt(now.value);
  const handshake = (caps.handshake_ops || []).includes(danger.value);
  return (
    <section aria-labelledby="console-heading">
      <h2 id="console-heading">Command console</h2>
      <p class="muted">
        Commands are published immediately (QoS 1) and held by the logger's
        persistent session while it sleeps. Without a final acknowledgement they
        are re-published after the next sleep, up to three times, until they
        expire.
      </p>
      <form
        class="command-section"
        preventdefault:submit
        onSubmit$={() => {
          if (
            action.pending ||
            basicArgs.errors.length ||
            expiryError(basicSeconds)
          )
            return;
          return queue(
            {
              op: basic.value,
              args: basicArgs.args,
              expires_in_s: basicSeconds,
            },
            basic.value,
          );
        }}
      >
        <h3>Routine command</h3>
        <div class="toolbar">
          <label class="field" for="basic-op">
            Operation
            <select
              id="basic-op"
              value={basic.value}
              onChange$={(_, el) => {
                basic.value = el.value;
              }}
            >
              {(caps.basic_ops || []).map((op) => (
                <option key={op} value={op}>
                  {op}
                </option>
              ))}
            </select>
          </label>
          <ExpiryField id="basic" preset={basicExpiry} custom={customBasic} />
        </div>
        <p class="muted">{OP_HELP[basic.value]}</p>
        {basic.value === "flush_mqtt" && (
          <div class="toolbar">
            {["log_id", "from_seq", "to_seq"].map((key) => (
              <label key={key} class="field" for={`arg-${key}`}>
                {key} (optional)
                <input
                  id={`arg-${key}`}
                  inputMode="numeric"
                  value={args[key] || ""}
                  onInput$={(_, el) => {
                    args[key] = el.value;
                  }}
                />
              </label>
            ))}
          </div>
        )}
        {(basic.value === "file_list" || basic.value === "file_chunk") && (
          <div class="toolbar">
            <label class="field" for="arg-path">
              SD path
              <input
                id="arg-path"
                value={args.path}
                onInput$={(_, el) => {
                  args.path = el.value;
                }}
              />
            </label>
            {basic.value === "file_list" ? (
              <label class="field" for="arg-page">
                Page
                <input
                  id="arg-page"
                  inputMode="numeric"
                  value={args.page}
                  onInput$={(_, el) => {
                    args.page = el.value;
                  }}
                />
              </label>
            ) : (
              <>
                <label class="field" for="arg-off">
                  Offset
                  <input
                    id="arg-off"
                    inputMode="numeric"
                    value={args.off}
                    onInput$={(_, el) => {
                      args.off = el.value;
                    }}
                  />
                </label>
                <label class="field" for="arg-len">
                  Length (≤ 1024)
                  <input
                    id="arg-len"
                    inputMode="numeric"
                    value={args.len}
                    onInput$={(_, el) => {
                      args.len = el.value;
                    }}
                  />
                </label>
              </>
            )}
          </div>
        )}
        {[...basicArgs.errors, expiryError(basicSeconds)]
          .filter(Boolean)
          .map((e) => (
            <p key={e} class="error-text" role="alert">
              {e}
            </p>
          ))}
        <button
          class="primary"
          type="submit"
          disabled={
            action.pending ||
            basicArgs.errors.length > 0 ||
            !!expiryError(basicSeconds)
          }
          aria-busy={action.pending}
        >
          Queue {basic.value}
        </button>
      </form>
      <form
        class="command-section"
        preventdefault:submit
        onSubmit$={() => {
          if (
            action.pending ||
            !danger.value ||
            confirm.value !== "DANGER" ||
            unsupported.includes(danger.value) ||
            expiryError(dangerSeconds)
          )
            return;
          return queue(
            {
              op: danger.value,
              confirm: "DANGER",
              auto_confirm: handshake && autoConfirm.value,
              expires_in_s: dangerSecondsAt(Date.now()),
            },
            danger.value,
          );
        }}
      >
        <h3 class="error-text">Danger commands</h3>
        <p>
          Every danger command except reboot uses the logger's nonce handshake:
          it answers with a challenge valid for about two minutes while it stays
          awake, and an operator confirms it here (with the unsaved frame count,
          if any).
        </p>
        <div class="toolbar">
          <label class="field" for="danger-op">
            Operation
            <select
              id="danger-op"
              value={danger.value}
              onChange$={(_, el) => {
                danger.value = el.value;
                confirm.value = "";
                autoConfirm.value = false;
              }}
            >
              <option value="">Choose a danger command</option>
              {(caps.danger_ops || []).map((op) => (
                <option key={op} value={op} disabled={unsupported.includes(op)}>
                  {`${op}${unsupported.includes(op) ? " (not supported by firmware)" : ""}`}
                </option>
              ))}
            </select>
          </label>
          <ExpiryField
            id="danger"
            preset={dangerExpiry}
            custom={customDanger}
            next={untilNext(now.value) != null}
          />
        </div>
        {!expiryError(dangerSeconds) && (
          <p class="muted">
            Expires{" "}
            {stamp(new Date(now.value + dangerSeconds * 1000).toISOString())}
            {dangerExpiry.value === 0 && !customDanger.value.trim()
              ? untilNext(now.value) != null
                ? ", one hour after the logger's announced next connection."
                : ": the next connection is not known, so one day."
              : "."}
          </p>
        )}
        {danger.value && <p class="muted">{OP_HELP[danger.value]}</p>}
        {unsupported.length > 0 && (
          <p class="muted">
            Not supported by firmware 2.2 (the logger rejects them):{" "}
            {unsupported.join(", ")}.
          </p>
        )}
        {handshake && (
          <label class="checkbox">
            <input
              type="checkbox"
              checked={autoConfirm.value}
              onChange$={(_, el) => {
                autoConfirm.value = el.checked;
              }}
            />
            Confirm automatically when the logger reports no unsaved data
          </label>
        )}
        <div class="toolbar">
          <label class="field" for="danger-confirm-text">
            Type DANGER
            <input
              id="danger-confirm-text"
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
              action.pending ||
              !danger.value ||
              confirm.value !== "DANGER" ||
              !!expiryError(dangerSeconds)
            }
          >
            Queue {danger.value || "danger command"}
          </button>
        </div>
        {expiryError(dangerSeconds) && (
          <p class="error-text" role="alert">
            {expiryError(dangerSeconds)}
          </p>
        )}
      </form>
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

/** Seconds from `now` until one hour after the logger's announced next
 * connection, or null when that is unknown or not in the future. A weekly
 * logger never sees a danger command that expires after a day. */
export function nextConnectionExpiry(device: Device, now: number) {
  if (device.status === "awake") return null;
  const at = Date.parse(
    device.expected_contact_at || device.next_contact_at || "",
  );
  if (!Number.isFinite(at) || at < CLOCK_FLOOR_MS || at <= now) return null;
  return Math.min(
    2592000,
    Math.max(60, Math.ceil((at + 3600000 - now) / 1000)),
  );
}

/** `preset` 0 is "next connection + 1 h"; offered only when `next`. */
export const ExpiryField = component$<{
  id: string;
  preset: Signal<number>;
  custom: Signal<string>;
  next?: boolean;
}>((props) => (
  <>
    <label class="field" for={`${props.id}-expiry`}>
      Expires after
      <select
        id={`${props.id}-expiry`}
        value={String(
          props.preset.value === 0 && !props.next ? 86400 : props.preset.value,
        )}
        onChange$={(_, el) => {
          props.preset.value = Number(el.value);
          props.custom.value = "";
        }}
      >
        {props.next && <option value="0">Next connection + 1 hour</option>}
        {EXPIRY_PRESETS.map(([seconds, label]) => (
          <option key={seconds} value={String(seconds)}>
            {label}
          </option>
        ))}
      </select>
    </label>
    <label class="field" for={`${props.id}-expiry-custom`}>
      Or seconds (60–2592000)
      <input
        id={`${props.id}-expiry-custom`}
        inputMode="numeric"
        value={props.custom.value}
        placeholder={props.preset.value ? String(props.preset.value) : ""}
        onInput$={(_, el) => {
          props.custom.value = el.value;
        }}
      />
    </label>
  </>
));

/** Danger commands waiting for the operator's nonce confirmation. */
export const Challenges = component$<{
  device: string;
  commands: Command[];
  operator: boolean;
  refresh: QRL<() => void>;
}>((props) => {
  const now = useNow(1000);
  const typed = useStore<Record<string, string>>({});
  const action = useStore({ pending: 0, message: "", failed: false });
  const waiting = props.commands.filter(
    (c) => c.protocol === 2 && c.state === "challenge",
  );
  if (waiting.length === 0 && !action.message) return null;
  return (
    <section aria-labelledby="challenge-heading" class="challenge">
      <h2 id="challenge-heading" class="error-text">
        Confirmation required
      </h2>
      {waiting.map((command) => {
        const challenge = command.challenge;
        const deadline =
          command.challenge_expires_at ||
          (challenge?.nexp
            ? new Date(challenge.nexp * 1000).toISOString()
            : null);
        const left = secondsLeft(deadline, now.value);
        const frames = challenge?.unsaved_frames || 0;
        const expired = left === 0;
        // A confirmation already queued or published: the server refuses a
        // second one, and the logger's ack settles this command.
        const sent = props.commands.find(
          (c) =>
            c.parent_id === command.id &&
            c.op === "confirm" &&
            ["queued", "sent"].includes(c.state),
        );
        const matches = frames === 0 || typed[command.id] === String(frames);
        return (
          <form
            key={command.id}
            class="command-section"
            preventdefault:submit
            onSubmit$={async () => {
              if (
                action.pending ||
                expired ||
                !matches ||
                sent ||
                !props.operator
              )
                return;
              action.pending = command.id;
              action.message = "";
              try {
                const result = await send<{ command?: Command }>(
                  "POST",
                  devicePath(props.device, `/commands/${command.id}/confirm`),
                  frames > 0 ? { confirm_unsaved: frames } : {},
                );
                action.message = `Confirmation #${result.command?.id ?? "?"} published for ${command.op} #${command.id}.`;
                action.failed = false;
                props.refresh();
              } catch (error) {
                action.message = errorText(error);
                action.failed = true;
              } finally {
                action.pending = 0;
              }
            }}
          >
            <h3>
              {command.op} #{command.id}
            </h3>
            <dl class="facts">
              <div>
                <dt>Nonce</dt>
                <dd class="mono">{challenge?.nonce || "—"}</dd>
              </div>
              <div>
                <dt>Unsaved data that will be destroyed</dt>
                <dd class={frames ? "error-text" : ""}>
                  {frames
                    ? `${frames} frames (${challenge?.unsaved_bytes ?? "?"} bytes)`
                    : "none reported"}
                </dd>
              </div>
              <div>
                <dt>Time left</dt>
                <dd class={expired ? "error-text" : ""} aria-live="polite">
                  {expired
                    ? "expired: queue the command again"
                    : countdown(left)}
                </dd>
              </div>
              <div>
                <dt>Challenge received</dt>
                <dd>{stamp(challenge?.received_at)}</dd>
              </div>
            </dl>
            {sent && (
              <p class="notice" role="status">
                Confirmation #{sent.id}{" "}
                {sent.state === "sent" ? "published" : "queued"}{" "}
                {stamp(sent.last_published_at || sent.created_at)}. Waiting for
                the logger to execute {command.op} and acknowledge it.
              </p>
            )}
            {props.operator && !expired && !sent && (
              <div class="toolbar">
                {frames > 0 && (
                  <label class="field" for={`confirm-count-${command.id}`}>
                    Type {frames} to accept losing these frames
                    <input
                      id={`confirm-count-${command.id}`}
                      inputMode="numeric"
                      autoComplete="off"
                      value={typed[command.id] || ""}
                      onInput$={(_, el) => {
                        typed[command.id] = el.value;
                      }}
                    />
                  </label>
                )}
                <button
                  class="danger"
                  type="submit"
                  disabled={action.pending !== 0 || !matches}
                  aria-busy={action.pending === command.id}
                >
                  Confirm {command.op} ({countdown(left)})
                </button>
              </div>
            )}
          </form>
        );
      })}
      <Feedback message={action.message} failed={action.failed} />
    </section>
  );
});

const CANCELLABLE = ["queued", "sent", "challenge"];

/** What a logger's final status means for the operator. */
const FINAL_TEXT: Record<string, string> = {
  ok: "done",
  partial: "partly done; see the per-key results",
  failed: "not done",
  rejected: "not accepted; nothing changed",
  expired: "not run: its expiry passed before the logger executed it",
  duplicate: "already run under this id; not run again",
};

/** Ack `data` as label/value pairs (get_status, get_debug, flush results,
 * file_chunk, sync_time …). */
export function ackData(ack: unknown): [string, string][] {
  if (ack == null || typeof ack !== "object") return [];
  const record = ack as Record<string, unknown>;
  const data = record.data;
  const pairs: [string, string][] = [];
  if (typeof record.gen === "number")
    pairs.push(["settings generation", String(record.gen)]);
  if (data && typeof data === "object" && !Array.isArray(data))
    for (const [key, value] of Object.entries(data)) {
      if (key === "settings" || key === "files") continue;
      if (key === "t" && typeof value === "number")
        pairs.push([
          "logger clock",
          stamp(new Date(value * 1000).toISOString()),
        ]);
      else if (/_mv$/.test(key) && typeof value === "number")
        pairs.push([key.replace(/_mv$/, ""), `${(value / 1000).toFixed(2)} V`]);
      else pairs.push([key.replaceAll("_", " "), show(value)]);
    }
  return pairs.slice(0, 40);
}

export const Rev2Queue = component$<{
  device: string;
  commands: Command[];
  operator: boolean;
  refresh: QRL<() => void>;
  audit?: boolean;
  /** When the logger is expected to connect next (commands wait for it). */
  expected?: string | null;
  /** The server cut the list at its newest 500 commands. */
  truncated?: boolean;
}>((props) => {
  const now = useNow(30000);
  const pending = useSignal(0),
    error = useSignal("");
  return (
    <section>
      <h2>{props.audit ? "Command audit" : "Command queue"}</h2>
      <p class="muted">
        States: queued → sent (broker accepted; waits in the logger's session) →
        acked with the logger's final status, or challenge → acked/expired.
        Cancel stops further publishing; it cannot recall a command the logger
        already received.
      </p>
      {error.value && (
        <p role="alert" class="error-text">
          {error.value}
        </p>
      )}
      {props.truncated && <p class="notice">{TRUNCATED_COMMANDS}</p>}
      {props.commands.length === 0 ? (
        <p class="empty">No commands recorded for this device.</p>
      ) : (
        <TableRegion label="Command history">
          <table>
            <thead>
              <tr>
                <th>Command</th>
                <th>State / result</th>
                <th>Created / expires</th>
                <th>Publishing</th>
                <th>Arguments / acknowledgement</th>
              </tr>
            </thead>
            <tbody>
              {props.commands.map((c) => {
                const outcome = ackOutcome(c.ack_payload);
                const problem =
                  c.final_status &&
                  !["ok", "duplicate"].includes(c.final_status);
                return (
                  <tr key={`${c.id}-${c.state}`}>
                    <td>
                      <strong>
                        #{c.id} {c.op || c.kind}
                      </strong>
                      <small>
                        {originText(c.origin) ||
                          originText(c.requested_by) ||
                          c.requested_by}
                      </small>
                      {c.replace_settings && (
                        <small>replace: other keys reset to defaults</small>
                      )}
                      {c.parent_id != null && (
                        <small>confirms #{c.parent_id}</small>
                      )}
                      {c.preconfirmed && (
                        <small>auto-confirm when no unsaved data</small>
                      )}
                      {c.download_id != null && (
                        <small>download #{c.download_id}</small>
                      )}
                    </td>
                    <td>
                      <span class={`state state-${c.state}`}>{c.state}</span>
                      {c.final_status && (
                        <small class={problem ? "error-text" : ""}>
                          logger: {c.final_status}
                          {FINAL_TEXT[c.final_status]
                            ? ` (${FINAL_TEXT[c.final_status]})`
                            : ""}
                        </small>
                      )}
                      {["queued", "sent"].includes(c.state) &&
                        !c.hold_until_sleep && (
                          <small>
                            waiting for the logger's next connection
                            {props.expected
                              ? ` (expected ${stamp(props.expected)})`
                              : ""}
                          </small>
                        )}
                      {c.status_reason && <small>{c.status_reason}</small>}
                      {c.hold_until_sleep && (
                        <small>held until the next sleep (busy)</small>
                      )}
                      {!c.final_status && outcome && (
                        <small class={outcome.problem ? "error-text" : ""}>
                          firmware: {outcome.status}
                          {outcome.detail ? ` (${outcome.detail})` : ""}
                        </small>
                      )}
                    </td>
                    <td>
                      {stamp(c.created_at)}
                      {c.expires_at && (
                        <small>
                          expires {stamp(c.expires_at)}
                          {CANCELLABLE.includes(c.state) &&
                          Date.parse(c.expires_at) > now.value
                            ? ` (in ${duration(Date.parse(c.expires_at) - now.value)})`
                            : ""}
                        </small>
                      )}
                    </td>
                    <td>
                      {c.protocol === 2
                        ? `${c.publish_count ?? 0} publish${c.publish_count === 1 ? "" : "es"}`
                        : `${(c as { attempts?: number }).attempts ?? 0} attempts`}
                      <small>
                        last {stamp(c.last_published_at || c.sent_at)}
                      </small>
                      <small>ack {stamp(c.acked_at)}</small>
                    </td>
                    <td>
                      {ackData(c.ack_payload).length > 0 && (
                        <dl class="ack-data">
                          {ackData(c.ack_payload).map(([key, value]) => (
                            <div key={key}>
                              <dt>{key}</dt>
                              <dd>{value}</dd>
                            </div>
                          ))}
                        </dl>
                      )}
                      <details>
                        <summary>Details</summary>
                        <pre>
                          {JSON.stringify(c.args ?? c.payload, null, 2)}
                        </pre>
                        <pre>
                          {c.ack_payload == null
                            ? "No acknowledgement"
                            : JSON.stringify(c.ack_payload, null, 2)}
                        </pre>
                        {c.challenge && (
                          <pre>{JSON.stringify(c.challenge, null, 2)}</pre>
                        )}
                      </details>
                      {props.operator && CANCELLABLE.includes(c.state) && (
                        <button
                          disabled={pending.value !== 0}
                          onClick$={async () => {
                            pending.value = c.id;
                            error.value = "";
                            try {
                              await send(
                                "POST",
                                devicePath(
                                  props.device,
                                  `/commands/${c.id}/cancel`,
                                ),
                                {},
                              );
                              props.refresh();
                            } catch (e) {
                              error.value = errorText(e);
                            } finally {
                              pending.value = 0;
                            }
                          }}
                        >
                          {pending.value === c.id
                            ? "Cancelling…"
                            : `Cancel #${c.id}`}
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </TableRegion>
      )}
    </section>
  );
});
