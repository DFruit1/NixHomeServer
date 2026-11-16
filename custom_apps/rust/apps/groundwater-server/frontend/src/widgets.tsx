import { component$, Slot, type Signal } from "@builder.io/qwik";
import { CLOCK_FLOOR_MS, stamp } from "./api";
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
