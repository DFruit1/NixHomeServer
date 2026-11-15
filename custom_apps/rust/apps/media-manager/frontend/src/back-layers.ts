import {
  useVisibleTask$,
  type QRL,
  type ReadonlySignal,
} from "@builder.io/qwik";

// Browser and phone Back close the innermost open layer (a dialog, sheet,
// menu, editor or edit mode) before they leave the current page. Each open
// layer owns one same-URL history entry whose state lists the open layers;
// popping that entry asks the layer to close. Page owners (library selection,
// photos, albums, views) keep their own history and use `pushRoute`, so a new
// page replaces a closing layer's entry instead of stacking a dead one.

const STACK_KEY = "mmBackLayers";

type Layer = { onBack: () => unknown; closing: boolean };

const openLayers = new Map<string, Layer>();
let layerSequence = 0;
let listening = false;
let syncTimer: ReturnType<typeof setTimeout> | undefined;

export function backLayerStack(state: unknown = history.state): string[] {
  const stack = (state as Record<string, unknown> | null)?.[STACK_KEY];
  return Array.isArray(stack)
    ? stack.filter((id): id is string => typeof id === "string")
    : [];
}

// Reconcile history with the open layers once per task, after a render has
// opened and closed whatever it will: closed layers on top are popped (or
// replaced by a newly opened layer) so Back never lands on a dead entry.
function sync() {
  syncTimer = undefined;
  const stack = backLayerStack();
  let live = stack.length;
  while (live > 0 && !openLayers.has(stack[live - 1])) live--;
  const closedOnTop = stack.length - live;
  const unlisted = [...openLayers]
    .filter(([id, layer]) => !layer.closing && !stack.includes(id))
    .map(([id]) => id);
  if (unlisted.length === 0) {
    if (closedOnTop > 0) history.go(-closedOnTop);
    return;
  }
  let next = stack.slice(0, live);
  unlisted.forEach((id, index) => {
    next = [...next, id];
    const state = { ...history.state, [STACK_KEY]: next };
    if (index === 0 && closedOnTop > 0)
      history.replaceState(state, "", location.href);
    else history.pushState(state, "", location.href);
  });
}

function scheduleSync() {
  if (syncTimer === undefined) syncTimer = setTimeout(sync, 0);
}

function onPopState() {
  const stack = backLayerStack();
  // Map order is opening order, so the most recent layer closes first.
  const dropped = [...openLayers]
    .filter(([id, layer]) => !layer.closing && !stack.includes(id))
    .reverse();
  for (const [id, layer] of dropped) {
    layer.closing = true;
    void Promise.resolve()
      .then(layer.onBack)
      .then(
        (result) => result,
        () => false,
      )
      .then((result) => {
        // A layer that stays open (e.g. the user kept a dirty draft) gets its
        // entry back so the next Back asks again.
        if (result !== false || openLayers.get(id) !== layer) return;
        layer.closing = false;
        scheduleSync();
      });
  }
}

/** Registers an open layer; the returned function releases it. */
export function openBackLayer(name: string, onBack: () => unknown) {
  if (typeof window === "undefined") return () => {};
  if (!listening) {
    window.addEventListener("popstate", onPopState);
    listening = true;
  }
  const id = `${name}#${++layerSequence}`;
  const layer: Layer = { onBack, closing: false };
  openLayers.set(id, layer);
  scheduleSync();
  return () => {
    if (openLayers.get(id) !== layer) return;
    openLayers.delete(id);
    if (backLayerStack().includes(id)) scheduleSync();
  };
}

/**
 * Pushes a page-level history entry. When layer entries are on top (they are
 * closing because of this navigation), the new page replaces them.
 */
export function pushRoute(
  state: Record<string, unknown>,
  url: string,
  options: { replace?: boolean } = {},
) {
  const next = { ...state };
  delete next[STACK_KEY];
  if (options.replace || backLayerStack().length > 0)
    history.replaceState(next, "", url);
  else history.pushState(next, "", url);
}

/**
 * While `open` is true, Back calls `onBack$` instead of leaving the page.
 * `onBack$` closes the layer, or returns false to keep it open.
 */
export function useBackLayer(
  name: string,
  open: ReadonlySignal<boolean>,
  onBack$: QRL<() => unknown>,
) {
  // eslint-disable-next-line qwik/no-use-visible-task -- history is browser-only
  useVisibleTask$(({ track, cleanup }) => {
    if (!track(() => open.value)) return;
    cleanup(openBackLayer(name, () => onBack$()));
  });
}
