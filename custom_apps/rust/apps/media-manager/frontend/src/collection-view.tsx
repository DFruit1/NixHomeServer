import { $, component$, useSignal, useTask$ } from "@builder.io/qwik";
import type { QRL } from "@builder.io/qwik";
import "./collection-view.css";
import { Icon } from "./icon";

export type CollectionView =
  | "detailed-list"
  | "simple-list"
  | "tiles-1"
  | "tiles-2"
  | "tiles-3"
  | "tiles-4";
type CollectionViewOption = readonly [CollectionView, string];
export const collectionViews: readonly CollectionViewOption[] = [
  ["detailed-list", "Detailed list"],
  ["simple-list", "Simple list"],
  ["tiles-1", "1 tile per row"],
  ["tiles-2", "2 tiles per row"],
  ["tiles-3", "3 tiles per row"],
  ["tiles-4", "4 tiles per row"],
];
/** Photos browse in one full row or a tile grid; Music also keeps simple rows. */
export const photoCollectionViews: readonly CollectionViewOption[] =
  collectionViews.filter(([view]) => view !== "simple-list");
const validView = (
  value: string | null,
  views: readonly CollectionViewOption[],
): value is CollectionView => views.some(([view]) => view === value);
const preferenceKey = (subject: string, surface: string) =>
  `mm-collection-view:v1:${JSON.stringify([subject, surface])}`;

// Local storage supplies the browser/device boundary; the stable account subject
// and collection supply the other two. Never load a device-wide/username fallback
// or persist defaults automatically while identity is still loading.
export function useCollectionView(
  props: { userSubject?: string },
  surface: "images" | "music",
  fallback: CollectionView,
  views: readonly CollectionViewOption[] = collectionViews,
) {
  const view = useSignal<CollectionView>(fallback);
  useTask$(({ track }) => {
    const subject = track(() => props.userSubject);
    view.value = fallback;
    if (!subject || typeof window === "undefined") return;
    try {
      const saved = window.localStorage.getItem(
        preferenceKey(subject, surface),
      );
      if (validView(saved, views)) view.value = saved;
    } catch {
      // Blocked/full storage must not prevent choosing a view for this visit.
    }
  });
  const change = $((value: CollectionView) => {
    if (!validView(value, views)) return;
    view.value = value;
    if (!props.userSubject) return;
    try {
      window.localStorage.setItem(
        preferenceKey(props.userSubject, surface),
        value,
      );
    } catch {
      // Keep the selected layout usable when persistence is unavailable.
    }
  });
  return { view, change };
}

export const CollectionViewControl = component$<{
  label: string;
  value: CollectionView;
  onChange$: QRL<(value: CollectionView) => void>;
  /** Hide the visible "View" caption where space is tight; the select keeps its accessible name. */
  hideCaption?: boolean;
  /** Show the current layout as a short named chip over the native picker. */
  compact?: boolean;
  /** Layouts this surface offers; defaults to every shared layout. */
  views?: readonly CollectionViewOption[];
}>((props) => {
  const views = props.views ?? collectionViews;
  const select = (
    <select
      aria-label={props.label}
      value={props.value}
      onChange$={(_, select) => {
        if (validView(select.value, views))
          return props.onChange$(select.value);
      }}
    >
      {views.map(([value, label]) => (
        <option key={value} value={value}>
          {label}
        </option>
      ))}
    </select>
  );
  if (props.compact) {
    const tiles = props.value.startsWith("tiles-");
    const current = views.find(([value]) => value === props.value);
    // "3 per row" reads as a layout setting, where a bare grid icon and
    // number read like a photo count.
    return (
      <label class="collection-view-compact" title={current?.[1]}>
        <Icon name={tiles ? "grid" : "list"} size={18} />
        <span class="collection-view-current" aria-hidden="true">
          {tiles
            ? `${props.value.slice("tiles-".length)} per row`
            : current?.[1]}
        </span>
        <Icon name="chevron-down" size={14} />
        {select}
      </label>
    );
  }
  return (
    <label class="collection-view-choice">
      {props.hideCaption ? <span class="sr-only">View</span> : "View"}
      {select}
    </label>
  );
});
