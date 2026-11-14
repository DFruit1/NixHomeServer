import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, catalogItems, readableError } from "./api";
import { Icon } from "./icon";
import { findTargetIndex, prepareBrowserPlayback } from "./playback-target";
import type { CatalogItem, MediaRoot } from "./root-types";
import { thumbnailSizes, thumbnailSrc, thumbnailSrcset } from "./thumbnail";
import {
  audioNeedsBrowserConversion,
  decodedAudioState,
  probeReportsNoAudio,
} from "./video-audio";

const THEATRE_STORAGE_KEY = "media-manager.videos.theatre";

function fileName(relativePath: string): string {
  return relativePath.split("/").at(-1) ?? relativePath;
}

// The title shown for a video is its metadata title; the file name without the
// extension is the fallback when no title has been set.
function fileStem(relativePath: string): string {
  const filename = fileName(relativePath);
  const extension = filename.match(/\.[^.\s]{1,5}$/)?.[0] ?? "";
  return extension && extension.length < filename.length
    ? filename.slice(0, -extension.length)
    : filename;
}

// Rows show only the title: the extension stays in the tooltip and for screen
// readers, and the folder remains searchable through the filter.
const VideoListCopy = component$<{ relativePath: string }>((props) => {
  const filename = fileName(props.relativePath);
  const stem = fileStem(props.relativePath);
  return (
    <span class="video-list-copy">
      <strong title={filename}>
        {stem}
        {stem !== filename && (
          <span class="sr-only">{filename.slice(stem.length)}</span>
        )}
      </strong>
    </span>
  );
});

export const VideosView = component$<{
  roots: MediaRoot[];
  initialItemId?: string;
  initialPath?: string;
}>((props) => {
  const videoRef = useSignal<HTMLVideoElement>();
  const pipSupported = useSignal(false);
  const pipActive = useSignal(false);
  const theatre = useSignal(false);
  // Position to restore when the converted copy replaces the original, so a
  // long conversion does not send the viewer back to the start.
  const resumeAt = useSignal(0);
  const state = useStore({
    items: [] as CatalogItem[],
    selectedId: "",
    title: "",
    rootId: "",
    query: "",
    loading: true,
    error: "",
    transcode: false,
    transcodeLoading: false,
    audioChecked: false,
  });
  const configuredVideoRoots = props.roots.filter(
    (root) => root.category === "videos",
  );
  const videoRoots = configuredVideoRoots.filter(
    (root) => root.category === "videos" && root.available,
  );

  const loadGeneration = useSignal(0);
  const preparationGeneration = useSignal(0);
  const titleGeneration = useSignal(0);

  const loadVideos = $(async () => {
    const generation = ++loadGeneration.value;
    const current = () => generation === loadGeneration.value;
    state.loading = true;
    state.error = "";
    try {
      const roots = state.rootId
        ? videoRoots.filter((root) => root.id === state.rootId)
        : videoRoots;
      const results = await Promise.all(
        roots.map((root) => catalogItems(root.id, current, true)),
      );
      if (!current()) return;
      state.items = results
        .flatMap((result) => result.items)
        .filter((item) => item.mediaKind === "video")
        .sort((a, b) => a.relativePath.localeCompare(b.relativePath));
      if (
        !state.rootId &&
        props.initialItemId &&
        !state.items.some((item) => item.id === props.initialItemId)
      ) {
        const targetId = props.initialItemId;
        const item = await api<CatalogItem>(
          `/items/${encodeURIComponent(targetId)}`,
        );
        if (!current() || props.initialItemId !== targetId) return;
        if (item.mediaKind !== "video")
          throw new Error("This file is not a video.");
        state.items = [...state.items, item];
      }
      if (!state.items.some((item) => item.id === state.selectedId)) {
        const requestedIndex = findTargetIndex(
          state.items,
          props.initialItemId,
          props.initialPath,
        );
        state.selectedId =
          requestedIndex >= 0
            ? state.items[requestedIndex]!.id
            : (state.items[0]?.id ?? "");
        state.transcode = false;
        state.transcodeLoading = false;
        state.audioChecked = false;
      }
    } catch (error) {
      if (current()) state.error = readableError(error);
    } finally {
      if (current()) state.loading = false;
    }
  });

  useTask$(async ({ track }) => {
    track(() => state.rootId);
    track(() => props.roots.map((root) => root.id).join("|"));
    await loadVideos();
  });

  const chooseVideo = $((id: string) => {
    preparationGeneration.value++;
    state.selectedId = id;
    state.title = "";
    state.transcode = false;
    state.transcodeLoading = false;
    state.audioChecked = false;
    state.error = "";
    resumeAt.value = 0;
  });

  // Browsers render a video whose audio codec they cannot decode without
  // raising an error, so a silent track never reaches the error fallback.
  // Prepare the H.264/AAC conversion up front whenever we already know the
  // track would be dropped.
  const prepareBrowserCopy = $(async (id: string) => {
    const generation = ++preparationGeneration.value;
    const current = () =>
      generation === preparationGeneration.value && state.selectedId === id;
    state.transcodeLoading = true;
    try {
      const started = videoRef.value?.currentTime ?? 0;
      if (await prepareBrowserPlayback(id, current)) {
        resumeAt.value = started;
        state.transcode = true;
      }
    } catch (error) {
      if (current()) state.error = readableError(error);
    } finally {
      if (current()) state.transcodeLoading = false;
    }
  });

  useTask$(async ({ track }) => {
    track(() => state.selectedId);
    const item = selected();
    if (!item || !audioNeedsBrowserConversion(item.videoProbe)) return;
    await prepareBrowserCopy(item.id);
  });

  // The probe cache fills in the background, so a just-scanned video may not
  // have one yet. Chrome and Firefox report whether audio was actually decoded
  // after playback starts; an unprobed silent element means the track was
  // dropped, and the conversion restores it.
  const checkDecodedAudio = $(() => {
    const video = videoRef.value;
    if (
      !video ||
      state.transcode ||
      state.transcodeLoading ||
      state.audioChecked
    )
      return;
    if (video.currentTime < 3) return;
    state.audioChecked = true;
    const item = selected();
    if (!item || item.videoProbe || probeReportsNoAudio(item.videoProbe))
      return;
    if (decodedAudioState(video) !== "silent") return;
    void prepareBrowserCopy(item.id);
  });

  useTask$(async ({ track }) => {
    track(() => state.selectedId);
    const itemId = state.selectedId;
    const generation = ++titleGeneration.value;
    const current = () => generation === titleGeneration.value;
    state.title = "";
    if (!itemId) return;
    try {
      const metadata = await api<{ title?: string }>(
        `/items/${encodeURIComponent(itemId)}/metadata`,
      );
      if (!current()) return;
      const title = String(metadata.title ?? "").trim();
      if (title) state.title = title;
    } catch {
      // Without a metadata title the file name remains the fallback.
    }
  });

  useVisibleTask$(({ cleanup }) => {
    try {
      theatre.value = localStorage.getItem(THEATRE_STORAGE_KEY) === "1";
    } catch {
      // Storage can be unavailable; the default layout still works.
    }
    cleanup(() => {
      preparationGeneration.value++;
    });
  });

  const toggleTheatre = $(() => {
    theatre.value = !theatre.value;
    try {
      localStorage.setItem(THEATRE_STORAGE_KEY, theatre.value ? "1" : "0");
    } catch {
      // Keep the choice for this visit only.
    }
  });

  // Picture-in-Picture is available in Chrome for Android and on desktop
  // browsers. It needs a user gesture, so it is exposed as a button rather than
  // triggered automatically; browsers also auto-enter PiP when the page is
  // occluded if a media session is registered below.
  const togglePip = $(async () => {
    const video = videoRef.value;
    if (!video || typeof document === "undefined") return;
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (document.pictureInPictureEnabled) {
        await video.requestPictureInPicture();
      }
    } catch {
      pipActive.value = false;
    }
  });

  const selected = () =>
    state.items.find((item) => item.id === state.selectedId);
  const displayTitle = () => {
    const item = selected();
    if (!item) return "";
    return state.title || fileStem(item.relativePath);
  };
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

  useVisibleTask$(({ track, cleanup }) => {
    track(() => state.selectedId);
    track(() => state.transcode);
    pipSupported.value =
      typeof document !== "undefined" &&
      document.pictureInPictureEnabled === true;
    const video = videoRef.value;
    if (!video) return;
    const onEnter = () => (pipActive.value = true);
    const onLeave = () => (pipActive.value = false);
    video.addEventListener("enterpictureinpicture", onEnter);
    video.addEventListener("leavepictureinpicture", onLeave);
    cleanup(() => {
      video.removeEventListener("enterpictureinpicture", onEnter);
      video.removeEventListener("leavepictureinpicture", onLeave);
    });
  });

  useVisibleTask$(({ track, cleanup }) => {
    track(() => state.selectedId);
    track(() => state.transcode);
    if (typeof navigator === "undefined" || !("mediaSession" in navigator)) {
      return;
    }
    const item = selected();
    if (!item) return;
    const filename = item.relativePath.split("/").at(-1) ?? "";
    const folder = item.relativePath.split("/").slice(0, -1).join("/");
    let sessionMetadata: MediaMetadata | null = null;
    const claimSession = () => {
      sessionMetadata = new MediaMetadata({
        title: filename,
        artist: folder,
      });
      navigator.mediaSession.metadata = sessionMetadata;
      navigator.mediaSession.playbackState = "playing";
      navigator.mediaSession.setActionHandler("play", () => {
        void videoRef.value?.play();
      });
      navigator.mediaSession.setActionHandler("pause", () => {
        videoRef.value?.pause();
      });
      navigator.mediaSession.setActionHandler(
        "enterpictureinpicture" as unknown as MediaSessionAction,
        () => {
          void togglePip();
        },
      );
    };
    const video = videoRef.value;
    video?.addEventListener("play", claimSession);
    cleanup(() => {
      video?.removeEventListener("play", claimSession);
      // Audio may have reclaimed the session while this page was visible.
      if (
        !sessionMetadata ||
        navigator.mediaSession.metadata !== sessionMetadata
      )
        return;
      navigator.mediaSession.metadata = null;
      navigator.mediaSession.playbackState = "none";
      navigator.mediaSession.setActionHandler("play", null);
      navigator.mediaSession.setActionHandler("pause", null);
      navigator.mediaSession.setActionHandler(
        "enterpictureinpicture" as unknown as MediaSessionAction,
        null,
      );
    });
  });

  return (
    <section
      class={{ "video-page": true, "video-page--theatre": theatre.value }}
      aria-label="Video player"
    >
      <div class="video-player-column">
        {selected() ? (
          <video
            key={`${state.selectedId}-${state.transcode ? "transcoded" : "original"}`}
            ref={videoRef}
            class="video-screen"
            aria-label={selected()!.relativePath.split("/").at(-1)}
            controls
            playsInline
            preload="metadata"
            src={streamUrl()}
            onError$={async () => {
              if (state.transcodeLoading) return;
              if (state.transcode) {
                state.error =
                  "This video could not be played after conversion.";
                return;
              }
              await prepareBrowserCopy(state.selectedId);
            }}
            onLoadedMetadata$={(_, element) => {
              if (resumeAt.value <= 0) return;
              element.currentTime = resumeAt.value;
              resumeAt.value = 0;
            }}
            onTimeUpdate$={checkDecodedAudio}
          />
        ) : (
          <div class="video-screen video-screen-empty">
            <Icon name="video" size={42} />
            <p>{state.loading ? "Loading videos…" : "No videos found"}</p>
          </div>
        )}
        {(selected() || videoRoots.length > 1) && (
          <div class="video-title">
            <div class="video-title-text">
              {selected() && (
                <h2 title={fileName(selected()!.relativePath)}>
                  {displayTitle()}
                </h2>
              )}
              {videoRoots.length > 1 && (
                <label class="video-library-select">
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
            </div>
            {selected() && (
              <div class="video-actions">
                <button
                  type="button"
                  class="secondary-button compact-action video-action-button video-theatre-button"
                  aria-label="Theatre mode"
                  title="Theatre mode"
                  aria-pressed={theatre.value}
                  onClick$={toggleTheatre}
                >
                  <Icon name="theatre" size={16} />
                </button>
                {pipSupported.value && (
                  <button
                    type="button"
                    class="secondary-button compact-action video-action-button video-pip-button"
                    aria-label={
                      pipActive.value
                        ? "Exit picture in picture"
                        : "Picture in picture"
                    }
                    title={
                      pipActive.value
                        ? "Exit picture in picture"
                        : "Picture in picture"
                    }
                    aria-pressed={pipActive.value}
                    onClick$={togglePip}
                  >
                    <Icon name="picture-in-picture" size={14} />
                    <span class="video-action-label">
                      {pipActive.value
                        ? "Exit picture in picture"
                        : "Picture in picture"}
                    </span>
                  </button>
                )}
              </div>
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
        <label class="video-library-filter">
          <span class="sr-only">Filter videos by title or folder</span>
          <input
            type="search"
            placeholder="Filter videos"
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
                    <img
                      src={thumbnailSrc(
                        `/api/v1/items/${encodeURIComponent(item.id)}/image`,
                      )}
                      srcset={thumbnailSrcset(
                        `/api/v1/items/${encodeURIComponent(item.id)}/image`,
                      )}
                      sizes={thumbnailSizes("76px")}
                      alt=""
                      loading="lazy"
                      onError$={(_, image) => {
                        image.hidden = true;
                      }}
                    />
                  </span>
                  <VideoListCopy relativePath={item.relativePath} />
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>
    </section>
  );
});
