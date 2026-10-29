export interface LiveSource {
  readyState: number;
  onopen: ((event: Event) => void) | null;
  onerror: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent) => void) | null;
  addEventListener(type: string, listener: () => void): void;
  close(): void;
}
export function connectLive(
  refresh: () => void,
  status: (text: string) => void,
  create: (() => LiveSource) | undefined = typeof EventSource === "undefined"
    ? undefined
    : () => new EventSource("/api/events"),
) {
  let source: LiveSource | undefined,
    timer: ReturnType<typeof setTimeout> | undefined;
  const schedule = () => {
    // Bound the wait even while a backlog produces an uninterrupted stream.
    if (timer !== undefined) return;
    timer = setTimeout(() => {
      timer = undefined;
      refresh();
    }, 300);
  };
  try {
    source = create?.();
    if (source) {
      source.onopen = () => {
        status("Live");
        schedule();
      };
      source.onerror = () => status("Reconnecting · polling every 30 s");
      source.onmessage = schedule;
      source.addEventListener("resync", schedule);
    } else status("Polling every 30 s");
  } catch {
    status("Polling every 30 s");
  }
  const poll = setInterval(() => {
    if (!source || source.readyState !== 1) refresh();
  }, 30000);
  return () => {
    clearInterval(poll);
    clearTimeout(timer);
    source?.close();
  };
}

// Aborting alone is insufficient if a response has already completed. The
// identity check also rejects late results from a previous selection.
export function latestRequest() {
  let current: AbortController | undefined;
  return {
    run<T>(
      load: (signal: AbortSignal) => Promise<T>,
      apply: (value: T) => void,
      fail: (error: unknown) => void,
    ) {
      current?.abort();
      const controller = new AbortController();
      current = controller;
      void load(controller.signal).then(
        (value) => {
          if (current === controller && !controller.signal.aborted)
            apply(value);
        },
        (error) => {
          if (current === controller && !controller.signal.aborted) fail(error);
        },
      );
    },
    cancel() {
      current?.abort();
      current = undefined;
    },
  };
}
