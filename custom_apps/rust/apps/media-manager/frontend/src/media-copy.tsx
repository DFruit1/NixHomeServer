import { $, component$, useStore, useTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import type {
  Root,
  CatalogItem,
  ItemsResponse,
  VideoConversionQueued,
  VideoConversionJob,
} from "./api-contract.generated";
import "./comic-archive-action.css";
import "./media-copy.css";

/** Copy audio into another library; the existing worker owns progress/history. */
export const MediaCopy = component$<{
  canEdit: boolean;
  jobs?: VideoConversionJob[];
}>((props) => {
  const state = useStore({
    roots: [] as Root[],
    source: "",
    destination: "",
    search: "",
    items: [] as CatalogItem[],
    cursor: null as string | null,
    loading: true,
    busy: "",
    error: "",
    notice: "",
  });
  useTask$(async () => {
    try {
      state.roots = (await api<Root[]>("/roots")).filter(
        (root) => root.available,
      );
      state.source =
        state.roots.find((root) => root.category === "videos")?.id ?? "";
      state.destination =
        state.roots.find((root) => root.category === "podcasts")?.id ??
        state.roots.find((root) =>
          ["music", "audiobooks"].includes(root.category),
        )?.id ??
        "";
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });
  useTask$(({ track, cleanup }) => {
    const source = track(() => state.source);
    const search = track(() => state.search);
    const controller = new AbortController();
    cleanup(() => controller.abort());
    state.items = [];
    state.cursor = null;
    if (!source) return;
    state.loading = true;
    const timer = setTimeout(async () => {
      try {
        const page = await api<ItemsResponse>(
          `/items?${new URLSearchParams({ rootId: source, search })}`,
          { signal: controller.signal },
        );
        if (!controller.signal.aborted) {
          state.items = page.items.filter((item) => item.mediaKind === "video");
          state.cursor = page.nextCursor ?? null;
          state.error = "";
        }
      } catch (error) {
        if (!controller.signal.aborted) state.error = readableError(error);
      } finally {
        if (!controller.signal.aborted) state.loading = false;
      }
    }, 250);
    cleanup(() => clearTimeout(timer));
  });
  const more = $(async () => {
    if (!state.cursor || state.loading) return;
    const source = state.source,
      search = state.search,
      cursor = state.cursor;
    state.loading = true;
    try {
      const page = await api<ItemsResponse>(
        `/items?${new URLSearchParams({ rootId: source, search, cursor })}`,
      );
      if (source === state.source && search === state.search) {
        state.items = [
          ...state.items,
          ...page.items.filter((item) => item.mediaKind === "video"),
        ];
        state.cursor = page.nextCursor ?? null;
      }
    } catch (error) {
      state.error = readableError(error);
    } finally {
      if (source === state.source && search === state.search)
        state.loading = false;
    }
  });
  const copy = $(async (item: CatalogItem) => {
    if (state.busy) return;
    const destinationRootId = state.destination;
    const destination = state.roots.find(
      (root) => root.id === destinationRootId,
    )?.label;
    state.busy = item.id;
    state.error = "";
    state.notice = "";
    try {
      const result = await api<VideoConversionQueued>("/video-conversions", {
        method: "POST",
        body: JSON.stringify({
          itemIds: [item.id],
          format: "audio-mp3",
          destinationRootId,
        }),
      });
      state.notice = result.jobs.length
        ? `Audio copy of ${item.relativePath} queued for ${destination}. Progress appears in Processing jobs.`
        : result.skipped.map((skip) => skip.reason).join(" ");
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.busy = "";
    }
  });
  return (
    <section
      class="panel comic-conversions media-copy"
      aria-labelledby="media-copy-heading"
    >
      <header class="panel-heading">
        <h2 id="media-copy-heading">Copy audio to another library</h2>
      </header>
      <div class="comic-conversions__body">
        <p class="quiet-copy">
          Keep the video and save its first audio track as an MP3. Existing
          files are kept.
        </p>
        <div class="media-copy-fields">
          <label>
            Video library
            <select
              aria-label="Video library"
              value={state.source}
              onChange$={(_, element) => {
                state.source = element.value;
              }}
            >
              {state.roots
                .filter((root) => root.category === "videos")
                .map((root) => (
                  <option key={root.id} value={root.id}>
                    {root.label}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Copy to
            <select
              aria-label="Copy to"
              value={state.destination}
              disabled={!!state.busy}
              onChange$={(_, element) => {
                state.destination = element.value;
              }}
            >
              {state.roots
                .filter((root) =>
                  ["music", "podcasts", "audiobooks"].includes(root.category),
                )
                .map((root) => (
                  <option key={root.id} value={root.id}>
                    {`${root.label} · ${root.category}`}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Find a video
            <input
              type="search"
              value={state.search}
              onInput$={(_, element) => {
                state.search = element.value;
              }}
            />
          </label>
        </div>
        {!state.loading && !state.source && (
          <p>No video library is available.</p>
        )}
        {!state.loading && !state.destination && (
          <p>No music, podcast or audiobook library is available.</p>
        )}
        {!props.canEdit && (
          <p>Copying audio requires the Media Manager editor group.</p>
        )}
        {state.error && (
          <p class="message error" role="alert">
            {state.error}
          </p>
        )}
        {state.notice && (
          <p class="message success" role="status">
            {state.notice}
          </p>
        )}
        <ul class="comic-conversions__list">
          {state.items.map((item) => (
            <li key={item.id}>
              <div class="comic-conversions__name">
                <strong>{item.relativePath.split("/").at(-1)}</strong>
                <small>{item.relativePath}</small>
              </div>
              <button
                type="button"
                class="secondary-button"
                disabled={!props.canEdit || !state.destination || !!state.busy}
                onClick$={() => copy(item)}
              >
                {state.busy === item.id ? "Queuing…" : "Copy audio"}
              </button>
            </li>
          ))}
        </ul>
        {state.loading && <p role="status">Loading videos…</p>}
        {!state.loading &&
          state.source &&
          !state.items.length &&
          !state.error && <p>No videos found.</p>}
        {state.cursor && (
          <button
            type="button"
            class="secondary-button"
            disabled={state.loading}
            onClick$={more}
          >
            Load more
          </button>
        )}
        {(props.jobs ?? []).filter(
          (job) =>
            job.destinationRootId &&
            ["completed", "failed", "cancelled"].includes(job.state),
        ).length > 0 && (
          <>
            <h3>Your audio copies</h3>
            <ul class="comic-conversions__list">
              {(props.jobs ?? [])
                .filter(
                  (job) =>
                    job.destinationRootId &&
                    ["completed", "failed", "cancelled"].includes(job.state),
                )
                .map((job) => (
                  <li key={job.id}>
                    <div class="comic-conversions__name">
                      <strong>{job.relativePath}</strong>
                      <small>
                        {job.state === "completed"
                          ? `Saved ${job.outputRelativePath} to ${state.roots.find((root) => root.id === job.destinationRootId)?.label ?? job.destinationRootId}`
                          : job.error || "Cancelled"}
                      </small>
                    </div>
                    {job.state === "completed" && (
                      <a
                        class="text-button"
                        href={`?view=library&root=${encodeURIComponent(job.destinationRootId!)}`}
                      >
                        Open library
                      </a>
                    )}
                  </li>
                ))}
            </ul>
          </>
        )}
      </div>
    </section>
  );
});
