import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import "./video-transcript.css";
import { api, catalogItems, readableError } from "./api";
import { useBackLayer } from "./back-layers";
import type {
  ImmichAlbumList,
  ImmichVideo,
  ImmichVideoPage,
  VideoClip,
  VideoTranscript,
} from "./api-contract.generated";
import { Icon } from "./icon";
import { findTargetIndex, prepareBrowserPlayback } from "./playback-target";
import type { CatalogItem, MediaRoot } from "./root-types";
import { thumbnailSizes, thumbnailSrc, thumbnailSrcset } from "./thumbnail";
import {
  displayFolderName,
  displayTitleFromFileName,
  displayVideoTitleFromFileName,
  friendlyFolderName,
} from "./display-names";
import {
  audioNeedsBrowserConversion,
  decodedAudioState,
  probeReportsNoAudio,
} from "./video-audio";

const THEATRE_STORAGE_KEY = "media-manager.videos.theatre";
const CLIP_MAX_SECONDS = 30;

function clipTime(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

function fileName(relativePath: string): string {
  return relativePath.split("/").at(-1) ?? relativePath;
}

const DVD_PART = /^VTS_(\d+)_(\d+)$/i;
const EPISODE = /\bS(\d{1,2})\s?E(\d{1,3})(?:\s?-?\s?E\d{1,3})*\b/i;
const SEASON_FOLDER = /^(?:season|series)\s*\d+$|^specials$/i;

function fileStem(relativePath: string): string {
  const filename = fileName(relativePath);
  const extension = filename.match(/\.[^.\s]{1,5}$/)?.[0] ?? "";
  return extension && extension.length < filename.length
    ? filename.slice(0, -extension.length)
    : filename;
}

export type VideoCategory = "videos" | "youtube" | "movies" | "shows" | "dvds";

export interface VideoInfo {
  /** Standalone name: the show is included for an episode. */
  title: string;
  /** Name inside its group, where the group already names the show. */
  rowTitle: string;
  group: string;
  /** Season heading inside a show; empty otherwise. */
  section: string;
  /** Sort key inside the group. */
  order: string;
  /** Category the Videos page's selector reads. */
  category: VideoCategory;
  /** Orders groups: Movies, shows, YouTube, DVDs, folders, then the rest. */
  rank: number;
}

/**
 * What a viewer reads for a video file when no metadata title is known: no
 * extension, release noise or IDs; DVD `VTS_xx_y` parts take the disc
 * folder's name; episodes group under their show and season, YouTube
 * downloads under YouTube and films under Movies.
 */
export function videoInfo(relativePath: string): VideoInfo {
  const parts = relativePath.split("/").filter(Boolean);
  const file = parts.pop() ?? relativePath;
  const stem = fileStem(file);
  const lowerParts = parts.map((part) => part.toLowerCase());
  const dvd = stem.match(DVD_PART);
  let title = displayVideoTitleFromFileName(file);
  if (dvd) {
    const disc = [...parts]
      .reverse()
      .find((part) => !/^(?:VIDEO_TS|AUDIO_TS)$/i.test(part));
    const set = Number(dvd[1]);
    const part = Number(dvd[2]);
    const suffix =
      set === 1 && part <= 1
        ? ""
        : ` · title ${set}${part > 1 ? `, part ${part}` : ""}`;
    title =
      (disc ? displayTitleFromFileName(displayFolderName(disc)) : "DVD") +
      suffix;
  }
  const episode = stem.match(EPISODE);
  if (episode && !dvd) {
    const season = Number(episode[1]);
    const number = Number(episode[2]);
    const showIndex = lowerParts.findIndex((part) =>
      ["_shows", "_tv"].includes(part),
    );
    const showFolder =
      showIndex >= 0
        ? parts[showIndex + 1]
        : [...parts].reverse().find((part) => !SEASON_FOLDER.test(part));
    const before = stem.slice(0, episode.index).replace(/[\s._-]+$/, "");
    const show =
      (showFolder && displayFolderName(showFolder)) ||
      (before && displayVideoTitleFromFileName(before)) ||
      "TV shows";
    const after = displayVideoTitleFromFileName(
      stem
        .slice((episode.index ?? 0) + episode[0].length)
        .replace(/^[\s._-]+/, ""),
    );
    const episodeName = after;
    const rowTitle = `Episode ${number}${episodeName ? `: ${episodeName}` : ""}`;
    return {
      title: `${show} · S${season} E${number}${episodeName ? ` · ${episodeName}` : ""}`,
      rowTitle,
      group: show,
      section: season === 0 ? "Specials" : `Season ${season}`,
      order: `${String(season).padStart(3, "0")}${String(number).padStart(4, "0")}`,
      category: "shows",
      rank: 1,
    };
  }
  const youtube =
    lowerParts.includes("_youtube") ||
    /\[(?!(?:tmdb|tvdb|imdb|mbid|isbn|asin))[A-Za-z0-9_-]{11}\]/i.test(stem);
  const movie =
    lowerParts.includes("_movies") ||
    (!youtube && /\((?:19|20)\d{2}\)(?:\s·.*)?$/.test(title));
  const [group, rank, category]: [string, number, VideoCategory] = youtube
    ? ["YouTube", 2, "youtube"]
    : movie
      ? ["Movies", 0, "movies"]
      : dvd
        ? ["DVDs", 3, "dvds"]
        : parts[0]?.startsWith("_")
          ? [friendlyFolderName(parts[0]), 4, "videos"]
          : parts.length > 0
            ? [displayFolderName(parts.at(-1) ?? ""), 4, "videos"]
            : ["Other videos", 5, "videos"];
  return {
    title,
    rowTitle: title,
    group,
    section: "",
    order: title,
    category,
    rank,
  };
}

interface VideoGroup {
  name: string;
  sections: { name: string; items: { item: CatalogItem; info: VideoInfo }[] }[];
}

/** Lightweight library sections: Movies, each show by season, YouTube, folders. */
export function groupVideos(items: CatalogItem[]): VideoGroup[] {
  const groups = new Map<
    string,
    Map<string, { item: CatalogItem; info: VideoInfo }[]>
  >();
  const ranks = new Map<string, number>();
  for (const item of items) {
    const info = videoInfo(item.relativePath);
    const sections = groups.get(info.group) ?? new Map();
    groups.set(info.group, sections);
    ranks.set(info.group, Math.min(ranks.get(info.group) ?? 9, info.rank));
    const rows = sections.get(info.section) ?? [];
    sections.set(info.section, rows);
    rows.push({ item, info });
  }
  return [...groups.entries()]
    .sort(
      ([a], [b]) =>
        (ranks.get(a) ?? 9) - (ranks.get(b) ?? 9) || a.localeCompare(b),
    )
    .map(([name, sections]) => ({
      name,
      sections: [...sections.entries()]
        .sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true }))
        .map(([section, rows]) => ({
          name: section,
          items: rows.sort((a, b) =>
            a.info.order.localeCompare(b.info.order, undefined, {
              numeric: true,
            }),
          ),
        })),
    }));
}

export type VideoCategoryChoice = VideoCategory | "immich";

export const VIDEO_CATEGORY_OPTIONS: ReadonlyArray<{
  id: VideoCategoryChoice;
  label: string;
}> = [
  { id: "videos", label: "Videos" },
  { id: "youtube", label: "YouTube" },
  { id: "movies", label: "Movies" },
  { id: "shows", label: "TV shows" },
  { id: "dvds", label: "DVDs" },
  { id: "immich", label: "Videos in Photos" },
];

/**
 * Videos is the default because Jellyfin already covers the film and episode
 * folders. It deliberately includes YouTube: those downloads never reach
 * Jellyfin, so they belong with the everyday videos rather than hidden behind
 * another choice. The YouTube entry narrows the same content further.
 */
export function inVideoCategory(
  info: VideoInfo,
  category: VideoCategory,
): boolean {
  return category === "videos"
    ? info.category === "videos" || info.category === "youtube"
    : info.category === category;
}

// Module scope keeps the lookup usable inside task closures, which Qwik
// cannot serialize while it captures a component-local function.
function selectedItem(
  items: CatalogItem[],
  selectedId: string,
): CatalogItem | undefined {
  return items.find((item) => item.id === selectedId);
}

function itemsInVideoCategory(
  items: CatalogItem[],
  category: VideoCategoryChoice,
): CatalogItem[] {
  if (category === "immich") return [];
  return items.filter((item) =>
    inVideoCategory(videoInfo(item.relativePath), category),
  );
}

export const VideosView = component$<{
  roots: MediaRoot[];
  immichUrl?: string;
  initialItemId?: string;
  initialPath?: string;
  initialRootId?: string;
}>((props) => {
  const videoRef = useSignal<HTMLVideoElement>();
  const transcript = useStore({
    open: false,
    query: "",
    error: "",
    cues: [] as VideoTranscript["cues"],
  });
  const pipSupported = useSignal(false);
  const pipActive = useSignal(false);
  const theatre = useSignal(false);
  const clip = useStore({
    open: false,
    busy: false,
    loadingAlbums: false,
    error: "",
    start: 0,
    seconds: 5,
    albums: [] as ImmichAlbumList["albums"],
    albumId: "",
    albumName: "GIF",
  });
  const clipNotice = useSignal<{ albumId: string; albumName: string } | null>(
    null,
  );
  // Position to restore when the converted copy replaces the original, so a
  // long conversion does not send the viewer back to the start.
  const resumeAt = useSignal(0);
  const resumePlaying = useSignal(false);
  const state = useStore({
    items: [] as CatalogItem[],
    selectedId: "",
    title: "",
    rootId: "",
    query: "",
    category: "videos" as VideoCategoryChoice,
    immichItems: [] as ImmichVideo[],
    immichSelectedId: "",
    immichNextPage: null as number | null,
    immichLoading: false,
    immichLoaded: false,
    immichError: "",
    loading: true,
    error: "",
    transcode: false,
    transcodeLoading: false,
    audioChecked: false,
  });
  useTask$(({ track, cleanup }) => {
    const id = track(() => state.selectedId);
    const category = track(() => state.category);
    let stopped = false;
    cleanup(() => {
      stopped = true;
    });
    transcript.open = false;
    transcript.query = "";
    transcript.cues = [];
    transcript.error = "";
    if (!id || category === "immich") return;
    void api<VideoTranscript>(`/items/${encodeURIComponent(id)}/transcript`)
      .then((result) => {
        if (!stopped) transcript.cues = result.cues;
      })
      .catch((error) => {
        if (!stopped) transcript.error = readableError(error);
      });
  });
  const configuredVideoRoots = props.roots.filter(
    (root) => root.category === "videos",
  );
  const videoRoots = configuredVideoRoots.filter(
    (root) => root.category === "videos" && root.available,
  );

  const loadGeneration = useSignal(0);
  const immichGeneration = useSignal(0);
  const preparationGeneration = useSignal(0);
  const titleGeneration = useSignal(0);
  const deepLinkRefresh = useSignal("");
  const deepLinkNotice = useSignal("");
  const deepLinkGeneration = useSignal(0);
  const deepLinkRouteKey = useSignal("");
  // Bumped by any deliberate choice, so a deep-link rescan that finishes later
  // cannot move the selection away from the video the user picked.
  const navigationGeneration = useSignal(0);

  // Every route change (and unmount) invalidates a deep link that is still
  // waiting on a scan or a reload, including a path that returns to a value
  // an older task already captured.
  useVisibleTask$(({ track, cleanup }) => {
    const key = track(
      () => `${props.initialItemId ?? ""}|${props.initialPath ?? ""}`,
    );
    if (deepLinkRouteKey.value && deepLinkRouteKey.value !== key)
      deepLinkGeneration.value++;
    deepLinkRouteKey.value = key;
    cleanup(() => {
      deepLinkGeneration.value++;
    });
  });

  const loadVideos = $(async (valid?: () => boolean) => {
    const generation = ++loadGeneration.value;
    const current = () =>
      generation === loadGeneration.value && (valid?.() ?? true);
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
        const target =
          requestedIndex >= 0 ? state.items[requestedIndex] : undefined;
        if (target) {
          // A library or downloader link names one video; open the category
          // that holds it so the selected row is visible in the list.
          state.category = videoInfo(target.relativePath).category;
          state.selectedId = target.id;
        } else if (state.category !== "immich") {
          state.selectedId =
            itemsInVideoCategory(state.items, state.category)[0]?.id ?? "";
        }
        state.transcode = false;
        state.transcodeLoading = false;
        state.audioChecked = false;
      } else if (state.category !== "immich") {
        // The default Videos category may not contain an item selected from a
        // previous visit; fall back to its first video.
        const visible = itemsInVideoCategory(state.items, state.category);
        if (!visible.some((item) => item.id === state.selectedId)) {
          state.selectedId = visible[0]?.id ?? "";
          state.transcode = false;
          state.transcodeLoading = false;
          state.audioChecked = false;
        }
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

  // A rescan can empty the chosen category or disable Photos; keep the page on
  // the default rather than showing a select with no matching option.
  useTask$(({ track }) => {
    track(() => state.items.map((item) => item.id).join("|"));
    track(() => props.immichUrl);
    track(() => state.loading);
    if (state.category === "immich") {
      if (!props.immichUrl) {
        state.category = "videos";
        state.query = "";
        state.immichError = "";
      }
      return;
    }
    if (
      state.category !== "videos" &&
      !state.loading &&
      itemsInVideoCategory(state.items, state.category).length === 0
    ) {
      state.category = "videos";
      state.query = "";
    }
  });

  const loadImmichVideos = $(async (more: boolean) => {
    if (!props.immichUrl) return;
    const generation = ++immichGeneration.value;
    const page = more ? (state.immichNextPage ?? 1) : 1;
    const current = () => generation === immichGeneration.value;
    state.immichLoading = true;
    state.immichError = "";
    try {
      const result = await api<ImmichVideoPage>(
        `/provider-lookups/immich/videos?page=${page}`,
      );
      if (!current()) return;
      state.immichItems = more
        ? [...state.immichItems, ...result.items]
        : result.items;
      state.immichNextPage = result.nextPage;
      state.immichLoaded = true;
      if (
        !state.immichItems.some((asset) => asset.id === state.immichSelectedId)
      ) {
        state.immichSelectedId = state.immichItems[0]?.id ?? "";
      }
    } catch (error) {
      if (current()) state.immichError = readableError(error);
    } finally {
      if (current()) state.immichLoading = false;
    }
  });

  const chooseCategory = $((value: string) => {
    const category = value as VideoCategoryChoice;
    if (category === state.category) return;
    state.category = category;
    state.query = "";
    state.title = "";
    state.error = "";
    state.transcode = false;
    state.transcodeLoading = false;
    state.audioChecked = false;
    state.immichError = "";
    transcript.open = false;
    transcript.query = "";
    transcript.cues = [];
    transcript.error = "";
    resumeAt.value = 0;
    resumePlaying.value = false;
    clip.open = false;
    clip.busy = false;
    clip.error = "";
    clipNotice.value = null;
    if (category === "immich") {
      if (!state.immichLoaded) void loadImmichVideos(false);
      return;
    }
    const visible = itemsInVideoCategory(state.items, category);
    if (!visible.some((item) => item.id === state.selectedId)) {
      state.selectedId = visible[0]?.id ?? "";
    }
  });

  const chooseImmichVideo = $((id: string) => {
    state.immichSelectedId = id;
    state.title = "";
    state.transcode = false;
    state.transcodeLoading = false;
    state.audioChecked = false;
    state.error = "";
    transcript.open = false;
    transcript.query = "";
    transcript.cues = [];
    transcript.error = "";
    resumeAt.value = 0;
    resumePlaying.value = false;
    clip.open = false;
    clip.busy = false;
    clip.error = "";
    clipNotice.value = null;
  });

  const chooseVideo = $((id: string) => {
    preparationGeneration.value++;
    navigationGeneration.value++;
    state.selectedId = id;
    state.title = "";
    state.transcode = false;
    state.transcodeLoading = false;
    state.audioChecked = false;
    state.error = "";
    deepLinkNotice.value = "";
    resumeAt.value = 0;
    resumePlaying.value = false;
    clip.open = false;
    clip.busy = false;
    clip.error = "";
    clipNotice.value = null;
  });

  // A finished download can reach the library before the next scheduled scan
  // of its root, so a path deep link can miss the catalog even though the file
  // exists. Refresh the hinted root (or every video root) once and retry.
  const refreshVideoRoots = $(async (rootId?: string) => {
    const hinted =
      rootId != null ? videoRoots.filter((root) => root.id === rootId) : [];
    const targets = hinted.length > 0 ? hinted : videoRoots;
    await Promise.all(
      targets.map(async (root) => {
        try {
          await api("/catalog/refresh", {
            method: "POST",
            body: JSON.stringify({ rootId: root.id }),
          });
        } catch {
          // Ignore cooldowns and scan failures; the retry below decides.
        }
      }),
    );
  });

  // Applying a link is detached from the visible task: a pending scan must not
  // block the next link's task from running. A newer link replaces the value
  // checked here, so the older scan can finish without taking over.
  const applyVideoDeepLink = $(async (path: string) => {
    const generation = ++deepLinkGeneration.value;
    const navigation = navigationGeneration.value;
    const stillCurrent = () =>
      generation === deepLinkGeneration.value &&
      deepLinkRefresh.value === path &&
      props.initialPath === path &&
      !props.initialItemId &&
      navigation === navigationGeneration.value;
    await refreshVideoRoots(props.initialRootId);
    if (!stillCurrent()) return;
    // The reload is guarded too: a route change while it runs must not let its
    // items, selection or error land on the newer link.
    await loadVideos(stillCurrent);
    if (!stillCurrent()) return;
    const index = findTargetIndex(state.items, undefined, path);
    if (index < 0) {
      deepLinkNotice.value =
        "The linked download isn't in the video library. It may still be copying, or saved in a container the library doesn't index.";
      return;
    }
    // loadVideos keeps an unrelated sibling selected when one was already
    // present, so move the selection onto the refreshed link explicitly.
    const target = state.items[index]!;
    state.category = videoInfo(target.relativePath).category;
    await chooseVideo(target.id);
  });

  useVisibleTask$(
    ({ track }) => {
      track(() => state.loading);
      track(() => props.initialPath);
      track(() => props.initialItemId);
      const path = props.initialPath;
      if (!path || props.initialItemId || state.loading) return;
      if (findTargetIndex(state.items, undefined, path) >= 0) {
        deepLinkNotice.value = "";
        return;
      }
      if (deepLinkRefresh.value === path) return;
      deepLinkRefresh.value = path;
      void applyVideoDeepLink(path);
    },
    { strategy: "document-ready" },
  );

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
        // The original (silent) copy keeps playing while the server converts,
        // so keep the position the viewer has reached, not the one they had
        // when the conversion started.
        resumeAt.value = videoRef.value?.currentTime ?? started;
        resumePlaying.value = !(videoRef.value?.paused ?? true);
        state.transcode = true;
      }
    } catch (error) {
      if (current()) state.error = readableError(error);
    } finally {
      if (current()) state.transcodeLoading = false;
    }
  });

  useTask$(({ track }) => {
    track(() => state.selectedId);
    track(() => state.category);
    if (state.category === "immich") return;
    const item = selectedItem(state.items, state.selectedId);
    if (!item || !audioNeedsBrowserConversion(item.videoProbe)) return;
    // Preparing polls until the server has the file, which takes minutes for a
    // full film. Awaiting it here would hold Qwik's render flush, so the
    // "converting" status and every other update would appear only at the end.
    void prepareBrowserCopy(item.id);
  });

  // The probe cache fills in the background, so a just-scanned video may not
  // have one yet. Chrome and Firefox report whether audio was actually decoded
  // after playback starts; an unprobed silent element means the track was
  // dropped, and the conversion restores it.
  const checkDecodedAudio = $(() => {
    const video = videoRef.value;
    if (
      !video ||
      state.category === "immich" ||
      state.transcode ||
      state.transcodeLoading ||
      state.audioChecked
    )
      return;
    if (video.currentTime < 3) return;
    state.audioChecked = true;
    const item = selectedItem(state.items, state.selectedId);
    if (!item || item.videoProbe || probeReportsNoAudio(item.videoProbe))
      return;
    if (decodedAudioState(video) !== "silent") return;
    void prepareBrowserCopy(item.id);
  });

  useTask$(async ({ track }) => {
    track(() => state.selectedId);
    track(() => state.category);
    const itemId = state.selectedId;
    const generation = ++titleGeneration.value;
    const current = () => generation === titleGeneration.value;
    state.title = "";
    if (!itemId || state.category === "immich") return;
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

  const closeClipDialog = $(() => {
    clip.open = false;
    clip.error = "";
  });

  const clipDialogOpen = useComputed$(() => clip.open);
  useBackLayer("gif-dialog", clipDialogOpen, closeClipDialog);

  const chooseClipAlbum = $((value: string) => {
    clip.albumId = value;
    if (!value) {
      clip.albumName = "GIF";
      return;
    }
    const album = clip.albums.find((entry) => entry.id === value);
    if (album) clip.albumName = album.name;
  });

  const openClipDialog = $(async () => {
    if (!videoRef.value || !selectedItem(state.items, state.selectedId)) return;
    const video = videoRef.value;
    const remaining = Number.isFinite(video.duration)
      ? Math.max(0, video.duration - video.currentTime)
      : CLIP_MAX_SECONDS;
    clip.open = true;
    clip.error = "";
    clip.start = video.currentTime;
    // Default to five seconds, but never ask for more than the video has left.
    clip.seconds = Math.min(
      CLIP_MAX_SECONDS,
      Math.max(1, Math.floor(Math.min(5, remaining))),
    );
    clipNotice.value = null;
    clip.loadingAlbums = true;
    clip.albums = [];
    clip.albumId = "";
    clip.albumName = "GIF";
    try {
      const payload = await api<ImmichAlbumList>(
        "/provider-lookups/immich/albums",
      );
      clip.albums = payload.albums;
      const gif = payload.albums.find(
        (album) => album.name.trim().toLowerCase() === "gif",
      );
      if (gif) {
        clip.albumId = gif.id;
        clip.albumName = gif.name;
      }
    } catch (error) {
      // A missing album list must not block the default GIF album; the upload
      // creates it on demand unless creating it is itself forbidden.
      clip.error = readableError(error);
    } finally {
      clip.loadingAlbums = false;
    }
  });

  const createClip = $(async () => {
    const item = selectedItem(state.items, state.selectedId);
    if (!item || clip.busy) return;
    const seconds = Math.min(
      CLIP_MAX_SECONDS,
      Math.max(1, Math.floor(clip.seconds)),
    );
    clip.seconds = seconds;
    clip.busy = true;
    clip.error = "";
    try {
      const created = await api<VideoClip>(
        `/items/${encodeURIComponent(item.id)}/clips`,
        {
          method: "POST",
          body: JSON.stringify({
            startSeconds: clip.start,
            durationSeconds: seconds,
            albumId: clip.albumId || null,
            albumName: clip.albumName || "GIF",
          }),
        },
        180_000,
      );
      clip.open = false;
      clipNotice.value = {
        albumId: created.albumId,
        albumName: created.albumName,
      };
    } catch (error) {
      clip.error = readableError(error);
    } finally {
      clip.busy = false;
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
    state.category === "immich"
      ? undefined
      : state.items.find((item) => item.id === state.selectedId);
  const selectedImmich = () =>
    state.category === "immich"
      ? state.immichItems.find((asset) => asset.id === state.immichSelectedId)
      : undefined;
  const hasSelection = () => Boolean(selected() ?? selectedImmich());
  const displayTitle = () => {
    const item = selected();
    if (item) return state.title || videoInfo(item.relativePath).title;
    const asset = selectedImmich();
    return asset ? displayVideoTitleFromFileName(asset.filename) : "";
  };
  const playbackLabel = () =>
    selected()
      ? fileName(selected()!.relativePath)
      : (selectedImmich()?.filename ?? "");
  const playbackKey = () =>
    selected()
      ? `${state.selectedId}-${state.transcode ? "transcoded" : "original"}`
      : `immich-${state.immichSelectedId}`;
  const streamUrl = () => {
    const item = selected();
    if (item) {
      const suffix = state.transcode ? "?transcode=1" : "";
      return `/api/v1/items/${encodeURIComponent(item.id)}/stream${suffix}`;
    }
    const asset = selectedImmich();
    return asset
      ? `/api/v1/provider-lookups/immich/videos/${encodeURIComponent(asset.id)}/playback`
      : "";
  };
  /** Keep categories that hold something, plus the two always-useful ones. */
  const categoryChoices = () =>
    VIDEO_CATEGORY_OPTIONS.filter((option) => {
      const category = option.id;
      if (category === "videos") return true;
      if (category === "immich") return Boolean(props.immichUrl);
      return state.items.some((item) =>
        inVideoCategory(videoInfo(item.relativePath), category),
      );
    });
  const query = state.query.trim().toLowerCase();
  const categoryItems = itemsInVideoCategory(state.items, state.category);
  const visibleItems = query
    ? categoryItems.filter(
        (item) =>
          item.relativePath.toLowerCase().includes(query) ||
          videoInfo(item.relativePath).title.toLowerCase().includes(query),
      )
    : categoryItems;
  const visibleGroups = groupVideos(visibleItems);
  const visibleImmichVideos = query
    ? state.immichItems.filter(
        (asset) =>
          asset.filename.toLowerCase().includes(query) ||
          displayVideoTitleFromFileName(asset.filename)
            .toLowerCase()
            .includes(query),
      )
    : state.immichItems;
  // The chosen category already names its only group in these cases.
  const headingRepeatsCategory = (groupName: string) =>
    (state.category === "movies" && groupName === "Movies") ||
    (state.category === "youtube" && groupName === "YouTube") ||
    (state.category === "dvds" && groupName === "DVDs");

  useVisibleTask$(({ track, cleanup }) => {
    track(() => state.selectedId);
    track(() => state.immichSelectedId);
    track(() => state.category);
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
    track(() => state.immichSelectedId);
    track(() => state.category);
    track(() => state.transcode);
    if (typeof navigator === "undefined" || !("mediaSession" in navigator)) {
      return;
    }
    const item = selectedItem(state.items, state.selectedId);
    const asset =
      state.category === "immich"
        ? state.immichItems.find(
            (candidate) => candidate.id === state.immichSelectedId,
          )
        : undefined;
    if (state.category === "immich" ? !asset : !item) return;
    const info = item ? videoInfo(item.relativePath) : undefined;
    let sessionMetadata: MediaMetadata | null = null;
    const claimSession = () => {
      sessionMetadata = new MediaMetadata({
        title:
          state.title ||
          info?.title ||
          (asset ? displayVideoTitleFromFileName(asset.filename) : ""),
        artist: info?.group ?? "Photos",
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
        {hasSelection() ? (
          <video
            key={playbackKey()}
            ref={videoRef}
            class="video-screen"
            aria-label={playbackLabel()}
            controls
            playsInline
            preload="metadata"
            src={streamUrl()}
            onError$={async () => {
              if (state.transcodeLoading) return;
              if (state.category === "immich" || !state.selectedId) {
                state.error =
                  "This video could not be played from Photos. Try again, or check that it still exists in Photos.";
                return;
              }
              if (state.transcode) {
                state.error =
                  "This video could not be played after conversion.";
                return;
              }
              await prepareBrowserCopy(state.selectedId);
            }}
            onLoadedMetadata$={(_, element) => {
              if (resumeAt.value > 0) {
                element.currentTime = resumeAt.value;
                resumeAt.value = 0;
              }
              if (resumePlaying.value) {
                resumePlaying.value = false;
                void element.play?.()?.catch(() => {});
              }
            }}
            onTimeUpdate$={checkDecodedAudio}
          />
        ) : (
          <div class="video-screen video-screen-empty">
            <Icon name="video" size={42} />
            <p>
              {state.loading ||
              (state.category === "immich" &&
                state.immichLoading &&
                state.immichItems.length === 0)
                ? "Loading videos…"
                : state.category === "videos"
                  ? "No regular videos here"
                  : "No videos found"}
            </p>
          </div>
        )}
        {(hasSelection() || videoRoots.length > 1) && (
          <div class="video-title">
            <div class="video-title-text">
              {hasSelection() && (
                <h2 title={playbackLabel()}>{displayTitle()}</h2>
              )}
              {videoRoots.length > 1 && state.category !== "immich" && (
                <label class="video-library-select">
                  <span>Show</span>
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
            {hasSelection() && (
              <div class="video-actions">
                {(transcript.cues.length > 0 || transcript.error) && (
                  <button
                    type="button"
                    class="secondary-button compact-action video-action-button"
                    aria-expanded={transcript.open}
                    aria-controls="video-transcript"
                    onClick$={() => {
                      transcript.open = !transcript.open;
                    }}
                  >
                    Transcript
                  </button>
                )}
                {props.immichUrl && selected() && (
                  <button
                    type="button"
                    class="secondary-button compact-action video-action-button video-clip-button"
                    aria-haspopup="dialog"
                    onClick$={openClipDialog}
                  >
                    <Icon name="film" size={14} />
                    <span class="video-action-label">Create GIF</span>
                  </button>
                )}
                <button
                  type="button"
                  class="secondary-button compact-action video-action-button video-theatre-button"
                  aria-label="Theatre mode"
                  title="Theatre mode"
                  aria-pressed={theatre.value}
                  onClick$={toggleTheatre}
                >
                  <Icon name="theatre" size={16} />
                  <span class="video-action-label">Theatre mode</span>
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
        {transcript.open && (
          <section
            id="video-transcript"
            class="video-transcript"
            aria-label="Transcript"
          >
            <label>
              <span class="sr-only">Search transcript</span>
              <input
                type="search"
                placeholder="Search transcript"
                value={transcript.query}
                onInput$={(_, input) => {
                  transcript.query = input.value;
                }}
              />
            </label>
            {transcript.error && <p role="alert">{transcript.error}</p>}
            <ol class="video-transcript-lines" aria-label="Dialogue">
              {transcript.cues
                .filter((cue) =>
                  cue.text
                    .toLocaleLowerCase()
                    .includes(transcript.query.trim().toLocaleLowerCase()),
                )
                .map((cue) => (
                  <li key={cue.index}>
                    <button
                      type="button"
                      onClick$={() => {
                        const video = videoRef.value;
                        if (video) video.currentTime = cue.startMs / 1000;
                      }}
                    >
                      <time>{clipTime(cue.startMs / 1000)}</time>
                      <span>{cue.text}</span>
                    </button>
                  </li>
                ))}
            </ol>
            {!transcript.error &&
              !transcript.cues.some((cue) =>
                cue.text
                  .toLocaleLowerCase()
                  .includes(transcript.query.trim().toLocaleLowerCase()),
              ) && <p role="status">No matching dialogue.</p>}
          </section>
        )}
        {clipNotice.value && props.immichUrl && (
          <p class="video-clip-status" role="status">
            GIF saved to{" "}
            <a
              href={`${props.immichUrl.replace(/\/+$/, "")}/albums/${encodeURIComponent(clipNotice.value.albumId)}`}
              target="_blank"
              rel="noreferrer"
            >
              {clipNotice.value.albumName}
            </a>
          </p>
        )}
        {clip.open && selected() && (
          <div class="dialog-backdrop" onClick$={closeClipDialog}>
            <form
              class="dialog clip-dialog"
              role="dialog"
              aria-modal="true"
              aria-labelledby="clip-dialog-heading"
              onClick$={(event) => event.stopPropagation()}
              preventdefault:submit
              onSubmit$={createClip}
            >
              <div class="dialog-header">
                <h3 id="clip-dialog-heading">Create GIF</h3>
                <button
                  type="button"
                  class="dialog-close"
                  aria-label="Close"
                  onClick$={closeClipDialog}
                >
                  ×
                </button>
              </div>
              <div class="dialog-body clip-form">
                <p class="clip-source">{displayTitle()}</p>
                <p class="clip-range">
                  From {clipTime(clip.start)} · {clip.seconds}s clip
                </p>
                <label class="clip-field">
                  <span>Length (seconds)</span>
                  <input
                    type="number"
                    min={1}
                    max={CLIP_MAX_SECONDS}
                    value={clip.seconds}
                    disabled={clip.busy}
                    onInput$={(_, element) => {
                      clip.seconds = Number(element.value) || 1;
                    }}
                  />
                </label>
                <label class="clip-field">
                  <span>Album</span>
                  <select
                    value={clip.albumId}
                    disabled={clip.busy || clip.loadingAlbums}
                    onChange$={(_, element) => chooseClipAlbum(element.value)}
                  >
                    {clip.albums.map((album) => (
                      <option key={album.id} value={album.id}>
                        {album.name}
                      </option>
                    ))}
                    {!clip.albums.some(
                      (album) => album.name.trim().toLowerCase() === "gif",
                    ) && <option value="">GIF (new album)</option>}
                  </select>
                </label>
                {clip.loadingAlbums && (
                  <p class="quiet-copy">Loading albums…</p>
                )}
                {clip.error && (
                  <p class="message error" role="alert">
                    {clip.error}
                  </p>
                )}
                <div class="clip-dialog-actions">
                  <button
                    type="button"
                    class="secondary-button"
                    disabled={clip.busy}
                    onClick$={closeClipDialog}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="primary-button"
                    disabled={clip.busy}
                  >
                    {clip.busy ? "Creating GIF…" : "Create GIF"}
                  </button>
                </div>
              </div>
            </form>
          </div>
        )}
        {state.transcodeLoading && (
          <p role="status" class="video-conversion-status">
            Converting this video for browser playback. The first play may take
            a while.
          </p>
        )}
        {state.transcodeLoading && (
          <p class="video-conversion-hint">
            For better loading times and device compatibility, consider
            converting this video to another format in the{" "}
            <a
              href={`?view=conversions&item=${encodeURIComponent(state.selectedId)}`}
            >
              Conversions page
            </a>
            .
          </p>
        )}
        {state.error && (
          <p class="message error" role="alert">
            {state.error}
          </p>
        )}
      </div>

      <aside class="video-library" aria-label="Video library">
        <label class="video-category-select">
          <span>Category</span>
          <select
            value={state.category}
            onChange$={(_, element) => chooseCategory(element.value)}
          >
            {categoryChoices().map((option) => (
              <option key={option.id} value={option.id}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        <label class="video-library-filter">
          <span class="sr-only">Filter videos by title or folder</span>
          <input
            type="search"
            placeholder="Filter videos"
            value={state.query}
            onInput$={(_, element) => (state.query = element.value)}
          />
        </label>
        {deepLinkNotice.value && (
          <p class="video-library-empty" role="status">
            {deepLinkNotice.value}
          </p>
        )}
        {state.category === "immich" ? (
          <>
            {state.immichError && (
              <div class="video-library-error">
                <p class="message error" role="alert">
                  {state.immichError}
                </p>
                <button
                  type="button"
                  class="secondary-button"
                  disabled={state.immichLoading}
                  onClick$={() => loadImmichVideos(false)}
                >
                  Try again
                </button>
              </div>
            )}
            {state.immichLoading && state.immichItems.length === 0 ? (
              <p class="video-library-empty">Loading videos from Photos…</p>
            ) : state.immichItems.length === 0 ? (
              !state.immichError && (
                <p class="video-library-empty">No videos in Photos.</p>
              )
            ) : (
              <>
                {visibleImmichVideos.length === 0 ? (
                  <p class="video-library-empty">No matching videos.</p>
                ) : (
                  <ul class="video-list">
                    {visibleImmichVideos.map((asset) => (
                      <li
                        key={asset.id}
                        class={{
                          active: asset.id === state.immichSelectedId,
                        }}
                      >
                        <button
                          type="button"
                          aria-current={
                            asset.id === state.immichSelectedId
                              ? "true"
                              : undefined
                          }
                          onClick$={() => chooseImmichVideo(asset.id)}
                        >
                          <span class="video-list-icon">
                            <Icon name="video" />
                            <img
                              src={thumbnailSrc(
                                `/api/v1/provider-lookups/immich/videos/${encodeURIComponent(asset.id)}/thumbnail`,
                              )}
                              srcset={thumbnailSrcset(
                                `/api/v1/provider-lookups/immich/videos/${encodeURIComponent(asset.id)}/thumbnail`,
                              )}
                              sizes={thumbnailSizes("76px")}
                              alt=""
                              loading="lazy"
                              onError$={(_, image) => {
                                image.hidden = true;
                              }}
                            />
                          </span>
                          <span class="video-list-copy">
                            <strong title={asset.filename}>
                              {displayVideoTitleFromFileName(asset.filename)}
                            </strong>
                          </span>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                {state.immichNextPage !== null && (
                  <button
                    type="button"
                    class="secondary-button video-library-more"
                    disabled={state.immichLoading}
                    onClick$={() => loadImmichVideos(true)}
                  >
                    {state.immichLoading ? "Loading videos…" : "Load more"}
                  </button>
                )}
              </>
            )}
          </>
        ) : state.loading ? (
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
          <p class="video-library-empty">
            {query
              ? "No matching videos."
              : state.category === "videos"
                ? "No regular videos here."
                : "No videos in this category."}
          </p>
        ) : (
          <ul class="video-list">
            {visibleGroups.map((group) => (
              <li key={group.name} class="video-list-group">
                {!headingRepeatsCategory(group.name) && <h3>{group.name}</h3>}
                {group.sections.map((section) => (
                  <div key={section.name} class="video-list-section">
                    {section.name && <h4>{section.name}</h4>}
                    <ul>
                      {section.items.map(({ item, info }) => (
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
                            <span class="video-list-copy">
                              <strong title={fileName(item.relativePath)}>
                                {info.rowTitle}
                              </strong>
                            </span>
                          </button>
                        </li>
                      ))}
                    </ul>
                  </div>
                ))}
              </li>
            ))}
          </ul>
        )}
      </aside>
    </section>
  );
});
