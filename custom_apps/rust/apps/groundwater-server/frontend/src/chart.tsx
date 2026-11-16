import { component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import type { Alert, Series, SeriesPoint } from "./types";
import { number, stamp } from "./api";
import { sensorProblem } from "./events";
import { alertLabel, alertValue } from "./alert-text";

/** Fault readings at one place on the time axis, from the series' own
 * `faults` list (owner decision 2026-11-16: an out-of-range or failed
 * reading is "possible sensor failure", never a level). `valid` > 0 marks a
 * bucket whose plotted average comes from its valid samples only. */
export interface FaultMark {
  /** Epoch ms: the reading, or the bucket start. */
  at: number;
  count: number;
  valid: number;
  text: string;
}

/** A run of fault readings with no valid level between them, drawn as one
 * shaded span. */
export interface FaultSpan {
  from: number;
  to: number;
  count: number;
  text: string;
}

const RANGE_KINDS = ["under-range", "over-range"];

/** Operator wording for fault kinds (`over-range`, `no-sensor`, …) or a raw
 * reading's status: out of range is "possible sensor failure". */
export function faultText(kinds: string[], status?: number | null): string {
  if (status != null && status !== 0) return sensorProblem(status);
  const range = kinds.filter((k) => RANGE_KINDS.includes(k));
  const other = kinds.filter((k) => !RANGE_KINDS.includes(k));
  return [
    range.length
      ? `out of range: possible sensor failure (${range.join(", ")})`
      : "",
    other.length ? `sensor fault: ${other.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("; ");
}

/** A point that is not a valid level: a raw reading with a fault status
 * (the firmware still sends its untrustworthy level). Buckets never are:
 * their level is the average of valid samples. */
export const isFaultPoint = (p: Pick<SeriesPoint, "sensor_status">) =>
  p.sensor_status != null && p.sensor_status !== 0;

/** The level series as chart input: fault points become breaks, so a fault
 * is never drawn or scaled as a level; each fault entry becomes a mark. */
export function levelSeries(
  series: Pick<Series, "points" | "faults" | "bucket_minutes">,
) {
  const samples: Sample[] = series.points.map((p) => [
    Date.parse(p.recorded_at),
    isFaultPoint(p) ? null : p.gwl,
  ]);
  const marks: FaultMark[] = (series.faults || [])
    .map((f) => ({
      at: Date.parse(f.recorded_at),
      count: f.fault_count,
      valid: f.valid_count,
      text: faultText(f.fault_kinds, f.sensor_status),
    }))
    .filter((m) => Number.isFinite(m.at))
    .sort((a, b) => a.at - b.at);
  return { samples, marks };
}

/** Spans of fault marks without a valid level (`valid` 0), merged while no
 * valid sample lies between them and they are at most `gapMinutes` apart
 * (a longer silence stays a gap). A bucket span covers its width. */
export function faultSpans(
  marks: FaultMark[],
  samples: Sample[],
  bucketMinutes: number,
  gapMinutes: number,
): FaultSpan[] {
  const valid = samples
    .filter(([, v]) => v != null)
    .map(([t]) => t)
    .sort((a, b) => a - b);
  const width = bucketMinutes * 60000;
  const spans: FaultSpan[] = [];
  let i = 0,
    lastAt = -Infinity;
  for (const mark of marks.filter((m) => m.valid === 0)) {
    // Index of the first valid sample after this mark.
    while (i < valid.length && valid[i] <= mark.at) i++;
    const last = spans[spans.length - 1];
    const validBetween = i > 0 && valid[i - 1] > lastAt;
    if (last && !validBetween && mark.at - lastAt <= gapMinutes * 60000) {
      last.to = mark.at + width;
      last.count += mark.count;
      if (!last.text.includes(mark.text)) last.text += `; ${mark.text}`;
    } else
      spans.push({
        from: mark.at,
        to: mark.at + width,
        count: mark.count,
        text: mark.text,
      });
    lastAt = mark.at;
  }
  return spans;
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
  nonNegative = false,
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
  // A quantity that cannot be negative (volts, bytes, CSQ) is never padded
  // below zero.
  const min = nonNegative && low >= 0 ? Math.max(0, low - pad) : low - pad,
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
    points.map((p) => [
      Date.parse(p.recorded_at),
      // A raw fault reading keeps the firmware's level: never a level here.
      metric === "gwl" && isFaultPoint(p) ? null : (p[metric] ?? null),
    ]),
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
  /** Volts, bytes, CSQ: the axis never goes below zero. */
  nonNegative?: boolean;
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
    props.nonNegative,
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
  /** Fault readings without a valid level (shaded). */
  faults?: FaultSpan[];
  /** Buckets whose valid average is drawn but that also held faults. */
  mixed?: FaultMark[];
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
  const levels = new Map(
    props.points.map((p) => [Date.parse(p.recorded_at), p[props.metric]]),
  );
  const count = props.points.filter(
    (p) =>
      p[props.metric] != null && !(props.metric === "gwl" && isFaultPoint(p)),
  ).length;
  const empty = count === 0 && !(props.faults || []).length;
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
      {empty ? (
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
            .filter((f) => f.to >= start && f.from <= end)
            .map((f) => {
              const x1 = geo.x(Math.max(f.from, start)),
                x2 = geo.x(Math.min(f.to, end));
              return (
                <rect
                  key={f.from}
                  class="fault-band"
                  x={Math.min(x1, width.value - 33)}
                  y="22"
                  width={Math.max(3, x2 - x1)}
                  height="200"
                >
                  <title>{`${f.count} reading${f.count === 1 ? "" : "s"}, ${stamp(new Date(f.from).toISOString())}${f.to > f.from ? ` to ${stamp(new Date(f.to).toISOString())}` : ""}: ${f.text}. No level.`}</title>
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
                  <title>{`${alertLabel(a)}: ${alertValue(a)} at ${stamp(a.opened_at)}`}</title>
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
            props.points[0][props.metric] != null &&
            count === 1 && (
              <circle
                class="single-point"
                cx={geo.x(Date.parse(props.points[0].recorded_at))}
                cy={geo.y(props.points[0][props.metric]!)}
                r="3"
              />
            )}
          {(props.mixed || []).map((m) => {
            const value = levels.get(m.at);
            return value == null ? null : (
              <circle
                key={m.at}
                class="fault-point"
                cx={geo.x(m.at)}
                cy={geo.y(value)}
                r="4"
              >
                <title>{`${stamp(new Date(m.at).toISOString())}: average of ${m.valid} valid sample${m.valid === 1 ? "" : "s"}; the bucket also held ${m.count} fault reading${m.count === 1 ? "" : "s"} (${m.text})`}</title>
              </circle>
            );
          })}
          <TimeAxis from={start} to={end} width={width.value} />
        </svg>
      )}
    </figure>
  );
});
