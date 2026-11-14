import { $, component$, useSignal, useTask$ } from "@builder.io/qwik";
import type { QRL } from "@builder.io/qwik";
import "./collection-view.css";

export const collectionViews = [
  ["detailed-list", "Detailed list"],
  ["simple-list", "Simple list"],
  ["tiles-1", "1 tile per row"],
  ["tiles-2", "2 tiles per row"],
  ["tiles-3", "3 tiles per row"],
  ["tiles-4", "4 tiles per row"],
] as const;
export type CollectionView = (typeof collectionViews)[number][0];
const validView = (value: string | null): value is CollectionView =>
  collectionViews.some(([view]) => view === value);
const preferenceKey = (subject: string, surface: string) =>
  `mm-collection-view:v1:${JSON.stringify([subject, surface])}`;

// Local storage supplies the browser/device boundary; the stable account subject
// and collection supply the other two. Never load a device-wide/username fallback
// or persist defaults automatically while identity is still loading.
export function useCollectionView(
  props: { userSubject?: string },
  surface: "images" | "music",
  fallback: CollectionView,
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
      if (validView(saved)) view.value = saved;
    } catch {
      // Blocked/full storage must not prevent choosing a view for this visit.
    }
  });
  const change = $((value: CollectionView) => {
    if (!validView(value)) return;
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
}>((props) => (
  <label class="collection-view-choice">
    {props.hideCaption ? <span class="sr-only">View</span> : "View"}
    <select
      aria-label={props.label}
      value={props.value}
      onChange$={(_, select) => {
        if (validView(select.value)) return props.onChange$(select.value);
      }}
    >
      {collectionViews.map(([value, label]) => (
        <option key={value} value={value}>
          {label}
        </option>
      ))}
    </select>
  </label>
));
