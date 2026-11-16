import { component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import type { Alert, DeviceEvent, SeriesPoint } from "./types";
import { number, stamp } from "./api";
import { sensorProblem } from "./events";

/** A span in which the logger reported a sensor fault (Type 17 enter until
 * its exit). Levels inside it come from an out-of-range or failed loop and
 * are never plotted as valid (owner decision 2026-11-16). */
export interface FaultSpan {
  from: number;
  /** Infinity while the fault is still open. */
  to: number;
  text: string;
}

/** Fault spans from `sensor_fault` ring records (any order). Enter and exit
 * alternate; a status change is an exit followed by an enter. */
export function faultSpans(
  events: Pick<DeviceEvent, "event" | "recorded_at" | "details" | "seq">[],
): FaultSpan[] {
  const ordered = events
    .filter((e) => e.event === "sensor_fault" && e.recorded_at)
    .map((e) => ({ at: Date.parse(e.recorded_at!), e }))
    .filter(({ at }) => Number.isFinite(at))
    .sort((a, b) => a.at - b.at || (a.e.seq ?? 0) - (b.e.seq ?? 0));
  const spans: FaultSpan[] = [];
  let open: FaultSpan | undefined;
  for (const { at, e } of ordered) {
    const d = e.details || {};
    const status = (d.sensor_status ?? d.ss) as number | undefined;
    if (d.state === "exit") {
      if (open) open.to = at;
      open = undefined;
    } else if (!open) {
      open = {
        from: at,
        to: Infinity,
        text: sensorProblem(typeof status === "number" ? status : 4),
      };
      spans.push(open);
    }
  }
  return spans;
}

/** The fault covering a sample at `time` (or its bucket of `bucketMs`). */
export function faultAt(spans: FaultSpan[], time: number, bucketMs = 0) {
  return spans.find(
    (span) => time < span.to && time + Math.max(bucketMs, 1) > span.from,
  );
}

/** Local time labels across the axis, as many as fit the width. */
export function timeTicks(from: number, to: number, width: number) {
  const count = Math.max(2, Math.min(6, Math.floor((width - 90) / 150) + 1));
  return Array.from(
    { length: count },
    (_, i) => from + ((to - from) * i) / (count - 1),
  );
}

export type Metric = "gwl" | "battery_v" | "rssi" | "solar_v" | "csq";

/** One plotted sample: epoch milliseconds and a value (null breaks the line). */
export type Sample = [number, number | null];

/** Path, scale and gap count for one series. `inverted` draws larger values
 * lower, as depth-to-water charts do. */
export function seriesGeometry(
  samples: Sample[],
  from: number,
  to: number,
  gapMinutes: number,
  limits: (number | null | undefined)[] = [],
  width = 960,
  inverted = false,
  minPad = 0.05,
) {
  const values = samples
    .map(([, v]) => v)
    .filter((v): v is number => v != null && Number.isFinite(v));
  const bounds = [
    ...values,
    ...limits.filter((v): v is number => v != null && Number.isFinite(v)),
  ];
  const low = bounds.length ? Math.min(...bounds) : 0,
    high = bounds.length ? Math.max(...bounds) : 1;
  const pad = Math.max((high - low) * 0.12, minPad);
  const min = low - pad,
    max = high + pad;
  const x = (time: number) =>
    60 + ((time - from) / Math.max(1, to - from)) * (width - 90);
  const y = (value: number) =>
    inverted
      ? 22 + ((value - min) / (max - min)) * 200
      : 222 - ((value - min) / (max - min)) * 200;
  let path = "",
    previous = -Infinity,
    gaps = 0;
  for (const [time, value] of samples) {
    if (value == null || !Number.isFinite(value) || !Number.isFinite(time)) {
      previous = -Infinity;
      continue;
    }
    const gap = time - previous > gapMinutes * 60000;
    if (gap && previous !== -Infinity) gaps++;
    // A zero-length segment after each move draws an isolated sample as a
    // dot (round line caps); within a run it is hidden under the line.
    path += `${gap ? "M" : "L"}${x(time).toFixed(2)},${y(value).toFixed(2)} ${gap ? "l0,0 " : ""}`;
    previous = time;
  }
  return { path, min, max, x, y, gaps };
}

export function chartGeometry(
  points: SeriesPoint[],
  metric: Metric,
  from: number,
  to: number,
  gapMinutes: number,
  limits: (number | null)[] = [],
  width = 960,
  inverted = false,
) {
  return seriesGeometry(
    points.map((p) => [Date.parse(p.recorded_at), p[metric] ?? null]),
    from,
    to,
    gapMinutes,
    limits,
    width,
    inverted,
    metric === "rssi" || metric === "csq" ? 1 : 0.05,
  );
}

const axisTime = (time: number) =>
  new Date(time).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

export interface ChartSeries {
  name: string;
  /** CSS class suffix: series-line metric-<cls>. */
  cls: string;
  samples: Sample[];
}

/** Generic time chart for revision 2 health, tilt and similar series. Several
 * series share one value axis; a legend names them. */
export const TimeChart = component$<{
  title: string;
  unit: string;
  series: ChartSeries[];
  from: number;
  to: number;
  gapMinutes: number;
  digits?: number;
  inverted?: boolean;
  band?: { min: number | null; max: number | null } | null;
}>((props) => {
  const figure = useSignal<HTMLElement>();
  const width = useSignal(960);
  useVisibleTask$(({ cleanup }) => {
    const measure = () => {
      width.value = Math.max(280, Math.round(figure.value?.clientWidth || 960));
    };
    measure();
    const observer = new ResizeObserver(measure);
    if (figure.value) observer.observe(figure.value);
    cleanup(() => observer.disconnect());
  });
  const all: Sample[] = props.series.flatMap((s) => s.samples);
  const scale = seriesGeometry(
    all,
    props.from,
    props.to,
    props.gapMinutes,
    [props.band?.min, props.band?.max],
    width.value,
    props.inverted,
    props.digits === 0 ? 1 : 0.05,
  );
  const count = all.filter(([, v]) => v != null).length;
  const digits = props.digits ?? 2;
  return (
    <figure ref={figure} class="history-chart secondary-chart">
      <figcaption>
        <strong>{props.title}</strong>
        <span class="muted">{props.unit}</span>
        {props.series.length > 1 &&
          props.series.map((s) => (
            <span key={s.name} class={`legend legend-${s.cls}`}>
              {s.name}
            </span>
          ))}
      </figcaption>
      {count === 0 ? (
        <p class="empty">
          No {props.title.toLowerCase()} samples in this range.
        </p>
      ) : (
        <svg
          viewBox={`0 0 ${width.value} 270`}
          role="img"
          aria-label={`${props.title}, ${count} samples. Values are in the table.`}
        >
          {props.band?.min != null && props.band?.max != null && (
            <rect
              class="threshold-band"
              x="60"
              width={width.value - 90}
              y={Math.min(scale.y(props.band.max), scale.y(props.band.min))}
              height={Math.abs(
                scale.y(props.band.min) - scale.y(props.band.max),
              )}
            />
          )}
          {[0, 1, 2, 3, 4].map((tick) => {
            const value = scale.min + ((scale.max - scale.min) * tick) / 4;
            return (
              <g key={tick}>
                <line
                  class="grid-line"
                  x1="60"
                  x2={width.value - 30}
                  y1={scale.y(value)}
                  y2={scale.y(value)}
                />
                <text x="51" y={scale.y(value) + 4} text-anchor="end">
                  {number(value, digits)}
                </text>
              </g>
            );
          })}
          {props.series.map((s) => {
            const geo = seriesGeometry(
              s.samples,
              props.from,
              props.to,
              props.gapMinutes,
              [scale.min, scale.max],
              width.value,
              props.inverted,
              0,
            );
            const single = s.samples.filter(([, v]) => v != null);
            return (
              <g key={s.name}>
                <path class={`series-line metric-${s.cls}`} d={geo.path} />
                {single.length === 1 && (
                  <circle
                    class={`single-point metric-${s.cls}`}
                    cx={geo.x(single[0][0])}
                    cy={geo.y(single[0][1]!)}
                    r="3"
                  />
                )}
              </g>
            );
          })}
          <TimeAxis from={props.from} to={props.to} width={width.value} />
        </svg>
      )}
    </figure>
  );
});

const TimeAxis = component$<{ from: number; to: number; width: number }>(
  (props) => {
    const ticks = timeTicks(props.from, props.to, props.width);
    const x = (time: number) =>
      60 +
      ((time - props.from) / Math.max(1, props.to - props.from)) *
        (props.width - 90);
    return (
      <>
        {ticks.map((time, i) => (
          <text
            key={i}
            x={x(time)}
            y="252"
            text-anchor={
              i === 0 ? "start" : i === ticks.length - 1 ? "end" : "middle"
            }
          >
            {axisTime(time)}
          </text>
        ))}
      </>
    );
  },
);

export const HistoryChart = component$<{
  points: SeriesPoint[];
  metric: Metric;
  title: string;
  unit: string;
  from: string;
  to: string;
  gapMinutes: number;
  min?: number | null;
  max?: number | null;
  alerts?: Alert[];
  inverted?: boolean;
  faults?: FaultSpan[];
}>((props) => {
  const figure = useSignal<HTMLElement>();
  const width = useSignal(960);
  useVisibleTask$(({ cleanup }) => {
    const measure = () => {
      width.value = Math.max(280, Math.round(figure.value?.clientWidth || 960));
    };
    measure();
    const observer = new ResizeObserver(measure);
    if (figure.value) observer.observe(figure.value);
    cleanup(() => observer.disconnect());
  });
  const start = Date.parse(props.from),
    end = Date.parse(props.to);
  const geo = chartGeometry(
    props.points,
    props.metric,
    start,
    end,
    props.gapMinutes,
    [props.min ?? null, props.max ?? null],
    width.value,
    props.inverted,
  );
  const count = props.points.filter((p) => p[props.metric] != null).length;
  return (
    <figure
      ref={figure}
      class={`history-chart ${props.metric !== "gwl" ? "secondary-chart" : ""}`}
    >
      <figcaption>
        <strong>{props.title}</strong>
        <span class="muted">
          {props.unit}
          {geo.gaps
            ? ` · ${geo.gaps} visible gap${geo.gaps === 1 ? "" : "s"}`
            : ""}
        </span>
      </figcaption>
      {count === 0 ? (
        <p class="empty">
          No {props.title.toLowerCase()} measurements in this range.
        </p>
      ) : (
        <svg
          viewBox={`0 0 ${width.value} 270`}
          role="img"
          aria-label={`${props.title} over time, ${count} points. ${geo.gaps} gaps. Values available in the data table below.`}
        >
          {props.min != null && props.max != null && (
            <rect
              class="threshold-band"
              x="60"
              width={width.value - 90}
              y={Math.min(geo.y(props.max), geo.y(props.min))}
              height={Math.abs(geo.y(props.min) - geo.y(props.max))}
            />
          )}
          {[0, 1, 2, 3, 4].map((tick) => {
            const value = geo.min + ((geo.max - geo.min) * tick) / 4;
            return (
              <g key={tick}>
                <line
                  class="grid-line"
                  x1="60"
                  x2={width.value - 30}
                  y1={geo.y(value)}
                  y2={geo.y(value)}
                />
                <text x="51" y={geo.y(value) + 4} text-anchor="end">
                  {number(
                    value,
                    props.metric === "rssi" || props.metric === "csq" ? 0 : 2,
                  )}
                </text>
              </g>
            );
          })}
          {[props.min, props.max].map(
            (limit, index) =>
              limit != null && (
                <g key={index}>
                  <line
                    class="limit-line"
                    x1="60"
                    x2={width.value - 30}
                    y1={geo.y(limit)}
                    y2={geo.y(limit)}
                  />
                  <text
                    class="limit-label"
                    x={width.value - 35}
                    y={geo.y(limit) - 5}
                    text-anchor="end"
                  >
                    {index === 0 ? "min" : "max"}{" "}
                    {String(Number(limit.toFixed(3)))}
                  </text>
                </g>
              ),
          )}
          {(props.faults || [])
            .filter((f) => f.to > start && f.from < end)
            .map((f) => {
              const x1 = geo.x(Math.max(f.from, start)),
                x2 = geo.x(Math.min(f.to, end));
              return (
                <rect
                  key={f.from}
                  class="fault-band"
                  x={x1}
                  y="22"
                  width={Math.max(2, x2 - x1)}
                  height="200"
                >
                  <title>{`Sensor ${f.text} from ${stamp(new Date(f.from).toISOString())}${Number.isFinite(f.to) ? ` to ${stamp(new Date(f.to).toISOString())}` : " (still open)"}`}</title>
                </rect>
              );
            })}
          {(props.alerts || [])
            .filter(
              (a) =>
                Date.parse(a.opened_at) >= start &&
                Date.parse(a.opened_at) <= end,
            )
            .map((a) => (
              <g key={a.id}>
                <line
                  class="alert-marker"
                  x1={geo.x(Date.parse(a.opened_at))}
                  x2={geo.x(Date.parse(a.opened_at))}
                  y1="22"
                  y2="222"
                >
                  <title>{`${a.kind}: ${a.trigger_value} m at ${stamp(a.opened_at)}`}</title>
                </line>
                <text
                  class="alert-label"
                  x={geo.x(Date.parse(a.opened_at))}
                  y="16"
                  text-anchor="middle"
                >
                  !
                </text>
              </g>
            ))}
          <path class={`series-line metric-${props.metric}`} d={geo.path} />
          {props.points.length === 1 &&
            props.points[0][props.metric] != null && (
              <circle
                class="single-point"
                cx={geo.x(Date.parse(props.points[0].recorded_at))}
                cy={geo.y(props.points[0][props.metric]!)}
                r="3"
              />
            )}
          <TimeAxis from={start} to={end} width={width.value} />
        </svg>
      )}
    </figure>
  );
});
