import { component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import type { Alert, SeriesPoint } from "./types";
import { number, stamp } from "./api";

export type Metric = "gwl" | "battery_v" | "rssi";
export function chartGeometry(
  points: SeriesPoint[],
  metric: Metric,
  from: number,
  to: number,
  gapMinutes: number,
  limits: (number | null)[] = [],
  width = 960,
) {
  const values = points
    .map((p) => p[metric])
    .filter((v): v is number => v != null && Number.isFinite(v));
  const bounds = [
    ...values,
    ...limits.filter((v): v is number => v != null && Number.isFinite(v)),
  ];
  const low = bounds.length ? Math.min(...bounds) : 0,
    high = bounds.length ? Math.max(...bounds) : 1;
  const pad = Math.max((high - low) * 0.12, metric === "rssi" ? 1 : 0.05);
  const min = low - pad,
    max = high + pad;
  const x = (time: number) =>
    60 + ((time - from) / Math.max(1, to - from)) * (width - 90);
  const y = (value: number) => 222 - ((value - min) / (max - min)) * 200;
  let path = "",
    previous = -Infinity,
    gaps = 0;
  for (const point of points) {
    const time = Date.parse(point.recorded_at),
      value = point[metric];
    if (value == null || !Number.isFinite(value)) {
      previous = -Infinity;
      continue;
    }
    const gap = time - previous > gapMinutes * 60000;
    if (gap && previous !== -Infinity) gaps++;
    path += `${gap ? "M" : "L"}${x(time).toFixed(2)},${y(value).toFixed(2)} `;
    previous = time;
  }
  return { path, min, max, x, y, gaps };
}

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
  const axisTime = (time: number) =>
    new Date(time).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
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
              y={geo.y(props.max)}
              height={Math.max(0, geo.y(props.min) - geo.y(props.max))}
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
                  {number(value, props.metric === "rssi" ? 0 : 2)}
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
                    {index === 0 ? "min" : "max"} {String(limit)}
                  </text>
                </g>
              ),
          )}
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
          <text x="60" y="252">
            {axisTime(start)}
          </text>
          <text x={width.value - 30} y="252" text-anchor="end">
            {axisTime(end)}
          </text>
        </svg>
      )}
    </figure>
  );
});
