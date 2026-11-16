import {
  $,
  component$,
  Slot,
  useStore,
  type QRL,
  type Signal,
} from "@builder.io/qwik";
import { CLOCK_FLOOR_MS, downloadExport, errorText, stamp } from "./api";
import { relative } from "./format";

/** Status line for an operator action (polite on success, alert on error). */
export const Feedback = component$<{ message: string; failed: boolean }>(
  (props) =>
    props.message ? (
      <p
        role={props.failed ? "alert" : "status"}
        class={props.failed ? "notice error-text" : "notice"}
      >
        {props.message}
      </p>
    ) : null,
);

/** Paging props of a command list: the server lists 500 commands per page. */
export interface CommandPaging {
  truncated?: boolean;
  more?: QRL<() => void>;
  moreLoading?: boolean;
  moreError?: string;
}

/** "Show older commands" below a command list cut at a page. */
export const OlderCommands = component$<CommandPaging & { shown: number }>(
  (props) => (
    <>
      <Feedback message={props.moreError || ""} failed />
      {props.truncated && props.more && (
        <p class="toolbar">
          <span class="muted">
            {props.shown.toLocaleString()} newest commands shown.
          </span>
          <button
            type="button"
            disabled={props.moreLoading}
            aria-busy={props.moreLoading}
            onClick$={() => props.more!()}
          >
            {props.moreLoading ? "Loading…" : "Show older commands"}
          </button>
        </p>
      )}
    </>
  ),
);

/** Loading / error / empty states shared by the fetched views. */
export const LoadState = component$<{
  loading: boolean;
  error: string;
  empty?: boolean;
  emptyText?: string;
  label?: string;
}>((props) => (
  <>
    {props.error && (
      <p role="alert" class="notice error-text">
        {props.error}
      </p>
    )}
    {props.loading && (
      <p role="status" class="muted">
        Loading {props.label || ""}…
      </p>
    )}
    {!props.loading && !props.error && props.empty && (
      <p class="empty">{props.emptyText || "Nothing recorded yet."}</p>
    )}
  </>
));

/** Recent-window buttons (hours) bound to a signal. */
export const WindowPicker = component$<{
  hours: Signal<number>;
  options?: number[];
  label?: string;
}>((props) => (
  <div class="quick-range" role="group" aria-label={props.label || "Window"}>
    {(props.options || [24, 168, 720, 2160]).map((hours) => (
      <button
        key={hours}
        type="button"
        aria-pressed={props.hours.value === hours}
        onClick$={() => {
          props.hours.value = hours;
        }}
      >
        {hours < 48
          ? `${hours} hours`
          : hours % 24 === 0
            ? `${hours / 24} days`
            : `${hours} h`}
      </button>
    ))}
  </div>
));

/** Absolute local time with a relative hint. */
export const When = component$<{ at: string | null | undefined; now?: number }>(
  (props) =>
    props.at && Date.parse(props.at) >= CLOCK_FLOOR_MS ? (
      <span title={props.at}>
        {stamp(props.at)}{" "}
        <span class="muted">({relative(props.at, props.now)})</span>
      </span>
    ) : (
      <span>{props.at ? "clock not set" : "—"}</span>
    ),
);

/** Scrollable, labelled table region. */
export const TableRegion = component$<{ label: string; bounded?: boolean }>(
  (props) => (
    <div
      class={props.bounded ? "table-scroll bounded" : "table-scroll"}
      role="region"
      aria-label={props.label}
      tabIndex={0}
    >
      <Slot />
    </div>
  ),
);

/** Meter for a 0–1 fraction with a text value (unsaved vs usable, download
 * progress). */
export const Meter = component$<{
  value: number | null;
  label: string;
  text: string;
  warnAbove?: number;
}>((props) => (
  <div class="meter-row">
    <meter
      min={0}
      max={1}
      high={props.warnAbove ?? 0.8}
      optimum={0}
      value={props.value ?? 0}
      aria-label={props.label}
    />
    <span>{props.text}</span>
  </div>
));

/** Saves a capped JSON export (events, positions) and, when the server
 * cut it, says so and offers the next part from the last row's time. */
export const ExportButton = component$<{
  /** Export path without `from`. */
  path: string;
  from?: string;
  label: string;
  fileName: string;
}>((props) => {
  const state = useStore({
    pending: false,
    message: "",
    failed: false,
    next: "",
  });
  const run = $(async (from: string) => {
    if (state.pending) return;
    state.pending = true;
    state.message = "";
    state.next = "";
    try {
      const sep = props.path.includes("?") ? "&" : "?";
      const cut = await downloadExport(
        from
          ? `${props.path}${sep}from=${encodeURIComponent(from)}`
          : props.path,
        props.fileName,
      );
      if (cut.truncated) {
        state.failed = true;
        state.message = `The file was cut at ${cut.limit?.toLocaleString() ?? "the server's limit of"} rows, oldest first; it ends at ${stamp(cut.lastAt)}.`;
        state.next = cut.lastAt || "";
      }
    } catch (error) {
      state.failed = true;
      state.message = errorText(error);
    } finally {
      state.pending = false;
    }
  });
  return (
    <>
      <button
        type="button"
        class="button"
        aria-busy={state.pending}
        disabled={state.pending}
        onClick$={() => run(props.from || "")}
      >
        {props.label}
      </button>
      {state.message && (
        <p
          role={state.failed ? "alert" : "status"}
          class="notice error-text export-note"
        >
          {state.message}{" "}
          {state.next && (
            <button type="button" onClick$={() => run(state.next)}>
              Export the rest from {stamp(state.next)}
            </button>
          )}
          {state.next && (
            <small>
              Rows at exactly that time can appear in both files; their ids tell
              them apart.
            </small>
          )}
        </p>
      )}
    </>
  );
});
