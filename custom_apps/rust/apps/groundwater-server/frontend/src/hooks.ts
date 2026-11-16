import {
  $,
  useSignal,
  useStore,
  useVisibleTask$,
  type ReadonlySignal,
} from "@builder.io/qwik";
import { errorText, failure, request } from "./api";
import { latestRequest } from "./live";

export interface Loaded<T> {
  data?: T;
  error: string;
  loading: boolean;
}

/** Fetches `url` (skipped while empty) and refetches when the URL, the live
 * `revision` or the returned `reload` counter changes. Late responses for an
 * earlier URL are discarded. */
export function useJson<T>(
  url: ReadonlySignal<string>,
  revision: ReadonlySignal<number>,
) {
  const state = useStore<Loaded<T>>({ error: "", loading: true });
  const reload = useSignal(0);
  const shown = useSignal("");
  useVisibleTask$(({ track, cleanup }) => {
    const path = track(() => url.value);
    track(() => revision.value);
    track(() => reload.value);
    if (!path) {
      state.loading = false;
      state.data = undefined;
      return;
    }
    if (shown.value !== path) {
      state.data = undefined;
      shown.value = path;
    }
    const latest = latestRequest();
    state.loading = true;
    latest.run(
      (signal) => request<T>(path, signal),
      (value) => {
        state.data = value as never;
        state.error = "";
        state.loading = false;
      },
      (error) => {
        state.error = errorText(error);
        state.loading = false;
      },
    );
    cleanup(() => latest.cancel());
  });
  const again = $(() => {
    reload.value++;
  });
  return { state, reload: again };
}

/** Current time in ms, ticking every `periodMs` while the view is visible
 * (countdowns to the next connection or a nonce expiry). */
export function useNow(periodMs = 1000) {
  const now = useSignal(Date.now());
  useVisibleTask$(({ cleanup }) => {
    const timer = setInterval(() => {
      now.value = Date.now();
    }, periodMs);
    cleanup(() => clearInterval(timer));
  });
  return now;
}

export async function send<T>(
  method: "POST" | "PUT" | "PATCH" | "DELETE",
  path: string,
  body?: unknown,
): Promise<T> {
  const response = await fetch(path, {
    method,
    credentials: "same-origin",
    headers:
      body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw await failure(response);
  const text = await response.text();
  return (text ? JSON.parse(text) : {}) as T;
}

export const devicePath = (device: string, rest = "") =>
  `/api/devices/${encodeURIComponent(device)}${rest}`;
