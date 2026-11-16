// Data stream: ring logs, sequence gaps with manual resend, the device gap
// report and (operators) raw data/stream batches.
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
} from "@builder.io/qwik";
import { errorText, query, stamp } from "./api";
import { devicePath, send, useJson } from "./hooks";
import type {
  Device,
  GapReportRow,
  StreamBatch,
  StreamGap,
  StreamLog,
} from "./types";
import { Feedback, LoadState, TableRegion, WindowPicker } from "./widgets";

type Props = { device: Device; revision: number; operator: boolean };

export const missingFrames = (gap: Pick<StreamGap, "from_seq" | "to_seq">) =>
  gap.to_seq - gap.from_seq + 1;

export const GapReportFacts = component$<{ row: GapReportRow }>((props) => {
  const r = props.row;
  return (
    <dl class="facts">
      <div>
        <dt>Open / requested</dt>
        <dd class={r.open + r.requested ? "error-text" : ""}>
          {r.open} / {r.requested} ({r.missing_open} frames missing)
        </dd>
      </div>
      <div>
        <dt>Unrecoverable</dt>
        <dd class={r.unrecoverable ? "error-text" : ""}>
          {r.unrecoverable} ({r.missing_unrecoverable} frames)
        </dd>
      </div>
      <div>
        <dt>Filled</dt>
        <dd>{r.filled}</dd>
      </div>
      <div>
        <dt>Logger-reported gaps</dt>
        <dd>{r.data_gap_events}</dd>
      </div>
      <div>
        <dt>Oldest open gap</dt>
        <dd>{stamp(r.oldest_open_at)}</dd>
      </div>
      <div>
        <dt>Last stream batch</dt>
        <dd>{stamp(r.last_stream_at)}</dd>
      </div>
    </dl>
  );
});

/** Why readings of a log have no time yet (api_rev2.rs pending_reasons). */
const PENDING_TEXT: Record<string, string> = {
  awaiting_anchor: "waiting for the anchor record that dates them",
  gap_unrecoverable:
    "can never be dated: readings between them and their anchor were lost in an unrecoverable gap",
  awaiting_clock_set: "waiting for the logger's clock to be set",
  no_time: "no time information",
};

export const StreamView = component$<Props>((props) => {
  const rev = useComputed$(() => props.revision);
  const hours = useSignal(720);
  const logsUrl = useComputed$(() =>
    devicePath(props.device.device_id, "/logs"),
  );
  const reportUrl = useComputed$(() => {
    void props.revision;
    const from = new Date(Date.now() - hours.value * 3600000).toISOString();
    return devicePath(
      props.device.device_id,
      `/gaps/report?${query({ from })}`,
    );
  });
  const batchesUrl = useComputed$(() =>
    props.operator
      ? devicePath(props.device.device_id, "/batches?limit=100")
      : "",
  );
  const logs = useJson<{ logs: StreamLog[]; gaps: StreamGap[] }>(logsUrl, rev);
  const report = useJson<{ report: GapReportRow; gaps: StreamGap[] }>(
    reportUrl,
    rev,
  );
  const batches = useJson<{ batches: StreamBatch[] }>(batchesUrl, rev);
  const action = useStore({ pending: 0, message: "", failed: false });
  const resend = $(async (gap: StreamGap) => {
    if (action.pending) return;
    action.pending = gap.id;
    action.message = "";
    try {
      const result = await send<{ command?: { id: number } }>(
        "POST",
        devicePath(props.device.device_id, "/commands"),
        {
          op: "flush_mqtt",
          args: {
            log_id: gap.log_id,
            from_seq: gap.from_seq,
            to_seq: gap.to_seq,
          },
        },
      );
      action.message = `Resend of seq ${gap.from_seq}–${gap.to_seq} queued as #${result.command?.id ?? "?"}.`;
      action.failed = false;
      logs.reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = 0;
    }
  });
  const logRows = logs.state.data?.logs || [];
  const gaps = logs.state.data?.gaps || [];
  return (
    <>
      <section aria-labelledby="gap-report-heading">
        <div class="section-heading">
          <h2 id="gap-report-heading">Gap report</h2>
          <WindowPicker
            hours={hours}
            options={[168, 720, 2160, 8760]}
            label="Gap report window"
          />
        </div>
        <LoadState
          loading={report.state.loading && !report.state.data}
          error={report.state.error}
          label="gap report"
        />
        {report.state.data && <GapReportFacts row={report.state.data.report} />}
      </section>
      <section aria-labelledby="logs-heading">
        <h2 id="logs-heading">Ring logs</h2>
        <LoadState
          loading={logs.state.loading && !logs.state.data}
          error={logs.state.error}
          empty={logRows.length === 0}
          emptyText="No data/stream frames received."
          label="logs"
        />
        {logRows.length > 0 && (
          <TableRegion label="Ring logs">
            <table>
              <thead>
                <tr>
                  <th>Log</th>
                  <th>Frames / sequence</th>
                  <th>Gaps</th>
                  <th>Quality</th>
                  <th>Received</th>
                </tr>
              </thead>
              <tbody>
                {logRows.map((l) => (
                  <tr key={l.log_id}>
                    <td>
                      <strong class="mono">{l.log_hex}</strong>
                      <small>
                        {l.start_reason || "start unknown"} · fw{" "}
                        {l.firmware_version || "?"}
                      </small>
                      <small>started {stamp(l.started_at)}</small>
                    </td>
                    <td class="numeric">
                      {l.frames.toLocaleString()}
                      <small>
                        seq {l.min_seq ?? "—"}–{l.max_seq ?? "—"}
                      </small>
                    </td>
                    <td>
                      <span class={l.open_gaps ? "error-text" : ""}>
                        {l.open_gaps} open
                      </span>
                      <small class={l.unrecoverable_gaps ? "error-text" : ""}>
                        {l.unrecoverable_gaps} unrecoverable
                      </small>
                    </td>
                    <td>
                      <small>{l.decode_errors} decode errors</small>
                      <small>{l.conflicting_copies} conflicting copies</small>
                      <small>{l.resent_copies} resent copies</small>
                      {(l.pending_reasons?.length ?? 0) > 0 ? (
                        l.pending_reasons!.map((r) => (
                          <small
                            key={`${r.state}-${r.min_seq}`}
                            class={
                              r.state === "gap_unrecoverable"
                                ? "error-text"
                                : ""
                            }
                          >
                            {r.count} reading{r.count === 1 ? "" : "s"} without
                            time (seq {r.min_seq ?? "?"}–{r.max_seq ?? "?"}):{" "}
                            {PENDING_TEXT[r.state] || r.reason}
                          </small>
                        ))
                      ) : (
                        <small>
                          {l.pending_readings} readings awaiting time
                        </small>
                      )}
                    </td>
                    <td>{stamp(l.last_received_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableRegion>
        )}
      </section>
      <section aria-labelledby="gaps-heading">
        <h2 id="gaps-heading">Sequence gaps</h2>
        <p class="muted">
          The server requests open gaps automatically (flush_mqtt ranges, three
          attempts at least 30 minutes apart). Request resend queues the same
          command now.
        </p>
        {gaps.length === 0 ? (
          <p class="empty">No sequence gaps detected.</p>
        ) : (
          <TableRegion label="Sequence gaps">
            <table>
              <thead>
                <tr>
                  <th>Range</th>
                  <th>State</th>
                  <th>Requests</th>
                  <th>Detected / resolved</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                {gaps.map((g) => (
                  <tr key={g.id}>
                    <td class="numeric">
                      seq {g.from_seq}–{g.to_seq}
                      <small>
                        {missingFrames(g)} frame
                        {missingFrames(g) === 1 ? "" : "s"} · log {g.log_id}
                      </small>
                    </td>
                    <td>
                      <span
                        class={
                          g.state === "unrecoverable" || g.state === "open"
                            ? "state error-text"
                            : "state"
                        }
                      >
                        {g.state}
                      </span>
                    </td>
                    <td>
                      {g.attempts}
                      {g.command_id != null && (
                        <small>last command #{g.command_id}</small>
                      )}
                    </td>
                    <td>
                      {stamp(g.detected_at)}
                      <small>
                        {g.resolved_at
                          ? `resolved ${stamp(g.resolved_at)}`
                          : "unresolved"}
                      </small>
                    </td>
                    <td>
                      {props.operator && g.state !== "filled" && (
                        <button
                          type="button"
                          disabled={action.pending !== 0}
                          aria-busy={action.pending === g.id}
                          onClick$={() => resend(g)}
                        >
                          Request resend
                        </button>
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
      {props.operator && (
        <section aria-labelledby="batches-heading">
          <h2 id="batches-heading">Raw batches</h2>
          <p class="muted">
            Operator debugging view of data/stream and data/file messages,
            newest first.
          </p>
          <LoadState
            loading={batches.state.loading && !batches.state.data}
            error={batches.state.error}
            empty={(batches.state.data?.batches || []).length === 0}
            emptyText="No batches received."
            label="batches"
          />
          {(batches.state.data?.batches || []).length > 0 && (
            <TableRegion label="Raw batches" bounded>
              <table>
                <thead>
                  <tr>
                    <th>Batch</th>
                    <th>Frames</th>
                    <th>Flags</th>
                    <th>Result</th>
                  </tr>
                </thead>
                <tbody>
                  {batches.state.data!.batches.map((b) => (
                    <tr key={b.id}>
                      <td>
                        #{b.id} · {b.channel}
                        <small>
                          {stamp(b.received_at)} · {b.encoding} · {b.size} B
                          {b.raw_retained ? " · raw kept" : ""}
                        </small>
                      </td>
                      <td class="numeric">
                        {b.frame_count ?? "—"} (new {b.frames_new}, dup{" "}
                        {b.frames_duplicate})
                        <small>
                          log {b.log_id ?? "—"} · seq {b.first_seq ?? "—"}–
                          {b.last_seq ?? "—"}
                        </small>
                      </td>
                      <td>
                        {[
                          b.resend && "resend",
                          b.gap_before && "gap before",
                          b.from_sd && "from SD",
                        ]
                          .filter(Boolean)
                          .join(", ") || "—"}
                      </td>
                      <td>
                        <span class={b.ok ? "state" : "state error-text"}>
                          {b.ok ? "ok" : "refused"}
                        </span>
                        {b.error && <small class="error-text">{b.error}</small>}
                        {(b.issues?.length > 0 || b.warnings?.length > 0) && (
                          <details>
                            <summary>
                              Issues {b.issues.length}, warnings{" "}
                              {b.warnings.length}
                            </summary>
                            <pre>
                              {JSON.stringify(
                                { issues: b.issues, warnings: b.warnings },
                                null,
                                2,
                              )}
                            </pre>
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
      )}
    </>
  );
});
