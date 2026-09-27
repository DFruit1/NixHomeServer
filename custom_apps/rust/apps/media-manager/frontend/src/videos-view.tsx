import { $, component$, useSignal, useStore, useTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import type { CatalogItem, MediaRoot } from "./root-types";

export const VideosView = component$<{
  roots: MediaRoot[];
  initialItemId?: string;
  initialPath?: string;
}>((props) => {
  const videoRef = useSignal<HTMLVideoElement>();
  const state = useStore({
    items: [] as CatalogItem[],
    selectedId: "",
    rootId: "",
    query: "",
    loading: true,
    error: "",
    transcode: false,
    transcodeLoading: false,
  });
  const configuredVideoRoots = props.roots.filter(
    (root) => root.category === "videos",
  );
  const videoRoots = configuredVideoRoots.filter(
    (root) => root.category === "videos" && root.available,
  );

  const loadVideos = $(async () => {
    state.loading = true;
    state.error = "";
    try {
      const roots = state.rootId
        ? videoRoots.filter((root) => root.id === state.rootId)
        : videoRoots;
      const results = await Promise.all(
        roots.map((root) =>
          api<{ items: CatalogItem[] }>(
            `/items?rootId=${encodeURIComponent(root.id)}`,
          ),
        ),
      );
      state.items = results
        .flatMap((result) => result.items)
        .filter((item) => item.mediaKind === "video")
        .sort((a, b) => a.relativePath.localeCompare(b.relativePath));
      if (!state.items.some((item) => item.id === state.selectedId)) {
        const requested = state.items.find(
          (item) =>
            item.id === props.initialItemId ||
            (props.initialPath &&
              (item.relativePath === props.initialPath ||
                item.relativePath.endsWith(`/${props.initialPath}`))),
        );
        state.selectedId = requested?.id ?? state.items[0]?.id ?? "";
        state.transcode = false;
        state.transcodeLoading = false;
      }
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });

  useTask$(async ({ track }) => {
    track(() => state.rootId);
    track(() => props.roots.map((root) => root.id).join("|"));
    await loadVideos();
  });

  const chooseVideo = $((id: string) => {
    state.selectedId = id;
    state.transcode = false;
    state.transcodeLoading = false;
    state.error = "";
  });

  const selected = () =>
    state.items.find((item) => item.id === state.selectedId);
  const streamUrl = () => {
    const item = selected();
    if (!item) return "";
    const suffix = state.transcode ? "?transcode=1" : "";
    return `/api/v1/items/${encodeURIComponent(item.id)}/stream${suffix}`;
  };
  const query = state.query.trim().toLowerCase();
  const visibleItems = query
    ? state.items.filter((item) =>
        item.relativePath.toLowerCase().includes(query),
      )
    : state.items;

  return (
    <section class="video-page" aria-label="Video player">
      <div class="video-player-column">
        {selected() ? (
          <video
            key={`${state.selectedId}-${state.transcode ? "transcoded" : "original"}`}
            ref={videoRef}
            class="video-screen"
            aria-label={selected()!.relativePath.split("/").at(-1)}
            controls
            autoplay
            playsInline
            preload="metadata"
            src={streamUrl()}
            onError$={() => {
              if (!state.transcode) {
                state.transcode = true;
                state.transcodeLoading = true;
              } else {
                state.transcodeLoading = false;
                state.error =
                  "This video could not be played after conversion.";
              }
            }}
            onCanPlay$={() => (state.transcodeLoading = false)}
          />
        ) : (
          <div class="video-screen video-screen-empty">
            <Icon name="video" size={42} />
            <p>{state.loading ? "Loading videos…" : "No videos found"}</p>
          </div>
        )}
        {selected() && (
          <div class="video-title">
            <h2>{selected()!.relativePath.split("/").at(-1)}</h2>
            {selected()!.relativePath.includes("/") && (
              <p>
                {selected()!.relativePath.split("/").slice(0, -1).join("/")}
              </p>
            )}
          </div>
        )}
        {state.transcodeLoading && (
          <p role="status" class="video-conversion-status">
            Converting this video for browser playback. The first play may take
            a while.
          </p>
        )}
        {state.error && (
          <p class="message error" role="alert">
            {state.error}
          </p>
        )}
      </div>

      <aside class="video-library" aria-label="Video library">
        <div class="video-library-header">
          <h2>Videos</h2>
          {videoRoots.length > 1 && (
            <label>
              <span class="sr-only">Video library</span>
              <select
                value={state.rootId}
                onChange$={(_, element) => (state.rootId = element.value)}
              >
                <option value="">All libraries</option>
                {videoRoots.map((root) => (
                  <option key={root.id} value={root.id}>
                    {root.label}
                  </option>
                ))}
              </select>
            </label>
          )}
          <span>
            {visibleItems.length === state.items.length
              ? state.items.length
              : `${visibleItems.length} of ${state.items.length}`}
          </span>
        </div>
        <label class="video-library-filter">
          <span class="sr-only">Filter videos by title or folder</span>
          <input
            type="search"
            placeholder="Filter titles and folders"
            value={state.query}
            onInput$={(_, element) => (state.query = element.value)}
          />
        </label>
        {state.loading ? (
          <p class="video-library-empty">Loading videos…</p>
        ) : state.items.length === 0 ? (
          <p class="video-library-empty">
            {configuredVideoRoots.length === 0
              ? "No video libraries are configured."
              : videoRoots.length === 0
                ? "Video libraries are unavailable."
                : "No videos in this library."}
          </p>
        ) : visibleItems.length === 0 ? (
          <p class="video-library-empty">No matching videos.</p>
        ) : (
          <ul class="video-list">
            {visibleItems.map((item) => (
              <li
                key={item.id}
                class={{ active: item.id === state.selectedId }}
              >
                <button
                  type="button"
                  aria-current={
                    item.id === state.selectedId ? "true" : undefined
                  }
                  onClick$={() => chooseVideo(item.id)}
                >
                  <span class="video-list-icon">
                    <Icon name="video" />
                  </span>
                  <span class="video-list-copy">
                    <strong>{item.relativePath.split("/").at(-1)}</strong>
                    <span>
                      {item.relativePath.split("/").slice(0, -1).join("/") ||
                        "Video library"}
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>
    </section>
  );
});
